import XCTest
@testable import Screenme

/// Taking over and restoring the macOS screenshot shortcuts rewrites the user's AppleSymbolicHotKeys:
/// the pure halves of both, without touching the real preferences.
@MainActor
final class SystemShortcutsTests: XCTestCase {
    private let screenshotIDs = ["28", "29", "30", "31", "184"]

    private func entry(enabled: Any, parameters: [Int] = [51, 20, 1_179_648]) -> [String: Any] {
        ["enabled": enabled, "value": ["type": "standard", "parameters": parameters] as [String: Any]]
    }

    private func enabled(_ hotKeys: [String: Any], _ id: String) -> Bool? {
        guard let entry = hotKeys[id] as? [String: Any] else { return nil }
        return SystemShortcuts.isEnabled(entry, default: true)
    }

    func testTakeOverThenRestorePutsEveryShortcutBack() {
        let original: [String: Any] = [
            "28": entry(enabled: true),
            "29": entry(enabled: false),
            // 30 is missing: macOS uses its default.
            "31": entry(enabled: 1),
            "184": entry(enabled: 0),
            "64": entry(enabled: true, parameters: [32, 49, 1_048_576]),
        ]

        let taken = SystemShortcuts.takingOver(original, backup: nil)
        for id in screenshotIDs { XCTAssertEqual(enabled(taken.hotKeys, id), false, "shortcut \(id) is off") }
        XCTAssertEqual(enabled(taken.hotKeys, "64"), true, "other shortcuts stay as they were")

        let restored = SystemShortcuts.restoring(taken.hotKeys, backup: taken.backup)
        XCTAssertEqual(enabled(restored, "28"), true)
        XCTAssertEqual(enabled(restored, "29"), false)
        XCTAssertNil(restored["30"], "an entry that did not exist is removed again")
        XCTAssertEqual(enabled(restored, "31"), true)
        XCTAssertEqual(enabled(restored, "184"), false)
        XCTAssertEqual(enabled(restored, "64"), true)
    }

    func testMissingEntriesAreAddedOffAndRemovedOnRestore() {
        let taken = SystemShortcuts.takingOver([:], backup: nil)
        XCTAssertEqual(Set(taken.hotKeys.keys), Set(screenshotIDs))
        for id in screenshotIDs {
            XCTAssertEqual(enabled(taken.hotKeys, id), false)
            let value = (taken.hotKeys[id] as? [String: Any])?["value"] as? [String: Any]
            XCTAssertEqual((value?["parameters"] as? [Int])?.count, 3, "shortcut \(id) gets its default keys")
        }
        XCTAssertTrue(taken.backup.allSatisfy { !$0.existed && $0.enabled })

        XCTAssertTrue(SystemShortcuts.restoring(taken.hotKeys, backup: taken.backup).isEmpty)
    }

    func testSecondTakeOverKeepsTheFirstBackup() {
        let original: [String: Any] = ["28": entry(enabled: true), "29": entry(enabled: false)]
        let first = SystemShortcuts.takingOver(original, backup: nil)

        // Everything is off now because of the first takeover: the second one must not record that as the user's choice.
        let second = SystemShortcuts.takingOver(first.hotKeys, backup: first.backup)
        XCTAssertEqual(second.backup, first.backup)

        let restored = SystemShortcuts.restoring(second.hotKeys, backup: second.backup)
        XCTAssertEqual(enabled(restored, "28"), true)
        XCTAssertEqual(enabled(restored, "29"), false)
        XCTAssertNil(restored["30"])
    }

    func testShortcutTurnedOnSinceTheFirstTakeOverIsRecordedAsOn() {
        let first = SystemShortcuts.takingOver(["29": entry(enabled: false)], backup: nil)
        var changed = first.hotKeys
        changed["29"] = entry(enabled: true)

        let second = SystemShortcuts.takingOver(changed, backup: first.backup)
        XCTAssertEqual(second.backup.first { $0.id == 29 }, SystemShortcuts.SavedShortcut(id: 29, existed: true, enabled: true))
    }

    func testRestoreWithoutABackupTurnsEveryShortcutOn() {
        let off = SystemShortcuts.takingOver([:], backup: nil).hotKeys
        let restored = SystemShortcuts.restoring(off, backup: nil)
        for id in screenshotIDs { XCTAssertEqual(enabled(restored, id), true) }
    }
}
