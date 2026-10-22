import Foundation

extension Redaction {
    /// The one gate for what leaves the Mac through Share and Upload & Copy Link. With "Hide sensitive info when sharing"
    /// on it is a redacted copy of an image and how many items it hides; otherwise, or when there is nothing to hide,
    /// the capture itself. Throws when the image could not be read: what is shared must not go out unchecked.
    static func shareableCopy(of url: URL) async throws -> (url: URL, hidden: Int) {
        guard Prefs[Pref.hideSensitiveWhenSharing], let copy = try await redactedCopy(of: url) else { return (url, 0) }
        return (copy.url, copy.count)
    }
}
