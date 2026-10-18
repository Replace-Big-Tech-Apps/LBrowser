import Foundation
import Observation
import WebKit

/// A browsing profile, like Safari's: its own cookies and website data, history, bookmarks and windows.
struct Profile: Codable, Identifiable, Hashable {
    static let defaultID = "default"

    var id: String
    var name: String
    var color: GroupColor

    var isDefault: Bool { id == Self.defaultID }
}

@Observable @MainActor
final class ProfileManager {
    static let shared = ProfileManager()

    private(set) var profiles: [Profile]
    /// Set when deleting a profile couldn't remove all of its website data.
    var problem: String?
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = AppPaths.root.appending(path: "profiles.json")) {
        self.fileURL = fileURL
        let saved = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        let personal = Profile(id: Profile.defaultID, name: "Personal", color: .grey)
        profiles = saved.contains(where: \.isDefault) ? saved : [personal] + saved
    }

    func profile(_ id: String) -> Profile {
        profiles.first { $0.id == id } ?? profiles[0]
    }

    @discardableResult
    func add(name: String) -> Profile {
        let used = Set(profiles.map(\.color))
        let color = GroupColor.allCases.first { !used.contains($0) } ?? .blue
        let profile = Profile(id: UUID().uuidString, name: name, color: color)
        profiles.append(profile)
        save()
        return profile
    }

    func rename(_ id: String, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { profiles[i].name = name }
        save()
    }

    func setColor(_ id: String, _ color: GroupColor) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].color = color
        save()
    }

    /// Removes a profile with all of its data. The default profile can't be deleted.
    func delete(_ id: String) async {
        guard id != Profile.defaultID, let profile = profiles.first(where: { $0.id == id }) else { return }
        WindowManager.shared.closeWindows(of: profile.id)
        profiles.removeAll { $0.id == id }
        save()
        Extensions.shared.removeAll(profileID: id)
        ProfileContext.forget(id)
        if let uuid = UUID(uuidString: id) {
            // WebKit refuses while the closed windows' web views are still being released, so retry briefly.
            var removed = false
            for _ in 0..<10 where !removed {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: uuid)
                    removed = true
                } catch {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            if !removed { problem = "Some website data of “\(profile.name)” couldn't be removed. Quit and reopen LBrowser, then delete it from Settings → Websites." }
        }
        try? FileManager.default.removeItem(at: AppPaths.profileDirectory(id))
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Everything a window of one profile needs: website data, history and bookmarks.
@MainActor
final class ProfileContext {
    let id: String
    let dataStore: WKWebsiteDataStore
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let permissions: SitePermissions
    let directory: URL

    private static var cache: [String: ProfileContext] = [:]

    static func `for`(_ id: String) -> ProfileContext {
        if let cached = cache[id] { return cached }
        let context = ProfileContext(id: id)
        cache[id] = context
        return context
    }

    static var `default`: ProfileContext { .for(Profile.defaultID) }
    static var all: [ProfileContext] { ProfileManager.shared.profiles.map { .for($0.id) } }

    static func forget(_ id: String) { cache[id] = nil }

    private init(id: String) {
        self.id = id
        directory = AppPaths.profileDirectory(id)
        if id == Profile.defaultID {
            dataStore = .default()
        } else {
            dataStore = UUID(uuidString: id).map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
        }
        history = HistoryStore(fileURL: directory.appending(path: "history.json"))
        bookmarks = BookmarkStore(fileURL: directory.appending(path: "bookmarks.json"), profileID: id)
        permissions = SitePermissions(fileURL: directory.appending(path: "site-permissions.json"))
    }

    var profile: Profile { ProfileManager.shared.profile(id) }
}

enum AppPaths {
    /// ~/Library/Application Support/LBrowser
    nonisolated static var root: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The default profile keeps the original locations so existing data carries over.
    nonisolated static func profileDirectory(_ id: String) -> URL {
        if id == Profile.defaultID { return root }
        let dir = root.appending(path: "Profiles/\(id)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
