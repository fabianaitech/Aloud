// Voices.swift — the engines Aloud can drive, and the shape of a voice.
//
// Neither voice list lives here. Apple's is whatever the user has downloaded in
// System Settings; Kokoro's is fixed by the pinned model. Both come from the
// daemon's GET /voices, so there is one source of truth rather than a copy here
// that quietly goes stale.

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

/// One voice, as the daemon reports it. The two engines fill in different
/// fields — Apple has a quality tier, Kokoro a language and a gender, and
/// Kokoro's non-default languages name a package they need — so the optionals
/// also say which engine a voice came from, without needing a second type.
struct EngineVoice: Decodable {
    let name: String
    let lang: String
    /// Apple: "premium" | "enhanced" | "default".
    let quality: String?
    /// Kokoro: the readable language, e.g. "British English".
    let language: String?
    /// Kokoro: "female" | "male".
    let gender: String?
    /// Kokoro: a package this language needs that setup.sh does not install.
    let extra: String?

    /// Apple voices show under their own name. Kokoro's are `af_heart`, where the
    /// prefix is language and gender — both of which the menu already groups by,
    /// so repeating them in every row is noise.
    var displayName: String {
        guard gender != nil, let sep = name.firstIndex(of: "_") else { return name }
        return String(name[name.index(after: sep)...]).capitalized
    }
}
