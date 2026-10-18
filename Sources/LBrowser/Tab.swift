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
    /// A page in this tab is playing sound.
    var isPlayingAudio = false
    var isMuted = false
    /// Camera or microphone is in use.
    var isCapturing = false
    /// The page looks like an article Reader can show.
    var readerAvailable = false
    var readerShown = false
    /// `<html lang>` of the page, for offering translation.
    var pageLanguage: String?
    /// The page currently shows a translation.
    var isTranslated = false

    let profileID: String
    @ObservationIgnored private let dataStore: WKWebsiteDataStore
    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored private(set) var existingWebView: WKWebView?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingState: Any?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    /// Frames (main page and iframes) with media, and those currently playing sound.
    @ObservationIgnored private var mediaFrames: [String: WKFrameInfo] = [:]
    @ObservationIgnored private var playingFrames: Set<String> = []
    /// Location answers for this page load, so a page asking repeatedly isn't re-prompted.
    @ObservationIgnored private var locationDecisions: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private let delegate = TabDelegate()

    @ObservationIgnored private static let owners = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    /// The tab showing a web view (for script messages, which only know the web view).
    static func owner(of webView: WKWebView?) -> BrowserTab? {
        webView.flatMap { owners.object(forKey: $0) }
    }

    init(url: URL?, title: String? = nil, dataStore: WKWebsiteDataStore? = nil, profileID: String = Profile.defaultID,
         interactionState: Any? = nil) {
        self.dataStore = dataStore ?? .default()
        self.profileID = profileID
        self.url = url
        self.pendingURL = url
        self.pendingState = interactionState
        self.title = title ?? url?.host() ?? "New Tab"
        delegate.tab = self
    }

    /// Popup tabs must use the configuration WebKit hands us.
    init(configuration: WKWebViewConfiguration, profileID: String = Profile.defaultID) {
        self.dataStore = configuration.websiteDataStore
        self.profileID = profileID
        self.title = "Loading…"
        delegate.tab = self
        attach(WKWebView(frame: .zero, configuration: configuration))
    }

    var isPrivate: Bool { !dataStore.isPersistent }

    var showsStartPage: Bool { url == nil && existingWebView == nil }

    /// Plain HTTP to another machine: shown as "Not Secure" in the address bar.
    var isInsecure: Bool {
        guard let url, url.scheme == "http", let host = url.host() else { return false }
        return !(["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost") || host.hasSuffix(".test"))
    }

    /// Web views are created lazily so restored tabs cost nothing until opened.
    var webView: WKWebView {
        existingWebView ?? attach(WKWebView(frame: .zero, configuration: WebEngine.shared.makeConfiguration(
            dataStore: dataStore, profileID: profileID)))
    }

    @discardableResult
    private func attach(_ web: WKWebView) -> WKWebView {
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.customUserAgent = WebEngine.userAgent
        web.isInspectable = WebEngine.shared.developerToolsEnabled
        existingWebView = web
        Self.owners.setObject(self, forKey: web)
        observers = [
            web.observe(\.title) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, let t = w.title, !t.isEmpty else { return }
                    self.title = t
                    if !self.isPrivate, let u = w.url { ProfileContext.for(self.profileID).history.updateTitle(t, for: u) }
                }
            },
            web.observe(\.url) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = w.url else { return }
                    if u != self.url { self.readerAvailable = false; self.readerShown = false }
                    self.url = u
                }
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
            web.observe(\.cameraCaptureState) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.updateCapture(w) }
            },
            web.observe(\.microphoneCaptureState) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.updateCapture(w) }
            },
        ]
        if let state = pendingState {
            pendingState = nil
            pendingURL = nil
            web.interactionState = state
        } else if let pendingURL {
            self.pendingURL = nil
            web.load(URLRequest(url: pendingURL))
        }
        return web
    }

    private func updateCapture(_ web: WKWebView) {
        isCapturing = web.cameraCaptureState == .active || web.microphoneCaptureState == .active
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

    // MARK: Page tools

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyMute(in: nil)
        for frame in mediaFrames.values where !frame.isMainFrame { applyMute(in: frame) }
    }

    /// Runs the mute script in one frame (nil = main frame); embedded players live in iframes.
    private func applyMute(in frame: WKFrameInfo?) {
        existingWebView?.evaluateJavaScript("window.__lbSetMuted && window.__lbSetMuted(\(isMuted))", in: frame, in: PageScripts.world)
    }

    /// A frame's page script reports whether it is playing sound.
    func mediaReport(playing: Bool, frame: WKFrameInfo) {
        let key = frame.isMainFrame ? "main"
            : "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host):\(frame.securityOrigin.port)|\(frame.request.url?.absoluteString ?? "")"
        mediaFrames[key] = frame
        if playing {
            playingFrames.insert(key)
            if isMuted, !frame.isMainFrame { applyMute(in: frame) }
        } else {
            playingFrames.remove(key)
        }
        if isPlayingAudio != !playingFrames.isEmpty { isPlayingAudio = !playingFrames.isEmpty }
    }

    /// A new page replaced the old one: forget its frames and translation.
    func mainFrameCommitted() {
        locationDecisions = [:]
        mediaFrames = [:]
        playingFrames = []
        if isPlayingAudio { isPlayingAudio = false }
        if isTranslated { isTranslated = false }
    }

    /// Whether `host` may get the location: the site's saved choice, or the user's answer for this page load.
    func locationAllowed(for host: String, window: NSWindow?) async -> Bool {
        let key = host.lowercased()
        if let pending = locationDecisions[key] { return await pending.value }
        let permissions = ProfileContext.for(profileID).permissions
        let decision = Task { await permissions.decideLocation(host: host, window: window) }
        locationDecisions[key] = decision
        return await decision.value
    }

    /// Re-applies the mute state after a navigation.
    func pageDidLoad() {
        if isMuted { setMuted(true) }
        Task { await PageScripts.inspect(self) }
    }

    func pictureInPicture() {
        existingWebView?.evaluateJavaScript("window.__lbPictureInPicture && window.__lbPictureInPicture()", in: nil, in: PageScripts.world)
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
            Self.owners.removeObject(forKey: web)
        }
        existingWebView = nil
    }
}

