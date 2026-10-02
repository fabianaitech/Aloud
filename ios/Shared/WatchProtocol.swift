// WatchProtocol.swift — what the iPhone app and the watch app say to each other
// over WatchConnectivity. Compiled into both.
//
// The iPhone is the only one that talks to the Mac. It tells the watch what to
// show (WatchState, as application context: the latest always wins, and the
// watch gets it even if it was asleep), hands it audio (file transfers), and
// takes the watch's recordings and replies back to the Mac.

import Foundation

/// Everything the watch shows, sent whenever it changes.
struct WatchState: Codable, Equatable {
    var connected: Bool
    var mac: String?
    /// Accent name, so the watch wears the same colour as the phone.
    var accent: String
    var session: WatchSession?
    var sessions: [WatchSession]
    var response: WatchResponse?
    var reply: WatchReply?
    /// The selected session's conversation, oldest first: what the watch
    /// mostly shows.
    var log: [WatchLogItem] = []
    /// Each session's latest response (the session list previews it).
    var latest: [String: WatchResponse] = [:]

    static let empty = WatchState(connected: false, mac: nil, accent: "indigo", session: nil,
                                  sessions: [], response: nil, reply: nil)
}

struct WatchSession: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    var project: String
    /// idle | busy | permission
    var state: String
    var canReply: Bool
}

struct WatchResponse: Codable, Equatable {
    var id: String
    /// What was spoken: the watch shows text, not markdown.
    var text: String
    var ts: Double
    var duration: Double?
}

/// One message in the conversation: Claude's response, or your reply.
struct WatchLogItem: Codable, Equatable, Identifiable {
    var id: String
    /// claude | you
    var from: String
    var text: String
    var ts: Double
    /// Your replies: queued | sent | delivered | failed
    var status: String?
}

struct WatchReply: Codable, Equatable {
    var id: String
    var text: String
    /// queued | sent | delivered | failed
    var status: String
    var detail: String?
}

enum WatchMessage {
    static let state = "state"          // application context: JSON-encoded WatchState
    static let cmd = "cmd"

    // watch → phone
    static let select = "select"        // session
    static let transcribe = "transcribe" // file transfer; draft, locale
    static let audioPart = "audioPart"  // message; draft, locale, index, count, data — the same, live
    static let send = "send"            // draft, text → ok, status, error
    static let refresh = "refresh"      // ask for the state again

    // phone → watch
    static let clip = "clip"            // file transfer; event
    static let clipPart = "clipPart"    // message; event, index, count, data — the same clip, live
    static let transcript = "transcript" // draft, text | error

    // keys
    static let session = "session"
    static let draft = "draft"
    static let text = "text"
    static let locale = "locale"
    static let event = "event"
    static let error = "error"
    static let ok = "ok"
    static let status = "status"
    static let index = "index"
    static let count = "count"
    static let data = "data"
    /// Bytes per live clip message: WatchConnectivity messages must stay small.
    static let chunk = 48_000
}

extension WatchState {
    func encoded() -> Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data?) -> WatchState? {
        data.flatMap { try? JSONDecoder().decode(WatchState.self, from: $0) }
    }
}
