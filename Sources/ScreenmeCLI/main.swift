import Foundation

/// `screenme`: takes captures through the running Screenme app and reads its Captures folder, for scripts and agents.
/// Installed into Screenme.app/Contents/Helpers and linked onto PATH by scripts/install.sh.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("screenme: \(message)\n".utf8))
    exit(code)
}

let folder = CaptureFolder.standard
let command: Command
do {
    command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\n\(Command.usage)", code: 2)
}

switch command {
case .help:
    print(Command.usage)
case .capture(let request):
    do {
        print(try await folder.take(request).path)
    } catch {
        fail("\(error)")
    }
case .latest:
    guard let latest = folder.latest else { fail("no captures yet in \(folder.url.path)") }
    print(latest.url.path)
case .list(let limit):
    for capture in folder.captures().prefix(limit) { print(capture.url.path) }
case .zoom(let request):
    do {
        let report = try ReportBundle.open(request.bundle, reports: MCPServer.saveFolder)
        print(try await report.zoom(request.moment, span: request.span, columns: request.columns, rows: request.rows).text)
    } catch {
        fail("\(error)")
    }
case .frames(let bundle, let from, let to, let fps):
    do {
        let report = try ReportBundle.open(bundle, reports: MCPServer.saveFolder)
        for file in try await report.frames(from: from, to: to, fps: fps) { print(file.path) }
    } catch {
        fail("\(error)")
    }
case .inspect(let bundle, let json):
    do {
        let report = try ReportBundle.open(bundle, reports: MCPServer.saveFolder)
        if json {
            print(try String(contentsOf: report.url.appendingPathComponent(ReportBundle.manifestName), encoding: .utf8))
        } else {
            print(try report.summary, terminator: "")
        }
    } catch {
        fail("\(error)")
    }
case .mcp:
    let server = MCPServer(folder: folder, capture: { try await folder.take($0) })
    while let line = readLine() {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        if let response = await server.handle(line) {
            print(response)
            fflush(stdout)
        }
    }
}
