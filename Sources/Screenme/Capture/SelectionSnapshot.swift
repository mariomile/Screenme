import AppKit
import ScreenCaptureKit

/// A window the picker can highlight. `frame` is in global Cocoa coordinates.
struct WindowEntry {
    let window: SCWindow
    let frame: CGRect
    let appName: String
}

/// What the screen looked like when the picker opened.
struct ScreenSnapshot {
    var images: [CGDirectDisplayID: CGImage] = [:]
    /// On-screen windows, front to back.
    var windows: [WindowEntry] = []
}

enum SnapshotLoader {
    /// Reads the window list and, when `images` is true, grabs one image per screen at native pixel size.
    /// The images go through `CaptureTarget.streamSetup`, so they match a real capture.
    static func load(screens: [NSScreen], images: Bool, showsCursor: Bool) async -> ScreenSnapshot {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return ScreenSnapshot()
        }
        var snapshot = ScreenSnapshot()
        snapshot.windows = orderedWindows(content)
        guard images else { return snapshot }

        await withTaskGroup(of: (CGDirectDisplayID, CGImage?).self) { group in
            for screen in screens {
                let id = screen.displayID
                let target = CaptureTarget.display(screen)
                group.addTask {
                    guard let (filter, config) = try? await target.streamSetup(showsCursor: showsCursor) else { return (id, nil) }
                    return (id, try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
                }
            }
            for await (id, image) in group {
                if let image { snapshot.images[id] = image }
            }
        }
        return snapshot
    }

    private static func orderedWindows(_ content: SCShareableContent) -> [WindowEntry] {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // CGWindowList is ordered front to back; ScreenCaptureKit is not.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let window = byID[number],
                  let app = window.owningApplication,
                  window.windowLayer == 0,              // skips the menu bar, Dock, notifications
                  app.processID != ownPID,
                  app.bundleIdentifier != "com.apple.dock",
                  window.frame.width >= 60, window.frame.height >= 40,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { return nil }
            return WindowEntry(window: window, frame: window.frame.cocoaFlipped, appName: app.applicationName)
        }
    }
}

extension CGImage {
    /// The part of a full-screen snapshot covered by `rect` (global Cocoa points) on `screen`.
    /// `retina: false` resamples to one pixel per point.
    func cropped(to rect: CGRect, on screen: NSScreen, retina: Bool) -> CGImage? {
        let frame = screen.frame
        let visible = rect.intersection(frame)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1, frame.width > 0 else { return nil }
        let scale = CGFloat(width) / frame.width
        let pixels = CGRect(x: (visible.minX - frame.minX) * scale,
                            y: (frame.maxY - visible.maxY) * scale,
                            width: visible.width * scale,
                            height: visible.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixels.isNull, let cut = cropping(to: pixels) else { return nil }
        if retina || scale <= 1.01 { return cut }

        let outWidth = max(1, Int(visible.width.rounded())), outHeight = max(1, Int(visible.height.rounded()))
        guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return cut }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        return context.makeImage() ?? cut
    }
}
