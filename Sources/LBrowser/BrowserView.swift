import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(BrowserStore.self) private var store
    @State private var ready = false
    @State private var omnibox = Omnibox()

    var body: some View {
        VStack(spacing: 0) {
            NavBar()
                .frame(height: WindowChrome.barHeight)
                .hairline(.bottom)
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
        .environment(omnibox)
        .background(Orbis.canvas)
        .foregroundStyle(Orbis.ink)
        .ignoresSafeArea()
        .background(WindowChrome())
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4), value: store.sidebarVisible)
        .task {
            guard !ready else { return }
            ready = true
            await WebEngine.shared.prepare()
            store.restore()
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

            Spacer(minLength: 12)
            AddressBar().frame(maxWidth: 640)
            Spacer(minLength: 12)

            ShieldToggle()
            IconButton(symbol: tab?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload", bordered: true) {
                if tab?.isLoading == true { tab?.existingWebView?.stopLoading() } else { tab?.existingWebView?.reload() }
            }
            IconButton(symbol: "plus", help: "New Tab (⌘T)", bordered: true) { store.newTab() }
        }
        .padding(.trailing, 16)
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

struct AddressBar: View {
    @Environment(BrowserStore.self) private var store
    @Environment(Omnibox.self) private var omnibox
    @State private var focused = false

    private var displayText: String { store.selected?.url?.absoluteString ?? "" }

    /// Unfocused, show just the host like Safari/ORBIS's "localhost:5173".
    private var compactText: String {
        guard let url = store.selected?.url else { return "" }
        return url.host(percentEncoded: false).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
    }

    var body: some View {
        let secure = store.selected?.url?.scheme == "https"
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                OmniboxField(
                    omnibox: omnibox,
                    placeholder: store.isPrivate ? "Search privately or enter address" : "Search or enter address",
                    displayText: displayText,
                    focusTick: store.focusAddressTick,
                    isPrivate: store.isPrivate,
                    isFocused: $focused
                ) { store.load($0) }
                .opacity(focused || store.selected?.url == nil ? 1 : 0)
                if !focused, store.selected?.url != nil {
                    HStack(spacing: 6) {
                        if secure { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Orbis.inkWhisper) }
                        Text(compactText).font(.system(size: 12)).lineLimit(1)
                    }
                    .allowsHitTesting(false)
                }
            }
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
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(focused ? Orbis.canvas : Orbis.surface))
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(focused ? Orbis.ink : Orbis.line))
        .overlay(alignment: .bottom) { LoadingLine() }
        .anchorPreference(key: OmniboxAnchorKey.self, value: .bounds) { $0 }
        .contentShape(Rectangle())
        .onTapGesture { store.focusAddressTick += 1 }
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
        ZStack {
            Orbis.canvas
            if let tab = store.selected {
                if tab.showsStartPage {
                    StartPage(tab: tab).id(tab.id)
                } else {
                    WebViewHost(tab: tab)
                }
            }
        }
        .overlay(alignment: .top) {
            if !store.isPrivate { SafespaceNoticeView().padding(.top, 12) }
        }
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
