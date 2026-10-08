import SwiftUI

struct StartPage: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let shortcuts: [(String, String)] = [
        ("YouTube", "https://www.youtube.com"),
        ("GitHub", "https://github.com"),
        ("Wikipedia", "https://en.wikipedia.org"),
        ("Reddit", "https://www.reddit.com"),
        ("Hacker News", "https://news.ycombinator.com"),
        ("Gmail", "https://mail.google.com"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                searchField.frame(maxWidth: 560)
                if store.isPrivate {
                    Text("Private browsing — tabs and website data are discarded when you exit. Downloads are kept.")
                        .font(.system(size: 12))
                        .foregroundStyle(Orbis.inkMute)
                        .multilineTextAlignment(.center)
                }
                shortcutBar
                DotCloud()
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 14)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            InfoPanel()
                .frame(width: 320)
                .hairline(.leading)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Orbis.inkWhisper)
            TextField("", text: $query, prompt: Text("Search \(SearchEngine.current.label) or type a URL")
                .font(OrbisFont.display(9)).foregroundStyle(Orbis.inkWhisper))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { if let url = AddressParser.url(from: query) { tab.load(url) } }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Orbis.radiusXS).fill(Orbis.canvas))
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(searchFocused ? Orbis.ink : Orbis.line))
    }

    /// ORBIS category filter bar.
    private var shortcutBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.shortcuts, id: \.0) { name, link in
                ShortcutChip(name: name) { if let url = URL(string: link) { tab.load(url) } }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(Orbis.line))
        .fixedSize()
    }
}

private struct ShortcutChip: View {
    let name: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .eyebrow(hover ? Orbis.ink : Orbis.inkWhisper, size: 8)
                .padding(.horizontal, 11)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { if hover { Orbis.ink.frame(height: 1.5).padding(.horizontal, 8) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Right-hand detail panel, modeled on ORBIS's article/oil panel.
private struct InfoPanel: View {
    @Environment(BrowserStore.self) private var store

    private var place: String {
        let parts = TimeZone.current.identifier.split(separator: "/").map { $0.replacingOccurrences(of: "_", with: " ") }
        return parts.reversed().joined(separator: ", ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(place).eyebrow(size: 8)
                    HStack(spacing: 5) {
                        PulseDot()
                        Text("Live").eyebrow(size: 8)
                    }
                }

                Text(context.date.formatted(.dateTime.hour().minute()))
                    .font(OrbisFont.pinstripe(104))
                    .monospacedDigit()
                    .padding(.top, 14)
                    .frame(height: 104)
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(OrbisFont.pinstripe(34))
                    .foregroundStyle(Orbis.inkMute)
                    .padding(.top, 10)

                HStack(spacing: 8) {
                    Tag(text: store.adBlockEnabled ? "Shield on" : "Shield off", dot: store.adBlockEnabled ? Orbis.alert : Orbis.inkWhisper)
                    Tag(text: SearchEngine.current.label, dot: nil)
                }
                .padding(.top, 18)

                Orbis.line.frame(height: 1).padding(.vertical, 20)

                Text("Session").eyebrow(size: 8)
                HStack(spacing: 12) {
                    StatCard(label: "Tabs", value: store.orderedTabs.count)
                    StatCard(label: "Groups", value: store.groups.count)
                }
                .frame(height: 96)
                .padding(.top, 12)

                Orbis.line.frame(height: 1).padding(.vertical, 20)

                VStack(spacing: 12) {
                    InfoRow(label: "Blocked networks", value: "\(AdRules.adDomains.count)")
                    InfoRow(label: "YouTube", value: store.adBlockEnabled ? "Ads skipped" : "Unfiltered")
                    InfoRow(label: "Engine", value: "WebKit")
                }

                Spacer(minLength: 16)

                OutlineButton(title: "Reopen closed tab") { store.reopenClosed() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct Tag: View {
    let text: String
    let dot: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 4, height: 4) }
            Text(text).eyebrow(Orbis.inkMute, size: 8)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(Orbis.line))
    }
}

private struct StatCard: View {
    let label: String
    let value: Int

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).eyebrow(size: 7.5)
                Text(String(format: "%02d", value))
                    .font(OrbisFont.pinstripe(44))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).eyebrow(size: 8)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Orbis.ink)
        }
    }
}

struct OutlineButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).eyebrow(Orbis.ink, size: 8.5)
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 11))
                    .offset(x: hover ? 3 : 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Orbis.radiusXS).fill(hover ? Orbis.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(Orbis.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4), value: hover)
    }
}

/// Drifting dot-matrix cloud: three puffs on a flat base; dots swell where it's thickest.
struct DotCloud: View {
    /// Puffs in unit space (x: 0…1 across, y: 0…1 down); radius in width units.
    private static let puffs: [(x: Double, y: Double, r: Double)] = [
        (0.31, 0.56, 0.165), (0.50, 0.42, 0.225), (0.71, 0.56, 0.155),
    ]
    /// Flat capsule the puffs sit on.
    private static let base = (x0: 0.15, x1: 0.85, y: 0.72, r: 0.085)
    private static let aspect = 0.6 // height / width

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let width = min(size.width, size.height / Self.aspect) * 0.9
                guard width > 60 else { return }
                let height = width * Self.aspect
                let origin = CGPoint(x: (size.width - width) / 2,
                                     y: (size.height - height) / 2 + sin(t * 0.6) * width * 0.012)
                let columns = 78
                let step = 1.0 / Double(columns)
                let dotMax = width * step * 0.64

                var y = step / Self.aspect / 2
                while y < 1 {
                    var x = step / 2
                    while x < 1 {
                        let h = Self.thickness(x: x, y: y, t: t)
                        if h > 0 {
                            let shimmer = 0.1 * sin(t * 1.3 - x * 7 + y * 4)
                            let v = min(1, max(0, h + shimmer))
                            let s = dotMax * (0.22 + 0.78 * v)
                            let px = origin.x + x * width, py = origin.y + y * height
                            ctx.fill(Path(CGRect(x: px - s / 2, y: py - s / 2, width: s, height: s)),
                                     with: .color(Orbis.ink.opacity(0.14 + 0.86 * v)))
                        }
                        x += step
                    }
                    y += step / Self.aspect
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 0 outside the cloud; up to ~1 at the thickest, top-lit part of a puff.
    private static func thickness(x: Double, y: Double, t: Double) -> Double {
        func dome(_ dx: Double, _ dy: Double, _ r: Double) -> Double {
            let (u, v) = (dx / r, dy * aspect / r)
            let d2 = u * u + v * v
            guard d2 < 1 else { return 0 }
            let lit = 0.5 - 0.35 * v - 0.15 * u // light from the top-left
            return (1 - d2).squareRoot() * 0.75 + lit * 0.25
        }
        var best = 0.0, second = 0.0
        func add(_ h: Double) {
            if h > best { second = best; best = h } else if h > second { second = h }
        }
        for (i, p) in puffs.enumerated() {
            let r = p.r * (1 + 0.03 * sin(t * 0.8 + Double(i) * 2.1)) // gentle breathing
            add(dome(x - p.x, y - p.y, r))
        }
        let bx = min(max(x, base.x0), base.x1)
        add(dome(x - bx, y - base.y, base.r) * 0.8)
        // Thin valleys where two puffs meet keep the lobes readable.
        if second > 0, best - second < 0.035 { best *= 0.45 }
        return best
    }
}
