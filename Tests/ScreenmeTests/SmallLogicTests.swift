import XCTest
@testable import Screenme

final class DurationFormatTests: XCTestCase {
    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(Duration.format(0), "0:00")
        XCTAssertEqual(Duration.format(12), "0:12")
        XCTAssertEqual(Duration.format(65), "1:05")
        XCTAssertEqual(Duration.format(3723), "1:02:03")
    }

    func testRoundsWithoutTenthsAndCutsWithTenths() {
        XCTAssertEqual(Duration.format(11.6), "0:12")
        XCTAssertEqual(Duration.format(12.47, tenths: true), "0:12.4")
        XCTAssertEqual(Duration.format(12, tenths: true), "0:12.0")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(Duration.format(-5), "0:00")
    }
}

final class EditorGeometryTests: XCTestCase {
    func testDragRectNormalizesAnyDirection() {
        let anchor = CGPoint(x: 10, y: 10)
        XCTAssertEqual(CGRect.dragRect(anchor: anchor, to: CGPoint(x: 30, y: 20), ratio: nil), CGRect(x: 10, y: 10, width: 20, height: 10))
        XCTAssertEqual(CGRect.dragRect(anchor: anchor, to: CGPoint(x: 0, y: 4), ratio: nil), CGRect(x: 0, y: 4, width: 10, height: 6))
    }

    func testDragRectLocksRatioByGrowingTheShortSide() {
        let wide = CGRect.dragRect(anchor: .zero, to: CGPoint(x: 40, y: 10), ratio: 1)
        XCTAssertEqual(wide, CGRect(x: 0, y: 0, width: 40, height: 40))
        let tall = CGRect.dragRect(anchor: .zero, to: CGPoint(x: 10, y: 40), ratio: 2)
        XCTAssertEqual(tall, CGRect(x: 0, y: 0, width: 80, height: 40))
    }

    func testHandlePointsAndOpposites() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(Handle.tl.point(in: r), CGPoint(x: 0, y: 0))
        XCTAssertEqual(Handle.br.point(in: r), CGPoint(x: 100, y: 50))
        XCTAssertEqual(Handle.t.point(in: r), CGPoint(x: 50, y: 0))
        XCTAssertEqual(Handle.l.point(in: r), CGPoint(x: 0, y: 25))
        for handle in [Handle.tl, .t, .tr, .r, .br, .b, .bl, .l] {
            XCTAssertEqual(handle.opposite.opposite, handle)
        }
        XCTAssertEqual(Handle.points(for: r).count, 8)
    }

    func testEdgeHandleMovesOnlyItsOwnSide() {
        let r = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertEqual(Handle.r.drag(r, to: CGPoint(x: 150, y: 999), ratio: nil), CGRect(x: 10, y: 10, width: 140, height: 50))
        XCTAssertEqual(Handle.t.drag(r, to: CGPoint(x: 999, y: 0), ratio: nil), CGRect(x: 10, y: 0, width: 100, height: 60))
    }

    func testCornerHandleKeepsOppositeCornerFixed() {
        let r = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertEqual(Handle.br.drag(r, to: CGPoint(x: 210, y: 110), ratio: nil), CGRect(x: 10, y: 10, width: 200, height: 100))
        XCTAssertEqual(Handle.tl.drag(r, to: CGPoint(x: 60, y: 30), ratio: nil), CGRect(x: 60, y: 30, width: 50, height: 30))
    }

    func testHitHandlePicksFirstWithinRadius() {
        let handles = Handle.points(for: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(Handle.hitHandle(handles, at: CGPoint(x: 99, y: 2), radius: 5), .tr)
        XCTAssertNil(Handle.hitHandle(handles, at: CGPoint(x: 30, y: 30), radius: 5))
    }
}

final class ActionLinkTests: XCTestCase {
    func testEveryActionRoundTripsThroughItsLink() {
        for action in ShortcutAction.allCases {
            XCTAssertEqual(ActionLink(url: URL(string: "screenme://\(action.urlName)")!)?.action, action)
        }
        XCTAssertEqual(ShortcutAction.captureArea.urlName, "capture-area")
        XCTAssertEqual(ShortcutAction.allInOne.urlName, "all-in-one")
    }

    func testAreaAndWindowTargets() throws {
        let area = try XCTUnwrap(ActionLink(url: URL(string: "screenme://capture-area?x=10&y=20&width=300&height=200")!))
        guard case .area(let rect) = area.target else { return XCTFail("expected an area") }
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 300, height: 200))

        let window = try XCTUnwrap(ActionLink(url: URL(string: "screenme://capture-window?app=com.apple.TextEdit")!))
        guard case .window(let app) = window.target else { return XCTFail("expected a window") }
        XCTAssertEqual(app, "com.apple.TextEdit")
    }

    func testIncompleteOrEmptyAreasAreIgnored() {
        XCTAssertNil(ActionLink(url: URL(string: "screenme://capture-area?x=10&y=20&width=300")!)?.target)
        XCTAssertNil(ActionLink(url: URL(string: "screenme://capture-area?x=0&y=0&width=0&height=50")!)?.target)
    }

    func testUnknownLinksDoNothing() {
        XCTAssertNil(ActionLink(url: URL(string: "screenme://format-disk")!))
        XCTAssertNil(ActionLink(url: URL(string: "https://capture-area")!))
    }
}
