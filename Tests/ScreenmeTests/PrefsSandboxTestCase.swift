import XCTest
@testable import Screenme

/// Base for tests that read or write preferences: each test gets its own throwaway suite, so it never sees
/// or changes the user's settings, and nothing carries over between tests.
class PrefsSandboxTestCase: XCTestCase {
    private var realStore: UserDefaults!
    private var suiteName: String!

    /// Before `setUp`, so subclasses that set preferences in either see the sandbox.
    override func setUpWithError() throws {
        try super.setUpWithError()
        realStore = Prefs.store
        suiteName = "dev.mariomiletta.ScreenmeTests.\(UUID().uuidString)"
        Prefs.store = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        Prefs.store.removePersistentDomain(forName: suiteName)
        Prefs.store = realStore
        super.tearDown()
    }

    /// A new empty folder, deleted after the test.
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
