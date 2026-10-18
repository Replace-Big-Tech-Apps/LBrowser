import XCTest
@testable import LBrowser

final class DownloadTests: XCTestCase {
    @MainActor
    func testProgressSpeedAndTimeLeft() {
        let item = DownloadItem(filename: "big.zip")
        let start = Date()
        item.sample(received: 0, total: 10_000_000, at: start)
        XCTAssertEqual(item.fraction, 0)
        XCTAssertNil(item.secondsRemaining)

        item.sample(received: 2_000_000, total: 10_000_000, at: start.addingTimeInterval(1))
        XCTAssertEqual(item.fraction ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(item.speed, 2_000_000, accuracy: 1)
        XCTAssertEqual(item.secondsRemaining ?? 0, 4, accuracy: 0.01)
        XCTAssertTrue(item.statusText.contains(" of "))
        XCTAssertTrue(item.statusText.hasSuffix("4 sec left"))

        item.state = .cancelled
        XCTAssertEqual(item.statusText, "Cancelled")
        XCTAssertNil(item.secondsRemaining)
    }

    @MainActor
    func testUnknownSizeHasNoFractionOrETA() {
        let item = DownloadItem(filename: "stream.bin")
        let start = Date()
        item.sample(received: 0, total: -1, at: start)
        item.sample(received: 500_000, total: -1, at: start.addingTimeInterval(1))
        XCTAssertNil(item.fraction)
        XCTAssertNil(item.secondsRemaining)
        XCTAssertFalse(item.statusText.contains("left"))
    }

    @MainActor
    func testDurationFormatting() {
        XCTAssertEqual(DownloadItem.duration(4.2), "5 sec")
        XCTAssertEqual(DownloadItem.duration(125), "2 min 5 sec")
        XCTAssertEqual(DownloadItem.duration(3_725), "1 h 2 min")
    }
}
