// WatchBridge.swift — the iPhone's half of the Apple Watch app.
//
// The watch never talks to the Mac. This sends it what to show (as application
// context: only the latest matters, and it arrives even if the watch was
// asleep) and the latest clip (a file transfer), and does the watch's errands:
// switch session, transcribe a recording, send a reply.
//
// It works while this app runs. iOS suspends it in the background, and then
// nothing new reaches the watch until it's opened again — the same rule as
// listening on the phone. A message from the watch can wake it briefly,
// which is enough to send a reply.

import Foundation
import WatchConnectivity

@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    private weak var model: AppModel?
    private var lastState: WatchState?
    private var sentClip: String?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start(model: AppModel) {
        self.model = model
        guard let s = session else { return }
        s.delegate = self
        s.activate()
    }

    /// Not `isWatchAppInstalled`: a watch app installed straight from Xcode
    /// can be reported as missing while it runs fine. Try, and let it fail.
    private var ready: Bool {
        guard let s = session else { return false }
        return s.activationState == .activated && s.isPaired
    }

    /// The current state, for answering the watch directly.
    private func stateReply(_ base: [String: Any]) -> [String: Any] {
        var out = base
        if let data = model?.watchState().encoded() { out[WatchMessage.state] = data }
        return out
    }

    /// Send the watch what it shows, if that changed — and the newest clip.
    func publish(force: Bool = false) {
        guard ready, let model, let s = session else { return }
        let state = model.watchState()
        if force || state != lastState, let data = state.encoded() {
            do {
                try s.updateApplicationContext([WatchMessage.state: data])
                lastState = state
            } catch {
                playbackLog.error("watch context: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let r = model.latestResponse, r.clip != nil, sentClip != r.id {
            sentClip = r.id
            Task { await sendClip(r) }
        }
    }

    private func sendClip(_ r: ResponseItem) async {
        guard let model, let s = session,
              let data = try? await model.clipData(for: r) else { return }
        // Watch app open: send it live, in pieces — immediate, where a file
        // transfer is queued and can take a while. Otherwise, queue the file.
        if s.isReachable, await sendLive(data, id: r.id, via: s) { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(r.id).m4a")
        do {
            try data.write(to: url)
            // Older clips still on their way are superseded by this one.
            for t in s.outstandingFileTransfers where t.file.metadata?[WatchMessage.cmd] as? String == WatchMessage.clip {
                t.cancel()
            }
            s.transferFile(url, metadata: [WatchMessage.cmd: WatchMessage.clip, WatchMessage.event: r.id])
        } catch {
            playbackLog.error("watch clip: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendLive(_ data: Data, id: String, via s: WCSession) async -> Bool {
        let n = (data.count + WatchMessage.chunk - 1) / WatchMessage.chunk
        for i in 0..<n {
            let part = data.subdata(in: (i * WatchMessage.chunk)..<min(data.count, (i + 1) * WatchMessage.chunk))
            let ok: Bool = await withCheckedContinuation { cont in
                s.sendMessage([WatchMessage.cmd: WatchMessage.clipPart, WatchMessage.event: id,
                               WatchMessage.index: i, WatchMessage.count: n, WatchMessage.data: part],
                              replyHandler: { _ in cont.resume(returning: true) },
                              errorHandler: { _ in cont.resume(returning: false) })
            }
            if !ok { return false }
        }
        return true
    }

    /// Tell the watch, now if it's listening, otherwise queued for when it is.
    private func tell(_ message: [String: Any]) {
        guard let s = session else { return }
        if s.isReachable {
            s.sendMessage(message, replyHandler: nil) { _ in s.transferUserInfo(message) }
        } else {
            s.transferUserInfo(message)
        }
    }

    // MARK: errands from the watch

    private func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let model else { return [WatchMessage.ok: false, WatchMessage.error: "Aloud isn't ready"] }
        switch message[WatchMessage.cmd] as? String {
        case WatchMessage.select:
            if let id = message[WatchMessage.session] as? String { model.selectedSessionID = id }
            publish(force: true)
            return stateReply([WatchMessage.ok: true])
        case WatchMessage.send:
            guard let draft = message[WatchMessage.draft] as? String,
                  let text = message[WatchMessage.text] as? String else {
                return [WatchMessage.ok: false, WatchMessage.error: "nothing to send"]
            }
            do {
                let r = try await model.sendFromWatch(draft: draft, text: text)
                publish()
                return [WatchMessage.ok: true, WatchMessage.status: r.status]
            } catch {
                return [WatchMessage.ok: false, WatchMessage.error: error.localizedDescription]
            }
        case WatchMessage.audioPart:
            receivedAudioPiece(message)
            return [WatchMessage.ok: true]
        case WatchMessage.refresh:
            publish(force: true)
            return stateReply([WatchMessage.ok: true])
        default:
            return [WatchMessage.ok: false, WatchMessage.error: "unknown request"]
        }
    }

    /// A recording sent live, piece by piece; transcribed once complete.
    private var audioPieces: [String: [Int: Data]] = [:]

    private func receivedAudioPiece(_ message: [String: Any]) {
        guard let draft = message[WatchMessage.draft] as? String,
              let i = message[WatchMessage.index] as? Int,
              let n = message[WatchMessage.count] as? Int,
              let data = message[WatchMessage.data] as? Data else { return }
        audioPieces[draft, default: [:]][i] = data
        guard let got = audioPieces[draft], got.count == n else { return }
        audioPieces[draft] = nil
        let whole = (0..<n).reduce(into: Data()) { $0.append(got[$1] ?? Data()) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-reply-\(UUID().uuidString).m4a")
        guard (try? whole.write(to: url)) != nil else { return }
        let locale = message[WatchMessage.locale] as? String
        Task { await transcribe(url, draft: draft, locale: locale) }
    }

    private func transcribe(_ url: URL, draft: String, locale: String?) async {
        guard let model else { return }
        do {
            let text = try await model.transcribeForWatch(url, locale: locale)
            tell([WatchMessage.cmd: WatchMessage.transcript, WatchMessage.draft: draft, WatchMessage.text: text])
        } catch {
            tell([WatchMessage.cmd: WatchMessage.transcript, WatchMessage.draft: draft,
                  WatchMessage.error: error.localizedDescription])
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.publish(force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()          // switched to another watch
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.sentClip = nil
            self.publish(force: true)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish(force: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in replyHandler(await self.handle(message)) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in _ = await self.handle(message) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?[WatchMessage.cmd] as? String == WatchMessage.transcribe,
              let draft = file.metadata?[WatchMessage.draft] as? String else { return }
        // The system deletes the file when this returns: keep a copy.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("watch-reply-\(UUID().uuidString).m4a")
        guard (try? FileManager.default.copyItem(at: file.fileURL, to: copy)) != nil else { return }
        let locale = file.metadata?[WatchMessage.locale] as? String
        Task { @MainActor in await self.transcribe(copy, draft: draft, locale: locale) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
