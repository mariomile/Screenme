import Foundation

/// The MCP server's tools. Each call becomes a `Command`, run as the command line runs it.
enum Tool: String, CaseIterable {
    case takeScreenshot = "take_screenshot"
    case getLatestCapture = "get_latest_capture"
    case listCaptures = "list_captures"
    case searchCaptures = "search_captures"
    case readText = "read_text"
    case redactCapture = "redact_capture"
    case uploadCapture = "upload_capture"
    case testUpload = "test_upload"
    case captureAction = "capture_action"
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case makeReport = "make_report"
    case getLatestReport = "get_latest_report"
    case zoomReport = "zoom_report"
    case inspectReport = "inspect_report"
    case getSettings = "get_settings"
    case setSetting = "set_setting"
    case listWindows = "list_windows"
    case getStatus = "get_status"

    /// The command a call runs.
    func command(_ arguments: AgentArguments) throws -> Command {
        let file = try arguments.string("path") ?? "latest"
        switch self {
        case .takeScreenshot:
            return .capture(try target(arguments), scrolling: try arguments.bool("scrolling") ?? false)
        case .getLatestCapture:
            return .latest
        case .listCaptures:
            let limit = try arguments.integer("limit") ?? Command.defaultListLimit
            guard limit > 0 else { throw Command.UsageError("limit must be at least 1") }
            return .list(limit: limit)
        case .searchCaptures:
            guard let query = try arguments.string("query"), !query.isEmpty else { throw Command.UsageError("search_captures needs query") }
            let limit = try arguments.integer("limit") ?? Command.defaultSearchLimit
            guard limit > 0 else { throw Command.UsageError("limit must be at least 1") }
            return .search(query: query, limit: limit)
        case .readText:
            return .text(path: file)
        case .redactCapture:
            return .redact(path: file)
        case .uploadCapture:
            return .upload(path: file)
        case .testUpload:
            return .testUpload
        case .captureAction:
            guard let action = try arguments.string("action"), Command.actions.contains(action) else {
                throw Command.UsageError("action must be one of \(Command.actions.joined(separator: ", "))")
            }
            return .act(action: action, path: file)
        case .startRecording:
            return .recordStart(try target(arguments))
        case .stopRecording:
            return .recordStop(report: try arguments.bool("report") ?? false)
        case .makeReport:
            return .makeReport(path: file)
        case .getLatestReport:
            return .inspect(bundle: "latest", json: false)
        case .zoomReport:
            let moments: [ReportBundle.Moment?] = [try arguments.moment("at"), try arguments.string("phrase").map { .phrase($0) },
                                                    try arguments.integer("mark").map { .mark($0) }]
            return .zoom(try ZoomRequest(bundle: arguments.string("report") ?? "latest", moments: moments.compactMap { $0 },
                                         span: arguments.number("span"), grid: arguments.string("grid")))
        case .inspectReport:
            return .inspect(bundle: try arguments.string("report") ?? "latest", json: try arguments.bool("json") ?? false)
        case .getSettings:
            return .settings(key: try arguments.string("key"), json: true)
        case .setSetting:
            guard let key = try arguments.string("key") else { throw Command.UsageError("set_setting needs key") }
            guard let raw = arguments.value("value"), let value = AppCall.Value(json: raw) else {
                throw Command.UsageError("set_setting needs value: text, a number or true and false")
            }
            return .setSetting(key: key, value: value)
        case .listWindows:
            return .windows
        case .getStatus:
            return .status
        }
    }

