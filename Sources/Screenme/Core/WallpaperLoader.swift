import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The desktop picture, for the desktop icon covers and the editor's Wallpaper background.
/// Decode the file with `Thumbnails.decodeImage(at:maxPixelSize:)`.
enum WallpaperLoader {
    /// The picture file behind `screen`'s wallpaper. A rotating folder keeps its current pick private,
    /// so this is the folder's first picture. Dynamic and video wallpapers have no file: use `snapshot`.
    @MainActor
    static func pictureURL(for screen: NSScreen) -> URL? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return url }
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Captures only the wallpaper windows of a display with ScreenCaptureKit.
    static func snapshot(displayID: CGDirectDisplayID, pixelSize: CGSize) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let wallpapers = content.windows.filter { $0.windowLayer < iconLevel }
        guard !wallpapers.isEmpty else { return nil }
        let filter = SCContentFilter(display: display, including: wallpapers)
        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
