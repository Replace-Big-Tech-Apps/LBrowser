import AppKit
import Observation
import SwiftUI

struct Suggestion: Equatable {
    enum Kind { case history, search, address }
    let kind: Kind
    let title: String
    let detail: String
    let url: URL
    /// Text shown in the address field while this row is highlighted.
    let fill: String
}

/// State behind the address bar's dropdown: inline history completion plus history and search suggestions.
@Observable @MainActor
final class Omnibox {
    private(set) var suggestions: [Suggestion] = []
    private(set) var highlighted = 0
    var isOpen: Bool { !suggestions.isEmpty }

    @ObservationIgnored private(set) var typed = ""
    @ObservationIgnored private(set) var completion: HistoryStore.Completion?
    @ObservationIgnored var isPrivate = false
    @ObservationIgnored private var remote: [String] = []
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private let history: HistoryStore
    private let maxRows = 8

    init(history: HistoryStore? = nil) {
        self.history = history ?? .shared
    }

    private var query: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Called on every edit. Returns the inline completion to append (and select) after the typed text.
    func update(typed: String, allowCompletion: Bool) -> String? {
        self.typed = typed
        completion = allowCompletion && typed == typed.trimmingCharacters(in: .whitespaces) ? history.completion(for: typed) : nil
        highlighted = 0
        guard !query.isEmpty else { close(); return nil }
        rebuild()
        fetchRemote()
        return completion?.suffix
    }

    /// Moves the highlight; returns the text the field should now show.
    func move(by delta: Int) -> String? {
        guard isOpen else { return nil }
        highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        return highlighted == 0 ? typed + (completion?.suffix ?? "") : suggestions[highlighted].fill
    }

    /// Where Enter goes for the field's current text.
    func destination(for fieldText: String) -> URL? {
        if isOpen, highlighted > 0 { return suggestions[highlighted].url }
        if let completion, fieldText == typed + completion.suffix { return completion.url }
        return AddressParser.url(from: fieldText)
    }

    func close() {
        fetchTask?.cancel()
        suggestions = []
        remote = []
        highlighted = 0
        typed = ""
        completion = nil
    }

    private func rebuild() {
        let q = query
        var rows: [Suggestion] = []
        let engine = SearchEngine.current

        if let c = completion {
            let full = typed + c.suffix
            rows.append(Suggestion(kind: .history, title: c.title.isEmpty ? full : c.title, detail: full, url: c.url, fill: full))
        } else if let url = AddressParser.address(from: q) {
            rows.append(Suggestion(kind: .address, title: q, detail: "Open address", url: url, fill: q))
        } else if let url = engine.url(for: q) {
            rows.append(Suggestion(kind: .search, title: q, detail: "Search \(engine.label)", url: url, fill: q))
        }

        let shown = Set(rows.map { Self.key($0.url) })
        let pages = history.matches(for: q, limit: maxRows)
            .filter { !shown.contains(Self.key($0.url)) }
            .map { e in
                let bare = e.bareURL.hasPrefix("www.") ? String(e.bareURL.dropFirst(4)) : e.bareURL
                return Suggestion(kind: .history, title: e.title.isEmpty ? bare : e.title, detail: bare,
                                  url: e.url, fill: e.url.absoluteString)
            }
        let searches = remote
            .filter { $0.lowercased() != q.lowercased() }
            .compactMap { s in engine.url(for: s).map { Suggestion(kind: .search, title: s, detail: "", url: $0, fill: s) } }

        // Up to 3 history pages, then search suggestions, then more history if there is room.
        rows += pages.prefix(3)
        rows += searches.prefix(maxRows - rows.count)
        rows += pages.dropFirst(3).prefix(max(0, maxRows - rows.count))
        suggestions = rows
    }

