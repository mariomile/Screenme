import Foundation

/// What to capture or record: the screen under the pointer, a rectangle or an app's front window.
enum CaptureRequest: Equatable {
    case fullscreen
    /// Global screen points, top-left origin.
    case area(x: Double, y: Double, width: Double, height: Double)
    /// The frontmost window of an app, by name or bundle ID.
    case window(app: String)

    /// The arguments the app's capture and record_start commands take.
    var arguments: [String: AppCall.Value] {
        switch self {
        case .fullscreen:
            ["mode": .string("fullscreen")]
        case let .area(x, y, width, height):
            ["mode": .string("area"), "x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)]
        case .window(let app):
            ["mode": .string("window"), "app": .string(app)]
        }
    }

    /// The request when it can be taken: an area with a size, a window of a named app.
    func checked() throws -> CaptureRequest {
        switch self {
        case .area(_, _, let width, let height) where !(width > 0 && height > 0):
            throw Command.UsageError("capture area needs a width and height above 0")
        case .window(let app) where app.isEmpty:
            throw Command.UsageError("capture window needs one app name or bundle ID")
        default:
            return self
        }
    }
}

/// A closer look at a moment of a report: `screenme zoom`.
struct ZoomRequest: Equatable {
    var bundle = "latest"
    var moment: ReportBundle.Moment
    var span = 2.0
    var columns = 3
    var rows = 3
}

extension ZoomRequest {
    /// A zoom from what the command line or a tool call gave: exactly one moment, a span from 0 to 60 seconds,
    /// a grid of 1 to 8 columns and rows written `3x3`.
    init(bundle: String, moments: [ReportBundle.Moment], span: Double?, grid: String?) throws {
        guard moments.count == 1, let moment = moments.first else {
            throw Command.UsageError("zoom needs one of --at TIME, --phrase TEXT or --mark N")
        }
        if case .mark(let number) = moment, number < 1 { throw Command.UsageError("--mark needs a mark number") }
        self.init(bundle: bundle, moment: moment)
        if let span {
            guard span > 0, span <= 60 else { throw Command.UsageError("--span needs seconds from 0 to 60, got \(span)") }
            self.span = span
        }
        if let grid {
            let parts = grid.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, (1...8).contains(parts[0]), (1...8).contains(parts[1]) else {
                throw Command.UsageError("--grid needs COLUMNSxROWS, each 1 to 8, like 3x3; got \(grid)")
            }
            (columns, rows) = (parts[0], parts[1])
        }
    }
}

/// A parsed command line.
enum Command: Equatable {
    case capture(CaptureRequest, scrolling: Bool = false)
    case recordStart(CaptureRequest)
    case recordStop(report: Bool)
    case makeReport(path: String)
    case latest
    case list(limit: Int)
    case search(query: String, limit: Int)
    case text(path: String)
    case redact(path: String)
    case upload(path: String)
    case testUpload
    case act(action: String, path: String)
    case settings(key: String?, json: Bool)
    case setSetting(key: String, value: AppCall.Value)
    case windows
    case status
    case zoom(ZoomRequest)
    case frames(bundle: String, from: Double, to: Double, fps: Double)
    case inspect(bundle: String, json: Bool)
    case skill
    case mcp
    case help

    static let defaultListLimit = 10
    static let defaultSearchLimit = 20

