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

/// A parsed command line.
enum Command: Equatable {
    case capture(CaptureRequest)
    case latest
    case list(limit: Int)
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

        Captures run in the Screenme app, which must be installed and allowed to record the screen.
        `capture` prints the path of the new file.
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
        case "mcp":
            guard rest.isEmpty else { throw UsageError("mcp takes no arguments") }
            return .mcp
        case "help", "-h", "--help":
            return .help
        default:
            throw UsageError("unknown command \(first)")
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
