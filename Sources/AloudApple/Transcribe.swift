// Transcribe.swift — speech to text for Remote Voice replies, on this Mac.
//
// SpeechTranscriber (macOS 26+) runs on-device: the audio never leaves the
// machine and there is no account or key. Measured on macOS 27: a five-second
// reply transcribes in ~0.2s once the model is loaded.

import AVFoundation
import Foundation
import Speech

/// Transcribe an audio file and print {"ok": true, "text": "...", "locale": "..."}.
/// Exits non-zero with {"ok": false, "error": "..."} when it can't.
func transcribeCommand(path: String, localeID: String?) -> Never {
    let done = DispatchSemaphore(value: 0)
    var result: [String: Any] = ["ok": false, "error": "not run"]
    Task {
        do {
            result = try await transcribe(url: URL(fileURLWithPath: path),
                                          locale: Locale(identifier: localeID ?? "en-US"))
        } catch {
            result = ["ok": false, "error": "\(error)"]
        }
        done.signal()
    }
    done.wait()
    emit(result)
    exit(result["ok"] as? Bool == true ? 0 : 1)
}

func transcribe(url: URL, locale requested: Locale) async throws -> [String: Any] {
    guard #available(macOS 26, *) else {
        return ["ok": false, "error": "on-device transcription needs macOS 26 or later"]
    }
    // SpeechTranscriber is the better model but covers fewer languages (no
    // Dutch, on macOS 27); DictationTranscriber covers the rest.
    let module: any SpeechModule
    let locale: Locale
    let results: AsyncThrowingStream<String, Error>
    if let l = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
        let t = SpeechTranscriber(locale: l, preset: .transcription)
        module = t; locale = l
        results = strings(t.results.map { String($0.text.characters) })
    } else if let l = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
        let t = DictationTranscriber(locale: l, preset: .longDictation)
        module = t; locale = l
        results = strings(t.results.map { String($0.text.characters) })
    } else {
        return ["ok": false, "error": "no on-device transcription model for \(requested.identifier)"]
    }
    // The model for a language is an OS-managed download, fetched once.
    if await AssetInventory.status(forModules: [module]) != .installed,
       let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [module])
    let file = try AVAudioFile(forReading: url)
    async let text: String = results.reduce("") { $0 + $1 }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return ["ok": true,
            "text": try await text.trimmingCharacters(in: .whitespacesAndNewlines),
            "locale": locale.identifier]
}

/// Erase a module's result sequence to plain strings, so both transcribers can
/// feed the same code.
@available(macOS 26, *)
func strings<S: AsyncSequence & Sendable>(_ seq: S) -> AsyncThrowingStream<String, Error> where S.Element == String {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await s in seq { continuation.yield(s) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
