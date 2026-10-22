import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Model Context Protocol server over stdio: one JSON-RPC 2.0 message per line in, one per line out.
/// Handles `initialize`, `ping`, `tools/list` and `tools/call`; notifications get no answer. A tool call runs its
/// `Command` and returns the command's images as pictures, then its text.
/// See modelcontextprotocol.io/specification.
struct MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Images go back with their long side at most this many pixels, the size Claude reads without scaling.
    static let maxImageSide = 1568

    let context: Command.Context

    /// Answers one line of input. Nil for notifications, which get no answer.
    func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let response = await respond(to: message) else { return nil }
        return encode(response)
    }

    private func respond(to message: [String: Any]) async -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        guard let method = message["method"] as? String else { return error(id: id, code: -32600, message: "Invalid request") }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return result(id: id, [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "screenme", "version": "0.1.0"],
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": Tool.allCases.map(\.definition)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard let tool = Tool(rawValue: name) else { return error(id: id, code: -32602, message: "Unknown tool: \(name)") }
            return result(id: id, await call(tool, Tool.Arguments(params["arguments"] as? [String: Any] ?? [:])))
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// A tool result. Failures are results with `isError`, so the model reads them.
    private func call(_ tool: Tool, _ arguments: Tool.Arguments) async -> [String: Any] {
        do {
            let output = try await tool.command(arguments).run(context)
            let images = output.images.compactMap(Self.pngData).map { ["type": "image", "data": $0.base64EncodedString(), "mimeType": "image/png"] }
            // An empty list still says something.
            return ["content": images + [text(output.text.isEmpty ? "Nothing found." : output.text)]]
        } catch {
            return ["content": [text("\(error)")], "isError": true]
        }
    }

    /// The image as PNG, scaled down to `maxImageSide`. Nil when the file is not an image (a video).
    static func pngData(of url: URL) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxImageSide] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func text(_ string: String) -> [String: Any] { ["type": "text", "text": string] }

    // MARK: JSON-RPC

    private func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ message: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
