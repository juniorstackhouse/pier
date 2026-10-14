import Foundation

/// The seam between the typed API and the wire. `BoxClient` is the production conformance;
/// tests plug in a scripted one.
public protocol PierTransport: Sendable {
    /// One request/response. `path` starts with `/v1/` and already carries any query string.
    /// A non-2xx answer throws (`PierError.api` / `.unauthorized` / `.rateLimited`).
    func send(_ method: BoxClient.Method, path: String, body: Data?) async throws -> (status: Int, data: Data)
    /// One connection's worth of a long-lived GET (NDJSON events): body chunks until the response ends or fails.
    func stream(path: String) -> AsyncThrowingStream<Data, Error>
    /// One request whose body and answer both stream (a terminal, `POST /v1/sessions/{name}/tty`): `body`'s chunks go
    /// out as they come, the answer's chunks arrive as they are sent. A non-2xx answer ends it with its error.
    func duplex(_ method: BoxClient.Method, path: String, contentType: String, body: AsyncStream<Data>) -> AsyncThrowingStream<Data, Error>
    /// Drop the connection (foreground / network change); the next call re-dials.
    func reset() async
}

extension PierTransport {
    /// A transport with no streams both ways: the route is not served.
    public func duplex(_ method: BoxClient.Method, path: String, contentType: String, body: AsyncStream<Data>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish(throwing: PierError.api(status: 404, message: "not served", code: "not_found")) }
    }
}

extension BoxClient: PierTransport {
    public func send(_ method: Method, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        try await requestStatus(method, path: path, jsonBody: body)
    }

    public nonisolated func stream(path: String) -> AsyncThrowingStream<Data, Error> { chunks(path: path) }
}
