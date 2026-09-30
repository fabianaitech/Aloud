// Views.swift — pairing, the main screen, and settings.

import SwiftUI
import UIKit

@main
struct AloudRemoteApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.player)
                .environmentObject(model.recorder)
                .onAppear {
                    model.start()
                    #if DEBUG
                    model.runDebugLaunchArguments()
                    #endif
                }
        }
        .onChange(of: phase) { _, p in
            // Foreground is the supported mode: listen while open, and pick up
            // exactly where we left off when opened again.
            if p == .active { model.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.connection == .notPaired {
            PairView()
        } else {
            MainView()
        }
    }
}

// MARK: - Pairing

struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var server = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-mac.tailnet.ts.net:8443", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Pairing code", text: $code)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text("On the Mac, open Aloud's menu → Remote Voice → Pair iPhone… for the address and a one-time code. The Tailscale app must be connected on this iPhone.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task {
                            busy = true
                            error = nil
                            do { try await model.pair(server: server, code: code) } catch {
                                self.error = error.localizedDescription
                            }
                            busy = false
                        }
                    } label: {
                        HStack {
                            Text("Pair")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || server.isEmpty || code.filter(\.isNumber).count != 6)
                }
            }
            .navigationTitle("Aloud Remote")
            .onAppear { if server.isEmpty { server = model.serverText } }
        }
    }
}

