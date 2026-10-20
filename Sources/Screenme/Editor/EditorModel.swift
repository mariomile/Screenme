import AppKit

// MARK: - Color

/// A plain sRGB color that is Codable and Equatable, so styles can be saved and compared.
struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor.black.usingColorSpace(.sRGB)!
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }

    func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var isLight: Bool { luminance > 0.62 }
    /// Readable text color on top of this color.
    var contrast: RGBA { isLight ? RGBA(0.09, 0.09, 0.1) : .white }

    static let white = RGBA(1, 1, 1)
    static let black = RGBA(0, 0, 0)
    static let clear = RGBA(1, 1, 1, 0)
}

enum Palette {
    static let red = RGBA(hex: 0xFF3B30)
    static let orange = RGBA(hex: 0xFF9500)
    static let yellow = RGBA(hex: 0xFFCC00)
    static let green = RGBA(hex: 0x34C759)
    static let blue = RGBA(hex: 0x0A84FF)
    static let purple = RGBA(hex: 0xAF52DE)
    static let ink = RGBA(hex: 0x1C1C1E)
    static let white = RGBA.white
    static let presets: [RGBA] = [red, orange, yellow, green, blue, purple, ink, white]
}

// MARK: - Tools

enum ToolKind: String, Codable, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, text, pen, highlighter, counter, pixelate, blur, spotlight, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .counter: "Counter"
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .spotlight: "Spotlight"
        case .crop: "Crop"
        }
    }

    /// Single-letter shortcut.
    var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .pen: "p"
        case .highlighter: "h"
        case .counter: "n"
        case .pixelate: "x"
        case .blur: "b"
        case .spotlight: "s"
        case .crop: "c"
        }
    }

    var tooltip: String { "\(title) (\(key.uppercased()))" }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .counter: "1.circle"
        case .pixelate: "squareshape.split.3x3"
        case .blur: "drop"
        case .spotlight: "flashlight.on.fill"
        case .crop: "crop"
        }
    }

    var isLineLike: Bool { self == .arrow || self == .line }
    var isFreehand: Bool { self == .pen || self == .highlighter }
    var isRedaction: Bool { self == .pixelate || self == .blur }
    /// Kinds that are dragged out as a rectangle.
    var isBox: Bool { self == .rectangle || self == .ellipse || isRedaction || self == .spotlight }
    var isAnnotation: Bool { self != .select && self != .crop }
}

enum TextBackdrop: String, Codable, CaseIterable, Identifiable {
    case plain, pill, outline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: "Plain"
        case .pill: "Pill"
        case .outline: "Outline"
        }
    }
}

enum FontWeightChoice: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold, heavy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var weight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

/// Everything the inspector can change about an annotation. One per tool is remembered.
struct ToolStyle: Codable, Equatable {
    var color: RGBA
    /// 0, 1, 2 for S, M, L.
    var sizeIndex = 1
    var filled = false
    var rounded = false
    var dashed = false
    var shadow = false
    var opacity = 1.0
    // Arrow
    var curved = false
    var outline = false
    // Text
    var fontSize = 24.0
    var weight = FontWeightChoice.semibold
    var backdrop = TextBackdrop.plain
    // Redaction strength, 0...1
    var intensity = 0.5
    // Spotlight
    var ellipseSpot = false

    static func defaults(for kind: ToolKind) -> ToolStyle {
        var s = ToolStyle(color: Palette.red)
        switch kind {
        case .highlighter:
            s.color = Palette.yellow
            s.opacity = 0.85
        case .arrow:
            s.shadow = true
        case .counter:
            s.shadow = true
        case .text:
            s.fontSize = 26
        case .pixelate, .blur:
            s.intensity = 0.55
        default:
            break
        }
        return s
    }

    /// Stroke width, diameter or thickness in points for the S/M/L choice.
    func points(for kind: ToolKind) -> CGFloat {
        let i = min(max(sizeIndex, 0), 2)
        switch kind {
        case .arrow: return [3, 5, 8][i]
        case .highlighter: return [14, 22, 34][i]
        case .counter: return [24, 32, 44][i]
        default: return [2, 4, 7][i]
        }
    }
}

