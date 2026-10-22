import AppKit
import XCTest
@testable import Screenme

/// The picker's selection as a value: dragging, the modifiers, Space moving it, the arrows and a held selection.
final class SelectionTests: XCTestCase {
    private var screen: NSScreen!
    private var origin: CGPoint { CGPoint(x: screen.frame.minX + 100, y: screen.frame.minY + 100) }

    override func setUpWithError() throws {
        screen = try XCTUnwrap(NSScreen.screens.first, "needs a display")
    }

    private func drag(to point: CGPoint) -> Selection.Drag {
        var drag = Selection.Drag(at: origin, on: screen)
        drag.follow(point, delta: CGPoint(x: point.x - origin.x, y: point.y - origin.y), spaceHeld: false, modifiers: [])
        return drag
    }

    func testADragSelectsFromTheAnchorToThePointer() {
        let drag = drag(to: CGPoint(x: origin.x + 40, y: origin.y + 20))
        XCTAssertEqual(drag.rect(modifiers: []), CGRect(x: origin.x, y: origin.y, width: 40, height: 20))
        XCTAssertEqual(drag.rect(modifiers: .shift), CGRect(x: origin.x, y: origin.y, width: 40, height: 40), "Shift squares it")
        XCTAssertEqual(drag.rect(modifiers: .option), CGRect(x: origin.x - 40, y: origin.y - 20, width: 80, height: 40), "Option grows it from the center")
    }

    func testADragStartedOffTheDisplayStartsAtItsEdge() {
        let drag = Selection.Drag(at: CGPoint(x: screen.frame.minX - 50, y: screen.frame.minY + 10), on: screen)
        XCTAssertEqual(drag.anchor, CGPoint(x: screen.frame.minX, y: screen.frame.minY + 10))
    }

    func testSpaceMovesTheWholeSelection() {
        var drag = drag(to: CGPoint(x: origin.x + 40, y: origin.y + 20))
        drag.follow(CGPoint(x: origin.x + 50, y: origin.y + 25), delta: CGPoint(x: 10, y: 5), spaceHeld: true, modifiers: [])
        XCTAssertEqual(drag.rect(modifiers: []), CGRect(x: origin.x + 10, y: origin.y + 5, width: 40, height: 20))
        // Released: the corner follows the pointer again from where it is.
        drag.follow(CGPoint(x: origin.x + 60, y: origin.y + 25), delta: CGPoint(x: 10, y: 0), spaceHeld: false, modifiers: [])
        XCTAssertEqual(drag.rect(modifiers: []), CGRect(x: origin.x + 10, y: origin.y + 5, width: 50, height: 20))
    }

    func testAnArrowSetsTheSelectionUntilThePointerMoves() {
        var drag = drag(to: CGPoint(x: origin.x + 40, y: origin.y + 20))
        let pointer = CGPoint(x: origin.x + 40, y: origin.y + 20)
        let nudged = CGRect(x: origin.x + 1, y: origin.y, width: 40, height: 20)
        drag.nudge(to: nudged, pointer: pointer)
        XCTAssertEqual(drag.rect(modifiers: [.shift, .option]), nudged, "modifiers do not change a nudged selection")

        drag.follow(pointer, delta: .zero, spaceHeld: false, modifiers: [])
        XCTAssertEqual(drag.rect(modifiers: .shift), nudged, "no move, still nudged")

        drag.follow(CGPoint(x: pointer.x + 5, y: pointer.y), delta: CGPoint(x: 5, y: 0), spaceHeld: false, modifiers: [])
        XCTAssertEqual(drag.rect(modifiers: []), CGRect(x: origin.x + 1, y: origin.y, width: 45, height: 20))
    }

    func testTheSelectionStatesSayWhatIsSelectedAndWhere() {
        XCTAssertNil(Selection.none.rect(modifiers: []))
        XCTAssertNil(Selection.none.screen)
        XCTAssertFalse(Selection.none.isDragging)

        let dragging = Selection.dragging(drag(to: CGPoint(x: origin.x + 40, y: origin.y + 20)))
        XCTAssertTrue(dragging.isDragging)
        XCTAssertTrue(dragging.screen === screen)
        XCTAssertEqual(dragging.rect(modifiers: []), CGRect(x: origin.x, y: origin.y, width: 40, height: 20))

        let rect = CGRect(x: origin.x, y: origin.y, width: 30, height: 30)
        let held = Selection.held(rect: rect, screen: screen)
        XCTAssertFalse(held.isDragging)
        XCTAssertTrue(held.screen === screen)
        XCTAssertEqual(held.rect(modifiers: .shift), rect, "a held selection ignores modifiers")
    }
}
