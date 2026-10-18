import Foundation
import Observation
import WebKit

/// A Safari-style tab group: its own set of tabs that replaces the sidebar's tab list when selected.
@Observable @MainActor
final class TabGroup: Identifiable {
    let id = UUID()
    var name: String
    var color: GroupColor
    var tabs: [BrowserTab] = []
    /// The tab to return to when switching back to this group.
    @ObservationIgnored var lastSelectedID: UUID?

    init(name: String, color: GroupColor) {
        self.name = name
        self.color = color
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
        return address(from: text) ?? SearchEngine.current.url(for: text)
    }

    /// The URL the input names, or nil when it should be searched for instead.
    static func address(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") || text.hasPrefix("about:"), let u = URL(string: text) { return u }
        if !text.contains(" ") {
            if text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") { return URL(string: "http://" + text) }
            if text.contains("."), !text.hasSuffix("."), let u = URL(string: "https://" + text), u.host() != nil {
                return u
            }
        }
        return nil
    }
}

/// A recently closed tab, kept with its back/forward history so ⇧⌘T brings all of it back.
struct ClosedTab {
    var url: URL?
    var title: String
    var interactionState: Any?
    var groupID: UUID?
    var wasPinned: Bool
}

/// One browser window's tabs: pinned tabs, tab groups and the default (ungrouped) tabs.
@Observable @MainActor
final class BrowserStore {
    var groups: [TabGroup] = []
    var looseTabs: [BrowserTab] = []
    /// Shown in every tab group, like Safari's pinned tabs.
    var pinnedTabs: [BrowserTab] = []
    var selectedID: UUID? {
        didSet {
            guard let selected else { return }
            if oldValue != selectedID { Extensions.shared.tabActivated(selected, previous: orderedTabs.first { $0.id == oldValue }) }
            if pinnedTabs.contains(where: { $0 === selected }) { return }
            let g = group(of: selected)
            if let g { g.lastSelectedID = selected.id } else { looseLastSelectedID = selected.id }
            if activeGroup !== g { activeGroup = g }
        }
    }
    /// The group whose tabs the sidebar lists (nil = the default tabs). Pinned tabs don't change it.
    private(set) var activeGroup: TabGroup?
    /// Group whose name field the sidebar should open for editing (set right after creating one).
    var renamingGroupID: UUID?
    var sidebarVisible = true
    var focusAddressTick = 0
    var findTick = 0
    var findShown = false
    var findNextTick = 0
    @ObservationIgnored var findBackwards = false
    var tabSearchShown = false
    /// A short message shown at the top of the page area.
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private(set) var isPrivate = false
    var adBlockEnabled: Bool { WebEngine.shared.isAdBlockEnabled }

    let profile: ProfileContext
    let windowID: String

    @ObservationIgnored private var regularSession: (groups: [TabGroup], loose: [BrowserTab], pinned: [BrowserTab], selectedID: UUID?, closed: [ClosedTab])?
    @ObservationIgnored private var privateDataStore: WKWebsiteDataStore?
    @ObservationIgnored private let sessionURLOverride: URL?
    @ObservationIgnored private var looseLastSelectedID: UUID?
    @ObservationIgnored private var closedTabs: [ClosedTab] = []
    @ObservationIgnored private(set) var isReady = false
    @ObservationIgnored private var pendingExternal: [URL] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(profile: ProfileContext? = nil, windowID: String = WindowManager.mainWindowID, sessionURL: URL? = nil) {
        self.profile = profile ?? .default
        self.windowID = windowID
        sessionURLOverride = sessionURL
    }

    /// Every tab in the window (pinned last so saved selection indexes stay compatible).
    var orderedTabs: [BrowserTab] { groups.flatMap(\.tabs) + looseTabs + pinnedTabs }
    var selected: BrowserTab? { orderedTabs.first { $0.id == selectedID } }

    /// The tabs listed in the sidebar: only the active group's.
    var visibleTabs: [BrowserTab] { activeGroup?.tabs ?? looseTabs }

    func tabs(in group: TabGroup?) -> [BrowserTab] { group?.tabs ?? looseTabs }

