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
                Section {
                    AccentPicker()
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Changes the colour in the app and its icon on your Home Screen.")
                }
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

/// The accent colours as swatches; picking one also switches the app icon.
struct AccentPicker: View {
    @AppStorage("accent") private var accent = Accent.indigo.rawValue

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
            ForEach(Accent.allCases) { a in
                Button { choose(a) } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [swatch(a.colors.top), swatch(a.colors.bottom)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 46, height: 46)
                            .overlay { WaveformBars(height: 20) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(a.rawValue == accent ? Color.primary.opacity(0.85) : .clear,
                                                  lineWidth: 2.5)
                                    .padding(-4)
                            }
                        Text(a.title)
                            .font(.caption2.weight(a.rawValue == accent ? .semibold : .regular))
                            .foregroundStyle(a.rawValue == accent ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(a.title)
                .accessibilityAddTraits(a.rawValue == accent ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .sensoryFeedback(.selection, trigger: accent)
    }

    private func swatch(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    private func choose(_ a: Accent) {
        guard a.rawValue != accent else { return }
        accent = a.rawValue
        // iOS confirms an icon change with its own alert; that's not ours to skip.
        if UIApplication.shared.supportsAlternateIcons {
            UIApplication.shared.setAlternateIconName(a.iconName)
        }
    }
}
