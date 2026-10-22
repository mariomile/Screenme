import Foundation

/// What to capture, named the way `screenme://` links name it.
enum CaptureRequest: Equatable {
    case fullscreen
    /// Global screen points, top-left origin.
    case area(x: Double, y: Double, width: Double, height: Double)
    /// The frontmost window of an app, by name or bundle ID.
    case window(app: String)

    /// The link the running app performs.
    var link: URL {
        var components = URLComponents()
        components.scheme = "screenme"
        switch self {
        case .fullscreen:
            components.host = "capture-fullscreen"
        case let .area(x, y, width, height):
            components.host = "capture-area"
            components.queryItems = [("x", x), ("y", y), ("width", width), ("height", height)]
                .map { URLQueryItem(name: $0.0, value: Self.format($0.1)) }
        case .window(let app):
            components.host = "capture-window"
            components.queryItems = [URLQueryItem(name: "app", value: app)]
        }
        return components.url!
    }

    /// 100 rather than 100.0, so links read like the ones in the README.
    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
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
    case capture(CaptureRequest)
    case latest
    case list(limit: Int)
    case zoom(ZoomRequest)
    case frames(bundle: String, from: Double, to: Double, fps: Double)
    case inspect(bundle: String, json: Bool)
    case skill
    case mcp
    case help

    static let defaultListLimit = 10

    static let usage = """
        Usage:
          screenme capture fullscreen          Capture every screen
          screenme capture area X Y W H        Capture a rectangle (screen points, top-left origin)
          screenme capture window APP          Capture the frontmost window of an app (name or bundle ID)
          screenme latest                      Print the path of the newest capture
          screenme list [--limit N]            Print the paths of recent captures, newest first (default 10)
          screenme mcp                         Run the MCP server on stdin and stdout
          screenme skill                       Print the agent skill for reading reports (SKILL.md)

        Reports for AI (REPORT is a report folder or `latest`, the default):
          screenme zoom [REPORT] --at TIME     A grid of frames around a moment, TIME as 1:05, 0:12.5 or 12.5
          screenme zoom [REPORT] --phrase TEXT ... around when the user said TEXT (--at TEXT works too)
          screenme zoom [REPORT] --mark N      ... around when the user drew mark N
                [--span SECONDS] [--grid 3x3]  Seconds covered (default 2, a quarter before) and columns x rows
          screenme frames [REPORT] --from TIME --to TIME [--fps 4]   Plain PNG frames of a stretch
          screenme inspect [REPORT] [--json]   Print summary.md, or report.json with --json

        Captures run in the Screenme app, which must be installed and allowed to record the screen.
        `capture` prints the path of the new file; `zoom` and `frames` print the paths of the PNGs they write
        into the report's zoom folder.
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
            return .capture(try parseCapture(rest))
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
    /// Where commands find captures and reports, and how they take a capture: the app's folders and the running
    /// app in the tool, a temporary folder and a stub in tests.
    struct Context {
        var folder: CaptureFolder
        var reports: URL
        var capture: (CaptureRequest) async throws -> URL

        static var standard: Context {
            Context(folder: .standard, reports: ScreenmePaths.saveFolder) { try await CaptureFolder.standard.take($0) }
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
        case .capture(let request):
            let file = try await context.capture(request)
            return Output(text: file.path, images: [file])
        case .latest:
            guard let latest = context.folder.latest else { throw Failure.noCaptures(context.folder.url.path) }
            return Output(text: latest.url.path, images: [latest.url])
        case .list(let limit):
            return Output(text: context.folder.captures().prefix(limit).map(\.url.path).joined(separator: "\n"))
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
}
