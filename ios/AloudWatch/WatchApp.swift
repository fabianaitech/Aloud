// WatchApp.swift — Aloud on the wrist: hear Claude's latest response, and
// answer it by voice.
//
// Built for how a watch is used:
//   • the conversation first: the Crown scrolls it, newest at the bottom
//   • tap the session name to switch session
//   • Double Tap moves the flow on: Reply → Stop → Send
//   • play/pause and Reply sit in the bottom toolbar, inside the screen's
//     rounded corners, where a thumb expects them
//   • wrist down (always-on), only the session and the text remain, dimmed

import SwiftUI
import WatchKit

@main
struct AloudWatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRoot()
                .environmentObject(model)
                .onAppear {
                    model.start()
                    #if DEBUG
                    model.runDebugLaunchArguments()
                    #endif
                }
        }
        .onChange(of: phase, initial: true) { _, p in
            model.setActive(p == .active)
        }
    }
}

extension Accent {
    var top: Color { Color(red: rgb.top.0, green: rgb.top.1, blue: rgb.top.2) }
    var bottom: Color { Color(red: rgb.bottom.0, green: rgb.bottom.1, blue: rgb.bottom.2) }
    var gradient: LinearGradient { LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom) }
}

func stateColor(_ state: String?) -> Color {
    switch state {
    case "busy": return .orange
    case "permission": return .red
    case "idle": return .green
    default: return .gray
    }
}

func stateLabel(_ state: String?) -> String {
    switch state {
    case "busy": return "Working"
    case "permission": return "Needs permission"
    case "idle": return "Ready"
    default: return ""
    }
}

struct WatchRoot: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationStack {
            Group {
                switch model.compose {
                case .idle, .sent:
                    HomePager()
                case .recording:
                    RecordingView()
                case .transcribing:
                    TranscribingView()
                case .review(let text):
                    ReviewView(text: text)
                case .sending:
                    BusyView(title: "Sending…", icon: "arrow.up.circle")
                case .failed(let why):
                    FailedView(message: why)
                }
            }
            .animation(.snappy, value: model.compose)
            .overlay { if case .sent = model.compose { SentBadge() } }
        }
        .tint(model.accent.top)
        .sensoryFeedback(trigger: model.compose) { old, new in
            switch (old, new) {
            case (_, .recording): return .start
            case (.recording, _): return .stop
            case (_, .sent): return .success
            case (_, .failed): return .error
            default: return nil
            }
        }
    }
}

// MARK: - Home: sessions on the left, the conversation on the right

/// Three pages: Sessions ← Conversation → Now Playing. Picking a session
/// swipes back to its conversation. Now Playing is the system's own control:
/// there the Digital Crown sets the watch's volume, as in Music.
struct HomePager: View {
    @State private var page = 1

    var body: some View {
        TabView(selection: $page) {
            SessionList { withAnimation { page = 1 } }
                .tag(0)
            ChatView(showSessions: { withAnimation { page = 0 } },
                     showVolume: { withAnimation { page = 2 } })
                .tag(1)
            NowPlayingView()
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #if DEBUG
        .onAppear { if UserDefaults.standard.object(forKey: "rvPage") != nil {
                        page = UserDefaults.standard.integer(forKey: "rvPage") } }
        #endif
    }
}

// MARK: - The conversation

/// The selected session's conversation, newest at the bottom: what the watch
/// is mostly for. The Crown scrolls it; tap the session name to switch.
struct ChatView: View {
    @EnvironmentObject var model: WatchModel
    @Environment(\.isLuminanceReduced) private var dimmed

    /// Go to the sessions page (also reachable by swiping right).
    let showSessions: () -> Void
    /// Go to Now Playing, for the volume (also reachable by swiping left).
    let showVolume: () -> Void

