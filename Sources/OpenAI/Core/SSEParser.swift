import Foundation

struct ServerSentEvent: Sendable, Equatable {
    let data: String
    let event: String?
    let id: String?
    let retry: Int?
}

/// Incremental byte framing preserves split UTF-8 scalars and accepts LF, CR, and CRLF.
struct SSEParser {
    private let maxEventBytes: Int
    private var line = Data()
    private var eventBytes = 0
    private var skipLF = false
    private var firstLine = true
    private var dataLines: [String] = []
    private var event: String?
    private var id: String?
    private var retry: Int?

    init(maxEventBytes: Int = 8 * 1024 * 1024) { self.maxEventBytes = maxEventBytes }

    mutating func append(_ data: Data) throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in data {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            eventBytes += 1
            guard eventBytes <= maxEventBytes else { throw OpenAIClientError.streamEventTooLarge }
            if byte == 10 || byte == 13 {
                if let event = try consumeLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                line.append(byte)
            }
        }
        return events
    }

    mutating func finish() throws -> [ServerSentEvent] {
        // SSE dispatch requires a blank line. An unterminated event is a truncated
        // response, rather than a fabricated successful final event.
        guard line.isEmpty && dataLines.isEmpty else {
            throw OpenAIClientError.invalidStream("Connection closed in the middle of an SSE event")
        }
        return []
    }

    private mutating func consumeLine() throws -> ServerSentEvent? {
        guard var text = String(data: line, encoding: .utf8) else {
            throw OpenAIClientError.invalidStream("SSE data is not UTF-8")
        }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.first == "\u{FEFF}" { text.removeFirst() }
        }
        if text.isEmpty {
            eventBytes = 0
            defer {
                dataLines.removeAll(keepingCapacity: true)
                event = nil
                retry = nil
            }
            guard !dataLines.isEmpty else { return nil }
            return ServerSentEvent(data: dataLines.joined(separator: "\n"), event: event, id: id, retry: retry)
        }
        if text.first == ":" { return nil }
        let split = text.firstIndex(of: ":")
        let field = split.map { String(text[..<$0]) } ?? text
        var value = split.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "data": dataLines.append(value)
        case "event": event = value
        case "id": if !value.contains("\0") { id = value }
        case "retry":
            if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) { retry = Int(value) }
        default: break
        }
        return nil
    }
}
