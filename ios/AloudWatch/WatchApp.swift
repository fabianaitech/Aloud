// WatchApp.swift — Aloud on the wrist: hear Claude's latest response, and
// answer it by voice.

import SwiftUI

@main
struct AloudWatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRoot()
                .environmentObject(model)
                .onAppear { model.start() }
        }
        .onChange(of: phase) { _, p in
            model.active = (p == .active)
            if p == .active { model.refresh() }
        }
    }
}

extension Accent {
    var top: Color { Color(red: rgb.top.0, green: rgb.top.1, blue: rgb.top.2) }
    var bottom: Color { Color(red: rgb.bottom.0, green: rgb.bottom.1, blue: rgb.bottom.2) }
    var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom) }
}

struct WatchRoot: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.compose {
                case .idle, .sent:
                    HomeView()
                case .recording:
                    RecordingView()
                case .transcribing:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Transcribing…").font(.footnote).foregroundStyle(.secondary)
                    }
                case .review(let text):
                    ReviewView(text: text)
                case .sending:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Sending…").font(.footnote).foregroundStyle(.secondary)
                    }
                case .failed(let why):
                    FailedView(message: why)
                }
            }
            .animation(.snappy, value: model.compose)
        }
        .tint(model.accent.top)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.phoneReachable || !model.state.connected {
                    Label(model.phoneReachable ? "iPhone isn't connected to the Mac"
                                               : "Open Aloud on your iPhone",
                          systemImage: "iphone.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                NavigationLink {
                    SessionList()
                } label: {
                    SessionRowLabel(session: model.state.session)
                }
                .buttonStyle(.plain)

                if let r = model.state.response {
                    Text(r.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    controls
                } else {
                    Text("Claude's next response plays here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if case .sent = model.compose {
                    Label("Sent", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                } else if let p = model.state.reply, p.status != "delivered" {
                    Label(p.status == "failed" ? "Reply not delivered" : "Reply \(p.status)",
                          systemImage: p.status == "failed" ? "exclamationmark.circle" : "clock")
                        .font(.caption2)
                        .foregroundStyle(p.status == "failed" ? .red : .secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Aloud")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                }
                .controlSize(.large)
                .background(model.accent.gradient, in: Circle())
                .foregroundStyle(.white)
                .disabled(model.state.session?.canReply != true || !model.phoneReachable)
                .accessibilityLabel("Reply")
                Spacer()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isCurrentPlaying && model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(model.accent.gradient, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasClip)
            .opacity(model.hasClip ? 1 : 0.4)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            if model.isCurrentPlaying {
                ProgressView(value: model.progress).tint(model.accent.top)
            } else {
                Text(model.hasClip ? clip : "Audio on its way…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Button { model.replay() } label: {
                Image(systemName: "gobackward")
            }
            .buttonStyle(.plain)
            .disabled(!model.hasClip)
            .accessibilityLabel("Play from the start")
        }
    }

    private var clip: String {
        guard let d = model.state.response?.duration else { return "" }
        let s = Int(d.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

struct SessionRowLabel: View {
    @EnvironmentObject var model: WatchModel
    let session: WatchSession?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(session?.state))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.name ?? "Choose a session")
                    .font(.headline)
                    .lineLimit(1)
                if let s = session, s.name != s.project {
                    Text(s.project).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(model.accent.top.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

func color(_ state: String?) -> Color {
    switch state {
    case "busy": return .orange
    case "permission": return .red
    case "idle": return .green
    default: return .gray
    }
}

struct SessionList: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.state.sessions.isEmpty {
                Text("No Claude Code sessions on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.state.sessions) { s in
                Button {
                    model.select(s.id)
                    dismiss()
                } label: {
                    HStack {
                        Circle().fill(color(s.state)).frame(width: 7, height: 7)
                        VStack(alignment: .leading) {
                            Text(s.name).lineLimit(2)
                            if s.name != s.project {
                                Text(s.project).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if s.id == model.state.session?.id {
                            Image(systemName: "checkmark").foregroundStyle(model.accent.top)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sessions")
    }
}

// MARK: - Replying

struct RecordingView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 9, height: 9)
                    .phaseAnimator([0.3, 1.0]) { c, p in c.opacity(p) } animation: { _ in .easeInOut(duration: 0.7) }
                Text(String(format: "%d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                    .font(.title3.monospacedDigit())
            }
            Text("Listening…").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button(role: .cancel) { model.cancelRecording() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Cancel")
                Button { model.stopRecording() } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 50, height: 50)
                        .background(Color.red, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop and transcribe")
            }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject var model: WatchModel
    let text: String
    @State private var edited: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reply to \(model.state.session?.name ?? "Claude")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // Tap to correct it, by dictation or Scribble.
                TextField("Your reply", text: $edited, axis: .vertical)
                    .lineLimit(2...8)
                Button {
                    Task { await model.send(edited) }
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                }
                .tint(model.accent.top)
                .disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(role: .destructive) { model.discard() } label: {
                    Text("Discard").frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { edited = text }
    }
}

struct FailedView: View {
    @EnvironmentObject var model: WatchModel
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(message).font(.footnote).multilineTextAlignment(.center)
                if model.draftReviewText != nil {
                    Button("Try Again") { model.retrySend() }.tint(model.accent.top)
                }
                Button("Discard", role: .destructive) {
                    model.draftReviewText = nil
                    model.discard()
                }
            }
        }
    }
}
