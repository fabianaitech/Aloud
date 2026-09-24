// SpeechController.swift — the bridge to the local Kokoro TTS daemon
// (~/.aloud). Lifted from Claude Island, which keeps only the
// "speak Claude's responses" toggle now that speech has its own app.
//
// Every action shells out to control.sh rather than hitting the HTTP API
// directly, so there is ONE control surface shared with the /speak command, the
// Stop hook and the macOS Services — control.sh is what keeps the flag files
// (speak.enabled, speak.speed, speak.voice) from drifting out of sync with the
// daemon. Live state is polled from GET /state. Loopback only; nothing leaves
// the machine.

import Foundation

/// Live speech state as reported by the daemon's /state endpoint.
struct SpeechStatus: Decodable, Equatable {
    var enabled: Bool
    var paused: Bool
    var speaking: Bool
    var queued: Int
    var speed: Double
    /// Added alongside the /voice endpoint; optional so a stale daemon still decodes.
    var voice: String?
    /// "apple" | "kokoro". Optional so a daemon predating engine support decodes.
    var engine: String?
    /// The remembered voice per engine, so switching engines can tick the right
    /// one without waiting for a round trip.
    var voices: [String: String]?
    /// False once the idle reaper has dropped the model to give the memory back.
    /// The engine is still running and will speak — the next request reloads first.
    /// Optional so a daemon predating the idle timeout still decodes.
    var loaded: Bool?
    /// True only while the synth worker is actually coming up (~6s). Distinct from
    /// `loaded == false`, which is the resting state after an idle unload.
    var loading: Bool?
}

final class SpeechController {
    /// Fired on the main queue when the polled state (or reachability) changes.
    /// A nil status means the daemon is not reachable (not started yet).
    var onState: (SpeechStatus?) -> Void = { _ in }

    private let port: Int
    private let dir: String
    private let controlScript: String
    private var timer: Timer?
    private var last: SpeechStatus?
    private var lastUp: Bool?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init() {
        let p = UserDefaults.standard.integer(forKey: "AloudPort")
        port = (p > 0 && p < 65_536) ? p : 8877
        dir = (("~/.aloud") as NSString).expandingTildeInPath
        controlScript = (dir as NSString).appendingPathComponent("control.sh")
    }

    /// False when the daemon was never installed — the menu says so rather than
    /// offering controls that could only fail.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: controlScript)
    }

    func start() {
        refresh()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Poll every 0.25s until `seconds` from now. While an engine is starting or
    /// a model is loading, the 1.5s tick alone would leave the spinner up for as
    /// much as 1.5s after the engine was already ready — both engines start in
    /// well under that, so the tick was most of what you waited for.
    func pollFast(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if let current = fastUntil, current > until { return }
        fastUntil = until
        guard !fastTicking else { return }
        fastTicking = true
        fastTick()
    }

    private var fastUntil: Date?
    private var fastTicking = false

    private func fastTick() {
        guard let until = fastUntil, until > Date() else {
            fastTicking = false
            fastUntil = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
            self?.fastTick()
        }
    }

    /// Run control.sh with arguments: on/off/pause/resume/stop/skip/faster/slower/
    /// reset/start/restart/clipboard, "voice <name>", or a numeric speed like "1.25".
    /// Fire-and-forget, then refresh.
    func control(_ args: String...) {
        guard isInstalled else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [controlScript] + args
        // A Service-style bare PATH would hide Homebrew's jq from the scripts.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        do {
            try proc.run()
        } catch {
            NSLog("[Aloud] control '\(args.joined(separator: " "))' failed: \(error.localizedDescription)")
            return
        }
        // Reflect the change quickly rather than waiting for the next poll tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
    }

    /// Voices per engine, from the daemon — Apple's are whatever the OS has
    /// installed, Kokoro's are fixed by the pinned model. Both arrive from one
    /// endpoint so there is a single source of truth, rather than a second copy
    /// of the list living here. Cached; neither changes often.
    private(set) var appleVoices: [EngineVoice] = []
    private(set) var kokoroVoices: [EngineVoice] = []

    func refreshVoices() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/voices") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            let decoded = try? JSONDecoder().decode([String: [EngineVoice]].self, from: data)
            DispatchQueue.main.async {
                if let a = decoded?["apple"], !a.isEmpty { self.appleVoices = a }
                if let k = decoded?["kokoro"], !k.isEmpty { self.kokoroVoices = k }
            }
        }.resume()
    }

    private func refresh() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/state") else { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            let status = data.flatMap { try? JSONDecoder().decode(SpeechStatus.self, from: $0) }
            let up = status != nil
            DispatchQueue.main.async {
                // Keep polling quickly for as long as a model is coming up.
                if status?.loading == true { self.pollFast(for: 1) }
                guard up != self.lastUp || status != self.last else { return }
                self.lastUp = up
                self.last = status
                self.onState(status)
            }
        }.resume()
    }
}
