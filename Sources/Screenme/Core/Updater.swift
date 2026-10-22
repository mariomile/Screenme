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
        /// What the update is doing now, e.g. building, and when the update started, for the elapsed time.
        case updating(step: String, since: Date)
        case failed(String)
    }

    /// One command of an update. `executable` is an absolute path or one inside the checkout.
    struct Step {
        let title: String
        let executable: String
        let arguments: [String]
    }

    static let steps = [
        Step(title: "Downloading the changes…", executable: "/usr/bin/git", arguments: ["pull", "--ff-only"]),
        Step(title: "Building and installing…", executable: "scripts/install.sh", arguments: []),
    ]

    /// Runs a command in a folder off the main thread. Output and errors go to `log` when given, otherwise they are returned.
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ directory: URL, _ log: FileHandle?) async throws
        -> (status: Int32, output: Data)

    /// What Check for Updates does, for its button in Settings and its menu item.
    static let checkHelp = "Fetches the latest changes from GitHub and lists what is new since this copy was installed."

    @Published private(set) var state: State = .idle

    /// Checking or updating: the buttons that start either are off.
    var isBusy: Bool {
        switch state {
        case .checking, .updating: true
        case .idle, .upToDate, .available, .failed: false
        }
    }

    let source: Source?
    /// The output of the last update, for "Show Update Log".
    let logURL: URL
    private let run: Runner

    init(source: Source?,
         logURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Screenme/update.log"),
         run: @escaping Runner = Updater.runProcess) {
        self.source = source
        self.logURL = logURL
        self.run = run
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
            _ = try await Self.git(["fetch", "--quiet"], in: source.repo, run: run)
            // Commits on the remote branch or in the checkout that this copy was not built from.
            let log = try await Self.git(["log", "--format=%s", "HEAD", "@{upstream}", "^\(source.commit)"], in: source.repo, run: run)
            let commits = log.split(separator: "\n").map(String.init)
            state = commits.isEmpty ? .upToDate : .available(commits)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Pulls and reinstalls. On success the install script quits this copy and opens the new one.
    /// Busy from the first line, so a second click while it runs does nothing.
    func update() async {
        guard let source, !isBusy else { return }
        let started = Date()
        state = .updating(step: Self.steps[0].title, since: started)
        do {
            let changes = try await Self.git(["status", "--porcelain", "--untracked-files=no"], in: source.repo, run: run)
            guard changes.isEmpty else {
                state = .failed("The source folder has uncommitted changes. Commit or stash them, then update.")
                return
            }
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            for step in Self.steps {
                state = .updating(step: step.title, since: started)
                let command = ([step.executable] + step.arguments).joined(separator: " ")
                log.write(Data("\n[\(Date().formatted(date: .omitted, time: .standard))] \(command)\n".utf8))
                let (status, _) = try await run(step.executable, step.arguments, source.repo, log)
                guard status == 0 else {
                    state = .failed("The update stopped at \"\(command)\". Details are in the update log.")
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

    nonisolated static func git(_ arguments: [String], in repo: URL, run: Runner = runProcess) async throws -> String {
        let (status, output) = try await run("/usr/bin/git", arguments, repo, nil)
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else { throw CommandError(message: text.isEmpty ? "git \(arguments[0]) failed." : text) }
        return text
    }

    /// The real `Runner`: a `Process`, with a relative `executable` found in `directory`.
    nonisolated static let runProcess: Runner = { executable, arguments, directory, log in
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable, relativeTo: directory)
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
