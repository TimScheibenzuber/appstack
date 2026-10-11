import ClaudeKit
import Foundation
import Testing
@testable import Blitz

/// Transport that replays canned SSE bodies (one per request).
final class ScriptedTransport: StreamingTransport, @unchecked Sendable {
    enum Reply: Sendable {
        case stream(String)
        case status(Int, String)
        case hang
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var bodies: [Data] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func events(for request: URLRequest) -> AsyncThrowingStream<TransportEvent, any Error> {
        lock.lock()
        bodies.append(request.httpBody ?? Data())
        let reply = replies.isEmpty ? .status(500, "exhausted") : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .stream(let text):
                    continuation.yield(.response(HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"])))
                    continuation.yield(.data(Data(text.utf8)))
                case .status(let code, let body):
                    continuation.yield(.response(HTTPResponseHead(statusCode: code, headers: ["content-type": "application/json"])))
                    continuation.yield(.data(Data(body.utf8)))
                case .hang:
                    continuation.yield(.response(HTTPResponseHead(statusCode: 200, headers: ["content-type": "text/event-stream"])))
                    continuation.yield(.data(Data(Self.event("message_start", #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5"}}"#).utf8)))
                    continuation.yield(.data(Data(Self.event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#).utf8)))
                    continuation.yield(.data(Data(Self.event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Teil"}}"#).utf8)))
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func event(_ name: String, _ json: String) -> String {
        "event: \(name)\ndata: \(json)\n\n"
    }

    static func reply(_ text: String, stopReason: String = "end_turn", category: String? = nil) -> String {
        let details = category.map { #","stop_details":{"type":"refusal","category":"\#($0)"}"# } ?? ""
        return event("message_start", #"{"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":3}}}"#)
            + event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
            + event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#)
            + event("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
            + event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"\#(details)},"usage":{"output_tokens":5}}"#)
            + event("message_stop", #"{"type":"message_stop"}"#)
    }
}

@MainActor
final class FakeHost: ChatHost {
    let client: ClaudeClient
    var settings = AppSettings()
    private(set) var saved: [Conversation] = []

    init(transport: ScriptedTransport) {
        client = ClaudeClient(transport: transport, apiKeyProvider: { "sk-ant-test" }, sleep: { _ in })
    }

    func persist(_ conversation: Conversation) {
        saved.append(conversation)
    }
}

@MainActor
struct ChatViewModelTests {
    private func waitUntilIdle(_ chat: ChatViewModel) async {
        for _ in 0..<400 where chat.isBusy {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func sendStreamsAndPersistsReply() async {
        let transport = ScriptedTransport([.stream(ScriptedTransport.reply("Hallo!"))])
        let host = FakeHost(transport: transport)
        let chat = ChatViewModel(conversation: Conversation(systemPrompt: "kurz"), host: host)
        chat.draft = "  Hi  "
        chat.send()
        #expect(chat.draft.isEmpty)
        #expect(chat.isBusy)
        await waitUntilIdle(chat)

        let messages = chat.conversation.messages
        #expect(messages.count == 2)
        #expect(messages[0].text == "Hi")
        #expect(messages[1].text == "Hallo!")
        #expect(messages[1].status == .complete)
        #expect(messages[1].usage?.outputTokens == 5)
        #expect(chat.conversation.title == "Hi")
        #expect(host.saved.last?.messages.count == 2)
        #expect(chat.banner == nil)

        let body = try? JSONSerialization.jsonObject(with: transport.bodies[0]) as? [String: Any]
        #expect(body?["system"] as? String == "kurz")
    }

    @Test func refusalIsExcludedAndPromptReturned() async {
        let transport = ScriptedTransport([.stream(ScriptedTransport.reply("x", stopReason: "refusal", category: "cyber"))])
        let chat = ChatViewModel(conversation: Conversation(systemPrompt: nil), host: FakeHost(transport: transport))
        chat.draft = "Frage"
        chat.send()
        await waitUntilIdle(chat)
        let messages = chat.conversation.messages
        #expect(messages[1].status == .refused(category: "cyber"))
        #expect(messages[1].blocks.isEmpty)
        #expect(messages.allSatisfy(\.excludedFromContext))
        #expect(chat.draft == "Frage")
        #expect(chat.conversation.apiMessages().isEmpty)
    }

    @Test func failureShowsBannerAndIsNotReplayed() async {
        let transport = ScriptedTransport([.status(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        let chat = ChatViewModel(conversation: Conversation(systemPrompt: nil), host: FakeHost(transport: transport))
        chat.draft = "Hi"
        chat.send()
        await waitUntilIdle(chat)
        #expect(chat.banner?.kind == .missingKey)
        guard case .failed = chat.conversation.messages[1].status else {
            Issue.record("expected failed status")
            return
        }
        #expect(chat.conversation.apiMessages() == [Message.user("Hi")])
    }

    @Test func stopKeepsPartialText() async {
        let transport = ScriptedTransport([.hang])
        let chat = ChatViewModel(conversation: Conversation(systemPrompt: nil), host: FakeHost(transport: transport))
        chat.draft = "Hi"
        chat.send()
        for _ in 0..<200 where chat.live.text.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        chat.stop()
        await waitUntilIdle(chat)
        #expect(chat.conversation.messages.last?.status == .stopped)
        #expect(chat.conversation.messages.last?.text == "Teil")
    }

    @Test func editTruncatesHistory() async {
        let transport = ScriptedTransport([.stream(ScriptedTransport.reply("A"))])
        let chat = ChatViewModel(conversation: Conversation(systemPrompt: nil), host: FakeHost(transport: transport))
        chat.draft = "Erste"
        chat.send()
        await waitUntilIdle(chat)
        chat.edit(chat.conversation.messages[0].id)
        #expect(chat.conversation.messages.isEmpty)
        #expect(chat.draft == "Erste")
    }

    @Test func restoresInterruptedTurnsOnLoad() {
        var conversation = Conversation(systemPrompt: nil)
        conversation.messages = [
            ChatMessage(role: .user, blocks: [.text("Q")]),
            ChatMessage(role: .assistant, blocks: [], status: .streaming),
        ]
        let chat = ChatViewModel(conversation: conversation, host: FakeHost(transport: ScriptedTransport([])))
        #expect(chat.conversation.messages[1].status == .failed(message: "Unterbrochen"))
        #expect(!chat.isBusy)
    }
}

struct ConversationStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func savesLoadsAndDeletes() async throws {
        let store = ConversationStore(directory: temporaryDirectory())
        var conversation = Conversation(systemPrompt: "s")
        conversation.messages = [ChatMessage(role: .user, blocks: [.text("Hallo")])]
        try await store.save(conversation)
        #expect(await store.load(conversation.id) == conversation)
        #expect(await store.summaries().map(\.title) == ["Hallo"])
        try await store.delete(conversation.id)
        #expect(await store.load(conversation.id) == nil)
        #expect(await store.summaries().isEmpty)
    }

    @Test func rebuildsDamagedIndexAndQuarantinesCorruptFiles() async throws {
        let directory = temporaryDirectory()
        var conversation = Conversation(systemPrompt: nil)
        conversation.messages = [ChatMessage(role: .user, blocks: [.text("Bleibt")])]
        try await ConversationStore(directory: directory).save(conversation)

        try Data("kaputt".utf8).write(to: directory.appendingPathComponent("index.json"))
        let corrupt = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{".utf8).write(to: corrupt)

        let reopened = ConversationStore(directory: directory)
        #expect(await reopened.summaries().map(\.id) == [conversation.id])
        #expect(FileManager.default.fileExists(atPath: corrupt.path + ".corrupt"))
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
    }
}