// MARK: - Main screen

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectionBanner()
                    SessionPicker()
                    ResponseCard()
                    ReplyComposer()
                    RecentReplies()
                }
                .padding()
            }
            .navigationTitle(model.macName ?? "Aloud Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { try? await model.refreshSessions() }
        }
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let (text, icon, color): (String, String, Color) = {
            switch model.connection {
            case .connected: return ("Listening", "dot.radiowaves.left.and.right", .green)
            case .connecting: return ("Connecting…", "arrow.triangle.2.circlepath", .orange)
            case .offline(let why): return (why, "wifi.exclamationmark", .orange)
            case .remoteOff: return ("Remote Voice is off on the Mac. Turn it on in Aloud's menu.", "speaker.slash", .gray)
            case .unauthorized: return ("This iPhone was removed on the Mac. Pair again in Settings.", "lock", .red)
            case .notPaired: return ("Not paired", "lock", .red)
            }
        }()
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SessionPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            if model.sessions.isEmpty {
                Text("No Claude Code sessions running")
            }
            ForEach(model.sessions) { s in
                Button {
                    model.selectedSessionID = s.session_id
                } label: {
                    Label("\(s.label) · \(s.surface)",
                          systemImage: s.session_id == model.selectedSessionID ? "checkmark" : "terminal")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.selectedSession?.project ?? "Choose a session")
                        .font(.headline)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                    Spacer()
                    if let s = model.selectedSession { StateBadge(state: s.state) }
                }
                if let s = model.selectedSession {
                    Text(s.title?.isEmpty == false ? s.title! : s.cwd ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(s.surface) · \(String(s.session_id.prefix(8)))\(s.can_reply ? "" : " · listen only")")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if model.selectedSessionID != nil {
                    Text("This session has ended.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct StateBadge: View {
    let state: String
    var body: some View {
        let (t, c): (String, Color) = {
            switch state {
            case "busy": return ("Working", .orange)
            case "permission": return ("Needs permission", .red)
            case "idle": return ("Ready", .green)
            default: return (state.capitalized, .gray)
            }
        }()
        Text(t).font(.caption.bold()).foregroundStyle(c)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(c.opacity(0.15), in: Capsule())
    }
}

struct ResponseCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest response").font(.caption).foregroundStyle(.secondary)
            if let r = model.latestResponse {
                ScrollView {
                    Text(r.text).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                HStack(spacing: 20) {
                    if player.currentID == r.id {
                        Button {
                            player.isPlaying ? player.pause() : player.resume()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 40))
                        }
                        ProgressView(value: player.progress)
                    } else {
                        Button {
                            Task { await model.playClip(of: r) }
                        } label: {
                            Image(systemName: "play.circle.fill").font(.system(size: 40))
                        }
                        .disabled(r.clip == nil)
                        Spacer()
                    }
                    Button {
                        Task { await model.playClip(of: r) }
                    } label: {
                        Image(systemName: "gobackward").font(.title2)
                    }
                    .disabled(r.clip == nil)
                    .accessibilityLabel("Replay")
                }
                if r.clip == nil {
                    Text(r.clipError.map { "Audio unavailable: \($0)" } ?? "Preparing audio…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let d = r.duration {
                    Text(String(format: "%.0f s", d)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Claude's next response in this session will appear and play here.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ReplyComposer: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your reply").font(.caption).foregroundStyle(.secondary)
            if model.selectedSession == nil {
                Text("Choose a running session to reply to.").foregroundStyle(.secondary)
            } else if model.selectedSession?.can_reply == false {
                Text("This session can't receive replies (it has no inbox socket). You can still listen.")
                    .foregroundStyle(.secondary)
            } else {
                content
            }
            if model.micDenied {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Microphone access is off for Aloud Remote.", systemImage: "mic.slash")
                        .foregroundStyle(.red)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var content: some View {
        switch model.compose {
        case .idle:
            HStack {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Record", systemImage: "mic.circle.fill").font(.title2.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.connection != .connected)
                Button("Type") { model.typeReply() }
                    .buttonStyle(.bordered)
            }
        case .recording:
            VStack(spacing: 10) {
                HStack {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(String(format: "Recording  %0.0f s", recorder.elapsed)).monospacedDigit()
                    Spacer()
                    ProgressView(value: Double(recorder.level)).frame(width: 90)
                }
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelReply() }
                        .buttonStyle(.bordered)
                    Button {
                        Task { await model.stopRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .transcribing:
            HStack { ProgressView(); Text("Transcribing on your Mac…") }
        case .editing, .sending:
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $model.transcript)
                    .frame(minHeight: 90, maxHeight: 200)
                    .padding(6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(model.compose == .sending)
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelReply() }
                        .buttonStyle(.bordered)
                    Button {
                        Task { await model.startRecording() }
                    } label: { Image(systemName: "mic") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Record more")
                    Button {
                        Task { await model.send() }
                    } label: {
                        HStack {
                            if model.compose == .sending { ProgressView() }
                            Text("Send to \(model.selectedSession?.project ?? "session")")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.compose == .sending)
                }
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 10) {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                HStack {
                    Button("Discard", role: .destructive) { model.cancelReply() }
                        .buttonStyle(.bordered)
                    if model.recorder.url != nil {
                        Button("Transcribe Again") { Task { await model.retryTranscription() } }
                            .buttonStyle(.bordered)
                    }
                    if !model.transcript.isEmpty {
                        Button("Edit") { model.compose = .editing }.buttonStyle(.bordered)
                        Button("Send Again") { Task { await model.send() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

struct RecentReplies: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.repliesForSelected
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sent replies").font(.caption).foregroundStyle(.secondary)
                ForEach(items) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ReplyStatus(status: r.status)
                            Spacer()
                            Text(r.created, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(r.text).font(.subheadline).lineLimit(3)
                        if let e = r.error {
                            Text(e).font(.caption).foregroundStyle(.red)
                        } else if let d = r.detail, r.status != "delivered" {
                            Text(d).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

struct ReplyStatus: View {
    let status: String
    var body: some View {
        let (t, i, c): (String, String, Color) = {
            switch status {
            case "queued": return ("Queued", "clock", .orange)
            case "sent": return ("Sent", "paperplane", .blue)
            case "delivered": return ("Delivered", "checkmark.circle.fill", .green)
            case "failed": return ("Failed", "xmark.octagon.fill", .red)
            default: return (status, "questionmark", .gray)
            }
        }()
        Label(t, systemImage: i).font(.caption.bold()).foregroundStyle(c)
    }
}

// MARK: - Settings

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
                } header: {
                    Text("Replies")
                } footer: {
                    Text("Transcribed on your Mac, on-device.")
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
