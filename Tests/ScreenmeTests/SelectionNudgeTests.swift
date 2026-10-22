import XCTest
@testable import Screenme

/// Arrow keys on a selection, in Cocoa coordinates: y grows upward, so Up is +y and the bottom edge is minY.
final class SelectionNudgeTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 150)

    private func moved(_ arrow: SelectionNudge.Arrow, _ rect: CGRect? = nil, step: CGFloat = 1) -> CGRect {
        SelectionNudge.apply(arrow, to: rect ?? self.rect, step: step, resize: false, within: bounds)
    }

    private func resized(_ arrow: SelectionNudge.Arrow, _ rect: CGRect? = nil, step: CGFloat = 1) -> CGRect {
        SelectionNudge.apply(arrow, to: rect ?? self.rect, step: step, resize: true, within: bounds)
    }

    func testStepIsOneOrTenWithShift() {
        XCTAssertEqual(SelectionNudge.step(shift: false), 1)
        XCTAssertEqual(SelectionNudge.step(shift: true), 10)
    }

    func testArrowsMoveBySteps() {
        XCTAssertEqual(moved(.left), CGRect(x: 99, y: 100, width: 200, height: 150))
        XCTAssertEqual(moved(.right), CGRect(x: 101, y: 100, width: 200, height: 150))
        XCTAssertEqual(moved(.up), CGRect(x: 100, y: 101, width: 200, height: 150))
        XCTAssertEqual(moved(.down), CGRect(x: 100, y: 99, width: 200, height: 150))
        XCTAssertEqual(moved(.right, step: 10), CGRect(x: 110, y: 100, width: 200, height: 150))
    }

    func testMovingStopsAtTheEdgesAndKeepsTheSize() {
        let corner = CGRect(x: 2, y: 3, width: 200, height: 150)
        XCTAssertEqual(moved(.left, corner, step: 10), CGRect(x: 0, y: 3, width: 200, height: 150))
        XCTAssertEqual(moved(.down, corner, step: 10), CGRect(x: 2, y: 0, width: 200, height: 150))
        let far = CGRect(x: 795, y: 645, width: 200, height: 150)
        XCTAssertEqual(moved(.right, far, step: 10), CGRect(x: 800, y: 645, width: 200, height: 150))
        XCTAssertEqual(moved(.up, far, step: 10), CGRect(x: 795, y: 650, width: 200, height: 150))
    }

    func testResizeRightAndLeftChangeTheWidthFromTheRightEdge() {
        XCTAssertEqual(resized(.right), CGRect(x: 100, y: 100, width: 201, height: 150))
        XCTAssertEqual(resized(.left), CGRect(x: 100, y: 100, width: 199, height: 150))
        XCTAssertEqual(resized(.right, step: 10), CGRect(x: 100, y: 100, width: 210, height: 150))
    }

    func testResizeDownGrowsAndUpShrinksFromTheBottomEdgeKeepingTheTop() {
        let grown = resized(.down)
        XCTAssertEqual(grown, CGRect(x: 100, y: 99, width: 200, height: 151))
        XCTAssertEqual(grown.maxY, rect.maxY)
        let shrunk = resized(.up, step: 10)
        XCTAssertEqual(shrunk, CGRect(x: 100, y: 110, width: 200, height: 140))
        XCTAssertEqual(shrunk.maxY, rect.maxY)
    }

    func testResizeNeverGoesBelowOnePoint() {
        let thin = CGRect(x: 100, y: 100, width: 3, height: 4)
        XCTAssertEqual(resized(.left, thin, step: 10).width, 1)
        XCTAssertEqual(resized(.up, thin, step: 10).height, 1)
        XCTAssertEqual(resized(.up, thin, step: 10).maxY, thin.maxY)
    }

    func testResizeNeverLeavesTheDisplay() {
        let wide = CGRect(x: 900, y: 100, width: 95, height: 150)
        XCTAssertEqual(resized(.right, wide, step: 10).maxX, 1000)
        let low = CGRect(x: 100, y: 4, width: 200, height: 150)
        let down = resized(.down, low, step: 10)
        XCTAssertEqual(down.minY, 0)
        XCTAssertEqual(down.maxY, low.maxY)
    }

    func testBoundsNotAtTheOrigin() {
        let second = CGRect(x: 1000, y: -200, width: 800, height: 600)
        let inside = CGRect(x: 1000, y: -200, width: 100, height: 100)
        XCTAssertEqual(SelectionNudge.apply(.left, to: inside, step: 10, resize: false, within: second), inside)
        XCTAssertEqual(SelectionNudge.apply(.down, to: inside, step: 10, resize: false, within: second), inside)
        XCTAssertEqual(SelectionNudge.apply(.right, to: inside, step: 10, resize: false, within: second).minX, 1010)
    }
}
