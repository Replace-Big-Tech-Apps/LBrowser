import AppKit
import Observation
import WebKit

/// Per-website choices for camera, microphone and JavaScript ("Ask" unless the user decided).
/// Each profile has its own (ProfileContext.permissions).
@Observable @MainActor
final class SitePermissions {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case camera, microphone, location, javascript
        var id: String { rawValue }
        var label: String {
            switch self {
            case .camera: "Camera"
            case .microphone: "Microphone"
            case .location: "Location"
            case .javascript: "JavaScript"
            }
        }
        /// What happens when nothing was chosen for a site.
        var fallback: Setting { self == .javascript ? .allow : .ask }
    }

    enum Setting: String, Codable, CaseIterable, Identifiable {
        case ask, allow, deny
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask: "Ask"
            case .allow: "Allow"
            case .deny: "Deny"
            }
        }
    }

    /// host → kind → setting
    private(set) var sites: [String: [Kind: Setting]] = [:]
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: [Kind: Setting]].self, from: data) {
            sites = saved
        }
    }

    nonisolated static func normalized(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    func setting(_ kind: Kind, for host: String) -> Setting {
        sites[Self.normalized(host)]?[kind] ?? kind.fallback
    }

    func set(_ setting: Setting, _ kind: Kind, for host: String) {
        let key = Self.normalized(host)
        var entry = sites[key] ?? [:]
        entry[kind] = setting == kind.fallback ? nil : setting
        sites[key] = entry.isEmpty ? nil : entry
        save()
    }

    func reset(_ host: String) {
        sites[Self.normalized(host)] = nil
        save()
    }

    /// Answers a page's camera/microphone request, asking the user when the site has no saved choice.
    func decideMediaCapture(host: String, type: WKMediaCaptureType, window: NSWindow?) async -> WKPermissionDecision {
        let kinds: [Kind] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        default: [.camera, .microphone]
        }
        return await decide(kinds, host: host, window: window) ? .grant : .deny
    }

    /// Answers a page's request for the Mac's location (navigator.geolocation).
    func decideLocation(host: String, window: NSWindow?) async -> Bool {
        await decide([.location], host: host, window: window)
    }

    /// Uses the site's saved choice, or asks with "Allow / Don't Allow" and an option to remember it.
    private func decide(_ kinds: [Kind], host: String, window: NSWindow?) async -> Bool {
        let settings = kinds.map { setting($0, for: host) }
        if settings.contains(.deny) { return false }
        if settings.allSatisfy({ $0 == .allow }) { return true }

        let alert = NSAlert()
        let what = kinds.map { $0.label.lowercased() }.joined(separator: " and ")
        alert.messageText = "Allow \(Self.normalized(host)) to use your \(what)?"
        alert.informativeText = kinds == [.location]
            ? "The website gets your Mac's approximate location. You can change this later by clicking the lock in the address bar."
            : "You can change this later in Settings → Websites."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember for this website"
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
        let allowed = response == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            kinds.forEach { set(allowed ? .allow : .deny, $0, for: host) }
        }
        return allowed
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(sites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Cookies and other website data, per profile.
enum WebsiteData {
    struct Site: Identifiable, Hashable {
        let name: String
        let kinds: Set<String>
        var id: String { name }
        var summary: String {
            var parts: [String] = []
            if kinds.contains(WKWebsiteDataTypeCookies) { parts.append("Cookies") }
            if !kinds.isDisjoint(with: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeIndexedDBDatabases,
                                        WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeWebSQLDatabases]) { parts.append("Local storage") }
            if !kinds.isDisjoint(with: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                        WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]) { parts.append("Cache") }
            if kinds.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("Service workers") }
            return parts.isEmpty ? "Other data" : parts.joined(separator: ", ")
        }
    }

    @MainActor
    static func sites(in store: WKWebsiteDataStore) async -> [Site] {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records.map { Site(name: $0.displayName, kinds: $0.dataTypes) }.sorted { $0.name < $1.name }
    }

    /// Removes data for the given sites (record display names, e.g. "example.com").
    @MainActor
    static func remove(_ names: Set<String>, from store: WKWebsiteDataStore) async {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matching = records.filter { names.contains($0.displayName) }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
    }

    /// Removes the data belonging to a host. WebKit names records by registrable domain
    /// ("bbc.co.uk" for www.bbc.co.uk), so match any record the host equals or is a subdomain of.
    @MainActor
    static func remove(host: String, from store: WKWebsiteDataStore) async {
        let host = host.lowercased()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matching = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
    }

    @MainActor
    static func removeAll(from store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

enum DownloadSettings {
    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "downloadFolder"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func setFolder(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: "downloadFolder")
    }

    static var askWhereToSave: Bool {
        UserDefaults.standard.bool(forKey: "askWhereToSave")
    }
}
