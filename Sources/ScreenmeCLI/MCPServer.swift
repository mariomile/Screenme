import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Model Context Protocol server over stdio: one JSON-RPC 2.0 message per line in, one per line out.
/// Handles `initialize`, `ping`, `tools/list` and `tools/call`; notifications get no answer.
/// See modelcontextprotocol.io/specification.
struct MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Images go back with their long side at most this many pixels, the size Claude reads without scaling.
    static let maxImageSide = 1568

    let folder: CaptureFolder
    /// Takes a capture and returns its file. `CaptureFolder.take` in the tool, a stub in tests.
    let capture: (CaptureRequest) async throws -> URL

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
            return result(id: id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            return result(id: id, await call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        [
            "name": "take_screenshot",
            "description": "Take a screenshot with Screenme and return it as an image plus its file path. "
                + "mode fullscreen captures every screen; area captures x, y, width, height in global screen points "
                + "(top-left origin); window captures the frontmost window of app (name or bundle ID).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mode": ["type": "string", "enum": ["fullscreen", "area", "window"]],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "width": ["type": "number"],
                    "height": ["type": "number"],
                    "app": ["type": "string", "description": "App name or bundle ID, for mode window"],
                ],
                "required": ["mode"],
            ],
        ],
        [
            "name": "get_latest_capture",
            "description": "Return the newest Screenme capture as an image plus its file path.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "list_captures",
            "description": "List recent Screenme captures, newest first: file path and date, one per line.",
            "inputSchema": [
                "type": "object",
                "properties": ["limit": ["type": "integer", "minimum": 1, "description": "How many, default 10"]],
            ],
        ],
    ]

    /// A tool result. Failures are results with `isError`, so the model reads them.
    private func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "take_screenshot":
                return imageResult(try await capture(try Self.request(from: arguments)))
            case "get_latest_capture":
                guard let latest = folder.latest else { return failure("There are no captures yet in \(folder.url.path)") }
                return imageResult(latest.url)
            default:
                let limit = arguments["limit"] as? Int ?? Command.defaultListLimit
                guard limit > 0 else { return failure("limit must be at least 1") }
                let lines = folder.captures().prefix(limit).map { "\($0.url.path)\t\($0.date.ISO8601Format())" }
                return ["content": [text(lines.isEmpty ? "No captures yet" : lines.joined(separator: "\n"))]]
            }
        } catch {
            return failure("\(error)")
        }
    }

    static func request(from arguments: [String: Any]) throws -> CaptureRequest {
        switch arguments["mode"] as? String {
        case "fullscreen":
            return .fullscreen
        case "area":
            guard let x = arguments["x"] as? Double, let y = arguments["y"] as? Double,
                  let width = arguments["width"] as? Double, let height = arguments["height"] as? Double else {
                throw Command.UsageError("mode area needs x, y, width and height")
            }
            guard width > 0, height > 0 else { throw Command.UsageError("width and height must be above 0") }
            return .area(x: x, y: y, width: width, height: height)
        case "window":
            guard let app = arguments["app"] as? String, !app.isEmpty else { throw Command.UsageError("mode window needs app") }
            return .window(app: app)
        default:
            throw Command.UsageError("mode must be fullscreen, area or window")
        }
    }

    /// The image (PNG, scaled down to `maxImageSide`) and the path. Only the path when the file is not an image (a video).
    private func imageResult(_ url: URL) -> [String: Any] {
        guard let png = Self.pngData(of: url) else { return ["content": [text(url.path)]] }
        return ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"], text(url.path)]]
    }

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
    private func failure(_ message: String) -> [String: Any] { ["content": [text(message)], "isError": true] }

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
