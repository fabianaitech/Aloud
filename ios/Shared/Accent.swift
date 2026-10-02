// Accent.swift — the accent colours, shared by the iPhone and watch apps.

import Foundation

/// The accent colours on offer, each a gradient with its own home-screen icon
/// (drawn by _dev/icon/make_icon.swift from the same values).
enum Accent: String, CaseIterable, Identifiable {
    case indigo, blue, teal, green, coral, pink, purple, graphite

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Gradient top and bottom, as in the icon.
    var colors: (top: UInt32, bottom: UInt32) {
        switch self {
        case .indigo: return (0x6366F1, 0x4F46E5)
        case .blue: return (0x3B82F6, 0x2563EB)
        case .teal: return (0x2DD4BF, 0x0D9488)
        case .green: return (0x34D399, 0x059669)
        case .coral: return (0xDE8163, 0xD06E4E)
        case .pink: return (0xF472B6, 0xDB2777)
        case .purple: return (0xA78BFA, 0x7C3AED)
        case .graphite: return (0x6B7280, 0x374151)
        }
    }

    /// The alternate icon's name; indigo is the app's own icon.
    var iconName: String? { self == .indigo ? nil : "AppIcon-\(rawValue)" }

    static var current: Accent {
        Accent(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .indigo
    }

    /// Gradient stops as 0...1 RGB, for SwiftUI on either platform.
    var rgb: (top: (Double, Double, Double), bottom: (Double, Double, Double)) {
        func split(_ h: UInt32) -> (Double, Double, Double) {
            (Double((h >> 16) & 0xFF) / 255, Double((h >> 8) & 0xFF) / 255, Double(h & 0xFF) / 255)
        }
        return (split(colors.top), split(colors.bottom))
    }
}

