import AVFoundation
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

    func testListsSixTools() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((response?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["take_screenshot", "get_latest_capture", "get_latest_report", "zoom_report", "inspect_report", "list_captures"])
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

    func testLatestReportReturnsTheSummaryAndTheContactSheet() async throws {
        let empty = try await send(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"get_latest_report"}}"#)
        XCTAssertEqual((empty?["result"] as? [String: Any])?["isError"] as? Bool, true)

        let now = Date()
        try ReportBundleTests.writeReport(in: folder.url, name: "Report 2026-10-21 at 10.00.00", video: false, modified: now.addingTimeInterval(-60))
        try ReportBundleTests.writeReport(in: folder.url, name: "Report 2026-10-21 at 11.00.00", video: false, modified: now)
        // Not reports: another folder, and a report folder still being written (no summary.md yet).
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Screens"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Report 2026-10-21 at 12.00.00"), withIntermediateDirectories: true)

        XCTAssertEqual(MCPServer.latestReport(in: folder.url)?.lastPathComponent, "Report 2026-10-21 at 11.00.00")
        let response = try await send(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_latest_report","arguments":{}}}"#)
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image", "text", "text"])
        XCTAssertEqual(content[0]["text"] as? String, "# Report 2026-10-21 at 11.00.00\n")
        XCTAssertEqual(content[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual((content[2]["text"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }, "contact-sheet.png")
        XCTAssertTrue((content.last?["text"] as? String)?.hasSuffix("Report 2026-10-21 at 11.00.00") == true)
    }

    func testZoomAndInspectReport() async throws {
        let report = try ReportBundleTests.writeReport(in: folder.url, name: "Report 2026-10-21 at 10.00.00", video: true, modified: Date())
        try await ReportBundleTests.writeVideo(to: report.appendingPathComponent("recording.mp4"))

        let zoom = try await send(#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"zoom_report","arguments":{"phrase":"the total","grid":"2x2"}}}"#)
        let content = try XCTUnwrap((zoom?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        let text = try XCTUnwrap(content[1]["text"] as? String)
        XCTAssertTrue(text.contains("Around 0:01.4: #1 0:00.9, #2 0:01.6, #3 0:02.2, #4 0:02.9"), text)

        let bad = try await send(#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"zoom_report","arguments":{"mark":4}}}"#)
        XCTAssertEqual((bad?["result"] as? [String: Any])?["isError"] as? Bool, true)

        let inspect = try await send(#"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"inspect_report","arguments":{"json":true}}}"#)
        let json = try XCTUnwrap((((inspect?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String))
        XCTAssertTrue(json.contains("\"keyframes\""))
        XCTAssertEqual(try MCPServer.zoomRequest(from: ["at": 12.5, "span": 4]), ZoomRequest(moment: .at(12.5), span: 4))
        XCTAssertThrowsError(try MCPServer.zoomRequest(from: [:]))
    }
}

/// Report folders read by `screenme zoom`, `frames` and `inspect`, from a generated silent video.
final class ReportBundleTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenmeReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A report folder as Report for AI writes it: summary.md (modified at `modified`), report.json, a contact sheet,
    /// and recording.mp4 when `video` is set (written by `writeVideo`). "Look at the total." is said from 1 s; mark 1 at 2 s.
    @discardableResult
    static func writeReport(in parent: URL, name: String, video: Bool, modified: Date) throws -> URL {
        let report = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: report.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let manifest = """
        {"duration": 3, "video": "recording.mp4", "summary": "summary.md", "contactSheet": "contact-sheet.png",
         "keyframes": [{"number": 1, "time": 0.3, "moment": 0, "reason": "start", "file": "frames/frame-01.png", "text": "Look at the total.", "events": []}],
         "transcript": {"segments": [{"start": 1, "end": 2, "text": "Look at the total."}],
                        "words": [{"start": 1, "end": 1.2, "text": "Look"}, {"start": 1.2, "end": 1.4, "text": "at"},
                                  {"start": 1.4, "end": 1.6, "text": "the"}, {"start": 1.6, "end": 2, "text": "total."}]},
         "marks": [{"number": 1, "time": 2, "keyframe": 1}], "events": []}
        """
        try manifest.write(to: report.appendingPathComponent("report.json"), atomically: true, encoding: .utf8)
        let sheet = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try ReportBundle.writePNG(sheet.makeImage()!, to: report.appendingPathComponent("contact-sheet.png"))
        let summary = report.appendingPathComponent("summary.md")
        try "# \(name)\n".write(to: summary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: summary.path)
        return report
    }

    /// A 3 second, 320 × 240 H.264 video with no audio, 10 frames a second, a little brighter every frame.
    static func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 8), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testParsesReportCommands() throws {
        XCTAssertEqual(try Command.parse(["zoom", "--at", "0:12"]), .zoom(ZoomRequest(moment: .at(12))))
        XCTAssertEqual(try Command.parse(["zoom", "/tmp/Report 1", "--at", "1:02:03.5", "--span", "4", "--grid", "4x2"]),
                       .zoom(ZoomRequest(bundle: "/tmp/Report 1", moment: .at(3723.5), span: 4, columns: 4, rows: 2)))
        XCTAssertEqual(try Command.parse(["zoom", "latest", "--at", "the width changes"]), .zoom(ZoomRequest(moment: .phrase("the width changes"))))
        XCTAssertEqual(try Command.parse(["zoom", "--phrase", "here"]), .zoom(ZoomRequest(moment: .phrase("here"))))
        XCTAssertEqual(try Command.parse(["zoom", "--mark", "2"]), .zoom(ZoomRequest(moment: .mark(2))))
        XCTAssertEqual(try Command.parse(["frames", "R", "--from", "0:04", "--to", "6", "--fps", "2"]), .frames(bundle: "R", from: 4, to: 6, fps: 2))
        XCTAssertEqual(try Command.parse(["frames", "--from", "1", "--to", "2"]), .frames(bundle: "latest", from: 1, to: 2, fps: 4))
        XCTAssertEqual(try Command.parse(["inspect"]), .inspect(bundle: "latest", json: false))
        XCTAssertEqual(try Command.parse(["inspect", "R", "--json"]), .inspect(bundle: "R", json: true))
        for arguments in [["zoom"], ["zoom", "--at", "1", "--mark", "2"], ["zoom", "--mark", "x"], ["zoom", "--at", "1", "--grid", "9x1"],
                          ["zoom", "--at", "1", "--span", "0"], ["zoom", "--at"], ["zoom", "--at", "1", "--full"], ["frames", "--from", "2"],
                          ["frames", "--from", "3", "--to", "1"], ["frames", "--from", "1", "--to", "2", "--fps", "0"], ["inspect", "--yaml"],
                          ["inspect", "a", "b"]] {
            XCTAssertThrowsError(try Command.parse(arguments), "\(arguments)")
        }
    }

    func testTheSkillHasFrontmatterAndShipsInTheApp() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = try String(contentsOf: repo.appendingPathComponent("skills/screenme/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(skill.hasPrefix("---\nname: screenme\ndescription: "))
        XCTAssertTrue(skill.contains("\n---\n\n# Screenme reports\n"))
        XCTAssertFalse(skill.contains("\u{2014}"), "no em-dashes")
        XCTAssertEqual(try Command.parse(["skill"]), .skill)
        XCTAssertThrowsError(try Command.parse(["skill", "install"]))

        // Screenme.app/Contents/Helpers/screenme finds Contents/Resources/SKILL.md, also through a link on PATH.
        let contents = folder.appendingPathComponent("Screenme.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let tool = contents.appendingPathComponent("Helpers/screenme")
        FileManager.default.createFile(atPath: tool.path, contents: Data())
        try skill.write(to: contents.appendingPathComponent("Resources/SKILL.md"), atomically: true, encoding: .utf8)
        let link = folder.appendingPathComponent("screenme")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        XCTAssertEqual(Skill.url(executable: link)?.resolvingSymlinksInPath().path,
                       contents.appendingPathComponent("Resources/SKILL.md").resolvingSymlinksInPath().path)
    }

    func testTimes() {
        XCTAssertEqual(ReportBundle.parseTime("12.5"), 12.5)
        XCTAssertEqual(ReportBundle.parseTime("1:05"), 65)
        XCTAssertNil(ReportBundle.parseTime("here"))
        XCTAssertNil(ReportBundle.parseTime("-1"))
        XCTAssertEqual(ReportBundle.format(65.04), "1:05.0")
        XCTAssertEqual(ReportBundle.format(3723.46), "1:02:03.5")
    }

    func testFindsMomentsByTimePhraseAndMark() throws {
        let report = try ReportBundle(Self.writeReport(in: folder, name: "Report 1", video: false, modified: Date()))
        XCTAssertEqual(try report.time(of: .at(9)), 3, "inside the video")
        XCTAssertEqual(try report.time(of: .phrase("THE tot")), 1.4, "case does not matter; the last word may be cut short")
        XCTAssertEqual(try report.time(of: .phrase("look, at")), 1)
        XCTAssertThrowsError(try report.time(of: .phrase("nothing like it"))) {
            XCTAssertEqual($0 as? ReportBundle.Failure, .phraseNotFound("nothing like it"))
        }
        XCTAssertEqual(try report.time(of: .mark(1)), 2)
        XCTAssertThrowsError(try report.time(of: .mark(3))) { XCTAssertEqual($0 as? ReportBundle.Failure, .markNotFound(3, count: 1)) }
        XCTAssertThrowsError(try ReportBundle(folder.appendingPathComponent("missing"))) {
            XCTAssertEqual(($0 as? ReportBundle.Failure).map { "\($0)" }?.hasSuffix("is not a Report for AI folder (no report.json)"), true)
        }
        XCTAssertEqual(try ReportBundle.open("latest", reports: folder).url.lastPathComponent, "Report 1")
        XCTAssertEqual(report.said(from: 1.3, to: 1.5), "at the")
    }

    func testZoomWritesAGridAroundTheMoment() async throws {
        let url = try Self.writeReport(in: folder, name: "Report 1", video: true, modified: Date())
        try await Self.writeVideo(to: url.appendingPathComponent("recording.mp4"))
        let report = try ReportBundle(url)

        let zoom = try await report.zoom(.at(1))
        XCTAssertEqual(zoom.image.deletingLastPathComponent().lastPathComponent, "zoom")
        XCTAssertEqual(zoom.times.count, 9)
        XCTAssertEqual(zoom.times.first ?? 0, 0.5, accuracy: 0.001, "a quarter of the span before")
        XCTAssertEqual(zoom.times.last ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(zoom.said, "Look at the total.")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(zoom.image as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1920)
        XCTAssertEqual(image.height, 4 * 12 + 3 * 468)
        XCTAssertTrue(zoom.text.hasPrefix(zoom.image.path + "\nAround 0:01.0: #1 0:00.5, #2 0:00.8,"))

        // Near the end the grid stays inside the video.
        let end = try await report.zoom(.mark(1), span: 2, columns: 2, rows: 1)
        XCTAssertEqual(end.times.map { ($0 * 100).rounded() / 100 }, [0.95, 2.95])

        let none = try ReportBundle(Self.writeReport(in: folder, name: "Report 2", video: false, modified: Date()))
        do {
            _ = try await none.zoom(.at(1))
            XCTFail("no video, no zoom")
        } catch {
            XCTAssertEqual(error as? ReportBundle.Failure, .noVideo(none.video.path))
        }
    }

    func testFramesOfAStretch() async throws {
        let url = try Self.writeReport(in: folder, name: "Report 1", video: true, modified: Date())
        try await Self.writeVideo(to: url.appendingPathComponent("recording.mp4"))
        let files = try await ReportBundle(url).frames(from: 0.5, to: 1.5, fps: 4)
        XCTAssertEqual(files.count, 5)
        XCTAssertEqual(files.first?.lastPathComponent, "frame-0001-0m00.5.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(files[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 320)
    }
}
