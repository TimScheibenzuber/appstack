import Foundation

/// Open set of stop reasons; unknown values survive decoding instead of failing the stream.
public struct StopReason: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let endTurn = StopReason(rawValue: "end_turn")
    public static let maxTokens = StopReason(rawValue: "max_tokens")
    public static let stopSequence = StopReason(rawValue: "stop_sequence")
    public static let toolUse = StopReason(rawValue: "tool_use")
    public static let pauseTurn = StopReason(rawValue: "pause_turn")
    public static let refusal = StopReason(rawValue: "refusal")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Populated only for `stop_reason == "refusal"`. Informational - branch on the stop reason.
public struct StopDetails: Codable, Sendable, Hashable {
    public var type: String?
    public var category: String?
    public var explanation: String?
    public var recommendedModel: String?

    public init(type: String? = nil, category: String? = nil, explanation: String? = nil, recommendedModel: String? = nil) {
        self.type = type
        self.category = category
        self.explanation = explanation
        self.recommendedModel = recommendedModel
    }

    private enum CodingKeys: String, CodingKey {
        case type, category, explanation
        case recommendedModel = "recommended_model"
    }
}

public struct Usage: Codable, Sendable, Hashable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var cacheReadInputTokens: Int?
    public var speed: String?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        speed: String? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.speed = speed
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case speed
    }

    /// `message_delta` carries cumulative counts; later non-nil values win.
    public mutating func merge(_ other: Usage) {
        inputTokens = other.inputTokens ?? inputTokens
        outputTokens = other.outputTokens ?? outputTokens
        cacheCreationInputTokens = other.cacheCreationInputTokens ?? cacheCreationInputTokens
        cacheReadInputTokens = other.cacheReadInputTokens ?? cacheReadInputTokens
        speed = other.speed ?? speed
    }
}

public enum Effort: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    public var id: String { rawValue }
}

public enum ThinkingDisplay: String, Codable, Sendable, Hashable, CaseIterable {
    /// Readable summary of the reasoning streams to the client.
    case summarized
    /// Thinking happens (and is billed) but its text is not returned.
    case omitted
}

/// Static knowledge about the models this app offers. Capabilities gate which optional
/// request features are sent, so a model never receives a parameter it rejects.
public struct ModelInfo: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let supportsFastMode: Bool
    public let supportsDefaultFallback: Bool
    public let maxOutputTokens: Int

    public init(id: String, displayName: String, supportsFastMode: Bool, supportsDefaultFallback: Bool, maxOutputTokens: Int) {
        self.id = id
        self.displayName = displayName
        self.supportsFastMode = supportsFastMode
        self.supportsDefaultFallback = supportsDefaultFallback
        self.maxOutputTokens = maxOutputTokens
    }
}

public enum ModelCatalog {
    public static let opus55 = ModelInfo(
        id: "claude-opus-5-5", displayName: "Claude Opus 5.5",
        supportsFastMode: true, supportsDefaultFallback: true, maxOutputTokens: 128_000
    )
    public static let sonnet55 = ModelInfo(
        id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5",
        supportsFastMode: false, supportsDefaultFallback: true, maxOutputTokens: 128_000
    )
    public static let haiku55 = ModelInfo(
        id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
        supportsFastMode: false, supportsDefaultFallback: false, maxOutputTokens: 128_000
    )

    public static let all: [ModelInfo] = [opus55, sonnet55, haiku55]
    public static let defaultModel = opus55

    public static func info(for id: String) -> ModelInfo {
        all.first { $0.id == id }
            ?? ModelInfo(id: id, displayName: id, supportsFastMode: false, supportsDefaultFallback: false, maxOutputTokens: 32_000)
    }
}
