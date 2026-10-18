import Foundation
import Observation

/// Optional sync of bookmarks and history between your Macs through iCloud Drive
/// (~/Library/Mobile Documents/com~apple~CloudDocs/LBrowser). Each Mac merges the others' copies.
@Observable @MainActor
final class CloudSync {
    static let shared = CloudSync()

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: "iCloudSync")
    private(set) var lastSync: Date?
    private(set) var problem: String?

    @ObservationIgnored private var timer: Timer?
    /// What this Mac last wrote per file, so unchanged data isn't re-uploaded.
    @ObservationIgnored private var written: [String: Data] = [:]
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    }
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: iCloudDrive.path) }
    private var folder: URL { Self.iCloudDrive.appending(path: "LBrowser", directoryHint: .isDirectory) }

    private struct BookmarkFile: Codable {
        var items: [Bookmark]
        var deleted: [UUID: Date]
    }

    func start() {
        guard isEnabled else { return }
        hook()
        syncNow()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { CloudSync.shared.syncNow() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "iCloudSync")
        if enabled { start() } else {
            timer?.invalidate()
            timer = nil
            ProfileContext.all.forEach { $0.bookmarks.onChange = nil; $0.history.onChange = nil }
        }
    }

    private func hook() {
        for context in ProfileContext.all {
            context.bookmarks.onChange = { CloudSync.shared.schedulePush() }
            context.history.onChange = { CloudSync.shared.schedulePush() }
        }
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            syncNow()
        }
    }

    /// Pull everyone's copy, merge, then publish this Mac's merged copy.
    func syncNow() {
        guard isEnabled else { return }
        guard Self.isAvailable else {
            problem = "iCloud Drive isn't turned on for this Mac."
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let me = Host.current().localizedName ?? "Mac"
            // This Mac's own files only echo local state (and would undo Clear History), so skip them.
            let others = files.filter { !$0.deletingPathExtension().lastPathComponent.hasSuffix("-\(me)") }
            for context in ProfileContext.all {
                let id = context.id
                for file in others where file.lastPathComponent.hasPrefix("bookmarks-\(id)-") {
                    if let data = try? Data(contentsOf: file), let remote = try? JSONDecoder().decode(BookmarkFile.self, from: data) {
                        _ = context.bookmarks.merge(items: remote.items, deleted: remote.deleted)
                    }
                }
                for file in others where file.lastPathComponent.hasPrefix("history-\(id)-") {
                    if let data = try? Data(contentsOf: file), let remote = HistoryStore.Snapshot.decode(data) {
                        context.history.merge(remote)
                    }
                }
                let mine = BookmarkFile(items: context.bookmarks.items, deleted: context.bookmarks.deleted)
                try write(JSONEncoder().encode(mine), to: "bookmarks-\(id)-\(me).json")
                try write(JSONEncoder().encode(context.history.snapshot), to: "history-\(id)-\(me).json")
            }
            lastSync = .now
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func write(_ data: Data, to name: String) throws {
        guard written[name] != data else { return }
        try data.write(to: folder.appending(path: name), options: .atomic)
        written[name] = data
    }
}
