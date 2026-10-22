import AppKit
import XCTest
@testable import Screenme

/// Live drawing: the canvas numbers the pins of a take and records them; Clear keeps them, a restart starts again.
@MainActor
final class LiveDrawingTests: XCTestCase {
    func testTheCanvasNumbersPinsAndARestartStartsAgain() throws {
        let area = CGRect(x: 0, y: 0, width: 400, height: 300)
        let events = RecordingEventRecorder(area: area, recordsWindows: false, cursorless: false, time: { 1 })
        let canvas = DrawingCanvas(frame: area, drawing: LiveDrawing())
        canvas.events = events
        // ⇧-click drops a pin with any tool. The event goes straight to the view: nothing moves the real pointer.
        func shiftClick(_ x: Double, _ y: Double) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: x, y: y), modifierFlags: .shift,
                                                         timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            canvas.mouseDown(with: event)
        }
        func pins() -> [Int] {
            events.events.compactMap { event in
                guard case .pin(let number, _) = event.action else { return nil }
                return number
            }
        }

        try shiftClick(10, 20)
        try shiftClick(30, 40)
        canvas.clear()
        try shiftClick(50, 60)
        XCTAssertEqual(pins(), [1, 2, 3], "Clear removes drawings; the pins and their count stay")

        canvas.clear(pins: true)
        try shiftClick(70, 80)
        XCTAssertEqual(pins().last, 1, "a restart numbers pins from 1 again")
    }
}
