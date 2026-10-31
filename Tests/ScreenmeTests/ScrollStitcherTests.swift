import AppKit
import XCTest
@testable import Screenme

/// Frames are windows onto one tall "page" of noisy grey rows, so every window has detail the matcher can lock onto.
final class ScrollStitcherTests: XCTestCase {
    private let width = 64
    private let frameHeight = 200

    /// Page rows, BGRA, `width` pixels each. Each 8-pixel band of a row gets its own seeded grey level.
    private func makePage(rows: Int, seed: UInt64) -> [UInt8] {
        var state = seed
        var page = [UInt8](repeating: 255, count: rows * width * 4)
        for y in 0..<rows {
            for band in 0..<(width / 8) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let grey = UInt8(truncatingIfNeeded: state >> 33)
                for x in (band * 8)..<(band * 8 + 8) {
                    let o = (y * width + x) * 4
                    page[o] = grey; page[o + 1] = grey; page[o + 2] = grey
                }
            }
        }
        return page
    }

    /// `frameHeight` rows of `page` starting at `offset`, with optional constant header and footer rows pinned on top.
    private func frame(of page: [UInt8], at offset: Int, header: Int = 0, footer: Int = 0) -> [UInt8] {
        let rowBytes = width * 4
        var out = Array(page[(offset * rowBytes)..<((offset + frameHeight) * rowBytes)])
        for y in 0..<header { out.replaceSubrange((y * rowBytes)..<((y + 1) * rowBytes), with: repeatElement(40, count: rowBytes)) }
        for y in (frameHeight - footer)..<frameHeight { out.replaceSubrange((y * rowBytes)..<((y + 1) * rowBytes), with: repeatElement(220, count: rowBytes)) }
        return out
    }

    private func add(_ stitcher: ScrollStitcher, _ pixels: [UInt8]) -> ScrollStitcher.Outcome {
        pixels.withUnsafeBufferPointer { stitcher.add($0.baseAddress!, bytesPerRow: width * 4) }
    }

    private func bytes(of image: CGImage) -> [UInt8] {
        Array(image.dataProvider!.data! as Data)
    }

    func testRejectsTooSmallFrames() {
        XCTAssertNil(ScrollStitcher(width: 4, height: 200))
        XCTAssertNil(ScrollStitcher(width: 64, height: 32))
    }

    func testStitchesOverlappingFramesIntoTheOriginalPage() throws {
        let shift = 60, frames = 5
        let page = makePage(rows: frameHeight + shift * (frames - 1), seed: 1)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))

        XCTAssertEqual(add(stitcher, frame(of: page, at: 0)), .first)
        for i in 1..<frames {
            XCTAssertEqual(add(stitcher, frame(of: page, at: i * shift)), .advanced, "frame \(i)")
        }
        XCTAssertEqual(stitcher.totalRows, frameHeight + shift * (frames - 1))

        let image = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, frameHeight + shift * (frames - 1))
        XCTAssertEqual(bytes(of: image), page, "stitched pixels must equal the source page")
    }

    func testVariableScrollSpeeds() throws {
        let offsets = [0, 25, 110, 130, 190]
        let page = makePage(rows: offsets.last! + frameHeight, seed: 2)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        _ = add(stitcher, frame(of: page, at: offsets[0]))
        for offset in offsets.dropFirst() {
            XCTAssertEqual(add(stitcher, frame(of: page, at: offset)), .advanced, "offset \(offset)")
        }
        let image = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(image.height, offsets.last! + frameHeight)
        XCTAssertEqual(bytes(of: image), page)
    }

    func testIdenticalFrameIsStill() throws {
        let page = makePage(rows: frameHeight, seed: 3)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        XCTAssertEqual(add(stitcher, frame(of: page, at: 0)), .first)
        XCTAssertEqual(add(stitcher, frame(of: page, at: 0)), .still)
        XCTAssertEqual(stitcher.totalRows, frameHeight)
        XCTAssertEqual(try XCTUnwrap(stitcher.finish()).height, frameHeight)
    }

    func testUnrelatedFrameIsLostAndAddsNothing() throws {
        let first = makePage(rows: frameHeight, seed: 4)
        let other = makePage(rows: frameHeight, seed: 5)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        XCTAssertEqual(add(stitcher, frame(of: first, at: 0)), .first)
        XCTAssertEqual(add(stitcher, frame(of: other, at: 0)), .lost)
        XCTAssertEqual(stitcher.totalRows, frameHeight)
    }

    func testScrollingBackNeverDuplicatesContent() throws {
        let page = makePage(rows: frameHeight + 100, seed: 6)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        _ = add(stitcher, frame(of: page, at: 0))
        XCTAssertEqual(add(stitcher, frame(of: page, at: 100)), .advanced)
        XCTAssertEqual(add(stitcher, frame(of: page, at: 40)), .scrolledBack)
        XCTAssertEqual(stitcher.totalRows, frameHeight + 100)
        // Scrolling forward again over what is already stitched adds nothing either.
        XCTAssertEqual(add(stitcher, frame(of: page, at: 100)), .still)
        let image = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(image.height, frameHeight + 100)
        XCTAssertEqual(bytes(of: image), page)
    }

    func testStickyHeaderAndFooterAppearOnce() throws {
        let shift = 50, frames = 4
        let page = makePage(rows: frameHeight + shift * (frames - 1), seed: 7)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        _ = add(stitcher, frame(of: page, at: 0, header: 20, footer: 16))
        for i in 1..<frames {
            XCTAssertEqual(add(stitcher, frame(of: page, at: i * shift, header: 20, footer: 16)), .advanced, "frame \(i)")
        }
        let image = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(image.height, frameHeight + shift * (frames - 1))

        // Header on top, footer closing the image, once each.
        let data = bytes(of: image)
        let rowBytes = width * 4
        func rowIsConstant(_ row: Int, _ value: UInt8) -> Bool { data[(row * rowBytes)..<((row + 1) * rowBytes)].allSatisfy { $0 == value || $0 == 255 } }
        XCTAssertTrue((0..<20).allSatisfy { rowIsConstant($0, 40) })
        XCTAssertTrue((image.height - 16..<image.height).allSatisfy { rowIsConstant($0, 220) })
        XCTAssertFalse(rowIsConstant(20 + 5, 40), "the header must not repeat down the page")
    }

    /// A fixed sidebar (flat, with a bright bar every 37 rows) beside a scrolling page: its bars show once, in the
    /// first frame, and the page next to it still matches the source.
    func testFixedSidebarIsNotRepeatedDownThePage() throws {
        let shift = 23, frames = 12, sidebar = 16
        var page = makePage(rows: frameHeight + shift * (frames - 1), seed: 9)
        let rowBytes = width * 4
        let content = sidebar + 8 // the page starts after a gap, as it does beside a real sidebar
        for y in 0..<(page.count / rowBytes) {
            page.replaceSubrange((y * rowBytes + sidebar * 4)..<(y * rowBytes + content * 4), with: repeatElement(255, count: (content - sidebar) * 4))
        }
        func shot(_ i: Int) -> [UInt8] {
            var out = frame(of: page, at: i * shift)
            for y in 0..<frameHeight {
                let value: UInt8 = y % 37 < 8 ? 200 : 20
                for x in 0..<sidebar {
                    let o = y * rowBytes + x * 4
                    out[o] = value; out[o + 1] = value; out[o + 2] = value
                }
            }
            return out
        }
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        for i in 0..<frames {
            XCTAssertNotEqual(add(stitcher, shot(i)), .lost, "frame \(i)")
        }
        let image = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(image.height, frameHeight + shift * (frames - 1))
        let data = bytes(of: image)
        for y in 0..<image.height {
            for x in content..<width {
                XCTAssertEqual(data[y * rowBytes + x * 4], page[y * rowBytes + x * 4], "page pixel \(x),\(y)")
                if data[y * rowBytes + x * 4] != page[y * rowBytes + x * 4] { return }
            }
        }
        let bars = (frameHeight..<image.height).filter { data[$0 * rowBytes] == 200 }
        XCTAssertTrue(bars.isEmpty, "sidebar bars repeated at rows \(bars.prefix(8))")
    }

    /// A real page: black text on white with wide empty margins and gaps, a sticky nav bar, Retina-sized
    /// frames and the uneven steps of a trackpad flick (fast, then slowing down, with idle frames).
    func testRenderedTextPageWithTrackpadMomentum() throws {
        let pageWidth = 1400, viewport = 900, nav = 96
        let offsets = [0, 4, 30, 140, 320, 560, 780, 960, 1100, 1190, 1240, 1262, 1270, 1270, 1290, 1420, 1700, 2050, 2300, 2420, 2460]
        let page = renderTextPage(width: pageWidth, height: offsets.last! + viewport)
        let rowBytes = pageWidth * 4
        func shot(_ offset: Int) -> [UInt8] {
            var out = Array(page[(offset * rowBytes)..<((offset + viewport) * rowBytes)])
            out.replaceSubrange(0..<(nav * rowBytes), with: repeatElement(30, count: nav * rowBytes)) // the sticky nav bar
            return out
        }
        let stitcher = try XCTUnwrap(ScrollStitcher(width: pageWidth, height: viewport))
        for offset in offsets {
            let outcome = shot(offset).withUnsafeBufferPointer { stitcher.add($0.baseAddress!, bytesPerRow: rowBytes) }
            XCTAssertNotEqual(outcome, .lost, "offset \(offset)")
        }
        let image = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(image.height, offsets.last! + viewport)
        // Below the nav bar, every stitched row is the page row at the same height.
        let stitched = bytes(of: image)
        let wrong = (nav..<image.height).first { stitched[($0 * rowBytes)..<(($0 + 1) * rowBytes)] != page[($0 * rowBytes)..<(($0 + 1) * rowBytes)] }
        XCTAssertNil(wrong, "first stitched row that differs from the page")
    }

    /// White page with paragraphs of 15 pt text drawn at 2x, headings, and blank gaps between sections.
    private func renderTextPage(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.current = previous }
            let words = "the total on the checkout page is wrong because the discount code is applied twice when the plan changes and nobody noticed until a customer wrote in".split(separator: " ")
            var y = height - 140
            var section = 0
            while y > 60 {
                let heading = NSAttributedString(string: "Section \(section + 1): what happened", attributes: [.font: NSFont.boldSystemFont(ofSize: 44)])
                heading.draw(at: CGPoint(x: 200, y: y))
                y -= 90
                for line in 0..<(6 + section % 4) where y > 60 {
                    let text = (0..<12).map { String(words[(section * 7 + line * 5 + $0) % words.count]) }.joined(separator: " ")
                    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 30)]).draw(at: CGPoint(x: 200, y: y))
                    y -= 52
                }
                y -= 160 // the empty gap between sections
                section += 1
            }
        }
        return pixels
    }

    func testFinishTwiceReturnsNil() throws {
        let page = makePage(rows: frameHeight, seed: 8)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        _ = add(stitcher, frame(of: page, at: 0))
        XCTAssertNotNil(stitcher.finish())
        XCTAssertNil(stitcher.finish())
    }
}
