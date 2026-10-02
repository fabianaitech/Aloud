// MainView.swift — one session's conversation, and who you're talking to.

import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSessions = false
    @State private var showSettings = false
    @State private var fullResponse: ResponseItem?

    var body: some View {
        NavigationStack {
            Timeline(fullResponse: $fullResponse)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 8) {
                        SessionHeader { showSessions = true }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                        ProblemBanner()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(Color(.systemGroupedBackground))
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { Composer() }
                .background(Color(.systemGroupedBackground))
                .toolbar {
                    ToolbarItem(placement: .principal) { MacIndicator() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
                .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showSessions) { SessionsSheet() }
                .sheet(isPresented: $showSettings) { SettingsView() }
                .sheet(item: $fullResponse) { FullResponseSheet(response: $0) }
        }
        .tint(.aloud)
        #if DEBUG
        .task {
            // Screenshots without tapping: -rvShowSessions / -rvShowFull / -rvShowSettings YES.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if UserDefaults.standard.bool(forKey: "rvShowSessions") { showSessions = true }
            if UserDefaults.standard.bool(forKey: "rvShowFull") { fullResponse = model.latestResponse }
            if UserDefaults.standard.bool(forKey: "rvShowSettings") { showSettings = true }
        }
        #endif
    }
}

/// Top-left: which Mac, and whether we can hear it.
struct MacIndicator: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(model.macName ?? "Mac")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.macName ?? "Mac"), \(model.connection == .connected ? "connected" : "not connected")")
    }

    private var color: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .orange
        default: return .red
        }
    }
}

/// The session you're listening to and answering, with its state.
struct SessionHeader: View {
    @EnvironmentObject var model: AppModel
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                SurfaceTile(session: model.selectedSession, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedSession?.displayName ?? (model.sessions.isEmpty ? "No sessions" : "Choose a session"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let s = model.selectedSession { StatePill(state: s.state) }
                let others = model.unread.filter { $0.key != model.selectedSessionID }.values.reduce(0, +)
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                    if others > 0 {
                        Circle().fill(Color.aloud).frame(width: 9, height: 9).offset(x: 2, y: -1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows all sessions")
    }

    private var subtitle: String {
        if let s = model.selectedSession {
            // The project, unless it's already the title; then the id tells
            // same-folder sessions apart.
            var parts = s.displayName == s.project ? [s.surface, String(s.session_id.prefix(8))]
                                                   : [s.project, s.surface]
            if !s.can_reply { parts.append("listen only") }
            return parts.joined(separator: " · ")
        }
        if model.selectedSessionID != nil { return "This session has ended" }
        return model.sessions.isEmpty
            ? "Start Claude Code on your Mac"
            : "\(model.sessions.count) running on your Mac"
    }
}

/// Only when something's wrong — and then, what to do about it.
struct ProblemBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let (icon, text, color) = problem {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(color)
                Text(text).font(.footnote).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var problem: (String, String, Color)? {
        switch model.connection {
        case .connected, .notPaired: return nil
        case .connecting: return ("arrow.triangle.2.circlepath", "Connecting to your Mac…", .orange)
        case .offline(let why): return ("wifi.exclamationmark", why, .orange)
        case .remoteOff: return ("speaker.slash.fill", "Remote Voice is off on the Mac. Turn it on in Aloud's menu.", .secondary)
        case .unauthorized: return ("lock.fill", "This iPhone was removed on the Mac. Unpair in Settings, then pair again.", .red)
        }
    }
}

// MARK: - Timeline

struct Timeline: View {
    @EnvironmentObject var model: AppModel
    @Binding var fullResponse: ResponseItem?

    var body: some View {
        let items = model.timeline
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if items.isEmpty {
                        EmptyTimeline().padding(.top, 60)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .response(let r):
                            ResponseBubble(response: r, isLatest: r.id == model.latestResponse?.id) {
                                fullResponse = r
                            }
                        case .reply(let p):
                            ReplyBubble(reply: p)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom") }
            .onChange(of: items.last?.id) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo("bottom") }
            }
            .onChange(of: model.selectedSessionID) { _, _ in proxy.scrollTo("bottom") }
        }
    }
}

struct EmptyTimeline: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            WaveformBars(color: .aloud.opacity(0.35), height: 44)
            Text("Waiting for Claude").font(.headline)
            Text(model.selectedSession == nil
                 ? "Pick a session at the top to listen in."
                 : "The next response in \(model.selectedSession!.displayName) plays here as soon as it's spoken.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
    }
}

/// One Claude response: highlighted as it's spoken, formatted otherwise.
struct ResponseBubble: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: Player
    let response: ResponseItem
    let isLatest: Bool
    let showAll: () -> Void

    private var isCurrent: Bool { player.currentID == response.id }
    @State private var fullHeight: CGFloat = 0
    private var limit: CGFloat { isLatest ? 320 : 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.caption.weight(.bold)).foregroundStyle(Color.aloud)
                Text("Claude").font(.caption.weight(.semibold))
                Text(Date(timeIntervalSince1970: response.ts), format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if response.markdown != nil {
                    Button(action: showAll) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show the full response")
                }
            }

            if isCurrent && !response.segments.isEmpty {
                SpokenText(response: response)
            } else {
                Group {
                    if let md = response.markdown {
                        MarkdownView(md)
                    } else {
                        Text(response.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                .frame(maxHeight: limit, alignment: .top)
                .clipped()
                // Fade only where something is actually cut off.
                .overlay(alignment: .bottom) { if fullHeight > limit + 1 { fade } }
                .contentShape(Rectangle())
                .onTapGesture(perform: showAll)
            }

            PlaybackBar(response: response)
        }
        .card()
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.aloud.opacity(isCurrent ? 0.45 : 0), lineWidth: 1.5)
        }
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }

    /// A soft fade where long responses are cut off; tap for the rest.
    private var fade: some View {
        LinearGradient(colors: [Color(.secondarySystemGroupedBackground).opacity(0),
                                Color(.secondarySystemGroupedBackground)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 36)
            .allowsHitTesting(false)
    }
}