// MARK: - Annotation

struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var kind: ToolKind
    var style: ToolStyle
    /// Box-like kinds (rectangle, ellipse, redaction, spotlight) and the text origin. Document pixels.
    var rect = CGRect.zero
    /// Arrow and line endpoints, and the counter center (`p0`).
    var p0 = CGPoint.zero
    var p1 = CGPoint.zero
    /// Arrow curvature, as a fraction of the arrow length.
    var bend: CGFloat = 0.3
    var points: [CGPoint] = []
    var text = ""

    init(kind: ToolKind, style: ToolStyle) {
        self.kind = kind
        self.style = style
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        rect.origin.x += dx; rect.origin.y += dy
        p0.x += dx; p0.y += dy
        p1.x += dx; p1.y += dy
        for i in points.indices { points[i].x += dx; points[i].y += dy }
    }
}

// MARK: - Background

enum BackgroundFill: Codable, Equatable {
    case gradient(String)
    case solid(RGBA)
    case wallpaper
    case image(String)
}

enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case auto, square, fourThree, sixteenNine, nineSixteen, twitter, linkedin
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        case .twitter: "X"
        case .linkedin: "LinkedIn"
        }
    }

    /// Width divided by height. Nil means "wrap the image tightly".
    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        case .nineSixteen: 9.0 / 16.0
        case .twitter: 16.0 / 9.0
        case .linkedin: 1200.0 / 627.0
        }
    }
}

/// Where the image sits inside the background canvas.
enum Alignment9: Int, Codable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var fx: CGFloat { [0, 0.5, 1][rawValue % 3] }
    var fy: CGFloat { [0, 0.5, 1][rawValue / 3] }
}

struct BackgroundSettings: Codable, Equatable {
    var enabled = false
    /// Percent of the image's shorter side.
    var padding = 9.0
    var fill = BackgroundFill.gradient("sunset")
    /// Points.
    var cornerRadius = 12.0
    /// 0...1
    var shadow = 0.5
    var aspect = AspectPreset.auto
    var alignment = Alignment9.center
}

struct BackgroundPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var settings: BackgroundSettings
}

struct GradientSpec: Identifiable {
    let id: String
    let name: String
    let colors: [RGBA]
    /// Degrees, 0 = left to right, 90 = top to bottom.
    let angle: Double

    init(_ id: String, _ name: String, _ hexes: [UInt32], angle: Double = 135) {
        self.id = id
        self.name = name
        self.colors = hexes.map { RGBA(hex: $0) }
        self.angle = angle
    }

    static let all: [GradientSpec] = [
        GradientSpec("sunset", "Sunset", [0xFF9A8B, 0xFF6A88, 0xFF99AC]),
        GradientSpec("peach", "Peach", [0xFFECD2, 0xFCB69F]),
        GradientSpec("ocean", "Ocean", [0x2193B0, 0x6DD5ED]),
        GradientSpec("aurora", "Aurora", [0x00C9FF, 0x92FE9D]),
        GradientSpec("lavender", "Lavender", [0xA18CD1, 0xFBC2EB]),
        GradientSpec("mint", "Mint", [0x84FAB0, 0x8FD3F4]),
        GradientSpec("midnight", "Midnight", [0x232526, 0x414345]),
        GradientSpec("candy", "Candy", [0xFF9A9E, 0xFECFEF]),
        GradientSpec("flame", "Flame", [0xF12711, 0xF5AF19]),
        GradientSpec("forest", "Forest", [0x134E5E, 0x71B280]),
        GradientSpec("sky", "Sky", [0x89F7FE, 0x66A6FF]),
        GradientSpec("dusk", "Dusk", [0x2C3E50, 0xFD746C]),
        GradientSpec("cotton", "Cotton", [0xE0C3FC, 0x8EC5FC]),
        GradientSpec("mojave", "Mojave", [0xDA4453, 0x89216B]),
        GradientSpec("lagoon", "Lagoon", [0x43CEA2, 0x185A9D]),
        GradientSpec("grape", "Grape", [0x7F00FF, 0xE100FF]),
        GradientSpec("rose", "Rose", [0xF857A6, 0xFF5858]),
        GradientSpec("slate", "Slate", [0x485563, 0x29323C]),
        GradientSpec("ember", "Ember", [0x0F2027, 0x203A43, 0x2C5364]),
        GradientSpec("glacier", "Glacier", [0xC9D6FF, 0xE2E2E2]),
    ]

