import XCTest
@testable import Screenme

/// The editor's blur and pixelate patches: a full cache drops the least recently used patch, not all of them.
final class RedactionCacheTests: XCTestCase {
    @MainActor
    func testFullCacheEvictsTheLeastRecentlyUsedPatch() throws {
        let image = try XCTUnwrap(CGImage.drawn(width: 200, height: 10, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { _ in })
        let source = ImageSource(image: image, unit: 1)
        func patch(_ i: Int) -> CGImage? { source.pixelated(CGRect(x: i * 4, y: 0, width: 4, height: 4), block: 2)?.0 }

        let first = try XCTUnwrap(patch(0))
        let second = try XCTUnwrap(patch(1))
        for i in 2..<48 { _ = patch(i) }
        XCTAssertEqual(source.cachedRedactionCount, 48)

        XCTAssertTrue(patch(0) === first, "a hit marks the patch as used")
        _ = patch(48)

        XCTAssertEqual(source.cachedRedactionCount, 48)
        XCTAssertTrue(patch(0) === first, "the recently used patch stays")
        XCTAssertFalse(patch(1) === second, "the least recently used patch was dropped and made again")
    }
}
