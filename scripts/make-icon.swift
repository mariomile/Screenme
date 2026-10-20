// Generates the Screenme app icon, the menu bar icon and docs/icon-preview.png.
// Usage: swift scripts/make-icon.swift <repo root>
// Not part of the app target (lives outside Sources/Screenme).
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, nil)
    precondition(CGImageDestinationFinalize(d))
}

// MARK: App icon (1024 design grid, body 824 with 100 margin)

func squircle(_ r: CGRect, n: CGFloat = 5.2) -> CGPath {
    let p = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func brackets(half: CGFloat, arm: CGFloat, radius: CGFloat, center: CGPoint) -> CGPath {
    let p = CGMutablePath()
    for (sx, sy) in [(-1.0, 1.0), (1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] as [(CGFloat, CGFloat)] {
        let corner = CGPoint(x: center.x + sx * half, y: center.y + sy * half)
        p.move(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
        p.addArc(tangent1End: corner, tangent2End: CGPoint(x: corner.x - sx * arm, y: corner.y), radius: radius)
        p.addLine(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
    }
    return p
}

let ext: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let k = size / 1024 // CG shadow params ignore the CTM
    ctx.saveGState()
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    let small = size <= 64
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Drop shadow (part of the artwork, as in system icons)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 26 * k, color: rgb(0x0B0830, 0.45))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x2B1B8F)); ctx.fillPath()
    ctx.restoreGState()

    // Body
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(0x8E5BFF), 0), (rgb(0x5A33E0), 0.5), (rgb(0x20186E), 1)]),
                           start: CGPoint(x: 760, y: 924), end: CGPoint(x: 280, y: 100), options: ext)
    // Soft glow behind the viewfinder
    ctx.drawRadialGradient(gradient([(rgb(0xB48CFF, 0.40), 0), (rgb(0xB48CFF, 0), 1)]),
                           startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 430, options: ext)
    // Top highlight
    ctx.drawLinearGradient(gradient([(rgb(0xFFFFFF, 0.30), 0), (rgb(0xFFFFFF, 0.06), 0.55), (rgb(0xFFFFFF, 0), 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: ext)
    // Bottom inner shade
    ctx.drawLinearGradient(gradient([(rgb(0x0B0830, 0.35), 0), (rgb(0x0B0830, 0), 1)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 300), options: ext)
    ctx.restoreGState()

    // Rim light: thin bright edge fading out downwards
    ctx.saveGState()
    ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5)))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(0xFFFFFF, 0.55), 0), (rgb(0xFFFFFF, 0.08), 0.5), (rgb(0xFFFFFF, 0.18), 1)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: ext)
    ctx.restoreGState()

    // Viewfinder brackets
    let c = CGPoint(x: 512, y: 512)
    let bp = brackets(half: small ? 232 : 236, arm: small ? 190 : 168, radius: 46, center: c)
    let stroke: CGFloat = small ? 96 : 68
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: rgb(0x0B0830, 0.40))
    ctx.addPath(bp); ctx.setLineWidth(stroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.strokePath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bp); ctx.setLineWidth(stroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(rgb(0xFFFFFF), 0), (rgb(0xE4D9FF), 1)]),
                           start: CGPoint(x: 512, y: 780), end: CGPoint(x: 512, y: 244), options: ext)
    ctx.restoreGState()

    // Shutter: translucent aperture ring with a solid core
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 14 * k, color: rgb(0x0B0830, 0.35))
    ctx.setFillColor(rgb(0xFFFFFF))
    let core: CGFloat = small ? 78 : 58
    ctx.fillEllipse(in: CGRect(x: 512 - core, y: 512 - core, width: core * 2, height: core * 2))
    ctx.restoreGState()
    if !small {
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.setLineWidth(16)
        ctx.strokeEllipse(in: CGRect(x: 512 - 104, y: 512 - 104, width: 208, height: 208))
    }
    ctx.restoreGState()
}

func iconImage(_ px: Int) -> CGImage {
    let c = bitmap(px, px)
    drawIcon(c, size: CGFloat(px))
    return c.makeImage()!
}

// MARK: Menu bar icon (18 pt grid, template: black + alpha)

