import Foundation
import Testing
@testable import ClaudeKit

struct SSEParserTests {
    private func parseAll(_ chunks: [Data]) throws -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in chunks { events += try parser.feed(chunk) }
        return events
    }

    private func string(_ event: SSEEvent) -> String {
        String(decoding: event.data, as: UTF8.self)
    }

    @Test func parsesBasicEvents() throws {
        let stream = "event: message_start\ndata: {\"a\":1}\n\nevent: ping\ndata: {}\n\n"
        let events = try parseAll([Data(stream.utf8)])
        #expect(events.count == 2)
        #expect(events[0].event == "message_start")
        #expect(string(events[0]) == "{\"a\":1}")
        #expect(events[1].event == "ping")
    }

    @Test func everySplitPointYieldsIdenticalEvents() throws {
        let stream = "event: a\r\ndata: héllo 👋\r\n\r\n: keep-alive\n\nevent: b\rdata: x\rdata: y\r\rdata:z\n\n"
        let bytes = Array(stream.utf8)
        let expected = try parseAll([Data(bytes)])
        #expect(expected.map(string) == ["héllo 👋", "x\ny", "z"])
        #expect(expected.map(\.event) == ["a", "b", nil])

        for split in 0...bytes.count {
            let chunks = [Data(bytes[..<split]), Data(bytes[split...])]
            #expect(try parseAll(chunks) == expected, "split at \(split)")
        }
        for first in stride(from: 0, through: bytes.count, by: 3) {
            for second in stride(from: first, through: bytes.count, by: 5) {
                let chunks = [Data(bytes[..<first]), Data(bytes[first..<second]), Data(bytes[second...])]
                #expect(try parseAll(chunks) == expected)
            }
        }
        // Byte-by-byte delivery.
        #expect(try parseAll(bytes.map { Data([$0]) }) == expected)
    }

    @Test func crlfSplitAcrossChunksIsOneTerminator() throws {
        let events = try parseAll([Data("data: 1\r".utf8), Data("\n\r".utf8), Data("\ndata: 2\n\n".utf8)])
        #expect(events.map(string) == ["1", "2"])
    }

    @Test func handlesFieldsWithoutSpaceOrValue() throws {
        let events = try parseAll([Data("data:no-space\n\ndata\n\nevent\ndata: x\n\n".utf8)])
        #expect(events.map(string) == ["no-space", "", "x"])
        #expect(events[2].event == "")
    }

    @Test func ignoresUnknownFieldsAndEmptyEvents() throws {
        let events = try parseAll([Data("id: 7\nretry: 100\n\nevent: only-name\n\nfoo: bar\ndata: ok\n\n".utf8)])
        #expect(events.count == 1)
        #expect(string(events[0]) == "ok")
        #expect(events[0].event == nil)
    }

    @Test func stripsLeadingByteOrderMarkOnlyAtStart() throws {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes += Array("data: a\n\n".utf8)
        let events = try parseAll([Data(bytes[..<2]), Data(bytes[2...])])
        #expect(events.map(string) == ["a"])
    }

    @Test func doesNotDispatchIncompleteTrailingEvent() throws {
        let events = try parseAll([Data("data: done\n\ndata: partial".utf8)])
        #expect(events.map(string) == ["done"])
    }

    @Test func enforcesEventSizeLimit() throws {
        var parser = SSEParser(maxEventBytes: 32)
        let line = "data: " + String(repeating: "x", count: 64) + "\n\n"
        #expect(throws: SSEParserError.eventTooLarge(limit: 32)) {
            _ = try parser.feed(Data(line.utf8))
        }
        var multiLine = SSEParser(maxEventBytes: 32)
        #expect(throws: SSEParserError.eventTooLarge(limit: 32)) {
            for _ in 0..<10 { _ = try multiLine.feed(Data("data: 0123456\n".utf8)) }
        }
    }
}
