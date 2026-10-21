import XCTest
@testable import Screenme

final class SensitiveInfoTests: XCTestCase {
    /// Each match as (kind, matched text).
    private func found(_ text: String) -> [(SensitiveInfo.Kind, String)] {
        SensitiveInfo.matches(in: text).map { ($0.kind, String(text[$0.range])) }
    }

    private func assertFinds(_ text: String, _ expected: [(SensitiveInfo.Kind, String)], file: StaticString = #filePath, line: UInt = #line) {
        let actual = found(text)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), "kinds in \"\(text)\"", file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), "text in \"\(text)\"", file: file, line: line)
    }

    func testEmails() {
        assertFinds("Write to mario.rossi+test@example.co.uk today", [(.email, "mario.rossi+test@example.co.uk")])
        assertFinds("FOO@BAR.IO", [(.email, "FOO@BAR.IO")])
        assertFinds("no at sign here, just text", [])
    }

    func testPhoneNumbers() {
        assertFinds("Call +39 333 123 4567 now", [(.phone, "+39 333 123 4567")])
        assertFinds("(555) 123-4567", [(.phone, "(555) 123-4567")])
        assertFinds("555-123-4567", [(.phone, "555-123-4567")])
        assertFinds("+393331234567", [(.phone, "+393331234567")])
    }

    func testEuropeanPhoneFormats() {
        for number in ["+39 333 1234567", "+39 3331234567", "333 1234567", "06 12345678", "+49 30 12345678", "+33 6 12 34 56 78"] {
            assertFinds("Tel. \(number)", [(.phone, number)])
        }
    }

    func testFiguresInGroupsAreNotPhoneNumbers() {
        assertFinds("From 2023 2024", [])
        assertFinds("Revenue 1200 3400 5600", [])
        assertFinds("12 500 000 EUR", [])
        assertFinds("21 10 2026", [])
    }

    func testPhoneLeavesDatesTimesAndShortNumbersAlone() {
        assertFinds("Due 2026-10-21 at 10:30", [])
        assertFinds("21-10-2026", [])
        assertFinds("Room 12 34", [])
        assertFinds("Version 1.2.3", [])
    }

    func testCreditCardsNeedAValidLuhnChecksum() {
        assertFinds("Card 4111 1111 1111 1111 exp 12/27", [(.creditCard, "4111 1111 1111 1111")])
        assertFinds("4242424242424242", [(.creditCard, "4242424242424242")])
        assertFinds("5555-5555-5555-4444", [(.creditCard, "5555-5555-5555-4444")])
        // One digit off: not a card. Too long to be a phone, so nothing.
        assertFinds("4111 1111 1111 1112", [])
    }

    func testCardFollowedByMoreDigitsKeepsOnlyTheCard() {
        assertFinds("4111 1111 1111 1111 1225", [(.creditCard, "4111 1111 1111 1111")])
    }

    func testLuhn() {
        XCTAssertTrue(SensitiveInfo.isCardNumber("378282246310005")) // Amex test number
        XCTAssertFalse(SensitiveInfo.isCardNumber("378282246310006"))
        XCTAssertFalse(SensitiveInfo.isCardNumber("4111"))
    }

    func testIBANs() {
        assertFinds("IBAN: DE89 3704 0044 0532 0130 00", [(.iban, "DE89 3704 0044 0532 0130 00")])
        assertFinds("GB82WEST12345698765432 BIC", [(.iban, "GB82WEST12345698765432")])
        assertFinds("IT60 X054 2811 1010 0000 0123 456 BIC XYZ", [(.iban, "IT60 X054 2811 1010 0000 0123 456")])
        XCTAssertFalse(SensitiveInfo.isIBAN("DE89370400440532013001"))
    }

    func testKnownKeyPrefixes() {
        let keys = [
            "sk-proj-abcdefghijklmnop1234",
            "sk_live_51HxYzAbCdEfGh",
            "pk_test_51HxYzAbCdEfGh",
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "gho_abcdefghijklmnopqrstuvwx",
            "github_pat_11ABCDEFG0123456789_abcdefghij",
            "xoxb-1234567890-abcdefghij",
            "AKIAIOSFODNN7EXAMPLE",
            "AIzaSyA1234567890abcdefghijklmnopqrstu",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijk_lmnop",
        ]
        for key in keys {
            assertFinds("token \(key) here", [(.apiKey, key)])
        }
    }

    func testPrefixInsideAWordIsNotAKey() {
        assertFinds("task-management-is-fun-for-everyone", [])
    }

    func testLongRandomStringsAreKeysButLongWordsAreNot() {
        assertFinds("secret: 9f86d081884c7d659a2feaa0c55ad015", [(.apiKey, "9f86d081884c7d659a2feaa0c55ad015")])
        assertFinds("Qm8vZ2x1Y2tYbnR3UjNkM2pLc0hvV2VyN3Nq", [(.apiKey, "Qm8vZ2x1Y2tYbnR3UjNkM2pLc0hvV2VyN3Nq")])
        assertFinds("kubernetes-deployment-controller-manager-2", [])
        assertFinds("Supercalifragilisticexpialidociousword", [])
    }

    func testIPv4() {
        assertFinds("Server at 192.168.1.20:8080", [(.ipAddress, "192.168.1.20")])
        assertFinds("10.0.0.1 and 256.1.1.1", [(.ipAddress, "10.0.0.1")])
        assertFinds("version 1.2.3.4.5", [])
    }

    func testSeveralMatchesComeInReadingOrderWithoutOverlap() {
        let text = "a@b.com 192.168.0.1 +39 333 123 4567"
        assertFinds(text, [(.email, "a@b.com"), (.ipAddress, "192.168.0.1"), (.phone, "+39 333 123 4567")])
    }
}
