import Foundation
import UniformTypeIdentifiers
import PDFKit
import QuickLookThumbnailing
import ImageIO

enum Importer {
    enum Role { case user, assistant }

    struct Turn: Hashable {
        var role: Role
        var text: String
    }

    // MARK: Files

    /// Encrypts the file into the vault and returns an item with extracted text and a thumbnail.
    static func file(_ url: URL, into vault: Vault) async throws -> Item {
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values.contentType ?? .data
        var item = Item(kind: .file, title: url.deletingPathExtension().lastPathComponent)
        try vault.storeBlob(from: url, id: item.id)
        let thumb = await thumbnail(of: url)
        if let thumb { try? vault.storeThumb(thumb, id: item.id) }
        item.file = FileRef(name: url.lastPathComponent, type: type.identifier, size: values.fileSize ?? 0,
                            text: text(of: url, type: type), hasThumb: thumb != nil)
        return item
    }

    static func text(of url: URL, type: UTType) -> String? {
        if type.conforms(to: .pdf) { return PDFDocument(url: url)?.string.map { String($0.prefix(20_000)) } }
        guard type.conforms(to: .text), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 60_000)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func thumbnail(of url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 220), scale: 2,
                                                   representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func image(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    // MARK: Chats

    /// Reads Claude (`chat_messages`) and ChatGPT (`mapping`) data exports.
    static func chats(from data: Data) -> [Item] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let conversations = json as? [[String: Any]] ?? [json as? [String: Any]].compactMap { $0 }
        return conversations.compactMap { c in
            let turns = claudeTurns(c) ?? chatGPTTurns(c) ?? []
            guard !turns.isEmpty else { return nil }
            let name = (c["name"] as? String) ?? (c["title"] as? String) ?? ""
            let date = date(c["created_at"]) ?? date(c["create_time"]) ?? .now
            return Item(kind: .chat, title: name.isEmpty ? String(turns[0].text.prefix(60)) : name,
                        body: transcript(turns), created: date, updated: date)
        }
    }

    private static func claudeTurns(_ c: [String: Any]) -> [Turn]? {
        (c["chat_messages"] as? [[String: Any]])?.compactMap { m in
            let parts = (m["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
            let text = (m["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parts.joined(separator: "\n")
            return text.isEmpty ? nil : Turn(role: m["sender"] as? String == "human" ? .user : .assistant, text: text)
        }
    }

    private static func chatGPTTurns(_ c: [String: Any]) -> [Turn]? {
        guard let mapping = c["mapping"] as? [String: [String: Any]] else { return nil }
        // Follow the active branch from the last node back to the root.
        var chain: [[String: Any]] = []
        var node = c["current_node"] as? String
        while let id = node, let entry = mapping[id] {
            if let message = entry["message"] as? [String: Any] { chain.append(message) }
            node = entry["parent"] as? String
        }
        return chain.reversed().compactMap { m in
            let role = (m["author"] as? [String: Any])?["role"] as? String
            let parts = ((m["content"] as? [String: Any])?["parts"] as? [Any])?.compactMap { $0 as? String } ?? []
            let text = parts.joined(separator: "\n")
            guard role == "user" || role == "assistant", !text.isEmpty else { return nil }
            return Turn(role: role == "user" ? .user : .assistant, text: text)
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let t = value as? Double { return Date(timeIntervalSince1970: t) }
        guard let s = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: s.replacing(/\.\d+/, with: ""))
    }

    // MARK: Transcripts

    static func transcript(_ turns: [Turn]) -> String {
        turns.map { "### \($0.role == .user ? "You" : "Assistant")\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Splits a pasted or imported transcript into turns. Understands "### You", "User:", "**Claude:**" and similar.
    static func turns(in body: String) -> [Turn] {
        var turns: [Turn] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let speaker = speaker(line) {
                turns.append(Turn(role: speaker.role, text: speaker.rest))
            } else if turns.isEmpty {
                turns.append(Turn(role: .user, text: String(line)))
            } else {
                turns[turns.count - 1].text += "\n" + line
            }
        }
        return turns.compactMap { t in
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Turn(role: t.role, text: text)
        }
    }

    private static let users: Set = ["you", "user", "human", "me", "ich", "du"]
    private static let assistants: Set = ["assistant", "claude", "chatgpt", "gpt", "gemini", "ai", "ki", "bot"]

    private static func speaker(_ line: Substring) -> (role: Role, rest: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isHeading = trimmed.hasPrefix("#")
        let bare = trimmed.drop { "#*_ ".contains($0) }
        let parts = bare.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard isHeading || parts.count == 2 else { return nil }
        let marks = CharacterSet(charactersIn: "*_ ")
        let name = parts[0].trimmingCharacters(in: marks).lowercased()
        let rest = parts.count == 2 ? String(parts[1].drop { "*_ ".contains($0) }) : ""
        if users.contains(name) { return (.user, rest) }
        if assistants.contains(name) { return (.assistant, rest) }
        return nil
    }
}
