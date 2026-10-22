import AppKit
import ImageIO

extension Pref {
    /// Copy for AI and Share send a copy with emails, numbers, keys and faces pixelated. The capture file is not changed.
    static let hideSensitiveWhenSharing = PrefKey(name: "hideSensitiveWhenSharing", defaultValue: false)
}

/// Covers what should not leave the Mac (see `SensitiveInfo`, plus faces) with the editor's pixelate, in the editor
/// and on the copies that go to an AI or to other people.
@MainActor
enum Redaction {
    /// Why a copy with the sensitive info hidden could not be made. Nothing is shared then.
    enum Failure: LocalizedError, Equatable {
        /// The image could not be read or checked.
        case unchecked
        /// The sensitive info was found but the copy hiding it could not be drawn or written.
        case notWritten

        var errorDescription: String? {
            switch self {
            case .unchecked: "Could not check the image for sensitive info, so nothing was shared"
            case .notWritten: "Could not hide the sensitive info, so nothing was shared"
            }
        }
    }

    /// One pixelate annotation per box, each with a little margin so letter edges and descenders do not show around the mosaic.
    static func annotations(covering boxes: [CGRect], style: ToolStyle, unit: CGFloat, bounds: CGRect) -> [Annotation] {
        boxes.map { box in
            let pad = max(box.height * 0.2, 2 * unit)
            var annotation = Annotation(kind: .pixelate, style: style, at: box.origin)
            annotation.shape = .box(box.insetBy(dx: -pad, dy: -pad).integral.intersection(bounds))
            return annotation
        }
    }

    /// A copy of `image` with `boxes` (image pixels, top-left origin) pixelated by the editor's own renderer.
    static func redacted(_ image: CGImage, boxes: [CGRect], unit: CGFloat) -> CGImage? {
        let source = ImageSource(image: image, unit: unit)
        var state = EditState(cropRect: source.bounds)
        state.annotations = annotations(covering: boxes, style: ToolKind.pixelate.traits.style, unit: unit, bounds: source.bounds)
        return EditorRenderer.flatten(state: state, source: source, opaque: false)
    }

    /// `image` with everything sensitive in it hidden, and how many items that was. Nil when there is nothing to hide.
    /// Throws when the image could not be checked or the hiding drawn: what is shared must not go out unchecked.
    static func hidingSensitive(in image: CGImage, unit: CGFloat) async throws -> (image: CGImage, count: Int)? {
        guard let boxes = try? await TextRecognizer.sensitiveBoxes(in: image) else { throw Failure.unchecked }
        guard !boxes.isEmpty else { return nil }
        guard let redacted = redacted(image, boxes: boxes, unit: unit) else { throw Failure.notWritten }
        return (redacted, boxes.count)
    }

    /// A temporary copy named like `original`, in its format, holding `image` (`TemporaryCopies`): sharing the same
    /// capture again overwrites it.
    static func write(_ image: CGImage, like original: URL) -> URL? {
        Storage.encoded(image, as: ImageFormat(of: original)).flatMap { TemporaryCopies.write($0, named: original.lastPathComponent) }
    }

    /// A redacted temporary copy of the image file, for sharing. Nil when there is nothing to hide, or the file is not
    /// a still image (a GIF or a video is shared as it is). Throws when the image cannot be read or checked, or the
    /// copy cannot be made: then nothing may be shared.
    static func redactedCopy(of url: URL) async throws -> (url: URL, count: Int)? {
        guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        guard let source = ImageSource.load(url: url) else { throw Failure.unchecked }
        guard let (image, count) = try await hidingSensitive(in: source.image, unit: source.unit) else { return nil }
        guard let copy = write(image, like: url) else { throw Failure.notWritten }
        return (copy, count)
    }
}
