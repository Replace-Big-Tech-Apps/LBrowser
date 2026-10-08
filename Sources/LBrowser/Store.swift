import Foundation
import Observation
import WebKit

@Observable @MainActor
final class TabGroup: Identifiable {
    let id = UUID()
    var name: String
    var color: GroupColor
    var collapsed: Bool
    var tabs: [BrowserTab] = []

    init(name: String, color: GroupColor, collapsed: Bool = false) {
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo, google, bing, startpage

    var id: String { rawValue }
    var label: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .startpage: "Startpage"
        }
    }

    static var current: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .duckduckgo
    }

    func url(for query: String) -> URL? {
        var c: URLComponents
        switch self {
        case .duckduckgo: c = URLComponents(string: "https://duckduckgo.com/")!
        case .google: c = URLComponents(string: "https://www.google.com/search")!
        case .bing: c = URLComponents(string: "https://www.bing.com/search")!
        case .startpage: c = URLComponents(string: "https://www.startpage.com/do/search")!
        }
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }
}

enum AddressParser {
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") || text.hasPrefix("about:"), let u = URL(string: text) { return u }
        if !text.contains(" ") {
            if text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") { return URL(string: "http://" + text) }
            if text.contains("."), !text.hasSuffix("."), let u = URL(string: "https://" + text), u.host() != nil {
                return u
            }
        }
        return SearchEngine.current.url(for: text)
    }
}

@Observable @MainActor
final class BrowserStore {
    static let shared = BrowserStore()

    var groups: [TabGroup] = []
    var looseTabs: [BrowserTab] = []
    var selectedID: UUID?
    var sidebarVisible = true
    var focusAddressTick = 0
    private(set) var isPrivate = false
    var adBlockEnabled = WebEngine.shared.isAdBlockEnabled

    @ObservationIgnored private var regularSession: (groups: [TabGroup], loose: [BrowserTab], selectedID: UUID?, closedURLs: [URL])?
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?
    @ObservationIgnored private let sessionURLOverride: URL?

    init(sessionURL: URL? = nil) {
        sessionURLOverride = sessionURL
    }

    @ObservationIgnored private var closedURLs: [URL] = []
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var pendingExternal: [URL] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Sidebar order: groups first, then ungrouped tabs.
    var orderedTabs: [BrowserTab] { groups.flatMap(\.tabs) + looseTabs }
    var selected: BrowserTab? { orderedTabs.first { $0.id == selectedID } }

    func group(of tab: BrowserTab) -> TabGroup? {
        groups.first { $0.tabs.contains { $0 === tab } }
    }

    // MARK: Private browsing

    func setPrivate(_ enabled: Bool) {
        guard enabled != isPrivate else { return }
        if !isReady { restore() }
        saveTask?.cancel()
        if enabled {
            save()
            regularSession = (groups, looseTabs, selectedID, closedURLs)
            groups = []
            looseTabs = []
            selectedID = nil
            closedURLs = []
            privateDataStore = .nonPersistent()
            isPrivate = true
            newTab()
        } else {
            orderedTabs.forEach { $0.teardown() }
            groups = regularSession?.groups ?? []
            looseTabs = regularSession?.loose ?? []
            selectedID = regularSession?.selectedID
            closedURLs = regularSession?.closedURLs ?? []
            regularSession = nil
            privateDataStore = nil
            isPrivate = false
            fixSelection(preferredIndex: 0)
            scheduleSave()
        }
        focusAddressTick += 1
    }

    func newPrivateTab() {
        if isPrivate { newTab() } else { setPrivate(true) }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(_ url: URL? = nil, in group: TabGroup? = nil, after: BrowserTab? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, dataStore: privateDataStore ?? .default())
        insert(tab, in: group, after: after)
        if select {
            selectedID = tab.id
            if url == nil { focusAddressTick += 1 }
        }
        scheduleSave()
        return tab
    }

    func openInBackground(_ url: URL, from tab: BrowserTab) {
        guard orderedTabs.contains(where: { $0 === tab }) else { return }
        newTab(url, in: group(of: tab), after: tab, select: false)
    }

    func openPopup(configuration: WKWebViewConfiguration, from tab: BrowserTab) -> BrowserTab? {
        guard orderedTabs.contains(where: { $0 === tab }) else { return nil }
        let popup = BrowserTab(configuration: configuration)
        insert(popup, in: group(of: tab), after: tab)
        selectedID = popup.id
        return popup
    }

    func openExternal(_ url: URL) {
        if isReady { newTab(url) } else { pendingExternal.append(url) }
    }

    private func insert(_ tab: BrowserTab, in group: TabGroup?, after: BrowserTab?) {
        tab.store = self
        if let group {
            let i = after.flatMap { a in group.tabs.firstIndex { $0 === a } }.map { $0 + 1 } ?? group.tabs.count
            group.tabs.insert(tab, at: i)
        } else {
            let i = after.flatMap { a in looseTabs.firstIndex { $0 === a } }.map { $0 + 1 } ?? looseTabs.count
            looseTabs.insert(tab, at: i)
        }
    }

    private func detach(_ tab: BrowserTab) {
        looseTabs.removeAll { $0 === tab }
        for g in groups { g.tabs.removeAll { $0 === tab } }
    }

