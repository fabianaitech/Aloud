// Theme.swift — the small shared pieces: state pill, surface icon, the waveform.

import SwiftUI

import UIKit

private func uiColor(_ hex: UInt32) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

extension Color {
    /// The accent, for fills: buttons, bubbles, the tile.
    static var aloud: Color { Color(uiColor: uiColor(Accent.current.colors.top)) }
    static var aloudDeep: Color { Color(uiColor: uiColor(Accent.current.colors.bottom)) }
    /// The accent for text on a plain background: the deeper shade in light
    /// mode, the brighter one in dark, so it stays readable in both.
    static var aloudText: Color {
        let c = Accent.current.colors
        return Color(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark ? uiColor(c.top) : uiColor(c.bottom)
        })
    }
}

extension LinearGradient {
    static var aloud: LinearGradient {
        LinearGradient(colors: [.aloud, .aloudDeep], startPoint: .top, endPoint: .bottom)
    }
}

/// Ready / Working / Needs permission, with a dot that breathes while Claude works.
struct StatePill: View {
    let state: String
    var compact = false

    private var style: (String, Color) {
        switch state {
        case "busy": return ("Working", .orange)
        case "permission": return ("Needs permission", .red)
        case "idle": return ("Ready", .green)
        case "ended": return ("Ended", .gray)
        default: return (state.capitalized, .gray)
        }
    }

    var body: some View {
        let (label, color) = style
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .phaseAnimator(state == "busy" ? [0.35, 1.0] : [1.0]) { dot, phase in
                    dot.opacity(phase)
                } animation: { _ in .easeInOut(duration: 0.8) }
            if !compact {
                Text(label).font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// The session's surface — Terminal, Desktop, VS Code — as a small tile.
struct SurfaceTile: View {
    let session: RemoteSession?
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient.aloud)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: session?.surfaceIcon ?? "waveform")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Aloud's five bars. Idle it's the logo; recording, the bars follow your voice.
struct WaveformBars: View {
    var level: Float = 0
    var animating = false
    var color: Color = .white
    var height: CGFloat = 28

    private let shape: [CGFloat] = [0.42, 0.73, 1.0, 0.73, 0.42]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: height * 0.12) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = animating ? 0.55 + 0.45 * abs(sin(t * 6 + Double(i) * 0.9)) : 1
                    let l = animating ? max(0.18, CGFloat(level)) : 1
                    Capsule()
                        .fill(color)
                        .frame(width: height * 0.14,
                               height: max(height * 0.16, height * shape[i] * l * CGFloat(wobble)))
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

extension View {
    /// The card surface used throughout.
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