    private func fetchRemote() {
        fetchTask?.cancel()
        let q = query
        guard !isPrivate, SearchSuggestions.isEnabled, !q.contains("://") else {
            remote = []
            return
        }
        fetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await SearchSuggestions.fetch(q)
            guard let self, !Task.isCancelled, self.query == q else { return }
            self.remote = results
            // Don't reshuffle rows under the user's keyboard selection.
            if self.highlighted == 0, !self.suggestions.isEmpty { self.rebuild() }
        }
    }

    private static func key(_ url: URL) -> String {
        var s = url.absoluteString.lowercased()
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: Field

/// AppKit text field: SwiftUI's TextField can't select an inline completion or intercept ↑/↓.
struct OmniboxField: NSViewRepresentable {
    let omnibox: Omnibox
    var placeholder: String
    var displayText: String
    var focusTick: Int
    var isPrivate: Bool
    @Binding var isFocused: Bool
    var onCommit: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusField {
        let field = FocusField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = displayText
        field.placeholderString = placeholder
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocus = { [weak field, weak coordinator = context.coordinator] in
            if let field { coordinator?.didFocus(field) }
        }
        context.coordinator.lastTick = focusTick
        return field
    }

    func updateNSView(_ field: FocusField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        if !coordinator.editing, field.stringValue != displayText { field.stringValue = displayText }
        if focusTick != coordinator.lastTick {
            coordinator.lastTick = focusTick
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class FocusField: NSTextField {
        var onFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?() }
            return ok
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        var lastTick = 0
        var editing = false

        init(_ parent: OmniboxField) { self.parent = parent }

        private var omnibox: Omnibox { parent.omnibox }

        func didFocus(_ field: NSTextField) {
            editing = true
            parent.isFocused = true
            field.stringValue = parent.displayText
            DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            editing = false
            parent.isFocused = false
            omnibox.close()
            (note.object as? NSTextField)?.stringValue = parent.displayText
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField, let editor = field.currentEditor() as? NSTextView else { return }
            omnibox.isPrivate = parent.isPrivate
            let text = editor.string
            let length = (text as NSString).length
            let selection = editor.selectedRange()
            // Only complete while typing forward at the end, never after a delete.
            let canComplete = !editor.hasMarkedText() && selection.location == length && selection.length == 0
                && text.count > omnibox.typed.count
            if let suffix = omnibox.update(typed: text, allowCompletion: canComplete), !suffix.isEmpty {
                editor.string = text + suffix
                editor.setSelectedRange(NSRange(location: length, length: (suffix as NSString).length))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                guard let text = omnibox.move(by: selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1) else { return false }
                textView.string = text
                let typedLength = (omnibox.typed as NSString).length
                if omnibox.highlighted == 0, omnibox.completion != nil {
                    textView.setSelectedRange(NSRange(location: typedLength, length: (text as NSString).length - typedLength))
                } else {
                    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard let url = omnibox.destination(for: textView.string) else { return true }
                omnibox.close()
                control.window?.makeFirstResponder(nil)
                parent.onCommit(url)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if omnibox.isOpen {
                    omnibox.close()
                    textView.string = parent.displayText
                    textView.selectAll(nil)
                } else {
                    control.window?.makeFirstResponder(nil)
                }
                return true
            default:
                return false
            }
        }
    }
}

// MARK: Dropdown

struct OmniboxAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct SuggestionList: View {
    @Environment(Omnibox.self) private var omnibox
    let onSelect: (Suggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(omnibox.suggestions.enumerated()), id: \.offset) { i, suggestion in
                SuggestionRow(suggestion: suggestion, highlighted: i == omnibox.highlighted) { onSelect(suggestion) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(Orbis.canvas))
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(Orbis.lineStrong))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let highlighted: Bool
    let action: () -> Void
    @State private var hover = false

    private var symbol: String {
        switch suggestion.kind {
        case .history: "clock"
        case .search: "magnifyingglass"
        case .address: "globe"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(highlighted ? Orbis.ink : Orbis.inkMute)
                    .frame(width: 16)
                Text(suggestion.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !suggestion.detail.isEmpty {
                    Text(suggestion.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Orbis.inkMute)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Orbis.radiusXS)
                .fill(highlighted ? Orbis.surfaceHover : hover ? Orbis.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
