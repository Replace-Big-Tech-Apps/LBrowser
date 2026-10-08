import AppKit
import SwiftUI

@main
struct LBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BrowserStore.shared
    @AppStorage("appearance") private var appearance = "system"

    init() {
        OrbisFont.registerBundled()
    }

    var body: some Scene {
        Window("LBrowser", id: "main") {
            BrowserView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 480)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 820)
        .commands { BrowserCommands(store: store) }

        Settings {
            SettingsView().environment(store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { BrowserStore.shared.openExternal($0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserStore.shared.save()
    }
}

struct BrowserCommands: Commands {
    let store: BrowserStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }.keyboardShortcut("t")
            Button("New Private Tab") { store.newPrivateTab() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Tab Group") { store.newGroup() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { store.reopenClosed() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Open Location…") { store.focusAddressTick += 1 }.keyboardShortcut("l")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { store.closeSelected() }.keyboardShortcut("w")
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { store.sidebarVisible.toggle() }.keyboardShortcut("s")
            Divider()
            Button("Zoom In") { zoom(by: 0.1) }.keyboardShortcut("=")
            Button("Zoom Out") { zoom(by: -0.1) }.keyboardShortcut("-")
            Button("Actual Size") { store.selected?.existingWebView?.pageZoom = 1 }.keyboardShortcut("0")
        }
        CommandMenu("Navigate") {
            Button("Back") { store.selected?.existingWebView?.goBack() }.keyboardShortcut("[")
            Button("Forward") { store.selected?.existingWebView?.goForward() }.keyboardShortcut("]")
            Button("Reload") { store.selected?.existingWebView?.reload() }.keyboardShortcut("r")
            Divider()
            Button("Next Tab") { store.selectRelative(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { store.selectRelative(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(1..<10) { i in
                Button(i == 9 ? "Last Tab" : "Tab \(i)") { store.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")))
            }
        }
    }

    private func zoom(by delta: CGFloat) {
        guard let web = store.selected?.existingWebView else { return }
        web.pageZoom = min(3, max(0.3, web.pageZoom + delta))
    }
}

struct SettingsView: View {
    @Environment(BrowserStore.self) private var store
    @AppStorage("searchEngine") private var engine = SearchEngine.duckduckgo.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @State private var autofill = WebEngine.shared.isAutofillEnabled

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Picker("Search engine", selection: $engine) {
                ForEach(SearchEngine.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("Block ads & trackers", isOn: Binding(get: { store.adBlockEnabled }, set: { store.setAdBlock($0) }))
            Toggle("Autofill & save passwords with Safespace", isOn: $autofill)
                .onChange(of: autofill) { WebEngine.shared.setAutofill(autofill) }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}
