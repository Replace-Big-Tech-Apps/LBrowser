import AppKit
import Foundation
import Observation
import SQLite3

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    /// Shown in the favorites bar and on the start page.
    var isFavorite = false
    /// One level of folders, shown as submenus of the Bookmarks menu.
    var folder: String?
    var modified = Date()
}

/// A profile's bookmarks. Deletions are remembered (tombstones) so iCloud sync can merge across Macs.
@Observable @MainActor
final class BookmarkStore {
    private(set) var items: [Bookmark] = []
    @ObservationIgnored private(set) var deleted: [UUID: Date] = [:]
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored let profileID: String
    /// Called after every local change (iCloud sync hooks in here).
    @ObservationIgnored var onChange: (() -> Void)?

    private struct File: Codable {
        var items: [Bookmark]
        var deleted: [UUID: Date]?
    }

    init(fileURL: URL?, profileID: String = Profile.defaultID) {
        self.fileURL = fileURL
        self.profileID = profileID
        if let fileURL, let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            items = file.items
            deleted = file.deleted ?? [:]
        }
    }

    var favorites: [Bookmark] { items.filter(\.isFavorite) }
    var folders: [String] {
        var seen = Set<String>()
        return items.compactMap(\.folder).filter { seen.insert($0).inserted }
    }

    func bookmark(for url: URL?) -> Bookmark? {
        guard let url else { return nil }
        let key = url.comparisonKey
        return items.first { $0.url.comparisonKey == key }
    }

    @discardableResult
    func add(_ url: URL, title: String, favorite: Bool = true, folder: String? = nil) -> Bookmark {
        if let existing = bookmark(for: url) { return existing }
        let bookmark = Bookmark(title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                                url: url, isFavorite: favorite, folder: folder)
        items.append(bookmark)
        changed()
        return bookmark
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        deleted[id] = .now
        changed()
    }

    func update(_ id: UUID, _ edit: (inout Bookmark) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[i])
        items[i].modified = .now
        changed()
    }

    /// Reorders favorites by moving `id` in front of `before` (or to the end).
    func moveFavorite(_ id: UUID, before: UUID?) {
        guard id != before, let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        let to = before.flatMap { b in items.firstIndex { $0.id == b } } ?? items.count
        items.insert(item, at: to)
        changed()
    }

    /// Adds imported bookmarks, skipping URLs that are already bookmarked. Returns how many were added.
    @discardableResult
    func importBookmarks(_ imported: [Bookmark]) -> Int {
        var known = Set(items.map { $0.url.comparisonKey })
        var added = 0
        for var b in imported where known.insert(b.url.comparisonKey).inserted {
            b.id = UUID()
            b.modified = .now
            items.append(b)
            added += 1
        }
        if added > 0 { changed() }
        return added
    }

    /// Merges another copy (from iCloud): newest edit wins, deletions stick.
    func merge(items remote: [Bookmark], deleted remoteDeleted: [UUID: Date]) -> Bool {
        var changedAny = false
        for (id, date) in remoteDeleted where (deleted[id] ?? .distantPast) < date {
            deleted[id] = date
        }
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in remote {
            if let d = deleted[r.id], d >= r.modified { continue }
            if let local = byID[r.id] {
                if r.modified > local.modified, r != local { byID[r.id] = r; changedAny = true }
            } else {
                byID[r.id] = r
                changedAny = true
            }
        }
        let before = byID.count
        byID = byID.filter { id, b in (deleted[id].map { $0 < b.modified }) ?? true }
        changedAny = changedAny || byID.count != before
        guard changedAny else { return false }
        // Keep local order, append new ones in remote order.
        let localOrder = items.map(\.id).filter { byID[$0] != nil }
        let newOnes = remote.map(\.id).filter { id in byID[id] != nil && !localOrder.contains(id) }
        items = (localOrder + newOnes).compactMap { byID[$0] }
        save()
        return true
    }

    private func changed() {
        save()
        onChange?()
    }

    func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(File(items: items, deleted: deleted)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: Import

enum BookmarkImporter {
    enum Source: String, CaseIterable, Identifiable {
        case safari, chrome, brave, edge, arc, vivaldi, firefox
        var id: String { rawValue }
        var label: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Google Chrome"
            case .brave: "Brave"
            case .edge: "Microsoft Edge"
            case .arc: "Arc"
            case .vivaldi: "Vivaldi"
            case .firefox: "Firefox"
            }
        }

        private var chromiumRoot: String? {
            switch self {
            case .chrome: "Google/Chrome"
            case .brave: "BraveSoftware/Brave-Browser"
            case .edge: "Microsoft Edge"
            case .arc: "Arc/User Data"
            case .vivaldi: "Vivaldi"
            default: nil
            }
        }

        var file: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = home.appending(path: "Library/Application Support")
            switch self {
            case .safari:
                return home.appending(path: "Library/Safari/Bookmarks.plist")
            case .firefox:
                let profiles = support.appending(path: "Firefox/Profiles")
                let dirs = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                return dirs.map { $0.appending(path: "places.sqlite") }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                    .max { modified($0) < modified($1) }
            default:
                return chromiumRoot.map { support.appending(path: "\($0)/Default/Bookmarks") }
            }
        }

        var isInstalled: Bool { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

        private func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
    }

    enum ImportError: LocalizedError {
        case notFound, noAccess(String), unreadable
        var errorDescription: String? {
            switch self {
            case .notFound: "No bookmarks were found for that browser."
            case .noAccess(let browser):
                "LBrowser isn't allowed to read \(browser)'s bookmarks. Give it Full Disk Access in System Settings → Privacy & Security, or export them from \(browser) as an HTML file and import that."
            case .unreadable: "That file doesn't contain bookmarks LBrowser can read."
            }
        }
    }

    static func load(from source: Source) throws -> [Bookmark] {
        guard let file = source.file, FileManager.default.fileExists(atPath: file.path) else { throw ImportError.notFound }
        switch source {
        case .safari:
            guard let data = try? Data(contentsOf: file) else { throw ImportError.noAccess("Safari") }
            return try safari(data)
        case .firefox:
            return try firefox(file)
        default:
            guard let data = try? Data(contentsOf: file) else { throw ImportError.notFound }
            return try chromium(data, browser: source.label)
        }
    }

    /// Netscape bookmark HTML — the export format every browser supports.
    static func html(_ text: String) -> [Bookmark] {
        var result: [Bookmark] = []
        var folders: [(name: String, toolbar: Bool)] = []
        let link = try! NSRegularExpression(pattern: #"<A\s[^>]*HREF="([^"]+)"[^>]*>(.*?)</A>"#, options: [.caseInsensitive])
        let folder = try! NSRegularExpression(pattern: #"<H3([^>]*)>(.*?)</H3>"#, options: [.caseInsensitive])
        var pendingFolder: (String, Bool)?
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = folder.firstMatch(in: line, range: range) {
                let attrs = ns.substring(with: m.range(at: 1))
                pendingFolder = (decode(ns.substring(with: m.range(at: 2))), attrs.uppercased().contains("PERSONAL_TOOLBAR_FOLDER"))
            } else if line.range(of: "<DL", options: .caseInsensitive) != nil {
                folders.append(pendingFolder ?? ("", false))
                pendingFolder = nil
            } else if line.range(of: "</DL", options: .caseInsensitive) != nil {
                _ = folders.popLast()
            } else if let m = link.firstMatch(in: line, range: range),
                      let url = URL(string: ns.substring(with: m.range(at: 1))), url.scheme?.hasPrefix("http") == true {
                let toolbar = folders.contains { $0.toolbar }
                let name = folders.last { !$0.name.isEmpty && !$0.toolbar }?.name
                result.append(Bookmark(title: decode(ns.substring(with: m.range(at: 2))), url: url,
                                       isFavorite: toolbar, folder: toolbar ? nil : name))
            }
        }
        return result
    }

    static func chromium(_ data: Data, browser: String) throws -> [Bookmark] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw ImportError.unreadable }
        var result: [Bookmark] = []
        func walk(_ node: [String: Any], favorite: Bool, folder: String?) {
            if node["type"] as? String == "url" {
                if let s = node["url"] as? String, let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                    result.append(Bookmark(title: node["name"] as? String ?? s, url: url, isFavorite: favorite, folder: favorite ? nil : folder))
                }
            } else {
                let name = node["name"] as? String
                for child in node["children"] as? [[String: Any]] ?? [] {
                    walk(child, favorite: favorite, folder: folder == nil ? "Imported from \(browser)" : name ?? folder)
                }
            }
        }
        if let bar = roots["bookmark_bar"] as? [String: Any] {
            for child in bar["children"] as? [[String: Any]] ?? [] {
                // Top-level links go to the favorites bar; folders on the bar become folders.
                if child["type"] as? String == "url" { walk(child, favorite: true, folder: nil) }
                else { walk(child, favorite: false, folder: child["name"] as? String) }
            }
        }
        for key in ["other", "synced"] {
            if let root = roots[key] as? [String: Any] { walk(root, favorite: false, folder: nil) }
        }
        return result
    }

    static func safari(_ data: Data) throws -> [Bookmark] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.unreadable
        }
        var result: [Bookmark] = []
        func walk(_ node: [String: Any], favorite: Bool, folder: String?) {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let s = node["URLString"] as? String, let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { return }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? s
                result.append(Bookmark(title: title, url: url, isFavorite: favorite, folder: favorite ? nil : folder))
            case "WebBookmarkTypeList":
                let title = node["Title"] as? String
                if title == "com.apple.ReadingList" { return }
                let isBar = title == "BookmarksBar"
                let childFolder = isBar || title == "BookmarksMenu" || title == nil ? folder : title
                for child in node["Children"] as? [[String: Any]] ?? [] {
                    walk(child, favorite: favorite || (isBar && child["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf"),
                         folder: childFolder ?? (isBar ? nil : "Imported from Safari"))
                }
            default:
                break
            }
        }
        walk(plist, favorite: false, folder: nil)
        return result
    }

    static func firefox(_ file: URL) throws -> [Bookmark] {
        // Firefox keeps the database locked while running, so read a copy.
        let copy = FileManager.default.temporaryDirectory.appending(path: "lbrowser-places-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        do { try FileManager.default.copyItem(at: file, to: copy) } catch { throw ImportError.noAccess("Firefox") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ImportError.unreadable }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT b.title, p.url, parent.title, parent.guid FROM moz_bookmarks b
            JOIN moz_places p ON p.id = b.fk
            LEFT JOIN moz_bookmarks parent ON parent.id = b.parent
            WHERE b.type = 1 ORDER BY b.parent, b.position
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ImportError.unreadable }
        defer { sqlite3_finalize(statement) }
        var result: [Bookmark] = []
        let text = { (i: Int32) in sqlite3_column_text(statement, i).map { String(cString: $0) } }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let s = text(1), let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { continue }
            let toolbar = text(3) == "toolbar_____"
            let parent = text(2)
            let folder = toolbar ? nil : (["menu", "unfiled", "Bookmarks Menu", "Other Bookmarks", nil].contains(parent) ? "Imported from Firefox" : parent)
            result.append(Bookmark(title: text(0) ?? s, url: url, isFavorite: toolbar, folder: folder))
        }
        return result
    }

    /// Strips tags and decodes the HTML entities bookmark exports use.
    static func decode(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for m in numeric.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let ns = s as NSString
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                s = ns.replacingCharacters(in: m.range, with: String(Character(scalar)))
            }
        }
        return s.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
