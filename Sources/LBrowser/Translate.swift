import Observation
import SwiftUI
import Translation

/// Page translation with Apple's on-device Translation framework (macOS 15+).
@Observable @MainActor
final class PageTranslator {
    /// Drives `.translationTask`; a new value (or invalidate) starts a run.
    var configuration: TranslationSession.Configuration?
    private(set) var working: UUID?
    var error: String?

    @ObservationIgnored private weak var tab: BrowserTab?

    static var userLanguage: Locale.Language { Locale.current.language }

    /// True when the page declares a language other than the user's.
    static func isForeign(_ tab: BrowserTab?) -> Bool {
        guard let lang = tab?.pageLanguage else { return false }
        let page = Locale.Language(identifier: lang).languageCode
        return page != nil && page != userLanguage.languageCode
    }

    func isTranslated(_ tab: BrowserTab?) -> Bool { tab?.isTranslated ?? false }

    func translate(_ tab: BrowserTab) {
        self.tab = tab
        error = nil
        let source = tab.pageLanguage.map { Locale.Language(identifier: $0) }
        let config = TranslationSession.Configuration(source: source, target: Self.userLanguage)
        if configuration == config { configuration?.invalidate() } else { configuration = config }
    }

    func showOriginal(_ tab: BrowserTab) {
        tab.isTranslated = false
        Task { _ = await PageScripts.call("window.__lbRestoreOriginal && window.__lbRestoreOriginal(); return true", in: tab) }
    }

    /// Runs inside `.translationTask` with the session SwiftUI provides.
    func run(_ session: TranslationSession) async {
        guard let tab else { return }
        let page = tab.url
        working = tab.id
        defer { working = nil }
        guard let texts = await PageScripts.call("return window.__lbTextNodes ? window.__lbTextNodes() : []", in: tab) as? [String],
              !texts.isEmpty else { return }
        do {
            try await session.prepareTranslation()
            var output = Array(repeating: "", count: texts.count)
            // Batches keep the page updating progressively on long pages.
            for start in stride(from: 0, to: texts.count, by: 200) {
                let batch = texts[start..<min(start + 200, texts.count)].enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String(start + $0.offset))
                }
                for response in try await session.translations(from: batch) {
                    if let i = response.clientIdentifier.flatMap(Int.init) { output[i] = response.targetText }
                }
                _ = await PageScripts.call("return window.__lbApplyTranslations(texts)", in: tab, arguments: ["texts": output])
            }
            // The user may have navigated away while this ran.
            if tab.url == page { tab.isTranslated = true }
        } catch {
            self.error = "Couldn't translate this page: \(error.localizedDescription)"
        }
    }
}
