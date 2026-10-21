import AppKit

/// Redact Sensitive Info: reads the image's text and covers every email, phone number, card number, IBAN,
/// key and IP address it finds, and every face, with a pixelate annotation, as one undo step.
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
            let annotations = Redaction.annotations(covering: boxes, style: style, unit: unit, bounds: source.bounds)
            perform { $0.annotations.append(contentsOf: annotations) }
            choose(.select)
            select(Set(annotations.map(\.id)))
            Toast.show("Redacted \(boxes.count) \(boxes.count == 1 ? "item" : "items")", symbol: "eye.slash.fill")
        }
    }
}
