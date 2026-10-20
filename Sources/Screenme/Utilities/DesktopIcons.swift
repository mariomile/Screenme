import AppKit
import ImageIO
import ScreenCaptureKit

/// Hides desktop icons without touching Finder: one borderless window per screen, sitting just
/// above the desktop icons, shows that screen's wallpaper and ignores the mouse.
@MainActor
enum DesktopIcons {
    private(set) static var isHidden = false

    private static var covers: [CGDirectDisplayID: DesktopCover] = [:]
    private static var observers: [NSObjectProtocol] = []

    /// Window IDs of the cover windows. A capture that excludes Screenme's windows should
    /// except these, otherwise the icons come back in the shot.
    static var coverWindowIDs: [CGWindowID] {
        covers.values.map { CGWindowID($0.window.windowNumber) }
    }

    /// Flips the state and confirms it with a toast.
    static func toggle() {
        setHidden(!isHidden)
        Toast.show(isHidden ? "Desktop icons hidden" : "Desktop icons shown",
                   symbol: isHidden ? "eye.slash" : "eye")
    }

    /// Hides or shows the icons without a toast, for callers that manage it themselves (recording).
    static func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if hidden {
            observe()
            rebuild(animated: true)
        } else {
            stopObserving()
            let fading = covers
            covers.removeAll()
            for cover in fading.values { cover.dismiss() }
        }
    }

    // MARK: Screens

    private static func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if isHidden { rebuild(animated: false) } }
        })
        // Each Space can have its own wallpaper.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if isHidden { refreshWallpapers() } }
        })
    }

    private static func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// Creates, moves and removes covers so there is exactly one per screen.
    private static func rebuild(animated: Bool) {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, cover) in covers where !ids.contains(id) {
            cover.dismiss()
            covers.removeValue(forKey: id)
        }
        for screen in screens {
            if let cover = covers[screen.displayID] {
                cover.resize(to: screen)
            } else {
                let cover = DesktopCover(screen: screen)
                covers[screen.displayID] = cover
                cover.present(animated: animated)
            }
        }
    }

    private static func refreshWallpapers() {
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.displayID, $0) })
        for (id, cover) in covers {
            if let screen = screens[id] { cover.loadWallpaper(for: screen) }
        }
    }
}

// MARK: - DesktopCover window

@MainActor
private final class DesktopCover {
    let window: NSWindow
    private let wallpaper = CALayer()
    private var loadTask: Task<Void, Never>?

    init(screen: NSScreen) {
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.animationBehavior = .none
        window.backgroundColor = .black

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(wallpaper)
        wallpaper.frame = view.bounds
        wallpaper.masksToBounds = true
        wallpaper.contentsScale = screen.backingScaleFactor
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        loadWallpaper(for: screen)
    }

    func present(animated: Bool) {
        if animated {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().alphaValue = 1
            }
        } else {
            window.orderFrontRegardless()
        }
    }

    func dismiss() {
        loadTask?.cancel()
        let window = window
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    func resize(to screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        wallpaper.frame = CGRect(origin: .zero, size: screen.frame.size)
        wallpaper.contentsScale = screen.backingScaleFactor
        loadWallpaper(for: screen)
    }

    // MARK: Wallpaper

    func loadWallpaper(for screen: NSScreen) {
        loadTask?.cancel()
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let style = WallpaperStyle(options: options)
        let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                               height: screen.frame.height * screen.backingScaleFactor)
        let scale = screen.backingScaleFactor
        let displayID = screen.displayID

        wallpaper.backgroundColor = style.fill.cgColor
        loadTask = Task { [weak self] in
            var image: CGImage?
            var gravity = style.gravity
            if let url { image = await WallpaperLoader.load(url, style: style, pixelSize: pixelSize) }
            // Dynamic and video wallpapers have no single file: ask the compositor instead.
            if image == nil {
                image = await WallpaperLoader.snapshot(displayID: displayID, pixelSize: pixelSize)
                gravity = .resize
            }
            guard !Task.isCancelled, let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.wallpaper.contentsScale = scale
            self.wallpaper.contents = image
            self.wallpaper.contentsGravity = gravity
            CATransaction.commit()
        }
    }
}

// MARK: - Scaling

private struct WallpaperStyle {
    var scaling: NSImageScaling = .scaleProportionallyUpOrDown
    var allowClipping = true
    var fill: NSColor = .black

    init(options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        if let raw = (options[.imageScaling] as? NSNumber)?.uintValue, let value = NSImageScaling(rawValue: raw) {
            scaling = value
        }
        if let clipping = (options[.allowClipping] as? NSNumber)?.boolValue { allowClipping = clipping }
        if let color = options[.fillColor] as? NSColor { fill = color }
    }

    /// How the system lays the picture out: Fill, Fit, Stretch or Center.
    var gravity: CALayerContentsGravity {
        switch scaling {
        case .scaleAxesIndependently: .resize
        case .scaleNone: .center
        default: allowClipping ? .resizeAspectFill : .resizeAspect
        }
    }
}

private enum WallpaperLoader {
    /// Decodes the wallpaper file at (at most) screen size, off the main thread.
    nonisolated static func load(_ url: URL, style: WallpaperStyle, pixelSize: CGSize) async -> CGImage? {
        var target = url
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // A rotating folder: the system keeps the current pick private, take the first picture.
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = files.filter({ ["jpg", "jpeg", "png", "heic", "tiff"].contains($0.pathExtension.lowercased()) })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else { return nil }
            target = first
        }
        guard let source = CGImageSourceCreateWithURL(target as CFURL, nil) else { return nil }
        if style.scaling == .scaleNone {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let longest = max(pixelSize.width, pixelSize.height) * 1.0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Fill needs the short side to cover the screen, so allow the longest side to be larger.
            kCGImageSourceThumbnailMaxPixelSize: Int(longest * 1.6),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Captures only the wallpaper windows of a display with ScreenCaptureKit.
    nonisolated static func snapshot(displayID: CGDirectDisplayID, pixelSize: CGSize) async -> CGImage? {
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
