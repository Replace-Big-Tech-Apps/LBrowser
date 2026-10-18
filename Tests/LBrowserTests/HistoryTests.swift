import XCTest
@testable import LBrowser

final class HistoryTests: XCTestCase {
    @MainActor
    func testCompletionPrefersFrequentSitesAndRootPages() throws {
        let history = HistoryStore(fileURL: nil)
        for _ in 0..<5 { history.recordVisit(URL(string: "https://www.youtube.com/watch?v=1")!, title: "Video") }
        history.recordVisit(URL(string: "https://www.youtube.com/")!, title: "YouTube")
        history.recordVisit(URL(string: "https://yourdictionary.com/")!, title: "Dictionary")

        let c = try XCTUnwrap(history.completion(for: "you"))
        XCTAssertEqual(c.suffix, "tube.com")
        XCTAssertEqual(c.url, URL(string: "https://www.youtube.com/"))
        XCTAssertEqual(c.title, "YouTube")
        XCTAssertEqual(history.completion(for: "www.yout")?.suffix, "ube.com")
        XCTAssertEqual(history.completion(for: "youtube.com/wa")?.suffix, "tch?v=1")
        XCTAssertNil(history.completion(for: "youtube.com"))
        XCTAssertNil(history.completion(for: "you tube"))
        XCTAssertNil(history.completion(for: "zzz"))
    }

    @MainActor
    func testMatchesSearchTitleAndURLAndIgnoreNonWebSchemes() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(URL(string: "https://developer.apple.com/documentation/swiftui#top")!, title: "SwiftUI Docs")
        history.recordVisit(URL(string: "https://developer.apple.com/documentation/swiftui")!, title: "SwiftUI Docs")
        history.recordVisit(URL(string: "about:blank")!, title: "Blank")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.values.first?.visitCount, 2)
        XCTAssertEqual(history.matches(for: "swiftui docs", limit: 5).count, 1)
        XCTAssertEqual(history.matches(for: "apple documentation", limit: 5).count, 1)
        XCTAssertTrue(history.matches(for: "android", limit: 5).isEmpty)
    }

    @MainActor
    func testOmniboxRowsAndEnterDestination() {
        let history = HistoryStore(fileURL: nil)
        history.recordVisit(URL(string: "https://github.com/")!, title: "GitHub")
        let omnibox = Omnibox(history: history)
        omnibox.isPrivate = true // no network in tests

        XCTAssertEqual(omnibox.update(typed: "git", allowCompletion: true), "hub.com")
        XCTAssertEqual(omnibox.suggestions.first?.title, "GitHub")
        XCTAssertEqual(omnibox.destination(for: "github.com"), URL(string: "https://github.com/"))

        XCTAssertNil(omnibox.update(typed: "git", allowCompletion: false))
        XCTAssertEqual(omnibox.suggestions.first?.kind, .search)
        XCTAssertEqual(omnibox.suggestions.count, 2)
        XCTAssertEqual(omnibox.move(by: 1), "https://github.com/")
        XCTAssertEqual(omnibox.destination(for: "https://github.com/"), URL(string: "https://github.com/"))
        XCTAssertEqual(omnibox.move(by: 1), "git")

        omnibox.close()
        XCTAssertFalse(omnibox.isOpen)
    }

    @MainActor
    func testParsesOpenSearchSuggestions() {
        let data = Data(#"["swift",["swift","Swift","swiftui"],[],{}]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(data), ["swift", "swiftui"])
        XCTAssertEqual(SearchSuggestions.parse(Data("nope".utf8)), [])
    }
}
