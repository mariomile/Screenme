import AppKit

/// Joins several screenshots into one image, side by side or stacked, for "Combine" in History
/// and "Before & After".
enum ImageCombiner {
    enum Layout {
        case sideBySide, stacked
    }

    /// The images in order, scaled to the smallest common height (side by side) or width (stacked),
    /// so nothing is enlarged. Nil when fewer than two images decode.
    static func combine(_ urls: [URL], layout: Layout) -> CGImage? {
        let images = urls.compactMap { Thumbnails.decodeImage(at: $0, maxPixelSize: nil) }
        guard images.count >= 2 else { return nil }
        return compose(images, layout: layout)
    }

    /// Two screenshots with a "Before" and an "After" pill, on a neutral background with a thin gap.
    /// Stacked when the images are wider than tall, side by side otherwise. Nil unless both decode.
    static func beforeAfter(before: URL, after: URL) -> CGImage? {
        guard let first = Thumbnails.decodeImage(at: before, maxPixelSize: nil),
              let second = Thumbnails.decodeImage(at: after, maxPixelSize: nil) else { return nil }
        return compose([first, second], layout: first.width > first.height ? .stacked : .sideBySide, labels: ["Before", "After"])
    }

    /// `labels` also add a gap and a background between the images, and a pill in the corner of each.
    private static func compose(_ images: [CGImage], layout: Layout, labels: [String] = []) -> CGImage? {
        let sizes: [CGSize] = switch layout {
        case .sideBySide:
            images.map { let height = CGFloat(images.map(\.height).min()!); return CGSize(width: CGFloat($0.width) * height / CGFloat($0.height), height: height) }
        case .stacked:
            images.map { let width = CGFloat(images.map(\.width).min()!); return CGSize(width: width, height: CGFloat($0.height) * width / CGFloat($0.width)) }
        }
        let gap = labels.isEmpty ? 0 : max(4, (layout == .sideBySide ? sizes[0].height : sizes[0].width) * 0.012).rounded()
        let gaps = gap * CGFloat(images.count - 1)
        let total = switch layout {
        case .sideBySide: CGSize(width: sizes.map(\.width).reduce(0, +) + gaps, height: sizes[0].height)
        case .stacked: CGSize(width: sizes[0].width, height: sizes.map(\.height).reduce(0, +) + gaps)
        }
        return CGImage.drawn(width: Int(total.width.rounded()), height: Int(total.height.rounded()),
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { context in
            context.interpolationQuality = .high
            if !labels.isEmpty {
                context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                context.fill(CGRect(origin: .zero, size: total))
            }
            // Left to right, or top to bottom in a bottom-left origin context.
            var cursor: CGFloat = layout == .stacked ? total.height : 0
            for (index, (image, size)) in zip(images, sizes).enumerated() {
                let frame: CGRect
                switch layout {
                case .sideBySide:
                    frame = CGRect(x: cursor, y: 0, width: size.width, height: size.height)
                    cursor += size.width + gap
                case .stacked:
                    cursor -= size.height
                    frame = CGRect(x: 0, y: cursor, width: size.width, height: size.height)
                    cursor -= gap
                }
                context.draw(image, in: frame)
                if index < labels.count { drawPill(labels[index], in: frame, context) }
            }
        }
    }

    /// A small dark pill with white text in the top-left corner of `frame`, sized to the image.
    private static func drawPill(_ text: String, in frame: CGRect, _ context: CGContext) {
        let fontSize = max(12, (min(frame.width, frame.height) * 0.035).rounded())
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = label.size()
        let inset = (fontSize * 0.8).rounded()
        let pill = CGRect(x: frame.minX + inset, y: frame.maxY - inset - textSize.height - fontSize * 0.5,
                          width: textSize.width + fontSize * 1.2, height: textSize.height + fontSize * 0.5)
        context.setFillColor(CGColor(gray: 0, alpha: 0.7))
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        label.draw(at: CGPoint(x: pill.minX + fontSize * 0.6, y: pill.minY + fontSize * 0.25))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Combines `items`, oldest first, into a new capture and opens it in the editor.
    @MainActor
    static func combineAndEdit(_ items: [CaptureItem], layout: Layout) {
        open(combine(items.sorted { $0.date < $1.date }.map(\.url), layout: layout), failure: "Could not combine")
    }

    /// Before & After of `before` and `after` as a new capture, opened in the editor.
    @MainActor
    static func beforeAfterAndEdit(before: CaptureItem, after: CaptureItem) {
        open(beforeAfter(before: before.url, after: after.url), failure: "Could not compare")
    }

    @MainActor
    private static func open(_ image: CGImage?, failure: String) {
        guard let image, let url = try? Storage.write(image) else {
            Toast.show(failure, symbol: "exclamationmark.triangle.fill")
            return
        }
        let item = CaptureItem(url: url, kind: .image)
        CaptureCoordinator.shared.record(item)
        AnnotationEditor.open(item)
    }
}
