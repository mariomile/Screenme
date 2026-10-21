import AppKit

extension Pref {
    static let watermarkEnabled = PrefKey(name: "watermarkEnabled", defaultValue: false)
    static let watermarkText = PrefKey(name: "watermarkText", defaultValue: "")
    static let watermarkCorner = PrefKey(name: "watermarkCorner", defaultValue: WatermarkCorner.bottomRight)
}

enum WatermarkCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// A line of text in a corner of every screenshot and recording, when turned on in Settings.
/// Screenshots get it drawn in when they are delivered; recordings film a small overlay window.
enum Watermark {
    static var text: String? {
        let text = Prefs[Pref.watermarkText].trimmingCharacters(in: .whitespacesAndNewlines)
        return Prefs[Pref.watermarkEnabled] && !text.isEmpty ? text : nil
    }

    /// Text size for a picture whose shorter side is `side` long, in the picture's own units.
    static func fontSize(forShortSide side: CGFloat) -> CGFloat { max(11, side * 0.028) }

    static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = size * 0.25
        shadow.shadowOffset = CGSize(width: 0, height: -size * 0.05)
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .shadow: shadow,
        ])
    }

    /// Where text of `size` goes inside `bounds` (bottom-left origin), one text height from the edges.
    static func frame(of size: CGSize, in bounds: CGRect, margin: CGFloat) -> CGRect {
        let corner = Prefs[Pref.watermarkCorner]
        let x = corner == .topLeft || corner == .bottomLeft ? bounds.minX + margin : bounds.maxX - margin - size.width
        let y = corner == .bottomLeft || corner == .bottomRight ? bounds.minY + margin : bounds.maxY - margin - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// `image` with the watermark drawn in, or unchanged when it is off.
    static func applied(to image: CGImage) -> CGImage {
        guard let text else { return image }
        return image.overdrawn { context, bounds in
            let size = fontSize(forShortSide: min(bounds.width, bounds.height))
            let string = attributed(text, size: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(in: frame(of: string.size(), in: bounds, margin: size))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The watermark over a recording: a click-through window covering the recorded area, filmed with it.
@MainActor
final class WatermarkOverlay {
    let panel: FloatingPanel

    init?(frame: CGRect) {
        guard let text = Watermark.text else { return nil }
        panel = FloatingPanel(frame: frame, level: .popUpMenu, hasShadow: false, ignoresMouse: true,
                              collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let size = Watermark.fontSize(forShortSide: min(frame.width, frame.height))
        let label = NSTextField(labelWithAttributedString: Watermark.attributed(text, size: size))
        label.sizeToFit()
        label.frame = Watermark.frame(of: label.frame.size, in: root.bounds, margin: size)
        root.addSubview(label)
        panel.contentView = root
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
}
