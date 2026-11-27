import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// The gateway's upstream in tests (Plan X1 Task 8): records every request and replays scripted responses. Never touches the
/// network. A response may hold its stream open after its chunks (`hold`), so a test can watch the gateway stop it.
final class FakeUpstream: UpstreamTransport, @unchecked Sendable {
    enum Reply: Sendable {
        case respond(status: Int, headers: [String: String], chunks: [Data], hold: Bool)
        case fail(GatewayError)
        /// A response whose body the test feeds (`UpstreamFeed`) while the gateway relays it.
        case feed(status: Int, headers: [String: String], UpstreamFeed)
    }

    private let lock = NSLock()
    private var script: [Reply]
    private var recorded: [UpstreamRequest] = []
    private var terminations = 0
    private var sendHook: (@Sendable () -> Void)?

    /// `script` is replayed in order; the last reply repeats.
    init(_ script: [Reply]) { self.script = script }

    var requests: [UpstreamRequest] { lock.withLock { recorded } }
    /// Runs inside every `send`, before the reply (a test inspects what the gateway did before sending).
    func onSend(_ hook: @escaping @Sendable () -> Void) { lock.withLock { sendHook = hook } }
    /// How many response streams ended because their consumer stopped (cancelled or dropped), not by finishing.
    var cancelledStreams: Int { lock.withLock { terminations } }

    func send(_ r: UpstreamRequest) async throws(GatewayError) -> UpstreamResponse {
        let (reply, hook): (Reply, (@Sendable () -> Void)?) = lock.withLock {
            recorded.append(r)
            return (script.count > 1 ? script.removeFirst() : script[0], sendHook)
        }
        hook?()
        switch reply {
        case .fail(let error):
            throw error
        case .feed(let status, let headers, let feed):
            return UpstreamResponse(status: status, headers: headers, body: feed.stream)
        case .respond(let status, let headers, let chunks, let hold):
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.onTermination = { [weak self] end in
                if case .cancelled = end { self?.lock.withLock { self?.terminations += 1 } }
            }
            for chunk in chunks { continuation.yield(chunk) }
            if !hold { continuation.finish() }
            return UpstreamResponse(status: status, headers: headers, body: stream)
        }
    }

    // MARK: Scripts

    static func json(_ status: Int, _ body: String) -> Reply {
        .respond(status: status, headers: ["content-type": "application/json"], chunks: [Data(body.utf8)], hold: false)
    }

    /// An SSE body cut into `size`-byte chunks (events split across chunks, as the network does).
    static func sse(_ body: Data, chunk size: Int = 7, hold: Bool = false) -> Reply {
        var chunks: [Data] = []
        var offset = 0
        while offset < body.count {
            chunks.append(body.subdata(in: offset..<min(body.count, offset + size)))
            offset += size
        }
        return .respond(status: 200, headers: ["content-type": "text/event-stream"], chunks: chunks, hold: hold)
    }
}

/// An upstream body a test writes while the gateway reads it.
final class UpstreamFeed: Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() { (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream() }

    func send(_ text: String) { continuation.yield(Data(text.utf8)) }
    func finish() { continuation.finish() }
}

/// Fixtures under `Fixtures/anthropic/`.
enum AnthropicFixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/anthropic"))
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, _ ext: String) throws -> String { String(decoding: try data(name, ext), as: UTF8.self) }

    /// A provider key in the real format, assembled at runtime (lane rule: no key-format literal in fixtures).
    static let key = ["sk", "ant", "api03", "FIXTURE0only0not0a0key0", "AA"].joined(separator: "-")

    static func provider(_ id: String = "anthropic", adapter: String = "anthropic", host: String = "api.anthropic.com",
                         keySecret: String? = Provider.anthropicKeyName, lan: Bool = false) -> Provider {
        Provider(id: id, adapter: adapter, baseURL: URL(string: "https://\(host)")!, host: host, keySecret: keySecret, lan: lan,
                 builtin: true, createdAt: Date(timeIntervalSince1970: 0))
    }
}

/// A gateway reply wired to a socketpair: the adapter writes through a real `GatewayReply`, the test reads the other end.
struct ReplyRig {
    let reply: GatewayReply
    let peer: TestPeer
    let registry: TurnTokenRegistry
    private let wire: Wire
    private let lease: GatewayLease

    init() throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        precondition(socketpair(AF_UNIX, type, 0, &fds) == 0)
        registry = TurnTokenRegistry(clock: ManualAwakeClock())
        let token = registry.mint(GatewayHarness.grant())
        lease = try #require(registry.open(token.value))
        wire = try #require(Wire(fd: fds[0], ioStall: .seconds(30)))
        reply = GatewayReply(wire: wire, lease: lease, close: true)
        peer = TestPeer(fd: fds[1])
    }

    /// Ends the server side (after the adapter returned) so the peer can read to EOF.
    func finish() {
        _ = reply.finish()
        lease.finish()
        wire.close()
    }
}

