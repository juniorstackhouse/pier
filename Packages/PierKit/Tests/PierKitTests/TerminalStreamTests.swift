import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import PierKit

/// A transport whose terminal requests answer with `output` (or `failure`, before reading anything) and keep what was
/// sent. As the box does, the answer ends when the body does (the app closed the terminal), or at once with
/// `sessionEnds` (the session ended on the box).
private final class TerminalTransport: PierTransport, @unchecked Sendable {
    let output: [Data]
    let failure: Error?
    let sessionEnds: Bool
    private let lock = NIOLock()
    private var _paths: [String] = []
    private var _sent: [String] = []
    private var _bodyEnded = false

    init(output: [Data] = [], failure: Error? = nil, sessionEnds: Bool = false) {
        self.output = output
        self.failure = failure
        self.sessionEnds = sessionEnds
    }

    var paths: [String] { lock.withLock { _paths } }
    var sent: [String] { lock.withLock { _sent } }
    var bodyEnded: Bool { lock.withLock { _bodyEnded } }

    func send(_ method: BoxClient.Method, path: String, body: Data?) async throws -> (status: Int, data: Data) { (200, Data("{}".utf8)) }
    func stream(path: String) -> AsyncThrowingStream<Data, Error> { AsyncThrowingStream { $0.finish() } }
    func reset() async {}

    func duplex(_ method: BoxClient.Method, path: String, contentType: String, body: AsyncStream<Data>) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { _paths.append("\(method.rawValue) \(path) \(contentType)") }
        let (output, failure, sessionEnds) = (self.output, self.failure, self.sessionEnds)
        return AsyncThrowingStream { c in
            if let failure {
                c.finish(throwing: failure)
                return
            }
            for o in output { c.yield(o) }
            if sessionEnds { c.finish() }
            Task {
                for await chunk in body { self.lock.withLock { self._sent.append(String(decoding: chunk, as: UTF8.self)) } }
                self.lock.withLock { self._bodyEnded = true }
                c.finish()
            }
        }
    }
}

@Suite struct TerminalStreamTests {
    @Test func framesAreOneJSONObjectPerLine() throws {
        #expect(String(decoding: TerminalFrame.input(Data([0x03])), as: UTF8.self) == "{\"data\":\"Aw==\"}\n")
        #expect(String(decoding: TerminalFrame.input(Data("ls\r".utf8)), as: UTF8.self) == "{\"data\":\"bHMN\"}\n")
        #expect(String(decoding: TerminalFrame.size(cols: 132, rows: 43), as: UTF8.self) == "{\"cols\":132,\"rows\":43}\n")
        // The box takes 2…1000 × 2…500: a size out of it is brought in, never refused.
        #expect(String(decoding: TerminalFrame.size(cols: 0, rows: 9000), as: UTF8.self) == "{\"cols\":2,\"rows\":500}\n")
        struct F: Decodable { let data: Data }
        let decoded = try JSONDecoder().decode(F.self, from: TerminalFrame.input(Data("é\u{1b}[A".utf8)))
        #expect(decoded.data == Data("é\u{1b}[A".utf8))
    }

    @Test func aTerminalStreamsBothWays() async throws {
        let t = TerminalTransport(output: [Data("$ ".utf8), Data("hi\r\n".utf8)])
        let term = BoxAPI(transport: t).terminal(session: "shop-shell-1x", cols: 120, rows: 40)
        term.type(Data("ls\r".utf8))
        term.type(Data())
        term.resize(cols: 100, rows: 30)
        term.close()
        var out = Data()
        for try await chunk in term.output { out.append(chunk) }
        #expect(String(decoding: out, as: UTF8.self) == "$ hi\r\n")
        #expect(t.paths == ["POST /v1/sessions/shop-shell-1x/tty?cols=120&rows=40 application/x-ndjson"])
        // What was typed went out in order (an empty write sends nothing), then the body ended.
        #expect(t.bodyEnded)
        #expect(t.sent == ["{\"data\":\"bHMN\"}\n", "{\"cols\":100,\"rows\":30}\n"])
    }

    /// The session ended on the box (the answer ended): the body ends too, so the request is over on both sides.
    @Test func theSessionEndingEndsTheBody() async throws {
        let t = TerminalTransport(output: [Data("logout\r\n".utf8)], sessionEnds: true)
        let term = BoxAPI(transport: t).terminal(session: "s", cols: 80, rows: 24)
        var out = Data()
        for try await chunk in term.output { out.append(chunk) }
        #expect(String(decoding: out, as: UTF8.self) == "logout\r\n")
        for _ in 0..<50 where !t.bodyEnded { try await Task.sleep(for: .milliseconds(10)) }
        #expect(t.bodyEnded)
    }

    @Test func historyAndSizeGoInTheQuery() async throws {
        let t = TerminalTransport()
        let term = BoxAPI(transport: t).terminal(session: "a b", cols: 5000, rows: 1, history: 0)
        term.close()
        for try await _ in term.output {}
        #expect(t.paths == ["POST /v1/sessions/a%20b/tty?cols=1000&rows=2&history=0 application/x-ndjson"])
    }

    @Test func aRefusalIsABoxError() async throws {
        // As the connection maps the box's answers: 429 too_many is `rateLimited` there, a gate's 403 is `api`.
        let tooMany = mapHTTPError(status: 429, body: Data(#"{"error":"16 terminals are open on this box already: close one first","code":"too_many"}"#.utf8))
        let refused = mapHTTPError(status: 403, body: Data(#"{"error":"not now","code":"refused"}"#.utf8))
        for (failure, status, code) in [(tooMany, 429, "too_many"), (refused, 403, "refused")] {
            let term = BoxAPI(transport: TerminalTransport(failure: failure)).terminal(session: "s", cols: 80, rows: 24)
            do {
                for try await _ in term.output {}
                Issue.record("the stream did not fail")
            } catch let e as BoxError {
                #expect(e.status == status)
                #expect(e.code == code)
            }
        }
    }

    @Test func aLongPasteGoesInPieces() async throws {
        let t = TerminalTransport()
        let term = BoxAPI(transport: t).terminal(session: "s", cols: 80, rows: 24)
        let paste = Data((0..<(TerminalFrame.inputLimit * 2 + 100)).map { UInt8(truncatingIfNeeded: $0) })
        term.type(paste)
        term.close()
        for try await _ in term.output {}
        struct F: Decodable { let data: Data }
        let pieces = try t.sent.map { try JSONDecoder().decode(F.self, from: Data($0.utf8)).data }
        #expect(pieces.map(\.count) == [TerminalFrame.inputLimit, TerminalFrame.inputLimit, 100])
        #expect(pieces.reduce(Data(), +) == paste)
    }

    @Test func aTransportWithoutStreamsSaysNotServed() async throws {
        let term = BoxAPI(transport: MockTransport()).terminal(session: "s", cols: 80, rows: 24)
        do {
            for try await _ in term.output {}
            Issue.record("the stream did not fail")
        } catch let e as BoxError {
            #expect(e.status == 404)
        }
    }
}
