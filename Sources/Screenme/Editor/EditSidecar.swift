import Foundation

/// What keeps a capture's annotations editable after Done flattens them into the file: a hidden folder
/// `.<file>.screenme-edit/` next to the capture, holding the pixels as they were before the first edit
/// (`original.<ext>`) and the document (`edit.json`). Hidden, like a recording's events sidecar, so History and the
/// CLI's capture listing never show it. The capture file stays the flattened deliverable: Save, Save As, drag out,
/// Copy and Share use it and never the sidecar.
enum EditSidecar {
    static func folder(for capture: URL) -> URL {
        Sidecar.edit.url(for: capture)
    }

    static func originalURL(for capture: URL) -> URL {
        folder(for: capture).appendingPathComponent("original.\(capture.pathExtension)")
    }

    static func stateURL(for capture: URL) -> URL {
        folder(for: capture).appendingPathComponent("edit.json")
    }

    /// Copies the capture's pixels into the sidecar before Done overwrites them. Only the first time:
    /// once there is an original, later saves keep it.
    static func keepOriginal(of capture: URL) throws {
        let original = originalURL(for: capture)
        guard !FileManager.default.fileExists(atPath: original.path) else { return }
        try FileManager.default.createDirectory(at: folder(for: capture), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: capture, to: original)
    }

    static func write(_ state: EditState, for capture: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: folder(for: capture), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL(for: capture), options: .atomic)
    }

    /// The original pixels and the saved document, or nil when the capture was never saved from the editor.
    static func load(for capture: URL) -> (original: URL, state: EditState)? {
        let original = originalURL(for: capture)
        guard FileManager.default.fileExists(atPath: original.path),
              let data = try? Data(contentsOf: stateURL(for: capture)),
              let state = try? JSONDecoder().decode(EditState.self, from: data) else { return nil }
        return (original, state)
    }
}
