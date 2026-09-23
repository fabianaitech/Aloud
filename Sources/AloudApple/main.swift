// aloud-apple — the Apple engine's synthesis helper.
//
// Two things `say` can't do, which is why this exists:
//
//   * Siri voices. macOS hides them from `say -v '?'` and from the public
//     AVSpeechSynthesisVoice.speechVoices(), but they synthesize fine once you
//     hold one. The list comes from a private AVFoundation class method; if a
//     future macOS drops it we fall back to the public list and simply show no
//     Siri voices, rather than failing.
//   * Staying warm. Every `say` pays ~0.8s to reach the speech service before a
//     word is synthesized, and the daemon spawns one per sentence-sized chunk.
//     A persistent synthesizer pays that once: on macOS 27 an Enhanced voice
//     goes from ~0.85s to ~0.07s per chunk.
//
// Usage:
//   aloud-apple voices     print every usable voice as JSON, then exit
//   aloud-apple serve      the worker; same line protocol as synth.py:
//
//   <- {"id": 1, "text": "...", "speed": 1.0, "voice": "<id or name>", "out": "/tmp/x.wav"}
//   -> {"id": 1, "ok": true}                     wav written to `out`
//   -> {"id": 1, "ok": false, "error": "..."}
//   <- {"id": 2, "check_voice": "<id or name>"}  -> {"id": 2, "ok": true|false, "voice": "<id>"}
//   <- {"id": 3, "voices": true}                 -> {"id": 3, "ok": true, "voices": [...]}
//   -> {"ready": true}                           once, at startup

import AVFoundation
import Foundation

// MARK: - Voices

/// Every voice the synthesizer will accept, Siri's included when the OS lets us
/// see them. Deduplicated by identifier; only installed voices.
func allVoices() -> [AVSpeechSynthesisVoice] {
    let sel = NSSelectorFromString("_speechVoicesIncludingSiri")
    var voices: [AVSpeechSynthesisVoice] = []
    if AVSpeechSynthesisVoice.responds(to: sel),
       let list = AVSpeechSynthesisVoice.perform(sel)?.takeUnretainedValue() as? [AVSpeechSynthesisVoice] {
        voices = list
    } else {
        voices = AVSpeechSynthesisVoice.speechVoices()
    }
    var seen = Set<String>()
    return voices.filter { v in
        guard seen.insert(v.identifier).inserted else { return false }
        return flag(v, "isInstalled") ?? true
    }
}

/// A private Bool property, read only when the object actually has it: KVC on a
/// missing key raises an Objective-C exception, which Swift cannot catch.
func flag(_ v: AVSpeechSynthesisVoice, _ key: String) -> Bool? {
    guard v.responds(to: NSSelectorFromString(key)) else { return nil }
    return (v.value(forKey: key) as? NSNumber)?.boolValue
}

func isSiri(_ v: AVSpeechSynthesisVoice) -> Bool {
    flag(v, "isSiriVoice") ?? v.identifier.hasPrefix("com.apple.siri.")
}

/// Siri voices are named "Voice 2" — meaningless outside Siri's own settings
/// page, which is the only place Apple shows them — so say whose voice it is.
func displayName(_ v: AVSpeechSynthesisVoice) -> String {
    isSiri(v) && !v.name.hasPrefix("Siri") ? "Siri \(v.name)" : v.name
}

func describe(_ v: AVSpeechSynthesisVoice) -> [String: Any] {
    let quality: String
    switch v.quality {
    case .premium:  quality = "premium"
    case .enhanced: quality = "enhanced"
    default:        quality = "default"
    }
    var d: [String: Any] = [
        "id": v.identifier,
        "name": displayName(v),
        "lang": v.language,
        "quality": quality,
        "siri": isSiri(v),
    ]
    if flag(v, "isNoveltyVoice") == true { d["novelty"] = true }
    return d
}

/// Resolve what the daemon stored — an identifier, or a name from the `say`
/// days such as "Zoe (Enhanced)" — to a voice.
func resolve(_ key: String, in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
    voices.first { $0.identifier == key }
        ?? voices.first { $0.name == key }
        ?? voices.first { displayName($0) == key }
}

// MARK: - Speed

