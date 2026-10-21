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
