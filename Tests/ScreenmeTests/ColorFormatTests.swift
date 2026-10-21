import XCTest
@testable import Screenme

final class ColorFormatTests: XCTestCase {
    func testHex() {
        XCTAssertEqual(ColorFormat.hex.string(red: 1, green: 59 / 255, blue: 48 / 255), "#FF3B30")
        XCTAssertEqual(ColorFormat.hex.string(red: 0, green: 0, blue: 0), "#000000")
    }

    func testRGB() {
        XCTAssertEqual(ColorFormat.rgb.string(red: 1, green: 0.5, blue: 0), "rgb(255, 128, 0)")
    }

    func testHSL() {
        XCTAssertEqual(ColorFormat.hsl.string(red: 1, green: 0, blue: 0), "hsl(0, 100%, 50%)")
        XCTAssertEqual(ColorFormat.hsl.string(red: 0, green: 0, blue: 1), "hsl(240, 100%, 50%)")
        XCTAssertEqual(ColorFormat.hsl.string(red: 0.5, green: 0.5, blue: 0.5), "hsl(0, 0%, 50%)")
        // #0A84FF, the system blue.
        XCTAssertEqual(ColorFormat.hsl.string(red: 10 / 255, green: 132 / 255, blue: 1), "hsl(210, 100%, 52%)")
        // Hue just under 360 rounds to 0, not 360.
        XCTAssertEqual(ColorFormat.hsl.string(red: 1, green: 0, blue: 0.003), "hsl(0, 100%, 50%)")
    }

    func testSwiftUI() {
        XCTAssertEqual(ColorFormat.swiftUI.string(red: 1, green: 0.5, blue: 0.25), "Color(red: 1.000, green: 0.500, blue: 0.250)")
    }

    func testOutOfRangeComponentsAreClamped() {
        XCTAssertEqual(ColorFormat.hex.string(red: 1.2, green: -0.1, blue: 0.5), "#FF0080")
    }
}