    static let usage = """
        Usage (FILE is a capture's path or `latest`, the default):
          screenme capture fullscreen          Capture the screen under the pointer
          screenme capture area X Y W H        Capture a rectangle (screen points, top-left origin)
          screenme capture window APP          Capture the frontmost window of an app (name or bundle ID)
                [--scrolling]                  ... scrolling it to the end into one tall image (needs Accessibility)
          screenme record start [fullscreen | area X Y W H | window APP]   Start recording, with the saved settings
          screenme record stop [--report]      Stop and print the video's path; --report also makes a Report for AI
          screenme report [FILE]               Make a Report for AI from a recording
          screenme latest                      Print the path of the newest capture
          screenme list [--limit N]            Print the paths of recent captures, newest first (default 10)
          screenme search TEXT [--limit N]     Find captures by the text in them, a date or a kind (default 20)
          screenme text [FILE]                 Print the text in a screenshot
          screenme redact [FILE]               Make a copy with emails, keys, cards, IBANs, IPs and faces pixelated
          screenme upload [FILE]               Upload to your bucket (Settings > Upload) and print the public link
          screenme upload --test               Check the upload settings
          screenme act ACTION [FILE]           Do what a Quick Access button does: copy, copy_for_ai, copy_markdown,
                                               save, reveal, edit, pin
          screenme settings [--json]           Every setting with its value, type and allowed values
          screenme settings get KEY            One setting
          screenme settings set KEY VALUE      Change a setting (the upload secret is s3SecretAccessKey)
          screenme windows                     The windows on screen, front to back, with their frames
          screenme status                      Permissions, recording state and folders
          screenme mcp                         Run the MCP server on stdin and stdout
          screenme skill                       Print the agent skill (SKILL.md)

        Reports for AI (REPORT is a report folder or `latest`, the default):
          screenme zoom [REPORT] --at TIME     A grid of frames around a moment, TIME as 1:05, 0:12.5 or 12.5
          screenme zoom [REPORT] --phrase TEXT ... around when the user said TEXT (--at TEXT works too)
          screenme zoom [REPORT] --mark N      ... around when the user drew mark N
                [--span SECONDS] [--grid 3x3]  Seconds covered (default 2, a quarter before) and columns x rows
          screenme frames [REPORT] --from TIME --to TIME [--fps 4]   Plain PNG frames of a stretch
          screenme inspect [REPORT] [--json]   Print summary.md, or report.json with --json

        Captures, recordings, settings and uploads run in the Screenme app, which this tool starts when it is not
        running. It must be allowed to record the screen.
        """

    struct UsageError: Error, Equatable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noCaptures(String)
        case noSkill

        var description: String {
            switch self {
            case .noCaptures(let path): "no captures yet in \(path)"
            case .noSkill: "the skill is not installed: Screenme.app/Contents/Resources/\(Skill.fileName) is missing. Reinstall Screenme."
            }
        }
    }

