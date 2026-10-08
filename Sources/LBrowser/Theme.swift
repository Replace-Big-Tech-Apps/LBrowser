import AppKit
import CoreText
import SwiftUI

// ORBIS design language: white canvas, black ink, hairlines, one amber alert.
// Swap values here to re-theme the whole app.
extension Color {
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: Double = 1, darkAlpha: Double? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? (darkAlpha ?? alpha) : alpha
            )
        })
    }
}

enum Orbis {
    static let canvas = Color.dynamic(0xFEFEFE, 0x0A0A0B)
    static let canvasSoft = Color.dynamic(0xF5F5F5, 0x141416)
    static let surface = Color.dynamic(0x000000, 0xFFFFFF, alpha: 0.04, darkAlpha: 0.05)
    static let surfaceHover = Color.dynamic(0x000000, 0xFFFFFF, alpha: 0.07, darkAlpha: 0.09)
    static let line = Color.dynamic(0x000000, 0xFFFFFF, alpha: 0.10, darkAlpha: 0.12)
    static let lineStrong = Color.dynamic(0x000000, 0xFFFFFF, alpha: 0.22, darkAlpha: 0.28)
    static let ink = Color.dynamic(0x0A0A0B, 0xF5F5F5)
    static let inkMute = Color.dynamic(0x0A0A0B, 0xF5F5F5, alpha: 0.52, darkAlpha: 0.56)
    static let inkWhisper = Color.dynamic(0x0A0A0B, 0xF5F5F5, alpha: 0.30, darkAlpha: 0.34)
    /// Text on an ink-filled (selected) control.
    static let inkInverse = Color.dynamic(0xFEFEFE, 0x0A0A0B)

    static let alert = Color.dynamic(0xD4860A, 0xF0A22A)
    static let positive = Color.dynamic(0x2D7A4A, 0x4FB27A)
    static let negative = Color.dynamic(0xB83232, 0xE06060)

    static let radiusXS: CGFloat = 3
    static let radiusSM: CGFloat = 6
    static let radiusMD: CGFloat = 10
}

enum OrbisFont {
    /// Zen Dots — tracked uppercase labels.
    static func display(_ size: CGFloat) -> Font { .custom("ZenDots-Regular", size: size) }
    /// Alumni Sans Pinstripe — big thin numerals and headlines.
    static func pinstripe(_ size: CGFloat) -> Font { .custom("AlumniSansPinstripe-Regular", size: size) }

    static func registerBundled() {
        guard let dir = Bundle.main.resourceURL?.appending(path: "Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}

extension View {
    /// ORBIS "eyebrow": 9pt Zen Dots, uppercase, 0.14em tracking.
    func eyebrow(_ color: Color = Orbis.inkWhisper, size: CGFloat = 9) -> some View {
        font(OrbisFont.display(size))
            .tracking(size * 0.14)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    func hairline(_ edges: Edge.Set, color: Color = Orbis.line) -> some View {
        overlay(alignment: .top) { if edges.contains(.top) { color.frame(height: 1) } }
            .overlay(alignment: .bottom) { if edges.contains(.bottom) { color.frame(height: 1) } }
            .overlay(alignment: .leading) { if edges.contains(.leading) { color.frame(width: 1) } }
            .overlay(alignment: .trailing) { if edges.contains(.trailing) { color.frame(width: 1) } }
    }
}

enum GroupColor: String, Codable, CaseIterable, Identifiable {
    // Raw values kept stable for saved sessions.
    case yellow, grey, red, green, blue, purple, orange, pink

    var id: String { rawValue }
    var label: String {
        switch self {
        case .yellow: "Amber"
        case .grey: "Ink"
        default: rawValue.capitalized
        }
    }

    var accent: Color {
        switch self {
        case .yellow: Orbis.alert
        case .grey: Orbis.ink
        case .red: Orbis.negative
        case .green: Orbis.positive
        case .blue: .dynamic(0x2F5D9E, 0x6C9BE0)
        case .purple: .dynamic(0x5E4A9C, 0xA08CE0)
        case .orange: .dynamic(0xC2571A, 0xF08A50)
        case .pink: .dynamic(0xA8446F, 0xE07AA6)
        }
    }
}

/// Square bordered icon button, like ORBIS's refresh control.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var bordered = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(hover && !disabled ? Orbis.surfaceHover : .clear))
                .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(bordered ? Orbis.line : .clear))
                .foregroundStyle(disabled ? Orbis.inkWhisper : Orbis.ink)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.13), value: hover)
    }
}

/// Hairline-bordered panel, like ORBIS's price cards.
struct Panel<Content: View>: View {
    var fill: Color = Orbis.canvasSoft
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Orbis.radiusXS).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(Orbis.line))
    }
}

/// Numbered segmented control cell ("01 NEWS"); selected = ink fill.
struct Segment: View {
    let index: Int
    let title: String
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(String(format: "%02d", index)).eyebrow(selected ? Orbis.inkInverse.opacity(0.5) : Orbis.inkWhisper, size: 7)
                Text(title).eyebrow(selected ? Orbis.inkInverse : Orbis.inkMute, size: 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(selected ? Orbis.ink : (hover ? Orbis.surface : Orbis.canvas))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Moves the traffic lights so they sit centered in our taller nav bar.
struct WindowChrome: NSViewRepresentable {
    static let barHeight: CGFloat = 52

    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.relayout() }

    final class ChromeView: NSView {
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            ]
            tokens = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    self?.relayout()
                }
            }
            relayout()
        }

        func relayout() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let height = WindowChrome.barHeight
            container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            titlebar.frame = container.bounds
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, type) in buttons.enumerated() {
                guard let b = window.standardWindowButton(type) else { continue }
                b.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 20, y: (height - b.frame.height) / 2))
            }
        }
    }
}