    static func spec(_ id: String) -> GradientSpec { all.first { $0.id == id } ?? all[0] }
}

enum SolidSwatches {
    static let all: [RGBA] = [
        RGBA(hex: 0xFFFFFF), RGBA(hex: 0xF2F2F7), RGBA(hex: 0x1C1C1E), RGBA(hex: 0x000000),
        RGBA(hex: 0xFF3B30), RGBA(hex: 0xFF9500), RGBA(hex: 0xFFCC00), RGBA(hex: 0x34C759),
        RGBA(hex: 0x0A84FF), RGBA(hex: 0x5E5CE6), RGBA(hex: 0xAF52DE), RGBA(hex: 0xFF2D55),
    ]
}

// MARK: - Document state

enum CropAspect: String, CaseIterable, Identifiable {
    case free, square, fourThree, sixteenNine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: "Free"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        }
    }
}

/// Everything that is undoable. The image itself is never modified: crop, resize and
/// background are all applied only when the picture is flattened.
struct EditState: Equatable {
    var annotations: [Annotation] = []
    /// The visible part of the image, in image pixels. May extend past the image (Resize Canvas).
    var cropRect: CGRect
    /// Export scale applied by Resize Image.
    var outputScale: CGFloat = 1
    /// Fills the part of the crop rect outside the image.
    var canvasFill = RGBA.white
    var background = BackgroundSettings()
    /// How dark the picture gets around spotlights, 0...1. One level for the whole document.
    var spotlightDim = 0.6
}

extension EditState {
    /// Where everything lands in the exported picture.
    var exportLayout: Layout { Layout.make(crop: cropRect, background: background) }
}

/// Where the cropped image lands on the final canvas.
struct Layout: Equatable {
    var canvasSize: CGSize
    /// The crop rect placed on the canvas.
    var contentRect: CGRect
    var cropRect: CGRect
    /// The wrap around the image. Nil when the image fills the canvas: no background, or the crop preview.
    var background: BackgroundSettings?

    /// Translation from image pixels to canvas pixels.
    var docOffset: CGPoint { CGPoint(x: contentRect.minX - cropRect.minX, y: contentRect.minY - cropRect.minY) }

    func canvasToDoc(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - docOffset.x, y: p.y - docOffset.y) }
    func docToCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + docOffset.x, y: p.y + docOffset.y) }

    static func make(crop: CGRect, background bg: BackgroundSettings?) -> Layout {
        let cw = crop.width, ch = crop.height
        guard let bg, bg.enabled else {
            return Layout(canvasSize: crop.size, contentRect: CGRect(origin: .zero, size: crop.size), cropRect: crop)
        }
        let pad = (bg.padding / 100) * min(cw, ch)
        var w = cw + 2 * pad
        var h = ch + 2 * pad
        if let ratio = bg.aspect.ratio {
            if w / h < ratio { w = h * ratio } else { h = w / ratio }
        }
        w = w.rounded(.up); h = h.rounded(.up)
        let x = pad + (w - 2 * pad - cw) * bg.alignment.fx
        let y = pad + (h - 2 * pad - ch) * bg.alignment.fy
        return Layout(canvasSize: CGSize(width: w, height: h),
                      contentRect: CGRect(x: x.rounded(), y: y.rounded(), width: cw, height: ch),
                      cropRect: crop, background: bg)
    }
}
