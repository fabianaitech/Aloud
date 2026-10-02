// make_icon.swift — generates the Aloud app icon from CoreGraphics. Run with:
//     swift _dev/icon/make_icon.swift
// Produces, next to this script:
//   AppIcon-1024.png                       (master, the wired concept)
//   AppIcon.iconset/*.png + AppIcon.icns   (wired into build.sh)
//   alt-*-1024.png                         (colour alternates, for review only)
//   ../../ios/Aloud/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//                                          (the iPhone app: full bleed, opaque)
//
// Drawn rather than downloaded: an icon found online is someone's copyright, and
// shipping it inside an .app is a licensing problem. Code also stays crisp at
// every size and is reviewable in a diff.
//
// Concept: Big Sur rounded-square tile, ~824 live area on a 1024 canvas, with a
// white five-bar waveform — the universal "voice" mark. Bars, not concentric
// arcs: arcs read as Wi-Fi at small sizes, and this has to survive 16px in the
// Finder sidebar. Symmetric heights so it reads as a voice, not an equalizer.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let CANVAS: CGFloat = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: Int) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

struct Concept { let name: String; let top: Int; let bottom: Int }

// Indigo→violet: distinct from Claude Island's coral, so the two apps are never
// confused in the Dock or the menu bar's overflow.
let primary = Concept(name: "primary", top: 0x6366F1, bottom: 0x4F46E5)
let altTeal = Concept(name: "teal",    top: 0x2DD4BF, bottom: 0x0D9488)
let altCoral = Concept(name: "coral",  top: 0xDE8163, bottom: 0xD06E4E)  // Claude coral family

/// macOS draws the tile itself: a rounded square inside a transparent margin.
/// iOS wants the opposite — an opaque square to the edge, which the system
/// masks. Transparency there turns black, which is the border to avoid.
func tilePath(fullBleed: Bool = false) -> CGPath {
    if fullBleed { return CGPath(rect: CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS), transform: nil) }
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: CANVAS - 2 * inset, height: CANVAS - 2 * inset)
    return CGPath(roundedRect: rect, cornerWidth: 184, cornerHeight: 184, transform: nil)
}

func drawTile(_ ctx: CGContext, _ c: Concept, fullBleed: Bool = false) {
    let path = tilePath(fullBleed: fullBleed)
    // Soft drop shadow so a mid-tone tile still separates from a white Finder bg.
    // (Not on iOS: there is nothing outside the tile for it to fall on.)
    ctx.saveGState()
    if fullBleed { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
    if !fullBleed {
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30,
                      color: CGColor(gray: 0, alpha: 0.22))
    }
    ctx.addPath(path)
    ctx.setFillColor(rgb(c.top))
    ctx.fillPath()
    ctx.restoreGState()

    // Vertical gradient inside the tile.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: srgb,
                          colors: [rgb(c.top), rgb(c.bottom)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: CANVAS),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    // Faint top highlight — stops the flat fill looking like a placeholder.
    let gloss = CGGradient(colorsSpace: srgb,
                           colors: [CGColor(gray: 1, alpha: 0.18),
                                    CGColor(gray: 1, alpha: 0.0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           // From the tile's top edge: 100 in on macOS, the canvas edge on iOS.
                           start: CGPoint(x: 0, y: fullBleed ? CANVAS : CANVAS - 100),
                           end: CGPoint(x: 0, y: CANVAS * 0.55),
                           options: [])
    ctx.restoreGState()
}

/// Five rounded bars, symmetric about the centre: short / tall / tallest / tall /
/// short. Fully rounded caps (radius = half width) so they stay soft when the
/// icon is scaled down to 16px and the bars are barely 2px wide.
func drawWaveform(_ ctx: CGContext) {
    let heights: [CGFloat] = [196, 342, 470, 342, 196]
    let barW: CGFloat = 68
    let gap: CGFloat = 44
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (CANVAS - totalW) / 2
    let midY = CANVAS / 2

    ctx.saveGState()
    // A little depth under the white bars, so they don't look pasted on.
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
                  color: CGColor(gray: 0, alpha: 0.18))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for h in heights {
        let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2,
                           cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }
    ctx.restoreGState()
}

func render(_ c: Concept, px: Int, fullBleed: Bool = false) -> CGImage {
    // iOS rejects an app icon with an alpha channel, so that one is opaque.
    let alpha = fullBleed ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb, bitmapInfo: alpha.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(px) / CANVAS
    ctx.scaleBy(x: s, y: s)      // draw in 1024 units, crisp at any pixel size
    drawTile(ctx, c, fullBleed: fullBleed)
    drawWaveform(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fm = FileManager.default

writePNG(render(primary, px: 1024), outDir.appendingPathComponent("AppIcon-1024.png"))
writePNG(render(altTeal, px: 1024), outDir.appendingPathComponent("alt-teal-1024.png"))
writePNG(render(altCoral, px: 1024), outDir.appendingPathComponent("alt-coral-1024.png"))

let iosIcon = outDir.appendingPathComponent("../../ios/Aloud/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
    .standardizedFileURL
writePNG(render(primary, px: 1024, fullBleed: true), iosIcon)

// The watch app: the same square, which watchOS masks to a circle.
let watchSet = outDir.appendingPathComponent("../../ios/AloudWatch/Assets.xcassets/AppIcon.appiconset").standardizedFileURL
try? fm.createDirectory(at: watchSet, withIntermediateDirectories: true)
writePNG(render(primary, px: 1024, fullBleed: true), watchSet.appendingPathComponent("icon-1024.png"))
try! """
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "watchos", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: watchSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try! """
{ "info" : { "author" : "xcode", "version" : 1 } }
""".write(to: watchSet.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// The iPhone app's accent colours, each with its own home-screen icon
// (alternate app icons). Same names and colours as Accent in ios/Aloud/Theme.swift.
let iosAccents: [Concept] = [
    Concept(name: "blue", top: 0x3B82F6, bottom: 0x2563EB),
    Concept(name: "teal", top: 0x2DD4BF, bottom: 0x0D9488),
    Concept(name: "green", top: 0x34D399, bottom: 0x059669),
    Concept(name: "coral", top: 0xDE8163, bottom: 0xD06E4E),
    Concept(name: "pink", top: 0xF472B6, bottom: 0xDB2777),
    Concept(name: "purple", top: 0xA78BFA, bottom: 0x7C3AED),
    Concept(name: "graphite", top: 0x6B7280, bottom: 0x374151),
]
let catalog = outDir.appendingPathComponent("../../ios/Aloud/Assets.xcassets").standardizedFileURL
for c in iosAccents {
    let set = catalog.appendingPathComponent("AppIcon-\(c.name).appiconset")
    try? fm.createDirectory(at: set, withIntermediateDirectories: true)
    writePNG(render(c, px: 1024, fullBleed: true), set.appendingPathComponent("icon-1024.png"))
    let json = """
    {
      "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try! json.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

// Full iconset for iconutil.
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    writePNG(render(primary, px: px), iconset.appendingPathComponent(name))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path,
               "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()

print("wrote:")
print("  \(outDir.appendingPathComponent("AppIcon-1024.png").path)")
print("  \(outDir.appendingPathComponent("AppIcon.icns").path)  (iconutil exit \(p.terminationStatus))")
print("  \(outDir.appendingPathComponent("alt-teal-1024.png").path)")
print("  \(outDir.appendingPathComponent("alt-coral-1024.png").path)")
print("  \(iosIcon.path)")
