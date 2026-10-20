import CoreGraphics
import Foundation

/// Stitches a stream of frames of scrolling content into one tall image.
///
/// Each frame is reduced to a small signature per pixel row (mean luma in a few vertical bands).
/// Between two frames the rows that did not change at the top and bottom are sticky headers and
/// footers and are left out of the match; the remaining rows are compared at every candidate
/// offset with a truncated absolute difference, which tolerates sidebars, sub-pixel text and small
/// animations. Only rows below everything seen so far are appended, so scrolling back and forth
/// never duplicates content.
///
/// Stitched rows go to a temporary file rather than memory, and the final image is memory-mapped
/// from it, so a page of tens of thousands of pixels costs almost no resident memory.
/// Not thread-safe: callers serialize access.
final class ScrollStitcher {
    enum Outcome: Equatable {
        case first
        case advanced(rows: Int)
        case still
        case scrolledBack
        case lost
        case limit
    }

    /// Hard cap on the stitched height, in pixels.
    static let maxRows = 120_000

    let width: Int
    let height: Int
    private(set) var totalRows = 0
    var colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()

    private static let bandCount = 24
    private let bands: Int
    private let fileURL: URL
    private var fd: Int32

    private var previous: [UInt8] = []
    private var hasPrevious = false
    private var cursor = 0
    private var lastShift = 0
    private var footer: [UInt8] = []
    private var preview: ScrollPreviewBuilder
    private var finished = false

    init?(width: Int, height: Int) {
        guard width >= 8, height >= 64 else { return nil }
        self.width = width
        self.height = height
        bands = min(Self.bandCount, max(1, width / 8))
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("screenme-scroll-\(UUID().uuidString).raw")
        fd = open(fileURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
        preview = ScrollPreviewBuilder(width: width)
    }

    deinit {
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Adding frames

    /// Adds a BGRA frame. `base` must stay valid for the duration of the call.
    @discardableResult
    func add(_ base: UnsafePointer<UInt8>, bytesPerRow: Int) -> Outcome {
        guard !finished else { return .still }
        let current = signatures(base, bytesPerRow: bytesPerRow)

        guard hasPrevious else {
            append(base, bytesPerRow: bytesPerRow, rows: 0..<height)
            previous = current
            hasPrevious = true
            return .first
        }

        let (top, bottom) = stickyRows(previous, current)
        let regionHeight = height - top - bottom
        if top >= height || regionHeight < 48 {
            previous = current
            return .still
        }

        guard let shift = findShift(previous, current, top: top, bottom: bottom) else { return .lost }
        previous = current
        if shift == 0 { return .still }

        // The first frame was appended whole, including a sticky footer that hides real content.
        if shift > 0, bottom > 0, cursor == 0, totalRows == height { truncate(to: height - bottom) }

        lastShift = shift
        cursor += shift
        let contentBottom = cursor + height - bottom
        guard contentBottom > totalRows else { return shift < 0 ? .scrolledBack : .still }
        if totalRows >= Self.maxRows { return .limit }

        let from = max(0, totalRows - cursor)
        let to = min(height - bottom, from + (Self.maxRows - totalRows))
        guard to > from else { return .still }
        append(base, bytesPerRow: bytesPerRow, rows: from..<to)

        // Remember the footer so it can close the image once, at the end.
        footer.removeAll(keepingCapacity: true)
        if bottom > 0 {
            for y in (height - bottom)..<height {
                footer.append(contentsOf: UnsafeBufferPointer(start: base + y * bytesPerRow, count: width * 4))
            }
        }
        return .advanced(rows: to - from)
    }

    // MARK: Output

    /// A small version of the stitched result for the live preview.
    func previewImage() -> CGImage? {
        preview.image(colorSpace: colorSpace)
    }

    /// The finished image, backed by the memory-mapped temporary file. Call once.
    func finish() -> CGImage? {
        guard !finished else { return nil }
        finished = true
        if !footer.isEmpty, totalRows + footer.count / (width * 4) <= Self.maxRows + height {
            footer.withUnsafeBufferPointer { buffer in
                writeRows(buffer.baseAddress!, bytesPerRow: width * 4, count: footer.count / (width * 4), isFooter: true)
            }
        }
        guard totalRows > 0, let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) else { return nil }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        let image = CGImage(width: width, height: totalRows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        // The mapping outlives the directory entry.
        try? FileManager.default.removeItem(at: fileURL)
        close(fd)
        fd = -1
        return image
    }

    // MARK: Storage

    private func append(_ base: UnsafePointer<UInt8>, bytesPerRow: Int, rows: Range<Int>) {
        guard !rows.isEmpty else { return }
        writeRows(base + rows.lowerBound * bytesPerRow, bytesPerRow: bytesPerRow, count: rows.count, isFooter: false)
    }

    private func truncate(to rows: Int) {
        let bytes = off_t(rows * width * 4)
        guard ftruncate(fd, bytes) == 0 else { return }
        lseek(fd, bytes, SEEK_SET)
        totalRows = rows
        preview.truncate(toStitchedRows: rows)
    }

    private func writeRows(_ start: UnsafePointer<UInt8>, bytesPerRow: Int, count: Int, isFooter: Bool) {
        let rowBytes = width * 4
        for row in 0..<count {
            let pointer = start + row * bytesPerRow
            var written = 0
            while written < rowBytes {
                let n = write(fd, pointer + written, rowBytes - written)
                if n <= 0 { return }
                written += n
            }
            preview.add(row: pointer, index: totalRows)
            totalRows += 1
        }
    }

    // MARK: Signatures

    /// Mean luma of each vertical band, per row.
    private func signatures(_ base: UnsafePointer<UInt8>, bytesPerRow: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: height * bands)
        let bandWidth = width / bands
        let step = max(1, bandWidth / 12)
        result.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * bytesPerRow
                for b in 0..<bands {
                    let start = b * bandWidth
                    let end = b == bands - 1 ? width : start + bandWidth
                    var sum = 0
                    var count = 0
                    var x = start
                    while x < end {
                        let p = row + x * 4
                        sum += (Int(p[2]) * 77 + Int(p[1]) * 151 + Int(p[0]) * 28) >> 8
                        count += 1
                        x += step
                    }
                    out[y * bands + b] = UInt8(sum / max(count, 1))
                }
            }
        }
        return result
    }

    /// How many rows at the top and bottom are identical in both frames (sticky bars).
    private func stickyRows(_ a: [UInt8], _ b: [UInt8]) -> (top: Int, bottom: Int) {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var top = 0
                while top < height, rowsMatch(pa, top, pb, top) { top += 1 }
                var bottom = 0
                while bottom < height - top, rowsMatch(pa, height - 1 - bottom, pb, height - 1 - bottom) { bottom += 1 }
                return (top, bottom)
            }
        }
    }

    private func rowsMatch(_ a: UnsafeBufferPointer<UInt8>, _ ay: Int, _ b: UnsafeBufferPointer<UInt8>, _ by: Int) -> Bool {
        var total = 0
        for i in 0..<bands {
            let d = abs(Int(a[ay * bands + i]) - Int(b[by * bands + i]))
            if d > 16 { return false }
            total += d
        }
        return total <= bands * 3 / 2
    }

    // MARK: Matching

    /// The offset `s` such that `current[y] ≈ previous[y + s]` over the moving region,
    /// or nil when nothing matches well enough. Positive means the content scrolled down.
    private func findShift(_ a: [UInt8], _ b: [UInt8], top: Int, bottom: Int) -> Int? {
        let low = top
        let high = height - bottom
        let region = high - low
        let minOverlap = max(32, region / 8)
        let maxShift = region - minOverlap
        let cap = 24
        let acceptLimit = 7.0

        // Rows with some detail; flat rows match everywhere and prove nothing.
        var detail = [Int](repeating: 0, count: height + 1)
        b.withUnsafeBufferPointer { pb in
            for y in 0..<height {
                var lo = 255, hi = 0
                for i in 0..<bands {
                    let v = Int(pb[y * bands + i])
                    lo = min(lo, v)
                    hi = max(hi, v)
                }
                detail[y + 1] = detail[y] + (hi - lo >= 10 ? 1 : 0)
            }
        }
        let totalDetail = detail[high] - detail[low]
        let requiredDetail = max(3, min(12, totalDetail / 3))

        var best = acceptLimit
        var candidates: [(shift: Int, score: Double)] = []

        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for shift in -maxShift...maxShift {
                    let start = max(low, low - shift)
                    let end = min(high, high - shift)
                    let rows = end - start
                    if rows < minOverlap { continue }
                    if detail[end] - detail[start] < requiredDetail { continue }

                    let bound = Int((best * 1.15 + 0.04) * Double(rows * bands))
                    var sum = 0
                    var y = start
                    while y < end {
                        let nb = y * bands
                        let pb2 = (y + shift) * bands
                        for i in 0..<bands {
                            let d = abs(Int(pb[nb + i]) - Int(pa[pb2 + i]))
                            sum += d < cap ? d : cap
                        }
                        if sum > bound { break }
                        y += 1
                    }
                    if y < end { continue }
                    let score = Double(sum) / Double(rows * bands)
                    candidates.append((shift, score))
                    if score < best { best = score }
                }
            }
        }

        let threshold = best * 1.15 + 0.04
        let viable = candidates.filter { $0.score <= threshold }
        guard !viable.isEmpty, best < acceptLimit else { return nil }
        // Ties (flat or repeating content) resolve toward the previous speed.
        return viable.min { lhs, rhs in
            let l = abs(lhs.shift - lastShift), r = abs(rhs.shift - lastShift)
            return l != r ? l < r : abs(lhs.shift) < abs(rhs.shift)
        }?.shift
    }
}

