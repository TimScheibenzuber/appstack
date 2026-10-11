import Foundation

/// Splits Markdown into prose and fenced code blocks so the UI can render code with a
/// monospaced, copyable view and parse only prose as inline Markdown. Works on partial,
/// still-streaming text: an unclosed fence yields a code segment with `isClosed == false`.
public enum MarkdownSegment: Sendable, Hashable {
    case prose(String)
    case code(language: String?, code: String, isClosed: Bool)
}

public enum MarkdownSegmenter {
    public static func segments(of text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var fence: (marker: Character, length: Int, language: String?)?

        func flushProse() {
            guard !prose.isEmpty else { return }
            let joined = prose.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.prose(joined))
            }
            prose.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if isClosingFence(line, marker: open.marker, length: open.length) {
                    segments.append(.code(language: open.language, code: code.joined(separator: "\n"), isClosed: true))
                    code.removeAll()
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if let opening = openingFence(line) {
                flushProse()
                fence = opening
            } else {
                prose.append(line)
            }
        }

        if let open = fence {
            segments.append(.code(language: open.language, code: code.joined(separator: "\n"), isClosed: false))
        } else {
            flushProse()
        }
        return segments
    }

    private static func indentation(of line: Substring) -> Int {
        var count = 0
        for character in line {
            guard character == " " else { break }
            count += 1
        }
        return count
    }

    private static func openingFence(_ line: Substring) -> (marker: Character, length: Int, language: String?)? {
        let indent = indentation(of: line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string may not contain backticks (CommonMark).
        if marker == "`" && info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return (marker, length, language?.isEmpty == false ? language : nil)
    }

    private static func isClosingFence(_ line: Substring, marker: Character, length: Int) -> Bool {
        let indent = indentation(of: line)
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let run = rest.prefix { $0 == marker }.count
        guard run >= length else { return false }
        return rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