    func group(of tab: BrowserTab) -> TabGroup? {
        groups.first { $0.tabs.contains { $0 === tab } }
    }

    func isPinned(_ tab: BrowserTab) -> Bool { pinnedTabs.contains { $0 === tab } }

    private var dataStore: WKWebsiteDataStore { privateDataStore ?? profile.dataStore }

    func show(toast text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Find

    func showFind() {
        findShown = true
        findTick += 1
    }

    func findNext(backwards: Bool) {
        if !findShown { showFind(); return }
        findBackwards = backwards
        findNextTick += 1
    }

    // MARK: Private browsing

    func setPrivate(_ enabled: Bool) {
        guard enabled != isPrivate else { return }
        if !isReady { restore() }
        saveTask?.cancel()
        if enabled {
            save()
            regularSession = (groups, looseTabs, pinnedTabs, selectedID, closedTabs)
            groups = []
            looseTabs = []
            pinnedTabs = []
            activeGroup = nil
            selectedID = nil
            closedTabs = []
            privateDataStore = .nonPersistent()
            isPrivate = true
            newTab()
        } else {
            orderedTabs.forEach { $0.teardown() }
            groups = regularSession?.groups ?? []
            looseTabs = regularSession?.loose ?? []
            pinnedTabs = regularSession?.pinned ?? []
            activeGroup = nil
            selectedID = regularSession?.selectedID
            closedTabs = regularSession?.closed ?? []
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

    /// Opens a tab in `group`, or in the active group when nil.
    @discardableResult
    func newTab(_ url: URL? = nil, in group: TabGroup? = nil, after: BrowserTab? = nil, select: Bool = true) -> BrowserTab {
        makeTab(url, in: group ?? activeGroup, after: after, select: select)
    }

    @discardableResult
    private func makeTab(_ url: URL?, in group: TabGroup?, after: BrowserTab? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, dataStore: dataStore, profileID: profile.id)
        insert(tab, in: group, after: after)
        Extensions.shared.tabOpened(tab)
        if select {
            selectedID = tab.id
            if url == nil { focusAddressTick += 1 }
        }
        scheduleSave()
        return tab
    }

    /// Opens a page that needs its own web view configuration (an extension's options page).
    func openTab(_ url: URL, configuration: WKWebViewConfiguration) {
        let tab = BrowserTab(configuration: configuration, profileID: profile.id)
        insert(tab, in: activeGroup, after: nil)
        tab.load(url)
        selectedID = tab.id
    }

    /// Links opened from a pinned tab land in the shown group.
    private func home(of tab: BrowserTab) -> TabGroup? { isPinned(tab) ? activeGroup : group(of: tab) }

    func openInBackground(_ url: URL, from tab: BrowserTab) {
        guard orderedTabs.contains(where: { $0 === tab }) else { return }
        makeTab(url, in: home(of: tab), after: isPinned(tab) ? nil : tab, select: false)
    }

    func openPopup(configuration: WKWebViewConfiguration, from tab: BrowserTab) -> BrowserTab? {
        guard orderedTabs.contains(where: { $0 === tab }) else { return nil }
        let popup = BrowserTab(configuration: configuration, profileID: profile.id)
        insert(popup, in: home(of: tab), after: isPinned(tab) ? nil : tab)
        selectedID = popup.id
        return popup
    }

    func openExternal(_ url: URL) {
        if isReady { newTab(url) } else { pendingExternal.append(url) }
    }

    /// Takes over a tab from another window ("Move Tab to New Window").
    func adopt(_ tab: BrowserTab) {
        insert(tab, in: activeGroup, after: nil)
        selectedID = tab.id
        scheduleSave()
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
        pinnedTabs.removeAll { $0 === tab }
        for g in groups { g.tabs.removeAll { $0 === tab } }
    }

    func close(_ tab: BrowserTab) {
        guard orderedTabs.contains(where: { $0 === tab }) else { return }
        if !tab.isPrivate, tab.url != nil {
            closedTabs.append(ClosedTab(url: tab.url, title: tab.title, interactionState: tab.existingWebView?.interactionState,
                                        groupID: group(of: tab)?.id, wasPinned: isPinned(tab)))
            if closedTabs.count > 50 { closedTabs.removeFirst() }
        }
        remove(tab)
        Extensions.shared.tabClosed(tab)
        tab.teardown()
    }

    /// Takes a tab out of this window without closing it (for moving it to another window).
    func release(_ tab: BrowserTab) {
        guard orderedTabs.contains(where: { $0 === tab }) else { return }
        remove(tab)
        tab.store = nil
    }

    /// Takes a tab out of the window's lists and, if it was shown, selects what comes next in its place.
    private func remove(_ tab: BrowserTab) {
        let pinned = isPinned(tab)
        let home = group(of: tab)
        let index = tabs(in: home).firstIndex { $0 === tab } ?? 0
        let wasSelected = tab.id == selectedID
        detach(tab)
        if wasSelected {
            if pinned { switchTo(activeGroup, force: true) } else { selectNeighbor(in: home, near: index) }
        }
        scheduleSave()
    }

    /// Keeps the user in the same group: picks the next tab there, or opens a fresh one if it's now empty.
    private func selectNeighbor(in group: TabGroup?, near index: Int) {
        let tabs = tabs(in: group)
        if !tabs.isEmpty {
            selectedID = tabs[min(max(index, 0), tabs.count - 1)].id
        } else if isPrivate, orderedTabs.isEmpty {
            setPrivate(false)
        } else {
            makeTab(nil, in: group)
        }
    }

    func closeSelected() {
        if let selected { close(selected) }
    }

    var canReopenClosed: Bool { !closedTabs.isEmpty }

    /// Reopens the last closed tab in its group, with its back/forward history.
    func reopenClosed() {
        guard let closed = closedTabs.popLast() else { return }
        let group = closed.groupID.flatMap { id in groups.first { $0.id == id } } ?? (closed.groupID == nil ? nil : activeGroup)
        let tab = BrowserTab(url: closed.url, title: closed.title, dataStore: dataStore, profileID: profile.id,
                             interactionState: closed.interactionState)
        if closed.wasPinned {
            tab.store = self
            pinnedTabs.append(tab)
        } else {
            insert(tab, in: group, after: nil)
        }
        selectedID = tab.id
        scheduleSave()
    }

    private func fixSelection(preferredIndex: Int) {
        let tabs = orderedTabs
        if tabs.contains(where: { $0.id == selectedID }) { return }
        let unpinned = groups.flatMap(\.tabs) + looseTabs
        if unpinned.isEmpty {
            if isPrivate, tabs.isEmpty { setPrivate(false) } else { makeTab(nil, in: nil) }
        } else {
            selectedID = unpinned[min(max(preferredIndex, 0), unpinned.count - 1)].id
        }
    }

    func select(_ tab: BrowserTab) {
        selectedID = tab.id
    }

    /// The order ⌃Tab and ⌘1…9 walk: pinned tabs, then the shown group's tabs.
    private var cycleTabs: [BrowserTab] { pinnedTabs + visibleTabs }

    func selectRelative(_ offset: Int) {
        let tabs = cycleTabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == selectedID } ?? 0
        select(tabs[(i + offset + tabs.count) % tabs.count])
    }

    func select(index: Int) {
        let tabs = cycleTabs
        guard !tabs.isEmpty else { return }
        select(index >= 9 ? tabs[tabs.count - 1] : tabs[min(index - 1, tabs.count - 1)])
    }

    func duplicate(_ tab: BrowserTab) {
        makeTab(tab.url, in: home(of: tab), after: isPinned(tab) ? nil : tab)
    }

    func navigate(_ text: String) {
        if let url = AddressParser.url(from: text) { load(url) }
    }

    func load(_ url: URL) {
        if let selected { selected.load(url) } else { newTab(url) }
    }

    // MARK: Pinned tabs

    func pin(_ tab: BrowserTab) {
        guard !isPinned(tab), orderedTabs.contains(where: { $0 === tab }) else { return }
        let home = group(of: tab)
        detach(tab)
        pinnedTabs.append(tab)
        // Keep the group from going empty underneath the pinned tab.
        if tabs(in: home).isEmpty { makeTab(nil, in: home, select: false) }
        scheduleSave()
    }

    func unpin(_ tab: BrowserTab) {
        guard isPinned(tab) else { return }
        pinnedTabs.removeAll { $0 === tab }
        insert(tab, in: activeGroup, after: nil)
        selectedID = tab.id
        scheduleSave()
    }

    func movePinned(_ tab: BrowserTab, before: BrowserTab?) {
        guard isPinned(tab), before !== tab else { return }
        pinnedTabs.removeAll { $0 === tab }
        let i = before.flatMap { b in pinnedTabs.firstIndex { $0 === b } } ?? pinnedTabs.count
        pinnedTabs.insert(tab, at: i)
        scheduleSave()
    }

    // MARK: Groups

    /// Shows a group's tabs (nil = the default tabs), returning to the tab last used there.
    func switchTo(_ group: TabGroup?, force: Bool = false) {
        let showingPinned = selected.map(isPinned) ?? false
        guard force || showingPinned || group !== activeGroup || selected == nil else { return }
        let tabs = tabs(in: group)
        let remembered = group?.lastSelectedID ?? looseLastSelectedID
        if let tab = tabs.first(where: { $0.id == remembered }) ?? tabs.last {
            select(tab)
        } else {
            makeTab(nil, in: group)
        }
    }

    /// Switches to the next/previous entry in the group list (default tabs first).
    func switchGroupRelative(_ offset: Int) {
        let all: [TabGroup?] = [nil] + groups
        let i = all.firstIndex { $0 === activeGroup } ?? 0
        switchTo(all[(i + offset + all.count) % all.count])
    }

    /// Creates a group and switches to it — with `tab` moved into it, or a fresh tab.
    @discardableResult
    func newGroup(with tab: BrowserTab? = nil) -> TabGroup {
        let used = Set(groups.map(\.color))
        let color = GroupColor.allCases.first { !used.contains($0) } ?? GroupColor.allCases[groups.count % GroupColor.allCases.count]
        let group = TabGroup(name: "Group \(groups.count + 1)", color: color)
        groups.append(group)
        if let tab {
            detach(tab)
            group.tabs.append(tab)
            select(tab)
        } else {
            makeTab(nil, in: group)
        }
        renamingGroupID = group.id
        scheduleSave()
        return group
    }

    /// Moves a tab (drag & drop or "Move to Tab Group"). If the shown tab leaves the shown group,
    /// the user stays in that group, like Safari.
    func move(_ tab: BrowserTab, to group: TabGroup?, before: BrowserTab?) {
        guard before !== tab else { return }
        let wasPinned = isPinned(tab)
        let home = self.group(of: tab)
        let index = tabs(in: home).firstIndex { $0 === tab } ?? 0
        detach(tab)
        if let group {
            let i = before.flatMap { b in group.tabs.firstIndex { $0 === b } } ?? group.tabs.count
            group.tabs.insert(tab, at: i)
        } else {
            let i = before.flatMap { b in looseTabs.firstIndex { $0 === b } } ?? looseTabs.count
            looseTabs.insert(tab, at: i)
        }
        if tab.id == selectedID {
            if wasPinned { selectedID = tab.id } else if group !== home { selectNeighbor(in: home, near: index) }
        }
        scheduleSave()
    }

    /// Drop handler for sidebar drag & drop; payload is a tab UUID string.
    func handleDrop(_ items: [String], group: TabGroup?, before: BrowserTab?) -> Bool {
        guard let tab = draggedTab(items) else { return false }
        move(tab, to: group, before: before)
        return true
    }

    func handlePinnedDrop(_ items: [String], before: BrowserTab?) -> Bool {
        guard let tab = draggedTab(items) else { return false }
        if isPinned(tab) { movePinned(tab, before: before) } else {
            pin(tab)
            movePinned(tab, before: before)
        }
        return true
    }

    private func draggedTab(_ items: [String]) -> BrowserTab? {
        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return nil }
        return orderedTabs.first { $0.id == id }
    }

