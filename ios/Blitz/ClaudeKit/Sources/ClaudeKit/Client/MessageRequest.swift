import Foundation

/// Request features that improve speed or resilience but are not essential. If the API rejects
/// one (e.g. a research-preview beta not enabled for the organization), the client drops it
/// and retries instead of failing the user's message.
public enum OptionalFeature: String, Sendable, Hashable, CaseIterable, Codable {
    /// `speed: "fast"` (beta `fast-mode-2026-02-01`): up to ~2.5x output speed at premium price.
    case fastMode
    /// `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`): a classifier refusal is
    /// re-run server-side on the recommended fallback model inside the same stream.
    case refusalFallback
    /// `thinking.display: "summarized"`: stream readable reasoning instead of a silent pause.
    case thinkingSummary
    /// Top-level automatic prompt caching: the growing conversation prefix is served from
    /// cache, cutting time-to-first-token and input cost on every follow-up turn.
    case promptCaching
    /// Explicit `output_config.effort`.
    case effort

    var betaHeader: String? {
        switch self {
        case .fastMode: return "fast-mode-2026-02-01"
        case .refusalFallback: return "server-side-fallback-2026-07-01"
        case .thinkingSummary, .promptCaching, .effort: return nil
        }
    }
}

public struct MessageRequest: Sendable, Hashable {
    public var model: String
    public var maxTokens: Int
    /// Frozen per conversation: changing it mid-conversation would invalidate the prompt
    /// cache and every replayed thinking block.
    public var system: String?
    public var messages: [Message]
    public var effort: Effort
    public var features: Set<OptionalFeature>

    public init(
        model: String,
        maxTokens: Int,
        system: String?,
        messages: [Message],
        effort: Effort,
        features: Set<OptionalFeature>
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.effort = effort
        self.features = features
    }

    /// Builds a request for a catalog model, enabling only the features that model supports.
    public static func make(
        model: ModelInfo,
        system: String?,
        messages: [Message],
        effort: Effort,
        maxTokens: Int,
        fastMode: Bool,
        showThinking: Bool
    ) -> MessageRequest {
        var features: Set<OptionalFeature> = [.promptCaching, .effort]
        if fastMode && model.supportsFastMode { features.insert(.fastMode) }
        if model.supportsDefaultFallback { features.insert(.refusalFallback) }
        if showThinking { features.insert(.thinkingSummary) }
        return MessageRequest(
            model: model.id,
            maxTokens: min(max(maxTokens, 1), model.maxOutputTokens),
            system: system,
            messages: messages,
            effort: effort,
            features: features
        )
    }
}

/// Serializes requests deterministically (sorted keys) so identical histories produce
/// byte-identical bodies - a prerequisite for prompt-cache hits.
enum RequestEncoder {
    private struct Body: Encodable {
        struct Thinking: Encodable {
            let type = "adaptive"
            let display: String?
        }
        struct OutputConfig: Encodable {
            let effort: String
        }
        struct CacheControl: Encodable {
            let type = "ephemeral"
        }

        let model: String
        let maxTokens: Int
        let stream = true
        let system: String?
        let messages: [Message]
        let thinking: Thinking
        let outputConfig: OutputConfig?
        let cacheControl: CacheControl?
        let speed: String?
        let fallbacks: String?

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages, thinking, speed, fallbacks
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
            case cacheControl = "cache_control"
        }
    }

    static func encode(_ request: MessageRequest, messages: [Message], features: Set<OptionalFeature>) throws -> (body: Data, betas: [String]) {
        let system = request.system?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(
            model: request.model,
            maxTokens: request.maxTokens,
            system: (system?.isEmpty ?? true) ? nil : system,
            messages: messages,
            thinking: Body.Thinking(display: features.contains(.thinkingSummary) ? ThinkingDisplay.summarized.rawValue : nil),
            outputConfig: features.contains(.effort) ? Body.OutputConfig(effort: request.effort.rawValue) : nil,
            cacheControl: features.contains(.promptCaching) ? Body.CacheControl() : nil,
            speed: features.contains(.fastMode) ? "fast" : nil,
            fallbacks: features.contains(.refusalFallback) ? "default" : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(body)
        let betas = OptionalFeature.allCases.filter(features.contains).compactMap(\.betaHeader)
        return (data, betas)
    }
}

enum FeatureNegotiator {
    /// Decides which active optional features to drop after a 400 response.
    /// Returns an empty set when the error is not attributable to an optional feature.
    static func featuresToDisable(forMessage message: String, active: Set<OptionalFeature>) -> Set<OptionalFeature> {
        let lower = message.lowercased()
        var result: Set<OptionalFeature> = []
        if lower.contains("fast-mode") || lower.contains("speed") { result.insert(.fastMode) }
        if lower.contains("fallback") { result.insert(.refusalFallback) }
        if lower.contains("display") { result.insert(.thinkingSummary) }
        if lower.contains("cache_control") { result.insert(.promptCaching) }
        if lower.contains("effort") || lower.contains("output_config") { result.insert(.effort) }
        if result.isDisjoint(with: active), lower.contains("anthropic-beta") {
            // Unknown or disabled beta value without a recognizable name: drop every beta.
            result.formUnion(OptionalFeature.allCases.filter { $0.betaHeader != nil })
        }
        return result.intersection(active)
    }
}
