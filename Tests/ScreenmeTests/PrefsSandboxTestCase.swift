import XCTest
@testable import Screenme

/// Base for tests that read or write preferences: each test gets its own throwaway suite, so it never sees
/// or changes the user's settings, and nothing carries over between tests.
class PrefsSandboxTestCase: XCTestCase {
    private var realStore: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        realStore = Prefs.store
        suiteName = "dev.mariomiletta.ScreenmeTests.\(UUID().uuidString)"
        Prefs.store = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        Prefs.store.removePersistentDomain(forName: suiteName)
        Prefs.store = realStore
        super.tearDown()
    }
}
