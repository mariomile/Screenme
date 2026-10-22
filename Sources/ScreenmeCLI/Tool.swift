import Foundation

/// The MCP server's tools. Each call becomes a `Command`, run as the command line runs it.
enum Tool: String, CaseIterable {
    case takeScreenshot = "take_screenshot"
    case getLatestCapture = "get_latest_capture"
    case getLatestReport = "get_latest_report"
    case zoomReport = "zoom_report"
    case inspectReport = "inspect_report"
    case listCaptures = "list_captures"

    /// The arguments of a call, read by type. A value of the wrong type is an error, never a default.
    struct Arguments {
        let values: [String: Any]

        init(_ values: [String: Any]) { self.values = values }

        private func value(_ key: String) -> Any? {
            values[key].flatMap { $0 is NSNull ? nil : $0 }
        }

        /// JSON `true` and `false` arrive as numbers too.
        private static func isBool(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        func string(_ key: String) throws -> String? {
            guard let value = value(key) else { return nil }
            guard let string = value as? String else { throw Command.UsageError("\(key) must be a string") }
            return string
        }

        func number(_ key: String) throws -> Double? {
            guard let value = value(key) else { return nil }
            guard let number = value as? NSNumber, !Self.isBool(number) else { throw Command.UsageError("\(key) must be a number") }
            return number.doubleValue
        }

        /// A whole number, written `2` or `2.0`.
        func integer(_ key: String) throws -> Int? {
            guard let number = try number(key) else { return nil }
            guard let integer = Int(exactly: number) else { throw Command.UsageError("\(key) must be a whole number") }
            return integer
        }

        func bool(_ key: String) throws -> Bool? {
            guard let value = value(key) else { return nil }
            guard let number = value as? NSNumber, Self.isBool(number) else { throw Command.UsageError("\(key) must be true or false") }
            return number.boolValue
        }

        /// A time in seconds, or text as `--at` takes it: a time (`1:05`) or words the user said.
        func moment(_ key: String) throws -> ReportBundle.Moment? {
            if let text = value(key) as? String { return ReportBundle.Moment(at: text) }
            return try number(key).map { .at($0) }
        }
    }

    /// The command a call runs.
    func command(_ arguments: Arguments) throws -> Command {
        switch self {
        case .takeScreenshot:
            switch try arguments.string("mode") {
            case "fullscreen":
                return .capture(.fullscreen)
            case "area":
                guard let x = try arguments.number("x"), let y = try arguments.number("y"),
                      let width = try arguments.number("width"), let height = try arguments.number("height") else {
                    throw Command.UsageError("mode area needs x, y, width and height")
                }
                return .capture(try CaptureRequest.area(x: x, y: y, width: width, height: height).checked())
            case "window":
                guard let app = try arguments.string("app") else { throw Command.UsageError("mode window needs app") }
                return .capture(try CaptureRequest.window(app: app).checked())
            default:
                throw Command.UsageError("mode must be fullscreen, area or window")
            }
        case .getLatestCapture:
            return .latest
        case .getLatestReport:
            return .inspect(bundle: "latest", json: false)
        case .zoomReport:
            let moments: [ReportBundle.Moment?] = [try arguments.moment("at"), try arguments.string("phrase").map { .phrase($0) },
                                                    try arguments.integer("mark").map { .mark($0) }]
            return .zoom(try ZoomRequest(bundle: arguments.string("report") ?? "latest", moments: moments.compactMap { $0 },
                                         span: arguments.number("span"), grid: arguments.string("grid")))
        case .inspectReport:
            return .inspect(bundle: try arguments.string("report") ?? "latest", json: try arguments.bool("json") ?? false)
        case .listCaptures:
            let limit = try arguments.integer("limit") ?? Command.defaultListLimit
            guard limit > 0 else { throw Command.UsageError("limit must be at least 1") }
            return .list(limit: limit)
        }
    }

    /// The tool as `tools/list` describes it.
    var definition: [String: Any] {
        ["name": rawValue, "description": summary, "inputSchema": inputSchema]
    }

    private var summary: String {
        switch self {
        case .takeScreenshot:
            "Take a screenshot with Screenme and return it as an image plus its file path. "
                + "mode fullscreen captures every screen; area captures x, y, width, height in global screen points "
                + "(top-left origin); window captures the frontmost window of app (name or bundle ID)."
        case .getLatestCapture:
            "Return the newest Screenme capture as an image plus its file path."
        case .getLatestReport:
            "Return the newest Screenme Report for AI: a screen recording the user narrated, clicked and drew on "
                + "to show you something. Returns summary.md (each numbered keyframe #N with what they said and did while it was "
                + "on screen, and the paths of the frames, video and report.json) and the contact sheet, every keyframe in one "
                + "image with its #N. Look at the sheet first, then open frames/frame-NN.png for #N; red marks are their drawings. "
                + "Use zoom_report for a closer look at a moment."
        case .zoomReport:
            "A closer look at a moment of a Screenme Report for AI: a grid of frames from its video around a time, "
                + "something the user said, or a mark they drew (\"mark N\" in the summary), returned as an image with the "
                + "time of each cell and what was said. Use it when something moves, happens between keyframes, or a mark is unclear."
        case .inspectReport:
            "Return a Screenme Report for AI: summary.md and the contact sheet, or with json true its report.json manifest "
                + "(keyframes with crops, every word with its time, events, marks and the windows timeline)."
        case .listCaptures:
            "List recent Screenme captures, newest first: one file path per line."
        }
    }

    private var inputSchema: [String: Any] {
        func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return schema
        }
        let report = ["type": "string", "description": "Report folder path, default the latest report"]
        switch self {
        case .takeScreenshot:
            return object([
                "mode": ["type": "string", "enum": ["fullscreen", "area", "window"]],
                "x": ["type": "number"],
                "y": ["type": "number"],
                "width": ["type": "number"],
                "height": ["type": "number"],
                "app": ["type": "string", "description": "App name or bundle ID, for mode window"],
            ], required: ["mode"])
        case .getLatestCapture, .getLatestReport:
            return object([:])
        case .zoomReport:
            return object([
                "report": report,
                "at": ["type": "string", "description": "A time in the video: 1:05, 0:12.5 or 12.5"],
                "phrase": ["type": "string", "description": "Words the user said; the grid centers on when they said them"],
                "mark": ["type": "integer", "minimum": 1, "description": "A mark number from the summary"],
                "span": ["type": "number", "description": "Seconds covered, default 2 (a quarter before the moment)"],
                "grid": ["type": "string", "description": "Columns x rows, default 3x3"],
            ])
        case .inspectReport:
            return object([
                "report": report,
                "json": ["type": "boolean", "description": "Return report.json instead of summary.md"],
            ])
        case .listCaptures:
            return object(["limit": ["type": "integer", "minimum": 1, "description": "How many, default 10"]])
        }
    }
}
