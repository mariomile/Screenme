import AppKit

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

    /// Hides the icons for a capture or recording, which shows them again when it ends. Returns false when they
    /// were already hidden, so they stay that way. `settle` waits for the covers to fade in before the screen is read.
    static func hideForCapture(settle: Bool) async -> Bool {
        guard !isHidden else { return false }
        setHidden(true)
        if settle { try? await Task.sleep(for: .milliseconds(700)) }
        return true
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
        let url = WallpaperLoader.pictureURL(for: screen)
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
            if let url {
                // Fill needs the short side to cover the screen, so allow the longest side to be larger.
                let maxPixelSize = style.scaling == .scaleNone ? nil : Int(max(pixelSize.width, pixelSize.height) * 1.6)
                image = await Task.detached { Thumbnails.decodeImage(at: url, maxPixelSize: maxPixelSize) }.value
            }
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