    func rename(_ group: TabGroup, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { group.name = name }
        if renamingGroupID == group.id { renamingGroupID = nil }
        scheduleSave()
    }

    /// Deletes a group and closes its tabs.
    func closeGroup(_ group: TabGroup) {
        let wasActive = activeGroup === group
        groups.removeAll { $0 === group }
        group.tabs.forEach {
            Extensions.shared.tabClosed($0)
            $0.teardown()
        }
        if wasActive {
            activeGroup = nil
            switchTo(nil, force: true)
        }
        scheduleSave()
    }

    // MARK: Ad blocking

    func setAdBlock(_ enabled: Bool) {
        WebEngine.shared.setAdBlock(enabled)
        WindowManager.shared.openStores.forEach { $0.selected?.existingWebView?.reload() }
    }

    // MARK: Session persistence

    struct Session: Codable {
        struct Tab: Codable { var url: URL?; var title: String; var favicon: URL? }
        struct Group: Codable {
            var name: String
            var color: GroupColor
            var collapsed: Bool? // unused since Safari-style groups; kept so older sessions decode
            var tabs: [Tab]
            var selectedIndex: Int?
        }
        var groups: [Group]
        var loose: [Tab]
        var selectedIndex: Int?
        var looseSelectedIndex: Int?
        var pinned: [Tab]?
        var sidebarVisible: Bool?
    }

