import AppKit

// MARK: - Annotation kinds

/// The kinds of annotation. Everything that differs between them, apart from how they are drawn
/// (`EditorRenderer`), is data in `traits`.
enum ToolKind: String, Codable, CaseIterable, Identifiable {
    case arrow, line, rectangle, ellipse, text, pen, highlighter, counter, pixelate, blur, spotlight

    var id: String { rawValue }

    struct Traits {
        var title: String
        /// Single-letter shortcut.
        var key: String
        var symbol: String
        /// What a new annotation starts as, at the mouse-down point.
        var shape: (CGPoint) -> Annotation.Shape
        /// The style before the user changes anything.
        var style = ToolStyle(color: Palette.red)
        /// Stroke width, diameter or thickness in points for S, M, L. Empty when the kind has no size.
        var sizes: [CGFloat] = []
        /// A box that is an ellipse rather than a rectangle.
        var oval = false
        var hasColor = true
        var hasShadow = false
        /// Kind-specific inspector controls, in order.
        var options: [StyleOption] = []
    }

    var traits: Traits {
        switch self {
        case .arrow:
            Traits(title: "Arrow", key: "a", symbol: "arrow.up.right", shape: Self.segment,
                   style: ToolStyle(color: Palette.red, shadow: true), sizes: [3, 5, 8], hasShadow: true, options: [.curved, .outline])
        case .line:
            Traits(title: "Line", key: "l", symbol: "line.diagonal", shape: Self.segment,
                   sizes: [2, 4, 7], hasShadow: true, options: [.dashed])
        case .rectangle:
            Traits(title: "Rectangle", key: "r", symbol: "rectangle", shape: Self.box,
                   sizes: [2, 4, 7], hasShadow: true, options: [.fill, .rounded, .opacity(0.1...1)])
        case .ellipse:
            Traits(title: "Ellipse", key: "o", symbol: "circle", shape: Self.box,
                   sizes: [2, 4, 7], oval: true, hasShadow: true, options: [.fill, .opacity(0.1...1)])
        case .text:
            Traits(title: "Text", key: "t", symbol: "textformat", shape: { .label(origin: $0, text: "") },
                   style: ToolStyle(color: Palette.red, fontSize: 26), hasShadow: true, options: [.fontSize, .weight, .backdrop])
        case .pen:
            Traits(title: "Pen", key: "p", symbol: "pencil.tip", shape: Self.stroke,
                   sizes: [2, 4, 7], hasShadow: true)
        case .highlighter:
            Traits(title: "Highlighter", key: "h", symbol: "highlighter", shape: Self.stroke,
                   style: ToolStyle(color: Palette.yellow, opacity: 0.85), sizes: [14, 22, 34], options: [.opacity(0.2...1)])
        case .counter:
            Traits(title: "Counter", key: "n", symbol: "1.circle", shape: { .marker($0) },
                   style: ToolStyle(color: Palette.red, shadow: true), sizes: [24, 32, 44], hasShadow: true)
        case .pixelate:
            Traits(title: "Pixelate", key: "x", symbol: "squareshape.split.3x3", shape: Self.box,
                   style: ToolStyle(color: Palette.red, intensity: 0.55), hasColor: false, options: [.intensity("Pixel size")])
        case .blur:
            Traits(title: "Blur", key: "b", symbol: "drop", shape: Self.box,
                   style: ToolStyle(color: Palette.red, intensity: 0.55), hasColor: false, options: [.intensity("Blur")])
        case .spotlight:
            Traits(title: "Spotlight", key: "s", symbol: "flashlight.on.fill", shape: Self.box,
                   hasColor: false, options: [.spotShape, .dim])
        }
    }

    private static func segment(_ p: CGPoint) -> Annotation.Shape { .segment(p0: p, p1: p, bend: 0.3) }
    private static func box(_ p: CGPoint) -> Annotation.Shape { .box(CGRect(origin: p, size: .zero)) }
    private static func stroke(_ p: CGPoint) -> Annotation.Shape { .stroke([p]) }
}

/// A kind-specific control in the inspector.
enum StyleOption: Hashable {
    case curved, outline, dashed, fill, rounded, fontSize, weight, backdrop, spotShape
    /// The annotation's opacity, within this range.
    case opacity(ClosedRange<Double>)
    /// Redaction strength, under this caption.
    case intensity(String)
    /// The document's spotlight dim.
    case dim
}

// MARK: - Mode

/// What a mouse drag on the canvas does.
enum Mode: Equatable {
    case select
    case draw(ToolKind)
    case crop(CropSession)

    var choice: ToolChoice {
        switch self {
        case .select: .select
        case .draw(let kind): .draw(kind)
        case .crop: .crop
        }
    }

    var drawKind: ToolKind? {
        if case .draw(let kind) = self { kind } else { nil }
    }

    var crop: CropSession? {
        if case .crop(let session) = self { session } else { nil }
    }
}

/// A toolbar button and its single-letter key: Select, an annotation kind, or Crop.
enum ToolChoice: Hashable, Identifiable {
    case select, draw(ToolKind), crop

    static let all: [ToolChoice] = [.select] + ToolKind.allCases.map { .draw($0) } + [.crop]

    var id: Self { self }

    var title: String {
        switch self {
        case .select: "Select"
        case .draw(let kind): kind.traits.title
        case .crop: "Crop"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .draw(let kind): kind.traits.key
        case .crop: "c"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .draw(let kind): kind.traits.symbol
        case .crop: "crop"
        }
    }

    var tooltip: String { "\(title) (\(key.uppercased()))\n\(help)" }
}

// MARK: - Style

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

/// Everything the inspector can change about an annotation. One per kind is remembered.
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
}

extension ToolStyle {
    /// Saved in edit sidecars: fields added later decode with their defaults, so an older file still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try c.decode(RGBA.self, forKey: .color))
        try c.decodeIfPresent(.sizeIndex, into: &sizeIndex)
        try c.decodeIfPresent(.filled, into: &filled)
        try c.decodeIfPresent(.rounded, into: &rounded)
        try c.decodeIfPresent(.dashed, into: &dashed)
        try c.decodeIfPresent(.shadow, into: &shadow)
        try c.decodeIfPresent(.opacity, into: &opacity)
        try c.decodeIfPresent(.curved, into: &curved)
        try c.decodeIfPresent(.outline, into: &outline)
        try c.decodeIfPresent(.fontSize, into: &fontSize)
        try c.decodeIfPresent(.weight, into: &weight)
        try c.decodeIfPresent(.backdrop, into: &backdrop)
        try c.decodeIfPresent(.intensity, into: &intensity)
        try c.decodeIfPresent(.ellipseSpot, into: &ellipseSpot)
    }
}
