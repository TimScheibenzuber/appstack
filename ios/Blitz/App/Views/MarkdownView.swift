import ClaudeKit
import SwiftUI
import UIKit

/// Renders a finished reply.
struct MarkdownView: View {
    let text: String

    var body: some View {
        MarkdownBlocksView(stable: MarkdownBlockSplitter.blocks(of: text), tail: [])
    }
}

/// Renders Markdown blocks: prose as inline-formatted text, fenced code as copyable
/// monospaced blocks. Stable blocks are equatable views with cached parsing, so while a
/// reply streams only the growing tail is parsed and laid out again.
struct MarkdownBlocksView: View {
    let stable: [MarkdownBlock]
    let tail: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stable.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, isFinal: true)
                    .equatable()
            }
            ForEach(Array(tail.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, isFinal: false)
            }
        }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    /// Final blocks are parsed once and cached; a growing block is parsed fresh each frame.
    let isFinal: Bool

    nonisolated static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.isFinal == rhs.isFinal && lhs.block == rhs.block
    }

    var body: some View {
        switch block {
        case .paragraph(let prose):
            Text(isFinal ? MarkdownCache.attributed(prose) : MarkdownCache.render(prose))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code)
        }
    }
}

/// Small LRU cache of parsed paragraphs (main thread only).
@MainActor
enum MarkdownCache {
    private static var entries: [String: (value: AttributedString, lastUse: UInt64)] = [:]
    private static var clock: UInt64 = 0
    private static let capacity = 400

    static func attributed(_ prose: String) -> AttributedString {
        clock &+= 1
        if let hit = entries[prose] {
            entries[prose] = (hit.value, clock)
            return hit.value
        }
        let rendered = render(prose)
        if entries.count >= capacity {
            // Drop the least recently used quarter in one pass.
            let victims = entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(capacity / 4)
            for victim in victims { entries[victim.key] = nil }
        }
        entries[prose] = (rendered, clock)
        return rendered
    }

    static func render(_ prose: String) -> AttributedString {
        // SwiftUI `Text` shows inline Markdown only; headings and bullets are mapped to
        // inline equivalents so they still read well.
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                let title = trimmed.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**\(title)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let indent = String(repeating: " ", count: line.count - trimmed.count)
                return indent + "• " + trimmed.dropFirst(2)
            }
            return String(line)
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options))
            ?? AttributedString(prose)
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "Code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