    var body: some View {
        let log = model.state.log
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: showSessions) {
                        SessionHeader()
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows all sessions")

                    if !model.phoneReachable || !model.state.connected {
                        Label(model.phoneReachable ? "iPhone isn't connected to the Mac"
                                                   : "Open Aloud on your iPhone",
                              systemImage: "iphone.slash")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if log.isEmpty {
                        Text(model.state.session == nil
                             ? "Start Claude Code on your Mac."
                             : "Claude's next response plays here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }

                    ForEach(log) { item in
                        if item.from == "you" {
                            YouBubble(item: item)
                        } else {
                            ClaudeBubble(item: item, latest: item.id == model.state.response?.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
                .opacity(dimmed ? 0.6 : 1)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: log.last?.id) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .overlay(alignment: .top) {
            // While a message plays: one tap to the system volume control.
            if model.isPlaying {
                Button(action: showVolume) {
                    Label("Volume", systemImage: "speaker.wave.2.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(model.accent.top, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityHint("Opens Now Playing, where the Digital Crown sets the volume")
            }
        }
        .animation(.snappy, value: model.isPlaying)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                PlayButton()
                Spacer()
                ReplyButton()
            }
        }
    }
}

struct SessionHeader: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        let s = model.state.session
        HStack(spacing: 6) {
            Circle().fill(stateColor(s?.state)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(s?.name ?? "Choose a session")
                    .font(.headline)
                    .lineLimit(1)
                Text(s.map { [stateLabel($0.state), $0.name != $0.project ? $0.project : nil]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") } ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.state.sessions.count > 1 {
                Image(systemName: "chevron.left").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(model.accent.top.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ClaudeBubble: View {
    @EnvironmentObject var model: WatchModel
    let item: WatchLogItem
    let latest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The latest response is the one with audio: show it playing.
            if latest && model.isCurrentPlaying {
                ProgressView(value: model.progress).tint(model.accent.top)
            }
        }
        .padding(8)
        .background(Color.white.opacity(latest ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(model.accent.top.opacity(latest && model.isCurrentPlaying ? 0.8 : 0), lineWidth: 1.5)
        }
        .onTapGesture { if latest { model.togglePlay() } }
        .id(item.id)
    }
}

struct YouBubble: View {
    @EnvironmentObject var model: WatchModel
    let item: WatchLogItem

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(item.text)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(8)
                .background(model.accent.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let st = item.status, st != "delivered" {
                Text(st == "failed" ? "Not delivered" : st.capitalized)
                    .font(.caption2)
                    .foregroundStyle(st == "failed" ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 18)
        .id(item.id)
    }
}

struct PlayButton: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        Button { model.togglePlay() } label: {
            Image(systemName: model.isCurrentPlaying && model.isPlaying ? "pause.fill" : "play.fill")
                .foregroundStyle(.white)
        }
        .disabled(!model.hasClip)
        .accessibilityLabel(model.isCurrentPlaying && model.isPlaying ? "Pause" : "Play")
    }
}

struct ReplyButton: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        Button {
            Task { await model.startRecording() }
        } label: {
            Image(systemName: "mic.fill")
                .foregroundStyle(.white)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.accent.top)
        .disabled(model.state.session?.canReply != true || !model.phoneReachable)
        // Double Tap (thumb and index finger): start a reply without touching the screen.
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel("Reply")
    }
}

struct SessionList: View {
    @EnvironmentObject var model: WatchModel
    /// Back to the conversation, after picking.
    let picked: () -> Void

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
                    picked()
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(stateColor(s.state)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).lineLimit(2)
                            if let r = model.state.latest[s.id] {
                                Text(r.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            } else if s.name != s.project {
                                Text(s.project).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if s.id == model.selectedID {
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
        VStack(spacing: 10) {
            Text("To \(model.state.session?.name ?? "Claude")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            LiveBars()
                .frame(height: 30)
            Text(String(format: "%d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                .font(.title3.monospacedDigit())
            Button {
                model.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .frame(width: 58, height: 58)
                    .background(Color.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            // Double Tap again: stop, and transcribe.
            .handGestureShortcut(.primaryAction)
            .accessibilityLabel("Stop and transcribe")
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { model.cancelRecording() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel")
            }
        }
    }
}

/// Aloud's five bars, moving while you speak.
struct LiveBars: View {
    private let shape: [CGFloat] = [0.42, 0.73, 1.0, 0.73, 0.42]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(.red)
                        .frame(width: 5, height: 30 * shape[i] * (0.45 + 0.55 * abs(sin(t * 5 + Double(i)))))
                }
            }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject var model: WatchModel
    let text: String
    @State private var edited = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("To \(model.state.session?.name ?? "Claude")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Tap to correct it, by dictation or Scribble.
                TextField("Your reply", text: $edited, axis: .vertical)
                    .lineLimit(2...10)
                Button {
                    Task { await model.send(edited) }
                } label: {
                    Label("Send", systemImage: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.accent.top)
                .disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // Double Tap a third time: send.
                .handGestureShortcut(.primaryAction)
                HStack(spacing: 6) {
                    Button {
                        Task { await model.discardAndRecordAgain() }
                    } label: {
                        Image(systemName: "mic")
                    }
                    .accessibilityLabel("Record again")
                    Button(role: .destructive) { model.discard() } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Discard")
                }
            }
            .padding(.bottom, 8)
        }
        .onAppear { edited = text }
    }
}

/// Waiting for the transcript — and, if it takes a while, saying why it
/// might and offering a way out.
struct TranscribingView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let waited = ctx.date.timeIntervalSince(model.transcribeStarted ?? ctx.date)
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text("Transcribing…").font(.footnote).foregroundStyle(.secondary)
                if waited > 15 {
                    Text("Still working. Is Aloud open on your iPhone?")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Button("Cancel", role: .cancel) { model.discard() }
                }
            }
        }
    }
}

struct BusyView: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .symbolEffect(.variableColor.iterative, isActive: true)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct SentBadge: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Sent").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
        .transition(.opacity)
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
                    Button("Try Again") { model.retrySend() }
                        .buttonStyle(.borderedProminent)
                        .tint(model.accent.top)
                        .handGestureShortcut(.primaryAction)
                }
                Button("Discard", role: .destructive) {
                    model.draftReviewText = nil
                    model.discard()
                }
            }
        }
    }
}
