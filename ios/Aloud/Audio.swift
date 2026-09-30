// Audio.swift — playing Claude's clips and recording your reply.
//
// Playback uses the .playback category: full-quality audio to the speaker or
// headphones (A2DP). Recording switches to .playAndRecord with Bluetooth HFP,
// so AirPods' microphone works too, and back again afterwards — HFP would make
// every clip sound like a phone call. Recording always pauses playback first:
// the microphone must not hear Claude's voice.

import AVFoundation
import Foundation
import os

/// Why a clip did or didn't play: Console.app → device → subsystem
/// com.fabianaitech.Aloud, category playback.
let playbackLog = Logger(subsystem: "com.fabianaitech.Aloud", category: "playback")

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentID: String?
    /// Which sentence part is playing, or nil for a whole-response clip.
    @Published private(set) var currentPart: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    /// Seconds into what is playing now, and its length.
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var queue: [(id: String, part: Int?, data: Data)] = []
    private var timer: Timer?

    override init() {
        super.init()
        // A call, Siri or another app takes the audio: AVAudioPlayer stops
        // without telling its delegate, so listen for it here — otherwise the
        // player looks busy forever and every later clip waits behind it.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    self.isPlaying = false
                    self.stopTimer()
                } else if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume),
                          self.player != nil {
                    self.resume()
                }
            }
        }
    }

    private func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [])
        try? s.setActive(true)
    }

    /// Play after whatever is audible now. A new response doesn't wait behind
    /// one that is paused or was cut off: it starts at once, and the stale one's
    /// remaining parts go (it can still be replayed).
    func enqueue(id: String, part: Int? = nil, data: Data) {
        // The full clip of this response is already playing (a seek or a
        // replay): its sentence parts have nothing left to add.
        if part != nil, currentID == id, currentPart == nil { return }
        let audible = player?.isPlaying == true
        if currentID == nil || (!audible && currentID != id) {
            queue.removeAll { $0.id != id }
            play(id: id, part: part, data: data)
        } else {
            queue.append((id, part, data))
        }
    }

    /// Play now, replacing anything playing (replay).
    func play(id: String, part: Int? = nil, data: Data, from start: TimeInterval = 0) {
        // The whole clip replaces any of its sentences still waiting.
        if part == nil { queue.removeAll { $0.id == id } }
        playbackLog.info("play \(id, privacy: .public) part \(part ?? -1)")
        stopTimer()
        activate()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            if start > 0 { p.currentTime = min(start, max(0, p.duration - 0.05)) }
            p.play()
            player = p
            currentID = id
            currentPart = part
            position = p.currentTime
            duration = p.duration
            isPlaying = true
            startTimer()
        } catch {
            currentID = nil
            isPlaying = false
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func resume() {
        guard let player else { return }
        activate()
        player.play()
        isPlaying = true
        startTimer()
    }

    /// Jump within what is playing now.
    func seek(to t: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(t, player.duration - 0.05))
        position = player.currentTime
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        currentID = nil
        currentPart = nil
        isPlaying = false
        progress = 0
        stopTimer()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.next() }
    }

    private func next() {
        player = nil
        progress = 0
        position = 0
        if queue.isEmpty {
            currentID = nil
            currentPart = nil
            isPlaying = false
            stopTimer()
        } else {
            let n = queue.removeFirst()
            play(id: n.id, part: n.part, data: n.data)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
                self.position = p.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var timer: Timer?
    private var started: Date?
    private(set) var url: URL?

    static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Record to a file, and pass every buffer to `live` too — the phone's
    /// transcriber. The file is always written: it's what the Mac transcribes
    /// when the phone can't.
    func start(feed live: LiveFeed?) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .spokenAudio,
                          options: [.defaultToSpeaker, .allowBluetoothHFP])
        try s.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.couldNotStart }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-\(UUID().uuidString).m4a")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 48_000,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? file.write(from: buffer)
            live?.send(buffer)
            let level = Recorder.level(of: buffer)
            DispatchQueue.main.async { self?.level = level }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.file = file
        self.url = url
        isRecording = true
        started = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.started else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    /// Stop and hand back the file.
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        file = nil                  // closes it
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        return url
    }

    func cancel() {
        _ = stop()
        discard()
    }

    func discard() {
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }

    /// 0...1 from the buffer's RMS, for the level meter.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 50))
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone couldn't start recording." }
    }
}
