import ClaudeKit
import Foundation
import os

/// File-based persistence: one JSON file per conversation plus a small index for the list.
///
/// All I/O runs on this actor, off the main thread. Files are written atomically (a crash
/// never leaves a half-written file) with `completeUnlessOpen` data protection: encrypted
/// while the device is locked, yet a reply that finishes in the background can still be saved.
actor ConversationStore {
    private static let log = Logger(subsystem: "com.appstack.blitz", category: "store")

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var index: [UUID: ConversationSummary]?

    init(directory: URL) {
        self.directory = directory
        // Default date strategy (seconds as Double) round-trips exactly; ISO 8601 would drop
        // sub-second precision and make ordering of quick successive saves unstable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        // Also accepts ISO 8601 strings written by earlier development builds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            return try Date(container.decode(String.self), strategy: .iso8601)
        }
        self.decoder = decoder
    }

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Conversations", isDirectory: true)
    }

    // MARK: - Public

    func summaries() -> [ConversationSummary] {
        loadIndexIfNeeded().values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) -> Conversation? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(Conversation.self, from: data)
        } catch {
            quarantine(url, error: error)
            return nil
        }
    }

    func save(_ conversation: Conversation) throws {
        try ensureDirectory()
        let data = try encoder.encode(conversation)
        try write(data, to: fileURL(for: conversation.id))
        var current = loadIndexIfNeeded()
        current[conversation.id] = ConversationSummary(conversation)
        index = current
        try writeIndex(current)
    }

    func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var current = loadIndexIfNeeded()
        current[id] = nil
        index = current
        try writeIndex(current)
    }

    // MARK: - Private

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func writeIndex(_ index: [UUID: ConversationSummary]) throws {
        let data = try encoder.encode(Array(index.values))
        try write(data, to: indexURL)
    }

    private func loadIndexIfNeeded() -> [UUID: ConversationSummary] {
        if let index { return index }
        var loaded: [UUID: ConversationSummary] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let summaries = try? decoder.decode([ConversationSummary].self, from: data) {
            for summary in summaries { loaded[summary.id] = summary }
        } else {
            loaded = rebuildIndex()
        }
        index = loaded
        return loaded
    }

    /// Recovers the list from the conversation files if the index is missing or damaged.
    private func rebuildIndex() -> [UUID: ConversationSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var rebuilt: [UUID: ConversationSummary] = [:]
        for url in files where url.pathExtension == "json" && url.lastPathComponent != "index.json" {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let data = try? Data(contentsOf: url) else { continue }
            if let conversation = try? decoder.decode(Conversation.self, from: data) {
                rebuilt[conversation.id] = ConversationSummary(conversation)
            } else {
                quarantine(url, error: nil)
            }
        }
        if !rebuilt.isEmpty { try? writeIndex(rebuilt) }
        return rebuilt
    }

    /// Moves an undecodable file aside instead of deleting user data or crashing on it.
    private func quarantine(_ url: URL, error: (any Error)?) {
        Self.log.error("Unreadable conversation file \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        let target = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
