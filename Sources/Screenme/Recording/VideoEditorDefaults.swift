import Foundation

extension Pref {
    /// The video editor's remembered choices, as JSON `VideoEditorDefaults`. Empty: the defaults.
    static let videoEditorDefaults = PrefKey(name: "videoEditorDefaults", defaultValue: Data())
}

/// What the video editor remembers between editors: the background, auto zoom and how far it goes in, the cursor
/// style, the codec and the GIF settings. An editor reads them when it opens and writes them when one changes; a
/// recording that stops draws its Smooth cursor and makes its GIF with them too.
struct VideoEditorDefaults: Codable, Equatable {
    var canvas = BackgroundSettings()
    var autoZoom = false
    var zoomStrength = 1.8
    var cursor = CursorStyle()
    var codec = VideoCodec.h264
    var gifFPS = 15
    /// The widest a GIF gets, in pixels; 0 keeps the full width.
    var gifMaxWidth = 1280

    /// The saved choices, kept inside what the editor offers.
    static var saved: VideoEditorDefaults {
        get {
            var defaults = (try? JSONDecoder().decode(VideoEditorDefaults.self, from: Prefs[Pref.videoEditorDefaults])) ?? VideoEditorDefaults()
            defaults.canvas.padding = min(max(defaults.canvas.padding, VideoCanvas.paddingRange.lowerBound), VideoCanvas.paddingRange.upperBound)
            if !VideoCanvas.aspects.contains(defaults.canvas.aspect) { defaults.canvas.aspect = .auto }
            defaults.canvas.alignment = .center
            defaults.zoomStrength = min(max(defaults.zoomStrength, AutoZoom.strengthRange.lowerBound), AutoZoom.strengthRange.upperBound)
            defaults.cursor.size = min(max(defaults.cursor.size, CursorStyle.sizeRange.lowerBound), CursorStyle.sizeRange.upperBound)
            return defaults
        }
        set { Prefs[Pref.videoEditorDefaults] = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// A GIF as these settings make it.
    var gif: ExportSpec { .gif(fps: gifFPS, maxWidth: gifMaxWidth, quality: .high) }
}
