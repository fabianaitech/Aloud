// AppModel.swift — connection, sessions, responses and replies.
//
// One long poll against the Mac's event log: "everything after N". The last N
// is saved, so a reconnect — after a Tailscale drop, a Mac sleep or a relaunch —
// picks up exactly where it left off. Each clip is played at most once; each
// reply carries an id made when you start composing it, so sending again after
// a failure can't deliver it twice.

import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit

struct ResponseItem: Identifiable, Equatable {
    let id: String
    let sessionID: String?
    let project: String?
    let text: String
    let markdown: String?
    let ts: Double
    var clip: String?
    var clipError: String?
    var duration: Double?
    /// The spoken pieces, as they arrive: the text shown and highlighted.
    var segments: [Segment] = []
}

struct ReplyItem: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let text: String
    let created: Date
    var status: String          // queued | sent | delivered | failed
    var detail: String?
    var error: String?
}

enum TimelineItem: Identifiable {
    case response(ResponseItem)
    case reply(ReplyItem)

    var id: String {
        switch self {
        case .response(let r): return "r-" + r.id
        case .reply(let p): return "p-" + p.id
        }
    }

    var date: Date {
        switch self {
        case .response(let r): return Date(timeIntervalSince1970: r.ts)
        case .reply(let p): return p.created
        }
    }
}

enum Connection: Equatable {
    case notPaired
    case connecting
    case connected
    case offline(String)
    case remoteOff
    case unauthorized
}

enum Compose: Equatable {
    case idle
    case recording
    case transcribing
    case editing
    case sending
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connection: Connection = .notPaired
    @Published var macName: String?
    @Published var sessions: [RemoteSession] = []
    @Published var selectedSessionID: String? {
        didSet {
            defaults.set(selectedSessionID, forKey: "selectedSession")
            if let s = selectedSessionID { unread[s] = nil }
        }
    }
    /// New responses per session you aren't looking at.
    @Published var unread: [String: Int] = [:]
    @Published var responses: [ResponseItem] = []
    @Published var replies: [ReplyItem] = []
    @Published var compose: Compose = .idle
    @Published var transcript = ""
    @Published var micDenied = false
    /// What the phone has heard so far, while recording (on-device only).
    @Published var liveText = ""
    /// Where the current transcript came from: "iPhone" or "Mac".
    @Published var transcribedOn: String?

