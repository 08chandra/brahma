import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan X1 Task 9: the gateway's dollar meter — a reservation written before the request is sent, settled with the actual
/// usage (or the estimate when it is missing), per-company per-provider daily and monthly caps in the owner's calendar, and
/// item budgets that count gateway dollars.
@Suite(.scratch, .serialized) struct GatewayMeterTests {
    /// A clock the tests move.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        var now: Date {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
    }

    /// A value shared by concurrent workers.
    final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func with<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
    }

    /// One store with one company (`companyId`), a clock and a meter on the pinned prices.
    struct Rig {
        let store: Store
        let companyId: String
        let clock: Clock
        let meter: GatewayMeter

        init(caps: ProviderCaps? = ProviderCaps(monthlyUSD: 10), zone: String = "UTC", at start: Date = Self.noon,
             admission: GatewayMeter.Admission? = nil, owner prices: [PriceRow] = []) throws {
            store = try Store.inMemory()
            companyId = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: tempDir()).id
            try store.setOwnerTimeZone(zone)
            if let caps { try store.setProviderCaps(caps, companyId: companyId, provider: "anthropic") }
            clock = Clock(start)
            meter = Self.meter(store, clock: clock, admission: admission, prices: prices)
        }

        static func meter(_ store: Store, clock: Clock, admission: GatewayMeter.Admission? = nil, prices: [PriceRow] = []) -> GatewayMeter {
            GatewayMeter(store: store, prices: { PriceBook(owner: prices) }, clock: { clock.now }, admission: admission ?? GatewayMeter.admits,
                         log: { _ in })
        }

        static let noon = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

        func grant(item: String? = nil, aliases: [String: TurnGrant.RoutedTarget] = [:]) -> TurnGrant {
            TurnGrant(turnId: "turn-1", companyId: companyId, agentId: "agent-1", itemId: item, provider: "anthropic",
                      aliases: ["brahma-standard": .init(provider: "anthropic", model: "claude-sonnet-5-5")].merging(aliases) { _, new in new },
                      passThroughFamilies: ["claude-opus-5-5"])
        }

        func charges() throws -> [ModelGatewayRig.ChargeRow] { try ModelGatewayRig.charges(store) }
    }

    static let opus = PriceBook.pinned["anthropic/claude-opus-5-5"]!

    /// Opus, 1000 output tokens, 3000 body bytes: 1000 input tokens at the cache-write rate ($8) + 1000 at $20 = $0.028.
    static let small = (maxTokens: 1000, bytes: 3000, usd: 0.028)

    /// An ASCII body of `n` bytes (estimated at ceil(n / 3) input tokens).
    static func ascii(_ n: Int) -> Data { Data(repeating: UInt8(ascii: "a"), count: max(n, 0)) }

    static func expectRefusal(_ body: () throws(GatewayError) -> Void, status: Int = GatewayRefusal.status, type: String,
                              _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try body()
            Issue.record("expected a refusal: \(message)", sourceLocation: sourceLocation)
        } catch {
            #expect(error.status == status && error.type == type && error.message == message, "\(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Estimate and caps

    @Test func estimateIsThePinnedFormula() {
        #expect(abs(GatewayMeter.estimate(Self.opus, maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes)) - Self.small.usd) < 1e-12)
        // ASCII: ceil(bytes / 3) — 3001 bytes are 1001 tokens — at the higher of the input and cache-write rates.
        #expect(GatewayMeter.estimatedInputTokens(Self.ascii(3001)) == 1001)
        #expect(abs(GatewayMeter.estimate(Self.opus, maxTokens: 0, body: Self.ascii(3001)) - 1001 * 8 / 1e6) < 1e-12)
        let cheapCache = Price(inPerMTok: 3, outPerMTok: 15, cacheReadPerMTok: 0.3, cacheWritePerMTok: 1)
        #expect(abs(GatewayMeter.estimate(cheapCache, maxTokens: 0, body: Self.ascii(3)) - 3 / 1e6) < 1e-12)
        // Ruling 54: two tokens per scalar at or above U+0080, whatever its UTF-8 length; ASCII beside it at bytes / 3.
        #expect(GatewayMeter.estimatedInputTokens(Data("é中😀".utf8)) == 6)
        #expect(GatewayMeter.estimatedInputTokens(Data("abc中".utf8)) == 3)
        #expect(GatewayMeter.estimatedInputTokens(Data([0x61, 0xFF, 0xFE])) == 5, "bytes that are not UTF-8 count as U+FFFD")
        #expect(GatewayMeter.estimatedInputTokens(Data()) == 0)
        // Never negative; output bounded by the most any usage is metered for.
        #expect(GatewayMeter.estimate(Self.opus, maxTokens: -5, inputTokens: -7) == 0)
        #expect(GatewayMeter.estimate(Self.opus, maxTokens: .max, body: Data()) == Double(GatewayUsage.maxTokens) * 20 / 1e6)
        #expect(GatewayMeter.estimate(Self.opus, maxTokens: .max, inputTokens: .max).isFinite)
    }

    /// Admitted while the day's spend plus open reservations is below the cap; the refusal names the provider, the period, the
    /// cap and the company; nothing is written for a refused request; a settle below the estimate frees room.
    @Test func refusesAtCap() throws {
        let rig = try Rig(caps: ProviderCaps(monthlyUSD: 10, dailyUSD: 0.05))
        let g = rig.grant()
        let first = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes))
        #expect(abs(first.estimateUSD - Self.small.usd) < 1e-12)
        _ = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes))  // 0.028 < 0.05
        let daily = "Brahma: anthropic daily cap of $0.05 reached for \(rig.companyId)"
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1))   // 0.056 ≥ 0.05
        }, type: GatewayRefusal.type, daily)
        #expect(try rig.charges().map(\.state) == ["reserved", "reserved"])
        // An alias routed to the same provider shares the cap.
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try rig.meter.reserve(g, model: "brahma-standard", maxTokens: 1, body: Self.ascii(1))
        }, type: GatewayRefusal.type, daily)

        // The first settles far below its estimate: 0.028 + 0.001 < 0.05 admits again.
        rig.meter.settle(first, usage: GatewayUsage(inputTokens: 0, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0))
        _ = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1))

        // The monthly cap is named when it is the one reached.
        let monthly = try Rig(caps: ProviderCaps(monthlyUSD: 0.02, dailyUSD: 5))
        _ = try monthly.meter.reserve(monthly.grant(), model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes))
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try monthly.meter.reserve(monthly.grant(), model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1))
        }, type: GatewayRefusal.type, "Brahma: anthropic monthly cap of $0.02 reached for \(monthly.companyId)")

        // A zero cap admits nothing.
        let zero = try Rig(caps: ProviderCaps(monthlyUSD: 0))
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try zero.meter.reserve(zero.grant(), model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1))
        }, type: GatewayRefusal.type, "Brahma: anthropic monthly cap of $0.00 reached for \(zero.companyId)")
        #expect(try zero.charges().isEmpty)
    }

    /// No caps row for the provider: refused with how to set one — by the meter, and by the gateway before anything is sent.
    @Test func noCapNoRequest() async throws {
        let rig = try Rig(caps: nil)
        // Caps for another provider do not count.
        try rig.store.setProviderCaps(ProviderCaps(monthlyUSD: 100), companyId: rig.companyId, provider: "groq")
        let message = "Brahma: no cap set for anthropic; run brahma billing \(rig.companyId) caps anthropic --monthly-cap <usd>"
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try rig.meter.reserve(rig.grant(), model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1))
        }, type: GatewayRefusal.type, message)
        #expect(try rig.charges().isEmpty)

        let gateway = try ModelGatewayRig([ModelGatewayTests.ok], caps: nil)
        let r = try await gateway.exchange(ModelGatewayTests.body("claude-opus-5-5"), token: gateway.grant())
        #expect(r.status == 400 && r.errorType == "invalid_request_error", "\(r.text)")
        #expect(r.text.contains("Brahma: no cap set for anthropic; run brahma billing \(gateway.companyId) caps anthropic --monthly-cap <usd>"),
                "\(r.text)")
        #expect(gateway.upstream.requests.isEmpty)
        #expect(try gateway.charges().isEmpty)
    }

    /// A routed model with no price (pinned or owner) is refused with how to price it; an owner row prices it.
    @Test func unpricedRefused() async throws {
        let target = TurnGrant.RoutedTarget(provider: "anthropic", model: "claude-opus-9-9")
        let rig = try Rig()
        let g = rig.grant(aliases: ["brahma-deep": target])
        let message = "Brahma: no price for anthropic/claude-opus-9-9; run brahma settings model-price anthropic/claude-opus-9-9 <in> <out>"
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try rig.meter.reserve(g, model: "brahma-deep", maxTokens: 1, body: Self.ascii(1))
        }, type: GatewayRefusal.type, message)
        #expect(try rig.charges().isEmpty)
        // A refused (zero) owner row leaves it unpriced; a valid one prices it.
        let zeroRow = PriceRow(provider: "anthropic", model: "claude-opus-9-9", inPerMTok: 0, outPerMTok: 0, setBy: "owner")
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try Rig.meter(rig.store, clock: rig.clock, prices: [zeroRow]).reserve(g, model: "brahma-deep", maxTokens: 1, body: Self.ascii(1))
        }, type: GatewayRefusal.type, message)
        var priced = zeroRow
        priced.inPerMTok = 1; priced.outPerMTok = 2
        let r = try Rig.meter(rig.store, clock: rig.clock, prices: [priced]).reserve(g, model: "brahma-deep", maxTokens: 1000, body: Self.ascii(3))
        #expect(r.provider == "anthropic" && r.model == "claude-opus-9-9" && abs(r.estimateUSD - (1 * 1 + 1000 * 2) / 1e6) < 1e-12)

        let gateway = try ModelGatewayRig([ModelGatewayTests.ok])
        let refused = try await gateway.exchange(ModelGatewayTests.body("brahma-deep"), token: gateway.grant(aliases: ["brahma-deep": target]))
        #expect(refused.status == 400 && refused.text.contains("Brahma: no price for anthropic/claude-opus-9-9"), "\(refused.text)")
        #expect(gateway.upstream.requests.isEmpty)
        #expect(try gateway.charges().isEmpty)
    }

    // MARK: Property: concurrent requests never overrun a cap by more than one request

    /// The repo has no `FuzzConfig`: a seeded SplitMix64 (`SeededBytes`, as the fuzz tests use) over a pinned case count.
    static let propertyCases = 40
    static let propertySeed: UInt64 = 0x5EED_0009

    struct PlannedRequest {
        var model: String
        var maxTokens: Int
        var inputBytes: Int
        /// nil: the usage is missing (charged the estimate).
        var usage: GatewayUsage?
        /// Settled only after every request of its round has reserved (open reservations pile up).
        var deferred: Bool
    }

    struct PlannedCase {
        var monthlyUSD: Double
        var dailyUSD: Double
        /// Draws usage above the estimate too; otherwise every actual is at most its reservation.
        var overshoot: Bool
        /// (day of month, hour, requests); the first round's requests are all deferred.
        var rounds: [(day: Int, hour: Int, requests: [PlannedRequest])]
    }

    static func plan(_ index: Int) -> PlannedCase {
        var rng = SeededBytes(state: propertySeed &+ UInt64(index) &* 0x9E37_79B9)
        let overshoot = index % 2 == 1
        func request(deferred: Bool) -> PlannedRequest {
            let opus = rng.below(2) == 0
            let maxTokens = 100 + rng.below(3900)
            let bytes = 300 + rng.below(29_700)
            let estIn = (bytes + 2) / 3
            var usage: GatewayUsage?
            if rng.below(6) != 0 {
                usage = overshoot
                    ? GatewayUsage(inputTokens: rng.below(2 * estIn + 1), outputTokens: rng.below(2 * maxTokens + 1),
                                   cacheReadTokens: rng.below(estIn + 1), cacheWriteTokens: rng.below(3) == 0 ? rng.below(estIn + 1) : 0)
                    : GatewayUsage(inputTokens: rng.below(estIn + 1), outputTokens: rng.below(maxTokens + 1), cacheReadTokens: 0,
                                   cacheWriteTokens: 0)
            }
            return PlannedRequest(model: opus ? "claude-opus-5-5" : "brahma-standard", maxTokens: maxTokens, inputBytes: bytes,
                                  usage: usage, deferred: deferred)
        }
        let daily = 0.05 + Double(rng.below(350)) / 1000
        let monthly = daily * (1.5 + Double(rng.below(150)) / 100)
        var rounds: [(Int, Int, [PlannedRequest])] = []
        var day = 1
        for round in 0..<3 {
            day += rng.below(2)   // two rounds may share a day
            rounds.append((day, 8 + round * 4 + rng.below(3), (0..<(6 + rng.below(9))).map { _ in request(deferred: round == 0 || rng.below(3) == 0) }))
        }
        return PlannedCase(monthlyUSD: monthly, dailyUSD: daily, overshoot: overshoot, rounds: rounds)
    }

    struct PropertyRun {
        var violations: [String] = []
        var admitted = 0
        var refused = 0
        var windowsWithOvershoot = 0
        var windowsWithoutOvershoot = 0
    }

    /// Runs every planned case through `meter` (one month each, in the owner's zone), each round's requests concurrently, and
    /// checks every day and month window: total charged ≤ cap + the largest single charge + Σ max(0, actual − reserved).
    static func runProperty(_ rig: Rig) throws -> PropertyRun {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var run = PropertyRun()
        let g = rig.grant()
        for index in 0..<propertyCases {
            let planned = plan(index)
            try rig.store.setProviderCaps(ProviderCaps(monthlyUSD: planned.monthlyUSD, dailyUSD: planned.dailyUSD), companyId: rig.companyId,
                                          provider: "anthropic")
            let estimates = Locked<[Int64: Double]>([:])
            let counts = Locked((admitted: 0, refused: 0))
            var days = Set<Int>()
            var anyTime = Date()
            for round in planned.rounds {
                let at = try #require(calendar.date(from: DateComponents(year: 2030 + index / 12, month: index % 12 + 1, day: round.day,
                                                                         hour: round.hour, minute: 7)))
                rig.clock.now = at
                anyTime = at
                days.insert(round.day)
                let deferred = Locked<[(GatewayMeter.Reservation, GatewayUsage?)]>([])
                DispatchQueue.concurrentPerform(iterations: round.requests.count) { n in
                    let request = round.requests[n]
                    do {
                        let r = try rig.meter.reserve(g, model: request.model, maxTokens: request.maxTokens, body: Self.ascii(request.inputBytes))
                        estimates.with { $0[r.id] = r.estimateUSD }
                        counts.with { $0.admitted += 1 }
                        if request.deferred {
                            deferred.with { $0.append((r, request.usage)) }
                        } else {
                            rig.meter.settle(r, usage: request.usage)
                        }
                    } catch {
                        counts.with { $0.refused += 1 }
                    }
                }
                let open = deferred.with { $0 }
                DispatchQueue.concurrentPerform(iterations: open.count) { n in rig.meter.settle(open[n].0, usage: open[n].1) }
            }
            let c = counts.with { $0 }
            run.admitted += c.admitted; run.refused += c.refused
            var windows: [(String, (Date, Date), Double)] = [("month", try Store.spendWindow(.month, now: anyTime, zone: zone), planned.monthlyUSD)]
            for day in days.sorted() {
                let at = try #require(calendar.date(from: DateComponents(year: 2030 + index / 12, month: index % 12 + 1, day: day, hour: 12)))
                windows.append(("day \(day)", try Store.spendWindow(.day, now: at, zone: zone), planned.dailyUSD))
            }
            let reserved = estimates.with { $0 }
            for (name, window, cap) in windows {
                let rows = try rig.store.writer.read { db in
                    try Row.fetchAll(db, sql: "SELECT id, usd, state FROM gatewayCharge WHERE companyId = ? AND at >= ? AND at < ?",
                                     arguments: [rig.companyId, window.0, window.1])
                }
                var total = 0.0, largest = 0.0, over = 0.0
                for row in rows {
                    let usd: Double = row["usd"], id: Int64 = row["id"]
                    let state: String = row["state"]
                    if state == "reserved" { run.violations.append("case \(index) \(name): charge \(id) left reserved") }
                    total += usd; largest = max(largest, usd)
                    guard let estimate = reserved[id] else {
                        run.violations.append("case \(index) \(name): charge \(id) has no reservation the meter returned")
                        continue
                    }
                    over += max(0, usd - estimate)
                }
                if over > 0 { run.windowsWithOvershoot += 1 } else { run.windowsWithoutOvershoot += 1 }
                if !planned.overshoot, over > 1e-12 { run.violations.append("case \(index) \(name): an actual exceeded its reservation") }
                if total > cap + largest + over + 1e-9 {
                    run.violations.append("case \(index) \(name): \(total) > cap \(cap) + largest \(largest) + over \(over)")
                }
            }
        }
        return run
    }

    @Test func concurrentRequestsNeverExceedCapPlusOneMax() throws {
        let run = try Self.runProperty(try Rig(zone: "Asia/Kolkata"))
        #expect(run.violations.isEmpty, "\(run.violations.prefix(10))")
        // Not vacuous: caps were reached, and both bounds (with and without actuals above their reservations) were exercised.
        #expect(run.refused > 0 && run.admitted > 0, "\(run.admitted) admitted, \(run.refused) refused")
        #expect(run.windowsWithOvershoot > 0 && run.windowsWithoutOvershoot > 0)

        // Positive control: a meter that admits on spend alone (ignoring open reservations) overruns the bound.
        let broken = try Self.runProperty(try Rig(zone: "Asia/Kolkata", admission: { committed, _, cap in committed < cap }))
        #expect(broken.violations.contains { $0.contains(" > cap ") }, "the broken meter must fail the property")
    }

    // MARK: Crash, disconnect, missing usage

    /// A reservation never settled (the engine died) becomes `estimated` at its reserved amount when the next meter recovers —
    /// the gateway's start does it — and counts against the cap.
    @Test func crashBeforeSettleCountsReservation() throws {
        let rig = try Rig(caps: ProviderCaps(monthlyUSD: 10, dailyUSD: 0.05))
        do {
            let dying = Rig.meter(rig.store, clock: rig.clock)
            _ = try dying.reserve(rig.grant(), model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes))
        }
        let next = Rig.meter(rig.store, clock: rig.clock)
        #expect(try next.recover() == 1)
        let row = try #require(try rig.charges().first)
        #expect(row.state == "estimated" && row.estimated && abs(row.usd - Self.small.usd) < 1e-12)
        #expect(try next.recover() == 0)
        #expect(abs(try rig.store.spend(companyId: rig.companyId, provider: "anthropic", period: .day, now: rig.clock.now) - Self.small.usd) < 1e-12)
        _ = try next.reserve(rig.grant(), model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes))
        Self.expectRefusal({ () throws(GatewayError) in
            _ = try next.reserve(rig.grant(), model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1))
        }, type: GatewayRefusal.type, "Brahma: anthropic daily cap of $0.05 reached for \(rig.companyId)")
    }

    /// What `ModelGateway.start` runs before it serves (`recoverOpenReservations`, checked here without binding a port;
    /// `ModelGatewayTests.startsAndStopsOnLoopback` checks that `start` runs it).
    @Test func gatewayStartRecoversReservations() throws {
        let rig = try ModelGatewayRig([ModelGatewayTests.ok])
        let leftover = try rig.meter.reserve(rig.registry.admit(rig.grant().value)!, model: "claude-opus-5-5", maxTokens: 10, body: Self.ascii(30))
        #expect(try rig.charges().map(\.state) == ["reserved"])
        try rig.gateway.recoverOpenReservations()
        #expect(try rig.charges().map(\.state) == ["estimated"])
        #expect(rig.logLines.contains { $0.contains("1 reservation(s) left open by an earlier gateway charged at their estimates") })
        rig.meter.settle(leftover, usage: GatewayUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0))
        #expect(abs(try #require(try rig.charges().first).usd - leftover.estimateUSD) < 1e-12, "a late settle changes nothing")
    }

    // MARK: Ruling X1-37: a response that ends early costs at least its reservation

    static let startEvent = #"event: message_start"# + "\n" + #"data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":25,"output_tokens":1,"cache_read_input_tokens":2000,"cache_creation_input_tokens":100}}}"# + "\n\n"
    static let deltaEvent = #"event: content_block_delta"# + "\n" + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"# + "\n\n"
    /// A streamed request big enough for its reservation to matter: 1000 output tokens (≈ $0.02 on Opus).
    static let streamed = #"{"model":"claude-opus-5-5","max_tokens":1000,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#
    static var streamedEstimate: Double { GatewayMeter.estimate(opus, maxTokens: 1000, body: Data(streamed.utf8)) }

    /// Whether `task` ends within `seconds` (awake): a connection that never ends fails the test instead of hanging it.
    static func ends(_ task: Task<Void, Never>, within seconds: Int = 60) async -> Bool {
        let done = Locked(false)
        Task { await task.value; done.with { $0 = true } }
        return await eventually(within: seconds) { done.with { $0 } }
    }

    /// Starts a streamed request on `feed` and reads its head and first event (the reservation is open meanwhile).
    static func startStream(_ rig: ModelGatewayRig, _ feed: UpstreamFeed, token: GatewayToken) async throws -> (TestPeer, Task<Void, Never>) {
        let (peer, served) = rig.connect()
        await peer.write(rawRequest(token: token.value, body: streamed))
        feed.send(startEvent)
        #expect(try await peer.readHead().status == 200)
        _ = try await peer.readChunk()
        return (peer, served)
    }

    /// The one charge, once settled: `estimated` at the reservation (the usage seen was far below it), never the near-zero
    /// cost of `message_start`'s usage.
    static func expectChargedTheReservation(_ rig: ModelGatewayRig, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(await eventually { (try? rig.charges().first?.state) == "estimated" }, sourceLocation: sourceLocation)
        let row = try #require(try rig.charges().first, sourceLocation: sourceLocation)
        #expect(row.estimated && abs(row.usd - streamedEstimate) < 1e-12, "\(row)", sourceLocation: sourceLocation)
        let seen = opus.cost(GatewayUsage(inputTokens: 25, outputTokens: 1, cacheReadTokens: 2000, cacheWriteTokens: 100))
        #expect(seen < streamedEstimate / 10, sourceLocation: sourceLocation)
    }

    /// A client that disconnects mid-stream is charged at least the reservation, not the usage seen so far.
    @Test func disconnectSettlesAtLeastTheReservation() async throws {
        let feed = UpstreamFeed()
        let rig = try ModelGatewayRig([.feed(status: 200, headers: ["content-type": "text/event-stream"], feed)])
        let (peer, served) = try await Self.startStream(rig, feed, token: rig.grant())
        #expect(try rig.charges().map(\.state) == ["reserved"], "still streaming: the reservation is open")
        peer.close()
        feed.send(Self.deltaEvent)   // cannot be written: the gateway stops relaying and settles
        #expect(await Self.ends(served), "the connection never ended")
        try await Self.expectChargedTheReservation(rig)
        #expect(rig.logLines.contains { $0.contains("settled at estimate: stream ended early") }, "\(rig.logLines)")
        feed.finish()
    }

    /// An upstream that fails midway is charged at least the reservation.
    @Test func upstreamFailureMidwayChargesAtLeastTheReservation() async throws {
        let feed = UpstreamFeed()
        let rig = try ModelGatewayRig([.feed(status: 200, headers: ["content-type": "text/event-stream"], feed)])
        let (peer, served) = try await Self.startStream(rig, feed, token: rig.grant())
        feed.fail()
        #expect(String(decoding: try await peer.readChunk(), as: UTF8.self).contains("the provider stream failed"))
        peer.close()
        #expect(await Self.ends(served), "the connection never ended")
        try await Self.expectChargedTheReservation(rig)
    }

    /// STOP (every token revoked) mid-stream: charged at least the reservation.
    @Test func stopMidwayChargesAtLeastTheReservation() async throws {
        let feed = UpstreamFeed()
        let rig = try ModelGatewayRig([.feed(status: 200, headers: ["content-type": "text/event-stream"], feed)])
        let (peer, served) = try await Self.startStream(rig, feed, token: rig.grant())
        rig.registry.revokeAll(reason: "owner stop")
        #expect(await peer.seesEOF())
        #expect(await Self.ends(served), "the connection never ended")
        try await Self.expectChargedTheReservation(rig)
        feed.finish()
    }

    /// Ruling 56 m5: an SSE `event: error` mid-stream (the provider overloaded), then a normal end with no terminal usage:
    /// charged at least the reservation.
    @Test func midStreamErrorEventChargesAtLeastTheReservation() async throws {
        let error = "event: error\n" + #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"# + "\n\n"
        let rig = try ModelGatewayRig([FakeUpstream.sse(Data((Self.startEvent + error).utf8))])
        let r = try await rig.exchange(Self.streamed, token: rig.grant())
        #expect(r.status == 200 && r.text.contains("overloaded_error"), "\(r.text)")
        try await Self.expectChargedTheReservation(rig)
    }

    /// A stream that finishes normally — terminal usage, `message_stop` — is charged exactly its parsed usage, even far below
    /// the reservation.
    @Test func normalFinishChargesTheExactUsage() async throws {
        let fixture = try AnthropicFixture.data("stream-tools", "sse")
        let rig = try ModelGatewayRig([FakeUpstream.sse(fixture)])
        let r = try await rig.exchange(Self.streamed, token: rig.grant())
        #expect(r.status == 200 && Data(r.body) == fixture)
        let row = try #require(try rig.charges().first)
        let usage = GatewayUsage(inputTokens: 25, outputTokens: 87, cacheReadTokens: 2000, cacheWriteTokens: 100)
        #expect(row.state == "settled" && !row.estimated && row.inputTokens == 25 && row.outputTokens == 87)
        #expect(abs(row.usd - Self.opus.cost(usage)) < 1e-12 && row.usd < Self.streamedEstimate)
        // The same stream without its message_stop is not final.
        let cut = fixture.prefix(upTo: try #require(fixture.range(of: Data("event: message_stop".utf8))).lowerBound)
        let short = try ModelGatewayRig([FakeUpstream.sse(Data(cut))])
        #expect(try await short.exchange(Self.streamed, token: short.grant()).status == 200)
        let estimated = try #require(try short.charges().first)
        #expect(estimated.state == "estimated" && abs(estimated.usd - Self.streamedEstimate) < 1e-12)
    }

    /// A response that ended early but had already reported more than its reservation is charged what it reported.
    @Test func earlyEndAboveTheReservationChargesTheUsageSeen() throws {
        let rig = try Rig()
        let r = try rig.meter.reserve(rig.grant(), model: "claude-opus-5-5", maxTokens: 10, body: Self.ascii(30))
        let seen = GatewayUsage(inputTokens: 100_000, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 0)
        rig.meter.settle(r, UsageOutcome(usage: seen, complete: false))
        let row = try #require(try rig.charges().first)
        #expect(row.state == "estimated" && row.inputTokens == 100_000 && abs(row.usd - Self.opus.cost(seen)) < 1e-12)
        #expect(row.usd > r.estimateUSD)
    }

    /// Cutting stream after stream does not dodge the cap: each costs its reservation, and the cap refuses the next.
    @Test func repeatedCutStreamsReachTheCap() async throws {
        let feeds = (0..<3).map { _ in UpstreamFeed() }
        let rig = try ModelGatewayRig(feeds.map { .feed(status: 200, headers: ["content-type": "text/event-stream"], $0) },
                                      caps: ProviderCaps(monthlyUSD: 100, dailyUSD: 2.5 * Self.streamedEstimate))
        let token = rig.grant()
        for (index, feed) in feeds.enumerated() {
            let (peer, served) = try await Self.startStream(rig, feed, token: token)
            peer.close()
            feed.send(Self.deltaEvent)
            #expect(await Self.ends(served), "the connection never ended")
            feed.finish()
        }
        #expect(await eventually { ((try? rig.charges()) ?? []).allSatisfy { $0.state == "estimated" } })
        let refused = try await rig.exchange(Self.streamed, token: token)
        #expect(refused.status == 400 && refused.errorType == "invalid_request_error", "\(refused.text)")
        #expect(refused.text.contains("Brahma: anthropic daily cap of $"), "\(refused.text)")
        #expect(rig.upstream.requests.count == 3)
    }

    /// No usage: the row is `estimated` at the reservation — from the meter, and from a forwarded response that reported none
    /// (Ruling 52(a): never zero).
    @Test func missingUsageChargedAtEstimate() async throws {
        let rig = try Rig()
        let r = try rig.meter.reserve(rig.grant(), model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes))
        rig.meter.settle(r, usage: nil)
        rig.meter.settle(r, usage: GatewayUsage(inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0))  // idempotent
        let row = try #require(try rig.charges().first)
        #expect(row.state == "estimated" && row.estimated && abs(row.usd - Self.small.usd) < 1e-12)
        #expect(row.inputTokens == 1000 && row.outputTokens == 1000)

        let gateway = try ModelGatewayRig([FakeUpstream.json(200, #"{"type":"message","content":[]}"#)])
        let body = ModelGatewayTests.body("claude-opus-5-5")
        #expect(try await gateway.exchange(body, token: gateway.grant()).status == 200)
        let charged = try #require(try gateway.charges().first)
        #expect(charged.state == "estimated" && charged.usd > 0)
        #expect(abs(charged.usd - GatewayMeter.estimate(Self.opus, maxTokens: 16, body: Data(body.utf8))) < 1e-12)
    }

    /// A body in Chinese and Japanese (Ruling 54): every scalar at or above U+0080 is reserved as two input tokens, so the
    /// estimate holds at least two tokens per CJK character; an ASCII body is still reserved at ceil(bytes / 3). The
    /// fixture's true count is not known here (no model API in tests): Task 16's live run records `count_tokens` for
    /// `request-cjk.json` and asserts the estimate is at least that.
    @Test func nonASCIIInputEstimateIsConservative() async throws {
        let body = try AnthropicFixture.text("request-cjk", "json").trimmingCharacters(in: .newlines)
        let cjk = body.unicodeScalars.filter { $0.value >= 0x2E80 }.count
        #expect(cjk > 800)
        let reserved = GatewayMeter.estimatedInputTokens(Data(body.utf8))
        #expect(reserved >= 2 * cjk, "\(reserved) tokens for \(cjk) CJK characters")
        // Under the bytes / 3 rule the same body would have reserved about one token per character.
        #expect(reserved > (body.utf8.count + 2) / 3 + cjk / 2)
        // Through the gateway: the row holds that reservation.
        let rig = try ModelGatewayRig([FakeUpstream.json(200, #"{"type":"message","content":[]}"#)])   // no usage: charged the estimate
        #expect(try await rig.exchange(body, token: rig.grant()).status == 200)
        let row = try #require(try rig.charges().first)
        #expect(row.state == "estimated" && row.inputTokens == reserved)
        #expect(abs(row.usd - GatewayMeter.estimate(Self.opus, maxTokens: 1024, inputTokens: reserved)) < 1e-12)

        // Control: an ASCII body of the same length is still ceil(bytes / 3).
        let ascii = Self.ascii(body.utf8.count)
        #expect(GatewayMeter.estimatedInputTokens(ascii) == (body.utf8.count + 2) / 3)
    }

    /// A provider's usage claiming −5 or 10¹² tokens is clamped before it is priced: the charge is finite and not negative.
    @Test func negativeOrHugeUsageClamped() async throws {
        let rig = try Rig()
        let r = try rig.meter.reserve(rig.grant(), model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1))
        rig.meter.settle(r, usage: GatewayUsage(inputTokens: -5, outputTokens: 1_000_000_000_000, cacheReadTokens: .min, cacheWriteTokens: .max))
        let row = try #require(try rig.charges().first)
        #expect(row.state == "settled" && row.inputTokens == 0 && row.cacheReadTokens == 0)
        #expect(row.outputTokens == GatewayUsage.maxTokens && row.cacheWriteTokens == GatewayUsage.maxTokens)
        #expect(row.usd.isFinite && abs(row.usd - Double(GatewayUsage.maxTokens) * (20 + 8) / 1e6) < 1e-9)

        let gateway = try ModelGatewayRig([FakeUpstream.json(200, #"{"type":"message","usage":{"input_tokens":-5,"output_tokens":1000000000000,"cache_read_input_tokens":1e300}}"#)])
        #expect(try await gateway.exchange(ModelGatewayTests.body("claude-opus-5-5"), token: gateway.grant()).status == 200)
        let charged = try #require(try gateway.charges().first)
        #expect(charged.state == "settled" && charged.inputTokens == 0 && charged.outputTokens == GatewayUsage.maxTokens)
        #expect(charged.cacheReadTokens == GatewayUsage.maxTokens && charged.usd.isFinite && charged.usd >= 0)
    }

    /// The month (and day) are the owner's calendar: at 23:30 on Jan 31 in Kolkata the January cap is reached; at 00:30 on
    /// Feb 1 there — still January in UTC — the new month admits again.
    @Test func monthRollsOverInOwnerTimeZone() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2027, month: month, day: day, hour: hour, minute: minute)))
        }
        let rig = try Rig(caps: ProviderCaps(monthlyUSD: 0.05, dailyUSD: 1), zone: "Asia/Kolkata", at: try at(1, 31, 23, 30))
        let g = rig.grant()
        for _ in 0..<2 { _ = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes)) }
        let refusal = "Brahma: anthropic monthly cap of $0.05 reached for \(rig.companyId)"
        Self.expectRefusal({ () throws(GatewayError) in _ = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1)) },
                           type: GatewayRefusal.type, refusal)
        rig.clock.now = try at(1, 31, 23, 59)
        Self.expectRefusal({ () throws(GatewayError) in _ = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: 1, body: Self.ascii(1)) },
                           type: GatewayRefusal.type, refusal)
        rig.clock.now = try at(2, 1, 0, 30)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(utc.component(.month, from: rig.clock.now) == 1, "still January in UTC")
        _ = try rig.meter.reserve(g, model: "claude-opus-5-5", maxTokens: Self.small.maxTokens, body: Self.ascii(Self.small.bytes))
        #expect(abs(try rig.store.spend(companyId: rig.companyId, provider: "anthropic", period: .month, now: rig.clock.now) - Self.small.usd) < 1e-12)
    }

    // MARK: Item budgets

    /// A company with an engineer leased a tier S task (cost cap $3.00), as `BudgetTests` sets one up.
    struct ItemWorld {
        let w: World
        let c: Company
        let eng: Agent
        let item: WorkItem

        init() throws {
            w = try World()
            c = try w.company("Acme")
            let mgr = try w.hire(c, "mgr", role: "manager")
            eng = try w.store.hire(companyId: c.id, name: "eng", role: "engineer", model: "sonnet", managerId: mgr.id)
            item = try w.store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Do it", checkSpec: CheckSpec(command: "true", paths: ["src/a"]), tier: .s, status: .ready), now: w.clock.now)
            _ = try w.store.claimLease(itemId: item.id, agentId: eng.id, now: w.clock.now)
        }

        static func charge(_ store: Store, company: String, item: String, agent: String, turn: String, usd: Double, at: Date) throws {
            try store.recordCharge(GatewayCharge(companyId: company, turnId: turn, itemId: item, agentId: agent, provider: "anthropic",
                                                 model: "claude-opus-5-5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                                 cacheWriteTokens: 0, usd: usd, estimated: false, at: at))
        }

        /// One engineer work turn reporting $0.01 of subscription cost; `during` runs while it is in progress (its turn id).
        func turn(during: (@Sendable (String) throws -> Void)? = nil) async throws {
            let store = w.store, eng = eng
            var script = FakeTurnRunner.Script(events: [.initialized(sessionId: "s-eng", model: "claude-sonnet-5-5"),
                .result(TurnResult(isError: false, subtype: "success", text: "done", costUSD: 0.01, apiErrorStatus: nil, sessionId: "s-eng"))])
            if let during {
                script.sideEffect = { _ in
                    let id = try #require(try store.writer.read {
                        try String.fetchOne($0, sql: "SELECT id FROM turn WHERE agentId = ? AND outcome = 'inProgress'", arguments: [eng.id])
                    })
                    try during(id)
                }
            }
            w.fake.script(eng.name, script)
            try w.dm(c, eng)
            w.clock.advance(1)
            try await w.cycle()
        }
    }

    /// Item budgets count gateway dollars (cost = subscription $LE + metered USD), with today's text:
    /// - the budget step: $1.50 metered before a turn and $2.00 during it, plus the turn's $0.01, pass the tier S cap of $3.00;
    /// - the no-launch rule: an item whose metered $3.00 leaves nothing for a Quick turn is blocked before any turn;
    /// - the item's fact keeps the two apart (`costLE` subscription-only, `meteredUSD` the gateway's).
    @Test func itemBudgetCountsMetered() async throws {
        let a = try ItemWorld()
        let (store, company, item, agent) = (a.w.store, a.c.id, a.item.id, a.eng.id)
        let now = a.w.clock.now
        try ItemWorld.charge(store, company: company, item: item, agent: agent, turn: "t-before", usd: 1.5, at: now)
        try await a.turn { turn in
            for usd in [1.25, 0.75] { try ItemWorld.charge(store, company: company, item: item, agent: agent, turn: turn, usd: usd, at: now) }
        }
        let blocked = try #require(try store.workItem(id: item))
        #expect(blocked.status == .blocked)
        #expect(blocked.blockedReason == "over budget: 1/6 turns, 0k/300k tokens, $3.51/$3.00", "\(blocked.blockedReason ?? "nil")")
        let used = try store.itemUsage(itemId: item)
        #expect(used.turns == 1 && abs(used.costLE - 0.01) < 1e-9 && abs(used.meteredUSD - 3.5) < 1e-12 && abs(used.cost - 3.51) < 1e-9)

        // Facts split cost by mode.
        let fact = try await store.writer.read { db in try OutcomeFactsObserver.fact(db: db, item: blocked, now: now) }
        #expect(abs(fact.costLE - 0.01) < 1e-9 && abs(fact.meteredUSD - 3.5) < 1e-12)
        try await store.writer.write { db in try fact.save(db) }
        #expect(abs(try #require(try store.itemFact(itemId: item)).meteredUSD - 3.5) < 1e-12)

        let b = try ItemWorld()
        try ItemWorld.charge(b.w.store, company: b.c.id, item: b.item.id, agent: b.eng.id, turn: "t-gw", usd: 3, at: b.w.clock.now)
        try await b.turn()
        let stopped = try #require(try b.w.store.workItem(id: b.item.id))
        #expect(stopped.status == .blocked)
        #expect(stopped.blockedReason == "over budget: 0/6 turns, 0k/300k tokens, $3.00/$3.00", "\(stopped.blockedReason ?? "nil")")
        #expect(try b.w.store.itemUsage(itemId: b.item.id).turns == 0, "no counted turn ran")
    }
}
