import XCTest
@testable import Screenme

/// Check for Updates against real git repositories: a bare "GitHub" remote, the checkout Screenme
/// was installed from, and a second clone that pushes new work.
@MainActor
final class UpdaterTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("remote.git") }
    private var checkout: URL { root.appendingPathComponent("checkout") }
    private var other: URL { root.appendingPathComponent("other") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git(["init", "--quiet", "--bare", "--initial-branch=main", remote.path], in: root)
        try await git(["clone", "--quiet", remote.path, checkout.path], in: root)
        try await commit("First", in: checkout)
        try await git(["push", "--quiet", "-u", "origin", "main"], in: checkout)
        try await git(["clone", "--quiet", remote.path, other.path], in: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNothingNewIsUpToDate() async throws {
        let updater = try await installedUpdater()
        await updater.check()
        XCTAssertEqual(updater.state, .upToDate)
    }

    func testPushedCommitsAreListedNewestFirst() async throws {
        let updater = try await installedUpdater()
        try await commit("Add rulers", in: other)
        try await commit("Fix share sheet", in: other)
        try await git(["push", "--quiet"], in: other)
        await updater.check()
        XCTAssertEqual(updater.state, .available(["Fix share sheet", "Add rulers"]))
    }

    func testLocalCommitsNotInstalledYetCount() async throws {
        let updater = try await installedUpdater()
        try await commit("Local work", in: checkout)
        await updater.check()
        XCTAssertEqual(updater.state, .available(["Local work"]))
    }

    func testUpdateRefusesUncommittedChanges() async throws {
        let updater = try await installedUpdater()
        try "edited".write(to: checkout.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        await updater.update()
        guard case .failed(let message) = updater.state else { return XCTFail("expected a failure, got \(updater.state)") }
        XCTAssertTrue(message.contains("uncommitted changes"), message)
    }

    func testMissingCheckoutFails() async {
        let updater = Updater(source: Updater.Source(repo: root.appendingPathComponent("missing"), commit: "abc"))
        await updater.check()
        guard case .failed = updater.state else { return XCTFail("expected a failure, got \(updater.state)") }
    }

    func testASecondUpdateWhileTheFirstRunsDoesNothing() async throws {
        let commands = CommandLog()
        let updater = Updater(source: Updater.Source(repo: checkout, commit: "abc"),
                              logURL: root.appendingPathComponent("update.log")) { executable, arguments, _, _ in
            commands.append(([executable] + arguments).joined(separator: " "))
            try await Task.sleep(for: .milliseconds(100))
            return (0, Data())
        }
        let first = Task { await updater.update() }
        // The first update waits on its first command: busy already, so a double click cannot start a second one.
        while commands.all.isEmpty { await Task.yield() }
        guard case .updating = updater.state else { return XCTFail("expected updating, got \(updater.state)") }
        await updater.update()
        await first.value
        XCTAssertEqual(commands.all, ["/usr/bin/git status --porcelain --untracked-files=no", "/usr/bin/git pull --ff-only", "scripts/install.sh"])
    }

    // MARK: - Helpers

    private final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []
        var all: [String] { lock.withLock { commands } }
        func append(_ command: String) { lock.withLock { commands.append(command) } }
    }

    private func installedUpdater() async throws -> Updater {
        let head = try await Updater.git(["rev-parse", "HEAD"], in: checkout)
        return Updater(source: Updater.Source(repo: checkout, commit: head))
    }

    private func commit(_ subject: String, in repo: URL) async throws {
        try subject.write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "file.txt"], in: repo)
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--quiet", "-m", subject], in: repo)
    }

    @discardableResult
    private func git(_ arguments: [String], in repo: URL) async throws -> String {
        try await Updater.git(arguments, in: repo)
    }
}
