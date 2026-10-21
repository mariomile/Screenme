import XCTest
@testable import Screenme

/// Annotations stay editable after Done: the document is saved as JSON next to the capture and comes back intact.
final class EditSidecarTests: PrefsSandboxTestCase {
    /// A document using every shape, a styled annotation, a note, crop past the image, resize, canvas fill,
    /// background and spotlight dim.
    static func richState() -> EditState {
        var state = EditState(cropRect: CGRect(x: -10, y: 4, width: 120, height: 90))
        var arrow = Annotation(kind: .arrow, style: ToolStyle(color: Palette.blue, shadow: true), at: CGPoint(x: 1, y: 2))
        arrow.shape = .segment(p0: CGPoint(x: 1, y: 2), p1: CGPoint(x: 30.5, y: 40), bend: 0.25)
        arrow.style.curved = true
        arrow.note = "Make this button bigger"
        var box = Annotation(kind: .rectangle, style: ToolStyle(color: Palette.green), at: .zero)
        box.shape = .box(CGRect(x: 5, y: 6, width: 20, height: 10))
        box.style.filled = true
        box.style.opacity = 0.4
        var pen = Annotation(kind: .pen, style: ToolStyle(color: Palette.purple), at: .zero)
        pen.shape = .stroke([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 3), CGPoint(x: 4, y: 9)])
        var counter = Annotation(kind: .counter, style: ToolStyle(color: Palette.red), at: CGPoint(x: 50, y: 60))
        counter.style.sizeIndex = 2
        var text = Annotation(kind: .text, style: ToolStyle(color: Palette.ink, fontSize: 31), at: .zero)
        text.shape = .label(origin: CGPoint(x: 8, y: 9), text: "Hello\nworld")
        text.style.weight = .heavy
        text.style.backdrop = .pill
        var spot = Annotation(kind: .spotlight, style: ToolStyle(color: Palette.red), at: .zero)
        spot.shape = .box(CGRect(x: 40, y: 40, width: 30, height: 20))
        spot.style.ellipseSpot = true
        var blur = Annotation(kind: .blur, style: ToolStyle(color: Palette.red, intensity: 0.8), at: .zero)
        blur.shape = .box(CGRect(x: 0, y: 0, width: 12, height: 12))
        state.annotations = [arrow, box, pen, counter, text, spot, blur]
        state.outputScale = 0.5
        state.canvasFill = RGBA(0.1, 0.2, 0.3, 0.9)
        state.background = BackgroundSettings(enabled: true, padding: 14, fill: .solid(RGBA(hex: 0x0A84FF)), cornerRadius: 20,
                                              shadow: 0.3, aspect: .sixteenNine, alignment: .bottomRight)
        state.spotlightDim = 0.35
        return state
    }

    func testEditStateRoundTripsThroughJSON() throws {
        let state = Self.richState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.annotations.map(\.id), state.annotations.map(\.id))
        XCTAssertEqual(decoded.annotations.map(\.style), state.annotations.map(\.style))
        XCTAssertEqual(decoded.annotations.first?.note, "Make this button bigger")
        XCTAssertEqual(decoded.spotlightDim, 0.35)

        // The payload keys are named, so the file reads clearly and stays stable.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["\"rect\"", "\"points\"", "\"center\"", "\"p0\"", "\"origin\"", "\"text\""] {
            XCTAssertTrue(json.contains(key), "missing \(key)")
        }
        XCTAssertFalse(json.contains("\"_0\":[["), "an unnamed shape payload")
    }
}
