import SwiftUI
import Translation
import WebKit

struct BrowserView: View {
    @Environment(BrowserStore.self) private var store
    @State private var ready = false
    @State private var omnibox = Omnibox()
    @State private var translator = PageTranslator()
    @AppStorage("favoritesBarVisible") private var favoritesBarVisible = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar()
                .frame(height: WindowChrome.barHeight)
                .hairline(.bottom)
            if favoritesBarVisible, !store.isPrivate || !store.profile.bookmarks.favorites.isEmpty {
                FavoritesBar()
                    .frame(height: 30)
                    .hairline(.bottom)
            }
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    Sidebar()
                        .frame(width: 260)
                        .hairline(.trailing)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                WebArea()
            }
        }
        .overlayPreferenceValue(OmniboxAnchorKey.self) { anchor in
            GeometryReader { geo in
                if let anchor, omnibox.isOpen {
                    let rect = geo[anchor]
                    SuggestionList { open($0.url) }
                        .frame(width: rect.width)
                        .offset(x: rect.minX, y: rect.maxY + 6)
                }
            }
        }
        .overlay(alignment: .top) {
            if store.tabSearchShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { store.tabSearchShown = false }
                    TabSearchPalette().padding(.top, 90)
                }
            }
        }
        .environment(omnibox)
        .environment(translator)
        .focusedSceneValue(\.pageTranslator, translator)
        .translationTask(translator.configuration) { session in
            await translator.run(session)
        }
        .onChange(of: translator.error) { if let e = translator.error { store.show(toast: e) } }
        .background(Orbis.canvas)
        .foregroundStyle(Orbis.ink)
        .ignoresSafeArea()
        .background(WindowChrome())
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4), value: store.sidebarVisible)
        .task {
            guard !ready else { return }
            ready = true
            omnibox.history = store.profile.history
            await WebEngine.shared.prepare()
            store.restore()
            WindowManager.shared.storeReady(store)
        }
    }

    private func open(_ url: URL) {
        omnibox.close()
        NSApp.keyWindow?.makeFirstResponder(nil)
        store.load(url)
    }
}

struct NavBar: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let tab = store.selected
        HStack(spacing: 6) {
            Color.clear.frame(width: 76) // traffic lights

            IconButton(symbol: "sidebar.left", help: "Toggle Sidebar (⌘S)") { store.sidebarVisible.toggle() }
            IconButton(symbol: "chevron.left", help: "Back", disabled: !(tab?.canGoBack ?? false)) {
                tab?.existingWebView?.goBack()
            }
            IconButton(symbol: "chevron.right", help: "Forward", disabled: !(tab?.canGoForward ?? false)) {
                tab?.existingWebView?.goForward()
            }

            Wordmark().padding(.horizontal, 14)
            if !store.profile.profile.isDefault { ProfileChip(profile: store.profile.profile) }

            Spacer(minLength: 12)
            AddressBar().frame(maxWidth: 640)
            Spacer(minLength: 12)

            ExtensionButtons()
            DownloadsButton()
            if let url = tab?.url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Share")
            }
            ShieldToggle()
            IconButton(symbol: tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload", bordered: true) {
                if tab?.isLoading == true { tab?.existingWebView?.stopLoading() } else { tab?.existingWebView?.reload() }
            }
            IconButton(symbol: "plus", help: "New Tab (⌘T)", bordered: true) { store.newTab() }
        }
        .padding(.trailing, 16)
    }
}

struct ProfileChip: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(profile.color.accent).frame(width: 6, height: 6)
            Text(profile.name).eyebrow(Orbis.ink, size: 8).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(Orbis.line))
        .fixedSize()
        .help("Profile: \(profile.name)")
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "globe.europe.africa.fill").font(.system(size: 13))
            Text("L B R O W S E R").font(OrbisFont.display(9)).tracking(1.2)
        }
        .foregroundStyle(Orbis.ink)
        .fixedSize()
    }
}

struct ShieldToggle: View {
    @Environment(BrowserStore.self) private var store
    @State private var hover = false

