import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = "system"

    init() {
        OrbisFont.registerBundled()
    }

    var body: some Scene {
        WindowGroup("LBrowser", id: "browser", for: String.self) { $windowID in
            BrowserWindow(requestedID: windowID)
                .frame(minWidth: 760, minHeight: 480)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 820)
        // LBrowser restores its own windows (with their tabs and profiles).
        .restorationBehavior(.disabled)
        .commands { BrowserCommands() }

        Settings {
            SettingsView()
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        CloudSync.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { WindowManager.shared.openExternal($0) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowManager.shared.isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.isTerminating = true
        WindowManager.shared.saveAll()
        ProfileContext.all.forEach { $0.history.save() }
        AutofillStore.loaded?.saveNow()
        if CloudSync.shared.isEnabled { CloudSync.shared.syncNow() }
    }
}

// MARK: Menus

struct BrowserCommands: Commands {
    @FocusedValue(\.browserStore) private var focused
    @FocusedValue(\.pageTranslator) private var translator
    @AppStorage("favoritesBarVisible") private var favoritesBarVisible = true

    private var store: BrowserStore? { focused ?? WindowManager.shared.activeStore }
    private var tab: BrowserTab? { store?.selected }
    private var hasPage: Bool { tab?.existingWebView != nil && tab?.url != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { newTab() }.keyboardShortcut("t")
            Button("New Window") { WindowManager.shared.newWindow(profileID: store?.profile.id) }.keyboardShortcut("n")
            if ProfileManager.shared.profiles.count > 1 {
                Menu("New Window in Profile") {
                    ForEach(ProfileManager.shared.profiles) { p in
                        Button(p.name) { WindowManager.shared.newWindow(profileID: p.id) }
                    }
                }
            }
            Button("New Private Tab") { store?.newPrivateTab() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Tab Group") { store?.newGroup() }.keyboardShortcut("n", modifiers: [.command, .control])
            Button("Reopen Closed Tab") { store?.reopenClosed() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Open Location…") { store?.focusAddressTick += 1 }.keyboardShortcut("l")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { store?.closeSelected() }.keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Save Page As…") { PageActions.savePage(tab) }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(!hasPage)
            Button("Export as PDF…") { PageActions.exportPDF(tab) }.disabled(!hasPage)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { PageActions.print(tab) }.keyboardShortcut("p").disabled(!hasPage)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Link") { PageActions.copyLink(tab) }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(tab?.url == nil)
            Button("AutoFill Form") { autofill() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!hasPage)
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { store?.showFind() }.keyboardShortcut("f").disabled(!hasPage)
            Button("Find Next") { store?.findNext(backwards: false) }.keyboardShortcut("g").disabled(!hasPage)
            Button("Find Previous") { store?.findNext(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!hasPage)
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { store?.sidebarVisible.toggle() }.keyboardShortcut("s")
            Button(favoritesBarVisible ? "Hide Favorites Bar" : "Show Favorites Bar") { favoritesBarVisible.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Search Tabs…") { store?.tabSearchShown.toggle() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button(tab?.readerShown == true ? "Close Reader" : "Show Reader") { tab?.readerShown.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(tab?.readerAvailable ?? false) && !(tab?.readerShown ?? false))
            Button("Translate Page") { if let tab { translator?.translate(tab) } }
                .disabled(!hasPage || translator == nil)
            Button("Picture in Picture") { tab?.pictureInPicture() }.disabled(!hasPage)
            Divider()
            Button("Zoom In") { zoom(by: 0.1) }.keyboardShortcut("=")
            Button("Zoom Out") { zoom(by: -0.1) }.keyboardShortcut("-")
            Button("Actual Size") { tab?.existingWebView?.pageZoom = 1 }.keyboardShortcut("0")
        }
        CommandMenu("Navigate") {
            Button("Back") { tab?.existingWebView?.goBack() }.keyboardShortcut("[")
            Button("Forward") { tab?.existingWebView?.goForward() }.keyboardShortcut("]")
            Button("Reload") { tab?.existingWebView?.reload() }.keyboardShortcut("r")
            Divider()
            Button("Next Tab") { store?.selectRelative(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { store?.selectRelative(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab Group") { store?.switchGroupRelative(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Tab Group") { store?.switchGroupRelative(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            if let tab, let store {
                Button(store.isPinned(tab) ? "Unpin Tab" : "Pin Tab") { store.isPinned(tab) ? store.unpin(tab) : store.pin(tab) }
                Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.setMuted(!tab.isMuted) }
                if WindowManager.shared.canMoveToNewWindow(tab) {
                    Button("Move Tab to New Window") { WindowManager.shared.moveToNewWindow(tab) }
                }
                Divider()
            }
            ForEach(1..<10) { i in
                Button(i == 9 ? "Last Tab" : "Tab \(i)") { store?.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")))
            }
        }
        CommandMenu("Bookmarks") {
            Button("Add Bookmark") {
                if let tab, let url = tab.url, let store, !store.isPrivate {
                    store.profile.bookmarks.add(url, title: tab.title)
                    store.show(toast: "Added “\(tab.title)” to Favorites")
                }
            }
            .keyboardShortcut("d")
            .disabled(tab?.url == nil || store?.isPrivate == true)
            Divider()
            if let bookmarks = store?.profile.bookmarks {
                let favorites = bookmarks.favorites
                if !favorites.isEmpty {
                    Menu("Favorites") { ForEach(favorites) { b in Button(b.title) { store?.load(b.url) } } }
                }
                ForEach(bookmarks.folders, id: \.self) { folder in
                    Menu(folder) {
                        ForEach(bookmarks.items.filter { $0.folder == folder }) { b in Button(b.title) { store?.load(b.url) } }
                    }
                }
                ForEach(bookmarks.items.filter { !$0.isFavorite && $0.folder == nil }.prefix(40)) { b in
                    Button(b.title) { store?.load(b.url) }
                }
            }
            Divider()
            Menu("Import Bookmarks") {
                ForEach(BookmarkImporter.Source.allCases.filter(\.isInstalled)) { source in
                    Button("From \(source.label)") { BookmarkTools.importFrom(source, into: store) }
                }
                Divider()
                Button("From HTML File…") { BookmarkTools.importHTML(into: store) }
            }
            Button("Export Bookmarks…") { BookmarkTools.exportHTML(from: store) }
        }
        CommandMenu("Develop") {
            Toggle("Developer Tools", isOn: Binding(get: { WebEngine.shared.developerToolsEnabled },
                                                     set: { WebEngine.shared.setDeveloperTools($0) }))
            Button("Right-click a page → Inspect Element (reload open tabs first)") {}.disabled(true)
        }
    }

    private func newTab() {
        if let store { store.newTab() } else { WindowManager.shared.newWindow() }
    }

    private func zoom(by delta: CGFloat) {
        guard let web = tab?.existingWebView else { return }
        web.pageZoom = min(3, max(0.3, web.pageZoom + delta))
    }

    private func autofill() {
        guard let tab, let store else { return }
        Task {
            switch await AutofillStore.shared.fill(tab) {
            case .filled(let n): store.show(toast: "Filled \(n) field\(n == 1 ? "" : "s")")
            case .noData: store.show(toast: "Add your address or a card in Settings → AutoFill first")
            case .nothingToFill: store.show(toast: "No form fields to fill on this page")
            case .needsPassword: store.show(toast: "Set a login password for this Mac to fill saved cards")
            case .cancelled: break
            }
        }
    }
}

@MainActor
enum BookmarkTools {
    static func importFrom(_ source: BookmarkImporter.Source, into store: BrowserStore?) {
        guard let store else { return }
        do {
            let n = store.profile.bookmarks.importBookmarks(try BookmarkImporter.load(from: source))
            store.show(toast: "Imported \(n) bookmark\(n == 1 ? "" : "s") from \(source.label)")
        } catch {
            alert(error.localizedDescription)
        }
    }

    static func importHTML(into store: BrowserStore?) {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return }
        let found = BookmarkImporter.html(text)
        guard !found.isEmpty else { return alert(BookmarkImporter.ImportError.unreadable.localizedDescription) }
        let n = store.profile.bookmarks.importBookmarks(found)
        store.show(toast: "Imported \(n) bookmark\(n == 1 ? "" : "s")")
    }

    static func exportHTML(from store: BrowserStore?) {
        guard let store else { return }
        Task {
            guard let url = await PageActions.savePanel(name: "LBrowser Bookmarks.html", type: .html,
                                                        window: WindowManager.shared.window(for: store)) else { return }
            writeHTML(store.profile.bookmarks, to: url)
        }
    }

    private static func writeHTML(_ bookmarks: BookmarkStore, to url: URL) {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let items = bookmarks.items
        let link = { (b: Bookmark) in "<DT><A HREF=\"\(esc(b.url.absoluteString))\">\(esc(b.title))</A>" }
        var lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>", "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
                     "<TITLE>Bookmarks</TITLE>", "<H1>Bookmarks</H1>", "<DL><p>",
                     "<DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Favorites</H3>", "<DL><p>"]
        lines += items.filter(\.isFavorite).map(link)
        lines.append("</DL><p>")
        for folder in bookmarks.folders {
            lines += ["<DT><H3>\(esc(folder))</H3>", "<DL><p>"] + items.filter { $0.folder == folder && !$0.isFavorite }.map(link) + ["</DL><p>"]
        }
        lines += items.filter { !$0.isFavorite && $0.folder == nil }.map(link)
        lines.append("</DL><p>")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't import bookmarks"
        alert.informativeText = message
        alert.runModal()
    }
}
