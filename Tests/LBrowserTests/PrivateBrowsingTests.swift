import XCTest
import WebKit
@testable import LBrowser

final class PrivateBrowsingTests: XCTestCase {
    @MainActor
    func testPrivateSessionDoesNotPersistAndRestoresRegularTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appendingPathComponent("session.json")
        let store = BrowserStore(sessionURL: sessionURL)
        store.restore()
        let regular = try XCTUnwrap(store.selected)
        let group = store.newGroup(with: regular)
        store.save()
        let saved = try Data(contentsOf: sessionURL)

        store.newPrivateTab()
        XCTAssertTrue(store.isPrivate)
        XCTAssertTrue(store.groups.isEmpty)
        store.restore()
        XCTAssertTrue(store.groups.isEmpty)
        store.openInBackground(URL(string: "https://regular.example")!, from: regular)
        XCTAssertEqual(store.orderedTabs.count, 1)
        XCTAssertTrue(try XCTUnwrap(store.selected).isPrivate)
        let first = try XCTUnwrap(store.selected)
        let dataStore = first.webView.configuration.websiteDataStore
        XCTAssertFalse(dataStore.isPersistent)
        XCTAssertFalse(first.webView.configuration.userContentController.userScripts.contains {
            $0.source == SafespaceAutofill.shared.userScript.source
        })
        let url = try XCTUnwrap(URL(string: "https://private.example/secret"))
        store.openInBackground(url, from: first)
        let background = try XCTUnwrap(store.orderedTabs.last)
        XCTAssertTrue(background.isPrivate)
        XCTAssertTrue(background.webView.configuration.websiteDataStore === dataStore)
        store.duplicate(background)
        XCTAssertTrue(try XCTUnwrap(store.selected).isPrivate)
        let popup = try XCTUnwrap(store.openPopup(configuration: first.webView.configuration, from: first))
        XCTAssertTrue(popup.isPrivate)
        store.close(background)
        let count = store.orderedTabs.count
        store.reopenClosed()
        XCTAssertEqual(store.orderedTabs.count, count)
        store.newPrivateTab()
        XCTAssertEqual(store.orderedTabs.count, count + 1)
        store.save()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: saved) as? NSDictionary)

        store.setPrivate(false)
        XCTAssertFalse(store.isPrivate)
        XCTAssertTrue(store.groups.first === group)
        XCTAssertTrue(store.selected === regular)
        XCTAssertNil(first.existingWebView)
        XCTAssertNil(popup.existingWebView)
        store.save()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: saved) as? NSDictionary)
        let restored = BrowserStore(sessionURL: sessionURL)
        restored.restore()
        XCTAssertEqual(restored.groups.count, 1)
        XCTAssertFalse(try XCTUnwrap(restored.selected).isPrivate)

        store.setPrivate(true)
        let fresh = try XCTUnwrap(store.selected)
        XCTAssertFalse(fresh.webView.configuration.websiteDataStore === dataStore)
        store.close(fresh)
        XCTAssertFalse(store.isPrivate)
        XCTAssertTrue(store.selected === regular)
    }
}