/// A `ModelGateway` behind a real `GatewayServer` over socketpairs, with a fake upstream, an in-memory vault and recorded logs.
final class ModelGatewayRig: @unchecked Sendable {
    /// What the gateway's closures record (made before the gateway, so they never capture the rig).
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
        var lookups = 0
        var onLookup: (@Sendable () -> Void)?
    }

    let registry = TurnTokenRegistry(clock: ManualAwakeClock())
    let upstream: FakeUpstream
    let vault = MemoryVault()
    /// The meter's store: one company, `companyId`, with caps for `anthropic` unless the rig was made without them.
    let store: Store
    let companyId: String
    let meter: GatewayMeter
    let gateway: ModelGateway
    let server: GatewayServer
    private let recorder = Recorder()

    init(_ script: [FakeUpstream.Reply], providers: [Provider] = [AnthropicFixture.provider()], storeKey: Bool = true,
         caps: ProviderCaps? = ProviderCaps(monthlyUSD: 1000), maxUpstream: Int = GatewayLimits.maxUpstreamRequests) throws {
        upstream = FakeUpstream(script)
        store = try Store.inMemory()
        companyId = try store.createCompany(name: "Co", goal: "g", workspacesRoot: tempDir()).id
        if let caps { try store.setProviderCaps(caps, companyId: companyId, provider: "anthropic") }
        if storeKey { try vault.set(companyId: companyId, name: Provider.anthropicKeyName, value: AnthropicFixture.key) }
        let byId = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let recorder = self.recorder
        let log: @Sendable (String) -> Void = { line in recorder.lock.withLock { recorder.lines.append(line) } }
        meter = GatewayMeter(store: store, prices: { PriceBook(owner: []) }, clock: { Date() }, log: log)
        gateway = ModelGateway(registry: registry, providers: { id in
            let hook: (@Sendable () -> Void)? = recorder.lock.withLock { recorder.lookups += 1; return recorder.onLookup }
            hook?()
            return byId[id]
        }, adapters: [AnthropicAdapter()], upstream: upstream, vault: vault, meter: meter, maxUpstream: maxUpstream, log: log)
        // Connection deadlines on a clock that stands still: no load can time a connection out (Ruling 44).
        server = GatewayServer(registry: registry, handler: gateway, timing: .pinned, clock: ManualAwakeClock(), beforeDispatch: nil)
    }

    /// Runs on every provider lookup (the step before the key is read).
    func onProviderLookup(_ hook: @escaping @Sendable () -> Void) { recorder.lock.withLock { recorder.onLookup = hook } }

    var logLines: [String] { recorder.lock.withLock { recorder.lines } }
    var providerLookups: Int { recorder.lock.withLock { recorder.lookups } }

    func grant(aliases: [String: TurnGrant.RoutedTarget] = ["brahma-standard": .init(provider: "anthropic", model: "claude-sonnet-5-5")],
               passThrough: Set<String> = ["claude-opus-5-5"], textOnly: Set<String> = [], serverTools: Set<String> = []) -> GatewayToken {
        registry.mint(TurnGrant(turnId: "turn-1", companyId: companyId, agentId: "agent-1", provider: "anthropic", aliases: aliases,
                                passThroughFamilies: passThrough, textOnlyModels: textOnly, serverTools: serverTools))
    }

    /// One `gatewayCharge` row as the tests read it.
    struct ChargeRow: Equatable {
        var state: String
        var usd: Double
        var estimated: Bool
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var provider: String
        var model: String
    }

    /// Every charge, oldest first.
    func charges() throws -> [ChargeRow] { try ModelGatewayRig.charges(store) }

    static func charges(_ store: Store) throws -> [ChargeRow] {
        try store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM gatewayCharge ORDER BY id").map {
                ChargeRow(state: $0["state"], usd: $0["usd"], estimated: $0["estimated"], inputTokens: $0["inputTokens"],
                          outputTokens: $0["outputTokens"], cacheReadTokens: $0["cacheReadTokens"], cacheWriteTokens: $0["cacheWriteTokens"],
                          provider: $0["provider"], model: $0["model"])
            }
        }
    }

    func connect() -> (peer: TestPeer, served: Task<Void, Never>) {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        precondition(socketpair(AF_UNIX, type, 0, &fds) == 0)
        let server = self.server, fd = fds[0]
        return (TestPeer(fd: fds[1]), Task { await server.serve(connection: fd) })
    }

    /// One request on a fresh connection (`Connection: close`), its whole response.
    func exchange(_ body: String, token: GatewayToken, target: String = "/t/v1/messages?beta=true", extra: [String] = []) async throws
        -> TestResponse {
        let (peer, served) = connect()
        await peer.write(rawRequest(target: target, token: token.value, body: body, extra: extra + ["Connection: close"]))
        let response = try await peer.readResponse()
        peer.close()
        await served.value
        return response
    }
}

/// Polls `condition` (awake time) until it holds or `seconds` pass.
func eventually(within seconds: Int = testPatience, _ condition: () -> Bool) async -> Bool {
    let deadline = AwakeTime.deadline(after: .seconds(seconds))
    while AwakeTime.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
