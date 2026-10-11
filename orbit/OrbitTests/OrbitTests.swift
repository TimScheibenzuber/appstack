import Foundation
import Testing
@testable import Orbit

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "orbit-test-\(UUID().uuidString)", directoryHint: .isDirectory)
}

struct VaultTests {
    @Test func itemsAreEncryptedAndRoundTrip() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir, password: "correct horse", rounds: 1_000)
        let item = Item(kind: .note, title: "Secret plan", body: "Launch on Monday")
        try vault.save(item)

        let raw = try Data(contentsOf: vault.url(for: item.id))
        #expect(raw.range(of: Data("Secret plan".utf8)) == nil)

        let reopened = try Vault.open(at: dir, password: "correct horse")
        #expect(reopened.listing()[item.id] != nil)
        #expect(reopened.load([item.id]).first == item)
    }

    @Test func wrongPasswordAndWrongKeyAreRejected() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Vault.create(at: dir, password: "correct horse", rounds: 1_000)
        #expect(throws: VaultError.self) { try Vault.open(at: dir, password: "wrong horse") }
        #expect(throws: (any Error).self) { try Vault.open(at: dir, key: Data(repeating: 7, count: 32)) }
    }

    @Test func changingPasswordKeepsData() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir, password: "first secret", rounds: 1_000)
        let item = Item(kind: .question, title: "Why?")
        try vault.save(item)
        try vault.changePassword("second secret")
        #expect(throws: VaultError.self) { try Vault.open(at: dir, password: "first secret") }
        #expect(try Vault.open(at: dir, password: "second secret").load([item.id]).first?.title == "Why?")
    }

    @Test func blobsDecryptToTheOriginalBytes() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir, password: "correct horse", rounds: 1_000)
        let source = dir.appending(path: "report.txt")
        try Data("quarterly numbers".utf8).write(to: source)
        let id = UUID()
        try vault.storeBlob(from: source, id: id)
        let out = try vault.exportBlob(id, name: "report.txt")
        #expect(try String(contentsOf: out, encoding: .utf8) == "quarterly numbers")
        Vault.wipeTemp()
    }
}

struct ImportTests {
    @Test func claudeExport() throws {
        let json = """
        [{"uuid": "1", "name": "Trip planning", "created_at": "2026-03-05T10:30:00.123456Z",
          "chat_messages": [
            {"sender": "human", "text": "Where should I go?"},
            {"sender": "assistant", "text": "", "content": [{"type": "text", "text": "Try Lisbon."}]}
          ]}]
        """
        let items = Importer.chats(from: Data(json.utf8))
        #expect(items.count == 1)
        #expect(items[0].title == "Trip planning")
        #expect(items[0].kind == .chat)
        let turns = Importer.turns(in: items[0].body)
        #expect(turns.map(\.role) == [.user, .assistant])
        #expect(turns.last?.text == "Try Lisbon.")
        #expect(Calendar.current.component(.year, from: items[0].created) == 2026)
    }

    @Test func chatGPTExportFollowsTheActiveBranch() throws {
        let json = """
        [{"title": "Recipe", "create_time": 1700000000, "current_node": "c",
          "mapping": {
            "root": {"message": null, "parent": null},
            "a": {"message": {"author": {"role": "user"}, "content": {"parts": ["Pasta idea?"]}}, "parent": "root"},
            "old": {"message": {"author": {"role": "assistant"}, "content": {"parts": ["Discarded draft"]}}, "parent": "a"},
            "c": {"message": {"author": {"role": "assistant"}, "content": {"parts": ["Cacio e pepe."]}}, "parent": "a"}
          }}]
        """
        let items = Importer.chats(from: Data(json.utf8))
        #expect(items.first?.title == "Recipe")
        let turns = Importer.turns(in: items.first?.body ?? "")
        #expect(turns.map(\.text) == ["Pasta idea?", "Cacio e pepe."])
    }

    @Test func pastedTranscripts() {
        let turns = Importer.turns(in: "User: hi there\n**Claude:** hello\nsecond line\n\n### You\nthanks")
        #expect(turns.map(\.role) == [.user, .assistant, .user])
        #expect(turns[1].text == "hello\nsecond line")
        #expect(Importer.turns(in: Importer.transcript(turns)) == turns)
    }

    @Test func plainJSONIsNotAChat() {
        #expect(Importer.chats(from: Data(#"{"name": "config", "debug": true}"#.utf8)).isEmpty)
    }
}

struct LayoutTests {
    @Test func mindmapBranchesAlternateSides() {
        let root = MindNode(text: "Root")
        let children = (0..<4).map { MindNode(text: "Child \($0)", parent: root.id) }
        let layout = MindLayout([root] + children)
        let rootX = layout.points[root.id]!.x
        let right = children.filter { layout.points[$0.id]!.x > rootX }
        #expect(right.count == 2)
        #expect(layout.links.count == 4)
        #expect(Set(children.map { layout.branch[$0.id]! }).count == 4)
    }

    @Test func itemTextFeedsSearch() {
        var item = Item(kind: .note, title: "Budget", body: "Q3 marketing spend")
        item.tags = ["finance"]
        #expect(item.matches("marketing q3"))
        #expect(item.matches("finance"))
        #expect(!item.matches("roadmap"))
    }
}
