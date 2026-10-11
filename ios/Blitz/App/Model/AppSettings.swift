import ClaudeKit
import Foundation

/// Non-secret preferences (the API key lives in the Keychain, never here).
struct AppSettings: Codable, Equatable, Sendable {
    var modelID: String = ModelCatalog.defaultModel.id
    /// Low effort keeps time-to-first-token short; raise it for hard problems.
    var effort: Effort = .low
    /// Up to ~2.5x faster output on Claude Opus 5.5 at twice the token price.
    var fastMode: Bool = true
    /// Streams a readable summary of the model's reasoning instead of a silent pause.
    var showThinking: Bool = true
    var maxTokens: Int = 64_000
    /// Applied to new conversations only (an existing conversation keeps its prompt frozen).
    var systemPrompt: String = ""

    var model: ModelInfo { ModelCatalog.info(for: modelID) }

    private static let storageKey = "settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // Tolerant decoding: settings written by an older version never reset everything.
    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        modelID = (try? container.decode(String.self, forKey: .modelID)) ?? defaults.modelID
        effort = (try? container.decode(Effort.self, forKey: .effort)) ?? defaults.effort
        fastMode = (try? container.decode(Bool.self, forKey: .fastMode)) ?? defaults.fastMode
        showThinking = (try? container.decode(Bool.self, forKey: .showThinking)) ?? defaults.showThinking
        maxTokens = (try? container.decode(Int.self, forKey: .maxTokens)) ?? defaults.maxTokens
        systemPrompt = (try? container.decode(String.self, forKey: .systemPrompt)) ?? defaults.systemPrompt
    }
}
