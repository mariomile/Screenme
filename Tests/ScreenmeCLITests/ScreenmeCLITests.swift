import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class CommandParsingTests: XCTestCase {
    func testParsesEveryCommand() throws {
        XCTAssertEqual(try Command.parse([]), .help)
        XCTAssertEqual(try Command.parse(["--help"]), .help)
        XCTAssertEqual(try Command.parse(["capture", "fullscreen"]), .capture(.fullscreen))
        XCTAssertEqual(try Command.parse(["capture", "area", "10", "20.5", "640", "400"]),
                       .capture(.area(x: 10, y: 20.5, width: 640, height: 400)))
        XCTAssertEqual(try Command.parse(["capture", "window", "com.apple.Safari"]), .capture(.window(app: "com.apple.Safari")))
        XCTAssertEqual(try Command.parse(["latest"]), .latest)
        XCTAssertEqual(try Command.parse(["list"]), .list(limit: 10))
        XCTAssertEqual(try Command.parse(["list", "--limit", "3"]), .list(limit: 3))
        XCTAssertEqual(try Command.parse(["mcp"]), .mcp)
    }

    func testRejectsBadArguments() {
        for arguments in [["shoot"], ["capture"], ["capture", "area", "1", "2", "3"], ["capture", "area", "1", "2", "x", "4"],
                          ["capture", "area", "1", "2", "0", "4"], ["capture", "window"], ["capture", "fullscreen", "extra"],
                          ["list", "--limit"], ["list", "--limit", "0"], ["list", "5"], ["latest", "now"], ["mcp", "--stdio"]] {
            XCTAssertThrowsError(try Command.parse(arguments), "\(arguments)")
        }
    }

    func testLinksMatchTheAppsLinks() {
        XCTAssertEqual(CaptureRequest.fullscreen.link.absoluteString, "screenme://capture-fullscreen")
        XCTAssertEqual(CaptureRequest.area(x: 100, y: 80, width: 640.5, height: 400).link.absoluteString,
                       "screenme://capture-area?x=100&y=80&width=640.5&height=400")
        XCTAssertEqual(CaptureRequest.window(app: "Google Chrome").link.absoluteString, "screenme://capture-window?app=Google%20Chrome")
    }
}

final class CaptureFolderTests: XCTestCase {
    var folder: CaptureFolder!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenmeCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = CaptureFolder(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.url)
    }

    @discardableResult
    func writePNG(_ name: String, modified: Date) throws -> URL {
        let url = folder.url.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testListsNewestFirstAndSkipsHiddenFiles() throws {
        let now = Date()
        try writePNG("a.png", modified: now.addingTimeInterval(-60))
        let newest = try writePNG("b.png", modified: now)
        try writePNG("c.png", modified: now.addingTimeInterval(-30))
        FileManager.default.createFile(atPath: folder.url.appendingPathComponent(".DS_Store").path, contents: Data([1]))
        // The events of a recording, kept next to it by the app.
        FileManager.default.createFile(atPath: folder.url.appendingPathComponent(".b.mp4.events.json").path, contents: Data("{}".utf8))

        XCTAssertEqual(folder.captures().map(\.url.lastPathComponent), ["b.png", "c.png", "a.png"])
        XCTAssertEqual(folder.latest?.url.lastPathComponent, newest.lastPathComponent)
    }

    func testEmptyOrMissingFolderHasNoCaptures() throws {
        XCTAssertNil(folder.latest)
        XCTAssertNil(CaptureFolder(url: folder.url.appendingPathComponent("missing")).latest)
    }

    func testNewImageIgnoresExistingAndHalfWrittenFiles() throws {
        try writePNG("old.png", modified: Date().addingTimeInterval(-60))
        let existing = folder.names()
        XCTAssertNil(folder.newImage(notIn: existing))

        // A PNG cut short, as the app's file looks while it is still being written.
        let full = try Data(contentsOf: folder.url.appendingPathComponent("old.png"))
        let partial = folder.url.appendingPathComponent("new.png")
        try full.prefix(full.count / 2).write(to: partial)
        XCTAssertNil(folder.newImage(notIn: existing))

        try full.write(to: partial)
        XCTAssertEqual(folder.newImage(notIn: existing)?.lastPathComponent, "new.png")
    }

    func testJPEGIsCompleteAtItsEndMarker() throws {
        let jpeg = folder.url.appendingPathComponent("shot.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0]).write(to: jpeg)
        XCTAssertFalse(CaptureFolder.isComplete(jpeg))
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0xFF, 0xD9]).write(to: jpeg)
        XCTAssertTrue(CaptureFolder.isComplete(jpeg))
    }
}

