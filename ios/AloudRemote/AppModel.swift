// AppModel.swift — connection, sessions, responses and replies.
//
// One long poll against the Mac's event log: "everything after N". The last N
// is saved, so a reconnect — after a Tailscale drop, a Mac sleep or a relaunch —
// picks up exactly where it left off. Each clip is played at most once; each
// reply carries an id made when you start composing it, so sending again after
// a failure can't deliver it twice.

import AVFoundation
import Foundation
import SwiftUI
import UIKit

struct ResponseItem: Identifiable, Equatable {
    let id: String
    let sessionID: String?
    let project: String?
    let text: String
    let ts: Double
    var clip: String?
    var clipError: String?
    var duration: Double?
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
        didSet { defaults.set(selectedSessionID, forKey: "selectedSession") }
    }
    @Published var responses: [ResponseItem] = []
    @Published var replies: [ReplyItem] = []
    @Published var compose: Compose = .idle
    @Published var transcript = ""
    @Published var micDenied = false

    @AppStorage("autoPlay") var autoPlay = true
    @AppStorage("playAllSessions") var playAllSessions = false
    @AppStorage("replyLanguage") var replyLanguage = ""       // "" = the phone's language
    @AppStorage("keepScreenOn") var keepScreenOn = false {
        didSet { UIApplication.shared.isIdleTimerDisabled = keepScreenOn }
    }

    let player = Player()
    let recorder = Recorder()

    private let defaults = UserDefaults.standard
    private var api: API?
    private var pollTask: Task<Void, Never>?
    private var draftID: String?                // reply id, fixed per draft
    private var clipCache: [String: Data] = [:]
    private var played: [String]                // event ids already auto-played

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
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
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
                    let live = e.seq > historyUpTo || now - (e.ts ?? 0) < 180
                    apply(e, live: live)
                    seq = max(seq, e.seq)
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
                                          text: e.text ?? "", ts: e.ts ?? Date().timeIntervalSince1970))
            if responses.count > 100 { responses.removeFirst(responses.count - 100) }
            if selectedSessionID == nil { selectedSessionID = e.session_id }
        case "clip":
            guard let id = e.event_id, let i = responses.firstIndex(where: { $0.id == id }) else { return }
            responses[i].clip = e.clip
            responses[i].clipError = e.error
            responses[i].duration = e.duration
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

    var selectedSession: RemoteSession? {
        sessions.first { $0.session_id == selectedSessionID }
    }

    var latestResponse: ResponseItem? {
        responses.last { $0.sessionID == selectedSessionID }
    }

    func playClip(of r: ResponseItem, queue: Bool = false) async {
        guard let name = r.clip, let api else { return }
        do {
            let data: Data
            if let cached = clipCache[name] {
                data = cached
            } else {
                data = try await api.clip(name)
                clipCache[name] = data
            }
            if queue { player.enqueue(id: r.id, data: data) } else { player.play(id: r.id, data: data) }
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
        player.pause()                 // the microphone must not hear Claude
        do {
            try recorder.start()
            if draftID == nil { draftID = UUID().uuidString }
            compose = .recording
        } catch {
            compose = .failed(error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard let url = recorder.stop() else { compose = .idle; return }
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
            let locale = replyLanguage.isEmpty ? Locale.current.identifier : replyLanguage
            let text = try await api?.transcribe(audio: audio, locale: locale) ?? ""
            transcript = transcript.isEmpty ? text : transcript + " " + text
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
            draftID = nil
            compose = .idle
        } catch {
            compose = .failed("Not sent: \(error.localizedDescription)")
        }
    }

    var repliesForSelected: [ReplyItem] {
        replies.filter { $0.sessionID == selectedSessionID }.suffix(5).reversed()
    }

    #if DEBUG
    /// Simulator testing without tapping: pair from launch arguments, and
    /// optionally send one typed reply once connected. Debug builds only.
    ///   -rvServer http://127.0.0.1:8898 -rvCode 123456 -rvReply "text"
    func runDebugLaunchArguments() {
        let d = UserDefaults.standard
        Task {
            if let server = d.string(forKey: "rvServer"), let code = d.string(forKey: "rvCode") {
                try? await pair(server: server, code: code)
            }
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
}
