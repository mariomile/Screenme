import XCTest
@testable import Screenme

/// Annotations stay editable after Done: the document is saved as JSON next to the capture and comes back intact.
final class EditSidecarTests: PrefsSandboxTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// A small opaque PNG standing in for a capture.
    private func capture() throws -> URL {
        let url = folder.appendingPathComponent("Screenshot.png")
        let image = try XCTUnwrap(CGImage.drawn(width: 40, height: 30, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        })
        let data = try XCTUnwrap(FlattenedImage(image: image, type: .png, dpi: 72, jpegQuality: 0.9, name: url.lastPathComponent).encoded())
        try data.write(to: url)
        return url
    }

    @MainActor private func addBox(_ controller: EditorController, at x: CGFloat) {
        controller.perform { state in
            var box = Annotation(kind: .rectangle, style: ToolStyle(color: Palette.red), at: CGPoint(x: x, y: 2))
            box.shape = .box(CGRect(x: x, y: 2, width: 10, height: 8))
            state.annotations.append(box)
        }
    }

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

    @MainActor
    func testDoneKeepsTheOriginalOnceAndRewritesTheDocument() throws {
        let url = try capture()
        let captured = try Data(contentsOf: url)
        let controller = EditorController(item: CaptureItem(url: url, kind: .image), source: try XCTUnwrap(ImageSource.load(url: url)))
        addBox(controller, at: 2)

        XCTAssertTrue(controller.writeToCapture())
        XCTAssertEqual(try Data(contentsOf: EditSidecar.originalURL(for: url)), captured)
        XCTAssertNotEqual(try Data(contentsOf: url), captured, "the capture holds the flattened annotations")
        XCTAssertEqual(EditSidecar.load(for: url)?.state, controller.state)
        XCTAssertEqual(Sidecar.edit.url(for: url).lastPathComponent, ".Screenshot.png.screenme-edit")

        addBox(controller, at: 20)
        XCTAssertTrue(controller.writeToCapture())
        XCTAssertEqual(try Data(contentsOf: EditSidecar.originalURL(for: url)), captured, "a second Done keeps the original")
        XCTAssertEqual(EditSidecar.load(for: url)?.state.annotations.count, 2)
    }

    @MainActor
    func testReopeningASavedCaptureBringsBackTheAnnotationsOverTheOriginal() throws {
        let url = try capture()
        let item = CaptureItem(url: url, kind: .image)
        let first = try XCTUnwrap(AnnotationEditor.controller(for: item))
        XCTAssertFalse(first.reopened)
        addBox(first, at: 2)
        first.perform { $0.cropRect = CGRect(x: 1, y: 1, width: 30, height: 20) }
        XCTAssertTrue(first.writeToCapture())

        let reopened = try XCTUnwrap(AnnotationEditor.controller(for: item))
        XCTAssertTrue(reopened.reopened)
        XCTAssertEqual(reopened.state, first.state)
        XCTAssertFalse(reopened.isDirty, "a reopened document has nothing to save yet")
        // The source is the original, not the flattened crop the capture file now holds.
        XCTAssertEqual(reopened.source.size, CGSize(width: 40, height: 30))
        XCTAssertEqual(try XCTUnwrap(ImageSource.load(url: url)).size, CGSize(width: 30, height: 20))
    }

    @MainActor
    func testACaptureNeverSavedFromTheEditorOpensAsToday() throws {
        let controller = try XCTUnwrap(AnnotationEditor.controller(for: CaptureItem(url: try capture(), kind: .image)))
        XCTAssertFalse(controller.reopened)
        XCTAssertTrue(controller.state.annotations.isEmpty)
        XCTAssertEqual(controller.state.cropRect, CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    // MARK: Format

    /// Removes `keys` from every object in the JSON, the way a file written before those fields existed looks.
    private func dropping(_ keys: Set<String>, from data: Data) throws -> Data {
        func strip(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.filter { !keys.contains($0.key) }.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: strip(JSONSerialization.jsonObject(with: data)))
    }

    func testAFileWithoutFieldsAddedLaterStillLoadsWithTheirDefaults() throws {
        let state = Self.richState()
        let data = try JSONEncoder().encode(EditDocument(state: state))
        let optional: Set<String> = ["id", "note", "outputScale", "canvasFill", "background", "spotlightDim",
                                     "sizeIndex", "filled", "curved", "fontSize", "weight", "backdrop", "intensity", "ellipseSpot"]

        let decoded = try JSONDecoder().decode(EditDocument.self, from: try dropping(optional, from: data))

        let defaults = EditState(cropRect: state.cropRect)
        XCTAssertEqual(decoded.version, EditDocument.currentVersion)
        XCTAssertEqual(decoded.state.annotations.map(\.shape), state.annotations.map(\.shape))
        XCTAssertEqual(decoded.state.annotations.map(\.style.color), state.annotations.map(\.style.color))
        XCTAssertEqual(decoded.state.annotations.map(\.note), Array(repeating: "", count: state.annotations.count))
        XCTAssertEqual(decoded.state.annotations.first?.style.fontSize, ToolStyle(color: Palette.red).fontSize)
        XCTAssertEqual(decoded.state.outputScale, defaults.outputScale)
        XCTAssertEqual(decoded.state.background, defaults.background)
        XCTAssertEqual(decoded.state.spotlightDim, defaults.spotlightDim)
    }

    func testAFileFromBeforeTheVersionReadsAsVersionZero() throws {
        let state = Self.richState()
        let decoded = try JSONDecoder().decode(EditDocument.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(decoded.version, 0)
        XCTAssertEqual(decoded.state, state)
    }

    // MARK: Writing and failing

    /// The sidecar is written before the capture: when the capture is written, the original holds the pixels
    /// as captured and the document is already the new one.
    @MainActor
    func testDoneWritesTheSidecarFirstAndTheCaptureLast() throws {
        let url = try capture()
        let captured = try Data(contentsOf: url)
        var state = EditState(cropRect: CGRect(x: 0, y: 0, width: 40, height: 30))
        state.spotlightDim = 0.2
        var captureWritten = false

        try EditSidecar.save(state, flattened: Data("flat".utf8), to: url) { data, capture in
            XCTAssertEqual(try Data(contentsOf: EditSidecar.originalURL(for: capture)), captured)
            XCTAssertEqual(EditSidecar.load(for: capture)?.state, state)
            try data.write(to: capture, options: .atomic)
            captureWritten = true
        }

        XCTAssertTrue(captureWritten)
        XCTAssertEqual(try Data(contentsOf: url), Data("flat".utf8))
    }

    /// A capture that cannot be written fails Done, and the sidecar keeps the newer document: nothing is lost.
    @MainActor
    func testACaptureThatFailsToWriteKeepsTheNewerDocument() throws {
        let url = try capture()
        let captured = try Data(contentsOf: url)
        let state = EditState(cropRect: CGRect(x: 1, y: 1, width: 20, height: 20))
        struct Failed: Error {}

        XCTAssertThrowsError(try EditSidecar.save(state, flattened: Data(), to: url) { _, _ in throw Failed() })

        XCTAssertEqual(try Data(contentsOf: url), captured)
        XCTAssertEqual(EditSidecar.load(for: url)?.state, state)
    }

    /// A document that does not decode moves the whole sidecar aside, and the flattened capture opens.
    @MainActor
    func testAnUnreadableSidecarIsSetAsideAndTheFlattenedCaptureOpens() throws {
        let url = try capture()
        let first = try XCTUnwrap(AnnotationEditor.controller(for: CaptureItem(url: url, kind: .image)))
        addBox(first, at: 2)
        first.perform { $0.cropRect = CGRect(x: 1, y: 1, width: 30, height: 20) }
        XCTAssertTrue(first.writeToCapture())
        try Data("{ not json".utf8).write(to: EditSidecar.documentURL(for: url))

        let reopened = try XCTUnwrap(AnnotationEditor.controller(for: CaptureItem(url: url, kind: .image)))

        XCTAssertFalse(reopened.reopened)
        XCTAssertEqual(reopened.source.size, CGSize(width: 30, height: 20), "the flattened capture, not the original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.edit.url(for: url).path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertTrue(try XCTUnwrap(aside.first).hasPrefix(".Screenshot.png.screenme-edit.unreadable-"))
        let kept = folder.appendingPathComponent(try XCTUnwrap(aside.first))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: kept.path)), ["original.png", "edit.json"])

        // The next Done starts a new sidecar from the flattened pixels.
        addBox(reopened, at: 4)
        XCTAssertTrue(reopened.writeToCapture())
        XCTAssertEqual(EditSidecar.load(for: url)?.state.annotations.count, 1)
    }
}
