import XCTest
@testable import Screenme

/// The events sidecar and `report.json` keep the flat JSON events have always had: one object per event, `time`,
/// `kind` and the fields of its kind. Older files also hold `pointer`, which is no longer read.
final class RecordingEventCodingTests: XCTestCase {
    private let fixture = #"""
    {
      "width": 1440, "height": 900,
      "pointer": [[0.5, 10, 20], [0.6, 12, 22]],
      "events": [
        {"time": 1, "kind": "click", "x": 412, "y": 300},
        {"time": 1.5, "kind": "click", "x": 50, "y": 60, "button": "right", "element": "button \"Pay\""},
        {"time": 2, "kind": "drag", "x": 10, "y": 10, "toX": 80, "toY": 10, "until": 3, "element": "slider"},
        {"time": 5, "kind": "scroll", "x": 50, "y": 50, "until": 6.5, "direction": "down"},
        {"time": 7, "kind": "shortcut", "keys": "⌘S"},
        {"time": 8, "kind": "app", "app": "Safari", "window": "Checkout"},
        {"time": 8.5, "kind": "app", "app": "Finder"},
        {"time": 9, "kind": "drawing", "tool": "arrow", "color": "red", "x": 90, "y": 40,
         "box": {"x": 10, "y": 20, "width": 80, "height": 30}},
        {"time": 9.5, "kind": "drawing", "tool": "rectangle", "color": "blue",
         "box": {"x": 100, "y": 120, "width": 40, "height": 20}},
        {"time": 10, "kind": "pin", "number": 2, "x": 300, "y": 200}
      ],
      "windows": [{"time": 0, "windows": [{"app": "Safari", "title": "Checkout", "x": 0, "y": 0, "width": 800, "height": 600}]}]
    }
    """#

    private var expected: RecordingEvents {
        RecordingEvents(width: 1440, height: 900, events: [
            RecordingEvent(time: 1, action: .click(CGPoint(x: 412, y: 300), .left, element: nil)),
            RecordingEvent(time: 1.5, action: .click(CGPoint(x: 50, y: 60), .right, element: "button \"Pay\"")),
            RecordingEvent(time: 2, action: .drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 80, y: 10), until: 3, element: "slider")),
            RecordingEvent(time: 5, action: .scroll(at: CGPoint(x: 50, y: 50), .down, until: 6.5)),
            RecordingEvent(time: 7, action: .shortcut("⌘S")),
            RecordingEvent(time: 8, action: .app("Safari", window: "Checkout")),
            RecordingEvent(time: 8.5, action: .app("Finder", window: nil)),
            RecordingEvent(time: 9, action: .drawing(.arrow, .red, box: RecordingEvent.Box(x: 10, y: 20, width: 80, height: 30),
                                                     tip: CGPoint(x: 90, y: 40))),
            RecordingEvent(time: 9.5, action: .drawing(.rectangle, .blue, box: RecordingEvent.Box(x: 100, y: 120, width: 40, height: 20),
                                                       tip: nil)),
            RecordingEvent(time: 10, action: .pin(2, at: CGPoint(x: 300, y: 200))),
        ], windows: [WindowSnapshot(time: 0, windows: [WindowSnapshot.Window(app: "Safari", title: "Checkout", x: 0, y: 0,
                                                                              width: 800, height: 600)])])
    }

    func testTodaysFlatEventsDecodeToTypedEvents() throws {
        XCTAssertEqual(try JSONDecoder().decode(RecordingEvents.self, from: Data(fixture.utf8)), expected)
    }

    func testTypedEventsWriteTodaysFlatEvents() throws {
        let written = try JSONSerialization.jsonObject(with: expected.json()) as? NSDictionary
        let today = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        XCTAssertEqual(written, today.filter { $0.key != "pointer" } as NSDictionary)
    }

    func testAnEventOfAnUnknownKindDoesNotDecode() {
        let json = #"{"time": 1, "kind": "hover", "x": 1, "y": 2}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RecordingEvent.self, from: Data(json.utf8)))
    }
}
