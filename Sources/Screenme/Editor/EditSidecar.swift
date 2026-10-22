import Foundation

/// What keeps a capture's annotations editable after Done flattens them into the file: the hidden folder
/// `Sidecar.edit` next to the capture, holding the pixels as they were before the first edit (`original.<ext>`)
/// and the document (`edit.json`, an `EditDocument`). The capture file stays the flattened deliverable.
///
/// The sidecar is what reopening edits, so it is written first and the capture last: a capture that fails to save
/// leaves the newer document, never a document older than the pixels. A sidecar that cannot be read is moved
/// aside whole and the flattened capture opens instead, never an original with half a document.
enum EditSidecar {
    static func originalURL(for capture: URL) -> URL {
        Sidecar.edit.url(for: capture).appendingPathComponent("original.\(capture.pathExtension)")
    }

    static func documentURL(for capture: URL) -> URL {
        Sidecar.edit.url(for: capture).appendingPathComponent("edit.json")
    }

    /// Done: the original pixels (copied once, before the first edit overwrites them), then the document,
    /// then `flattened` over the capture. When the sidecar cannot be written the capture still saves, flattened,
    /// and the sidecar is set aside so an older document never comes back over newer pixels.
    /// Throws when the capture itself could not be written. Tests pass their own `writeCapture`.
    static func save(_ state: EditState, flattened: Data, to capture: URL,
                     writeCapture: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        do {
            try keepOriginal(of: capture)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(EditDocument(state: state)).write(to: documentURL(for: capture), options: .atomic)
        } catch {
            setAside(for: capture)
        }
        try writeCapture(flattened, capture)
    }

    private static func keepOriginal(of capture: URL) throws {
        let original = originalURL(for: capture)
        guard !FileManager.default.fileExists(atPath: original.path) else { return }
        try FileManager.default.createDirectory(at: Sidecar.edit.url(for: capture), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: capture, to: original)
    }

    /// The original pixels and the saved document, or nil when the capture was never saved from the editor.
    /// A sidecar missing either, or whose document does not decode, is set aside and reads as none.
    static func load(for capture: URL) -> (original: URL, state: EditState)? {
        guard FileManager.default.fileExists(atPath: Sidecar.edit.url(for: capture).path) else { return nil }
        let original = originalURL(for: capture)
        if FileManager.default.fileExists(atPath: original.path),
           let data = try? Data(contentsOf: documentURL(for: capture)),
           let document = try? JSONDecoder().decode(EditDocument.self, from: data) {
            return (original, document.state)
        }
        setAside(for: capture)
        return nil
    }

    /// Renames the sidecar to `.<capture>.screenme-edit.unreadable-<date>`, kept for a person to look at.
    private static func setAside(for capture: URL, now: Date = Date()) {
        let folder = Sidecar.edit.url(for: capture)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let aside = folder.deletingLastPathComponent()
            .appendingPathComponent("\(folder.lastPathComponent).unreadable-\(formatter.string(from: now))", isDirectory: true)
        try? FileManager.default.moveItem(at: folder, to: aside)
    }
}

/// The file `edit.json`. `version` lets a later format tell older files apart; fields added to the document
/// later decode with their defaults (`EditState`, `Annotation`), so a new field never makes an older file unreadable.
struct EditDocument: Codable, Equatable {
    static let currentVersion = 1

    var version = EditDocument.currentVersion
    var state: EditState

    init(state: EditState) {
        self.state = state
    }

    /// Files written before the version existed hold the bare `EditState`: version 0.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.state) else {
            version = 0
            state = try EditState(from: decoder)
            return
        }
        version = try container.decode(Int.self, forKey: .version)
        state = try container.decode(EditState.self, forKey: .state)
    }
}

extension KeyedDecodingContainer {
    /// Replaces `value` with the one stored under `key`, and leaves it (its default) when the key is missing.
    /// For documents whose fields grow over time.
    func decodeIfPresent<T: Decodable>(_ key: Key, into value: inout T) throws {
        if let decoded = try decodeIfPresent(T.self, forKey: key) { value = decoded }
    }
}
