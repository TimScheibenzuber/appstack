import Foundation

/// A renderable unit of Markdown: a paragraph (text between blank lines) or a fenced code block.
public enum MarkdownBlock: Sendable, Hashable {
    case paragraph(String)
    case code(language: String?, code: String, isClosed: Bool)
}

/// Splits Markdown into blocks incrementally while a reply streams.
///
/// Text only ever grows during streaming, so every block that is provably finished (a
/// paragraph followed by a blank line or a fence, a closed code block) is moved to
/// `stableBlocks` once and never scanned again. Each update therefore costs O(length of the
/// unfinished tail) instead of O(length of the whole reply), and the UI can skip re-rendering
/// stable blocks entirely.
public struct MarkdownBlockSplitter: Sendable {
    public private(set) var stableBlocks: [MarkdownBlock] = []
    public private(set) var tailBlocks: [MarkdownBlock] = []
    /// UTF-8 offset up to which the text has been consumed into `stableBlocks`.
    private var consumedUTF8 = 0

    public init() {}

    public var blocks: [MarkdownBlock] { stableBlocks + tailBlocks }

    /// `text` must extend the previously passed text; anything else starts over.
    public mutating func update(_ text: String) {
        let utf8 = text.utf8
        if utf8.count < consumedUTF8 { self = MarkdownBlockSplitter() }
        let start = utf8.index(utf8.startIndex, offsetBy: consumedUTF8)
        let scanned = Self.scan(text[start...], isComplete: false)
        tailBlocks = []
        for entry in scanned {
            if entry.finished {
                if let block = entry.block { stableBlocks.append(block) }
                consumedUTF8 += entry.length
            } else if let block = entry.block {
                tailBlocks.append(block)
            }
        }
    }

    /// One-shot split. With `isComplete` the last line counts as finished even without a
    /// trailing newline (a final reply often ends in a closing fence); while streaming it
    /// might still grow, so it is treated as open.
    public static func blocks(of text: String, isComplete: Bool = true) -> [MarkdownBlock] {
        scan(Substring(text), isComplete: isComplete).compactMap(\.block)
    }

    // MARK: - Scanner

    private struct Entry {
        /// `nil` for consumed blank lines that produce no block.
        var block: MarkdownBlock?
        /// UTF-8 length of the source consumed by this entry.
        var length: Int
        var finished: Bool
    }

    private struct Fence {
        var marker: Character
        var length: Int
        var language: String?
    }

    private static func scan(_ text: Substring, isComplete: Bool) -> [Entry] {
        var entries: [Entry] = []
        var paragraph: [Substring] = []
        var paragraphLength = 0
        var code: [Substring] = []
        var codeLength = 0
        var fence: Fence?

        func flushParagraph(finished: Bool) {
            guard !paragraph.isEmpty else { return }
            entries.append(Entry(block: .paragraph(paragraph.joined(separator: "\n")), length: paragraphLength, finished: finished))
            paragraph.removeAll()
            paragraphLength = 0
        }

        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var index = utf8.startIndex
        while true {
            let atEnd = index == utf8.endIndex
            if !atEnd && utf8[index] != 0x0A {
                index = utf8.index(after: index)
                continue
            }
            let line = text[lineStart..<index]
            let terminated = !atEnd || isComplete
            let lineLength = utf8.distance(from: lineStart, to: index) + (atEnd ? 0 : 1)
            if atEnd && line.isEmpty { break }

            if let open = fence {
                if terminated && MarkdownFence.isClosing(line, marker: open.marker, length: open.length) {
                    entries.append(Entry(
                        block: .code(language: open.language, code: code.joined(separator: "\n"), isClosed: true),
                        length: codeLength + lineLength, finished: true
                    ))
                    fence = nil
                    code.removeAll()
                    codeLength = 0
                } else {
                    code.append(line)
                    codeLength += lineLength
                }
            } else if terminated, let open = MarkdownFence.opening(line) {
                flushParagraph(finished: true)
                fence = Fence(marker: open.marker, length: open.length, language: open.language)
                codeLength = lineLength
            } else if terminated && line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
                if paragraph.isEmpty {
                    entries.append(Entry(block: nil, length: lineLength, finished: true))
                } else {
                    paragraphLength += lineLength
                    flushParagraph(finished: true)
                }
            } else {
                paragraph.append(line)
                paragraphLength += lineLength
            }

            if atEnd { break }
            index = utf8.index(after: index)
            lineStart = index
        }

        if let open = fence {
            entries.append(Entry(
                block: .code(language: open.language, code: code.joined(separator: "\n"), isClosed: false),
                length: codeLength, finished: false
            ))
        } else {
            flushParagraph(finished: false)
        }
        return entries
    }
}

/// CommonMark fenced-code-block rules (``` or ~~~, up to three spaces of indentation).
enum MarkdownFence {
    private static func indentation(of line: Substring) -> Int {
        var count = 0
        for character in line {
            guard character == " " else { break }
            count += 1
        }
        return count
    }

    static func opening(_ line: Substring) -> (marker: Character, length: Int, language: String?)? {
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

    static func isClosing(_ line: Substring, marker: Character, length: Int) -> Bool {
        let indent = indentation(of: line)
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let run = rest.prefix { $0 == marker }.count
        guard run >= length else { return false }
        return rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
