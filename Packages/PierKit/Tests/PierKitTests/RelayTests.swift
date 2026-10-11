import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import PierKit

@Suite struct RelayLinkTests {
    @Test func boxLinkCarriesTheRelay() throws {
        let q = "code=\(LinkTests.code)&fp=\(LinkTests.fp)"
        guard case .box(let b) = try PairingLink.parse("pier://192.0.2.10:7444?\(q)&relay=relay.example.com%3A7443") else {
            Issue.record("expected box"); return
        }
        #expect(b.relay == "relay.example.com:7443" && b.address == "192.0.2.10:7444")
        // A relay that does not parse is left out; the link still pairs directly.
        guard case .box(let bad) = try PairingLink.parse("pier://192.0.2.10:7444?\(q)&relay=nonsense") else {
            Issue.record("expected box"); return
        }
        #expect(bad.relay == nil)
    }

    @Test func joinLinkCarriesTheRelayWhereOlderAppsIgnoreIt() throws {
        let fp = PierIdentity.generate().fingerprint
        let link = BoxPairingLink(host: "192.0.2.10", port: 7444, fingerprint: fp, code: Array(repeating: 7, count: 32),
                                  relay: "relay.example.com:7443")
        let text = try JoinLink.encode(boxes: [(name: "devbox", link: link)], from: "mac", expires: Date(timeIntervalSince1970: 1_900_000_000))
        guard case .join(let j) = try PairingLink.parse(text) else { Issue.record("expected join"); return }
        let box = try #require(j.boxes.first)
        // The direct address stays first: an app that knows nothing of relays dials it, as before.
        #expect(box.addresses.first == "192.0.2.10:7444")
        #expect(box.relay == "relay.example.com:7443")
        let back = try box.pairingLink()
        #expect(back.address == "192.0.2.10:7444" && back.relay == "relay.example.com:7443")
    }

    @Test func recordsFromBeforeRelaysStillDecode() throws {
        let store = MemoryStore()
        let fp = PierIdentity.generate().fingerprint
        let old = #"[{"name":"devbox","address":"192.0.2.10:7444","fingerprint":"\#(fp.description)","paired_at":"2026-01-01T00:00:00Z"}]"#
        try store.write(Data(old.utf8), for: BoxStore.key)
        let boxes = BoxStore(store: store)
        var rec = try #require(try boxes.list().first)
        #expect(rec.relay == nil)
        // update keeps the entry in place and adds what the box said.
        rec.relay = "relay.example.com:7443"
        try boxes.update(rec)
        #expect(try boxes.list() == [rec])
    }
}

@Suite struct RaceTests {
    struct Fail: Error {}

    @Test func theFirstToSucceedWinsAndTheOtherIsDiscarded() async throws {
        let discarded = NIOLockedValueBox<[Int]>([])
        let attempts: [@Sendable () async throws -> Int] = [
            { try await Task.sleep(for: .milliseconds(600)); return 1 },
            { return 2 },
        ]
        let v = try await Race.first(attempts, stagger: .milliseconds(100)) { v in discarded.withLockedValue { $0.append(v) } }
        #expect(v == 2)
        try await Task.sleep(for: .milliseconds(800))
        #expect(discarded.withLockedValue { $0 } == [1])
    }

    @Test func aFailureStartsTheNextAtOnce() async throws {
        let start = ContinuousClock.now
        let attempts: [@Sendable () async throws -> Int] = [{ throw Fail() }, { return 2 }]
        let v = try await Race.first(attempts, stagger: .seconds(5)) { _ in }
        #expect(v == 2)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func aFastFirstNeverStartsTheSecond() async throws {
        let started = NIOLockedValueBox(false)
        let attempts: [@Sendable () async throws -> Int] = [{ return 1 }, { started.withLockedValue { $0 = true }; return 2 }]
        let v = try await Race.first(attempts, stagger: .milliseconds(200)) { _ in }
        #expect(v == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!started.withLockedValue { $0 })
    }

