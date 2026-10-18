import Foundation
import Observation

/// Visited pages, ranked by "frecency" (visit count weighted by recency). Private tabs never record.
@Observable @MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    struct Entry: Codable, Identifiable, Equatable {
        var url: URL
        var title: String
        var visitCount: Int
        var lastVisit: Date
        var id: URL { url }

        /// "www.youtube.com/watch?v=…" — URL without scheme, lowercased, for matching.
        var bareURL: String {
            let s = url.absoluteString
            let stripped = s.range(of: "://").map { String(s[$0.upperBound...]) } ?? s
            return (stripped.hasSuffix("/") ? String(stripped.dropLast()) : stripped).lowercased()
        }

        var host: String { url.host(percentEncoded: false)?.lowercased() ?? "" }

        func score(now: Date = .now) -> Double {
            let days = now.timeIntervalSince(lastVisit) / 86_400
            let recency: Double = days < 4 ? 1 : days < 14 ? 0.7 : days < 31 ? 0.5 : days < 90 ? 0.3 : 0.1
            return (1 + log2(Double(1 + visitCount))) * recency
        }
    }

    /// The inline autocompletion for what the user has typed.
    struct Completion: Equatable {
        /// Text to append after the typed characters.
        var suffix: String
        /// Where Enter goes when the completion is accepted.
        var url: URL
        var title: String
    }

    private(set) var entries: [URL: Entry] = [:]

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private let limit = 5000

    init(fileURL: URL? = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Dictionary(saved.map { ($0.url, $0) }, uniquingKeysWith: { a, b in a.lastVisit > b.lastVisit ? a : b })
        }
    }

    nonisolated private static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.json")
    }

    // MARK: Recording

    func recordVisit(_ url: URL, title: String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else { return }
        let key = Self.normalized(url)
        var entry = entries[key] ?? Entry(url: key, title: "", visitCount: 0, lastVisit: .now)
        entry.visitCount += 1
        entry.lastVisit = .now
        if let title, !title.isEmpty { entry.title = title }
        entries[key] = entry
        if entries.count > limit {
            let drop = entries.values.sorted { $0.score() < $1.score() }.prefix(entries.count - limit)
            drop.forEach { entries.removeValue(forKey: $0.url) }
        }
        scheduleSave()
    }

    func updateTitle(_ title: String, for url: URL) {
        let key = Self.normalized(url)
        guard !title.isEmpty, var entry = entries[key], entry.title != title else { return }
        entry.title = title
        entries[key] = entry
        scheduleSave()
    }

    func clear() {
        entries = [:]
        saveTask?.cancel()
        save()
    }

    /// Drops the fragment so "page#section" and "page" count as one page.
    static func normalized(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.fragment != nil else { return url }
        c.fragment = nil
        return c.url ?? url
    }

    // MARK: Queries

    /// Inline completion, like Chrome/Safari: "you" → "tube.com" from youtube.com visits.
    func completion(for typed: String) -> Completion? {
        let q = typed.lowercased()
        guard !q.isEmpty, !q.contains(" "), !q.contains("://") else { return nil }
        let now = Date.now

        if q.contains("/") {
            // Path-level: complete to the best visited page that starts with what was typed.
            let best = entries.values
                .compactMap { e -> (Entry, String)? in
                    let bare = e.bareURL
                    if bare.hasPrefix(q) { return (e, bare) }
                    if bare.hasPrefix("www."), bare.dropFirst(4).hasPrefix(q) { return (e, String(bare.dropFirst(4))) }
                    return nil
                }
                .max { $0.0.score(now: now) < $1.0.score(now: now) }
            guard let (entry, bare) = best, bare.count > q.count else { return nil }
            return Completion(suffix: String(bare.dropFirst(q.count)), url: entry.url, title: entry.title)
        }

        // Host-level: aggregate visits per site and complete to the domain.
        var sites: [String: (score: Double, best: Entry)] = [:]
        // The destination for a site: its root page if visited, else its most frecent page.
        func better(_ a: Entry, than b: Entry) -> Bool {
            let aRoot = a.url.path().count <= 1, bRoot = b.url.path().count <= 1
            return aRoot != bRoot ? aRoot : a.score(now: now) > b.score(now: now)
        }
        for e in entries.values {
            let host = e.host
            let display: String
            if host.hasPrefix(q) {
                display = host
            } else if host.hasPrefix("www."), host.dropFirst(4).hasPrefix(q) {
                display = String(host.dropFirst(4))
            } else {
                continue
            }
            let s = e.score(now: now)
            if let site = sites[display] {
                sites[display] = (site.score + s, better(e, than: site.best) ? e : site.best)
            } else {
                sites[display] = (s, e)
            }
        }
        guard let (display, site) = sites.max(by: { $0.value.score < $1.value.score }), display.count > q.count,
              let scheme = site.best.url.scheme,
              let root = URL(string: "\(scheme)://\(site.best.host)/")
        else { return nil }
        let isRoot = site.best.url.path().count <= 1
        return Completion(suffix: String(display.dropFirst(q.count)), url: root, title: isRoot ? site.best.title : display)
    }

    /// Pages whose URL or title contains every typed word, best first.
    func matches(for query: String, limit: Int) -> [Entry] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        let now = Date.now
        return entries.values
            .compactMap { e -> (Entry, Double)? in
                let bare = e.bareURL
                let title = e.title.lowercased()
                guard terms.allSatisfy({ bare.contains($0) || title.contains($0) }) else { return nil }
                var boost = 1.0
                let host = e.host.hasPrefix("www.") ? String(e.host.dropFirst(4)) : e.host
                if host.hasPrefix(terms[0]) { boost = 4 } else if title.hasPrefix(terms[0]) { boost = 2 }
                return (e, e.score(now: now) * boost)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard let fileURL else { return }
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Live query suggestions from the selected search engine (OpenSearch JSON: ["q", ["s1", "s2", …]]).
@MainActor
enum SearchSuggestions {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "searchSuggestions") as? Bool ?? true
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()

    static func endpoint(for engine: SearchEngine, query: String) -> URL? {
        var c: URLComponents
        switch engine {
        case .duckduckgo:
            c = URLComponents(string: "https://duckduckgo.com/ac/")!
            c.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "list")]
        case .google:
            c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            c.queryItems = [.init(name: "client", value: "firefox"), .init(name: "q", value: query)]
        case .bing:
            c = URLComponents(string: "https://api.bing.com/osjson.aspx")!
            c.queryItems = [.init(name: "query", value: query)]
        case .startpage:
            c = URLComponents(string: "https://www.startpage.com/osuggestions")!
            c.queryItems = [.init(name: "q", value: query)]
        }
        return c.url
    }

    static func fetch(_ query: String, engine: SearchEngine = .current) async -> [String] {
        guard let url = endpoint(for: engine, query: query) else { return [] }
        var request = URLRequest(url: url)
        request.setValue(WebEngine.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request) else { return [] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.count > 1,
              let list = json[1] as? [String] else { return [] }
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }
}
