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
}

/// A closer look at a moment of a report: `screenme zoom`.
struct ZoomRequest: Equatable {
    var bundle = "latest"
    var moment: ReportBundle.Moment
    var span = 2.0
    var columns = 3
    var rows = 3
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
        let moments = ["--at", "--phrase", "--mark"].filter { options[$0] != nil }
        guard moments.count == 1 else { throw UsageError("zoom needs one of --at TIME, --phrase TEXT or --mark N") }
        var request: ZoomRequest
        if let at = options["--at"] {
            // --at takes a phrase too, like the summary's "zoom --at" examples an agent may adapt.
            request = ZoomRequest(bundle: bundle, moment: ReportBundle.parseTime(at).map { .at($0) } ?? .phrase(at))
        } else if let phrase = options["--phrase"] {
            request = ZoomRequest(bundle: bundle, moment: .phrase(phrase))
        } else {
            guard let mark = options["--mark"].flatMap(Int.init), mark > 0 else { throw UsageError("--mark needs a mark number") }
            request = ZoomRequest(bundle: bundle, moment: .mark(mark))
        }
        if let span = options["--span"] {
            guard let value = Double(span), value > 0, value <= 60 else { throw UsageError("--span needs seconds from 0 to 60, got \(span)") }
            request.span = value
        }
        if let grid = options["--grid"] {
            let parts = grid.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, (1...8).contains(parts[0]), (1...8).contains(parts[1]) else {
                throw UsageError("--grid needs COLUMNSxROWS, each 1 to 8, like 3x3; got \(grid)")
            }
            (request.columns, request.rows) = (parts[0], parts[1])
        }
        return request
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
            guard width > 0, height > 0 else { throw UsageError("capture area needs a width and height above 0") }
            return .area(x: x, y: y, width: width, height: height)
        case "window":
            guard arguments.count == 2, !arguments[1].isEmpty else { throw UsageError("capture window needs one app name or bundle ID") }
            return .window(app: arguments[1])
        default:
            throw UsageError("capture needs fullscreen, area X Y W H or window APP")
        }
    }
}
