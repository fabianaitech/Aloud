// PairView.swift — first run: connect this iPhone to the Mac.

import SwiftUI

struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var server = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var field: Field?

    enum Field { case server, code }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient.aloud)
                        .frame(width: 88, height: 88)
                        .overlay { WaveformBars(height: 42) }
                        .shadow(color: .aloud.opacity(0.35), radius: 16, y: 8)
                    Text("Aloud Remote").font(.largeTitle.bold())
                    Text("Hear Claude on your iPhone, and answer by voice.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 14) {
                    step(1, "On your Mac, open Aloud's menu → Remote Voice → Pair iPhone…")
                    step(2, "Make sure the Tailscale app is connected on this iPhone.")
                    step(3, "Enter the address and the six-digit code it shows.")
                }
                .card()

                VStack(spacing: 12) {
                    TextField("https://your-mac.tailnet.ts.net:8443", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($field, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { field = .code }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    TextField("Pairing code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .multilineTextAlignment(.center)
                        .focused($field, equals: .code)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await pair() }
                } label: {
                    Group {
                        if busy { ProgressView().tint(.white) } else { Text("Pair with Mac").font(.headline) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(canPair ? AnyShapeStyle(LinearGradient.aloud) : AnyShapeStyle(Color.gray.opacity(0.4)),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!canPair)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if server.isEmpty { server = model.serverText } }
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
    }

    private var canPair: Bool {
        !busy && !server.isEmpty && code.filter(\.isNumber).count == 6
    }

    private func pair() async {
        busy = true
        error = nil
        field = nil
        do { try await model.pair(server: server, code: code) } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.aloud, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}