struct PlaybackBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: Player
    let response: ResponseItem
    /// While the slider is held: where it is, not where the audio is.
    @State private var scrub: Double?

    private var current: Bool { player.currentID == response.id }

    /// The whole response's length: the full clip once it exists, else the
    /// sentences so far.
    private var total: Double {
        response.duration ?? response.segments.reduce(0) { $0 + $1.duration }
    }

    /// Where playback is within the whole response — a streamed sentence
    /// counts the sentences before it.
    private var elapsed: Double {
        guard current else { return 0 }
        if let part = player.currentPart {
            return response.segments.prefix(part).reduce(0) { $0 + $1.duration } + player.position
        }
        return player.position
    }

    var body: some View {
        if current {
            VStack(spacing: 6) {
                HStack(spacing: 22) {
                    Spacer()
                    skip(-10)
                    playPause
                    skip(10)
                    Spacer()
                }
                timeline
            }
        } else {
            HStack(spacing: 12) {
                playPause
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var playPause: some View {
        Button {
            if current {
                player.isPlaying ? player.pause() : player.resume()
            } else {
                Task { await model.playClip(of: response) }
            }
        } label: {
            Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: current ? 18 : 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: current ? 46 : 36, height: current ? 46 : 36)
                .background(LinearGradient.aloud, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(response.clip == nil && !current)
        .opacity(response.clip == nil && !current ? 0.4 : 1)
        .accessibilityLabel(current && player.isPlaying ? "Pause" : "Play")
    }

    private func skip(_ seconds: Double) -> some View {
        Button { seek(to: elapsed + seconds) } label: {
            Image(systemName: seconds < 0 ? "gobackward.10" : "goforward.10")
                .font(.title3.weight(.medium))
        }
        .buttonStyle(.borderless)
        .disabled(total <= 0)
        .accessibilityLabel(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
    }

    private var timeline: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { scrub ?? elapsed }, set: { scrub = $0 }),
                   in: 0...max(total, 0.1)) { editing in
                if !editing, let to = scrub {
                    seek(to: to)
                    scrub = nil
                }
            }
            .tint(.aloud)
            HStack {
                Text(clock(scrub ?? elapsed))
                Spacer()
                Text("-" + clock(max(0, total - (scrub ?? elapsed))))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Seek within the whole response. Within the sentence playing now, that's
    /// a seek; anywhere else, the full clip takes over from that point (once it
    /// exists — while it's still being made, only the current sentence moves).
    private func seek(to target: Double) {
        let t = max(0, min(target, total))
        if player.currentPart == nil {
            player.seek(to: t)
            return
        }
        let part = player.currentPart ?? 0
        let start = response.segments.prefix(part).reduce(0) { $0 + $1.duration }
        let end = start + (response.segments.indices.contains(part) ? response.segments[part].duration : 0)
        if t >= start && t < end {
            player.seek(to: t - start)
        } else if response.clip != nil {
            Task { await model.playClip(of: response, from: t) }
        } else {
            player.seek(to: min(max(t - start, 0), end - start))
        }
    }

    private func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var status: String {
        if let e = response.clipError { return "Audio unavailable — \(e)" }
        guard response.clip != nil else { return "Preparing audio…" }
        guard let d = response.duration else { return "" }
        let s = Int(d.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }
}

/// Your reply, and how far it got.
struct ReplyBubble: View {
    let reply: ReplyItem

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(reply.text)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(LinearGradient.aloud,
                            in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                       bottomTrailingRadius: 5, topTrailingRadius: 18,
                                                       style: .continuous))
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            if let e = reply.error {
                Text(e).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.trailing)
            } else if let d = reply.detail, reply.status == "queued" || reply.status == "sent" {
                Text(d).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var icon: String {
        switch reply.status {
        case "mac": return "laptopcomputer"
        case "queued": return "clock"
        case "sent": return "paperplane"
        case "delivered": return "checkmark.circle.fill"
        default: return "exclamationmark.circle.fill"
        }
    }

    private var label: String {
        switch reply.status {
        case "mac": return "On your Mac"
        case "queued": return "Queued"
        case "sent": return "Sending"
        case "delivered": return "Delivered"
        default: return "Not delivered"
        }
    }

    private var color: Color {
        switch reply.status {
        case "delivered": return .green
        case "failed": return .red
        case "mac": return .secondary
        default: return .secondary
        }
    }
}

/// The whole response as Claude wrote it: code blocks, lists, tables.
struct FullResponseSheet: View {
    let response: ResponseItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownView(response.markdown ?? response.text)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: response.markdown ?? response.text)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .tint(.aloud)
        .presentationDragIndicator(.visible)
    }
}
