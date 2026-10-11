import ClaudeKit
import Foundation
import Observation
import os

@MainActor
protocol ChatHost: AnyObject {
    var client: ClaudeClient { get }
    var settings: AppSettings { get }
    func persist(_ conversation: Conversation)
}

/// The reply that is currently streaming. Kept separate from `Conversation` so a token only
/// invalidates the one row that shows it, not the whole message list.
@MainActor
@Observable
final class LiveReply {
    @ObservationIgnored fileprivate(set) var text = ""
    /// Finished Markdown blocks; never change once produced, so their views are not redrawn.
    private(set) var stableBlocks: [MarkdownBlock] = []
    /// The block(s) still growing.
    private(set) var tailBlocks: [MarkdownBlock] = []
    fileprivate(set) var thinking = ""
    fileprivate(set) var model: String?
    fileprivate(set) var notice: String?
    /// Bumped on every visible change; cheap to observe for auto-scrolling.
    private(set) var revision = 0
    @ObservationIgnored private var splitter = MarkdownBlockSplitter()

    var hasContent: Bool { !text.isEmpty || !thinking.isEmpty }

    fileprivate func append(text delta: String) {
        text += delta
        splitter.update(text)
        if splitter.stableBlocks.count != stableBlocks.count {
            stableBlocks = splitter.stableBlocks
        }
        tailBlocks = splitter.tailBlocks
        revision &+= 1
    }

    fileprivate func append(thinking delta: String) {
        thinking += delta
        revision &+= 1
    }

    fileprivate func reset(model: String?) {
        text = ""
        splitter = MarkdownBlockSplitter()
        stableBlocks = []
        tailBlocks = []
        thinking = ""
        notice = nil
        self.model = model
        revision &+= 1
    }
}

@MainActor
@Observable
final class ChatViewModel: Identifiable {
    enum Activity: Equatable {
        case idle
        case connecting
        case streaming
        case waitingForNetwork
        case retrying(attempt: Int)
    }

    struct Banner: Equatable, Identifiable {
        enum Kind: Equatable {
            case info
            case error
            case missingKey
            /// A refusal the server-side fallback could not rescue; the API named a model to retry on.
            case retryWithModel(String)
        }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    private static let log = Logger(subsystem: "com.appstack.blitz", category: "chat")
    /// ~30 fps: smooth to the eye, far fewer layout passes than one per token.
    private static let flushInterval: Duration = .milliseconds(33)

    private(set) var conversation: Conversation
    var draft = ""
    private(set) var activity: Activity = .idle
    private(set) var banner: Banner?
    let live = LiveReply()

    nonisolated let id: UUID
    @ObservationIgnored private weak var host: (any ChatHost)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var pendingThinking = ""
    @ObservationIgnored private var flushScheduled = false
    /// The last turn failed for lack of network; it is re-sent once the network returns.
    @ObservationIgnored private(set) var awaitsNetwork = false

    init(conversation: Conversation, host: any ChatHost) {
        var restored = conversation
        // A turn that was streaming when the app was terminated cannot be resumed.
        for index in restored.messages.indices where restored.messages[index].status == .streaming {
            if restored.messages[index].text.isEmpty {
                restored.messages[index].status = .failed(message: "Unterbrochen")
                restored.messages[index].excludedFromContext = true
            } else {
                restored.messages[index].status = .stopped
            }
        }
        self.conversation = restored
        self.id = conversation.id
        self.host = host
    }

    /// Derived from the observed `activity` so views update when a turn starts or ends.
    var isBusy: Bool { activity != .idle }

    var canSend: Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var lastAssistantID: UUID? {
        conversation.messages.last { $0.role == .assistant }?.id
    }

    // MARK: - Actions

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        draft = ""
        banner = nil
        conversation.messages.append(ChatMessage(role: .user, blocks: [.text(text)]))
        if conversation.title.isEmpty {
            conversation.title = Conversation.makeTitle(from: text)
        }
        startTurn()
    }

    func stop() {
        streamTask?.cancel()
    }

