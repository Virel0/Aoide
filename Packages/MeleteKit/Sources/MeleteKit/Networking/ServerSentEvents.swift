import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One server-sent event: its name and its data.
public struct ServerSentEvent: Equatable, Sendable {
    public let name: String
    public let data: String
}

/// Reads server-sent events a line at a time: each line goes in without its
/// line ending, and an event comes out at the blank line that ends it.
/// Comments and events without data are skipped.
struct ServerSentEventParser {
    private var name = "message"
    private var data: [String] = []

    mutating func feed(_ line: String) -> ServerSentEvent? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.isEmpty {
            defer { name = "message"; data = [] }
            return data.isEmpty ? nil : ServerSentEvent(name: name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") {
            name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            data.append(String(value.first == " " ? value.dropFirst() : value))
        }
        return nil
    }
}

#if !canImport(FoundationNetworking)
extension MeleteClient {
    /// Opens an event stream at `path` and hands each event to `each` until the
    /// server ends it. Cancelling the calling task closes it.
    func followEvents(path: String, _ each: (ServerSentEvent) async throws -> Void) async throws {
        var request = request("GET", path: path)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MeleteError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MeleteError.transport("The server sent a malformed response.")
        }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            try Self.check(status: http.statusCode, data: body, path: path)
        }
        var line = Data()
        // Read by hand: `AsyncBytes.lines` drops the blank lines that end each event.
        var parser = ServerSentEventParser()
        do {
            for try await byte in bytes {
                guard byte == UInt8(ascii: "\n") else {
                    line.append(byte)
                    if line.count > 4 * 1024 * 1024 {
                        throw MeleteError.transport("The server sent an event too large to read.")
                    }
                    continue
                }
                defer { line.removeAll(keepingCapacity: true) }
                if let event = parser.feed(String(decoding: line, as: UTF8.self)) {
                    try await each(event)
                }
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MeleteError.transport(error.localizedDescription)
        }
    }
}
#endif