    @AppStorage("autoPlay") var autoPlay = true
    @AppStorage("playAllSessions") var playAllSessions = false
    @AppStorage("replyLanguage") var replyLanguage = ""       // "" = the phone's language
    @AppStorage("transcribeOnPhone") var transcribeOnPhone = true
    @AppStorage("keepScreenOn") var keepScreenOn = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
    }

    let player = Player()
    let recorder = Recorder()
    /// The Apple Watch app's link to all of this.
    let watch = WatchBridge()
    private var watchUpdates: AnyCancellable?

    private let defaults = UserDefaults.standard
    private var api: API?
    private var pollTask: Task<Void, Never>?
    private var draftID: String?                // reply id, fixed per draft
    private var clipCache: [String: Data] = [:]
    private var played: [String]                // event ids already auto-played
    private var streaming: Set<String> = []     // responses playing sentence by sentence
    private var partChain: Task<Void, Never>?   // keeps sentence clips in order
    private var liveFeed: LiveFeed?
    /// While the app was in the background (locked, another app): what arrives
    /// in that time plays on return, whatever its age.
    private var awaySince: Double?
    private var backSince: Date?
    private var transcriber: AnyObject?         // LiveTranscriber, iOS 26+

    private var seq: Int {
        get { defaults.integer(forKey: "seq") }
        set { defaults.set(newValue, forKey: "seq") }
    }
    private var logID: String? {
        get { defaults.string(forKey: "logID") }
        set { defaults.set(newValue, forKey: "logID") }
    }
    var serverText: String { defaults.string(forKey: "server") ?? "" }

    init() {
        played = defaults.stringArray(forKey: "played") ?? []
        selectedSessionID = defaults.string(forKey: "selectedSession")
        if let url = API.serverURL(from: serverText), let token = Keychain.get("token") {
            api = API(base: url, token: token)
            connection = .connecting
        }
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        watch.start(model: self)
        // Whatever changes here, the watch hears about — at most a few times a
        // second, and only when what it shows actually changed.
        watchUpdates = objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.watch.publish() }
    }

    // MARK: pairing

    func pair(server: String, code: String) async throws {
        guard let url = API.serverURL(from: server) else {
            throw APIError.server("That doesn't look like a server address.")
        }
        let digits = code.filter(\.isNumber)
        let client = API(base: url, token: nil)
        let res = try await client.pair(code: digits, name: UIDevice.current.name)
        Keychain.set(res.token, for: "token")
        defaults.set(url.absoluteString, forKey: "server")
        // A new pairing is a new relationship: start the log over.
        seq = 0
        logID = nil
        responses = []
        replies = []
        api = API(base: url, token: res.token)
        connection = .connecting
        start()
    }

    func unpair() {
        pollTask?.cancel()
        pollTask = nil
        player.stop()
        Keychain.set(nil, for: "token")
        api = nil
        connection = .notPaired
        sessions = []
        responses = []
        replies = []
        macName = nil
    }

    // MARK: the event loop

    func start() {
        guard api != nil, pollTask == nil else { return }
        pollTask = Task { await pollLoop() }
        prepareTranscription()
    }

    var replyLocale: Locale {
        replyLanguage.isEmpty ? Locale.current : Locale(identifier: replyLanguage)
    }

    /// Fetch the phone's speech model for the reply language ahead of time, so
    /// the first reply doesn't have to fall back to the Mac.
    func prepareTranscription() {
        guard transcribeOnPhone else { return }
        if #available(iOS 26, *) {
            let locale = replyLocale
            Task { await LiveTranscriber.prepare(locale) }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func enteredBackground() {
        if awaySince == nil { awaySince = Date().timeIntervalSince1970 }
    }

    func becameActive() {
        if awaySince != nil { backSince = Date() }
        start()
    }

    private func pollLoop() async {
        var backoff: UInt64 = 1
        var needStatus = true
        var historyUpTo = 0      // events up to here were there before we (re)connected
        while !Task.isCancelled, let api {
            do {
                if needStatus {
                    let st = try await api.status()
                    macName = st.mac
                    // First connection ever: show recent history, don't replay it.
                    if logID == nil { seq = max(0, st.seq - 80) }
                    historyUpTo = st.seq
                    connection = .connected
                    try await refreshSessions()
                    // Recent history, to show what was said — never to play it.
                    let recent = try await api.events(after: max(0, st.seq - 80), logID: nil, wait: 0)
                    for e in recent.events { apply(e, live: false) }
                    if selectedSessionID == nil,
                       let newest = responses.last(where: { r in sessions.contains { $0.session_id == r.sessionID } }) {
                        selectedSessionID = newest.sessionID
                    }
                    needStatus = false
                }
                let page = try await api.events(after: seq, logID: logID)
                connection = .connected
                backoff = 1
                // The Mac lost its log (or it's another Mac): start over.
                if page.reset { seq = 0; historyUpTo = page.seq }
                logID = page.log_id
                let now = Date().timeIntervalSince1970
                for e in page.events {
                    // News is what arrived since we connected, or anything from the
                    // last few minutes (a clip missed while Tailscale reconnected).
                    // Older history is shown, not played. Nothing plays twice either
                    // way: `played` remembers.
                    let away = awaySince.map { (e.ts ?? 0) >= $0 } ?? false
                    let live = e.seq > historyUpTo || now - (e.ts ?? 0) < 180 || away
                    apply(e, live: live)
                    seq = max(seq, e.seq)
                }
                // Close the away window once the catch-up has arrived — not on a
                // stale empty poll that started before the phone locked.
                if let back = backSince, !page.events.isEmpty || Date().timeIntervalSince(back) > 20 {
                    backSince = nil
                    awaySince = nil
                }
            } catch is CancellationError {
                return
            } catch APIError.unauthorized {
                connection = .unauthorized
                pollTask = nil
                return
            } catch APIError.remoteOff {
                connection = .remoteOff
                needStatus = true
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            } catch let e as APIError {
                if case .unreachable(let why) = e { connection = .offline(why) } else {
                    connection = .offline(e.localizedDescription)
                }
                needStatus = true
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 15)
            } catch {
                connection = .offline(error.localizedDescription)
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 15)
            }
        }
    }

    func refreshSessions() async throws {
        guard let api else { return }
        sessions = try await api.sessions()
        if let sel = selectedSessionID, !sessions.contains(where: { $0.session_id == sel }) {
            // Keep a vanished session selected only while its history is on screen.
            if !responses.contains(where: { $0.sessionID == sel }) { selectedSessionID = nil }
        }
        if selectedSessionID == nil { selectedSessionID = sessions.first?.session_id }
    }

    private func apply(_ e: RemoteEvent, live: Bool) {
        switch e.type {
        case "response":
            guard let id = e.id, !responses.contains(where: { $0.id == id }) else { return }
            responses.append(ResponseItem(id: id, sessionID: e.session_id, project: e.project,
                                          text: e.text ?? "", markdown: e.markdown,
                                          ts: e.ts ?? Date().timeIntervalSince1970))
            if responses.count > 200 { responses.removeFirst(responses.count - 200) }
            // With nothing chosen yet, follow what's being said now — not
            // whatever history happens to come first.
            if selectedSessionID == nil, live { selectedSessionID = e.session_id }
            if live, let sid = e.session_id, sid != selectedSessionID { unread[sid, default: 0] += 1 }
        case "clip_part":
            if e.index == 0, let id = e.event_id {
                playbackLog.info("""
                    part0 \(id, privacy: .public) live=\(live) auto=\(self.autoPlay) \
                    recording=\(self.compose == .recording) selected=\(e.session_id == self.selectedSessionID) \
                    played=\(self.played.contains(id))
                    """)
            }
            if let id = e.event_id, let i = responses.firstIndex(where: { $0.id == id }),
               let idx = e.index, idx == responses[i].segments.count, let text = e.text {
                responses[i].segments.append(Segment(text: text, duration: e.duration ?? 0))
            }
            // A sentence, ready before the rest: start playing now. The first
            // part claims the response, so neither a later "clip" nor a reconnect
            // plays it again.
            guard live, autoPlay, compose != .recording, let id = e.event_id, let name = e.clip,
                  playAllSessions || e.session_id == selectedSessionID else { return }
            if e.index == 0 {
                guard !played.contains(id) else { return }
                markPlayed(id)
                streaming.insert(id)
            }
            guard streaming.contains(id) else { return }
            enqueuePart(of: id, index: e.index ?? 0, name: name)
        case "clip":
            guard let id = e.event_id, let i = responses.firstIndex(where: { $0.id == id }) else { return }
            streaming.remove(id)
            responses[i].clip = e.clip
            responses[i].clipError = e.error
            responses[i].duration = e.duration
            if let segs = e.segments, !segs.isEmpty { responses[i].segments = segs }
            if live, autoPlay, e.clip != nil, !played.contains(id),
               playAllSessions || e.session_id == selectedSessionID {
                markPlayed(id)
                // Never talk over a reply being recorded.
                if compose != .recording { Task { await playClip(of: responses[i], queue: true) } }
            }
        case "reply":
            guard let id = e.reply_id else { return }
            if let i = replies.firstIndex(where: { $0.id == id }) {
                replies[i].status = e.status ?? replies[i].status
                replies[i].detail = e.detail
                replies[i].error = e.error
            } else if let text = e.text, let sid = e.session_id {
                // A reply sent before this launch (or from another phone): rebuild it.
                replies.append(ReplyItem(id: id, sessionID: sid, text: text,
                                         created: Date(timeIntervalSince1970: e.created ?? e.ts ?? 0),
                                         status: e.status ?? "queued", detail: e.detail, error: e.error))
                if replies.count > 200 { replies.removeFirst(replies.count - 200) }
            }
        case "session":
            Task { try? await refreshSessions() }
        default:
            break
        }
    }

    private func markPlayed(_ id: String) {
        played.append(id)
        if played.count > 300 { played.removeFirst(played.count - 300) }
        defaults.set(played, forKey: "played")
    }

    // MARK: playback

    /// Fetch and queue sentence clips strictly in arrival order, however the
    /// downloads race.
    private func enqueuePart(of eventID: String, index: Int, name: String) {
        let previous = partChain
        partChain = Task { [weak self] in
            await previous?.value
            guard let self, let api = self.api,
                  let data = try? await api.clip(name) else { return }
            if self.compose == .recording { return }      // never over your voice
            self.player.enqueue(id: eventID, part: index, data: data)
        }
    }

    var selectedSession: RemoteSession? {
        sessions.first { $0.session_id == selectedSessionID }
    }

    var latestResponse: ResponseItem? {
        responses.last { $0.sessionID == selectedSessionID }
    }

    func clipData(for r: ResponseItem) async throws -> Data {
        guard let name = r.clip, let api else { throw APIError.server("no audio yet") }
        if let cached = clipCache[name] { return cached }
        let data = try await api.clip(name)
        clipCache[name] = data
        return data
    }

    func playClip(of r: ResponseItem, queue: Bool = false, from start: TimeInterval = 0) async {
        guard r.clip != nil else { return }
        do {
            let data = try await clipData(for: r)
            if queue { player.enqueue(id: r.id, data: data) } else { player.play(id: r.id, data: data, from: start) }
        } catch {
            if let i = responses.firstIndex(where: { $0.id == r.id }) {
                responses[i].clipError = error.localizedDescription
            }
        }
    }

    // MARK: replying

    func startRecording() async {
        guard selectedSession?.can_reply == true else { return }
        switch Recorder.permission {
        case .denied:
            micDenied = true
            return
        case .undetermined:
            guard await Recorder.requestPermission() else {
                micDenied = true
                return
            }
        default:
            break
        }
        micDenied = false
        // The microphone must not hear Claude. Stop rather than pause: what was
        // playing can be replayed, and its remaining sentences mustn't start
        // up again while you edit your reply.
        player.stop()
        streaming.removeAll()
        let feed = LiveFeed()
        do {
            try recorder.start(feed: transcribeOnPhone ? feed : nil)
            if draftID == nil { draftID = UUID().uuidString }
            liveText = ""
            compose = .recording
        } catch {
            compose = .failed(error.localizedDescription)
            return
        }
        // The transcriber starts while you already talk; the feed holds the
        // first words until it's ready.
        guard transcribeOnPhone else { return }
        liveFeed = feed
        if #available(iOS 26, *) {
            let t = await LiveTranscriber.start(locale: replyLocale) { [weak self] text in
                self?.liveText = text
            }
            if let t, compose == .recording, liveFeed === feed {
                transcriber = t
                feed.attach { t.feed($0) }
            } else {
                feed.close()               // not on this phone yet: the Mac will do it
                if let t { await t.cancel() }
            }
        } else {
            feed.close()
        }
    }

    func stopRecording() async {
        guard let url = recorder.stop() else { compose = .idle; return }
        liveFeed?.close()
        liveFeed = nil
        if #available(iOS 26, *), let t = transcriber as? LiveTranscriber {
            transcriber = nil
            compose = .transcribing
            if let text = await t.finish(), !text.isEmpty {
                transcript = transcript.isEmpty ? text : transcript + " " + text
                transcribedOn = "iPhone"
                recorder.discard()
                compose = .editing
                return
            }
            // Nothing came out of it: let the Mac have a go at the recording.
        }
        await transcribe(url)
    }

    func retryTranscription() async {
        guard let url = recorder.url else { compose = .editing; return }
        await transcribe(url)
    }

    private func transcribe(_ url: URL) async {
        compose = .transcribing
        do {
            let audio = try Data(contentsOf: url)
            let text = try await api?.transcribe(audio: audio, locale: replyLocale.identifier) ?? ""
            transcript = transcript.isEmpty ? text : transcript + " " + text
            transcribedOn = "Mac"
            recorder.discard()
            compose = .editing
        } catch {
            compose = .failed("Couldn't transcribe: \(error.localizedDescription)")
        }
    }

    func typeReply() {
        if draftID == nil { draftID = UUID().uuidString }
        compose = .editing
    }

    func cancelReply() {
        if recorder.isRecording { recorder.cancel() } else { recorder.discard() }
        liveFeed?.close()
        liveFeed = nil
        if #available(iOS 26, *), let t = transcriber as? LiveTranscriber {
            Task { await t.cancel() }
        }
        transcriber = nil
        liveText = ""
        transcribedOn = nil
        transcript = ""
        draftID = nil
        compose = .idle
    }

    /// Send the draft. Sending again after a failure reuses the draft's id, so
    /// if the first attempt did reach the Mac this is recognised as the same reply.
    func send() async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sid = selectedSessionID, !text.isEmpty, let api else { return }
        let id = draftID ?? UUID().uuidString
        draftID = id
        compose = .sending
        do {
            let r = try await api.reply(id: id, sessionID: sid, text: text,
                                        inReplyTo: latestResponse?.id)
            if let i = replies.firstIndex(where: { $0.id == id }) {
                replies[i].status = r.status
            } else {
                replies.append(ReplyItem(id: id, sessionID: sid, text: text, created: Date(),
                                         status: r.status, detail: r.detail, error: r.error))
            }
            transcript = ""
            transcribedOn = nil
            draftID = nil
            compose = .idle
        } catch {
            compose = .failed("Not sent: \(error.localizedDescription)")
        }
    }

    /// The selected session's conversation, oldest first.
    var timeline: [TimelineItem] {
        let rs = responses.filter { $0.sessionID == selectedSessionID }.map(TimelineItem.response)
        let ps = replies.filter { $0.sessionID == selectedSessionID }.map(TimelineItem.reply)
        return (rs + ps).sorted { $0.date < $1.date }.suffix(40)
    }

    func lastResponse(in sessionID: String) -> ResponseItem? {
        responses.last { $0.sessionID == sessionID }
    }

    #if DEBUG
    /// Simulator testing without tapping: pair from launch arguments, and
    /// optionally send one typed reply once connected. Debug builds only.
    ///   -rvServer http://127.0.0.1:8898 -rvCode 123456 -rvSelect <session id> -rvReply "text"
    func runDebugLaunchArguments() {
        let d = UserDefaults.standard
        Task {
            if let server = d.string(forKey: "rvServer"), let code = d.string(forKey: "rvCode") {
                try? await pair(server: server, code: code)
            }
            if let sid = d.string(forKey: "rvSelect") { selectedSessionID = sid }
            if let text = d.string(forKey: "rvReply") {
                for _ in 0..<40 where connection != .connected || selectedSession == nil {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                typeReply()
                transcript = text
                await send()
            }
        }
    }
    #endif

    // MARK: the watch

    /// What the watch shows: the selected session, its latest response, and
    /// the last reply to it.
    func watchState() -> WatchState {
        let ws = sessions.map {
            WatchSession(id: $0.session_id, name: $0.displayName, project: $0.project,
                         state: $0.state, canReply: $0.can_reply)
        }
        let r = latestResponse
        let p = replies.last { $0.sessionID == selectedSessionID }
        return WatchState(
            connected: connection == .connected,
            mac: macName,
            accent: Accent.current.rawValue,
            session: ws.first { $0.id == selectedSessionID },
            sessions: ws,
            response: r.map { WatchResponse(id: $0.id, text: $0.text, ts: $0.ts, duration: $0.duration) },
            reply: p.map { WatchReply(id: $0.id, text: $0.text, status: $0.status, detail: $0.error ?? $0.detail) },
            log: timeline.suffix(12).map { item -> WatchLogItem in
                switch item {
                case .response(let r):
                    return WatchLogItem(id: r.id, from: "claude", text: String(r.text.prefix(1500)), ts: r.ts)
                case .reply(let p):
                    return WatchLogItem(id: p.id, from: "you", text: String(p.text.prefix(800)),
                                        ts: p.created.timeIntervalSince1970, status: p.status)
                }
            },
            latest: Dictionary(uniqueKeysWithValues: sessions.compactMap { s in
                responses.last { $0.sessionID == s.session_id }.map {
                    (s.session_id, WatchResponse(id: $0.id, text: String($0.text.prefix(1500)), ts: $0.ts,
                                                 duration: $0.duration))
                }
            }))
    }

    /// A reply spoken on the watch. Its draft id comes from the watch, so a
    /// retry from there is recognised as the same reply.
    func sendFromWatch(draft: String, text: String) async throws -> ReplyRecord {
        guard let sid = selectedSessionID, let api else { throw APIError.server("No session chosen") }
        let r = try await api.reply(id: draft, sessionID: sid, text: text, inReplyTo: latestResponse?.id)
        if !replies.contains(where: { $0.id == draft }) {
            replies.append(ReplyItem(id: draft, sessionID: sid, text: text, created: Date(),
                                     status: r.status, detail: r.detail, error: r.error))
        }
        return r
    }

    /// A recording from the watch, transcribed on the Mac.
    func transcribeForWatch(_ url: URL, locale: String?) async throws -> String {
        guard let api else { throw APIError.server("Not paired with a Mac") }
        let audio = try Data(contentsOf: url)
        return try await api.transcribe(audio: audio, locale: locale ?? replyLocale.identifier)
    }
}
