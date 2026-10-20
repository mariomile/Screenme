import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

// MARK: - Palette

/// A global palette built by median cut over a 15-bit colour histogram.
/// Entry 255 is reserved for "unchanged since the previous frame".
struct GIFPalette {
    static let transparentIndex: UInt8 = 255

    /// 256 * 3 bytes.
    var rgb: [UInt8]
    /// Palette index for every 5-5-5 colour bin.
    var lookup: [UInt8]
}

final class GIFPaletteBuilder {
    private var counts = [UInt32](repeating: 0, count: 32768)
    private var sumR = [UInt64](repeating: 0, count: 32768)
    private var sumG = [UInt64](repeating: 0, count: 32768)
    private var sumB = [UInt64](repeating: 0, count: 32768)

    /// Adds every pixel of an RGBX frame.
    func add(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        for y in 0..<height {
            var p = pixels + y * bytesPerRow
            for _ in 0..<width {
                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                let bin = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                counts[bin] += 1
                sumR[bin] += UInt64(r)
                sumG[bin] += UInt64(g)
                sumB[bin] += UInt64(b)
                p += 4
            }
        }
    }

    func build(colors requested: Int) -> GIFPalette {
        struct Entry {
            var r: Int, g: Int, b: Int
            var count: Int
            var bin: Int
        }
        struct Box { var start: Int, end: Int, population: Int }

        var entries: [Entry] = []
        for bin in 0..<32768 where counts[bin] > 0 {
            entries.append(Entry(r: bin >> 10 & 31, g: bin >> 5 & 31, b: bin & 31, count: Int(counts[bin]), bin: bin))
        }
        let limit = min(max(requested, 2), 255)
        var boxes = [Box(start: 0, end: entries.count, population: entries.reduce(0) { $0 + $1.count })]

        while boxes.count < limit {
            guard let index = boxes.indices.filter({ boxes[$0].end - boxes[$0].start > 1 }).max(by: { boxes[$0].population < boxes[$1].population }) else { break }
            let box = boxes[index]
            var lo = (r: 31, g: 31, b: 31), hi = (r: 0, g: 0, b: 0)
            for e in entries[box.start..<box.end] {
                lo = (min(lo.r, e.r), min(lo.g, e.g), min(lo.b, e.b))
                hi = (max(hi.r, e.r), max(hi.g, e.g), max(hi.b, e.b))
            }
            // Green carries the most visible detail, blue the least.
            let spans = [(hi.r - lo.r) * 3, (hi.g - lo.g) * 4, (hi.b - lo.b) * 2]
            let channel = spans.firstIndex(of: spans.max() ?? 0) ?? 1
            entries[box.start..<box.end].sort { a, b in
                switch channel {
                case 0: a.r < b.r
                case 1: a.g < b.g
                default: a.b < b.b
                }
            }
            var running = 0
            var mid = box.start + 1
            for i in box.start..<(box.end - 1) {
                running += entries[i].count
                mid = i + 1
                if running * 2 >= box.population { break }
            }
            let left = entries[box.start..<mid].reduce(0) { $0 + $1.count }
            boxes[index] = Box(start: box.start, end: mid, population: left)
            boxes.append(Box(start: mid, end: box.end, population: box.population - left))
        }

        var rgb = [UInt8](repeating: 0, count: 256 * 3)
        var palette: [(Int, Int, Int)] = []
        for (i, box) in boxes.enumerated() {
            var r = 0, g = 0, b = 0, n = 0
            for e in entries[box.start..<box.end] {
                r += Int(sumR[e.bin]); g += Int(sumG[e.bin]); b += Int(sumB[e.bin]); n += e.count
            }
            let color = n > 0 ? ((r + n / 2) / n, (g + n / 2) / n, (b + n / 2) / n) : (0, 0, 0)
            palette.append(color)
            rgb[i * 3] = UInt8(color.0); rgb[i * 3 + 1] = UInt8(color.1); rgb[i * 3 + 2] = UInt8(color.2)
        }
        if palette.isEmpty { palette = [(0, 0, 0)] }

        var lookup = [UInt8](repeating: 0, count: 32768)
        for bin in 0..<32768 {
            let r: Int, g: Int, b: Int
            if counts[bin] > 0 {
                let n = UInt64(counts[bin])
                r = Int(sumR[bin] / n); g = Int(sumG[bin] / n); b = Int(sumB[bin] / n)
            } else {
                r = (bin >> 10 & 31) * 8 + 4; g = (bin >> 5 & 31) * 8 + 4; b = (bin & 31) * 8 + 4
            }
            var best = 0, bestDistance = Int.max
            for (i, c) in palette.enumerated() {
                let dr = r - c.0, dg = g - c.1, db = b - c.2
                let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                if distance < bestDistance { bestDistance = distance; best = i }
            }
            lookup[bin] = UInt8(best)
        }
        return GIFPalette(rgb: rgb, lookup: lookup)
    }
}