    var body: some View {
        let on = store.adBlockEnabled
        Button { store.setAdBlock(!on) } label: {
            HStack(spacing: 6) {
                Circle().fill(on ? Orbis.alert : Orbis.inkWhisper).frame(width: 5, height: 5)
                Text(on ? "Shield" : "Shield off").eyebrow(on ? Orbis.ink : Orbis.inkMute)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(hover ? Orbis.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(Orbis.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Ad & tracker blocking on" : "Ad & tracker blocking off")
        .onHover { hover = $0 }
    }
}

/// Toolbar buttons of installed web extensions (icon, badge, popup).
struct ExtensionButtons: View {
    @Environment(BrowserStore.self) private var store
    private let extensions = Extensions.shared

    var body: some View {
        ForEach(extensions.actionItems(for: store.selected)) { item in
            ExtensionButton(item: item) { anchor in
                if let tab = store.selected { extensions.performAction(item.id, tab: tab, anchor: anchor) }
            }
        }
    }
}

private struct ExtensionButton: View {
    let item: Extensions.ActionItem
    let action: ((NSWindow, CGRect)?) -> Void
    @State private var frame = CGRect.zero
    @State private var hover = false

    var body: some View {
        Button { action(NSApp.keyWindow.map { ($0, frame) }) } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon = item.icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "puzzlepiece.extension").font(.system(size: 12)) }
                }
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
                if !item.badge.isEmpty {
                    Text(item.badge)
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(Orbis.alert))
                        .foregroundStyle(.white)
                        .offset(x: 2, y: 1)
                }
            }
            .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(hover ? Orbis.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label)
        .onHover { hover = $0 }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { frame = $1 }
        })
    }
}

struct AddressBar: View {
    @Environment(BrowserStore.self) private var store
    @Environment(Omnibox.self) private var omnibox
    @Environment(PageTranslator.self) private var translator
    @State private var focused = false

    private var displayText: String { store.selected?.url?.absoluteString ?? "" }

    /// Unfocused, show just the host like Safari/ORBIS's "localhost:5173".
    private var compactText: String {
        guard let url = store.selected?.url else { return "" }
        return url.host(percentEncoded: false).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
    }

    var body: some View {
        // The start page has its own search field (with the Private toggle), so the bar stays empty there.
        if store.selected?.showsStartPage ?? true {
            Color.clear.frame(height: 30)
        } else {
            addressField
        }
    }

    private var addressField: some View {
        let tab = store.selected
        return HStack(spacing: 6) {
            if !focused, let tab { SiteInfoButton(tab: tab) }
            ZStack(alignment: .leading) {
                OmniboxField(
                    omnibox: omnibox,
                    placeholder: store.isPrivate ? "Search privately or enter address" : "Search or enter address",
                    displayText: displayText,
                    focusTick: store.focusAddressTick,
                    isPrivate: store.isPrivate,
                    isFocused: $focused
                ) { store.load($0) }
                .opacity(focused ? 1 : 0)
                if !focused {
                    Text(compactText).font(.system(size: 12)).lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            if !focused, let tab {
                if tab.readerAvailable || tab.readerShown {
                    SmallBarButton(symbol: "doc.plaintext", active: tab.readerShown,
                                   help: tab.readerShown ? "Close Reader (⇧⌘R)" : "Show Reader (⇧⌘R)") { tab.readerShown.toggle() }
                }
                if PageTranslator.isForeign(tab) || translator.isTranslated(tab) {
                    SmallBarButton(symbol: "character.bubble", active: translator.isTranslated(tab),
                                   help: translator.isTranslated(tab) ? "Show Original" : "Translate Page",
                                   busy: translator.working == tab.id) {
                        if translator.isTranslated(tab) { translator.showOriginal(tab) } else { translator.translate(tab) }
                    }
                }
                if !store.isPrivate, tab.url != nil { BookmarkButton(tab: tab) }
            }
            PrivateToggle()
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(focused ? Orbis.canvas : Orbis.surface))
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(focused ? Orbis.ink : Orbis.line))
        .overlay(alignment: .bottom) { LoadingLine() }
        .anchorPreference(key: OmniboxAnchorKey.self, value: .bounds) { $0 }
        .contentShape(Rectangle())
        .onTapGesture { store.focusAddressTick += 1 }
    }
}

/// Small icon button inside the address bar.
struct SmallBarButton: View {
    let symbol: String
    var active = false
    var help = ""
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: symbol).font(.system(size: 11)) }
            }
            .foregroundStyle(active ? Orbis.alert : (hover ? Orbis.ink : Orbis.inkMute))
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: Orbis.radiusXS).fill(hover ? Orbis.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Lock / "Not Secure" at the start of the address bar; opens the website's settings.
struct SiteInfoButton: View {
    let tab: BrowserTab
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                if tab.isInsecure {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text("Not Secure").font(.system(size: 11, weight: .medium))
                } else if tab.url?.scheme == "https" {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                } else {
                    Image(systemName: "info.circle").font(.system(size: 10))
                }
                if tab.isCapturing {
                    Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(Orbis.negative)
                }
            }
            .foregroundStyle(tab.isInsecure ? Orbis.negative : Orbis.inkWhisper)
            .frame(height: 22)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.isInsecure ? "This connection isn't encrypted" : "Website settings")
        .popover(isPresented: $shown, arrowEdge: .bottom) { SiteInfoPanel(tab: tab) }
    }
}

