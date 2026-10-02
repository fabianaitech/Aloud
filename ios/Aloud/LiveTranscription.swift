// LiveTranscription.swift — speech to text on the iPhone, while you talk.
//
// Apple's SpeechAnalyzer (iOS 26+), on-device: SpeechTranscriber where it has
// the language, DictationTranscriber for the rest (Dutch, for one). The model
// is an OS-managed download, shared with the system and every other app, not
// part of the app. Until it's on the phone, replies are transcribed on the
// Mac instead, and the download starts in the background.

import AVFoundation
import Foundation
import Speech

/// Carries microphone buffers from the audio thread to whoever listens. The
/// transcriber takes a moment to start, so buffers wait here until it's ready:
/// the first words of a reply aren't lost to the model loading.
final class LiveFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var target: ((AVAudioPCMBuffer) -> Void)?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var closed = false

    func send(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        if let target {
            target(buffer)
        } else if let copy = buffer.copy() as? AVAudioPCMBuffer,
                  pendingFrames < AVAudioFramePosition(buffer.format.sampleRate * 15) {
            pending.append(copy)
            pendingFrames += AVAudioFramePosition(copy.frameLength)
        }
    }

    func attach(_ t: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        for b in pending { t(b) }
        pending.removeAll()
        target = t
    }

    func close() {
        lock.lock()
        closed = true
        target = nil
        pending.removeAll()
        lock.unlock()
    }
}

@available(iOS 26, *)
final class LiveTranscriber: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private let results: Task<String, Error>

    /// The module for a language, if the phone has one at all.
    private static func module(for locale: Locale, volatile: Bool) async -> (any SpeechModule)? {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return SpeechTranscriber(locale: l, transcriptionOptions: [],
                                     reportingOptions: volatile ? [.volatileResults] : [],
                                     attributeOptions: [])
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return DictationTranscriber(locale: l, contentHints: [], transcriptionOptions: [],
                                        reportingOptions: volatile ? [.volatileResults] : [],
                                        attributeOptions: [])
        }
        return nil
    }

    /// Start fetching a language's model if the phone doesn't have it yet, so
    /// the next reply can be transcribed here. Returns whether it's ready now.
    @discardableResult
    static func prepare(_ locale: Locale) async -> Bool {
        guard let m = await module(for: locale, volatile: false) else { return false }
        if await AssetInventory.status(forModules: [m]) == .installed { return true }
        Task.detached {
            if let req = try? await AssetInventory.assetInstallationRequest(supporting: [m]) {
                try? await req.downloadAndInstall()
            }
        }
        return false
    }

    /// A whole recording (from the watch), on this iPhone. Nil when the phone
    /// can't — no model for the language yet — or heard nothing.
    static func transcribeFile(_ url: URL, locale: Locale) async -> String? {
        guard let m = await module(for: locale, volatile: false),
              await AssetInventory.status(forModules: [m]) == .installed else {
            await prepare(locale)
            return nil
        }
        do {
            let analyzer = SpeechAnalyzer(modules: [m])
            let file = try AVAudioFile(forReading: url)
            let results: Task<String, Error>
            if let t = m as? SpeechTranscriber {
                results = Task { try await t.results.reduce("") { $0 + String($1.text.characters) } }
            } else if let d = m as? DictationTranscriber {
                results = Task { try await d.results.reduce("") { $0 + String($1.text.characters) } }
            } else {
                return nil
            }
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            playbackLog.error("phone transcription: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A running transcriber, or nil when this language can't be done on the
    /// phone right now — the caller then uses the Mac.
    static func start(locale: Locale, onText: @escaping @MainActor (String) -> Void) async -> LiveTranscriber? {
        guard let m = await module(for: locale, volatile: true),
              await AssetInventory.status(forModules: [m]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m])
        else {
            await prepare(locale)
            return nil
        }
        let analyzer = SpeechAnalyzer(modules: [m])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            return nil
        }
        let results: Task<String, Error>
        if let t = m as? SpeechTranscriber {
            results = Task { try await collect(t.results.map { (String($0.text.characters), $0.isFinal) }, onText) }
        } else if let d = m as? DictationTranscriber {
            results = Task { try await collect(d.results.map { (String($0.text.characters), $0.isFinal) }, onText) }
        } else {
            return nil
        }
        return LiveTranscriber(analyzer: analyzer, continuation: continuation, format: format, results: results)
    }

    /// Finalized text plus whatever is still being decided, reported as it changes.
    private static func collect<S: AsyncSequence>(_ seq: S, _ onText: @escaping @MainActor (String) -> Void)
        async throws -> String where S.Element == (String, Bool) {
        var final = ""
        for try await (text, isFinal) in seq {
            if isFinal {
                final += text
                let snapshot = final
                await onText(snapshot)
            } else {
                let snapshot = final + text
                await onText(snapshot)
            }
        }
        return final
    }

    private init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation,
                 format: AVAudioFormat, results: Task<String, Error>) {
        self.analyzer = analyzer
        self.continuation = continuation
        self.format = format
        self.results = results
    }

    /// From the audio thread: convert to what the model wants and pass it on.
    func feed(_ buffer: AVAudioPCMBuffer) {
        if buffer.format == format {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: out))
        }
    }

    /// The whole transcript, once everything spoken has been decided.
    func finish() async -> String? {
        continuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func cancel() async {
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }
}
