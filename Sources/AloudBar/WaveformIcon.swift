// WaveformIcon.swift — the menu bar mark: the same five-bar waveform as the app
// icon, drawn as a monochrome template image.
//
// The status item is a status *readout*, not just branding, so rather than
// swapping to unrelated SF Symbols per state the bars express the state
// themselves — one visual vocabulary, four readings:
//
//   engine off   flattened to a line          "no signal"
//   idle         the static waveform          the app's mark, at rest
//   speaking     animated level meter         unmistakably talking
//   paused       two tall bars                reads as ⏸, same bars
//
// Template images are drawn in black with alpha; macOS recolours them for light,
// dark and tinted menu bars, so nothing here picks a colour.

import AppKit

enum WaveformIcon {
    /// Menu bar items get ~18×18pt to play with; the bars sit inside that.
    static let size = NSSize(width: 18, height: 16)
    private static let barCount = 5

    /// Resting shape — the app icon's silhouette, normalized 0…1.
    static let idleLevels: [CGFloat] = [0.34, 0.62, 0.92, 0.62, 0.34]
    /// Flattened: still five bars, but with nothing to say.
    static let offLevels: [CGFloat] = Array(repeating: 0.12, count: barCount)

    /// A frame of the speaking animation. `phase` advances by ~0.35 per tick; the
    /// per-bar offsets keep neighbours out of step so it ripples rather than pulses.
    static func speakingLevels(phase: CGFloat) -> [CGFloat] {
        let offsets: [CGFloat] = [0.0, 1.1, 2.2, 3.3, 4.4]
        return offsets.map { off in
            // Two frequencies so the motion doesn't read as a clean sine loop.
            let a = sin(phase + off)
            let b = sin(phase * 1.7 + off * 0.6)
            let v = (a * 0.6 + b * 0.4 + 1) / 2      // 0…1
            return 0.22 + v * 0.72                    // never fully collapsed
        }
    }

    /// Bars for a given state. `alpha` below 1 dims the whole mark — used for the
    /// stopped engine, where the flattened bars alone read as a slightly cryptic
    /// row of dots; dimmed as well, it is unmistakably "inactive".
    static func image(levels: [CGFloat], alpha: CGFloat = 1) -> NSImage {
        draw { ctx, rect in
            ctx.setAlpha(alpha)
            bars(ctx, rect, levels: levels, visible: Array(0..<barCount))
        }
    }

    /// Paused: keep only the two inner-flank bars at full height. Same shapes,
    /// same spacing — it just happens to look exactly like a pause glyph.
    static func pausedImage() -> NSImage {
        draw { ctx, rect in
            bars(ctx, rect, levels: Array(repeating: 0.92, count: barCount), visible: [1, 3])
        }
    }

    private static func bars(_ ctx: CGContext, _ rect: CGRect,
                             levels: [CGFloat], visible: [Int]) {
        // Bar width and gap chosen so five bars fill the width exactly; at this
        // size a bar is ~2pt, which is why the caps are fully rounded.
        let gapRatio: CGFloat = 0.62
        let barW = rect.width / (CGFloat(barCount) + CGFloat(barCount - 1) * gapRatio)
        let gap = barW * gapRatio
        let midY = rect.midY
        ctx.setFillColor(NSColor.black.cgColor)   // template: colour is ignored
        for i in visible {
            let h = max(barW, rect.height * levels[i])
            let x = rect.minX + CGFloat(i) * (barW + gap)
            let r = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2,
                               cornerHeight: barW / 2, transform: nil))
        }
        ctx.fillPath()
    }

    private static func draw(_ body: @escaping (CGContext, CGRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            body(ctx, rect.insetBy(dx: 0.5, dy: 0.5))
            return true
        }
        image.isTemplate = true
        return image
    }
}
