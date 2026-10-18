import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: Print, PDF, save, copy link

@MainActor
enum PageActions {
    static func print(_ tab: BrowserTab?) {
        guard let web = tab?.existingWebView, let window = web.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        let operation = web.printOperation(with: info)
        operation.view?.frame = web.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    static func exportPDF(_ tab: BrowserTab?) {
        guard let tab, let web = tab.existingWebView else { return }
        Task {
            guard let data = try? await web.pdf(configuration: WKPDFConfiguration()),
                  let url = await savePanel(name: fileName(tab, ext: "pdf"), type: .pdf, window: web.window) else { return }
            try? data.write(to: url)
        }
    }

    /// Saves the page with its images and styles as a Safari web archive.
    static func savePage(_ tab: BrowserTab?) {
        guard let tab, let web = tab.existingWebView else { return }
        Task {
            let data: Data? = await withCheckedContinuation { done in
                web.createWebArchiveData { done.resume(returning: try? $0.get()) }
            }
            guard let data, let url = await savePanel(name: fileName(tab, ext: "webarchive"),
                                                       type: UTType("com.apple.webarchive") ?? .data, window: web.window) else { return }
            try? data.write(to: url)
        }
    }

    static func copyLink(_ tab: BrowserTab?) {
        guard let url = tab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private static func fileName(_ tab: BrowserTab, ext: String) -> String {
        let base = tab.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(base.isEmpty ? "Page" : String(base.prefix(80))).\(ext)"
    }

    /// Save panel shown as a sheet on the window when there is one.
    static func savePanel(name: String, type: UTType?, window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let type { panel.allowedContentTypes = [type] }
        panel.directoryURL = DownloadSettings.folder
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        return response == .OK ? panel.url : nil
    }
}

// MARK: Find on page

struct FindBar: View {
    @Environment(BrowserStore.self) private var store
    @Binding var shown: Bool
    @State private var query = ""
    @State private var matches: Int?
    @State private var current = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Orbis.inkWhisper)
            TextField("Find on page", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 200)
                .focused($focused)
                .onSubmit { Task { await find(backwards: NSEvent.modifierFlags.contains(.shift)) } }
                .onChange(of: query) { current = 0; Task { await find(backwards: false, restart: true) } }
            if let matches, !query.isEmpty {
                Text(matches == 0 ? "Not found" : "\(min(current, matches)) of \(matches)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(matches == 0 ? Orbis.negative : Orbis.inkMute)
                    .fixedSize()
            }
            IconButton(symbol: "chevron.up", help: "Previous (⇧⌘G)", disabled: (matches ?? 0) == 0) { Task { await find(backwards: true) } }
            IconButton(symbol: "chevron.down", help: "Next (⌘G)", disabled: (matches ?? 0) == 0) { Task { await find(backwards: false) } }
            IconButton(symbol: "xmark", help: "Done (Esc)") { close() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(Orbis.canvas))
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(Orbis.lineStrong))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .onAppear { focused = true }
        .onChange(of: store.findTick) { focused = true }
        .onChange(of: store.findNextTick) { Task { await find(backwards: store.findBackwards) } }
        .onExitCommand { close() }
    }

    private func close() {
        shown = false
        guard let web = store.selected?.existingWebView else { return }
        // Drop the highlighted match WebKit leaves selected.
        web.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", in: nil, in: PageScripts.world)
        web.window?.makeFirstResponder(web)
    }

    private func find(backwards: Bool, restart: Bool = false) async {
        guard let web = store.selected?.existingWebView else { return }
        guard !query.isEmpty else { matches = nil; return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        let found = (try? await web.find(query, configuration: config))?.matchFound ?? false
        let count = (try? await web.callAsyncJavaScript(
            "const t = (document.body && document.body.innerText || '').toLowerCase(); const q = needle.toLowerCase(); let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1) { n++; i += q.length; } return n;",
            arguments: ["needle": query], in: nil, contentWorld: PageScripts.world) as? Int) ?? (found ? 1 : 0)
        matches = found ? max(count, 1) : 0
        guard let matches, matches > 0 else { return }
        if restart { current = 1 } else { current = backwards ? (current <= 1 ? matches : current - 1) : (current >= matches ? 1 : current + 1) }
    }
}

// MARK: Reader

struct ReaderView: View {
    let tab: BrowserTab
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerSerif") private var serif = true
    @State private var html: String?

    var body: some View {
        ZStack(alignment: .top) {
            Orbis.canvas
            if let html {
                ReaderWebView(html: html) { tab.readerShown = false; tab.load($0) }
            } else {
                ProgressView().controlSize(.small).padding(.top, 80)
            }
            HStack(spacing: 6) {
                Text("Reader").eyebrow()
                Spacer()
                IconButton(symbol: "textformat.size.smaller", help: "Smaller text") { fontSize = max(13, fontSize - 1); reload() }
                IconButton(symbol: "textformat.size.larger", help: "Larger text") { fontSize = min(32, fontSize + 1); reload() }
                IconButton(symbol: serif ? "character.book.closed" : "textformat", help: serif ? "Sans-serif" : "Serif") { serif.toggle(); reload() }
                IconButton(symbol: "xmark", help: "Close Reader (⇧⌘R)", bordered: true) { tab.readerShown = false }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Orbis.canvas.opacity(0.94))
            .hairline(.bottom)
        }
        .task(id: tab.id) { await load() }
    }