    func close(_ tab: BrowserTab) {
        guard orderedTabs.contains(where: { $0 === tab }) else { return }
        let before = orderedTabs
        let index = before.firstIndex { $0 === tab } ?? 0
        if !tab.isPrivate, let url = tab.url { closedURLs.append(url) }
        detach(tab)
        tab.teardown()
        fixSelection(preferredIndex: index)
        scheduleSave()
    }

    func closeSelected() {
        if let selected { close(selected) }
    }

    func reopenClosed() {
        if let url = closedURLs.popLast() { newTab(url) }
    }

    private func fixSelection(preferredIndex: Int) {
        let tabs = orderedTabs
        if tabs.contains(where: { $0.id == selectedID }) { return }
        if tabs.isEmpty {
            if isPrivate { setPrivate(false) } else { newTab() }
        } else {
            selectedID = tabs[min(max(preferredIndex, 0), tabs.count - 1)].id
        }
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
        if let g = group(of: tab), g.collapsed { g.collapsed = false }
    }

    func selectRelative(_ offset: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == selectedID } ?? 0
        select(tabs[(i + offset + tabs.count) % tabs.count])
    }

    func select(index: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        select(index >= 9 ? tabs[tabs.count - 1] : tabs[min(index - 1, tabs.count - 1)])
    }

    func duplicate(_ tab: BrowserTab) {
        newTab(tab.url, in: group(of: tab), after: tab)
    }

    func navigate(_ text: String) {
        guard let url = AddressParser.url(from: text) else { return }
        if let selected { selected.load(url) } else { newTab(url) }
    }

    // MARK: Groups

    @discardableResult
    func newGroup(with tab: BrowserTab? = nil) -> TabGroup {
        let used = Set(groups.map(\.color))
        let color = GroupColor.allCases.first { !used.contains($0) } ?? GroupColor.allCases[groups.count % GroupColor.allCases.count]
        let group = TabGroup(name: "Group \(groups.count + 1)", color: color)
        groups.append(group)
        if let tab { move(tab, to: group, before: nil) } else { newTab(in: group) }
        scheduleSave()
        return group
    }

    func move(_ tab: BrowserTab, to group: TabGroup?, before: BrowserTab?) {
        guard before !== tab else { return }
        detach(tab)
        if let group {
            let i = before.flatMap { b in group.tabs.firstIndex { $0 === b } } ?? group.tabs.count
            group.tabs.insert(tab, at: i)
        } else {
            let i = before.flatMap { b in looseTabs.firstIndex { $0 === b } } ?? looseTabs.count
            looseTabs.insert(tab, at: i)
        }
        scheduleSave()
    }

    /// Drop handler for sidebar drag & drop; payload is a tab UUID string.
    func handleDrop(_ items: [String], group: TabGroup?, before: BrowserTab?) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)),
              let tab = orderedTabs.first(where: { $0.id == id }) else { return false }
        move(tab, to: group, before: before)
        return true
    }

    func ungroup(_ group: TabGroup) {
        looseTabs.insert(contentsOf: group.tabs, at: 0)
        groups.removeAll { $0 === group }
        scheduleSave()
    }

    func closeGroup(_ group: TabGroup) {
        let index = orderedTabs.firstIndex { $0.id == selectedID } ?? 0
        groups.removeAll { $0 === group }
        group.tabs.forEach { $0.teardown() }
        fixSelection(preferredIndex: index)
        scheduleSave()
    }

    // MARK: Ad blocking

    func setAdBlock(_ enabled: Bool) {
        adBlockEnabled = enabled
        WebEngine.shared.setAdBlock(enabled)
        selected?.existingWebView?.reload()
    }

    // MARK: Session persistence

    private struct Session: Codable {
        struct Tab: Codable { var url: URL?; var title: String; var favicon: URL? }
        struct Group: Codable { var name: String; var color: GroupColor; var collapsed: Bool; var tabs: [Tab] }
        var groups: [Group]
        var loose: [Tab]
        var selectedIndex: Int?
    }

    private var sessionURL: URL {
        if let sessionURLOverride { return sessionURLOverride }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "session.json")
    }

    func restore() {
        guard !isReady else { return }
        if let data = try? Data(contentsOf: sessionURL),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            for g in session.groups {
                let group = TabGroup(name: g.name, color: g.color, collapsed: g.collapsed)
                groups.append(group)
                for t in g.tabs { insert(restoredTab(t), in: group, after: nil) }
            }
            for t in session.loose { insert(restoredTab(t), in: nil, after: nil) }
            let tabs = orderedTabs
            if let i = session.selectedIndex, tabs.indices.contains(i) { selectedID = tabs[i].id }
        }
        isReady = true
        pendingExternal.forEach { newTab($0) }
        pendingExternal = []
        fixSelection(preferredIndex: 0)
    }

    private func restoredTab(_ saved: Session.Tab) -> BrowserTab {
        let tab = BrowserTab(url: saved.url, title: saved.title)
        tab.faviconURL = saved.favicon
        return tab
    }

    func scheduleSave() {
        guard isReady, !isPrivate else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard isReady, !isPrivate else { return }
        let tab = { (t: BrowserTab) in Session.Tab(url: t.url, title: t.title, favicon: t.faviconURL) }
        let session = Session(
            groups: groups.map { Session.Group(name: $0.name, color: $0.color, collapsed: $0.collapsed, tabs: $0.tabs.map(tab)) },
            loose: looseTabs.map(tab),
            selectedIndex: orderedTabs.firstIndex { $0.id == selectedID }
        )
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: sessionURL, options: .atomic)
        }
    }
}
