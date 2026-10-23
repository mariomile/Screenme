import Foundation
import Network

/// Listens on the agent socket (`AgentChannel`) and answers each request with `AgentAPI`.
/// One request per connection: read until the tool closes its side, run the command, write the reply, close.
@MainActor
final class AgentServer {
    static let shared = AgentServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.mariomiletta.Screenme.agent")

    /// Starts listening. A socket left by a copy that quit is replaced; one another running copy answers on is left
    /// to it (a debug build next to the installed app), so this copy takes no requests. Tests listen on a socket of their own.
    func start(at socket: URL = AgentChannel.socketURL) {
        guard listener == nil else { return }
        guard !Self.isAnswered(socket.path) else {
            NSLog("Screenme: another copy answers on the agent socket; this one does not listen")
            return
        }
        do {
            let folder = socket.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            chmod(folder.path, 0o700)
            unlink(socket.path)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: socket.path)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Only this user may connect.
                    chmod(socket.path, 0o600)
                case .failed(let error):
                    NSLog("Screenme: the agent socket stopped: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Screenme: could not open the agent socket: \(error.localizedDescription)")
        }
    }

    /// Whether something accepts connections on the socket at `path`.
    private static func isAnswered(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
    }

    private nonisolated func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, into: Data())
    }

    /// Reads one line, answers it, then waits for the tool to close the connection after reading the reply: closing
    /// it here could drop the reply before the tool reads it. A request over 1 MB is refused.
    private nonisolated func receive(_ connection: NWConnection, into buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= 1 << 20 else {
                connection.cancel()
                return
            }
            guard let request = AgentChannel.message(in: buffer) else {
                if complete { connection.cancel() } else { self?.receive(connection, into: buffer) }
                return
            }
            Task { @MainActor in
                let reply = await AgentAPI.reply(to: request)
                connection.send(content: AgentChannel.encode(reply), completion: .contentProcessed { error in
                    guard error == nil else { return connection.cancel() }
                    // The tool closes once it has the reply; a tool that never does is let go after 10 s.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { connection.cancel() }
                })
            }
        }
    }
}
