import Foundation

/// Incremental UI-facing changes produced while a response streams.
public enum StreamUpdate: Sendable, Hashable {
    /// `message_start` received. `model` names the model that is actually serving.
    case started(messageID: String?, model: String?)
    case textDelta(blockIndex: Int, text: String)
    case thinkingDelta(blockIndex: Int, text: String)
    /// Server-side refusal fallback switched models at this point of the stream.
    case fallback(from: String?, to: String?)
    /// A transient failure happened; the request is re-sent after `delay`.
    /// If `discardPartial` is true, content already delivered for this turn must be dropped.
    case retrying(attempt: Int, delay: Duration, reason: ClaudeError, discardPartial: Bool)
    case waitingForConnectivity
    /// Optional request features the API rejected; they are no longer sent
    /// (for the rest of the session unless `temporary`).
    case featuresDisabled(Set<OptionalFeature>, temporary: Bool)
    /// The API rejected replayed thinking blocks; the request was re-sent without any.
    /// Callers should drop thinking blocks from the stored history as well.
    case thinkingStripped
    case completed(FinalMessage)
}

public struct FinalMessage: Sendable, Hashable {
    public var id: String?
    public var model: String?
    public var content: [ContentBlock]
    public var stopReason: StopReason?
    public var stopDetails: StopDetails?
    public var usage: Usage
    public var requestID: String?

    public var servedByFallback: Bool {
        content.contains { if case .fallback = $0 { return true } else { return false } }
    }

    public var text: String {
        content.compactMap(\.text).joined()
    }
}

/// Builds the final message from stream events without quadratic string copies:
/// each block is a mutable builder whose strings grow in place.
public struct MessageAccumulator: Sendable {
    private enum Kind: Sendable {
        case text, thinking, redactedThinking, other
    }

    private struct Builder: Sendable {
        var kind: Kind
        var text = ""
        var signature = ""
        var opaque: ContentBlock?
    }

    public private(set) var id: String?
    public private(set) var model: String?
    public private(set) var stopReason: StopReason?
    public private(set) var stopDetails: StopDetails?
    public private(set) var usage = Usage()
    public private(set) var isComplete = false
    /// True once any text or thinking has been delivered to the consumer.
    public private(set) var hasContent = false

    private var builders: [Builder] = []
    private var positions: [Int: Int] = [:]

    public init() {}

    public mutating func apply(_ event: StreamEvent) -> [StreamUpdate] {
        switch event {
        case .messageStart(let payload):
            id = payload.id
            model = payload.model
            if let start = payload.usage { usage.merge(start) }
            return [.started(messageID: payload.id, model: payload.model)]

        case .contentBlockStart(let index, let block):
            var builder: Builder
            var updates: [StreamUpdate] = []
            switch block {
            case .text(let initial):
                builder = Builder(kind: .text, text: initial)
                if !initial.isEmpty {
                    hasContent = true
                    updates.append(.textDelta(blockIndex: index, text: initial))
                }
            case .thinking(let thinking, let signature):
                builder = Builder(kind: .thinking, text: thinking, signature: signature)
                if !thinking.isEmpty {
                    hasContent = true
                    updates.append(.thinkingDelta(blockIndex: index, text: thinking))
                }
            case .redactedThinking(let data):
                builder = Builder(kind: .redactedThinking, text: data)
            case .fallback(let from, let to):
                builder = Builder(kind: .other, opaque: block)
                if let to { model = to }
                updates.append(.fallback(from: from, to: to))
            case .unknown:
                builder = Builder(kind: .other, opaque: block)
            }
            positions[index] = builders.count
            builders.append(builder)
            return updates

        case .contentBlockDelta(let index, let delta):
            guard let position = positions[index] else { return [] }
            switch delta {
            case .text(let text):
                guard builders[position].kind == .text, !text.isEmpty else { return [] }
                builders[position].text.append(text)
                hasContent = true
                return [.textDelta(blockIndex: index, text: text)]
            case .thinking(let text):
                guard builders[position].kind == .thinking, !text.isEmpty else { return [] }
                builders[position].text.append(text)
                hasContent = true
                return [.thinkingDelta(blockIndex: index, text: text)]
            case .signature(let signature):
                guard builders[position].kind == .thinking else { return [] }
                builders[position].signature.append(signature)
                return []
            case .inputJSON, .other:
                return []
            }

        case .contentBlockStop:
            return []

        case .messageDelta(let payload):
            if let reason = payload.stopReason { stopReason = reason }
            if let details = payload.stopDetails { stopDetails = details }
            if let delta = payload.usage { usage.merge(delta) }
            return []

        case .messageStop:
            isComplete = true
            return []

        case .ping, .error, .unknown:
            return []
        }
    }

    public var content: [ContentBlock] {
        builders.map { builder in
            switch builder.kind {
            case .text: return .text(builder.text)
            case .thinking: return .thinking(thinking: builder.text, signature: builder.signature)
            case .redactedThinking: return .redactedThinking(data: builder.text)
            case .other: return builder.opaque ?? .unknown(type: "unknown")
            }
        }
    }

    public func finalMessage(requestID: String?) -> FinalMessage {
        FinalMessage(
            id: id,
            model: model,
            content: content,
            stopReason: stopReason,
            stopDetails: stopDetails,
            usage: usage,
            requestID: requestID
        )
    }
}
