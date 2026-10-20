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
}

enum ScreenmeError: LocalizedError {
    case displayNotFound
    case recordingFailed
    case nothingToCapture

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "Screenme could not find the display to capture."
        case .recordingFailed: "The recording could not be saved."
        case .nothingToCapture: "There is no previous area to capture yet."
        }
    }
}

extension CaptureTarget {
    /// Builds the ScreenCaptureKit filter and configuration for this target.
    /// Screenme's own windows (overlays, Quick Access) are always excluded.
    /// `retina: false` produces 1x output (one pixel per point).
    func streamSetup(showsCursor: Bool = false, retina: Bool = true) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let config = SCStreamConfiguration()
        config.showsCursor = showsCursor
        config.ignoreShadowsSingleWindow = !Prefs[Pref.windowShadow]

        switch self {
        case .window(let window):
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let windowScale = retina ? CGFloat(filter.pointPixelScale) : 1
            config.width = Int(filter.contentRect.width * windowScale)
            config.height = Int(filter.contentRect.height * windowScale)
            return (filter, config)

        case .display(let screen), .area(_, let screen):
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                throw ScreenmeError.displayNotFound
            }
            // Desktop icon covers belong to Screenme but must appear in captures, or hidden icons come back.
            let coverIDs = await MainActor.run { DesktopIcons.coverWindowIDs }
            let covers = content.windows.filter { coverIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: covers)
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
        case .window(let window):
            CGRect(x: window.frame.minX, y: Self.primaryHeight - window.frame.maxY,
                   width: window.frame.width, height: window.frame.height)
        }
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}
