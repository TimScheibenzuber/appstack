import ClaudeKit
import SwiftUI
import UIKit

/// Renders Claude's Markdown: prose as inline-formatted text, fenced code as copyable
/// monospaced blocks. Parsed prose is cached, so while a reply streams only the segment that
/// is still growing gets parsed again.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let segments = MarkdownSegmenter.segments(of: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(MarkdownCache.attributed(prose))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code, _):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

@MainActor
enum MarkdownCache {
    private static var cache: [String: AttributedString] = [:]
    private static let limit = 512

    static func attributed(_ prose: String) -> AttributedString {
        if let hit = cache[prose] { return hit }
        let rendered = render(prose)
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[prose] = rendered
        return rendered
    }

    private static func render(_ prose: String) -> AttributedString {
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
