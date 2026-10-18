import AppKit
import Observation
import SwiftUI

/// Keeps track of browser windows: which are open, which profile each belongs to,
/// and which should come back after a relaunch.
@Observable @MainActor
final class WindowManager {
    static let shared = WindowManager()
    nonisolated static let mainWindowID = "main"

    struct Entry: Codable, Hashable {
        var id: String
        var profileID: String
    }

    /// Windows to restore on launch, in order.
    private(set) var entries: [Entry] = []
    private(set) var openStores: [BrowserStore] = []
    /// The store of the key window (where menu commands and opened links go).
    private(set) weak var activeStore: BrowserStore?

    @ObservationIgnored var isTerminating = false
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var windows: [String: NSWindow] = [:]
    @ObservationIgnored private var pendingTabs: [String: [BrowserTab]] = [:]
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var pendingWindowURLs: [String: URL] = [:]
    @ObservationIgnored private var launchHandled = false

    private var manifestURL: URL { AppPaths.root.appending(path: "windows.json") }

    init() {
        if let data = try? Data(contentsOf: manifestURL), let saved = try? JSONDecoder().decode([Entry].self, from: data), !saved.isEmpty {
            entries = saved
        } else {
            entries = [Entry(id: Self.mainWindowID, profileID: Profile.defaultID)]
        }
    }

    static func sessionURL(for windowID: String) -> URL {
        if windowID == mainWindowID { return AppPaths.root.appending(path: "session.json") }
        let dir = AppPaths.root.appending(path: "Windows", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(windowID).json")
    }

    // MARK: Opening

    /// The id for a window SwiftUI opened without one (at launch or from the Dock): the first saved window not yet open.
    func claimWindowID() -> String {
        let open = Set(openStores.map(\.windowID))
        if let entry = entries.first(where: { !open.contains($0.id) }) { return entry.id }
        let entry = Entry(id: open.contains(Self.mainWindowID) ? UUID().uuidString : Self.mainWindowID, profileID: Profile.defaultID)
        entries.append(entry)
        saveManifest()
        return entry.id
    }

    func store(for windowID: String) -> BrowserStore {
        if let existing = openStores.first(where: { $0.windowID == windowID }) { return existing }
        let entry = entries.first { $0.id == windowID } ?? {
            let e = Entry(id: windowID, profileID: Profile.defaultID)
            entries.append(e)
            saveManifest()
            return e
        }()
        let store = BrowserStore(profile: .for(entry.profileID), windowID: windowID)
        openStores.append(store)
        if activeStore == nil { activeStore = store }
        return store
    }

    /// Called once a window's store has restored its tabs.
    func storeReady(_ store: BrowserStore) {
        for tab in pendingTabs.removeValue(forKey: store.windowID) ?? [] { store.adopt(tab) }
        if let url = pendingWindowURLs.removeValue(forKey: store.windowID) { store.load(url) }
        if store === activeStore || activeStore == nil {
            pendingURLs.forEach { store.openExternal($0) }
            pendingURLs = []
        }
        // At launch, bring back the other saved windows.
        if !launchHandled {
            launchHandled = true
            let open = Set(openStores.map(\.windowID))
            for entry in entries where !open.contains(entry.id) { openWindowAction?(id: "browser", value: entry.id) }
        }
    }

    @discardableResult
    func newWindow(profileID: String? = nil, with tab: BrowserTab? = nil, url: URL? = nil) -> String {
        let profile = profileID ?? activeStore?.profile.id ?? Profile.defaultID
        let entry = Entry(id: UUID().uuidString, profileID: profile)
        entries.append(entry)
        saveManifest()
        if let tab { pendingTabs[entry.id] = [tab] }
        if let url { pendingWindowURLs[entry.id] = url }
        openWindowAction?(id: "browser", value: entry.id)
        return entry.id
    }

    /// Private tabs can't move: the new window isn't private and would save them to disk.
    func canMoveToNewWindow(_ tab: BrowserTab) -> Bool { !tab.isPrivate && tab.store != nil }

    func moveToNewWindow(_ tab: BrowserTab) {
        guard canMoveToNewWindow(tab), let store = tab.store else { return }
        store.release(tab)
        newWindow(profileID: store.profile.id, with: tab)
    }

    func openExternal(_ url: URL) {
        if let store = activeStore, store.isReady { return store.openExternal(url) }
        pendingURLs.append(url)
        // With every window closed, bring one back to show the link (it picks the URL up in storeReady).
        if launchHandled, openStores.isEmpty { openWindowAction?(id: "browser", value: claimWindowID()) }
    }

    // MARK: Window lifecycle

    func register(_ window: NSWindow, for store: BrowserStore) {
        windows[store.windowID] = window
        window.tabbingMode = .disallowed
        // Each window remembers its own size and position.
        window.setFrameAutosaveName("LBrowser.\(store.windowID)")
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.activeStore = store
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.windowClosed(store)
            }
        }
        if window.isKeyWindow { activeStore = store }
    }

    func window(for store: BrowserStore) -> NSWindow? { windows[store.windowID] }

    private func windowClosed(_ store: BrowserStore) {
        store.save()
        openStores.removeAll { $0 === store }
        windows[store.windowID] = nil
        if activeStore === store { activeStore = openStores.last }
        guard !isTerminating else { return }
        store.teardownAll()
        // Closing the last window keeps its tabs for next time, like before multiple windows existed.
        if openStores.isEmpty {
            entries = entries.filter { $0.id == store.windowID }
        } else {
            entries.removeAll { $0.id == store.windowID }
            try? FileManager.default.removeItem(at: Self.sessionURL(for: store.windowID))
        }
        saveManifest()
    }

    func closeWindows(of profileID: String) {
        for store in openStores where store.profile.id == profileID { window(for: store)?.close() }
        for entry in entries where entry.profileID == profileID {
            try? FileManager.default.removeItem(at: Self.sessionURL(for: entry.id))
        }
        entries.removeAll { $0.profileID == profileID }
        if entries.isEmpty { entries = [Entry(id: Self.mainWindowID, profileID: Profile.defaultID)] }
        saveManifest()
    }

    func saveAll() {
        openStores.forEach { $0.save() }
        saveManifest()
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: manifestURL, options: .atomic) }
    }
}

/// One browser window. SwiftUI hands it the window id (nil when it opened the window on its own).
struct BrowserWindow: View {
    let requestedID: String?
    @State private var store: BrowserStore?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let store {
                BrowserView()
                    .environment(store)
                    .focusedSceneValue(\.browserStore, store)
                    .background(WindowAccessor { WindowManager.shared.register($0, for: store) })
                    .navigationTitle(store.selected?.title ?? "LBrowser")
            } else {
                Orbis.canvas
            }
        }
        .onAppear {
            WindowManager.shared.openWindowAction = openWindow
            if store == nil {
                store = WindowManager.shared.store(for: requestedID ?? WindowManager.shared.claimWindowID())
            }
        }
    }
}

/// Hands back the NSWindow a SwiftUI view lives in.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var reported: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window !== reported {
                reported = window
                onWindow?(window)
            }
        }
    }
}

extension FocusedValues {
    @Entry var browserStore: BrowserStore?
    @Entry var pageTranslator: PageTranslator?
}