struct SiteInfoPanel: View {
    let tab: BrowserTab
    @State private var cleared = false

    private var host: String { tab.url?.host(percentEncoded: false) ?? "" }

    private var permissions: SitePermissions { ProfileContext.for(tab.profileID).permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SitePermissions.normalized(host)).font(.system(size: 13, weight: .semibold))
                Text(tab.isInsecure ? "Not secure — information you send here can be read by others on the network."
                     : tab.url?.scheme == "https" ? "Connection is secure (HTTPS)." : "Local page.")
                    .font(.system(size: 11))
                    .foregroundStyle(tab.isInsecure ? Orbis.negative : Orbis.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Orbis.line.frame(height: 1)
            ForEach(SitePermissions.Kind.allCases) { kind in
                HStack {
                    Text(kind.label).font(.system(size: 12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { permissions.setting(kind, for: host) },
                        set: { permissions.set($0, kind, for: host); if kind == .javascript { tab.existingWebView?.reload() } }
                    )) {
                        ForEach(kind == .javascript ? [SitePermissions.Setting.allow, .deny] : SitePermissions.Setting.allCases) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Orbis.line.frame(height: 1)
            Button(cleared ? "Cookies and data removed" : "Remove Cookies and Website Data…") {
                guard let store = tab.store else { return }
                Task {
                    await WebsiteData.remove(host: host, from: store.profile.dataStore)
                    cleared = true
                    tab.existingWebView?.reload()
                }
            }
            .disabled(cleared || tab.isPrivate)
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Star in the address bar: add the page to favorites, or edit/remove its bookmark.
struct BookmarkButton: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    @State private var shown = false

    var body: some View {
        let bookmarks = store.profile.bookmarks
        let existing = bookmarks.bookmark(for: tab.url)
        SmallBarButton(symbol: existing == nil ? "star" : "star.fill", active: existing != nil,
                       help: existing == nil ? "Add Bookmark (⌘D)" : "Edit Bookmark") {
            if existing == nil, let url = tab.url { bookmarks.add(url, title: tab.title) }
            shown = true
        }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            if let b = bookmarks.bookmark(for: tab.url) { BookmarkEditor(bookmarks: bookmarks, bookmark: b) { shown = false } }
        }
    }
}

struct BookmarkEditor: View {
    let bookmarks: BookmarkStore
    let bookmark: Bookmark
    let done: () -> Void
    @State private var title = ""
    @State private var folder = ""
    @State private var favorite = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmark").eyebrow()
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Toggle("Show in Favorites", isOn: $favorite)
            TextField("Folder (optional)", text: $folder).textFieldStyle(.roundedBorder)
            HStack {
                Button("Remove", role: .destructive) {
                    bookmarks.remove(bookmark.id)
                    done()
                }
                Spacer()
                Button("Done") { save(); done() }.keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 280)
        .onAppear {
            title = bookmark.title
            folder = bookmark.folder ?? ""
            favorite = bookmark.isFavorite
        }
        .onDisappear { if bookmarks.bookmark(for: bookmark.url) != nil { save() } }
    }

    private func save() {
        bookmarks.update(bookmark.id) {
            $0.title = title.isEmpty ? $0.title : title
            $0.isFavorite = favorite
            $0.folder = folder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : folder.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Safari-style favorites bar under the toolbar (⇧⌘B).
struct FavoritesBar: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let favorites = store.profile.bookmarks.favorites
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                if favorites.isEmpty {
                    Text("Click ☆ in the address bar to add favorites here").eyebrow(size: 8).padding(.horizontal, 10)
                }
                ForEach(favorites) { FavoriteChip(bookmark: $0) }
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
        }
        .scrollIndicators(.never)
    }
}

private struct FavoriteChip: View {
    @Environment(BrowserStore.self) private var store
    let bookmark: Bookmark
    @State private var hover = false
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            AsyncImage(url: URL(string: "/favicon.ico", relativeTo: bookmark.url)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "globe").font(.system(size: 9, weight: .light)).foregroundStyle(Orbis.inkMute)
            }
            .frame(width: 12, height: 12)
            Text(bookmark.title).font(.system(size: 11.5)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusXS).fill(hover ? Orbis.surfaceHover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { store.newTab(bookmark.url, select: false) } else { store.load(bookmark.url) }
        }
        .help(bookmark.url.absoluteString)
        .draggable(bookmark.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            store.profile.bookmarks.moveFavorite(id, before: bookmark.id)
            return true
        }
        .popover(isPresented: $editing) {
            BookmarkEditor(bookmarks: store.profile.bookmarks, bookmark: bookmark) { editing = false }
        }
        .contextMenu {
            Button("Open in New Tab") { store.newTab(bookmark.url) }
            Button("Open in New Window") { WindowManager.shared.newWindow(profileID: store.profile.id, url: bookmark.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Edit…") { editing = true }
            Button("Remove from Favorites") { store.profile.bookmarks.update(bookmark.id) { $0.isFavorite = false } }
            Button("Delete Bookmark", role: .destructive) { store.profile.bookmarks.remove(bookmark.id) }
        }
    }
}

/// Private browsing switch, shown at the right end of the address bar and the start page search field.
struct PrivateToggle: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Toggle(isOn: Binding(get: { store.isPrivate }, set: { store.setPrivate($0) })) {
            Label("Private", systemImage: "eye.slash")
                .font(.system(size: 10, weight: .medium))
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(store.isPrivate ? Orbis.inkInverse : Orbis.inkMute)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusXS)
            .fill(store.isPrivate ? Orbis.ink : .clear))
        .fixedSize()
        .help(store.isPrivate ? "Exit private mode and close private tabs" : "Private browsing (⇧⌘N)")
    }
}

