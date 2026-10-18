import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit

/// Web extensions (Safari/Chrome/Firefox WebExtension format, unpacked folder or .zip), per profile.
/// Uses WebKit's WKWebExtension support, available on macOS 15.4 and later.
@Observable @MainActor
final class Extensions {
    static let shared = Extensions()

    struct Record: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var profileID: String
        var enabled = true
    }

    private(set) var records: [Record] = []
    /// Bumped when an extension's toolbar button changes (icon, badge, enabled).
    private(set) var actionTick = 0
    var lastError: String?

    @ObservationIgnored private var controllers: [String: AnyObject] = [:]
    @ObservationIgnored private var contexts: [String: AnyObject] = [:]
    @ObservationIgnored private var delegate: AnyObject?
    @ObservationIgnored private var started = false

    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    private var listURL: URL { AppPaths.root.appending(path: "extensions.json") }
    private func folder(for id: String) -> URL { AppPaths.root.appending(path: "Extensions/\(id)", directoryHint: .isDirectory) }

    init() {
        if let data = try? Data(contentsOf: listURL), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
    }

    func records(for profileID: String) -> [Record] { records.filter { $0.profileID == profileID } }

    /// Gives new web views of a profile its extension controller (loading extensions the first time).
    func attach(to config: WKWebViewConfiguration, profileID: String) {
        guard #available(macOS 15.4, *) else { return }
        config.webExtensionController = controller(for: profileID)
    }

    @available(macOS 15.4, *)
    private func controller(for profileID: String) -> WKWebExtensionController {
        if let existing = controllers[profileID] as? WKWebExtensionController { return existing }
        let identifier = UUID(uuidString: profileID) ?? UUID(uuidString: "6C2B9C1E-2F0B-4E8E-9B1A-4C0F5B0D0001")!
        let controller = WKWebExtensionController(configuration: .init(identifier: identifier))
        let delegate = (self.delegate as? Delegate) ?? Delegate()
        self.delegate = delegate
        controller.delegate = delegate
        controllers[profileID] = controller
        for record in records(for: profileID) where record.enabled {
            Task { await load(record, into: controller) }
        }
        return controller
    }

    @available(macOS 15.4, *)
    private func load(_ record: Record, into controller: WKWebExtensionController) async {
        do {
            let ext = try await WKWebExtension(resourceBaseURL: folder(for: record.id))
            let context = WKWebExtensionContext(for: ext)
            context.uniqueIdentifier = record.id
            context.isInspectable = WebEngine.shared.developerToolsEnabled
            for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            contexts[record.id] = context
            actionTick += 1
        } catch {
            lastError = "\(record.name): \(error.localizedDescription)"
        }
    }

    /// Asks for a folder or .zip, shows what the extension wants, and installs it into the profile.
    func installInteractively(profileID: String) {
        guard #available(macOS 15.4, *) else {
            lastError = "Extensions need macOS 15.4 or later."
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Choose an unpacked web extension folder (with manifest.json) or a .zip"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task { await install(from: source, profileID: profileID) }
    }

    @available(macOS 15.4, *)
    private func install(from source: URL, profileID: String) async {
        let id = UUID().uuidString
        let target = folder(for: id)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if source.pathExtension.lowercased() == "zip" {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", source.path, target.path]
                try unzip.run()
                unzip.waitUntilExit()
                // Archives often wrap everything in one folder.
                let items = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
                if !FileManager.default.fileExists(atPath: target.appending(path: "manifest.json").path),
                   items.count == 1, FileManager.default.fileExists(atPath: items[0].appending(path: "manifest.json").path) {
                    let inner = items[0]
                    for item in try FileManager.default.contentsOfDirectory(at: inner, includingPropertiesForKeys: nil) {
                        try FileManager.default.moveItem(at: item, to: target.appending(path: item.lastPathComponent))
                    }
                    try FileManager.default.removeItem(at: inner)
                }
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
            let ext = try await WKWebExtension(resourceBaseURL: target)
            let name = ext.displayName ?? source.deletingPathExtension().lastPathComponent

            let alert = NSAlert()
            alert.messageText = "Add “\(name)” to \(ProfileManager.shared.profile(profileID).name)?"
            var info = ext.displayDescription.map { $0 + "\n\n" } ?? ""
            let hosts = ext.allRequestedMatchPatterns.map(\.string).sorted()
            let permissions = ext.requestedPermissions.map(\.rawValue).sorted()
            if !permissions.isEmpty { info += "Permissions: " + permissions.joined(separator: ", ") + "\n" }
            if !hosts.isEmpty { info += "Can read and change: " + (hosts.count > 6 ? hosts.prefix(6).joined(separator: ", ") + " and more" : hosts.joined(separator: ", ")) }
            alert.informativeText = info
            alert.addButton(withTitle: "Add Extension")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                try? FileManager.default.removeItem(at: target)
                return
            }
            let record = Record(id: id, name: name, profileID: profileID)
            records.append(record)
            saveRecords()
            await load(record, into: controller(for: profileID))
        } catch {
            try? FileManager.default.removeItem(at: target)
            lastError = "Couldn't add the extension: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ record: Record, _ enabled: Bool) {
        guard let i = records.firstIndex(of: record) else { return }
        records[i].enabled = enabled
        saveRecords()
        guard #available(macOS 15.4, *) else { return }
        let controller = controller(for: record.profileID)
        if enabled {
            let current = records[i]
            if contexts[record.id] == nil { Task { await load(current, into: controller) } }
        } else if let context = contexts.removeValue(forKey: record.id) as? WKWebExtensionContext {
            try? controller.unload(context)
            actionTick += 1
        }
    }

    /// Removes every extension of a profile that is being deleted.
    func removeAll(profileID: String) {
        records(for: profileID).forEach(remove)
        controllers[profileID] = nil
    }

    func remove(_ record: Record) {
        setEnabled(record, false)
        records.removeAll { $0.id == record.id }
        saveRecords()
        try? FileManager.default.removeItem(at: folder(for: record.id))
    }

    func openOptions(_ record: Record) {
        guard #available(macOS 15.4, *), let context = contexts[record.id] as? WKWebExtensionContext,
              let url = context.optionsPageURL, let config = context.webViewConfiguration,
              let store = WindowManager.shared.activeStore else { return }
        store.openTab(url, configuration: config)
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: listURL, options: .atomic) }
    }

    // MARK: Toolbar

    struct ActionItem: Identifiable {
        let id: String
        let label: String
        let icon: NSImage?
        let badge: String
    }

    /// Last toolbar items, reused until the tab or an extension's button changes (the toolbar re-renders often).
    @ObservationIgnored private var cachedActions: (key: String, items: [ActionItem])?

    func actionItems(for tab: BrowserTab?) -> [ActionItem] {
        let tick = actionTick
        guard #available(macOS 15.4, *), let tab else { return [] }
        let key = "\(tab.id)-\(tick)-\(records.count)"
        if let cachedActions, cachedActions.key == key { return cachedActions.items }
        let items: [ActionItem] = records(for: tab.profileID).compactMap { record in
            guard let context = contexts[record.id] as? WKWebExtensionContext,
                  let action = context.action(for: TabAdapter.for(tab)) else { return nil }
            return ActionItem(id: record.id, label: action.label.isEmpty ? record.name : action.label,
                              icon: action.icon(for: CGSize(width: 16, height: 16)), badge: action.badgeText)
        }
        cachedActions = (key, items)
        return items
    }

    @ObservationIgnored var popoverAnchor: (window: NSWindow, rect: CGRect)?

    func performAction(_ id: String, tab: BrowserTab, anchor: (NSWindow, CGRect)?) {
        guard #available(macOS 15.4, *), let context = contexts[id] as? WKWebExtensionContext else { return }
        popoverAnchor = anchor
        context.performAction(for: TabAdapter.for(tab))
    }

    fileprivate func refreshActions() { actionTick += 1 }

    // MARK: Tab events

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        guard #available(macOS 15.4, *), let controller = controllers[tab.profileID] as? WKWebExtensionController else { return }
        controller.didActivateTab(TabAdapter.for(tab), previousActiveTab: previous.map { TabAdapter.for($0) })
        actionTick += 1
    }

    func tabOpened(_ tab: BrowserTab) {
        guard #available(macOS 15.4, *), let controller = controllers[tab.profileID] as? WKWebExtensionController else { return }
        controller.didOpenTab(TabAdapter.for(tab))
    }

    func tabClosed(_ tab: BrowserTab) {
        guard #available(macOS 15.4, *), let controller = controllers[tab.profileID] as? WKWebExtensionController else { return }
        controller.didCloseTab(TabAdapter.for(tab), windowIsClosing: false)
        TabAdapter.forget(tab)
    }

    func tabChanged(_ tab: BrowserTab) {
        guard #available(macOS 15.4, *), let controller = controllers[tab.profileID] as? WKWebExtensionController else { return }
        controller.didChangeTabProperties([.URL, .title, .loading], for: TabAdapter.for(tab))
    }

    // MARK: Delegate

    @available(macOS 15.4, *)
    @MainActor
    final class Delegate: NSObject, WKWebExtensionControllerDelegate {
        func webExtensionController(_ controller: WKWebExtensionController,
                                    openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
            WindowManager.shared.openStores
                .filter { $0.profile.id == Extensions.shared.profileID(of: controller) }
                .map { WindowAdapter.for($0) }
        }

        func webExtensionController(_ controller: WKWebExtensionController,
                                    focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
            guard let store = WindowManager.shared.activeStore, store.profile.id == Extensions.shared.profileID(of: controller) else { return nil }
            return WindowAdapter.for(store)
        }

        func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                    for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
            guard let store = WindowManager.shared.activeStore else { return completionHandler(nil, nil) }
            let tab = store.newTab(configuration.url, select: configuration.shouldBeActive)
            completionHandler(TabAdapter.for(tab), nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping ((any Error)?) -> Void) {
            if let record = Extensions.shared.records.first(where: { $0.id == extensionContext.uniqueIdentifier }) {
                Extensions.shared.openOptions(record)
            }
            completionHandler(nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                    in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
            let alert = NSAlert()
            alert.messageText = "“\(extensionContext.webExtension.displayName ?? "An extension")” wants more access"
            alert.informativeText = permissions.map(\.rawValue).sorted().joined(separator: ", ")
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? permissions : [], nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                    in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping (Set<URL>, Date?) -> Void) {
            let allowed = Extensions.askForAccess(extensionContext, to: urls.compactMap { $0.host() }.sorted())
            completionHandler(allowed ? urls : [], nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                    in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
            let allowed = Extensions.askForAccess(extensionContext, to: matchPatterns.map(\.string).sorted())
            completionHandler(allowed ? matchPatterns : [], nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                    forExtensionContext context: WKWebExtensionContext) {
            Extensions.shared.refreshActions()
        }

        func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                    for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
            guard let popover = action.popupPopover,
                  let (window, rect) = Extensions.shared.popoverAnchor ?? NSApp.keyWindow.map({ ($0, CGRect(x: $0.frame.width - 60, y: 40, width: 1, height: 1)) }),
                  let view = window.contentView else { return completionHandler(nil) }
            let target = view.isFlipped ? rect : CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
            popover.show(relativeTo: target, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
            completionHandler(nil)
        }
    }

    /// Asks before an extension gets to read and change more websites at runtime.
    @available(macOS 15.4, *)
    fileprivate static func askForAccess(_ context: WKWebExtensionContext, to sites: [String]) -> Bool {
        guard !sites.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = "Allow “\(context.webExtension.displayName ?? "An extension")” to read and change these websites?"
        alert.informativeText = sites.count > 8 ? sites.prefix(8).joined(separator: ", ") + " and \(sites.count - 8) more" : sites.joined(separator: ", ")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    fileprivate func profileID(of controller: AnyObject) -> String? {
        controllers.first { $0.value === controller }?.key
    }
}

// MARK: Adapters between LBrowser's tabs/windows and WebKit's extension protocols

@available(macOS 15.4, *)
@MainActor
final class TabAdapter: NSObject, WKWebExtensionTab {
    weak var tab: BrowserTab?
    private static var cache: [UUID: TabAdapter] = [:]

    static func `for`(_ tab: BrowserTab) -> TabAdapter {
        if let cached = cache[tab.id] { return cached }
        let adapter = TabAdapter()
        adapter.tab = tab
        cache[tab.id] = adapter
        return adapter
    }

    static func forget(_ tab: BrowserTab) { cache[tab.id] = nil }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        tab?.store.map { WindowAdapter.for($0) }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let store = tab.store else { return 0 }
        return store.orderedTabs.firstIndex { $0 === tab } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.existingWebView }
    func title(for context: WKWebExtensionContext) -> String? { tab?.title }
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab.flatMap { t in t.store?.isPinned(t) } ?? false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.isPlayingAudio ?? false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.isMuted ?? false }
    func isSelected(for context: WKWebExtensionContext) -> Bool { tab.map { $0.store?.selectedID == $0.id } ?? false }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }
    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { tab?.readerAvailable ?? false }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { tab?.readerShown ?? false }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.setMuted(muted)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { tab?.existingWebView?.reloadFromOrigin() } else { tab?.existingWebView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.existingWebView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.existingWebView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { tab.store?.select(tab) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { tab.store?.close(tab) }
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab, let store = tab.store { if pinned { store.pin(tab) } else { store.unpin(tab) } }
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class WindowAdapter: NSObject, WKWebExtensionWindow {
    weak var store: BrowserStore?
    private static var cache: [String: WindowAdapter] = [:]

    static func `for`(_ store: BrowserStore) -> WindowAdapter {
        if let cached = cache[store.windowID], cached.store === store { return cached }
        let adapter = WindowAdapter()
        adapter.store = store
        cache[store.windowID] = adapter
        return adapter
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        (store?.orderedTabs ?? []).map { TabAdapter.for($0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        store?.selected.map { TabAdapter.for($0) }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { store?.isPrivate ?? false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        store.flatMap { WindowManager.shared.window(for: $0)?.frame } ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        store.flatMap { WindowManager.shared.window(for: $0) }?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        store.flatMap { WindowManager.shared.window(for: $0) }?.performClose(nil)
        completionHandler(nil)
    }
}
