// SpokenText.swift — the response as it's spoken, sentence highlighted.

import SwiftUI

/// The response, with the sentence being spoken highlighted.
///
/// The Mac says which text each audio part holds and how long it lasts, so the
/// part is exact; within a part, the sentence is placed by its share of the
/// characters — close enough to follow along, which is all this is for.
struct SpokenText: View {
    let response: ResponseItem
    @EnvironmentObject var player: Player

    var body: some View {
        if response.segments.isEmpty {
            ScrollView {
                Text(response.text).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        } else {
            let now = active
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(response.segments.enumerated()), id: \.offset) { i, seg in
                            Text(Self.attributed(Self.sentences(seg.text), highlight: now?.segment == i ? now?.sentence : nil))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        if let rest = remainder {
                            Text(rest).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .onChange(of: now?.segment) { _, seg in
                    if let seg { withAnimation { proxy.scrollTo(seg, anchor: .center) } }
                }
            }
        }
    }

    /// Text not yet synthesized while parts are still arriving.
    private var remainder: String? {
        guard response.clip == nil, response.clipError == nil else { return nil }
        let said = Self.collapse(response.segments.map(\.text).joined(separator: " "))
        let all = Self.collapse(response.text)
        guard all.hasPrefix(said), all.count > said.count else { return nil }
        return String(all.dropFirst(said.count)).trimmingCharacters(in: .whitespaces)
    }

    /// (segment, sentence) being spoken now, if this response is playing.
    private var active: (segment: Int, sentence: Int)? {
        guard player.currentID == response.id else { return nil }
        let segs = response.segments
        var seg = 0
        var t = player.position
        if let part = player.currentPart {
            seg = part
        } else {
            // A whole-response clip: find the part by adding up durations.
            for (i, s) in segs.enumerated() {
                seg = i
                if t < s.duration { break }
                t -= s.duration
            }
        }
        guard seg < segs.count else { return nil }
        let sents = Self.sentences(segs[seg].text)
        let total = Double(max(1, sents.reduce(0) { $0 + $1.count }))
        var end = 0.0
        for (j, s) in sents.enumerated() {
            end += Double(s.count) / total * segs[seg].duration
            if t < end { return (seg, j) }
        }
        return (seg, max(0, sents.count - 1))
    }

    static func attributed(_ sentences: [String], highlight: Int?) -> AttributedString {
        var out = AttributedString()
        for (j, s) in sentences.enumerated() {
            var a = AttributedString(j < sentences.count - 1 ? s + " " : s)
            if j == highlight {
                a.backgroundColor = Color.accentColor.opacity(0.22)
                a.foregroundColor = .primary
            }
            out += a
        }
        return out
    }

    /// The same sentence split the Mac uses to chunk speech.
    static func sentences(_ text: String) -> [String] {
        let t = collapse(text)
        guard let re = try? NSRegularExpression(pattern: #".*?[.!?](?:\s|$)|.+$"#) else { return [t] }
        let ns = t as NSString
        let out = re.matches(in: t, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return out.isEmpty ? [t] : out
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

