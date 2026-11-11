import XCTest
@testable import WindowPin

final class PinnedWindowTests: XCTestCase {

    private func window(_ id: UInt32, owner: String = "Safari", title: String = "") -> PinnedWindow {
        PinnedWindow(windowID: id, ownerPID: 1, ownerName: owner, windowTitle: title)
    }

    func testLabelIsJustTheOwnerWhenThereIsNoTitle() {
        XCTAssertEqual(window(1, owner: "Terminal").displayLabel, "Terminal")
    }

    func testLabelJoinsOwnerAndTitle() {
        XCTAssertEqual(window(1, title: "Inbox").displayLabel, "Safari — Inbox")
    }

    func testLongTitleIsTruncatedToFortyCharacters() {
        let label = window(1, title: String(repeating: "x", count: 41)).displayLabel
        XCTAssertEqual(label, "Safari — " + String(repeating: "x", count: 40) + "…")
    }

    func testTitleOfExactlyFortyCharactersIsKept() {
        let title = String(repeating: "x", count: 40)
        XCTAssertEqual(window(1, title: title).displayLabel, "Safari — " + title)
    }

    func testWindowsAreIdentifiedByWindowIDAlone() {
        XCTAssertEqual(window(7, title: "a"), window(7, owner: "Other", title: "b"))
        XCTAssertNotEqual(window(7), window(8))
        XCTAssertEqual(Set([window(7, title: "a"), window(7, title: "b")]).count, 1)
    }

    func testForeignWindowIsIdentifiedByWindowIDAlone() {
        let a = ForeignWindow(windowID: 3, ownerPID: 1, ownerName: "A", windowTitle: "x")
        let b = ForeignWindow(windowID: 3, ownerPID: 2, ownerName: "B", windowTitle: "y")
        XCTAssertEqual(a, b)
    }
}