    /// The screen, rectangle or window a screenshot or recording takes; the screen under the pointer by default.
    private func target(_ arguments: AgentArguments) throws -> CaptureRequest {
        switch try arguments.string("mode") ?? "fullscreen" {
        case "fullscreen":
            return .fullscreen
        case "area":
            guard let x = try arguments.number("x"), let y = try arguments.number("y"),
                  let width = try arguments.number("width"), let height = try arguments.number("height") else {
                throw Command.UsageError("mode area needs x, y, width and height")
            }
            return try CaptureRequest.area(x: x, y: y, width: width, height: height).checked()
        case "window":
            guard let app = try arguments.string("app") else { throw Command.UsageError("mode window needs app") }
            return try CaptureRequest.window(app: app).checked()
        default:
            throw Command.UsageError("mode must be fullscreen, area or window")
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
                + "mode fullscreen captures the screen under the pointer; area captures x, y, width, height in global screen points "
                + "(top-left origin); window captures the frontmost window of app (name or bundle ID; list_windows shows them). "
                + "scrolling true scrolls the area or window to its end and stitches one tall image (needs Accessibility; it moves the pointer)."
        case .getLatestCapture:
            "Return the newest Screenme capture as an image plus its file path."
        case .listCaptures:
            "List recent Screenme captures, newest first: one file path per line."
        case .searchCaptures:
            "Find captures in Screenme's History by the text in them (recognized on this Mac), a date like 2026-10-22 or yesterday, "
                + "or a kind (screenshot, recording, gif). Returns paths, newest first, with the matching text."
        case .readText:
            "Return the text in a screenshot, recognized on this Mac (QR codes too). path defaults to the newest capture."
        case .redactCapture:
            "Make a copy of a screenshot with emails, phone numbers, cards, IBANs, keys, IP addresses and faces pixelated. "
                + "Returns the copy as an image and its path; the original is untouched."
        case .uploadCapture:
            "Upload a capture to the user's own S3-compatible bucket (Settings > Upload) and return its public link. "
                + "When the hide-sensitive-info setting is on, a screenshot goes up as its redacted copy (GIFs and videos as they are). "
                + "The link is public: upload only what the user wants shared."
        case .testUpload:
            "Check the upload settings: puts a tiny test file in the bucket and deletes it."
        case .captureAction:
            "Do what a Quick Access button does with a capture, on the user's Mac: copy (clipboard), copy_for_ai (image with its "
                + "context), copy_markdown, save (to the save folder), reveal (in Finder), edit (opens the editor for the user), pin (floats it on screen)."
        case .startRecording:
            "Start a screen recording with the saved recording settings (microphone, system audio, camera, clicks, keys): "
                + "mode fullscreen, area or window as for take_screenshot. Stop it with stop_recording."
        case .stopRecording:
            "Stop the screen recording and return the video's path. report true also makes a Report for AI from it "
                + "(transcript, keyframes, contact sheet) and returns its folder, summary and contact sheet."
        case .makeReport:
            "Make a Report for AI from a recording (path, default the newest capture): keyframes with what was said and done, "
                + "a contact sheet and summary.md. Returns the folder, the summary and the contact sheet."
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
        case .getSettings:
            "Return Screenme's settings as JSON: each with its key, value, default, type, allowed options and description. "
                + "key returns one setting."
        case .setSetting:
            "Change a Screenme setting, as the Settings window would. Use the keys get_settings returns; value as text, a number "
                + "or true/false. s3SecretAccessKey stores the upload secret in the Keychain."
        case .listWindows:
            "List the windows on screen, front to back: app, title and frame in global screen points, for take_screenshot."
        case .getStatus:
            "Return Screenme's state: permissions (Screen Recording, Accessibility, Microphone, Camera), whether it is "
                + "recording, its folders and whether upload is set up."
        }
    }

    private var inputSchema: [String: Any] {
        func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return schema
        }
        let report = ["type": "string", "description": "Report folder path, default the latest report"]
        let path = ["type": "string", "description": "Path of a capture, default the newest"]
        let target: [String: Any] = [
            "mode": ["type": "string", "enum": ["fullscreen", "area", "window"], "description": "Default fullscreen"],
            "x": ["type": "number"],
            "y": ["type": "number"],
            "width": ["type": "number"],
            "height": ["type": "number"],
            "app": ["type": "string", "description": "App name or bundle ID, for mode window"],
        ]
        switch self {
        case .takeScreenshot:
            return object(target.merging(["scrolling": ["type": "boolean", "description": "Scroll to the end and stitch one tall image"]]) { $1 })
        case .startRecording:
            return object(target)
        case .getLatestCapture, .getLatestReport, .testUpload, .listWindows, .getStatus:
            return object([:])
        case .listCaptures:
            return object(["limit": ["type": "integer", "minimum": 1, "description": "How many, default 10"]])
        case .searchCaptures:
            return object(["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "description": "How many, default 20"]],
                          required: ["query"])
        case .readText, .redactCapture, .uploadCapture, .makeReport:
            return object(["path": path])
        case .captureAction:
            return object(["action": ["type": "string", "enum": Command.actions], "path": path], required: ["action"])
        case .stopRecording:
            return object(["report": ["type": "boolean", "description": "Also make a Report for AI"]])
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
        case .getSettings:
            return object(["key": ["type": "string", "description": "One setting; all when left out"]])
        case .setSetting:
            return object(["key": ["type": "string"], "value": ["type": ["string", "number", "boolean"]]], required: ["key", "value"])
        }
    }
}

extension AgentArguments {
    /// A time in seconds, or text as `--at` takes it: a time (`1:05`) or words the user said.
    func moment(_ key: String) throws -> ReportBundle.Moment? {
        if let text = value(key) as? String { return ReportBundle.Moment(at: text) }
        return try number(key).map { .at($0) }
    }
}