    /// Re-runs the last turn after a failure or refusal, or to get a different answer.
    /// `modelID` overrides the configured model for this one turn.
    func regenerate(modelID: String? = nil) {
        guard !isBusy else { return }
        while let last = conversation.messages.last, last.role == .assistant {
            conversation.messages.removeLast()
        }
        guard let index = conversation.messages.indices.last,
              conversation.messages[index].role == .user else { return }
        // Retrying is an explicit request to send this prompt again (e.g. after a refusal).
        if conversation.messages[index].excludedFromContext {
            conversation.messages[index].excludedFromContext = false
            if draft == conversation.messages[index].text { draft = "" }
        }
        banner = nil
        awaitsNetwork = false
        startTurn(modelID: modelID)
    }

    /// Called when connectivity returns.
    func networkRestored() {
        guard awaitsNetwork, !isBusy else { return }
        regenerate()
    }

    /// Puts a sent message back into the composer and removes it and everything after it.
    /// Truncating keeps the remaining history byte-identical (cache and thinking stay valid).
    func edit(_ messageID: UUID) {
        guard !isBusy, let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == .user else { return }
        draft = conversation.messages[index].text
        conversation.messages.removeSubrange(index...)
        banner = nil
        persistNow()
    }

    func dismissBanner() {
        banner = nil
    }

    func persistNow() {
        host?.persist(conversation)
    }

    /// Opens the connection while the user is still typing.
    func userIsTyping() {
        guard let client = host?.client else { return }
        Task { await client.prewarm() }
    }

    // MARK: - Streaming

    private func startTurn(modelID: String? = nil) {
        guard let host else { return }
        let settings = host.settings
        let model = modelID.map(ModelCatalog.info(for:)) ?? settings.model
        let history = conversation.apiMessages()
        // Invariant: a request must end with the user's turn (no prefill on current models).
        guard history.last?.role == .user else {
            banner = Banner(kind: .error, text: "Es gibt keine Nachricht zum Senden.")
            persistNow()
            return
        }
        let request = MessageRequest.make(
            model: model,
            system: conversation.systemPrompt,
            messages: history,
            effort: settings.effort,
            maxTokens: settings.maxTokens,
            fastMode: settings.fastMode,
            showThinking: settings.showThinking
        )
        let placeholder = ChatMessage(role: .assistant, blocks: [], status: .streaming, model: model.id)
        conversation.messages.append(placeholder)
        conversation.updatedAt = Date()
        live.reset(model: model.id)
        pendingText = ""
        pendingThinking = ""
        activity = .connecting
        persistNow()

        let client = host.client
        let messageID = placeholder.id
        streamTask = Task { [weak self] in
            let background = BackgroundActivity(name: "claude-reply")
            defer { background.end() }
            do {
                for try await update in client.stream(request) {
                    guard let self else { return }
                    self.handle(update, messageID: messageID)
                }
                // Cancelling the consumer ends the loop without a completion event.
                if Task.isCancelled { self?.finishStopped(messageID) }
            } catch is CancellationError {
                self?.finishStopped(messageID)
            } catch {
                self?.finishFailed(messageID, error: error)
            }
            self?.streamTask = nil
            self?.activity = .idle
        }
    }

