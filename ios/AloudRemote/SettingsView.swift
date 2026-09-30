// SettingsView.swift — listening, replies, and unpairing.

import SwiftUI


struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    private let languages: [(String, String)] = [
        ("", "Same as iPhone"), ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("nl-NL", "Nederlands"), ("de-DE", "Deutsch"), ("fr-FR", "Français"), ("es-ES", "Español"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    LabeledContent("Name", value: model.macName ?? "—")
                    LabeledContent("Server", value: model.serverText)
                }
                Section {
                    Toggle("Play new responses automatically", isOn: $model.autoPlay)
                    Toggle("Play responses from all sessions", isOn: $model.playAllSessions)
                    Toggle("Keep screen on while open", isOn: $model.keepScreenOn)
                } header: {
                    Text("Listening")
                } footer: {
                    Text("Responses play while this app is open. With all sessions off, only the selected session plays; others still appear.")
                }
                Section {
                    Picker("Language", selection: $model.replyLanguage) {
                        ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: model.replyLanguage) { _, _ in model.prepareTranscription() }
                    Toggle("Transcribe on iPhone", isOn: $model.transcribeOnPhone)
                        .onChange(of: model.transcribeOnPhone) { _, _ in model.prepareTranscription() }
                } header: {
                    Text("Replies")
                } footer: {
                    Text("On-device either way. On the iPhone you see the words while you speak (iOS 26 or later). The first time for a language, iOS downloads its speech model — a system download, not part of this app — and until it's there the Mac transcribes instead.")
                }
                Section {
                    Button("Unpair This iPhone", role: .destructive) { confirmUnpair = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Unpair from \(model.macName ?? "the Mac")?", isPresented: $confirmUnpair) {
                Button("Unpair", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
            } message: {
                Text("To stop it working from the Mac side too, remove the device in Aloud's menu.")
            }
        }
    }
}
