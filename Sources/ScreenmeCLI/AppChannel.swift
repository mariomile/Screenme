import AppKit
import Network

/// One request to the running Screenme app, as `screenme` sends it over the agent socket.
struct AppCall: Equatable {
    /// A JSON value an argument can hold.
    enum Value: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)

        var json: Any {
            switch self {
            case .string(let string): string
            case .number(let number): number
            case .bool(let bool): bool
            }
        }

        /// A JSON value from an MCP call: text, a number or true and false. Nil for anything else.
        init?(json: Any) {
            if let string = json as? String { self = .string(string); return }
            guard let number = json as? NSNumber else { return nil }
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        }
    }

    let command: String
    var arguments: [String: Value] = [:]

    /// How long the app may take: a scrolling capture or a report runs for minutes.
    var timeout: TimeInterval = 60
}

/// Sends `AppCall`s to the app over its agent socket (`AgentChannel`), starting the app when it is not running.
/// The app holds the Screen Recording permission, the settings and the upload key; this tool only asks.
enum AppChannel {
    enum Failure: Error, CustomStringConvertible {
        case notInstalled
        case notLaunchable(String)
        case notResponding
        case timedOut(seconds: Int)
        case refused(String)

        var description: String {
            switch self {
            case .notInstalled:
                "Screenme is not installed. Run scripts/install.sh in the Screenme checkout."
            case .notLaunchable(let reason):
                "Could not open Screenme: \(reason)"
            case .notResponding:
                "Screenme is running but does not answer on its agent socket. Quit and reopen Screenme, or update it from its menu."
            case .timedOut(let seconds):
                "Screenme did not answer within \(seconds) s. It may still finish: check `screenme latest` before trying again."
            case .refused(let message):
                message
            }
        }
    }

    /// Sends the call and returns the app's result, or throws the app's error as a `Failure`.
    static func send(_ call: AppCall) async throws -> [String: Any] {
        let request = try AgentChannel.encode(AgentChannel.Request(command: call.command, arguments: call.arguments.mapValues(\.json),
                                                                   timeout: call.timeout))
        let data: Data
        do {
            data = try await exchange(request, timeout: call.timeout)
        } catch Exchange.Unreachable.socket {
            try await launch()
            data = try await exchange(request, timeout: call.timeout)
        }
        switch try AgentChannel.decodeReply(data) {
        case .result(let result): return result
        case .error(let message): throw Failure.refused(message)
        }
    }

    /// Opens the app without bringing it forward and waits up to 10 s for its socket to answer.
    private static func launch() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: try appURL(), configuration: configuration)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.notLaunchable(error.localizedDescription)
        }
        let ping = try AgentChannel.encode(AgentChannel.Request(command: "status", arguments: [:]))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? await exchange(ping, timeout: 2)) != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw Failure.notResponding
    }

    private static func exchange(_ request: Data, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Exchange(request: request, timeout: timeout, continuation: continuation).start()
        }
    }

    /// The Screenme.app this tool is embedded in (the `screenme` on PATH is a symlink into it), otherwise the app
    /// macOS opens `screenme://` links with.
    private static func appURL() throws -> URL {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let bundle = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let bundle, bundle.pathExtension == "app" { return bundle }
        guard let link = URL(string: "screenme://status"), let app = NSWorkspace.shared.urlForApplication(toOpen: link) else {
            throw Failure.notInstalled
        }
        return app
    }
}

/// One connection: write the request, close the writing side, read the reply until the app closes.
/// Everything runs on one serial queue, so `finished` needs no lock.
private final class Exchange: @unchecked Sendable {
    /// Nothing listens on the socket: the app is not running, or not yet.
    enum Unreachable: Error { case socket }

    private let connection = NWConnection(to: .unix(path: AgentChannel.socketURL.path), using: .tcp)
    private let queue = DispatchQueue(label: "dev.mariomiletta.screenme.exchange")
    private let request: Data
    private let timeout: TimeInterval
    private let continuation: CheckedContinuation<Data, Error>
    private var reply = Data()
    private var finished = false
    /// Once connected, a failure is the exchange's, not a missing app: the request may already be running.
    private var connected = false

    init(request: Data, timeout: TimeInterval, continuation: CheckedContinuation<Data, Error>) {
        self.request = request
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connected = true
                connection.send(content: request, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] error in
                    if let error { finish(.failure(error)) }
                })
                receive()
            case .waiting(let error), .failed(let error):
                finish(.failure(connected ? error : Unreachable.socket))
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.failure(AppChannel.Failure.timedOut(seconds: Int(timeout)))) }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            if let data { reply.append(data) }
            if complete {
                finish(.success(reply))
            } else if let error {
                finish(.failure(error))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        continuation.resume(with: result)
    }
}
