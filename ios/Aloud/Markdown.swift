// Markdown.swift — Claude's responses as written: headings, lists, tables and
// code blocks, not the flattened text that gets spoken.
//
// A small block parser, with inline styling (bold, italics, `code`, links) left
// to Foundation's own Markdown support. Enough for what Claude writes; not a
// CommonMark implementation.

import SwiftUI
import UIKit

enum MDBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [String])
    case quote(String)
    case code(language: String?, text: String)
    case table(rows: [[String]])
    case rule
}

enum Markdown {
    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var quote: [String] = []
        var table: [[String]] = []
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if let l = list { blocks.append(.list(ordered: l.ordered, items: l.items)); list = nil }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
            if !table.isEmpty { blocks.append(.table(rows: table)); table = [] }
        }

        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.popFirst() {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(next)
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: code.joined(separator: "\n")))
                continue
            }
            if line.isEmpty { flush(); continue }
            if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 {
                flush(); blocks.append(.rule); continue
            }
            if let h = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[h] == " ", line.distance(from: line.startIndex, to: h) <= 6 {
                flush()
                blocks.append(.heading(level: line.distance(from: line.startIndex, to: h),
                                       text: String(line[h...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| line under the header carries no content.
                if !cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } && !$0.isEmpty }) {
                    table.append(cells)
                }
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                if quote.isEmpty { flush() }
                quote.append(String(line.dropFirst(line == ">" ? 1 : 2)))
                continue
            }
            if let item = bullet(line) {
                if list == nil || list?.ordered == true { flush(); list = (false, []) }
                list?.items.append(item)
                continue
            }
            if let item = numbered(line) {
                if list == nil || list?.ordered == false { flush(); list = (true, []) }
                list?.items.append(item)
                continue
            }
            if list != nil, raw.hasPrefix("  "), var l = list, !l.items.isEmpty {
                // A wrapped continuation of the last list item.
                l.items[l.items.count - 1] += " " + line
                list = l
                continue
            }
            if !quote.isEmpty || !table.isEmpty || list != nil { flush() }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    private static func bullet(_ line: String) -> String? {
        for p in ["- ", "* ", "+ "] where line.hasPrefix(p) {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
              line.distance(from: line.startIndex, to: dot) <= 3,
              line[line.startIndex..<dot].allSatisfy(\.isNumber), !line[line.startIndex..<dot].isEmpty
        else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest.dropFirst())
    }

    static func inline(_ text: String) -> AttributedString {
        var out = (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
        // Inline `code` gets a soft chip behind it, as it would on the web.
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].backgroundColor = Color(.tertiarySystemFill)
            out[run.range].foregroundColor = Color.aloudDeep
        }
        return out
    }
}

struct MarkdownView: View {
    let blocks: [MDBlock]

    init(_ source: String) { blocks = Markdown.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Markdown.inline(text))
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(Markdown.inline(item))
                    }
                }
            }
        case .quote(let text):
            Text(Markdown.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                }
        case .code(let language, let text):
            CodeBlock(language: language, code: text)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Markdown.inline(cell))
                                    .font(i == 0 ? .footnote.bold() : .footnote)
                            }
                        }
                        if i == 0 { Divider() }
                    }
                }
                .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        case .rule:
            Divider()
        }
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemFill))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }
}
