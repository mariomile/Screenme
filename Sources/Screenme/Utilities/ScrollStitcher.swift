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
/// Pixels that stay put while the page moves (a fixed sidebar, a floating chat button) are tracked per
/// screen position. Once seen, they are not copied into the rows added later: each is replaced by the
/// nearest row above or below where nothing is pinned, so they show once, in the first frame, not once per frame.
///
/// Stitched rows go to a temporary file rather than memory, and the final image is memory-mapped
/// from it, so a page of tens of thousands of pixels costs almost no resident memory.
/// Not thread-safe: callers serialize access.
final class ScrollStitcher {
    enum Outcome: Equatable {
        case first
        case advanced
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
    /// Luma of every `lumaStep`-th pixel of each row, for the previous and the current frame.
    private static let lumaStep = 4
    private let lumaWidth: Int
    private var previousLuma: [UInt8] = []
    /// Per sample: how often it stayed put while the page moved. Above zero means pinned to the screen.
    private var pinned: [Int8]
    private var finished = false

    init?(width: Int, height: Int) {
        guard width >= 8, height >= 64 else { return nil }
        self.width = width
        self.height = height
        bands = min(Self.bandCount, max(1, width / 8))
        lumaWidth = width / Self.lumaStep
        pinned = [Int8](repeating: 0, count: (width / Self.lumaStep) * height)
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("screenme-scroll-\(UUID().uuidString).raw")
        fd = open(fileURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
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
        let currentLuma = lumas(base, bytesPerRow: bytesPerRow)

        guard hasPrevious else {
            append(base, bytesPerRow: bytesPerRow, rows: 0..<height)
            previous = current
            previousLuma = currentLuma
            hasPrevious = true
            return .first
        }

        let (top, bottom) = stickyRows(previous, current)
        let regionHeight = height - top - bottom
        if top >= height || regionHeight < 48 {
            previous = current
            previousLuma = currentLuma
            return .still
        }

        guard let shift = findShift(previous, current, top: top, bottom: bottom) else { return .lost }
        previous = current
        if shift == 0 {
            previousLuma = currentLuma
            return .still
        }
        trackPinned(currentLuma, shift: shift)
        previousLuma = currentLuma

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
        if let unpinned = withoutPinned(base, bytesPerRow: bytesPerRow, rows: from..<to) {
            unpinned.withUnsafeBufferPointer { writeRows($0.baseAddress!, bytesPerRow: width * 4, count: to - from, isFooter: false) }
        } else {
            append(base, bytesPerRow: bytesPerRow, rows: from..<to)
        }

        // Remember the footer so it can close the image once, at the end.
        footer.removeAll(keepingCapacity: true)
        if bottom > 0 {
            for y in (height - bottom)..<height {
                footer.append(contentsOf: UnsafeBufferPointer(start: base + y * bytesPerRow, count: width * 4))
            }
        }
        return .advanced
    }

    // MARK: Output

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

    // MARK: Pinned pixels

    private func lumas(_ base: UnsafePointer<UInt8>, bytesPerRow: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: lumaWidth * height)
        result.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = base + y * bytesPerRow
                for i in 0..<lumaWidth {
                    let p = row + i * Self.lumaStep * 4
                    out[y * lumaWidth + i] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 151 + Int(p[0]) * 28) >> 8)
                }
            }
        }
        return result
    }

    /// Compares the frames at the same screen position and at the position the page moved to.
    /// A sample that kept its value while the page's value moved away is pinned; one that moved with the page is not.
    private func trackPinned(_ current: [UInt8], shift: Int) {
        guard abs(shift) >= 6 else { return }
        let lw = lumaWidth
        current.withUnsafeBufferPointer { cur in
            previousLuma.withUnsafeBufferPointer { prev in
                for y in 0..<height {
                    // The page moved from `from` in the previous frame to `to` in this one. Rows near the bottom have
                    // no earlier position, rows near the top no later one, so each direction covers the other's gap.
                    let ahead = y + shift, behind = y - shift
                    let useAhead = ahead >= 0 && ahead < height
                    guard useAhead || (behind >= 0 && behind < height) else { continue }
                    for i in 0..<lw {
                        let k = y * lw + i
                        let c = Int(cur[k]), p = Int(prev[k])
                        let stayed = abs(c - p)
                        let followed = useAhead ? abs(c - Int(prev[ahead * lw + i])) : abs(p - Int(cur[behind * lw + i]))
                        if stayed <= 3, followed > 12 {
                            pinned[k] = min(pinned[k] + 1, 6)
                        } else if followed <= 3, stayed > 12 {
                            pinned[k] = -4
                        }
                    }
                }
            }
        }
    }

    /// The frame's `rows` with every pinned sample replaced by the same column of the nearest row without one,
    /// or nil when nothing is pinned there.
    private func withoutPinned(_ base: UnsafePointer<UInt8>, bytesPerRow: Int, rows: Range<Int>) -> [UInt8]? {
        let lw = lumaWidth
        let reach = 64
        let lo = max(0, rows.lowerBound - reach), hi = min(height, rows.upperBound + reach)
        var mask = [Bool](repeating: false, count: (hi - lo) * lw)
        var any = false
        for y in lo..<hi {
            for i in 0..<lw where pinned[y * lw + i] > 0 {
                any = true
                // A sample stands for its whole block, and text edges reach past it.
                for yy in max(lo, y - 2)...min(hi - 1, y + 2) {
                    for ii in max(0, i - 1)...min(lw - 1, i + 1) { mask[(yy - lo) * lw + ii] = true }
                }
            }
        }
        guard any else { return nil }

        let rowBytes = width * 4
        let block = Self.lumaStep * 4
        var out = [UInt8](repeating: 0, count: rows.count * rowBytes)
        for (r, y) in rows.enumerated() {
            out.withUnsafeMutableBufferPointer { dst in
                let row = dst.baseAddress! + r * rowBytes
                row.update(from: base + y * bytesPerRow, count: rowBytes)
                for i in 0..<lw where mask[(y - lo) * lw + i] {
                    for d in 1...reach {
                        let source: Int
                        if y - d >= lo, !mask[(y - d - lo) * lw + i] { source = y - d }
                        else if y + d < hi, !mask[(y + d - lo) * lw + i] { source = y + d }
                        else { continue }
                        (row + i * block).update(from: base + source * bytesPerRow + i * block, count: block)
                        break
                    }
                }
            }
        }
        return out
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
