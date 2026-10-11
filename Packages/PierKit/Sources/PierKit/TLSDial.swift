import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Completes once the TLS handshake finished (or fails with the first error). Passes everything through.
final class HandshakeWaiter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    private let promise: EventLoopPromise<String?>
    private var done = false

    init(promise: EventLoopPromise<String?>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted(let proto) = event, !done {
            done = true
            promise.succeed(proto)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done {
            done = true
            promise.fail(error)
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            promise.fail(ChannelError.ioOnClosedChannel)
        }
        context.fireChannelInactive()
    }
}

/// The relay's side of a relayed connection, before TLS (pierd's package relay; docs/PROTOCOL.md §5): asks the relay
/// for the box by its key's fingerprint and waits for "OK", then passes every byte through untouched. The TLS that
/// follows is the box's own, pinned as on a direct connection: the relay only carries it.
final class RelayDialHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    static let version = "PIER-RELAY/1"

    private let fingerprint: String
    private let promise: EventLoopPromise<Void>
    private var pending: ByteBuffer?
    private var settled = false

    init(fingerprint: Fingerprint, promise: EventLoopPromise<Void>) {
        self.fingerprint = fingerprint.description
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var b = context.channel.allocator.buffer(capacity: 120)
        b.writeString("\(Self.version) DIAL \(fingerprint)\n")
        context.writeAndFlush(NIOAny(b), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !settled else { context.fireChannelRead(data); return }
        var incoming = unwrapInboundIn(data)
        if pending == nil { pending = incoming } else { pending!.writeBuffer(&incoming) }
        guard let view = pending?.readableBytesView, let nl = view.firstIndex(of: UInt8(ascii: "\n")) else {
            if (pending?.readableBytes ?? 0) > 1024 { settle(.failure(PierError.protocolViolation("relay: answer too long"))) }
            return
        }
        let line = (pending!.readString(length: nl - view.startIndex) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pending!.moveReaderIndex(forwardBy: 1)
        // Nothing may follow "OK" before TLS starts: the box waits for our hello.
        guard line == "OK", pending!.readableBytes == 0 else {
            settle(.failure(line == "OK" ? PierError.protocolViolation("relay: bytes before TLS") : Self.error(line)))
            return
        }
        pending = nil
        settle(.success(()))
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(PierError.transport("the relay closed the connection")))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle(.failure(error))
        context.fireErrorCaught(error)
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        promise.completeWith(result)
    }

    /// `ERR <code> [text]` as the person reads it.
    static func error(_ line: String) -> PierError {
        let code = line.hasPrefix("ERR ") ? String(line.dropFirst(4).split(separator: " ").first ?? "") : ""
        switch code {
        case "offline": return .transport("the box is not connected to its relay")
        case "timeout": return .transport("the box did not answer through its relay")
        case "busy": return .transport("the relay is busy; try again in a moment")
        default: return .protocolViolation("relay: \(line.prefix(80))")
        }
    }
}

/// Dials `host:port`, TLS 1.3, presents our Ed25519 client cert, and pins the server key by SPKI hash. With `viaRelay`,
/// `host:port` is the box's relay: it is asked for the box (`RelayDialHandler`) before the same TLS starts.
enum TLSDial {
    struct Result {
        let channel: Channel
        let negotiatedProtocol: String?
    }

    static func connect(
        host: String,
        port: Int,
        viaRelay: Bool = false,
        identity: PierIdentity,
        pin: Fingerprint,
        alpn: [String],
        group: EventLoopGroup,
        timeout: TimeAmount = .seconds(15),
        configure: @escaping @Sendable (ChannelPipeline.SynchronousOperations) throws -> Void
    ) async throws -> Result {
        let context = try sslContext(identity: identity, alpn: alpn)
        return try await dial(host: host, port: port, viaRelay: viaRelay, context: context, pin: pin, group: group, timeout: timeout,
                              configure: configure)
    }

    /// The TLS context depends only on our identity and ALPN: built once (key parsing, BoringSSL setup), not per dial.
    private static let contexts = NIOLockedValueBox<[String: NIOSSLContext]>([:])

