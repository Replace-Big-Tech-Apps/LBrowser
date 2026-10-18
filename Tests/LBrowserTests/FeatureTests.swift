import XCTest
@testable import LBrowser

final class FeatureTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    func testBookmarksAddPersistAndMerge() throws {
        let file = try tempDir().appendingPathComponent("bookmarks.json")
        let store = BookmarkStore(fileURL: file)
        let a = store.add(URL(string: "https://a.example/")!, title: "A")
        store.add(URL(string: "https://a.example")!, title: "dupe")
        let b = store.add(URL(string: "https://b.example")!, title: "B", favorite: false, folder: "Work")
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.favorites.map(\.title), ["A"])
        XCTAssertEqual(store.folders, ["Work"])
        store.moveFavorite(b.id, before: a.id)
        XCTAssertEqual(store.items.first?.id, b.id)

        let reloaded = BookmarkStore(fileURL: file)
        XCTAssertEqual(reloaded.items.map(\.title), ["B", "A"])

        // Another Mac deleted A and renamed B later; a third bookmark is new.
        var renamed = b
        renamed.title = "B renamed"
        renamed.modified = Date().addingTimeInterval(60)
        let c = Bookmark(title: "C", url: URL(string: "https://c.example")!)
        XCTAssertTrue(store.merge(items: [renamed, c], deleted: [a.id: Date().addingTimeInterval(60)]))
        XCTAssertEqual(store.items.map(\.title), ["B renamed", "C"])
        XCTAssertFalse(store.merge(items: [renamed, c], deleted: [:]))
    }

    func testImportsNetscapeHTMLAndChromeJSON() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Bar</H3>
            <DL><p>
                <DT><A HREF="https://news.example/" ADD_DATE="1">News &amp; Stuff</A>
            </DL><p>
            <DT><H3>Recipes</H3>
            <DL><p>
                <DT><A HREF="https://food.example/pasta">Pasta</A>
                <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
            </DL><p>
        </DL><p>
        """
        let parsed = BookmarkImporter.html(html)
        XCTAssertEqual(parsed.map(\.title), ["News & Stuff", "Pasta"])
        XCTAssertEqual(parsed.map(\.isFavorite), [true, false])
        XCTAssertEqual(parsed[1].folder, "Recipes")

        let json = #"""
        {"roots":{"bookmark_bar":{"type":"folder","children":[
            {"type":"url","name":"Bar link","url":"https://bar.example"},
            {"type":"folder","name":"Dev","children":[{"type":"url","name":"Docs","url":"https://docs.example"}]}]},
          "other":{"type":"folder","name":"Other","children":[{"type":"url","name":"Elsewhere","url":"https://other.example"}]}}}
        """#
        let chrome = try BookmarkImporter.chromium(Data(json.utf8), browser: "Chrome")
        XCTAssertEqual(chrome.map(\.title), ["Bar link", "Docs", "Elsewhere"])
        XCTAssertEqual(chrome.map(\.isFavorite), [true, false, false])
        XCTAssertEqual(chrome[1].folder, "Dev")
        XCTAssertEqual(chrome[2].folder, "Imported from Chrome")
    }

    @MainActor
    func testPinnedTabsStayAcrossGroupsAndReopenRestoresGroup() throws {
        let sessionURL = try tempDir().appendingPathComponent("session.json")
        let store = BrowserStore(sessionURL: sessionURL)
        store.restore()
        let first = try XCTUnwrap(store.selected)
        let mail = store.newTab(URL(string: "https://mail.example")!)
        store.pin(mail)
        XCTAssertEqual(store.pinnedTabs.count, 1)
        XCTAssertFalse(store.visibleTabs.contains { $0 === mail })

        let work = store.newGroup()
        store.select(mail)
        XCTAssertTrue(store.activeGroup === work, "selecting a pinned tab keeps the shown group")
        let fromPinned = store.newTab(URL(string: "https://link.example")!)
        XCTAssertTrue(store.group(of: fromPinned) === work)

        store.close(fromPinned)
        store.reopenClosed()
        XCTAssertTrue(store.group(of: try XCTUnwrap(store.selected)) === work)
        XCTAssertEqual(store.selected?.url, URL(string: "https://link.example"))

        store.save()
        let restored = BrowserStore(sessionURL: sessionURL)
        restored.restore()
        XCTAssertEqual(restored.pinnedTabs.map(\.url), [URL(string: "https://mail.example")])

        store.unpin(mail)
        XCTAssertTrue(store.pinnedTabs.isEmpty)
        XCTAssertTrue(store.group(of: mail) === work)
        _ = first
    }

    @MainActor
    func testSitePermissionsAndInsecureDetection() throws {
        let permissions = SitePermissions(fileURL: try tempDir().appendingPathComponent("p.json"))
        XCTAssertEqual(permissions.setting(.camera, for: "www.Meet.example"), .ask)
        XCTAssertEqual(permissions.setting(.javascript, for: "meet.example"), .allow)
        permissions.set(.allow, .camera, for: "www.meet.example")
        XCTAssertEqual(permissions.setting(.camera, for: "meet.example"), .allow)
        permissions.set(.ask, .camera, for: "meet.example")
        XCTAssertTrue(permissions.sites.isEmpty)
        XCTAssertEqual(permissions.setting(.location, for: "maps.example"), .ask)
        permissions.set(.deny, .location, for: "maps.example")
        XCTAssertEqual(permissions.setting(.location, for: "www.maps.example"), .deny)

        XCTAssertTrue(BrowserTab(url: URL(string: "http://example.com")).isInsecure)
        XCTAssertFalse(BrowserTab(url: URL(string: "http://localhost:3000")).isInsecure)
        XCTAssertFalse(BrowserTab(url: URL(string: "https://example.com")).isInsecure)
    }

    @MainActor
    func testCardFieldsNeverIncludeSecurityCode() {
        var card = AutofillStore.Card()
        card.number = "4111 1111 1111 1111"
        card.nameOnCard = "Pat Doe"
        card.expMonth = 3
        card.expYear = 2029
        XCTAssertEqual(card.fields["cc-number"], "4111111111111111")
        XCTAssertEqual(card.fields["cc-exp"], "03/29")
        XCTAssertEqual(card.masked, "•••• 1111")
        XCTAssertNil(card.fields["cc-csc"])
    }
}