final class MCPServerTests: XCTestCase {
    var folder: CaptureFolder!
    var captured: [CaptureRequest] = []

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenmeMCPTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = CaptureFolder(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.url)
    }

    /// A server whose captures write a 3000 x 1000 PNG instead of asking the app, with its reports in the same folder.
    var server: MCPServer {
        MCPServer(folder: folder, reports: folder.url) { request in
            self.captured.append(request)
            return try self.writeImage(width: 3000, height: 1000)
        }
    }

    func writeImage(width: Int, height: Int) throws -> URL {
        let url = folder.url.appendingPathComponent("\(UUID().uuidString).png")
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func send(_ message: String) async throws -> [String: Any]? {
        guard let line = await server.handle(message) else { return nil }
        XCTAssertFalse(line.contains("\n"), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func testInitializeEchoesASupportedVersion() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        XCTAssertEqual(response?["id"] as? Int, 1)
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "screenme")

        let unknown = try await send(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(unknown?["id"] as? String, "a")
        XCTAssertEqual((unknown?["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.protocolVersions[0])
    }

    func testNotificationsGetNoAnswer() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
    }

    func testErrors() async throws {
        let parse = try await send("not json")
        XCTAssertEqual((parse?["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(parse?["id"] is NSNull)
        let method = try await send(#"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        XCTAssertEqual((method?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let tool = try await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual((tool?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testListsFourTools() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((response?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["take_screenshot", "get_latest_capture", "get_latest_report", "list_captures"])
        XCTAssertTrue(tools.allSatisfy { $0["inputSchema"] is [String: Any] })
    }

    func testTakeScreenshotReturnsAScaledImageAndThePath() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"take_screenshot","arguments":{"mode":"area","x":10,"y":20,"width":300.5,"height":100}}}"#)
        XCTAssertEqual(captured, [.area(x: 10, y: 20, width: 300.5, height: 100)])
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        XCTAssertEqual(content[0]["mimeType"] as? String, "image/png")

        let png = try XCTUnwrap(Data(base64Encoded: content[0]["data"] as? String ?? ""))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), MCPServer.maxImageSide)
        XCTAssertTrue(FileManager.default.fileExists(atPath: content[1]["text"] as? String ?? ""))
    }

    func testTakeScreenshotWithBadArgumentsIsAToolError() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"take_screenshot","arguments":{"mode":"window"}}}"#)
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(captured.isEmpty)
    }

    func testLatestAndList() async throws {
        let empty = try await send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_latest_capture"}}"#)
        XCTAssertEqual((empty?["result"] as? [String: Any])?["isError"] as? Bool, true)

        let small = try writeImage(width: 40, height: 30)
        let latest = try await send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_latest_capture","arguments":{}}}"#)
        let content = try XCTUnwrap((latest?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        // The folder lists /private/var where the temporary directory says /var.
        XCTAssertEqual((content.last?["text"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }, small.lastPathComponent)

        _ = try writeImage(width: 10, height: 10)
        let list = try await send(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_captures","arguments":{"limit":1}}}"#)
        let text = try XCTUnwrap(((list?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        XCTAssertTrue(text.contains("\t"))
    }

    func testRequestFromArguments() throws {
        XCTAssertEqual(try MCPServer.request(from: ["mode": "fullscreen"]), .fullscreen)
        XCTAssertEqual(try MCPServer.request(from: ["mode": "window", "app": "Safari"]), .window(app: "Safari"))
        XCTAssertThrowsError(try MCPServer.request(from: ["mode": "area", "x": 1, "y": 2, "width": 0, "height": 4]))
        XCTAssertThrowsError(try MCPServer.request(from: [:]))
    }

    /// A report folder as Report for AI writes it, with `frames` PNG frames and report.md last modified at `modified`.
    @discardableResult
    func writeReport(_ name: String, frames: Int, modified: Date) throws -> URL {
        let report = folder.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: report.appendingPathComponent("frames"), withIntermediateDirectories: true)
        for index in 0..<frames {
            let image = try writeImage(width: 64, height: 40)
            try FileManager.default.moveItem(at: image, to: report.appendingPathComponent(String(format: "frames/%02d.png", index + 1)))
        }
        let markdown = report.appendingPathComponent("report.md")
        try "# \(name)\n".write(to: markdown, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: markdown.path)
        return report
    }

    func testLatestReportReturnsTheMarkdownAndUpToSixFrames() async throws {
        let empty = try await send(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_latest_report"}}"#)
        XCTAssertEqual((empty?["result"] as? [String: Any])?["isError"] as? Bool, true)

        let now = Date()
        try writeReport("Report 2026-10-21 at 10.00.00", frames: 2, modified: now.addingTimeInterval(-60))
        try writeReport("Report 2026-10-21 at 11.00.00", frames: 9, modified: now)
        // Not reports: another folder, and a report folder still being written (no report.md yet).
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Screens"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Report 2026-10-21 at 12.00.00"), withIntermediateDirectories: true)

        XCTAssertEqual(MCPServer.latestReport(in: folder.url)?.lastPathComponent, "Report 2026-10-21 at 11.00.00")
        let response = try await send(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_latest_report","arguments":{}}}"#)
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "# Report 2026-10-21 at 11.00.00\n")
        let images = content.filter { $0["type"] as? String == "image" }
        XCTAssertEqual(images.count, MCPServer.maxReportFrames)
        XCTAssertTrue(images.allSatisfy { $0["mimeType"] as? String == "image/png" })
        // Spread over the recording, not just the first six.
        let paths = content.compactMap { $0["text"] as? String }.filter { $0.hasSuffix(".png") }.map { URL(fileURLWithPath: $0).lastPathComponent }
        XCTAssertEqual(paths, ["01.png", "02.png", "04.png", "05.png", "07.png", "08.png"])
        XCTAssertTrue((content.last?["text"] as? String)?.hasSuffix("Report 2026-10-21 at 11.00.00") == true)
    }
}
