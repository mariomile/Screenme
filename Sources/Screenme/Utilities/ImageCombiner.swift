import AppKit

/// Joins several screenshots into one image, side by side or stacked, for "Combine" in History.
enum ImageCombiner {
    enum Layout {
        case sideBySide, stacked
    }

    /// The images in order, scaled to the smallest common height (side by side) or width (stacked),
    /// so nothing is enlarged. Nil when fewer than two images decode.
    static func combine(_ urls: [URL], layout: Layout) -> CGImage? {
        let images = urls.compactMap { Thumbnails.decodeImage(at: $0, maxPixelSize: nil) }
        guard images.count >= 2 else { return nil }
        let sizes: [CGSize] = switch layout {
        case .sideBySide:
            images.map { let height = CGFloat(images.map(\.height).min()!); return CGSize(width: CGFloat($0.width) * height / CGFloat($0.height), height: height) }
        case .stacked:
            images.map { let width = CGFloat(images.map(\.width).min()!); return CGSize(width: width, height: CGFloat($0.height) * width / CGFloat($0.width)) }
        }
        let total = switch layout {
        case .sideBySide: CGSize(width: sizes.map(\.width).reduce(0, +), height: sizes[0].height)
        case .stacked: CGSize(width: sizes[0].width, height: sizes.map(\.height).reduce(0, +))
        }
        guard let context = CGContext(data: nil, width: Int(total.width.rounded()), height: Int(total.height.rounded()),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Left to right, or top to bottom in a bottom-left origin context.
        var cursor: CGFloat = layout == .stacked ? total.height : 0
        for (image, size) in zip(images, sizes) {
            switch layout {
            case .sideBySide:
                context.draw(image, in: CGRect(x: cursor, y: 0, width: size.width, height: size.height))
                cursor += size.width
            case .stacked:
                cursor -= size.height
                context.draw(image, in: CGRect(x: 0, y: cursor, width: size.width, height: size.height))
            }
        }
        return context.makeImage()
    }

    /// Combines `items`, oldest first, into a new capture and opens it in the editor.
    @MainActor
    static func combineAndEdit(_ items: [CaptureItem], layout: Layout) {
        let urls = items.sorted { $0.date < $1.date }.map(\.url)
        guard let image = combine(urls, layout: layout), let url = try? Storage.write(image) else {
            Toast.show("Could not combine", symbol: "exclamationmark.triangle.fill")
            return
        }
        let item = CaptureItem(url: url, kind: .image)
        CaptureHistory.shared.add(item)
        AnnotationEditor.open(item)
    }
}
