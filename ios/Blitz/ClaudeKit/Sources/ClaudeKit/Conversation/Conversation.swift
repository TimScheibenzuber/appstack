import Foundation

public struct ChatMessage: Identifiable, Codable, Sendable, Hashable {
    public enum Status: Codable, Sendable, Hashable {
        case complete
        /// Placeholder for the turn currently streaming; never persisted as final state.
        case streaming
        /// The user stopped generation; partial text is kept.
        case stopped
        /// The model hit `max_tokens`.
        case truncated
        /// Declined by safety classifiers (after any server-side fallback).
        case refused(category: String?)
        case failed(message: String)
    }

    public let id: UUID
    public var role: Role
    public var blocks: [ContentBlock]
    public var createdAt: Date
    public var status: Status
    /// Model that produced an assistant turn (may differ from the requested one after a fallback).
    public var model: String?
    public var usage: Usage?
    /// Excluded turns stay visible but are never sent to the API again.
    public var excludedFromContext: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        blocks: [ContentBlock],
        createdAt: Date = Date(),
        status: Status = .complete,
        model: String? = nil,
        usage: Usage? = nil,
        excludedFromContext: Bool = false
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.createdAt = createdAt
        self.status = status
        self.model = model
        self.usage = usage
        self.excludedFromContext = excludedFromContext
    }

    public var text: String {
        blocks.compactMap(\.text).joined()
    }

    public var thinkingText: String {
        blocks.compactMap { block -> String? in
            if case .thinking(let thinking, _) = block, !thinking.isEmpty { return thinking }
            return nil
        }.joined(separator: "\n\n")
    }
}

public struct Conversation: Identifiable, Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Frozen at creation so the cached prefix and thinking signatures stay valid.
    public var systemPrompt: String?
    public var messages: [ChatMessage]
    public var schemaVersion: Int

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        systemPrompt: String?,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.schemaVersion = Self.currentSchemaVersion
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        let first = messages.first { $0.role == .user }?.text ?? ""
        return Self.makeTitle(from: first)
    }

    public static func makeTitle(from text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Neuer Chat" }
        return trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
    }

    /// The history as it must be sent to the API.
    ///
    /// The transformation is a pure per-message function plus merging of adjacent same-role
    /// turns, so the result for a conversation is always a prefix of the result after more
    /// turns are appended. That keeps request bodies append-only, which is what both the
    /// prompt cache and the preserved-thinking signature check require.
    public func apiMessages() -> [Message] {
        var result: [Message] = []
        for message in messages where !message.excludedFromContext && message.status != .streaming {
            let blocks = Self.sanitizedBlocks(message.blocks, role: message.role)
            guard !blocks.isEmpty else { continue }
            // An assistant turn must carry visible text; reasoning alone is not a reply.
            if message.role == .assistant && !blocks.contains(where: \.isText) { continue }
            if let last = result.last, last.role == message.role {
                result[result.count - 1].content.append(contentsOf: blocks)
            } else {
                result.append(Message(role: message.role, content: blocks))
            }
        }
        while let first = result.first, first.role != .user {
            result.removeFirst()
        }
        return result
    }

    static func sanitizedBlocks(_ blocks: [ContentBlock], role: Role) -> [ContentBlock] {
        // After a mid-output server-side fallback, only text may be echoed from before the
        // last fallback marker (thinking from the declining model must not be replayed).
        let lastFallback = blocks.lastIndex { if case .fallback = $0 { return true } else { return false } }
        var result: [ContentBlock] = []
        result.reserveCapacity(blocks.count)
        for (index, block) in blocks.enumerated() {
            let beforeFallback = lastFallback.map { index < $0 } ?? false
            switch block {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(block) }
            case .thinking(_, let signature):
                if role == .assistant, !beforeFallback, !signature.isEmpty { result.append(block) }
            case .redactedThinking(let data):
                if role == .assistant, !beforeFallback, !data.isEmpty { result.append(block) }
            case .fallback, .unknown:
                continue
            }
        }
        return result
    }

    /// Drops every thinking block (recovery after the API rejected replayed signatures).
    public mutating func stripThinking() {
        for index in messages.indices {
            messages[index].blocks.removeAll(where: \.isThinking)
        }
    }
}

/// Lightweight row model for the conversation list (kept in a small index file so the list
/// loads instantly without decoding every conversation).
public struct ConversationSummary: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    public var updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    public init(_ conversation: Conversation) {
        self.init(id: conversation.id, title: conversation.displayTitle, updatedAt: conversation.updatedAt)
    }
}
