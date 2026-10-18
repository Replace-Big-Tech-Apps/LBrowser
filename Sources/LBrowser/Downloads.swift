import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@Observable @MainActor
final class DownloadItem: Identifiable {
    enum State: Equatable { case active, finished, failed, cancelled }

    let id = UUID()
    var filename: String
    var destination: URL?
    var received: Int64 = 0
    /// Expected size in bytes, or nil when the server doesn't say.
    var total: Int64?
    /// Smoothed bytes per second.
    var speed: Double = 0
    var state: State = .active

    @ObservationIgnored weak var download: WKDownload?
    @ObservationIgnored fileprivate var lastSample: (date: Date, bytes: Int64)?

    init(filename: String, download: WKDownload? = nil) {
        self.filename = filename
        self.download = download
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    var secondsRemaining: Double? {
        guard state == .active, let total, total > received, speed > 1 else { return nil }
        return Double(total - received) / speed
    }

    /// "12.4 MB of 50 MB — 3.1 MB/s — 12 sec left", or the outcome once it's over.
    var statusText: String {
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch state {
        case .finished: return bytes(received)
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .active:
            var parts = [total.map { "\(bytes(received)) of \(bytes($0))" } ?? bytes(received)]
            if speed > 1 { parts.append("\(bytes(Int64(speed)))/s") }
            if let left = secondsRemaining { parts.append("\(Self.duration(left)) left") }
            return parts.joined(separator: " — ")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return "\(s / 60) min \(s % 60) sec" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    /// Takes a progress reading and updates the speed estimate.
    func sample(received: Int64, total: Int64, at date: Date) {
        self.received = received
        if total > 0 { self.total = total }
        if let last = lastSample {
            let dt = date.timeIntervalSince(last.date)
            if dt > 0 {
                let current = Double(received - last.bytes) / dt
                speed = speed == 0 ? current : speed * 0.7 + current * 0.3
            }
        }
        lastSample = (date, received)
    }
}

/// Tracks WebKit downloads for the downloads panel: what, how much is done, and how long is left.
@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var items: [DownloadItem] = []
    var panelShown = false

    @ObservationIgnored private var timer: Timer?

    var active: [DownloadItem] { items.filter { $0.state == .active } }

    /// Combined progress of running downloads, for the toolbar ring.
    var overallFraction: Double? {
        let running = active
        guard !running.isEmpty else { return nil }
        let totals = running.compactMap(\.total)
        guard totals.count == running.count, totals.reduce(0, +) > 0 else { return nil }
        return Double(running.map(\.received).reduce(0, +)) / Double(totals.reduce(0, +))
    }

    func started(_ download: WKDownload) {
        guard item(for: download) == nil else { return }
        let name = download.originalRequest?.url?.lastPathComponent ?? "Download"
        items.insert(DownloadItem(filename: name.isEmpty ? "Download" : name, download: download), at: 0)
        panelShown = true
        startTimer()
    }

    func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func setDestination(_ url: URL, for download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.destination = url
        item.filename = url.lastPathComponent
    }

    func finished(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        poll(item, at: .now)
        item.state = .finished
        if let total = item.total { item.received = max(item.received, total) }
        item.speed = 0
    }

    func failed(_ download: WKDownload, error: Error) {
        guard let item = item(for: download) else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        item.state = cancelled ? .cancelled : .failed
        item.speed = 0
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel(nil)
        item.state = .cancelled
        item.speed = 0
    }

    func open(_ item: DownloadItem) {
        if let url = item.destination, item.state == .finished { NSWorkspace.shared.open(url) }
    }

    func reveal(_ item: DownloadItem) {
        if let url = item.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func clearFinished() {
        items.removeAll { $0.state != .active }
        if items.isEmpty { panelShown = false }
    }

    private func poll(_ item: DownloadItem, at date: Date) {
        guard let progress = item.download?.progress else { return }
        item.sample(received: progress.completedUnitCount, total: progress.totalUnitCount, at: date)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date.now
                self.active.forEach { self.poll($0, at: now) }
                if self.active.isEmpty {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
    }
}

// MARK: Views

/// Toolbar button with a progress ring; shown once there's something in the downloads list.
struct DownloadsButton: View {
    @State private var downloads = DownloadManager.shared
    @State private var hover = false

    var body: some View {
        if !downloads.items.isEmpty {
            Button { downloads.panelShown.toggle() } label: {
                ZStack {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                    if !downloads.active.isEmpty {
                        Circle().stroke(Orbis.line, lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: downloads.overallFraction ?? 0.15)
                            .stroke(Orbis.alert, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.4), value: downloads.overallFraction)
                    }
                }
                .frame(width: 18, height: 18)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(hover ? Orbis.surfaceHover : .clear))
                .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(Orbis.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Downloads")
            .onHover { hover = $0 }
            .popover(isPresented: $downloads.panelShown, arrowEdge: .bottom) {
                DownloadsPanel().environment(downloads)
            }
        }
    }
}

struct DownloadsPanel: View {
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").eyebrow()
                Spacer()
                if downloads.items.contains(where: { $0.state != .active }) {
                    Button("Clear") { downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Orbis.inkMute)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(downloads.items) { DownloadRow(item: $0) }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
        .frame(width: 360)
        .background(Orbis.canvas)
    }
}

private struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    let item: DownloadItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (item.filename as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .active {
                    ProgressBar(fraction: item.fraction)
                }
                Text(item.statusText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(item.state == .failed ? Orbis.negative : Orbis.inkMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.state == .active {
                IconButton(symbol: "xmark", help: "Cancel") { downloads.cancel(item) }
            } else if item.state == .finished {
                IconButton(symbol: "magnifyingglass", help: "Show in Finder") { downloads.reveal(item) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(hover && item.state == .finished ? Orbis.surface : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { downloads.open(item) }
        .contextMenu {
            if item.state == .finished {
                Button("Open") { downloads.open(item) }
                Button("Show in Finder") { downloads.reveal(item) }
            }
            if item.state == .active { Button("Cancel") { downloads.cancel(item) } }
        }
    }
}

/// Thin ORBIS progress line; indeterminate (sliding) when the size is unknown.
private struct ProgressBar: View {
    let fraction: Double?
    @State private var phase = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Orbis.line)
                if let fraction {
                    Capsule().fill(Orbis.alert)
                        .frame(width: max(3, geo.size.width * fraction))
                        .animation(.easeOut(duration: 0.4), value: fraction)
                } else {
                    Capsule().fill(Orbis.alert)
                        .frame(width: geo.size.width * 0.25)
                        .offset(x: phase ? geo.size.width * 0.75 : 0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
                        }
                }
            }
        }
        .frame(height: 3)
    }
}