/// Aloud's speed is a multiplier on duration; AVSpeechUtterance.rate is not
/// linear in it. Measured on macOS 27 (Zoe, Siri Voice 2 and Samantha agree
/// within a few percent) as the speed-up relative to the default rate of 0.5.
let rateTable: [(speed: Double, rate: Float)] = [
    (0.56, 0.00), (0.65, 0.10), (0.73, 0.20), (0.82, 0.30), (0.91, 0.40),
    (1.00, 0.50), (1.29, 0.55), (1.59, 0.60), (2.20, 0.70), (2.78, 0.80),
    (3.40, 0.90), (3.93, 1.00),
]

func rate(forSpeed speed: Double) -> Float {
    guard let first = rateTable.first, let last = rateTable.last else { return 0.5 }
    if speed <= first.speed { return first.rate }
    if speed >= last.speed { return last.rate }
    for (a, b) in zip(rateTable, rateTable.dropFirst()) where speed <= b.speed {
        let t = (speed - a.speed) / (b.speed - a.speed)
        return a.rate + Float(t) * (b.rate - a.rate)
    }
    return 0.5
}

// MARK: - Synthesis

struct SynthError: Error, CustomStringConvertible {
    let description: String
}

let synthesizer = AVSpeechSynthesizer()

/// Synthesize `text` into a 16-bit WAV at `out`. Buffers arrive through the run
/// loop, so spin it rather than block: a semaphore would deadlock if AVFoundation
/// delivers them on this thread.
func synthesize(_ text: String, voice: AVSpeechSynthesisVoice, speed: Double, out: String) throws {
    let u = AVSpeechUtterance(string: text)
    u.voice = voice
    u.rate = rate(forSpeed: speed)

    var file: AVAudioFile?
    var failure: Error?
    var done = false
    let url = URL(fileURLWithPath: out)

    synthesizer.write(u) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            done = true
            return
        }
        do {
            if file == nil {
                let f = pcm.format
                file = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: f.sampleRate,
                        AVNumberOfChannelsKey: f.channelCount,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ],
                    commonFormat: f.commonFormat,
                    interleaved: f.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            failure = error
        }
    }

    let deadline = Date().addingTimeInterval(120)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    file = nil  // closes it, flushing the header
    if let failure { throw failure }
    if !done { throw SynthError(description: "timed out") }
    if !FileManager.default.fileExists(atPath: out) {
        // Nothing speakable ("…", a lone emoji). Leave a sliver of silence so the
        // playback queue has a file to play, as it would with `say`.
        try writeSilence(to: url)
    }
}

func writeSilence(to url: URL) throws {
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1),
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1103) else { return }
    buf.frameLength = 1103
    let f = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22050,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ])
    try f.write(from: buf)
}

// MARK: - Protocol

func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func serve() {
    var voices = allVoices()
    /// Look a voice up, re-listing once on a miss: it may have been downloaded
    /// in System Settings since we last looked.
    func lookup(_ key: String) -> AVSpeechSynthesisVoice? {
        if let v = resolve(key, in: voices) { return v }
        voices = allVoices()
        return resolve(key, in: voices)
    }

    emit(["ready": true])
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        var reply: [String: Any] = ["id": req["id"] ?? NSNull()]

        if req["voices"] != nil {
            voices = allVoices()
            reply["ok"] = true
            reply["voices"] = voices.map(describe)
        } else if let key = req["check_voice"] as? String {
            if let v = lookup(key) {
                reply["ok"] = true
                reply["voice"] = v.identifier
            } else {
                reply["ok"] = false
                reply["error"] = "no such voice: \(key)"
            }
        } else if let text = req["text"] as? String, let out = req["out"] as? String {
            let key = req["voice"] as? String ?? ""
            let speed = (req["speed"] as? NSNumber)?.doubleValue ?? 1.0
            if let v = lookup(key) {
                do {
                    try synthesize(text, voice: v, speed: speed, out: out)
                    reply["ok"] = true
                } catch {
                    reply["ok"] = false
                    reply["error"] = "\(error)"
                }
            } else {
                reply["ok"] = false
                reply["error"] = "no such voice: \(key)"
            }
        } else {
            reply["ok"] = false
            reply["error"] = "unknown request"
        }
        emit(reply)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "voices":
    let data = try JSONSerialization.data(withJSONObject: allVoices().map(describe))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
case "serve", nil:
    serve()
default:
    FileHandle.standardError.write(Data("usage: aloud-apple [voices|serve]\n".utf8))
    exit(2)
}