// MARK: - Preview

/// Keeps a thumbnail-width copy of the stitched rows, sampled every few rows.
private struct ScrollPreviewBuilder {
    private let step: Int
    private let previewWidth: Int
    private var pixels: [UInt8] = []
    private(set) var rowCount = 0

    init(width: Int) {
        step = max(1, width / 280)
        previewWidth = width / step
    }

    mutating func add(row: UnsafePointer<UInt8>, index: Int) {
        guard index % step == 0 else { return }
        let base = pixels.count
        pixels.append(contentsOf: repeatElement(0, count: previewWidth * 4))
        pixels.withUnsafeMutableBufferPointer { out in
            for x in 0..<previewWidth {
                var b = 0, g = 0, r = 0
                for k in 0..<step {
                    let p = row + (x * step + k) * 4
                    b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                }
                let o = base + x * 4
                out[o] = UInt8(b / step)
                out[o + 1] = UInt8(g / step)
                out[o + 2] = UInt8(r / step)
                out[o + 3] = 255
            }
        }
        rowCount += 1
    }

    mutating func truncate(toStitchedRows rows: Int) {
        let keep = (rows + step - 1) / step
        guard keep < rowCount else { return }
        pixels.removeLast((rowCount - keep) * previewWidth * 4)
        rowCount = keep
    }

    func image(colorSpace: CGColorSpace) -> CGImage? {
        guard rowCount > 0, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGImage(width: previewWidth, height: rowCount, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: previewWidth * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
