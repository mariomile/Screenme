import CoreGraphics
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

    func testFinishTwiceReturnsNil() throws {
        let page = makePage(rows: frameHeight, seed: 8)
        let stitcher = try XCTUnwrap(ScrollStitcher(width: width, height: frameHeight))
        _ = add(stitcher, frame(of: page, at: 0))
        XCTAssertNotNil(stitcher.finish())
        XCTAssertNil(stitcher.finish())
    }
}
