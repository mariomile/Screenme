import Foundation

/// Finds what should not be shared in a line of recognized text: emails, phone numbers, card numbers,
/// IBANs, API keys and tokens, IPv4 addresses. Pure, so Redact Sensitive Info and sharing can be tested
/// without Vision.
enum SensitiveInfo {
    enum Kind: String, CaseIterable {
        case email, phone, creditCard, iban, apiKey, ipAddress
    }

    struct Match: Equatable {
        let kind: Kind
        let range: Range<String.Index>
    }

    /// Every match in `text`, in reading order. Matches never overlap: when two kinds claim the same
    /// characters, the more specific one wins (a card number is not also a phone number).
    static func matches(in text: String) -> [Match] {
        var found: [Match] = []
        func add(_ kind: Kind, _ ranges: [Range<String.Index>]) {
            for range in ranges where !found.contains(where: { $0.range.overlaps(range) }) {
                found.append(Match(kind: kind, range: range))
            }
        }
        add(.email, ranges(of: email, in: text))
        add(.apiKey, ranges(of: keyPrefixes, in: text))
        add(.iban, validRuns(of: iban, in: text, separators: " ", isValid: isIBAN))
        add(.creditCard, validRuns(of: cardNumber, in: text, separators: " -", isValid: isCardNumber))
        add(.ipAddress, ranges(of: ipv4, in: text))
        add(.phone, ranges(of: phone, in: text).filter { isPhoneNumber(String(text[$0])) })
        add(.apiKey, ranges(of: longToken, in: text).filter { isHighEntropy(String(text[$0])) })
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `text` with every match replaced by "[redacted]", and how many were replaced.
    static func mask(_ text: String) -> (text: String, count: Int) {
        let found = matches(in: text)
        var masked = text
        for match in found.reversed() { masked.replaceSubrange(match.range, with: "[redacted]") }
        return (masked, found.count)
    }

    // MARK: Patterns

    private static let email = regex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, caseInsensitive: true)

    private static let keyPrefixes = regex([
        #"sk-[A-Za-z0-9_-]{16,}"#,
        #"(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#,
        #"pk_[A-Za-z0-9_]{16,}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"glpat-[A-Za-z0-9_-]{20,}"#,
        #"npm_[A-Za-z0-9]{30,}"#,
        #"hf_[A-Za-z0-9]{30,}"#,
        #"whsec_[A-Za-z0-9]{20,}"#,
        #"SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,
        #"(?:AKIA|ASIA)[0-9A-Z]{16}"#,
        #"xox[bpas]-[A-Za-z0-9-]{10,}"#,
        #"AIza[0-9A-Za-z_-]{30,}"#,
        #"eyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,}){1,2}"#,
    ].map { "(?<![A-Za-z0-9_])" + $0 }.joined(separator: "|"))

    /// Country code, check digits, then groups of up to four, spaced or not.
    private static let iban = regex(#"(?<![A-Z0-9])[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]{1,4}){3,8}(?![A-Z0-9])"#)

    private static let cardNumber = regex(#"(?<![0-9])[0-9]{1,6}(?:[ -]?[0-9]{1,6}){1,9}(?![0-9])"#)

    private static let ipv4 = regex(#"(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![0-9]|\.[0-9])"#)

    /// An optional +country code and area code in parentheses, then groups of digits split by spaces or dashes
    /// (a long last group too: "333 1234567"), or one run of digits after a +. Dots are left out: they are
    /// versions, amounts and addresses.
    private static let phone = regex(#"(?<![\w+])(?:\+[0-9]{1,3}[ -]?)?(?:\([0-9]{1,4}\)[ -]?)?[0-9]{1,5}(?:[ -][0-9]{2,10}){1,4}(?![\w-])|(?<![\w+])\+[0-9]{8,15}(?!\w)"#)

    /// Long runs of key-like characters, judged by `isHighEntropy`.
    private static let longToken = regex(#"(?<![A-Za-z0-9_+/=-])[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9_+/=-])"#)

    // MARK: Checks

    /// The Luhn checksum every card number carries, over 13 to 19 digits.
    static func isCardNumber(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count), digits.allSatisfy(\.isASCIIDigit) else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            var value = character.wholeNumberValue ?? 0
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    /// ISO 13616: 15 to 34 characters, and the number with its first four characters moved to the end is 1 mod 97.
    static func isIBAN(_ text: String) -> Bool {
        guard (15...34).contains(text.count), text.allSatisfy({ $0.isASCIIDigit || ("A"..."Z").contains($0) }) else { return false }
        var remainder = 0
        for character in text.dropFirst(4) + text.prefix(4) {
            let value = character.wholeNumberValue ?? Int(character.asciiValue! - 55) // A = 10
            for digit in String(value) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }

    /// 8 to 15 digits. A + or an area code in parentheses settles it; otherwise the groups must not read as
    /// something else: a date (2026-10-21, 21 10 2026), years or figures in fours (2023 2024), or thousands (12 500 000).
    private static func isPhoneNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isASCIIDigit).count
        guard (8...15).contains(digits) else { return false }
        if text.hasPrefix("+") || text.hasPrefix("(") { return true }
        let groups = text.split(whereSeparator: { $0 == "-" || $0 == " " }).map(\.count)
        let isDate = groups.count == 3 && groups[1] <= 2 && ((groups[0] == 4 && groups[2] <= 2) || (groups[0] <= 2 && groups[2] == 4))
        let isFours = groups.allSatisfy { $0 == 4 }
        let isThousands = groups[0] <= 3 && groups.dropFirst().allSatisfy { $0 == 3 }
        return !isDate && !isFours && !isThousands
    }

    /// A random-looking string with letters and digits mixed. Random hex runs about 3.8 bits of entropy per character
    /// and random base64 about 4.7, while words joined into identifiers stay near 4: hex gets the lower bar.
    private static func isHighEntropy(_ text: String) -> Bool {
        guard text.contains(where: \.isASCIIDigit), text.contains(where: \.isLetter) else { return false }
        let isHex = text.allSatisfy { $0.isHexDigit }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let length = Double(text.count)
        let entropy = counts.values.reduce(0.0) { total, count in
            let p = Double(count) / length
            return total - p * log2(p)
        }
        return entropy >= (isHex ? 3.0 : 4.3)
    }

    // MARK: Helpers

    /// Every pattern, compiled once in its static. Nil only for a pattern that does not compile, which then matches
    /// nothing instead of crashing; a test checks that none is nil.
    static var patterns: [NSRegularExpression?] { [email, keyPrefixes, iban, cardNumber, ipv4, phone, longToken] }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func ranges(of regex: NSRegularExpression?, in text: String) -> [Range<String.Index>] {
        guard let regex else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// Greedy patterns can run into what is around them (an expiry date after a card number, a word after an IBAN):
    /// for each candidate, the first and longest run of its groups whose characters, separators left out, pass `isValid`.
    private static func validRuns(of regex: NSRegularExpression?, in text: String, separators: String,
                                  isValid: (String) -> Bool) -> [Range<String.Index>] {
        ranges(of: regex, in: text).compactMap { candidate in
            let groups = text[candidate].split(whereSeparator: { separators.contains($0) }).map { $0.startIndex..<$0.endIndex }
            for first in groups.indices {
                for last in groups.indices.reversed() where last >= first {
                    let run = groups[first].lowerBound..<groups[last].upperBound
                    if isValid(text[run].filter { !separators.contains($0) }) { return run }
                }
            }
            return nil
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
