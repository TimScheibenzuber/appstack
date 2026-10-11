import ClaudeKit
import Foundation
import Observation
import os
import SwiftUI

/// Root state: settings, API key, conversation list and the shared API client.
@MainActor
@Observable
final class AppModel: ChatHost {
    private static let log = Logger(subsystem: "com.appstack.blitz", category: "app")

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            // A changed configuration deserves a fresh attempt at features rejected earlier.
            if settings.modelID != oldValue.modelID || settings.fastMode != oldValue.fastMode {
                Task { await client.resetFeatureNegotiation() }
            }
        }
    }

    private(set) var summaries: [ConversationSummary] = []
    var selectedID: UUID?
    private(set) var hasAPIKey = false
    private(set) var isOnline = true
    private(set) var storageError: String?

    let client: ClaudeClient
    @ObservationIgnored private let vault: APIKeyVault
    @ObservationIgnored private let store: ConversationStore
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var chats: [UUID: ChatViewModel] = [:]
    @ObservationIgnored private var didStart = false
    /// Storage operations run strictly in submission order (a later save never loses
    /// against an earlier one).
    @ObservationIgnored private var storageQueue: Task<Void, Never>?

    init(
        store: ConversationStore = ConversationStore(directory: ConversationStore.defaultDirectory()),
        keychain: KeychainStore = KeychainStore(service: "com.appstack.blitz", account: "anthropic-api-key")
    ) {
        let vault = APIKeyVault(keychain: keychain)
        let network = NetworkMonitor()
        self.vault = vault
        self.store = store
        self.network = network
        self.settings = AppSettings.load()
        self.client = ClaudeClient(
            transport: URLSessionTransport(),
            connectivity: network,
            apiKeyProvider: { try await vault.key() }
        )
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        network.start { [weak self] connected in
            Task { @MainActor in self?.isOnline = connected }
        }
        hasAPIKey = ((try? await vault.key()) ?? nil)?.isEmpty == false
        summaries = await store.summaries()
        if hasAPIKey { await client.prewarm() }
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            if hasAPIKey { Task { await client.prewarm() } }
        case .background:
            for chat in chats.values { chat.persistNow() }
        default:
            break
        }
    }

    // MARK: - API key

    func saveAPIKey(_ rawKey: String) async throws -> APIKeyCheck {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let check = try await client.validate(apiKey: key)
        if case .valid = check {
            try await vault.store(key)
            hasAPIKey = true
            await client.resetFeatureNegotiation()
        }
        return check
    }

    func removeAPIKey() async {
        do {
            try await vault.remove()
            hasAPIKey = false
        } catch {
            Self.log.error("Removing API key failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Conversations

    func chat(for id: UUID) -> ChatViewModel? {
        chats[id]
    }

    /// Loads (once) and returns the view model for a conversation. View models are cached so
    /// a reply keeps streaming while the user looks at another conversation.
    func openChat(_ id: UUID) async -> ChatViewModel? {
        if let existing = chats[id] { return existing }
        guard let conversation = await store.load(id) else {
            summaries.removeAll { $0.id == id }
            return nil
        }
        if let existing = chats[id] { return existing }
        let chat = ChatViewModel(conversation: conversation, host: self)
        chats[id] = chat
        return chat
    }

    @discardableResult
    func newConversation() -> UUID {
        if let current = selectedID, let chat = chats[current], chat.conversation.messages.isEmpty {
            return current // reuse an untouched empty chat instead of piling up blanks
        }
        let prompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = Conversation(systemPrompt: prompt.isEmpty ? nil : prompt)
        chats[conversation.id] = ChatViewModel(conversation: conversation, host: self)
        selectedID = conversation.id
        return conversation.id
    }

    func deleteConversations(_ ids: [UUID]) {
        for id in ids {
            chats[id]?.stop()
            chats[id] = nil
            summaries.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        }
        let store = store
        enqueueStorage { for id in ids { try await store.delete(id) } }
    }

    /// Called by a chat whenever its conversation reached a state worth saving.
    func persist(_ conversation: Conversation) {
        // Ignore late saves from a chat that was deleted meanwhile (no resurrection).
        guard !conversation.messages.isEmpty, chats[conversation.id] != nil else { return }
        let summary = ConversationSummary(conversation)
        if let index = summaries.firstIndex(where: { $0.id == summary.id }) {
            if summaries[index] != summary {
                summaries[index] = summary
                summaries.sort { $0.updatedAt > $1.updatedAt }
            }
        } else {
            summaries.insert(summary, at: 0)
        }
        let store = store
        enqueueStorage { try await store.save(conversation) }
    }

    private func enqueueStorage(_ operation: @escaping @Sendable () async throws -> Void) {
        let previous = storageQueue
        storageQueue = Task { [weak self] in
            await previous?.value
            do {
                try await operation()
            } catch {
                self?.report(error)
            }
        }
    }

    private func report(_ error: any Error) {
        Self.log.error("Storage error: \(error.localizedDescription, privacy: .public)")
        storageError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
    }

    func clearStorageError() {
        storageError = nil
    }
}
