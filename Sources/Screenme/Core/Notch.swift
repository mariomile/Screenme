import AppKit

/// "Hide notch": paints the menu bar black on screens with a camera notch, so the notch disappears
/// into it in screenshots.
enum Notch {
    /// What to paint over a capture of a notched screen: the menu bar `band` inside the `captured` frame,
    /// both global Cocoa points.
    struct Cover: Sendable {
        let band: CGRect
        let captured: CGRect

        /// `image` with the band painted black. Pixels only, so it runs off the main thread.
        func applied(to image: CGImage) -> CGImage {
            guard captured.width > 0 else { return image }
            let scale = CGFloat(image.width) / captured.width
            return image.overdrawn { context, _ in
                context.setFillColor(.black)
                // Both are bottom-left origin: Cocoa screen points and the bitmap context.
                context.fill(CGRect(x: (band.minX - captured.minX) * scale, y: (band.minY - captured.minY) * scale,
                                    width: band.width * scale, height: band.height * scale).integral)
            }
        }
    }

    /// The cover for a capture of `target`, or nil when there is nothing to hide. Reads the screen, so main thread.
    @MainActor
    static func cover(for target: CaptureTarget) -> Cover? {
        guard Prefs[Pref.hideNotch] else { return nil }
        let screen: NSScreen
        switch target {
        case .display(let display): screen = display
        case .area(_, let display): screen = display
        case .window: return nil
        }
        let menuBarHeight = screen.safeAreaInsets.top
        guard menuBarHeight > 0 else { return nil }
        let captured = target.cocoaFrame
        let band = CGRect(x: screen.frame.minX, y: screen.frame.maxY - menuBarHeight, width: screen.frame.width, height: menuBarHeight)
            .intersection(captured)
        guard !band.isNull, !band.isEmpty, captured.width > 0 else { return nil }
        return Cover(band: band, captured: captured)
    }
}
