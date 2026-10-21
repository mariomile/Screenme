import AppKit
import ScreenCaptureKit

/// What the user picked. Area rects are in global Cocoa coordinates (bottom-left origin).
enum CaptureTarget {
    case area(CGRect, NSScreen)
    case window(SCWindow)
    case display(NSScreen)
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// The screen holding `point` (global Cocoa coordinates). Edges count as inside, because the pointer
    /// can sit exactly on the top or right border of a display; off every screen, the nearest one.
    static func at(_ point: CGPoint) -> NSScreen {
        if let hit = screens.first(where: { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(point) }) { return hit }
        func distance(to rect: CGRect) -> CGFloat {
            hypot(point.x - min(max(point.x, rect.minX), rect.maxX), point.y - min(max(point.y, rect.minY), rect.maxY))
        }
        return screens.min { distance(to: $0.frame) < distance(to: $1.frame) } ?? screens[0]
    }

    static var underMouse: NSScreen { at(NSEvent.mouseLocation) }
}

extension CGRect {
    /// Converts a global rect between ScreenCaptureKit / Core Graphics (top-left origin) and Cocoa (bottom-left origin).
    /// The flip is its own inverse.
    var cocoaFlipped: CGRect {
        CGRect(x: minX, y: CaptureTarget.primaryHeight - maxY, width: width, height: height)
    }
}

enum ScreenmeError: LocalizedError {
    case displayNotFound
    case recordingFailed
    case nothingToCapture
    case windowNotFound(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "Screenme could not find the display to capture."
        case .recordingFailed: "The recording could not be saved."
        case .nothingToCapture: "There is no previous area to capture yet."
        case .windowNotFound(let app): "Screenme could not find a window of \(app) on screen."
        }
    }
}

extension CaptureTarget {
    /// The one ScreenCaptureKit filter and configuration for this target, used by stills, recordings,
    /// scrolling capture and the picker's snapshot. Screenme's own windows are excluded, except the desktop
    /// icon covers (or hidden icons come back in the picture) and `extraWindows`, which the caller wants filmed.
    /// `retina: false` produces 1x output (one pixel per point). Window shadows follow `Pref.windowShadow`.
    /// `hidingNotifications` leaves notification banners out of display and area captures.
    func streamSetup(showsCursor: Bool = false, retina: Bool = true,
                     including extraWindows: [CGWindowID] = [],
                     hidingNotifications: Bool = false) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let extras = content.windows.filter { extraWindows.contains($0.windowID) }
        let config = SCStreamConfiguration()
        config.showsCursor = showsCursor
        config.ignoreShadowsSingleWindow = !Prefs[Pref.windowShadow]

        switch self {
        case .window(let picked):
            // The window may have moved since the picker listed it.
            let window = content.windows.first { $0.windowID == picked.windowID } ?? picked
            if extras.isEmpty {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = retina ? CGFloat(filter.pointPixelScale) : 1
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                return (filter, config)
            }
            // The window plus the extra windows, filmed from its display so the extras can be part of the picture.
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
                throw ScreenmeError.displayNotFound
            }
            let filter = SCContentFilter(display: display, including: [window] + extras)
            // Both frames are global top-left coordinates, so the difference is display-local.
            config.sourceRect = CGRect(x: window.frame.minX - display.frame.minX, y: window.frame.minY - display.frame.minY,
                                       width: window.frame.width, height: window.frame.height)
            let displayScale = await MainActor.run { NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor }
            let scale = retina ? displayScale ?? 2 : 1
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            return (filter, config)

        case .display(let screen), .area(_, let screen):
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                throw ScreenmeError.displayNotFound
            }
            let coverIDs = await MainActor.run { DesktopIcons.coverWindowIDs }
            let kept = content.windows.filter { coverIDs.contains($0.windowID) } + extras
            // Excluding Notification Center leaves out banners that arrive later too, not just the ones on screen now.
            let excludedIDs = [Bundle.main.bundleIdentifier] + (hidingNotifications ? ["com.apple.notificationcenterui"] : [])
            let excluded = content.applications.filter { excludedIDs.contains($0.bundleIdentifier) }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: kept)
            let scale = retina ? screen.backingScaleFactor : 1
            var size = screen.frame.size
            if case .area(let rect, _) = self {
                // ScreenCaptureKit wants display-local points with a top-left origin.
                config.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                           y: screen.frame.maxY - rect.maxY,
                                           width: rect.width, height: rect.height)
                size = rect.size
            }
            config.width = Int(size.width * scale)
            config.height = Int(size.height * scale)
            return (filter, config)
        }
    }

    /// The on-screen frame in global Cocoa coordinates, used to outline a recording.
    var cocoaFrame: CGRect {
        switch self {
        case .area(let rect, _): rect
        case .display(let screen): screen.frame
        case .window(let window): window.frame.cocoaFlipped
        }
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}
