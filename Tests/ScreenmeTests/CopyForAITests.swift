import XCTest
@testable import Screenme

/// Copy for AI: the text next to the image, and the notes the editor lists.
@MainActor
final class CopyForAITests: PrefsSandboxTestCase {
    func testPromptListsContextNotesAndText() {
        let context = CaptureContext(app: "Safari", bundleID: "com.apple.Safari", window: "Pricing", page: "https://example.com/pricing",
                                     notes: ["Marker 1: make this bold", "Arrow at the top left: wrong color"])
        let prompt = context.prompt(path: "/tmp/shot.png", pixelSize: CGSize(width: 1440, height: 900), text: "  Pro plan\n$20  ")
        XCTAssertEqual(prompt, """
        Screenshot: /tmp/shot.png (1440×900 px)
        App: Safari
        Window: Pricing
        Page: https://example.com/pricing

        Notes on the screenshot:
        1. Marker 1: make this bold
        2. Arrow at the top left: wrong color

        Text in the screenshot:
        \"\"\"
        Pro plan
        $20
        \"\"\"
        """)
    }

    func testPromptWithNothingKnownIsJustTheFile() {
        XCTAssertEqual(CaptureContext().prompt(path: "/tmp/a.png", pixelSize: CGSize(width: 10, height: 20), text: " \n"),
                       "Screenshot: /tmp/a.png (10×20 px)")
    }

    func testNotesNameMarkersByNumberAndOtherShapesByPlace() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let controller = EditorController(item: CaptureItem(url: URL(fileURLWithPath: "/tmp/x.png"), kind: .image),
                                          source: ImageSource(image: image, unit: 1))
        func add(_ kind: ToolKind, at point: CGPoint, note: String) {
            var annotation = Annotation(kind: kind, style: kind.traits.style, at: point)
            if kind == .rectangle { annotation.shape = .box(CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)) }
            annotation.note = note
            controller.perform { $0.annotations.append(annotation) }
        }
        add(.counter, at: CGPoint(x: 20, y: 20), note: "")
        add(.counter, at: CGPoint(x: 150, y: 150), note: " bigger ")
        add(.rectangle, at: CGPoint(x: 270, y: 30), note: "wrong color")
        add(.rectangle, at: CGPoint(x: 150, y: 150), note: "center thing")
        add(.rectangle, at: CGPoint(x: 30, y: 280), note: "")
        XCTAssertEqual(controller.notes, ["Marker 2: bigger",
                                          "\(ToolKind.rectangle.traits.title) at the top right: wrong color",
                                          "\(ToolKind.rectangle.traits.title) at the center: center thing"])
    }
}