    /// Parses the arguments after the program name.
    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "capture":
            let scrolling = rest.last == "--scrolling"
            return .capture(try parseCapture(scrolling ? Array(rest.dropLast()) : rest), scrolling: scrolling)
        case "record":
            switch rest.first {
            case "start":
                let target = Array(rest.dropFirst())
                return .recordStart(target.isEmpty ? .fullscreen : try parseCapture(target))
            case "stop":
                let options = Array(rest.dropFirst())
                guard options.isEmpty || options == ["--report"] else { throw UsageError("record stop takes only --report") }
                return .recordStop(report: !options.isEmpty)
            default:
                throw UsageError("record needs start or stop")
            }
        case "report":
            return .makeReport(path: try file(rest, in: "report"))
        case "search":
            var words = rest
            var limit = defaultSearchLimit
            if let index = words.firstIndex(of: "--limit") {
                guard index + 1 < words.count, let value = Int(words[index + 1]), value > 0 else {
                    throw UsageError("--limit needs a positive number")
                }
                limit = value
                words.removeSubrange(index...(index + 1))
            }
            guard !words.isEmpty else { throw UsageError("search needs the text to look for") }
            return .search(query: words.joined(separator: " "), limit: limit)
        case "text":
            return .text(path: try file(rest, in: "text"))
        case "redact":
            return .redact(path: try file(rest, in: "redact"))
        case "upload":
            if rest == ["--test"] { return .testUpload }
            return .upload(path: try file(rest, in: "upload"))
        case "act":
            guard let action = rest.first else { throw UsageError("act needs an action: \(actions.joined(separator: ", "))") }
            guard actions.contains(action) else { throw UsageError("unknown action \(action); use \(actions.joined(separator: ", "))") }
            return .act(action: action, path: try file(Array(rest.dropFirst()), in: "act"))
        case "settings":
            switch rest.first {
            case nil, "--json":
                guard rest.count <= 1 else { throw UsageError("settings takes only --json") }
                return .settings(key: nil, json: !rest.isEmpty)
            case "get":
                guard rest.count == 2 else { throw UsageError("settings get needs one KEY") }
                return .settings(key: rest[1], json: false)
            case "set":
                guard rest.count == 3 else { throw UsageError("settings set needs KEY and VALUE") }
                return .setSetting(key: rest[1], value: .string(rest[2]))
            default:
                throw UsageError("settings takes get KEY, set KEY VALUE or --json")
            }
        case "windows":
            guard rest.isEmpty else { throw UsageError("windows takes no arguments") }
            return .windows
        case "status":
            guard rest.isEmpty else { throw UsageError("status takes no arguments") }
            return .status
        case "latest":
            guard rest.isEmpty else { throw UsageError("latest takes no arguments") }
            return .latest
        case "list":
            if rest.isEmpty { return .list(limit: defaultListLimit) }
            guard rest.count == 2, rest[0] == "--limit" else { throw UsageError("list takes only --limit N") }
            guard let limit = Int(rest[1]), limit > 0 else { throw UsageError("--limit needs a positive number, got \(rest[1])") }
            return .list(limit: limit)
        case "zoom":
            return .zoom(try parseZoom(rest))
        case "frames":
            let (bundle, options) = try bundleAndOptions(rest, flags: [])
            guard let from = options["--from"].flatMap(ReportBundle.parseTime), let to = options["--to"].flatMap(ReportBundle.parseTime) else {
                throw UsageError("frames needs --from TIME and --to TIME")
            }
            guard to >= from else { throw UsageError("--to must not be before --from") }
            let fps = try options["--fps"].map { value in
                guard let fps = Double(value), fps > 0, fps <= 30 else { throw UsageError("--fps needs a number from 0 to 30, got \(value)") }
                return fps
            } ?? 4
            try only(options, ["--from", "--to", "--fps"], in: "frames")
            return .frames(bundle: bundle, from: from, to: to, fps: fps)
        case "inspect":
            let (bundle, options) = try bundleAndOptions(rest, flags: ["--json"])
            try only(options, ["--json"], in: "inspect")
            return .inspect(bundle: bundle, json: options["--json"] != nil)
        case "skill":
            guard rest.isEmpty else { throw UsageError("skill takes no arguments") }
            return .skill
        case "mcp":
            guard rest.isEmpty else { throw UsageError("mcp takes no arguments") }
            return .mcp
        case "help", "-h", "--help":
            return .help
        default:
            throw UsageError("unknown command \(first)")
        }
    }

    /// What `act` can do, as the app names its Quick Access actions.
    static let actions = ["copy", "copy_for_ai", "copy_markdown", "save", "reveal", "edit", "pin"]

    /// The one FILE argument, `latest` when there is none.
    private static func file(_ arguments: [String], in command: String) throws -> String {
        guard arguments.count <= 1 else { throw UsageError("\(command) takes one FILE") }
        return arguments.first ?? "latest"
    }

    private static func parseZoom(_ arguments: [String]) throws -> ZoomRequest {
        let (bundle, options) = try bundleAndOptions(arguments, flags: [])
        try only(options, ["--at", "--phrase", "--mark", "--span", "--grid"], in: "zoom")
        let mark = try options["--mark"].map { value in
            guard let number = Int(value) else { throw UsageError("--mark needs a mark number") }
            return ReportBundle.Moment.mark(number)
        }
        let span = try options["--span"].map { value in
            guard let seconds = Double(value) else { throw UsageError("--span needs seconds from 0 to 60, got \(value)") }
            return seconds
        }
        let moments: [ReportBundle.Moment?] = [options["--at"].map(ReportBundle.Moment.init(at:)), options["--phrase"].map { .phrase($0) }, mark]
        return try ZoomRequest(bundle: bundle, moments: moments.compactMap { $0 }, span: span, grid: options["--grid"])
    }

    /// The report (the first argument when it is not an option, else `latest`) and the options after it.
    /// `flags` are options without a value.
    private static func bundleAndOptions(_ arguments: [String], flags: Set<String>) throws -> (String, [String: String]) {
        var rest = arguments[...]
        var bundle = "latest"
        if let first = rest.first, !first.hasPrefix("--") {
            bundle = first
            rest = rest.dropFirst()
        }
        var options: [String: String] = [:]
        while let name = rest.first {
            rest = rest.dropFirst()
            guard name.hasPrefix("--") else { throw UsageError("unexpected argument \(name)") }
            if flags.contains(name) {
                options[name] = ""
                continue
            }
            guard let value = rest.first else { throw UsageError("\(name) needs a value") }
            options[name] = value
            rest = rest.dropFirst()
        }
        return (bundle, options)
    }

    private static func only(_ options: [String: String], _ allowed: Set<String>, in command: String) throws {
        if let unknown = options.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw UsageError("\(command) does not take \(unknown)")
        }
    }

    private static func parseCapture(_ arguments: [String]) throws -> CaptureRequest {
        switch arguments.first {
        case "fullscreen":
            guard arguments.count == 1 else { throw UsageError("capture fullscreen takes no arguments") }
            return .fullscreen
        case "area":
            let values = arguments.dropFirst().map(Double.init)
            guard values.count == 4, let x = values[0], let y = values[1], let width = values[2], let height = values[3] else {
                throw UsageError("capture area needs four numbers: X Y W H")
            }
            return try CaptureRequest.area(x: x, y: y, width: width, height: height).checked()
        case "window":
            guard arguments.count == 2 else { throw UsageError("capture window needs one app name or bundle ID") }
            return try CaptureRequest.window(app: arguments[1]).checked()
        default:
            throw UsageError("capture needs fullscreen, area X Y W H or window APP")
        }
    }
}

