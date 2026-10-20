import CoreGraphics

/// The canvas view's zoom and pan, and the conversions between view points, canvas pixels and document
/// pixels. The canvas sits centered in the view, offset by `pan`.
struct Viewport {
    /// View points per canvas pixel.
    private(set) var zoom: CGFloat = 1
    private(set) var pan = CGPoint.zero
    /// While true, the canvas is refitted whenever the view or the canvas changes size. Zooming ends it.
    private(set) var fits = true
    var viewSize = CGSize.zero
    /// What the canvas shows: its size, and where the document sits on it.
    var layout: Layout
    /// Image pixels per point.
    let unit: CGFloat

    init(layout: Layout, unit: CGFloat) {
        self.layout = layout
        self.unit = unit
    }

    /// One image point per view point.
    var actualSize: CGFloat { 1 / unit }
    var percent: Int { Int((zoom * unit * 100).rounded()) }
    var viewCenter: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    private var canvasSize: CGSize { layout.canvasSize }

    var canvasOrigin: CGPoint {
        CGPoint(x: viewSize.width / 2 - canvasSize.width * zoom / 2 + pan.x, y: viewSize.height / 2 - canvasSize.height * zoom / 2 + pan.y)
    }

    /// The canvas, in view points.
    var canvasRect: CGRect { CGRect(origin: canvasOrigin, size: CGSize(width: canvasSize.width * zoom, height: canvasSize.height * zoom)) }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        let o = canvasOrigin
        return CGPoint(x: (p.x - o.x) / zoom, y: (p.y - o.y) / zoom)
    }

    func toDoc(_ p: CGPoint) -> CGPoint { layout.canvasToDoc(toCanvas(p)) }

    func toView(_ doc: CGPoint) -> CGPoint {
        let c = layout.docToCanvas(doc)
        let o = canvasOrigin
        return CGPoint(x: o.x + c.x * zoom, y: o.y + c.y * zoom)
    }

    func toView(_ rect: CGRect) -> CGRect {
        let a = toView(rect.origin), b = toView(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Shows the whole canvas with a margin, never above actual size, and keeps doing so.
    mutating func fit() {
        fits = true
        pan = .zero
        guard canvasSize.width > 0, canvasSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            zoom = actualSize
            return
        }
        let margin: CGFloat = 32
        let z = min((viewSize.width - 2 * margin) / canvasSize.width, (viewSize.height - 2 * margin) / canvasSize.height)
        zoom = max(0.04 / unit, min(z, actualSize))
    }

    /// Zooms to `value`, keeping the canvas point under `anchor` (a view point) where it is.
    mutating func zoom(to value: CGFloat, anchor: CGPoint) {
        let target = min(max(value, 0.04 / unit), 8 / unit)
        let canvasPoint = toCanvas(anchor)
        fits = false
        zoom = target
        pan = CGPoint(x: anchor.x - canvasPoint.x * zoom - (viewSize.width / 2 - canvasSize.width * zoom / 2),
                      y: anchor.y - canvasPoint.y * zoom - (viewSize.height / 2 - canvasSize.height * zoom / 2))
        clampPan()
    }

    mutating func setPan(_ value: CGPoint) {
        pan = value
        clampPan()
    }

    /// Keeps at least part of the canvas in view: it may scroll 80 points past either edge.
    mutating func clampPan() {
        let w = canvasSize.width * zoom, h = canvasSize.height * zoom
        let limitX = max(0, (w - viewSize.width) / 2 + 80)
        let limitY = max(0, (h - viewSize.height) / 2 + 80)
        pan.x = min(max(pan.x, -limitX), limitX)
        pan.y = min(max(pan.y, -limitY), limitY)
    }
}
