import CoreGraphics
import Foundation
import Vision

/// On-device text recognition with Vision, plus QR and barcode payloads.
enum TextRecognizer {
    /// Recognized text in reading order. Honors `Pref.ocrKeepLineBreaks` and `Pref.ocrDetectQR`.
    /// When the selection is mostly a QR or barcode, returns just its payload.
    static func recognize(_ image: CGImage) async throws -> String {
        let keepLineBreaks = Prefs[Pref.ocrKeepLineBreaks]
        let detectCodes = Prefs[Pref.ocrDetectQR]
        return try await Task.detached(priority: .userInitiated) {
            try run(image, keepLineBreaks: keepLineBreaks, detectCodes: detectCodes)
        }.value
    }

    // MARK: Pipeline

    private static func run(_ image: CGImage, keepLineBreaks: Bool, detectCodes: Bool) throws -> String {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true

        var requests: [VNRequest] = [textRequest]
        let barcodeRequest = VNDetectBarcodesRequest()
        if detectCodes { requests.append(barcodeRequest) }

        try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)

        let payloads = detectCodes ? codePayloads(barcodeRequest.results ?? []) : []
        let lines = readingOrder(textRequest.results ?? [])
        let text = format(lines, keepLineBreaks: keepLineBreaks)

        guard !payloads.isEmpty else { return text }
        let payloadText = payloads.joined(separator: "\n")

        // The selection is mostly the code (or has no text): the payload is what the user wants.
        let coverage = largestCodeCoverage(barcodeRequest.results ?? [])
        if text.isEmpty || coverage >= 0.3 { return payloadText }

        // Text first, then the code, unless the text already contains it.
        let unique = payloads.filter { !text.contains($0) }
        return unique.isEmpty ? text : text + "\n" + unique.joined(separator: "\n")
    }

    // MARK: Barcodes

    private static func codePayloads(_ results: [VNBarcodeObservation]) -> [String] {
        var seen = Set<String>()
        return results
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.payloadStringValue }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func largestCodeCoverage(_ results: [VNBarcodeObservation]) -> CGFloat {
        results.filter { $0.payloadStringValue?.isEmpty == false }
            .map { $0.boundingBox.width * $0.boundingBox.height }
            .max() ?? 0
    }

    // MARK: Reading order

    private struct Line {
        let text: String
        let box: CGRect // normalized, bottom-left origin
    }

    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [[Line]] {
        let lines: [Line] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return Line(text: candidate.string, box: observation.boundingBox)
        }
        // Top to bottom, then group lines that share a visual row (columns, table cells).
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[Line]] = []
        for line in sorted {
            if let last = rows.last, let anchor = last.first, sameRow(anchor.box, line.box) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > min(a.height, b.height) * 0.5
    }

    private static func format(_ rows: [[Line]], keepLineBreaks: Bool) -> String {
        guard !rows.isEmpty else { return "" }
        var output = ""
        var previous: [Line]?
        for row in rows {
            let joined = row.map(\.text).joined(separator: " ")
            if let previous {
                if keepLineBreaks {
                    // A gap taller than a line is a paragraph break.
                    let height = max(row.map(\.box.height).max() ?? 0, previous.map(\.box.height).max() ?? 0)
                    let gap = (previous.map(\.box.minY).min() ?? 0) - (row.map(\.box.maxY).max() ?? 0)
                    output += gap > height * 0.9 ? "\n\n" : "\n"
                } else {
                    output += " "
                }
            }
            output += joined
            previous = row
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