// MARK: Running

extension Command {
    /// Where commands find captures and reports, and how they reach the app: the app's folders and its agent socket
    /// in the tool, a temporary folder and a stub in tests.
    struct Context {
        var folder: CaptureFolder
        var reports: URL
        var app: (AppCall) async throws -> [String: Any]

        static var standard: Context {
            Context(folder: .standard, reports: ScreenmePaths.saveFolder, app: AppChannel.send)
        }
    }

    /// What a command gives back: the text the tool prints, and the images it is about (a capture, a report's
    /// contact sheet, a zoom grid), which the MCP server returns as pictures.
    struct Output: Equatable {
        var text: String
        var images: [URL] = []
    }

    /// Runs the command. `mcp` is the server itself, which `main` runs on stdin; it is not run here.
    func run(_ context: Context) async throws -> Output {
        switch self {
        case .help:
            return Output(text: Self.usage)
        case .capture(let request, let scrolling):
            var arguments = request.arguments
            if scrolling { arguments["scrolling"] = .bool(true) }
            let path = try await context.app(AppCall(command: "capture", arguments: arguments, timeout: scrolling ? 600 : 60))
                .string("path")
            return Output(text: path, images: [URL(fileURLWithPath: path)])
        case .recordStart(let request):
            _ = try await context.app(AppCall(command: "record_start", arguments: request.arguments))
            return Output(text: "Recording. Stop it with: screenme record stop")
        case .recordStop(let report):
            let result = try await context.app(AppCall(command: "record_stop", arguments: ["report": .bool(report)], timeout: report ? 900 : 300))
            return Self.recording(result)
        case .makeReport(let path):
            let result = try await context.app(AppCall(command: "make_report", arguments: ["path": .string(try resolve(path, context))], timeout: 900))
            return Self.recording(result)
        case .latest:
            guard let latest = context.folder.latest else { throw Failure.noCaptures(context.folder.url.path) }
            return Output(text: latest.url.path, images: [latest.url])
        case .list(let limit):
            return Output(text: context.folder.captures().prefix(limit).map(\.url.path).joined(separator: "\n"))
        case .search(let query, let limit):
            let results = try await context.app(AppCall(command: "search_history", arguments: ["query": .string(query), "limit": .number(Double(limit))]))
            let found = results["results"] as? [[String: Any]] ?? []
            return Output(text: found.map { entry in
                let path = entry["path"] as? String ?? ""
                return (entry["excerpt"] as? String).map { "\(path)\n    \($0)" } ?? path
            }.joined(separator: "\n"))
        case .text(let path):
            let result = try await context.app(AppCall(command: "recognize_text", arguments: ["path": .string(try resolve(path, context))]))
            return Output(text: try result.string("text"))
        case .redact(let path):
            let result = try await context.app(AppCall(command: "redact", arguments: ["path": .string(try resolve(path, context))]))
            let copy = try result.string("path")
            let hidden = result["hidden"] as? Int ?? 0
            return Output(text: hidden > 0 ? "\(copy)\n\(hidden) hidden" : "\(copy)\nNothing sensitive found", images: [URL(fileURLWithPath: copy)])
        case .upload(let path):
            let result = try await context.app(AppCall(command: "upload", arguments: ["path": .string(try resolve(path, context))], timeout: 600))
            let hidden = result["hidden"] as? Int ?? 0
            return Output(text: try result.string("url") + (hidden > 0 ? "\n\(hidden) hidden in the uploaded copy" : ""))
        case .testUpload:
            _ = try await context.app(AppCall(command: "test_upload"))
            return Output(text: "Upload works: a test file went up to the bucket and was deleted.")
        case .act(let action, let path):
            let result = try await context.app(AppCall(command: "act", arguments: ["action": .string(action), "path": .string(try resolve(path, context))]))
            return Output(text: result["done"] as? Bool == true ? "Done." : "It did not happen.")
        case .settings(let key, let json):
            let settings = try await context.app(AppCall(command: "settings"))["settings"] as? [[String: Any]] ?? []
            if let key {
                guard let setting = settings.first(where: { $0["key"] as? String == key }) else {
                    throw UsageError("unknown setting \(key); `screenme settings` lists them")
                }
                return Output(text: Self.json(setting))
            }
            return Output(text: json ? Self.json(settings) : Self.settingsText(settings))
        case .setSetting(let key, let value):
            let result = try await context.app(AppCall(command: "set_setting", arguments: ["key": .string(key), "value": value]))
            return Output(text: "\(key) = \(Self.describe(result["value"] as Any))")
        case .windows:
            let windows = try await context.app(AppCall(command: "list_windows"))["windows"] as? [[String: Any]] ?? []
            return Output(text: windows.map { window in
                let frame = ["x", "y", "width", "height"].map { Self.describe(window[$0] as Any) }
                let title = (window["title"] as? String).flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
                return "\(window["app"] as? String ?? "")\(title)  (\(frame[0]), \(frame[1]), \(frame[2]) x \(frame[3]))"
            }.joined(separator: "\n"))
        case .status:
            return Output(text: Self.json(try await context.app(AppCall(command: "status"))))
        case .zoom(let request):
            let zoom = try await ReportBundle.open(request.bundle, reports: context.reports)
                .zoom(request.moment, span: request.span, columns: request.columns, rows: request.rows)
            return Output(text: zoom.text, images: [zoom.image])
        case .frames(let bundle, let from, let to, let fps):
            let files = try await ReportBundle.open(bundle, reports: context.reports).frames(from: from, to: to, fps: fps)
            return Output(text: files.map(\.path).joined(separator: "\n"))
        case .inspect(let bundle, let json):
            let report = try ReportBundle.open(bundle, reports: context.reports)
            return json ? Output(text: try report.manifestText) : Output(text: try report.summary, images: [report.contactSheet])
        case .skill:
            guard let url = Skill.url(), let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.noSkill }
            return Output(text: text)
        case .mcp:
            throw UsageError("mcp is the MCP server: it reads requests on stdin and has no output of its own")
        }
    }

    /// A path as given, with `latest` replaced by the newest capture.
    private func resolve(_ path: String, _ context: Context) throws -> String {
        guard path == "latest" else { return path }
        guard let latest = context.folder.latest else { throw Failure.noCaptures(context.folder.url.path) }
        return latest.url.path
    }

    /// A recording's path, and its report's folder, summary and contact sheet when it has one.
    private static func recording(_ result: [String: Any]) -> Output {
        var lines = [result["path"] as? String].compactMap { $0 }
        var images: [URL] = []
        if let folder = result["report"] as? String {
            lines.append("Report for AI: \(folder)")
            if let summary = result["summary"] as? String { lines.append("\n" + summary) }
            images.append(URL(fileURLWithPath: folder).appendingPathComponent(ReportLayout.contactSheet))
        }
        if let error = result["report_error"] as? String { lines.append("No Report for AI: \(error)") }
        return Output(text: lines.joined(separator: "\n"), images: images)
    }

    /// Settings grouped by section: `key = value` with what it takes and what it does.
    private static func settingsText(_ settings: [[String: Any]]) -> String {
        var lines: [String] = []
        var section = ""
        for setting in settings {
            if let name = setting["section"] as? String, name != section {
                section = name
                lines.append((lines.isEmpty ? "" : "\n") + name)
            }
            var takes = setting["type"] as? String ?? ""
            if let options = setting["options"] as? [Any] { takes = options.map { describe($0) }.joined(separator: " | ") }
            if let range = setting["range"] as? [Any], range.count == 2 { takes = "\(describe(range[0])) to \(describe(range[1]))" }
            lines.append("  \(setting["key"] as? String ?? "") = \(describe(setting["value"] as Any))   [\(takes)]  \(setting["description"] as? String ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    /// A JSON value as one line: 3 rather than 3.0, true rather than 1.
    static func describe(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15 ? String(Int(double)) : String(double)
        }
        if let string = value as? String { return string.isEmpty ? "\"\"" : string }
        return "\(value)"
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Dictionary where Key == String, Value == Any {
    /// A text field of the app's reply, which the command needs.
    func string(_ key: String) throws -> String {
        guard let value = self[key] as? String else { throw AppChannel.Failure.refused("Screenme's reply has no \(key)") }
        return value
    }
}
