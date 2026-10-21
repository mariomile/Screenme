import AppKit
import SwiftUI

extension Pref {
    static let colorFormat = PrefKey(name: "colorFormat", defaultValue: ColorFormat.hex)
}

/// How Pick Color writes the color it copies.
enum ColorFormat: String, CaseIterable, Identifiable {
    case hex, rgb, hsl, swiftUI
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: "HEX  #RRGGBB"
        case .rgb: "RGB  rgb(r, g, b)"
        case .hsl: "HSL  hsl(h, s%, l%)"
        case .swiftUI: "SwiftUI  Color(red:green:blue:)"
        }
    }

    /// `red`, `green` and `blue` are sRGB components from 0 to 1.
    func string(red: Double, green: Double, blue: Double) -> String {
        let r = min(max(red, 0), 1), g = min(max(green, 0), 1), b = min(max(blue, 0), 1)
        func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        case .rgb:
            return "rgb(\(byte(r)), \(byte(g)), \(byte(b)))"
        case .hsl:
            let (h, s, l) = Self.hsl(r, g, b)
            return "hsl(\(Int(h.rounded()) % 360), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        case .swiftUI:
            func component(_ value: Double) -> String { String(format: "%.3f", value) }
            return "Color(red: \(component(r)), green: \(component(g)), blue: \(component(b)))"
        }
    }

    /// Hue in degrees, saturation and lightness from 0 to 1.
    private static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        switch high {
        case r: h = (g - b) / delta
        case g: h = (b - r) / delta + 2
        default: h = (r - g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }
}

/// Pick Color: the system loupe picks any pixel on screen (no Screen Recording needed),
/// and the color is copied as text in the format chosen in Settings.
@MainActor
enum ScreenColorPicker {
    static func run() async {
        // Esc reaches the loupe only while Screenme is active; the app the user was in gets focus back after.
        let previous = FocusKeeper.frontmostExternal()
        FocusKeeper.activateSelf()
        let picked = await NSColorSampler().sample()
        await FocusKeeper.restore(previous)
        guard let color = picked?.usingColorSpace(.sRGB) else { return }
        let text = Prefs[Pref.colorFormat].string(red: Double(color.redComponent), green: Double(color.greenComponent),
                                                  blue: Double(color.blueComponent))
        Clipboard.copyText(text)
        Toast.show(text, swatch: Color(nsColor: color))
    }
}
