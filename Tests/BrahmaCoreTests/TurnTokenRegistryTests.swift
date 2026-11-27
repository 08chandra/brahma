import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Task 7: per-turn gateway tokens — minting, admission, the end-of-turn grace for in-flight streams, revocation and
/// the emergency stop. Grace is counted on an injected awake clock (`ManualAwakeClock`), so no test waits 30 s.
@Suite(.scratch, .serialized) struct TurnTokenRegistryTests {
    /// A handler that starts a stream, sends one event, then parks until `release` opens and sends the rest; it records whether
    /// each later write went through and whether it saw the cut.
    final class ParkedStream: @unchecked Sendable {
        let release = Gate()
        let parked = Gate()
        let done = Gate()
        private let lock = NSLock()
        private var writes: [Bool] = []
        private var sawCut = false
        var laterWrites: [Bool] { lock.withLock { writes } }
        var observedCut: Bool { lock.withLock { sawCut } }

        func run(_ reply: GatewayReply) async {
            await reply.startEvents()
            await reply.event(Data("event: message_start\ndata: {}\n\n".utf8))
            parked.open()
            await release.wait()
            for name in ["content_block_delta", "message_stop"] {
                let ok = await reply.event(Data("event: \(name)\ndata: {}\n\n".utf8))
                lock.withLock { writes.append(ok) }
            }
            let ended = await reply.endEvents()
            lock.withLock { writes.append(ended); sawCut = reply.isCut }
            done.open()
        }
    }

    /// A handler that parks without writing until it is cancelled or its connection is cut (an upstream that went quiet).
    final class IdleStream: @unchecked Sendable {
        let parked = Gate()
        let done = Gate()
        private let lock = NSLock()
        private var cancelled = false
        var sawCancellation: Bool { lock.withLock { cancelled } }

        func run(_ reply: GatewayReply) async {
            await reply.startEvents()
            await reply.event(Data("event: message_start\ndata: {}\n\n".utf8))
            parked.open()
            let deadline = AwakeTime.deadline(after: .seconds(testPatience))
            while !Task.isCancelled, !reply.isCut, AwakeTime.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            lock.withLock { cancelled = Task.isCancelled }
            done.open()
        }
    }

    @Test func tokensAreUnique() {
        let registry = TurnTokenRegistry(clock: ManualAwakeClock())
        var seen = Set<String>()
        for i in 0..<10_000 {
            let token = registry.mint(GatewayHarness.grant("turn-\(i)"))
            #expect(GatewayToken.isWellFormed(token.value) && TurnTokenFormat.isWellFormed(token.value))
            seen.insert(token.value)
        }
        #expect(seen.count == 10_000)
        #expect(registry.liveTokens == 10_000)
        // Each token admits its own grant; the token never shows in a description or a dump.
        let token = registry.mint(GatewayHarness.grant("turn-x"))
        #expect(registry.admit(token.value)?.turnId == "turn-x")
        #expect(!"\(token)".contains(token.value) && !String(reflecting: token).contains(token.value))
        #expect(registry.admit("not-a-token") == nil && registry.admit(String(repeating: "a", count: 64)) == nil)
        // `mint()` draws 32 random bytes: 64 lowercase hex characters, never the same twice.
        #expect(Set((0..<1000).map { _ in GatewayToken.mint().value }).count == 1000)
        #expect(!GatewayToken.isWellFormed(token.value.uppercased()) && !GatewayToken.isWellFormed(token.value + "0"))
    }

    @Test func endTurnRefusesNewRequestsAtOnce() async throws {
        let stream = ParkedStream()
        let h = GatewayHarness { _, _, reply in await stream.run(reply) }
        let token = h.mint()
        // A stream is in flight on the turn's token...
        let (peer, served) = h.connect()
        await peer.write(rawRequest(token: token.value))
        #expect(try await peer.readHead().status == 200)
        await stream.parked.wait()
        #expect(h.registry.inFlightRequests == 1)
        // ...and the turn ends: admission stops at once, with no clock movement at all.
        h.registry.endTurn(token)
        #expect(h.registry.admit(token.value) == nil)
        let refused = try await h.exchange(rawRequest(token: token.value))
        #expect(refused.status == 401 && refused.errorType == "authentication_error")
        #expect(h.handler.callCount == 1)
        // The in-flight stream is untouched by the refusal; releasing it lets it finish normally.
        stream.release.open()
        await stream.done.wait()
        #expect(stream.laterWrites == [true, true, true])
        _ = try await peer.readChunk()
        peer.close()
        await served.value
        #expect(h.registry.inFlightRequests == 0)
        // Ending an unknown or already-ended turn is a no-op.
        h.registry.endTurn(token)
        #expect(h.registry.liveTokens == 0)
    }