@MainActor
final class TabDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var tab: BrowserTab?
    private var downloads: [ObjectIdentifier: URL] = [:]
    /// Temporary files for downloads that replace an existing file.
    private var replacements: [ObjectIdentifier: URL] = [:]

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.allow, preferences) }
        let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
        if let scheme = url.scheme?.lowercased(), !webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url) // mailto:, zoommtg:, etc.
            return (.cancel, preferences)
        }
        if action.shouldPerformDownload { return (.download, preferences) }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), let tab {
            tab.store?.openInBackground(url, from: tab)
            return (.cancel, preferences)
        }
        if action.targetFrame?.isMainFrame ?? true, let host = url.host(), let tab {
            preferences.allowsContentJavaScript = ProfileContext.for(tab.profileID).permissions.setting(.javascript, for: host) != .deny
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        if disposition?.lowercased().hasPrefix("attachment") == true { return .download }
        if response.isForMainFrame && !response.canShowMIMEType { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        DownloadManager.shared.started(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        DownloadManager.shared.started(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.mainFrameCommitted()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab, !tab.isPrivate, let url = webView.url {
            ProfileContext.for(tab.profileID).history.recordVisit(url, title: webView.title)
        }
        tab?.refreshFavicon()
        tab?.pageDidLoad()
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

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let tab else { return .deny }
        return await ProfileContext.for(tab.profileID).permissions.decideMediaCapture(host: origin.host, type: type, window: webView.window)
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
        if DownloadSettings.askWhereToSave {
            guard let chosen = await PageActions.savePanel(name: suggestedFilename, type: nil, window: tab?.existingWebView?.window) else {
                download.cancel(nil)
                return nil
            }
            downloads[ObjectIdentifier(download)] = chosen
            DownloadManager.shared.setDestination(chosen, for: download)
            guard FileManager.default.fileExists(atPath: chosen.path) else { return chosen }
            // Replacing a file: download next to it and swap only once the download succeeded,
            // so a failed download doesn't cost the user the old file.
            let temp = chosen.deletingLastPathComponent().appending(path: ".\(chosen.lastPathComponent).\(UUID().uuidString).download")
            replacements[ObjectIdentifier(download)] = temp
            return temp
        }
        let dir = DownloadSettings.folder
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var dest = dir.appending(path: suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appending(path: ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        downloads[ObjectIdentifier(download)] = dest
        DownloadManager.shared.setDestination(dest, for: download)
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let temp = replacements.removeValue(forKey: ObjectIdentifier(download)), let target = downloads[ObjectIdentifier(download)] {
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                DownloadManager.shared.failed(download, error: error)
                downloads.removeValue(forKey: ObjectIdentifier(download))
                return
            }
        }
        DownloadManager.shared.finished(download)
        guard let dest = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Bounces the Downloads stack in the Dock, like Safari.
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.DownloadFileFinished"), object: dest.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DownloadManager.shared.failed(download, error: error)
        downloads.removeValue(forKey: ObjectIdentifier(download))
        if let temp = replacements.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: temp) }
    }
}
