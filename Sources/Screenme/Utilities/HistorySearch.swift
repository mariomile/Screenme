import Foundation

/// What the History search box matches: every word of the query must appear in the capture's date, kind and file name,
/// or in the text found in the image. Case and accents do not matter.
enum HistorySearch {
    /// The words of `query`, folded for comparing.
    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// True when every token is in `details` or in `imageText`. No tokens matches everything.
    static func matches(_ tokens: [String], details: String, imageText: String?) -> Bool {
        guard !tokens.isEmpty else { return true }
        let details = fold(details)
        let text = imageText.map(fold)
        return tokens.allSatisfy { details.contains($0) || text?.contains($0) == true }
    }

    /// The line of the image text that holds the first token found in it, cut to `limit` characters.
    /// Nil when the text has none of the tokens.
    static func excerpt(of imageText: String?, matching tokens: [String], limit: Int = 140) -> String? {
        guard let imageText, !tokens.isEmpty else { return nil }
        for line in imageText.split(whereSeparator: \.isNewline) {
            let folded = fold(String(line))
            guard tokens.contains(where: folded.contains) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
        }
        return nil
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
