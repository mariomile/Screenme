import AppKit

/// Redact Sensitive Info: reads the image's text and covers every email, phone number, card number, IBAN,
/// key and IP address it finds with a pixelate annotation, as one undo step.
extension EditorController {
    func redactSensitiveInfo() {
        guard !isRedacting else { return }
        canvas?.finishTextEditing()
        isRedacting = true
        let image = source.image
        Task {
            defer { isRedacting = false }
            let boxes: [CGRect]
            do {
                boxes = try await TextRecognizer.sensitiveBoxes(in: image)
            } catch {
                Toast.show("Could not read the text", symbol: "exclamationmark.triangle.fill")
                return
            }
            guard !boxes.isEmpty else {
                Toast.show("Nothing sensitive found", symbol: "checkmark.shield.fill")
                return
            }
            let style = styles[.pixelate] ?? ToolKind.pixelate.traits.style
            let annotations = boxes.map { box in
                // A little margin so letter edges and descenders do not show around the mosaic.
                let pad = max(box.height * 0.2, 2 * unit)
                var annotation = Annotation(kind: .pixelate, style: style, at: box.origin)
                annotation.shape = .box(box.insetBy(dx: -pad, dy: -pad).integral.intersection(source.bounds))
                return annotation
            }
            perform { $0.annotations.append(contentsOf: annotations) }
            choose(.select)
            select(Set(annotations.map(\.id)))
            Toast.show("Redacted \(boxes.count) \(boxes.count == 1 ? "item" : "items")", symbol: "eye.slash.fill")
        }
    }
}
