import AppKit
import Observation
import WebKit

@Observable @MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    var title: String
    var url: URL?
    var faviconURL: URL?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false

    @ObservationIgnored private let dataStore: WKWebsiteDataStore
    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored private(set) var existingWebView: WKWebView?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private let delegate = TabDelegate()

    init(url: URL?, title: String? = nil, dataStore: WKWebsiteDataStore? = nil) {
        self.dataStore = dataStore ?? .default()
        self.url = url
        self.pendingURL = url
        self.title = title ?? url?.host() ?? "New Tab"
        delegate.tab = self
    }

    /// Popup tabs must use the configuration WebKit hands us.
    init(configuration: WKWebViewConfiguration) {
        self.dataStore = configuration.websiteDataStore
        self.title = "Loading…"
        delegate.tab = self
        attach(WKWebView(frame: .zero, configuration: configuration))
    }

    var isPrivate: Bool { !dataStore.isPersistent }

    var showsStartPage: Bool { url == nil && existingWebView == nil }

    /// Web views are created lazily so restored tabs cost nothing until opened.
    var webView: WKWebView {
        existingWebView ?? attach(WKWebView(frame: .zero, configuration: WebEngine.shared.makeConfiguration(dataStore: dataStore)))
    }

    @discardableResult
    private func attach(_ web: WKWebView) -> WKWebView {
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.customUserAgent = WebEngine.userAgent
        existingWebView = web
        observers = [
            web.observe(\.title) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, let t = w.title, !t.isEmpty else { return }
                    self.title = t
                }
            },
            web.observe(\.url) { [weak self] w, _ in
                MainActor.assumeIsolated { if let u = w.url { self?.url = u } }
            },
            web.observe(\.isLoading) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.isLoading = w.isLoading }
            },
            web.observe(\.estimatedProgress) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.progress = w.estimatedProgress }
            },
            web.observe(\.canGoBack) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoBack = w.canGoBack }
            },
            web.observe(\.canGoForward) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoForward = w.canGoForward }
            },
        ]
        if let pendingURL {
            self.pendingURL = nil
            web.load(URLRequest(url: pendingURL))
        }
        return web
    }

    func load(_ target: URL) {
        url = target
        if let existingWebView {
            existingWebView.load(URLRequest(url: target))
        } else {
            pendingURL = target
            _ = webView
        }
    }

    func refreshFavicon() {
        let js = "(document.querySelector('link[rel~=\"icon\"]') || {}).href || (location.origin + '/favicon.ico')"
        existingWebView?.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                if let s = result as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
                    self?.faviconURL = u
                }
            }
        }
    }

    func teardown() {
        observers.forEach { $0.invalidate() }
        observers = []
        if let web = existingWebView {
            web.stopLoading()
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.removeFromSuperview()
            web.navigationDelegate = nil
            web.uiDelegate = nil
        }
        existingWebView = nil
    }
}

@MainActor
final class TabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var tab: BrowserTab?
    private var downloads: [ObjectIdentifier: URL] = [:]

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
        if let scheme = url.scheme?.lowercased(), !webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url) // mailto:, zoommtg:, etc.
            return .cancel
        }
        if action.shouldPerformDownload { return .download }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), let tab {
            tab.store?.openInBackground(url, from: tab)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        if disposition?.lowercased().hasPrefix("attachment") == true { return .download }
        if response.isForMainFrame && !response.canShowMIMEType { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.refreshFavicon()
        tab?.store?.scheduleSave()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: UI

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let tab, let store = tab.store else { return nil }
        return store.openPopup(configuration: configuration, from: tab)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab { tab.store?.close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var dest = dir.appending(path: suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appending(path: ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        downloads[ObjectIdentifier(download)] = dest
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Bounces the Downloads stack in the Dock, like Safari.
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.DownloadFileFinished"), object: dest.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }
}