func drawMenu(_ ctx: CGContext, scale: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    let p = brackets(half: 6, arm: 5, radius: 2, center: CGPoint(x: 9, y: 9))
    ctx.addPath(p); ctx.setLineWidth(2); ctx.setLineCap(.butt); ctx.setLineJoin(.round)
    ctx.setStrokeColor(color); ctx.strokePath()
    ctx.restoreGState()
}

func menuImage(pt: Int, scale: Int, color: CGColor = rgb(0x000000)) -> CGImage {
    let c = bitmap(pt * scale, pt * scale)
    drawMenu(c, scale: CGFloat(scale), color: color)
    return c.makeImage()!
}

// MARK: Write assets

let res = root.appendingPathComponent("Sources/Screenme/Resources/Assets.xcassets")
let setDir = res.appendingPathComponent("AppIcon.appiconset")
var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(iconImage(base * scale), to: setDir.appendingPathComponent(name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(base)x\(base)" }
        """)
    }
}
try! """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: setDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try! "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
    .write(to: res.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let menuDir = res.appendingPathComponent("MenuBarIcon.imageset")
writePNG(menuImage(pt: 18, scale: 1), to: menuDir.appendingPathComponent("MenuBarIcon.png"))
writePNG(menuImage(pt: 18, scale: 2), to: menuDir.appendingPathComponent("MenuBarIcon@2x.png"))
try! """
{
  "images" : [
    { "filename" : "MenuBarIcon.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "MenuBarIcon@2x.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
""".write(to: menuDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// MARK: Preview

func label(_ ctx: CGContext, _ s: String, at p: CGPoint, color: CGColor) {
    let font = CTFontCreateWithName("Helvetica Neue" as CFString, 15, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = p
    CTLineDraw(line, ctx)
}

let W = 1600, H = 760
let pv = bitmap(W, H)
for (i, dark) in [false, true].enumerated() {
    let x0 = CGFloat(i * 800)
    pv.setFillColor(dark ? rgb(0x1C1C1E) : rgb(0xF2F2F7))
    pv.fill(CGRect(x: x0, y: 0, width: 800, height: CGFloat(H)))
    let fg = dark ? rgb(0xFFFFFF, 0.7) : rgb(0x000000, 0.6)
    pv.draw(iconImage(1024), in: CGRect(x: x0 + 40, y: 240, width: 480, height: 480))
    let x = x0 + 560
    for (sz, ty) in [(128, 592.0), (64, 510.0), (32, 460.0)] as [(Int, CGFloat)] {
        pv.draw(iconImage(sz), in: CGRect(x: x, y: ty, width: CGFloat(sz), height: CGFloat(sz)))
        label(pv, "\(sz) px", at: CGPoint(x: x + CGFloat(sz) + 12, y: ty + CGFloat(sz) / 2 - 5), color: fg)
    }
    pv.draw(iconImage(16), in: CGRect(x: x, y: 424, width: 16, height: 16))
    label(pv, "16 px", at: CGPoint(x: x + 28, y: 427), color: fg)
    // Fake menu bar strip
    pv.setFillColor(dark ? rgb(0x2C2C2E) : rgb(0xE5E5EA))
    pv.fill(CGRect(x: x0 + 40, y: 140, width: 720, height: 64))
    let ink = dark ? rgb(0xFFFFFF) : rgb(0x000000)
    pv.draw(menuImage(pt: 18, scale: 2, color: ink), in: CGRect(x: x0 + 60, y: 163, width: 18, height: 18))
    label(pv, "Menu bar icon, actual size (2x)", at: CGPoint(x: x0 + 96, y: 168), color: fg)
    pv.draw(menuImage(pt: 18, scale: 8, color: ink), in: CGRect(x: x0 + 40, y: 20, width: 90, height: 90))
    pv.draw(menuImage(pt: 18, scale: 2, color: ink), in: CGRect(x: x0 + 150, y: 20, width: 90, height: 90))
    label(pv, "Menu bar icon: drawn at 8x, and the shipped 36 px file enlarged", at: CGPoint(x: x0 + 260, y: 60), color: fg)
}
writePNG(pv.makeImage()!, to: root.appendingPathComponent("docs/icon-preview.png"))
print("done")
