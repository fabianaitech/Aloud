// Voices.swift — the two engines Aloud can drive, and the voices each offers.
//
// Kokoro's list is fixed, so it ships here. Apple's is whatever the user has
// downloaded in System Settings, so it comes from the daemon's GET /voices —
// one parser, shared, rather than a second copy of `say -v '?'` scraping here.

import Foundation

enum Engine: String, CaseIterable {
    case apple
    case kokoro

    var title: String {
        switch self {
        case .apple:  return "Apple"
        case .kokoro: return "Kokoro"
        }
    }

    /// Shown under the engine name in the menu — the trade-off in one line.
    var subtitle: String {
        switch self {
        case .apple:  return "Built in · instant · no memory"
        case .kokoro: return "Best quality · 1.2 GB while warm"
        }
    }
}

struct Voice {
    let id: String       // what the daemon wants: "af_heart", or "Isha (Premium)"
    let name: String     // what the menu shows
}

/// One voice as the daemon reports it from `say -v '?'`.
struct AppleVoice: Decodable {
    let name: String
    let lang: String
    let quality: String   // "premium" | "enhanced" | "default"
}

enum Voices {
    /// Kokoro-82M's American English voices. `af_heart` is the shipped default
    /// and the best-graded of them; the rest are ordered alphabetically.
    static let female: [Voice] = [
        Voice(id: "af_heart",   name: "Heart"),
        Voice(id: "af_alloy",   name: "Alloy"),
        Voice(id: "af_aoede",   name: "Aoede"),
        Voice(id: "af_bella",   name: "Bella"),
        Voice(id: "af_jessica", name: "Jessica"),
        Voice(id: "af_kore",    name: "Kore"),
        Voice(id: "af_nicole",  name: "Nicole"),
        Voice(id: "af_nova",    name: "Nova"),
        Voice(id: "af_river",   name: "River"),
        Voice(id: "af_sarah",   name: "Sarah"),
        Voice(id: "af_sky",     name: "Sky"),
    ]

    static let male: [Voice] = [
        Voice(id: "am_michael", name: "Michael"),
        Voice(id: "am_adam",    name: "Adam"),
        Voice(id: "am_echo",    name: "Echo"),
        Voice(id: "am_eric",    name: "Eric"),
        Voice(id: "am_fenrir",  name: "Fenrir"),
        Voice(id: "am_liam",    name: "Liam"),
        Voice(id: "am_onyx",    name: "Onyx"),
        Voice(id: "am_puck",    name: "Puck"),
        Voice(id: "am_santa",   name: "Santa"),
    ]

    static let all: [Voice] = female + male

    /// Display name for whatever the daemon reports, including a voice that isn't
    /// in the list above (someone set KOKORO_VOICE by hand).
    static func displayName(for id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}