    private func reload() { Task { await load() } }

    private func load() async {
        guard let article = await PageScripts.call("return window.__lbReader ? window.__lbReader() : null", in: tab) as? [String: Any] else {
            tab.readerShown = false
            return
        }
        html = Self.page(article, fontSize: fontSize, serif: serif)
    }

    static func page(_ a: [String: Any], fontSize: Double, serif: Bool) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let title = esc(a["title"] as? String ?? "")
        let byline = esc([a["byline"] as? String, a["site"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        let font = serif ? "'New York', 'Iowan Old Style', Georgia, serif" : "-apple-system, 'Helvetica Neue', sans-serif"
        return """
        <!doctype html><html lang="\(esc(a["lang"] as? String ?? ""))"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; --ink: #0A0A0B; --mute: rgba(10,10,11,.55); --bg: #FEFEFE; --line: rgba(0,0,0,.1); --accent: #D4860A; }
        @media (prefers-color-scheme: dark) { :root { --ink: #F0F0F0; --mute: rgba(240,240,240,.55); --bg: #0A0A0B; --line: rgba(255,255,255,.12); --accent: #F0A22A; } }
        body { background: var(--bg); color: var(--ink); font: \(fontSize)px/1.65 \(font); margin: 0; padding: 84px 24px 120px; }
        main { max-width: 680px; margin: 0 auto; }
        h1 { font: 600 \(fontSize * 1.75)px/1.2 -apple-system, sans-serif; letter-spacing: -0.01em; margin: 0 0 12px; }
        .by { color: var(--mute); font: 13px -apple-system, sans-serif; text-transform: uppercase; letter-spacing: .08em; padding-bottom: 24px; border-bottom: 1px solid var(--line); margin-bottom: 28px; }
        img { max-width: 100%; height: auto; border-radius: 4px; }
        a { color: var(--ink); text-decoration-color: var(--accent); text-underline-offset: 3px; }
        blockquote { border-left: 2px solid var(--accent); margin: 1.4em 0; padding-left: 1em; color: var(--mute); }
        pre, code { font: 0.85em ui-monospace, Menlo, monospace; }
        pre { overflow-x: auto; padding: 12px; border: 1px solid var(--line); border-radius: 4px; }
        figcaption { color: var(--mute); font-size: .8em; }
        h2, h3 { font-family: -apple-system, sans-serif; line-height: 1.3; }
        table { border-collapse: collapse; } td, th { border: 1px solid var(--line); padding: 4px 8px; }
        </style></head><body><main><h1>\(title)</h1><div class="by">\(byline)</div>\(a["html"] as? String ?? "")</main></body></html>
        """
    }
}

/// Reader's own sandboxed web view: no JavaScript, no website data; links open in the tab.
private struct ReaderWebView: NSViewRepresentable {
    let html: String
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.openLink = openLink
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var openLink: (URL) -> Void
        var loaded: String?
        init(openLink: @escaping (URL) -> Void) { self.openLink = openLink }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme?.hasPrefix("http") == true {
                await MainActor.run { openLink(url) }
                return .cancel
            }
            return .allow
        }
    }
}

// MARK: Tab search

struct TabSearchPalette: View {
    @Environment(BrowserStore.self) private var store
    @State private var query = ""
    @State private var highlighted = 0
    @State private var keyMonitor: Any?
    @State private var rowCount = 0
    @FocusState private var focused: Bool

    private var results: [(tab: BrowserTab, place: String)] {
        let all = store.pinnedTabs.map { ($0, "Pinned") }
            + store.groups.flatMap { g in g.tabs.map { ($0, g.name) } }
            + store.looseTabs.map { ($0, store.isPrivate ? "Private" : "Tabs") }
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return all }
        return all.filter { tab, _ in
            let hay = (tab.title + " " + (tab.url?.absoluteString ?? "")).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        let rows = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Orbis.inkWhisper)
                TextField("Search tabs", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { open(rows) }
                    .onChange(of: query) { highlighted = 0 }
                Text("\(rows.count)").eyebrow()
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .hairline(.bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.tab.id) { i, row in
                            HStack(spacing: 10) {
                                Favicon(tab: row.tab)
                                Text(row.tab.title).font(.system(size: 12.5)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(row.place).eyebrow(size: 8).lineLimit(1)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(i == highlighted ? Orbis.surfaceHover : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { store.select(row.tab); store.tabSearchShown = false }
                            .id(i)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(rows.count) * 34 + 8, 380))
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
        }
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusMD).fill(Orbis.canvas))
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusMD).strokeBorder(Orbis.lineStrong))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear {
            focused = true
            rowCount = rows.count
            // The text field's editor swallows ↑/↓, so catch them before it does.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 125: highlighted = min(highlighted + 1, max(rowCount - 1, 0)); return nil
                case 126: highlighted = max(highlighted - 1, 0); return nil
                default: return event
                }
            }
        }
        .onChange(of: rows.count) { rowCount = rows.count }
        .onDisappear { keyMonitor.map(NSEvent.removeMonitor); keyMonitor = nil }
        .onExitCommand { store.tabSearchShown = false }
    }

    private func open(_ rows: [(tab: BrowserTab, place: String)]) {
        guard rows.indices.contains(highlighted) else { return }
        store.select(rows[highlighted].tab)
        store.tabSearchShown = false
    }
}