/// 1px ink progress line on the address field.
struct LoadingLine: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        if let tab = store.selected, tab.isLoading {
            GeometryReader { geo in
                Rectangle()
                    .fill(Orbis.alert)
                    .frame(width: max(12, (geo.size.width - 8) * tab.progress), height: 1.5)
                    .animation(.easeOut(duration: 0.23), value: tab.progress)
            }
            .frame(height: 1.5)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
        }
    }
}

struct WebArea: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ZStack {
            Orbis.canvas
            if let tab = store.selected {
                if tab.showsStartPage {
                    StartPage(tab: tab).id(tab.id)
                } else {
                    WebViewHost(tab: tab)
                    if tab.readerShown { ReaderView(tab: tab).transition(.opacity) }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.selected?.readerShown)
        .overlay(alignment: .topTrailing) {
            if store.findShown, store.selected?.showsStartPage == false {
                FindBar(shown: $store.findShown).padding(12)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if !store.isPrivate { SafespaceNoticeView() }
                if let toast = store.toast { ToastView(text: toast) }
            }
            .padding(.top, 12)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: store.toast)
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Orbis.alert).frame(width: 5, height: 5)
            Text(text).font(.system(size: 12)).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(Orbis.canvas))
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(Orbis.lineStrong))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// "Saved to Safespace" confirmations, and the unlock prompt when a login is waiting to be saved.
struct SafespaceNoticeView: View {
    private let autofill = SafespaceAutofill.shared

    var body: some View {
        Group {
            if let notice = autofill.notice {
                HStack(spacing: 10) {
                    Circle().fill(Orbis.alert).frame(width: 5, height: 5)
                    Text("Safespace").eyebrow(Orbis.inkMute)
                    Text(notice.message).font(.system(size: 12)).lineLimit(1)
                    if notice.awaitsUnlock {
                        Button("Unlock") { autofill.unlockTapped() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: Orbis.radiusXS).fill(Orbis.ink))
                            .foregroundStyle(Orbis.inkInverse)
                        Button("Not now") { autofill.dismissNotice() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Orbis.inkMute)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(Orbis.canvas))
                .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(Orbis.lineStrong))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: autofill.notice)
    }
}

/// Hosts the selected tab's live WKWebView; switching tabs swaps the subview, never reloads.
struct WebViewHost: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let web = tab.webView
        guard web.superview !== view else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        web.frame = view.bounds
        web.autoresizingMask = [.width, .height]
        view.addSubview(web)
        DispatchQueue.main.async { web.window?.makeFirstResponder(web) }
    }
}
