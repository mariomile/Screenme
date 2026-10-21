import AppKit

/// "Hide notch": paints the menu bar black on screens with a camera notch, so the notch disappears
/// into it in screenshots.
enum Notch {
    /// `image` is a capture of `target`. Returns it unchanged when there is nothing to hide.
    @MainActor
    static func hidden(in image: CGImage, of target: CaptureTarget) -> CGImage {
        guard Prefs[Pref.hideNotch] else { return image }
        let screen: NSScreen
        switch target {
        case .display(let display): screen = display
        case .area(_, let display): screen = display
        case .window: return image
        }
        let menuBarHeight = screen.safeAreaInsets.top
        guard menuBarHeight > 0 else { return image }
        let captured = target.cocoaFrame
        let band = CGRect(x: screen.frame.minX, y: screen.frame.maxY - menuBarHeight, width: screen.frame.width, height: menuBarHeight)
            .intersection(captured)
        guard !band.isNull, !band.isEmpty, captured.width > 0 else { return image }
        let scale = CGFloat(image.width) / captured.width
        return image.overdrawn { context, _ in
            context.setFillColor(.black)
            // Both are bottom-left origin: Cocoa screen points and the bitmap context.
            context.fill(CGRect(x: (band.minX - captured.minX) * scale, y: (band.minY - captured.minY) * scale,
                                width: band.width * scale, height: band.height * scale).integral)
        }
    }
}
