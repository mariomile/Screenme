import AppKit

/// Updates come from the git checkout Screenme was installed from. `scripts/install.sh` records that
/// checkout and its commit in Info.plist, so an update is a fast-forward pull plus a fresh run of the
/// install script: same local signing identity, so the privacy permissions survive the update.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater(source: .installed)

    /// The checkout and commit this copy was built from.
    struct Source {
        let repo: URL
        let commit: String

        static var installed: Source? {
            let info = Bundle.main.infoDictionary
            guard let path = info?["ScreenmeSourcePath"] as? String, let commit = info?["ScreenmeCommit"] as? String else { return nil }
            return Source(repo: URL(fileURLWithPath: path), commit: commit)
        }

        var shortCommit: String { String(commit.prefix(7)) }
    }

    enum State: Equatable {
        case idle, checking, upToDate
        /// Subjects of the commits not in this copy yet, newest first.
        case available([String])
        /// What the update is doing now, e.g. building.
        case updating(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// When the running update started, for the elapsed time next to its progress.
    private(set) var updateStarted = Date()

    var isBusy: Bool {
        if case .updating = state { return true }
        return state == .checking
    }
    let source: Source?

    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Screenme/update.log")

    init(source: Source?) {
        self.source = source
    }

    /// The update restarts Screenme silently, so the first launch on a new commit confirms it.
    func announceIfUpdated() {
        guard let source else { return }
        let previous = Prefs[Pref.lastRunCommit]
        Prefs[Pref.lastRunCommit] = source.commit
        if !previous.isEmpty, previous != source.commit {
            Toast.show("Screenme updated to \(source.shortCommit)", symbol: "arrow.down.circle.fill", duration: 4)
        }
    }

    func check() async {
        guard let source, !isBusy else { return }
        state = .checking
        do {
            _ = try await Self.git(["fetch", "--quiet"], in: source.repo)
            // Commits on the remote branch or in the checkout that this copy was not built from.
            let log = try await Self.git(["log", "--format=%s", "HEAD", "@{upstream}", "^\(source.commit)"], in: source.repo)
            let commits = log.split(separator: "\n").map(String.init)
            state = commits.isEmpty ? .upToDate : .available(commits)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Pulls and reinstalls. On success the install script quits this copy and opens the new one.
    func update() async {
        guard let source, !isBusy else { return }
        do {
            let changes = try await Self.git(["status", "--porcelain", "--untracked-files=no"], in: source.repo)
            guard changes.isEmpty else {
                state = .failed("The source folder has uncommitted changes. Commit or stash them, then update.")
                return
            }
            try FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: Self.logURL)
            defer { try? log.close() }
            updateStarted = Date()
            let steps: [(title: String, command: String)] = [
                ("Downloading the changes…", "git pull --ff-only"),
                ("Building and installing…", "./scripts/install.sh"),
            ]
            for step in steps {
                state = .updating(step.title)
                log.write(Data("\n[\(Date().formatted(date: .omitted, time: .standard))] \(step.command)\n".utf8))
                let (status, _) = try await Self.run("/bin/zsh", ["-c", step.command], in: source.repo, log: log)
                guard status == 0 else {
                    state = .failed("The update stopped at \"\(step.command)\". Details are in the update log.")
                    return
                }
            }
            // The install script quits this copy and opens the new one, so this is rarely reached.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Processes

    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static func git(_ arguments: [String], in repo: URL) async throws -> String {
        let (status, output) = try await run("/usr/bin/git", arguments, in: repo)
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { throw CommandError(message: text.isEmpty ? "git \(arguments[0]) failed." : text) }
        return text
    }

    /// Runs a command off the main thread. Output and errors go to `log` when given, otherwise they are returned.
    nonisolated private static func run(_ executable: String, _ arguments: [String], in directory: URL,
                                        log: FileHandle? = nil) async throws -> (status: Int32, output: Data) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            // GUI apps get a bare PATH; the install script needs Homebrew's xcodegen.
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = log ?? pipe
            process.standardError = log ?? pipe
            try process.run()
            // Drain the pipe while the process runs, so a long output cannot block it.
            let output = log == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
            process.waitUntilExit()
            return (process.terminationStatus, output)
        }.value
    }
}