// MARK: - Encoder

/// Writes a GIF89a: one global palette, ordered dithering, and for every frame only the rectangle that changed,
/// with unchanged pixels left transparent. Frames identical to the previous one only extend its delay.
final class GIFEncoder {
    private let width: Int
    private let height: Int
    private let palette: GIFPalette
    private let dither: Bool
    private var file = [UInt8]()
    private var previous: [UInt8]?
    private var current: [UInt8]
    private var pending: PendingFrame?
    private var originTime: Double?
    private let lzw = LZWEncoder()
    private let bayer: [Int]

    private struct PendingFrame {
        var left: Int, top: Int, width: Int, height: Int
        var hasTransparency: Bool
        var data: [UInt8]
        var time: Double
    }

    init(width: Int, height: Int, palette: GIFPalette, dither: Bool) {
        self.width = width
        self.height = height
        self.palette = palette
        self.dither = dither
        current = [UInt8](repeating: 0, count: width * height)
        let matrix = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        bayer = matrix.map { Int((Double($0) - 7.5) * 0.8) }

        file.append(contentsOf: Array("GIF89a".utf8))
        file.append(contentsOf: [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)])
        file.append(contentsOf: [0xF7, 0, 0])
        file.append(contentsOf: palette.rgb)
        // Loop forever.
        file.append(contentsOf: [0x21, 0xFF, 0x0B])
        file.append(contentsOf: Array("NETSCAPE2.0".utf8))
        file.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    /// Adds a frame that starts at `time` seconds. Frames must come in increasing time order.
    func add(_ pixels: UnsafePointer<UInt8>, bytesPerRow: Int, at time: Double) {
        quantize(pixels, bytesPerRow: bytesPerRow)

        var left = 0, top = 0, w = width, h = height
        var hasTransparency = false
        var data: [UInt8]
        if let previous {
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                let row = y * width
                var x = 0
                while x < width {
                    if current[row + x] != previous[row + x] {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        maxY = y
                    }
                    x += 1
                }
            }
            if maxX < 0 { return } // Same picture: the previous frame just stays longer.
            left = minX; top = minY; w = maxX - minX + 1; h = maxY - minY + 1
            data = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                let source = (top + y) * width + left
                let target = y * w
                for x in 0..<w {
                    let value = current[source + x]
                    if value == previous[source + x] {
                        data[target + x] = GIFPalette.transparentIndex
                        hasTransparency = true
                    } else {
                        data[target + x] = value
                    }
                }
            }
        } else {
            data = current
        }

        if originTime == nil { originTime = time }
        flushPending(until: time)
        pending = PendingFrame(left: left, top: top, width: w, height: h, hasTransparency: hasTransparency, data: data, time: time)
        previous = current
    }

    /// Finishes the file. The last frame is shown until `endTime`.
    func finish(endTime: Double) -> Data {
        flushPending(until: endTime)
        file.append(0x3B)
        return Data(file)
    }

    // MARK: Frames

    private func flushPending(until next: Double) {
        guard let frame = pending else { return }
        pending = nil
        let origin = originTime ?? 0
        let startCS = Int(((frame.time - origin) * 100).rounded())
        let endCS = Int(((next - origin) * 100).rounded())
        let delay = min(65535, max(2, endCS - startCS))

        file.append(contentsOf: [0x21, 0xF9, 0x04, UInt8(0x04 | (frame.hasTransparency ? 1 : 0)),
                                 UInt8(delay & 0xFF), UInt8(delay >> 8),
                                 frame.hasTransparency ? GIFPalette.transparentIndex : 0, 0x00])
        file.append(0x2C)
        file.append(contentsOf: [UInt8(frame.left & 0xFF), UInt8(frame.left >> 8), UInt8(frame.top & 0xFF), UInt8(frame.top >> 8),
                                 UInt8(frame.width & 0xFF), UInt8(frame.width >> 8), UInt8(frame.height & 0xFF), UInt8(frame.height >> 8), 0x00])
        file.append(contentsOf: lzw.encode(frame.data))
    }

    // MARK: Quantizing

    private func quantize(_ pixels: UnsafePointer<UInt8>, bytesPerRow: Int) {
        palette.lookup.withUnsafeBufferPointer { lookup in
            palette.rgb.withUnsafeBufferPointer { colors in
                current.withUnsafeMutableBufferPointer { out in
                    bayer.withUnsafeBufferPointer { offsets in
                        for y in 0..<height {
                            var p = pixels + y * bytesPerRow
                            let row = y * width
                            let bayerRow = (y & 3) * 4
                            for x in 0..<width {
                                let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
                                var index = lookup[(r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)]
                                if dither {
                                    // Flat colours that the palette holds almost exactly stay exact; only the rest is dithered.
                                    let base = Int(index) * 3
                                    let dr = r - Int(colors[base]), dg = g - Int(colors[base + 1]), db = b - Int(colors[base + 2])
                                    if dr * dr + dg * dg + db * db > 27 {
                                        let d = offsets[bayerRow + (x & 3)]
                                        let rr = min(max(r + d, 0), 255), gg = min(max(g + d, 0), 255), bb = min(max(b + d, 0), 255)
                                        index = lookup[(rr >> 3) << 10 | (gg >> 3) << 5 | (bb >> 3)]
                                    }
                                }
                                out[row + x] = index
                                p += 4
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - LZW

/// GIF-flavoured variable-width LZW. Reused across frames.
private final class LZWEncoder {
    private let tableSize = 8192
    private let keys: UnsafeMutablePointer<Int32>
    private let values: UnsafeMutablePointer<UInt16>

    private var bits = 9
    private var maxCode = 511
    private var freeEntry = 258
    private var clearFlag = false
    private var accumulator: UInt32 = 0
    private var accumulatedBits = 0
    private var bytes = [UInt8]()

    init() {
        keys = .allocate(capacity: tableSize)
        values = .allocate(capacity: tableSize)
    }

    deinit {
        keys.deallocate()
        values.deallocate()
    }

    /// Returns the image data block of a GIF frame: minimum code size, sub-blocks, terminator.
    func encode(_ pixels: [UInt8]) -> [UInt8] {
        bits = 9; maxCode = 511; freeEntry = 258; clearFlag = false
        accumulator = 0; accumulatedBits = 0
        bytes.removeAll(keepingCapacity: true)
        resetTable()
        output(256)

        pixels.withUnsafeBufferPointer { buffer in
            guard var entry = buffer.first.map(Int.init) else { return }
            let mask = tableSize - 1
            for index in 1..<buffer.count {
                let c = Int(buffer[index])
                let key = Int32(entry << 8 | c)
                var slot = Int((UInt32(bitPattern: key) &* 2_654_435_761) >> 19) & mask
                var found = false
                while keys[slot] != -1 {
                    if keys[slot] == key { found = true; break }
                    slot = (slot + 1) & mask
                }
                if found {
                    entry = Int(values[slot])
                    continue
                }
                output(entry)
                entry = c
                if freeEntry < 4096 {
                    keys[slot] = key
                    values[slot] = UInt16(freeEntry)
                    freeEntry += 1
                } else {
                    resetTable()
                    freeEntry = 258
                    clearFlag = true
                    output(256)
                }
            }
            output(entry)
        }
        output(257)
        if accumulatedBits > 0 { bytes.append(UInt8(accumulator & 0xFF)) }

        var block = [UInt8]()
        block.reserveCapacity(bytes.count + bytes.count / 255 + 3)
        block.append(8)
        var offset = 0
        while offset < bytes.count {
            let length = min(255, bytes.count - offset)
            block.append(UInt8(length))
            block.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        block.append(0)
        return block
    }

    private func resetTable() {
        keys.initialize(repeating: -1, count: tableSize)
    }

    private func output(_ code: Int) {
        accumulator |= UInt32(code) << UInt32(accumulatedBits)
        accumulatedBits += bits
        while accumulatedBits >= 8 {
            bytes.append(UInt8(accumulator & 0xFF))
            accumulator >>= 8
            accumulatedBits -= 8
        }
        if freeEntry > maxCode || clearFlag {
            if clearFlag {
                bits = 9
                maxCode = 511
                clearFlag = false
            } else {
                bits += 1
                maxCode = bits == 12 ? 4096 : (1 << bits) - 1
            }
        }
    }
}
