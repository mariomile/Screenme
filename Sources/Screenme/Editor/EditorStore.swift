import Foundation

/// Preference keys owned by the editor. Values are JSON strings, decoded on demand, so there are
/// no defaults to register: an empty string means "use the built-in default".
extension Pref {
    static func editorStyle(_ tool: ToolKind) -> PrefKey<String> {
        PrefKey(name: "editor.style.\(tool.rawValue)", defaultValue: "")
    }
    static let editorBackground = PrefKey(name: "editor.background", defaultValue: "")
    static let editorBackgroundPresets = PrefKey(name: "editor.backgroundPresets", defaultValue: "")
    /// The spotlight dim level a new document starts with: the last one used.
    static let editorSpotlightDim = PrefKey(name: "editor.spotlightDim", defaultValue: 0.6)
    /// Copy in the editor also saves the edits to the capture and closes the window.
    static let editorCloseAfterCopy = PrefKey(name: "editor.closeAfterCopy", defaultValue: false)
}

enum EditorStore {
    private static func load<T: Decodable>(_ key: PrefKey<String>, as type: T.Type) -> T? {
        let raw = Prefs[key]
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to key: PrefKey<String>) {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return }
        Prefs[key] = string
    }

    static func style(for tool: ToolKind) -> ToolStyle {
        load(Pref.editorStyle(tool), as: ToolStyle.self) ?? tool.traits.style
    }

    static func save(style: ToolStyle, for tool: ToolKind) {
        save(style, to: Pref.editorStyle(tool))
    }

    /// The last background settings. The wrap itself always starts switched off.
    static func background() -> BackgroundSettings {
        var settings = load(Pref.editorBackground, as: BackgroundSettings.self) ?? BackgroundSettings()
        settings.enabled = false
        return settings
    }

    static func save(background: BackgroundSettings) {
        save(background, to: Pref.editorBackground)
    }

    static func presets() -> [BackgroundPreset] {
        load(Pref.editorBackgroundPresets, as: [BackgroundPreset].self) ?? []
    }

    static func save(presets: [BackgroundPreset]) {
        save(presets, to: Pref.editorBackgroundPresets)
    }
}
