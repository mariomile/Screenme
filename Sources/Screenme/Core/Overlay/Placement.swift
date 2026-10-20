import AppKit

/// Where overlays go relative to the area being captured.
@MainActor
enum Placement {
    /// The screen a target lives on.
    static func screen(for target: CaptureTarget) -> NSScreen {
        switch target {
        case .area(_, let screen), .display(let screen): screen
        case .window: NSScreen.at(CGPoint(x: target.cocoaFrame.midX, y: target.cocoaFrame.midY))
        }
    }

    /// Puts a bar of `size` just below `area`, or above it, or inside its bottom edge when neither fits.
    static func barFrame(size: CGSize, near area: CGRect, on screen: NSScreen, gap: CGFloat = 14) -> CGRect {
        let visible = screen.visibleFrame
        var y = area.minY - gap - size.height
        if y < visible.minY + 8 {
            y = area.maxY + gap
            if y + size.height > visible.maxY - 8 {
                y = max(visible.minY + 8, area.minY + 20)
            }
        }
        var x = area.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
