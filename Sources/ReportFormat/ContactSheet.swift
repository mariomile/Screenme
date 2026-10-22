import CoreGraphics
import CoreText
import Foundation

/// `contact-sheet.png`: every keyframe of a report in one picture, three to a row in time order, each with a big
/// `#N`, its time and what was said under it, on a dark background. An agent reads the whole recording at a glance
/// and opens a frame by its number. `screenme zoom` draws its grids of frames with it too. Pure Core Graphics, so
/// it runs anywhere and is unit tested.
enum ContactSheet {
    struct Cell {
        var image: CGImage
        var number: Int
        var time: Double
        /// What was said while it was on screen, or what happened. Cut to two lines.
        var caption: String
    }

    static let thumbnailWidth: CGFloat = 640
    static let columns = 3
    static let gap: CGFloat = 28
    /// The time line, two lines of caption, and the space around them.
    static let captionHeight: CGFloat = 112

    private static let background = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let panel = CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
    private static let timeColor = CGColor(srgbRed: 0.62, green: 0.62, blue: 0.66, alpha: 1)
    private static let textColor = CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)

    /// The size of the sheet and where each thumbnail box goes, top-left origin. The caption is under each box.
    /// Fewer cells than `columns` make a narrower sheet. `boxHeight` is the height of every thumbnail box.
    static func layout(count: Int, boxHeight: CGFloat, columns: Int = columns) -> (size: CGSize, boxes: [CGRect]) {
        guard count > 0 else { return (.zero, []) }
        let columns = min(count, max(columns, 1))
        let rows = (count + columns - 1) / columns
        let cellHeight = boxHeight + captionHeight
        let size = CGSize(width: CGFloat(columns) * thumbnailWidth + CGFloat(columns + 1) * gap,
                          height: CGFloat(rows) * cellHeight + CGFloat(rows) * gap + gap)
        let boxes = (0..<count).map { index in
            CGRect(x: gap + CGFloat(index % columns) * (thumbnailWidth + gap),
                   y: gap + CGFloat(index / columns) * (cellHeight + gap),
                   width: thumbnailWidth, height: boxHeight)
        }
        return (size, boxes)
    }

    /// The height of the thumbnail boxes: the middle aspect ratio of the frames, so most fill their box,
    /// kept between a wide strip and a tall portrait.
    static func boxHeight(for images: [CGImage]) -> CGFloat {
        let ratios = images.filter { $0.width > 0 }.map { CGFloat($0.height) / CGFloat($0.width) }.sorted()
        guard !ratios.isEmpty else { return thumbnailWidth * 0.625 }
        return min(max((thumbnailWidth * ratios[ratios.count / 2]).rounded(), 200), 900)
    }

    /// The sheet, `columns` cells to a row, or nil without cells. `tenths` shows each time to the tenth of a second.
    static func render(_ cells: [Cell], columns: Int = columns, tenths: Bool = false) -> CGImage? {
        let (size, boxes) = layout(count: cells.count, boxHeight: boxHeight(for: cells.map(\.image)), columns: columns)
        guard !cells.isEmpty else { return nil }
        let height = size.height
        return CGImage.drawn(width: Int(size.width), height: Int(height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { context in
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: size))
            // Top-left rects into the context's bottom-left space.
            func flip(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height) }

            for (cell, box) in zip(cells, boxes) {
                let flipped = flip(box)
                context.setFillColor(panel)
                context.addPath(CGPath(roundedRect: flipped, cornerWidth: 10, cornerHeight: 10, transform: nil))
                context.fillPath()
                context.saveGState()
                context.addPath(CGPath(roundedRect: flipped, cornerWidth: 10, cornerHeight: 10, transform: nil))
                context.clip()
                context.interpolationQuality = .high
                context.draw(cell.image, in: flip(fit(CGSize(width: cell.image.width, height: cell.image.height), in: box)))
                context.restoreGState()

                drawBadge("#\(cell.number)", at: CGPoint(x: box.minX + 12, y: box.minY + 12), height: height, in: context)
                let time = Duration.format(cell.time, tenths: tenths)
                drawText(time, font: font(22, bold: true), color: timeColor,
                         in: CGRect(x: box.minX + 4, y: box.maxY + 14, width: box.width - 8, height: 28), lines: 1, height: height, context: context)
                drawText(cell.caption, font: font(23, bold: false), color: textColor,
                         in: CGRect(x: box.minX + 4, y: box.maxY + 46, width: box.width - 8, height: 60), lines: 2, height: height, context: context)
            }
        }
    }

    /// `image` scaled down to the thumbnail width (twice that would only make the sheet heavier), or as it is
    /// when it is smaller.
    static func thumbnail(_ image: CGImage) -> CGImage {
        image.scaledDown(maxWidth: Int(thumbnailWidth))
    }

    /// `size` scaled to fit inside `box`, centered.
    static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    // MARK: Text

    private static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    /// A white chip with the keyframe number in black, its top-left corner at `origin` (top-left coordinates).
    private static func drawBadge(_ text: String, at origin: CGPoint, height: CGFloat, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font(34, bold: true), color: CGColor(gray: 0, alpha: 1)))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let chip = CGRect(x: origin.x, y: height - origin.y - 50, width: CGFloat(width) + 28, height: 50)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(gray: 0, alpha: 0.6))
        context.setFillColor(CGColor(gray: 1, alpha: 0.96))
        context.addPath(CGPath(roundedRect: chip, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.textPosition = CGPoint(x: chip.minX + 14, y: chip.minY + 13)
        CTLineDraw(line, context)
    }

    /// `text` in up to `lines` lines inside `rect` (top-left coordinates), the last one cut with an ellipsis.
    private static func drawText(_ text: String, font: CTFont, color: CGColor, in rect: CGRect, lines maxLines: Int,
                                 height: CGFloat, context: CGContext) {
        let string = attributed(text, font: font, color: color)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let ascent = CTFontGetAscent(font), lineHeight = ceil(ascent + CTFontGetDescent(font) + CTFontGetLeading(font)) + 3
        let ellipsis = CTLineCreateWithAttributedString(attributed("…", font: font, color: color))
        var start = 0
        for index in 0..<maxLines where start < string.length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(rect.width))
            if count <= 0 { break }
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            if index == maxLines - 1, start + count < string.length {
                count = string.length - start
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                line = CTLineCreateTruncatedLine(rest, Double(rect.width), .end, ellipsis) ?? line
            }
            context.textPosition = CGPoint(x: rect.minX, y: height - (rect.minY + ascent + CGFloat(index) * lineHeight))
            CTLineDraw(line, context)
            start += count
        }
    }
}