    var sessionURL: URL {
        sessionURLOverride ?? WindowManager.sessionURL(for: windowID)
    }

    func restore() {
        guard !isReady else { return }
        if let data = try? Data(contentsOf: sessionURL),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            for g in session.groups {
                let group = TabGroup(name: g.name, color: g.color)
                groups.append(group)
                for t in g.tabs { insert(restoredTab(t), in: group, after: nil) }
                if let i = g.selectedIndex, group.tabs.indices.contains(i) { group.lastSelectedID = group.tabs[i].id }
            }
            for t in session.loose { insert(restoredTab(t), in: nil, after: nil) }
            for t in session.pinned ?? [] {
                let tab = restoredTab(t)
                tab.store = self
                pinnedTabs.append(tab)
            }
            if let i = session.looseSelectedIndex, looseTabs.indices.contains(i) { looseLastSelectedID = looseTabs[i].id }
            let tabs = orderedTabs
            if let i = session.selectedIndex, tabs.indices.contains(i) {
                // A pinned tab doesn't say which group was shown; fall back to the default tabs.
                selectedID = tabs[i].id
            }
            if let visible = session.sidebarVisible { sidebarVisible = visible }
        }
        isReady = true
        pendingExternal.forEach { newTab($0) }
        pendingExternal = []
        fixSelection(preferredIndex: 0)
    }

    private func restoredTab(_ saved: Session.Tab) -> BrowserTab {
        let tab = BrowserTab(url: saved.url, title: saved.title, dataStore: profile.dataStore, profileID: profile.id)
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
        // Extension pages (options) need the extension's own web view setup, so they aren't restored.
        let keep = { (tabs: [BrowserTab]) in tabs.filter { $0.url?.scheme != "webkit-extension" } }
        let tab = { (t: BrowserTab) in Session.Tab(url: t.url, title: t.title, favicon: t.faviconURL) }
        let loose = keep(looseTabs)
        let session = Session(
            groups: groups.map { g in
                let tabs = keep(g.tabs)
                return Session.Group(name: g.name, color: g.color, tabs: tabs.map(tab),
                                     selectedIndex: tabs.firstIndex { $0.id == g.lastSelectedID })
            },
            loose: loose.map(tab),
            selectedIndex: (groups.flatMap { keep($0.tabs) } + loose + keep(pinnedTabs)).firstIndex { $0.id == selectedID },
            looseSelectedIndex: loose.firstIndex { $0.id == looseLastSelectedID },
            pinned: keep(pinnedTabs).map(tab),
            sidebarVisible: sidebarVisible
        )
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: sessionURL, options: .atomic)
        }
    }

    /// Closes every tab (the window is going away for good).
    func teardownAll() {
        saveTask?.cancel()
        let all = orderedTabs + (regularSession.map { $0.groups.flatMap(\.tabs) + $0.loose + $0.pinned } ?? [])
        for tab in all {
            Extensions.shared.tabClosed(tab)
            tab.teardown()
        }
    }
}
