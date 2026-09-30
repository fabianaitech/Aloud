// Composer.swift — speaking (or typing) a reply, pinned to the bottom.

import SwiftUI

struct Composer: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var recorder: Recorder
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 10) {
            if model.micDenied { micDenied }
            content
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy, value: model.compose)
        .sensoryFeedback(trigger: model.compose) { old, new in
            switch (old, new) {
            case (_, .recording): return .start
            case (.recording, _): return .stop
            case (.sending, .idle): return .success
            case (_, .failed): return .error
            default: return nil
            }
        }
    }

    private var canReply: Bool {
        model.connection == .connected && model.selectedSession?.can_reply == true
    }

    private var blockedReason: String? {
        if model.connection != .connected { return "Not connected to your Mac" }
        guard let s = model.selectedSession else { return "Choose a running session to reply" }
        if !s.can_reply { return "This session can't take replies — listen only" }
        return nil
    }

    @ViewBuilder private var content: some View {
        switch model.compose {
        case .idle:
            idle
        case .recording:
            recording
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Transcribing…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        case .editing, .sending:
            editor
        case .failed(let why):
            failed(why)
        }
    }

    // MARK: states

    private var idle: some View {
        HStack(spacing: 16) {
            Button {
                model.typeReply()
                editing = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 46, height: 46)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .disabled(!canReply)
            .accessibilityLabel("Type a reply")

            Button {
                Task { await model.startRecording() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill").font(.system(size: 18, weight: .bold))
                    Text(canReply ? "Reply" : (blockedReason ?? "Reply"))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(canReply ? AnyShapeStyle(LinearGradient.aloud) : AnyShapeStyle(Color.gray.opacity(0.45)),
                            in: Capsule())
            }
            .disabled(!canReply)
            .accessibilityLabel(canReply ? "Record a reply to \(model.selectedSession?.displayName ?? "the session")" : (blockedReason ?? ""))
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.liveText.isEmpty ? "Listening…" : model.liveText)
                .font(.body)
                .foregroundStyle(model.liveText.isEmpty ? .secondary : .primary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: model.liveText)

            HStack(spacing: 16) {
                Button(role: .cancel) { model.cancelReply() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Cancel")

                HStack(spacing: 10) {
                    WaveformBars(level: recorder.level, animating: true, color: .red, height: 24)
                    Text(timeString(recorder.elapsed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.red, in: Circle())
                        .shadow(color: .red.opacity(0.35), radius: 8, y: 3)
                }
                .accessibilityLabel("Stop recording")
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let on = model.transcribedOn {
                Label("Transcribed on \(on) · edit before sending", systemImage: on == "iPhone" ? "iphone" : "laptopcomputer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { model.cancelReply() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("Discard reply")

                TextField("Reply to \(model.selectedSession?.displayName ?? "Claude")", text: $model.transcript, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($editing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .disabled(model.compose == .sending)

                Button {
                    Task { await model.startRecording() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .disabled(model.compose == .sending)
                .accessibilityLabel("Record more")

                Button {
                    editing = false
                    Task { await model.send() }
                } label: {
                    Group {
                        if model.compose == .sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(sendable ? AnyShapeStyle(LinearGradient.aloud) : AnyShapeStyle(Color.gray.opacity(0.4)),
                                in: Circle())
                }
                .disabled(!sendable)
                .accessibilityLabel("Send")
            }
        }
    }

    private var sendable: Bool {
        model.compose != .sending && !model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            HStack {
                Button("Discard", role: .destructive) { model.cancelReply() }
                    .buttonStyle(.bordered)
                Spacer()
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

    private var micDenied: some View {
        HStack {
            Label("Microphone access is off", systemImage: "mic.slash.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            Spacer()
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote.weight(.semibold))
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