    private func handle(_ update: StreamUpdate, messageID: UUID) {
        switch update {
        case .started(_, let model):
            activity = .streaming
            if let model { live.model = model }
        case .textDelta(_, let text):
            pendingText += text
            scheduleFlush()
        case .thinkingDelta(_, let text):
            pendingThinking += text
            scheduleFlush()
        case .fallback(_, let to):
            live.notice = "Fortgesetzt mit \(to.map(ModelCatalog.info(for:))?.displayName ?? "Fallback-Modell")"
        case .retrying(let attempt, _, let reason, let discardPartial):
            Self.log.info("Retry \(attempt) after \(String(describing: reason), privacy: .public)")
            if discardPartial {
                pendingText = ""
                pendingThinking = ""
                live.reset(model: live.model)
            }
            activity = .retrying(attempt: attempt)
        case .waitingForConnectivity:
            activity = .waitingForNetwork
        case .featuresDisabled(let features, let temporary):
            if features.contains(.fastMode) {
                banner = Banner(kind: .info, text: temporary
                    ? "Fast-Mode-Limit erreicht – diese Antwort kommt in Standard-Geschwindigkeit."
                    : "Fast Mode ist für diesen API-Key nicht verfügbar – Standard-Geschwindigkeit wird genutzt.")
            }
        case .thinkingStripped:
            for index in conversation.messages.indices where conversation.messages[index].id != messageID {
                conversation.messages[index].blocks.removeAll(where: \.isThinking)
            }
        case .completed(let final):
            finishCompleted(messageID, final: final)
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // The very first token is shown immediately; later ones are batched per frame.
        let isFirst = !live.hasContent
        Task { [weak self] in
            if !isFirst { try? await Task.sleep(for: Self.flushInterval) }
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        if !pendingThinking.isEmpty {
            live.append(thinking: pendingThinking)
            pendingThinking = ""
        }
        if !pendingText.isEmpty {
            live.append(text: pendingText)
            pendingText = ""
        }
    }

    private func finishCompleted(_ messageID: UUID, final: FinalMessage) {
        flush()
        guard let index = streamingIndex(messageID) else { return }
        var message = conversation.messages[index]
        message.blocks = final.content
        message.model = final.model ?? message.model
        message.usage = final.usage
        switch final.stopReason {
        case .refusal?:
            // A declined turn is shown but never replayed; the prompt goes back to the composer.
            message.status = .refused(category: final.stopDetails?.category)
            message.blocks = []
            message.excludedFromContext = true
            if index > 0, conversation.messages[index - 1].role == .user {
                conversation.messages[index - 1].excludedFromContext = true
                if draft.isEmpty { draft = conversation.messages[index - 1].text }
            }
            if let recommended = final.stopDetails?.recommendedModel, !recommended.isEmpty {
                banner = Banner(
                    kind: .retryWithModel(recommended),
                    text: "Abgelehnt. Mit \(ModelCatalog.info(for: recommended).displayName) erneut versuchen?"
                )
            }
        case .maxTokens?:
            message.status = .truncated
        default:
            message.status = .complete
        }
        conversation.messages[index] = message
        conversation.updatedAt = Date()
        live.reset(model: nil)
        persistNow()
    }

    /// Index of the placeholder for `messageID` while it is still streaming. Guards against
    /// late events (e.g. a stop tap racing the final event) overwriting a finished turn.
    private func streamingIndex(_ messageID: UUID) -> Int? {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].status == .streaming else { return nil }
        return index
    }

    private func finishStopped(_ messageID: UUID) {
        flush()
        guard let index = streamingIndex(messageID) else { return }
        if live.text.isEmpty {
            conversation.messages.remove(at: index)
        } else {
            conversation.messages[index].blocks = [.text(live.text)]
            conversation.messages[index].status = .stopped
        }
        live.reset(model: nil)
        persistNow()
    }

    private func finishFailed(_ messageID: UUID, error: any Error) {
        flush()
        let presentation = ErrorPresentation(error)
        Self.log.error("Turn failed: \(presentation.logDescription, privacy: .public)")
        guard let index = streamingIndex(messageID) else { return }
        conversation.messages[index].blocks = live.text.isEmpty ? [] : [.text(live.text)]
        conversation.messages[index].status = .failed(message: presentation.message)
        // A broken partial reply is shown but not replayed as if it were Claude's answer.
        conversation.messages[index].excludedFromContext = true
        awaitsNetwork = presentation.isConnectivityLoss
        let text = awaitsNetwork
            ? "\(presentation.message) Wird automatisch erneut gesendet, sobald das Netz zurück ist."
            : presentation.message
        banner = Banner(kind: presentation.isMissingKey ? .missingKey : .error, text: text)
        live.reset(model: nil)
        persistNow()
    }
}
