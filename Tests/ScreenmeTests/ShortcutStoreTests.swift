import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Screenme

final class ShortcutStoreTests: PrefsSandboxTestCase {
    private let cmdShift = UInt32(cmdKey | shiftKey)
    private func combo(_ key: Int, _ modifiers: Int) -> KeyCombo { KeyCombo(keyCode: UInt32(key), modifiers: UInt32(modifiers)) }

    func testDefaultsApplyWhenNothingIsSaved() {
        XCTAssertEqual(ShortcutStore.combo(for: .captureArea), KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: cmdShift))
        XCTAssertEqual(ShortcutStore.combo(for: .captureFullscreen), KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift))
        XCTAssertEqual(ShortcutStore.combo(for: .recordScreen), KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: cmdShift))
        XCTAssertEqual(ShortcutStore.combo(for: .captureText), KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: cmdShift))
        XCTAssertEqual(ShortcutStore.combo(for: .allInOne), KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: cmdShift))
        XCTAssertNil(ShortcutStore.combo(for: .openHistory))
    }

    func testDefaultCombosAreUnique() {
        let combos = ShortcutAction.allCases.compactMap(\.defaultCombo)
        XCTAssertEqual(Set(combos).count, combos.count)
    }

    func testSetOverridesTheDefault() {
        let custom = combo(kVK_ANSI_9, controlKey | optionKey)
        ShortcutStore.set(custom, for: .captureArea)
        XCTAssertEqual(ShortcutStore.combo(for: .captureArea), custom)
        XCTAssertEqual(ShortcutStore.combo(for: .recordScreen), ShortcutAction.recordScreen.defaultCombo, "other actions keep their defaults")
    }

    func testSetCanGiveANormallyEmptyActionAShortcut() {
        let custom = combo(kVK_ANSI_H, cmdKey | optionKey)
        ShortcutStore.set(custom, for: .openHistory)
        XCTAssertEqual(ShortcutStore.combo(for: .openHistory), custom)
    }

    func testExplicitNilMeansNoShortcutNotDefault() {
        ShortcutStore.set(nil, for: .captureArea)
        XCTAssertNil(ShortcutStore.combo(for: .captureArea))
        XCTAssertEqual(ShortcutStore.combo(for: .captureFullscreen), ShortcutAction.captureFullscreen.defaultCombo)
    }

    func testAllCombosAgreesWithComboForEveryAction() {
        ShortcutStore.set(nil, for: .captureArea)
        ShortcutStore.set(combo(kVK_ANSI_H, cmdKey | optionKey), for: .openHistory)
        let all = ShortcutStore.allCombos()
        XCTAssertNil(all[.captureArea], "an action without a shortcut is absent")
        XCTAssertNil(all[.measure], "so is one without a default")
        XCTAssertEqual(all[.openHistory], combo(kVK_ANSI_H, cmdKey | optionKey))
        for action in ShortcutAction.allCases { XCTAssertEqual(all[action], ShortcutStore.combo(for: action), "\(action)") }
    }

    func testResetAllRestoresDefaults() {
        ShortcutStore.set(nil, for: .captureArea)
        ShortcutStore.set(combo(kVK_ANSI_9, cmdKey), for: .recordScreen)
        ShortcutStore.resetAll()
        for action in ShortcutAction.allCases {
            XCTAssertEqual(ShortcutStore.combo(for: action), action.defaultCombo, action.rawValue)
        }
    }

    func testActionUsingFindsTheOwner() {
        XCTAssertEqual(ShortcutStore.action(using: ShortcutAction.captureArea.defaultCombo!), .captureArea)
        XCTAssertNil(ShortcutStore.action(using: combo(kVK_ANSI_Z, cmdKey)))

        // Moving a shortcut frees the old combo and claims the new one.
        let custom = combo(kVK_ANSI_9, cmdKey)
        ShortcutStore.set(custom, for: .captureArea)
        XCTAssertEqual(ShortcutStore.action(using: custom), .captureArea)
        XCTAssertNil(ShortcutStore.action(using: ShortcutAction.captureArea.defaultCombo!))

        // A cleared default is no longer taken.
        ShortcutStore.set(nil, for: .recordScreen)
        XCTAssertNil(ShortcutStore.action(using: ShortcutAction.recordScreen.defaultCombo!))
    }

    func testChangesPostNotification() {
        let set = expectation(forNotification: .shortcutsChanged, object: nil)
        ShortcutStore.set(nil, for: .captureArea)
        wait(for: [set], timeout: 1)
        let reset = expectation(forNotification: .shortcutsChanged, object: nil)
        ShortcutStore.resetAll()
        wait(for: [reset], timeout: 1)
    }

    func testCorruptStoredDataFallsBackToDefaults() {
        Prefs[Pref.shortcuts] = Data("not json".utf8)
        XCTAssertEqual(ShortcutStore.combo(for: .captureArea), ShortcutAction.captureArea.defaultCombo)
    }

    func testTestsNeverTouchStandardDefaults() {
        ShortcutStore.set(nil, for: .captureArea)
        XCTAssertTrue(Prefs.store !== UserDefaults.standard)
        XCTAssertNotEqual(UserDefaults.standard.data(forKey: Pref.shortcuts.name), Prefs[Pref.shortcuts])
    }

    // MARK: KeyCombo

    func testKeyComboCodableRoundTrip() throws {
        let original = combo(kVK_ANSI_K, cmdKey | shiftKey | optionKey | controlKey)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)

        let map: [String: KeyCombo?] = ["a": original, "b": nil]
        let back = try JSONDecoder().decode([String: KeyCombo?].self, from: JSONEncoder().encode(map))
        XCTAssertEqual(back["a"], .some(original))
        XCTAssertEqual(back["b"], .some(nil), "an explicit nil must survive the round trip")
    }

    func testEventModifiersConversion() {
        XCTAssertEqual(combo(kVK_ANSI_A, cmdKey).eventModifiers, [.command])
        XCTAssertEqual(combo(kVK_ANSI_A, cmdKey | shiftKey).eventModifiers, [.command, .shift])
        XCTAssertEqual(combo(kVK_ANSI_A, controlKey | optionKey).eventModifiers, [.control, .option])
        XCTAssertEqual(combo(kVK_ANSI_A, 0).eventModifiers, [])
    }

    func testInitFromKeyEventConvertsToCarbonModifiers() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .capsLock],
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "a",
                                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
        let result = KeyCombo(event: event)
        XCTAssertEqual(result.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(result.modifiers, UInt32(cmdKey | optionKey), "caps lock is not a shortcut modifier")
        XCTAssertEqual(result.eventModifiers, [.command, .option])
    }

    func testDisplayUsesMacModifierOrder() {
        XCTAssertEqual(combo(kVK_Return, cmdKey | shiftKey | optionKey | controlKey).display, "⌃⌥⇧⌘↩")
        XCTAssertEqual(combo(kVK_Space, cmdKey).display, "⌘Space")
        XCTAssertEqual(combo(kVK_F5, 0).display, "F5")
    }
}
