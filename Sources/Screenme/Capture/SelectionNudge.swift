import CoreGraphics

/// Moving and resizing a selection with the arrow keys. Pure geometry, in global Cocoa coordinates (bottom-left origin).
enum SelectionNudge {
    enum Arrow { case left, right, up, down }

    /// One press moves by 1 pt, or 10 pt with Shift.
    static func step(shift: Bool) -> CGFloat { shift ? 10 : 1 }

    /// `rect` after one arrow press, kept inside `bounds`.
    /// - Moving: the arrow's direction as seen on screen; the rect keeps its size and stops at the edge of `bounds`.
    /// - Resizing (Option): the right edge follows Left and Right, the bottom edge follows Up and Down
    ///   (Down grows the selection downward, Up shrinks it); the top left corner stays put. At least 1 pt wide and tall,
    ///   and never past `bounds`.
    static func apply(_ arrow: Arrow, to rect: CGRect, step: CGFloat, resize: Bool, within bounds: CGRect) -> CGRect {
        var result = rect
        if resize {
            switch arrow {
            case .right:
                result.size.width = min(max(rect.width + step, 1), bounds.maxX - rect.minX)
            case .left:
                result.size.width = min(max(rect.width - step, 1), bounds.maxX - rect.minX)
            case .down:
                // Cocoa y grows upward: the bottom edge moves down by lowering minY while the top edge stays.
                let top = rect.maxY
                let minY = min(max(rect.minY - step, bounds.minY), top - 1)
                result.origin.y = minY
                result.size.height = top - minY
            case .up:
                let top = rect.maxY
                let minY = min(max(rect.minY + step, bounds.minY), top - 1)
                result.origin.y = minY
                result.size.height = top - minY
            }
            return result
        }
        switch arrow {
        case .left: result.origin.x -= step
        case .right: result.origin.x += step
        case .up: result.origin.y += step
        case .down: result.origin.y -= step
        }
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - rect.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - rect.height)
        return result
    }
}
