import Foundation

public struct SSEEvent: Sendable, Hashable {
    public var event: String?
    public var data: Data

    public init(event: String?, data: Data) {
        self.event = event
        self.data = data
    }
}

public enum SSEParserError: Error, Sendable, Equatable {
    case eventTooLarge(limit: Int)
}

/// Incremental Server-Sent Events parser (WHATWG "event stream interpretation").
///
/// Works on raw bytes as they arrive from the network, so chunk boundaries may fall anywhere:
/// inside a field, between `\r` and `\n`, or inside a multi-byte UTF-8 sequence. Only the
/// `event` and `data` fields are interpreted; `id`/`retry` are irrelevant for one-shot
/// Messages API streams. A per-event size cap protects against unbounded memory growth.
public struct SSEParser: Sendable {
    public let maxEventBytes: Int

    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var hasData = false
    private var eventName: String?
    private var pendingCR = false
    private var isFirstLine = true

    private static let lf: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D
    private static let colon: UInt8 = 0x3A
    private static let space: UInt8 = 0x20

    public init(maxEventBytes: Int = 8 * 1024 * 1024) {
        self.maxEventBytes = maxEventBytes
        line.reserveCapacity(1024)
        data.reserveCapacity(1024)
    }

    /// Feeds a network chunk and returns every event completed by it, in order.
    public mutating func feed(_ chunk: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            try consume(raw.bindMemory(to: UInt8.self), into: &events)
        }
        return events
    }

    private mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>, into events: inout [SSEEvent]) throws {
        var lineStart = 0
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if pendingCR {
                pendingCR = false
                if byte == Self.lf {
                    // Second half of a CRLF terminator split across chunks.
                    index += 1
                    lineStart = index
                    continue
                }
            }
            if byte == Self.lf || byte == Self.cr {
                try appendToLine(UnsafeBufferPointer(rebasing: bytes[lineStart..<index]))
                try processLine(into: &events)
                line.removeAll(keepingCapacity: true)
                if byte == Self.cr {
                    if index + 1 < count {
                        if bytes[index + 1] == Self.lf { index += 1 }
                    } else {
                        pendingCR = true
                    }
                }
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart < count {
            try appendToLine(UnsafeBufferPointer(rebasing: bytes[lineStart..<count]))
        }
    }

    private mutating func appendToLine(_ slice: UnsafeBufferPointer<UInt8>) throws {
        guard !slice.isEmpty else { return }
        guard line.count + slice.count <= maxEventBytes else {
            throw SSEParserError.eventTooLarge(limit: maxEventBytes)
        }
        line.append(contentsOf: slice)
    }

    private mutating func processLine(into events: inout [SSEEvent]) throws {
        if isFirstLine {
            isFirstLine = false
            // A UTF-8 byte order mark may only appear at the very start of the stream.
            if line.count >= 3, line[0] == 0xEF, line[1] == 0xBB, line[2] == 0xBF {
                line.removeFirst(3)
            }
        }

        if line.isEmpty {
            dispatch(into: &events)
            return
        }
        if line[0] == Self.colon {
            return // comment / keep-alive
        }

        let colonIndex = line.firstIndex(of: Self.colon)
        let fieldEnd = colonIndex ?? line.count
        var valueStart = colonIndex.map { $0 + 1 } ?? line.count
        if valueStart < line.count, line[valueStart] == Self.space {
            valueStart += 1
        }

        if fieldEnd == 4, line[0] == 0x64, line[1] == 0x61, line[2] == 0x74, line[3] == 0x61 { // "data"
            let valueLength = line.count - valueStart
            guard data.count + valueLength + 1 <= maxEventBytes else {
                throw SSEParserError.eventTooLarge(limit: maxEventBytes)
            }
            if hasData { data.append(Self.lf) }
            data.append(contentsOf: line[valueStart...])
            hasData = true
        } else if fieldEnd == 5, line[0] == 0x65, line[1] == 0x76, line[2] == 0x65, line[3] == 0x6E, line[4] == 0x74 { // "event"
            eventName = String(decoding: line[valueStart...], as: UTF8.self)
        }
        // Other fields (id, retry, unknown) are ignored by design.
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer {
            data.removeAll(keepingCapacity: true)
            hasData = false
            eventName = nil
        }
        guard hasData else { return }
        events.append(SSEEvent(event: eventName, data: Data(data)))
    }
}
