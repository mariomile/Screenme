import Foundation

/// The local channel between the `screenme` tool and the running app. Whatever needs the app (its Screen Recording
/// permission, its settings, its Keychain item, its windows) goes through it; everything else the tool does itself.
///
/// The app listens on a Unix socket in its Application Support folder, readable by this user only, so a web page
/// cannot reach it the way it can open a `screenme://` link. One connection carries one exchange: the tool writes a
/// request, the app writes the reply, the tool closes the connection once it has read it. Each is one JSON object on
/// one line, ending with a line break, so neither side waits for the other to close to know a message is whole:
///
///     {"command": "capture", "arguments": {"mode": "window", "app": "Safari"}, "timeout": 60}
///     {"result": {"path": "/Users/…/Screenme 2026-10-23 at 10.12.40.png"}}
///     {"error": "No window of Safari is on screen"}
enum AgentChannel {
    /// `~/Library/Application Support/Screenme/agent.sock`. A Unix socket path has to stay under 104 bytes.
    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenme/agent.sock")
    }

    struct Request {
        let command: String
        let arguments: [String: Any]
        /// Seconds the tool waits for the reply. The app stops the work a little before, so the tool hears why
        /// instead of giving up while the work goes on.
        var timeout: TimeInterval?
    }

    /// A reply is a result or an error, never both.
    enum Reply {
        case result([String: Any])
        case error(String)
    }

    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    /// The byte that ends a message. JSON written on one line holds no raw line break.
    static let endOfMessage = UInt8(ascii: "\n")

    /// The first whole message in `buffer`, without its line break; nil while it is still arriving.
    static func message(in buffer: Data) -> Data? {
        buffer.firstIndex(of: endOfMessage).map { buffer[buffer.startIndex..<$0] }
    }

    static func encode(_ request: Request) throws -> Data {
        var object: [String: Any] = ["command": request.command, "arguments": request.arguments]
        if let timeout = request.timeout { object["timeout"] = timeout }
        return try JSONSerialization.data(withJSONObject: object) + [endOfMessage]
    }

    static func decodeRequest(_ data: Data) throws -> Request {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            throw FormatError(description: "the request is not a JSON object with a command")
        }
        let timeout = (object["timeout"] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
        return Request(command: command, arguments: object["arguments"] as? [String: Any] ?? [:], timeout: timeout)
    }

    static func encode(_ reply: Reply) -> Data {
        let object: [String: Any] = switch reply {
        case .result(let result): ["result": result]
        case .error(let message): ["error": message]
        }
        // A result the app built is always serializable; an error message stands in if one ever is not.
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"error":"the reply could not be written as JSON"}"#.utf8)
        return json + [endOfMessage]
    }

    static func decodeReply(_ data: Data) throws -> Reply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError(description: "Screenme sent a reply that is not JSON")
        }
        if let message = object["error"] as? String { return .error(message) }
        return .result(object["result"] as? [String: Any] ?? [:])
    }
}

/// The arguments of a request or an MCP tool call, read by type. A value of the wrong type is an error, never a default.
struct AgentArguments {
    struct WrongType: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    let values: [String: Any]

    init(_ values: [String: Any]) { self.values = values }

    func value(_ key: String) -> Any? {
        values[key].flatMap { $0 is NSNull ? nil : $0 }
    }

    /// JSON `true` and `false` arrive as numbers too.
    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    func string(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard let string = value as? String else { throw WrongType(description: "\(key) must be a string") }
        return string
    }

    func number(_ key: String) throws -> Double? {
        guard let value = value(key) else { return nil }
        guard let number = value as? NSNumber, !Self.isBool(number) else { throw WrongType(description: "\(key) must be a number") }
        return number.doubleValue
    }

    /// A whole number, written `2` or `2.0`.
    func integer(_ key: String) throws -> Int? {
        guard let number = try number(key) else { return nil }
        guard let integer = Int(exactly: number) else { throw WrongType(description: "\(key) must be a whole number") }
        return integer
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        guard let number = value as? NSNumber, Self.isBool(number) else { throw WrongType(description: "\(key) must be true or false") }
        return number.boolValue
    }
}
