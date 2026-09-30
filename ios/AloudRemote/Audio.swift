// Audio.swift — playing Claude's clips and recording your reply.
//
// Playback uses the .playback category: full-quality audio to the speaker or
// headphones (A2DP). Recording switches to .playAndRecord with Bluetooth HFP,
// so AirPods' microphone works too, and back again afterwards — HFP would make
// every clip sound like a phone call. Recording always pauses playback first:
// the microphone must not hear Claude's voice.

import AVFoundation
import Foundation

@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var queue: [(id: String, data: Data)] = []
    private var timer: Timer?

    private func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [])
        try? s.setActive(true)
    }

    /// Play after whatever is playing now.
    func enqueue(id: String, data: Data) {
        if currentID == nil { play(id: id, data: data) } else { queue.append((id, data)) }
    }

    /// Play now, replacing anything playing (replay).
    func play(id: String, data: Data) {
        stopTimer()
        activate()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            currentID = id
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

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
        currentID = nil
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
        if queue.isEmpty {
            currentID = nil
            isPlaying = false
            stopTimer()
        } else {
            let n = queue.removeFirst()
            play(id: n.id, data: n.data)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
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

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var url: URL?

    static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .spokenAudio,
                          options: [.defaultToSpeaker, .allowBluetoothHFP])
        try s.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reply-\(UUID().uuidString).m4a")
        // 16 kHz mono AAC: all speech recognition needs, and small over the tailnet.
        let r = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.couldNotStart }
        recorder = r
        self.url = url
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.elapsed = r.currentTime
                self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
            }
        }
    }

    /// Stop and hand back the file.
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
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

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone couldn't start recording." }
    }
}
