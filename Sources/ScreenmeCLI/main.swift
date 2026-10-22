import Foundation

/// `screenme`: takes captures through the running Screenme app and reads its Captures folder, for scripts and agents.
/// Installed into Screenme.app/Contents/Helpers and linked onto PATH by scripts/install.sh.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("screenme: \(message)\n".utf8))
    exit(code)
}

let command: Command
do {
    command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\n\(Command.usage)", code: 2)
}

if command == .mcp {
    let server = MCPServer(context: .standard)
    while let line = readLine() {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        if let response = await server.handle(line) {
            print(response)
            fflush(stdout)
        }
    }
} else {
    do {
        let output = try await command.run(.standard)
        if !output.text.isEmpty { print(output.text, terminator: output.text.hasSuffix("\n") ? "" : "\n") }
    } catch {
        fail("\(error)")
    }
}
