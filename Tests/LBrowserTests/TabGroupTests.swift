import XCTest
@testable import LBrowser

final class TabGroupTests: XCTestCase {
    @MainActor
    func testGroupsAreSeparateTabSetsLikeSafari() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appendingPathComponent("session.json")
        let store = BrowserStore(sessionURL: sessionURL)
        store.restore()
        let a = try XCTUnwrap(store.selected)
        let b = store.newTab(URL(string: "https://b.example")!)
        XCTAssertNil(store.activeGroup)
        XCTAssertEqual(store.visibleTabs.count, 2)

        // A new group starts with its own fresh tab and becomes the shown group.
        let work = store.newGroup()
        XCTAssertTrue(store.activeGroup === work)
        XCTAssertEqual(store.visibleTabs.count, 1)
        XCTAssertEqual(store.renamingGroupID, work.id)
        store.rename(work, to: "  Work ")
        XCTAssertEqual(work.name, "Work")
        XCTAssertNil(store.renamingGroupID)

        // New tabs open in the shown group; tab cycling stays inside it.
        let w2 = store.newTab(URL(string: "https://w2.example")!)
        XCTAssertTrue(store.group(of: w2) === work)
        store.selectRelative(1)
        XCTAssertTrue(store.activeGroup === work)

        // Switching back returns to the tab last used there.
        store.select(a)
        store.switchTo(work)
        let workTab = try XCTUnwrap(store.selected)
        store.switchTo(nil)
        XCTAssertTrue(store.selected === a)
        store.switchTo(work)
        XCTAssertTrue(store.selected === workTab)

        // Closing a group's last tab keeps you in that group with a fresh tab.
        work.tabs.filter { $0 !== workTab }.forEach(store.close)
        store.close(workTab)
        XCTAssertTrue(store.activeGroup === work)
        XCTAssertEqual(work.tabs.count, 1)
        XCTAssertTrue(work.tabs[0].showsStartPage)

        // Moving the shown tab away keeps you in the group you're looking at.
        store.switchTo(nil)
        store.select(b)
        store.move(b, to: work, before: nil)
        XCTAssertNil(store.activeGroup)
        XCTAssertTrue(store.selected === a)
        XCTAssertEqual(work.tabs.count, 2)

        // Session restore keeps groups and each group's last-used tab.
        store.switchTo(work)
        store.select(b)
        store.switchTo(nil)
        store.save()
        let restored = BrowserStore(sessionURL: sessionURL)
        restored.restore()
        XCTAssertEqual(restored.groups.map(\.name), ["Work"])
        XCTAssertNil(restored.activeGroup)
        restored.switchTo(restored.groups[0])
        XCTAssertEqual(restored.selected?.url, URL(string: "https://b.example"))

        // Deleting the shown group goes back to the default tabs.
        store.switchTo(work)
        store.closeGroup(work)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(store.selected === a)
    }

    @MainActor
    func testOldSessionsWithCollapsedGroupsStillLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appendingPathComponent("session.json")
        let json = #"""
        {"groups":[{"name":"Old","color":"blue","collapsed":true,"tabs":[{"url":"https://old.example","title":"Old"}]}],
         "loose":[{"url":"https://loose.example","title":"Loose"}],"selectedIndex":1}
        """#
        try Data(json.utf8).write(to: sessionURL)
        let store = BrowserStore(sessionURL: sessionURL)
        store.restore()
        XCTAssertEqual(store.groups.first?.name, "Old")
        XCTAssertEqual(store.selected?.title, "Loose")
        XCTAssertNil(store.activeGroup)
    }
}