    private static func sslContext(identity: PierIdentity, alpn: [String]) throws -> NIOSSLContext {
        let key = "\(identity.fingerprint)|\(alpn.joined(separator: ","))"
        if let c = contexts.withLockedValue({ $0[key] }) { return c }
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = .tlsv13
        config.maximumTLSVersion = .tlsv13
        // The default chain/hostname validation is replaced by the pin check below.
        config.certificateVerification = .noHostnameVerification
        config.applicationProtocols = alpn
        // BoringSSL does NOT advertise ed25519 in signature_algorithms by default; pierd only has an
        // Ed25519 certificate, so without this the server answers handshake_failure.
        config.verifySignatureAlgorithms = [.ed25519]
        let creds = try identity.tlsCredentials()
        config.certificateChain = creds.chain
        config.privateKey = creds.key
        let context: NIOSSLContext
        do { context = try NIOSSLContext(configuration: config) } catch { throw PierError.tls("\(error)") }
        contexts.withLockedValue { $0[key] = context }
        return context
    }

    private static func dial(
        host: String, port: Int, viaRelay: Bool, context: NIOSSLContext, pin: Fingerprint, group: EventLoopGroup,
        timeout: TimeAmount, configure: @escaping @Sendable (ChannelPipeline.SynchronousOperations) throws -> Void
    ) async throws -> Result {

        let actualFP = NIOLockedValueBox<Fingerprint?>(nil)
        let handshake = group.next().makePromise(of: String?.self)
        let relayed = viaRelay ? group.next().makePromise(of: Void.self) : nil

        // TLS, pinned, then the caller's handlers: at once on a direct connection, after the relay's OK on a relayed one.
        @Sendable func addTLS(_ ops: ChannelPipeline.SynchronousOperations) throws {
            let ssl = try NIOSSLClientHandler(
                context: context,
                serverHostname: nil,
                customVerificationCallback: { certs, promise in
                    guard let leaf = certs.first,
                        let spki = try? leaf.extractPublicKey().toSPKIBytes()
                    else { return promise.succeed(.failed) }
                    let fp = Fingerprint(spki: spki)
                    if fp == pin {
                        promise.succeed(.certificateVerified)
                    } else {
                        actualFP.withLockedValue { $0 = fp }
                        promise.succeed(.failed)
                    }
                })
            try ops.addHandler(ssl)
            try ops.addHandler(HandshakeWaiter(promise: handshake))
            try configure(ops)
        }

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ops = channel.pipeline.syncOperations
                    if let relayed {
                        try ops.addHandler(RelayDialHandler(fingerprint: pin, promise: relayed))
                    } else {
                        try addTLS(ops)
                    }
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            relayed?.fail(error)
            handshake.fail(error)
            _ = try? await handshake.futureResult.get()
            throw map(error, pin: actualFP.withLockedValue { $0 }, expected: pin)
        }

        if let relayed {
            let wait = channel.eventLoop.scheduleTask(in: timeout) { relayed.fail(PierError.timeout) }
            do {
                try await relayed.futureResult.get()
                wait.cancel()
                try await channel.eventLoop.submit { try addTLS(channel.pipeline.syncOperations) }.get()
            } catch {
                wait.cancel()
                handshake.fail(error)
                try? await channel.close().get()
                throw map(error, pin: nil, expected: pin)
            }
        }

        let timer = channel.eventLoop.scheduleTask(in: timeout) { handshake.fail(PierError.timeout) }
        do {
            let proto = try await handshake.futureResult.get()
            timer.cancel()
            return Result(channel: channel, negotiatedProtocol: proto)
        } catch {
            timer.cancel()
            try? await channel.close().get()
            throw map(error, pin: actualFP.withLockedValue { $0 }, expected: pin)
        }
    }

    static func map(_ error: Error, pin actual: Fingerprint?, expected: Fingerprint) -> PierError {
        if let actual { return .pinMismatch(expected: expected.description, actual: actual.description) }
        if let e = error as? PierError { return e }
        if error is NIOSSLError || error is BoringSSLError { return .tls("\(error)") }
        if let e = error as? NIOConnectionError { return .transport("\(e)") }
        return .transport("\(error)")
    }
}