    @Test func whenAllFailAPinMismatchIsWhatIsSaid() async throws {
        let attempts: [@Sendable () async throws -> Int] = [
            { throw PierError.transport("no route") },
            { throw PierError.pinMismatch(expected: "a", actual: "b") },
        ]
        do {
            _ = try await Race.first(attempts, stagger: .milliseconds(50)) { _ in }
            Issue.record("expected a failure")
        } catch PierError.pinMismatch {
        }
    }
}

/// A relay in a test: answers DIAL for one fingerprint by joining the app to `target` (the box), else ERR offline.
final class FakeRelay: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let target: Int
    let fingerprint: String
    private var buffer = ByteBuffer()
    private var joined = false

    init(target: Int, fingerprint: String) {
        self.target = target
        self.fingerprint = fingerprint
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        guard !joined else { return }
        buffer.writeBuffer(&incoming)
        guard let nl = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return }
        let line = buffer.readString(length: nl - buffer.readerIndex) ?? ""
        joined = true
        let app = context.channel
        guard line == "PIER-RELAY/1 DIAL \(fingerprint)" else {
            app.writeAndFlush(ByteBuffer(string: "ERR offline\n")).whenComplete { _ in app.close(promise: nil) }
            return
        }
        let toApp = Glue(partner: app)
        ClientBootstrap(group: app.eventLoop)
            .channelInitializer { $0.pipeline.addHandler(toApp) }
            .connect(host: "127.0.0.1", port: target)
            .whenComplete { result in
                guard case .success(let box) = result else { app.close(promise: nil); return }
                _ = app.pipeline.removeHandler(self).flatMap { app.pipeline.addHandler(Glue(partner: box)) }.map {
                    app.writeAndFlush(ByteBuffer(string: "OK\n"), promise: nil)
                }
            }
    }
}

/// Copies what one channel reads to its partner.
final class Glue: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let partner: Channel
    init(partner: Channel) { self.partner = partner }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner.writeAndFlush(data, promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { partner.close(promise: nil) }
}

@Suite struct RelayDialTests {
    func startRelay(target: Int, fingerprint: Fingerprint, group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandler(FakeRelay(target: target, fingerprint: fingerprint.description))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    /// Through the relay, the TLS is still the app's and the box's own: same exporter on both ends, key pinned.
    @Test func tlsRunsEndToEndThroughTheRelay() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = PierIdentity.generate(), client = PierIdentity.generate()
        let holder = TLSLoopbackTests.ExportHolder()
        let box = try await TLSLoopbackTests().startServer(identity: server, holder: holder, group: group)
        let relay = try await startRelay(target: box.localAddress!.port!, fingerprint: server.fingerprint, group: group)
        let dial = try await TLSDial.connect(
            host: "127.0.0.1", port: relay.localAddress!.port!, viaRelay: true, identity: client, pin: server.fingerprint,
            alpn: ["http/1.1"], group: group
        ) { _ in }
        #expect(dial.negotiatedProtocol == "http/1.1")
        let c = dial.channel
        let exported = try await c.eventLoop.submit {
            try c.pipeline.syncOperations.nioSSL_exportKeyingMaterial(label: Pairing.exporterLabel, length: 32)
        }.get()
        try await Task.sleep(for: .milliseconds(200))
        #expect(holder.lock.withLockedValue { $0 } == exported)
        #expect(holder.client.withLockedValue { $0 } == client.fingerprint)
        try await c.close()
        try await relay.close()
        try await box.close()
        try await group.shutdownGracefully()
    }

    @Test func aBoxTheRelayDoesNotKnowIsOffline() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = PierIdentity.generate(), client = PierIdentity.generate(), other = PierIdentity.generate()
        let box = try await TLSLoopbackTests().startServer(identity: server, holder: .init(), group: group)
        let relay = try await startRelay(target: box.localAddress!.port!, fingerprint: server.fingerprint, group: group)
        do {
            _ = try await TLSDial.connect(
                host: "127.0.0.1", port: relay.localAddress!.port!, viaRelay: true, identity: client, pin: other.fingerprint,
                alpn: ["http/1.1"], group: group
            ) { _ in }
            Issue.record("expected the relay to refuse")
        } catch PierError.transport(let m) {
            #expect(m.contains("not connected to its relay"))
        }
        try await relay.close()
        try await box.close()
        try await group.shutdownGracefully()
    }
}
