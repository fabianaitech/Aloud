// SessionsSheet.swift — every Claude Code session on the Mac, by name.

import SwiftUI

struct SessionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.sessions.isEmpty {
                    ContentUnavailableView("No sessions",
                                           systemImage: "terminal",
                                           description: Text("Start Claude Code on your Mac. Sessions started before Remote Voice was set up need a restart to show up here."))
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(model.sessions) { s in
                        Button {
                            model.selectedSessionID = s.session_id
                            dismiss()
                        } label: {
                            SessionRow(session: s,
                                       selected: s.session_id == model.selectedSessionID,
                                       unread: model.unread[s.session_id] ?? 0,
                                       last: model.lastResponse(in: s.session_id))
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if !model.sessions.isEmpty {
                        Text("Names come from Claude Code — rename a session with /rename.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(model.macName ?? "Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { try? await model.refreshSessions() }
            .toolbar { Button("Done") { dismiss() } }
        }
        .tint(.aloud)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct SessionRow: View {
    let session: RemoteSession
    let selected: Bool
    let unread: Int
    let last: ResponseItem?

    var body: some View {
        HStack(spacing: 12) {
            SurfaceTile(session: session, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayName).font(.body.weight(.semibold)).lineLimit(1)
                    if selected {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.aloud)
                    }
                }
                Text([session.project, session.surface, session.can_reply ? nil : "listen only"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let last {
                    Text(last.text).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                StatePill(state: session.state, compact: true)
                if unread > 0 {
                    Text("\(unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.aloud, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
