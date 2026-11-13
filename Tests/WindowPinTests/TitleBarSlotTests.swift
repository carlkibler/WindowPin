import XCTest
@testable import WindowPin

final class TitleBarSlotTests: XCTestCase {

    /// A title bar with controls over the given ranges, in points from the right edge.
    private func bar(_ taken: ClosedRange<CGFloat>...) -> (CGFloat) -> TitleBarSlot.Probe {
        { x in taken.contains { $0.contains(x) } ? .taken : .free }
    }

    func testEmptyTitleBarKeepsTheCorner() {
        XCTAssertEqual(TitleBarSlot.inset(side: 22, width: 800, probe: bar()), TitleBarSlot.margin)
    }

    func testBadgeMovesLeftOfAButtonInTheCorner() {
        // A 28pt button from 10pt to 38pt in from the edge.
        let inset = TitleBarSlot.inset(side: 22, width: 800, probe: bar(10...38))
        XCTAssertEqual(inset, 40)
    }

    func testBadgeFitsInAGapBetweenButtons() {
        // Buttons at 8–30 and 60–90: the gap 30–60 holds a 22pt badge.
        let inset = TitleBarSlot.inset(side: 22, width: 800, probe: bar(8...30, 60...90))
        XCTAssertEqual(inset, 32)
    }

    func testGapTooNarrowIsSkipped() {
        // A 14pt gap between 30 and 44 is too small.
        let inset = TitleBarSlot.inset(side: 22, width: 800, probe: bar(8...30, 44...70))
        XCTAssertEqual(inset, 72)
    }

    func testAToolbarFullOfButtonsFallsBackToTheCorner() {
        XCTAssertNil(TitleBarSlot.inset(side: 22, width: 300, probe: bar(0...300)))
    }

    func testAnAppThatDoesNotAnswerFallsBackToTheCorner() {
        XCTAssertNil(TitleBarSlot.inset(side: 22, width: 800) { _ in .failed })
    }

    func testNeverAsksTooManyTimes() {
        var asked = 0
        _ = TitleBarSlot.inset(side: 22, width: 4000) { _ in asked += 1; return .taken }
        XCTAssertLessThanOrEqual(asked, TitleBarSlot.maxProbes)
    }

    func testEachPointIsAskedOnce() {
        var asked: [CGFloat] = []
        _ = TitleBarSlot.inset(side: 22, width: 800) { x in
            asked.append(x)
            return (40...44).contains(x) ? .taken : .free
        }
        XCTAssertEqual(asked.count, Set(asked).count)
    }
}

final class BadgeSpotTests: XCTestCase {

    func testBadgeIsCentredOnTheCloseButton() {
        // A plain title bar: close button middle 14pt down.
        XCTAssertEqual(BadgeSpot.top(centredOn: 14, side: 22), 3)
        // A tall unified toolbar: middle 26pt down.
        XCTAssertEqual(BadgeSpot.top(centredOn: 26, side: 22), 15)
    }

    func testCloseButtonInAnOddPlaceKeepsTheCorner() {
        XCTAssertEqual(BadgeSpot.top(centredOn: 300, side: 22), BadgeSpot.corner.top)
        XCTAssertEqual(BadgeSpot.top(centredOn: -5, side: 22), BadgeSpot.corner.top)
        XCTAssertEqual(BadgeSpot.top(centredOn: .nan, side: 22), BadgeSpot.corner.top)
    }
}