    @Test func inFlightStreamFinishesWithinGrace() async throws {
        #expect(TurnTokenRegistry.inFlightGrace == .seconds(30))
        let stream = ParkedStream()
        let h = GatewayHarness { _, _, reply in await stream.run(reply) }
        let token = h.mint()
        let (peer, served) = h.connect()
        await peer.write(rawRequest(token: token.value))
        #expect(try await peer.readHead().status == 200)
        #expect(try await peer.readChunk().count > 0)
        await stream.parked.wait()
        h.registry.endTurn(token)
        // 29 s of awake time later the stream may still finish.
        h.clock.advance(by: .seconds(29))
        stream.release.open()
        await stream.done.wait()
        #expect(stream.laterWrites == [true, true, true] && !stream.observedCut)
        #expect(String(decoding: try await peer.readChunk(), as: UTF8.self).contains("content_block_delta"))
        #expect(String(decoding: try await peer.readChunk(), as: UTF8.self).contains("message_stop"))
        #expect(try await peer.readChunk().isEmpty)
        peer.close()
        await served.value
        // The finished stream's grace timer is gone: moving past the grace cuts nothing and leaves no sleeper.
        #expect(h.registry.inFlightRequests == 0)
        let deadline = AwakeTime.deadline(after: .seconds(testPatience))
        while h.clock.sleeperCount > 0, AwakeTime.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.clock.sleeperCount == 0)
    }

    @Test func inFlightStreamCutAfterGrace() async throws {
        // A stream that writes after the grace: the write is refused and the client sees the connection end with no terminator.
        do {
            let stream = ParkedStream()
            let h = GatewayHarness { _, _, reply in await stream.run(reply) }
            let token = h.mint()
            let (peer, served) = h.connect()
            await peer.write(rawRequest(token: token.value))
            #expect(try await peer.readHead().status == 200)
            #expect(try await peer.readChunk().count > 0)
            await stream.parked.wait()
            h.registry.endTurn(token)
            h.clock.advance(by: TurnTokenRegistry.inFlightGrace)
            stream.release.open()
            await stream.done.wait()
            #expect(stream.laterWrites == [false, false, false] && stream.observedCut)
            #expect(await peer.seesEOF())
            await served.value
            #expect(h.registry.inFlightRequests == 0)
        }
        // A stream parked without writing (upstream gone quiet) is cut by the grace timer itself, and its handler is cancelled.
        do {
            let stream = IdleStream()
            let h = GatewayHarness { _, _, reply in await stream.run(reply) }
            let token = h.mint()
            let (peer, served) = h.connect()
            await peer.write(rawRequest(token: token.value))
            #expect(try await peer.readHead().status == 200)
            #expect(try await peer.readChunk().count > 0)
            await stream.parked.wait()
            h.registry.endTurn(token)
            h.clock.advance(by: .seconds(29))
            #expect(await peer.staysQuiet(milliseconds: 100), "not cut inside the grace")
            h.clock.advance(by: .seconds(1))
            #expect(await peer.seesEOF())
            await stream.done.wait()
            #expect(stream.sawCancellation)
            await served.value
        }
    }

    /// Sends a head declaring 1000 body bytes plus the first 500 of them, and waits until the request holds its lease.
    private func halfSentBody(_ h: GatewayHarness, _ token: GatewayToken) async throws -> (TestPeer, Task<Void, Never>) {
        let (peer, served) = h.connect()
        await peer.write(rawRequest(token: token.value, body: String(repeating: "a", count: 500), extra: ["Content-Length: 1000"],
                                    contentLength: false))
        let deadline = AwakeTime.deadline(after: .seconds(testPatience))
        while h.registry.inFlightRequests == 0, AwakeTime.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(h.registry.inFlightRequests == 1, "the request was admitted and is reading its body")
        return (peer, served)
    }

    /// X1-33: a request revoked while its body is still arriving is cut there and never dispatched.
    @Test func revocationMidBodyCutsBeforeDispatch() async throws {
        let revocations: [(String, @Sendable (GatewayHarness, GatewayToken) async -> Void)] = [
            ("revokeAll", { h, _ in h.registry.revokeAll(reason: "test") }),
            ("stopAll", { h, _ in await h.registry.stopAll(reason: "everything stopped by the owner") }),
        ]
        for (name, revoke) in revocations {
            let h = GatewayHarness()
            let token = h.mint()
            let (peer, served) = try await halfSentBody(h, token)
            await revoke(h, token)
            #expect(await peer.seesEOF(), "\(name): cut mid-body")
            // The rest of the body arriving now changes nothing.
            await peer.write(String(repeating: "b", count: 500))
            await served.value
            #expect(h.handler.callCount == 0, "\(name): never dispatched")
            #expect(h.registry.inFlightRequests == 0)
        }
        // The end of a turn mid-body: the request may keep uploading within the grace, and is cut when the grace runs out.
        let h = GatewayHarness()
        let token = h.mint()
        let (peer, served) = try await halfSentBody(h, token)
        h.registry.endTurn(token)
        h.clock.advance(by: .seconds(29))
        #expect(await peer.staysQuiet(milliseconds: 100), "not cut inside the grace")
        h.clock.advance(by: .seconds(1))
        #expect(await peer.seesEOF())
        await served.value
        #expect(h.handler.callCount == 0)
    }

    /// X1-33 (b): a request whose lease is revoked after its body was read but before dispatch is refused 401, not dispatched.
    @Test func revocationBeforeDispatchIs401() async throws {
        // Revoked outright.
        do {
            let h = GatewayHarness()
            let token = h.mint()
            let registry = h.registry
            h.beforeDispatch.action = { _ in registry.revokeAll(reason: "test") }
            let response = try await h.exchange(rawRequest(token: token.value))
            #expect(response.status == 401 && response.errorType == "authentication_error")
            #expect(h.handler.callCount == 0)
        }
        // The turn ended and its grace ran out before dispatch.
        do {
            let h = GatewayHarness()
            let token = h.mint()
            let (registry, clock) = (h.registry, h.clock)
            h.beforeDispatch.action = { _ in
                registry.endTurn(token)
                clock.advance(by: TurnTokenRegistry.inFlightGrace)
            }
            let response = try await h.exchange(rawRequest(token: token.value))
            #expect(response.status == 401)
            #expect(h.handler.callCount == 0)
        }
        // Control: a turn that ended inside the grace still has its admitted request served (it was in flight).
        do {
            let h = GatewayHarness()
            let token = h.mint()
            let registry = h.registry
            h.beforeDispatch.action = { _ in registry.endTurn(token) }
            #expect(try await h.exchange(rawRequest(token: token.value)).status == 200)
            #expect(h.handler.callCount == 1)
            #expect(try await h.exchange(rawRequest(token: token.value)).status == 401, "new requests are refused")
        }
    }

    @Test func stopRevokesAll() async throws {
        let streams = [IdleStream(), IdleStream()]
        let index = Counter()
        let h = GatewayHarness { _, _, reply in await streams[index.next() - 1].run(reply) }
        let a = h.mint("turn-a"), b = h.mint("turn-b")
        var peers: [(TestPeer, Task<Void, Never>)] = []
        for (i, token) in [a, b].enumerated() {
            let (peer, served) = h.connect()
            await peer.write(rawRequest(token: token.value))
            #expect(try await peer.readHead().status == 200)
            await streams[i].parked.wait()
            peers.append((peer, served))
        }
        #expect(h.registry.inFlightRequests == 2)
        // The registry is an emergency-stop observer: a stop revokes every token and cuts every stream at once (no grace).
        let observer: any EmergencyStopObserver = h.registry
        await observer.stopAll(reason: "everything stopped by the owner")
        for (i, (peer, served)) in peers.enumerated() {
            #expect(await peer.seesEOF(), "stream \(i) cut at once")
            await streams[i].done.wait()
            await served.value
        }
        #expect(h.registry.admit(a.value) == nil && h.registry.admit(b.value) == nil)
        #expect(h.registry.liveTokens == 0 && h.registry.inFlightRequests == 0)
        #expect(h.registry.lastRevocationReason == "everything stopped by the owner")
        #expect(try await h.exchange(rawRequest(token: a.value)).status == 401)
        // New turns after the stop get new tokens that work.
        let c = h.mint("turn-c")
        let index2 = index.next()
        #expect(index2 == 3)
        #expect(h.registry.admit(c.value)?.turnId == "turn-c")
        // `revokeAll` alone does the same without a stop.
        h.registry.revokeAll(reason: "gateway stopping")
        #expect(h.registry.admit(c.value) == nil && h.registry.lastRevocationReason == "gateway stopping")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
