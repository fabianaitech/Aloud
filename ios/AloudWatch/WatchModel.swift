// WatchModel.swift — the watch app's state: what the iPhone says to show, the
// latest clip, and the reply being spoken.
//
// Everything goes through the iPhone (WatchConnectivity): it shows us the
// session and the latest response, sends the clip, transcribes our recordings
// on the Mac and delivers our replies. The watch itself talks to no one else.

import AVFoundation
import Foundation
import SwiftUI
import WatchConnectivity
import os

let watchLog = Logger(subsystem: "com.fabianaitech.Aloud.watch", category: "watch")

enum WatchCompose: Equatable {
    case idle
    case recording
    case transcribing
    case review(String)
    case sending
    case sent
    case failed(String)
}

@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate, AVAudioPlayerDelegate {
    @Published private(set) var state: WatchState
    @Published private(set) var phoneReachable = false
    @Published var compose: WatchCompose = .idle
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @AppStorage("autoPlay") var autoPlay = true

    /// Set by the app when it comes to the front or goes away: clips only play
    /// by themselves while you're looking.
    var active = false

    private var player: AVAudioPlayer?
    private var playingID: String?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var draftID: String?
    private var timer: Timer?
    private var transcribeTimeout: Task<Void, Never>?
    private let clipsDir: URL

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    override init() {
        clipsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        // Show what we last knew until the iPhone says otherwise.
        state = WatchState.decode(UserDefaults.standard.data(forKey: "lastState")) ?? .empty
        super.init()
    }

    func start() {
        guard let s = session else { return }
        s.delegate = self
        s.activate()
    }

    var accent: Accent { Accent(rawValue: state.accent) ?? .indigo }

    var hasClip: Bool {
        guard let id = state.response?.id else { return false }
        return FileManager.default.fileExists(atPath: clipURL(id).path)
    }

    var isCurrentPlaying: Bool { playingID != nil && playingID == state.response?.id }

    private func clipURL(_ id: String) -> URL { clipsDir.appendingPathComponent("\(id).m4a") }

    private func apply(_ new: WatchState) {
        state = new
        UserDefaults.standard.set(new.encoded(), forKey: "lastState")
        UserDefaults.standard.set(new.accent, forKey: "accent")
    }

    // MARK: asking the iPhone

    private func ask(_ message: [String: Any]) async -> [String: Any]? {
        guard let s = session, s.activationState == .activated, s.isReachable else { return nil }
        return await withCheckedContinuation { cont in
            s.sendMessage(message, replyHandler: { cont.resume(returning: $0) },
                          errorHandler: { _ in cont.resume(returning: nil) })
        }
    }

    /// Ask the iPhone for the current state; it answers with it directly, so
    /// this works even when application context doesn't arrive.
    func refresh() {
        Task { applyReply(await ask([WatchMessage.cmd: WatchMessage.refresh])) }
    }

    func select(_ id: String) {
        Task { applyReply(await ask([WatchMessage.cmd: WatchMessage.select, WatchMessage.session: id])) }
    }

    private func applyReply(_ reply: [String: Any]?) {
        if let s = WatchState.decode(reply?[WatchMessage.state] as? Data) { apply(s) }
    }

    private var poll: Timer?

    /// While the app is in front: a light refresh every 10 seconds, so the
    /// watch never shows stale state for long, whatever delivery does.
    func setActive(_ on: Bool) {
        active = on
        poll?.invalidate()
        poll = nil
        guard on else { return }
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: playback

    func togglePlay() {
        if isCurrentPlaying, let player {
            if player.isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }
            return
        }
        playLatest()
    }

    func replay() { playLatest() }

    private func playLatest() {
        guard let id = state.response?.id, compose != .recording else { return }
        let url = clipURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingID = id
            isPlaying = true
            startTimer()
            UserDefaults.standard.set(id, forKey: "played")
        } catch {
            watchLog.error("play: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
        progress = 0
        stopTimer()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 0
            self.playingID = nil
            self.stopTimer()
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let p = self.player, p.duration > 0 { self.progress = p.currentTime / p.duration }
                if let r = self.recorder, r.isRecording { self.elapsed = r.currentTime }
            }
        }
    }

    private func stopTimer() {
        if recorder?.isRecording == true { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: replying

    func startRecording() async {
        guard state.session?.canReply == true else { return }
        if AVAudioApplication.shared.recordPermission != .granted {
            guard await AVAudioApplication.requestRecordPermission() else {
                compose = .failed("Allow the microphone for Aloud in the Watch app on your iPhone.")
                return
            }
        }
        stopPlayback()                  // the microphone must not hear Claude
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reply-\(UUID().uuidString).m4a")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let r = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            guard r.record() else { throw NSError(domain: "Aloud", code: 1) }
            recorder = r
            recordingURL = url
            draftID = UUID().uuidString
            elapsed = 0
            compose = .recording
            startTimer()
        } catch {
            compose = .failed("The microphone couldn't start.")
        }
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        stopTimer()
        guard let url = recordingURL, let draft = draftID, let s = session else { compose = .idle; return }
        compose = .transcribing
        // The iPhone hands it to the Mac to transcribe: live, in pieces, when
        // it's reachable; otherwise as a queued file transfer.
        Task {
            if s.isReachable, let data = try? Data(contentsOf: url), await sendLive(data, draft: draft, via: s) {
                return
            }
            s.transferFile(url, metadata: [WatchMessage.cmd: WatchMessage.transcribe,
                                           WatchMessage.draft: draft,
                                           WatchMessage.locale: Locale.current.identifier])
        }
        transcribeTimeout?.cancel()
        transcribeTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.compose == .transcribing else { return }
            self.compose = .failed(self.phoneReachable
                                   ? "Transcription took too long."
                                   : "Open Aloud on your iPhone, then try again.")
        }
    }

    private func sendLive(_ data: Data, draft: String, via s: WCSession) async -> Bool {
        let n = (data.count + WatchMessage.chunk - 1) / WatchMessage.chunk
        for i in 0..<n {
            let part = data.subdata(in: (i * WatchMessage.chunk)..<min(data.count, (i + 1) * WatchMessage.chunk))
            let ok: Bool = await withCheckedContinuation { cont in
                s.sendMessage([WatchMessage.cmd: WatchMessage.audioPart, WatchMessage.draft: draft,
                               WatchMessage.locale: Locale.current.identifier,
                               WatchMessage.index: i, WatchMessage.count: n, WatchMessage.data: part],
                              replyHandler: { _ in cont.resume(returning: true) },
                              errorHandler: { _ in cont.resume(returning: false) })
            }
            if !ok { return false }
        }
        return true
    }

    func cancelRecording() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        stopTimer()
        discard()
    }

    func discard() {
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        draftID = nil
        transcribeTimeout?.cancel()
        compose = .idle
    }

    func send(_ text: String) async {
        guard let draft = draftID else { return }
        compose = .sending
        let reply = await ask([WatchMessage.cmd: WatchMessage.send,
                               WatchMessage.draft: draft, WatchMessage.text: text])
        guard let reply else {
            compose = .failed("Your iPhone isn't reachable. Open Aloud on it and send again.")
            draftReviewText = text
            return
        }
        if reply[WatchMessage.ok] as? Bool == true {
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
            draftID = nil
            compose = .sent
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if compose == .sent { compose = .idle }
        } else {
            draftReviewText = text
            compose = .failed(reply[WatchMessage.error] as? String ?? "Not sent.")
        }
    }

    /// The transcript to go back to after a failed send (same draft id: a
    /// second try can't deliver it twice).
    @Published var draftReviewText: String?

    func retrySend() {
        if let t = draftReviewText { compose = .review(t) }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            if let s = WatchState.decode(context[WatchMessage.state] as? Data) { self.apply(s) }
            self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            if reachable { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let s = WatchState.decode(context[WatchMessage.state] as? Data) else { return }
        Task { @MainActor in self.apply(s) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        watchLog.info("file arrived: \(file.metadata?.description ?? "no metadata", privacy: .public)")
        guard file.metadata?[WatchMessage.cmd] as? String == WatchMessage.clip,
              let id = file.metadata?[WatchMessage.event] as? String else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("clips", isDirectory: true)
        let dest = dir.appendingPathComponent("\(id).m4a")
        try? FileManager.default.removeItem(at: dest)
        // The system deletes the file when this returns: move it now.
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: dest)
        } catch {
            watchLog.error("clip store failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Keep only the newest few.
        if let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = all.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in sorted.dropFirst(3) { try? FileManager.default.removeItem(at: old) }
        }
        Task { @MainActor in self.clipArrived(id) }
    }

    private func clipArrived(_ id: String) {
        objectWillChange.send()         // hasClip changed
        let alreadyPlayed = UserDefaults.standard.string(forKey: "played") == id
        guard active, autoPlay, !alreadyPlayed, id == state.response?.id,
              compose == .idle || compose == .sent else { return }
        playLatest()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.received(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            self.received(message)
            replyHandler([WatchMessage.ok: true])
        }
    }

    /// Pieces of a clip sent live, until all have arrived.
    private var pieces: [String: [Int: Data]] = [:]

    private func receivedPiece(_ message: [String: Any]) {
        guard let id = message[WatchMessage.event] as? String,
              let i = message[WatchMessage.index] as? Int,
              let n = message[WatchMessage.count] as? Int,
              let data = message[WatchMessage.data] as? Data else { return }
        pieces[id, default: [:]][i] = data
        guard let got = pieces[id], got.count == n else { return }
        pieces[id] = nil
        let whole = (0..<n).reduce(into: Data()) { $0.append(got[$1] ?? Data()) }
        do {
            try whole.write(to: clipURL(id), options: .atomic)
            watchLog.info("clip \(id, privacy: .public) arrived live, \(whole.count) bytes")
            clipArrived(id)
        } catch {
            watchLog.error("clip store failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.received(userInfo) }
    }

    private func received(_ message: [String: Any]) {
        if message[WatchMessage.cmd] as? String == WatchMessage.clipPart {
            receivedPiece(message)
            return
        }
        guard message[WatchMessage.cmd] as? String == WatchMessage.transcript,
              message[WatchMessage.draft] as? String == draftID, compose == .transcribing else { return }
        transcribeTimeout?.cancel()
        if let text = message[WatchMessage.text] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compose = .review(text)
        } else {
            compose = .failed(message[WatchMessage.error] as? String ?? "Nothing was heard.")
        }
    }

    #if DEBUG
    /// Simulator testing without tapping or a microphone. Debug builds only.
    ///   -rvAudioFile <path to an audio file on the Mac>  — "record" this file
    ///   -rvAutoSend YES                                   — send what comes back
    func runDebugLaunchArguments() {
        let d = UserDefaults.standard
        watchLog.info("debug args: audio=\(d.string(forKey: "rvAudioFile") ?? "none", privacy: .public)")
        guard let path = d.string(forKey: "rvAudioFile") else { return }
        Task {
            for _ in 0..<40 where !phoneReachable || state.session == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("debug-\(UUID().uuidString).m4a")
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
            } catch {
                watchLog.error("debug audio copy failed: \(error.localizedDescription, privacy: .public)")
            }
            watchLog.info("debug: reachable=\(self.phoneReachable) session=\(self.state.session?.id ?? "none", privacy: .public)")
            recordingURL = url
            draftID = UUID().uuidString
            compose = .recording
            stopRecording()
            guard d.bool(forKey: "rvAutoSend") else { return }
            for _ in 0..<120 {
                if case .review(let text) = compose {
                    await send(text)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
    #endif
}
