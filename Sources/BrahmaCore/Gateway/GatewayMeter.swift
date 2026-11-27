import Foundation

/// The gateway's dollar meter (Plan X1 Task 9): every request is reserved before it is sent and settled after, against the
/// company's per-provider daily and monthly caps (spec §8.2.3, §8.2.5 "Money").
///
/// - **Reserve.** The request's routed `<provider>/<model>` must be priced (`PriceBook`) and the company must have caps for
///   that provider; otherwise it is refused. For each of the owner-calendar day and month it is admitted only while
///   `committed + reserved < cap` — committed is every settled or estimated charge, reserved every open reservation — and
///   the reservation is written to the database (`gatewayCharge`, `state = 'reserved'`, the estimate as `usd`) in the same
///   immediate transaction, so concurrent requests can never all slip under the cap on the same spend. The worst overrun of a
///   period is one request's charge plus what requests used beyond their estimates (an in-flight response is never cut).
/// - **Settle.** The row becomes `settled` at the cost of the provider's final usage (clamped by `GatewayUsage`). Without a
///   final usage — missing (Ruling 52(a): never zero) or a response that ended early (Ruling X1-37: a client cut, a cancel or
///   STOP, an upstream failure midway, no terminal usage event) — it becomes `estimated` at max(cost of the usage seen,
///   reserved amount): `estimated` always means "charged at least the reservation, not from a final usage report", and the
///   log says "settled at estimate: stream ended early". Only a `reserved` row changes, so settling is idempotent. A
///   request that never left the gateway is released (Ruling 23: a refused request is never charged).
/// - **Recover.** At gateway start every `reserved` row left by a gateway that died becomes `estimated` at its reserved
///   amount, so a `kill -9` never under-records spend.
///
/// Every amount is finite and zero or more; a cost that is not falls back to the estimate.
public final class GatewayMeter: Sendable {
    /// One open reservation: the row it wrote and what it holds.
    public struct Reservation: Sendable, Equatable {
        /// The `gatewayCharge` row.
        public let id: Int64
        public let companyId: String
        /// The routed provider and its model id (Ruling 14: caps are per routed target).
        public let provider: String
        public let model: String
        /// What the reservation holds, and what the request is charged when its usage is missing.
        public let estimateUSD: Double
        /// The price at reservation time: the settle uses it, so a price change mid-request changes nothing.
        let price: Price
    }

    /// Whether one period admits a request: `committed` (settled and estimated charges) and `reserved` (open reservations)
    /// against its cap. A seam for the tests' positive control (a meter that ignores reservations must fail the cap property).
    typealias Admission = @Sendable (_ committed: Double, _ reserved: Double, _ cap: Double) -> Bool

    /// The admission rule (spec §8.2.3 worst case): spend so far, open reservations included, is below the cap.
    static let admits: Admission = { committed, reserved, cap in committed + reserved < cap }

    private let store: Store
    private let prices: @Sendable () -> PriceBook
    private let clock: @Sendable () -> Date
    private let admission: Admission
    private let log: @Sendable (String) -> Void

    /// `prices` is read per request (owner rows may change); `clock` stamps reservations and picks the day and month (the
    /// owner's time zone); `log` gets a line when a charge cannot be settled (it then stays reserved, at its estimate).
    public convenience init(store: Store, prices: @escaping @Sendable () -> PriceBook, clock: @escaping @Sendable () -> Date,
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(store: store, prices: prices, clock: clock, admission: Self.admits, log: log)
    }

    init(store: Store, prices: @escaping @Sendable () -> PriceBook, clock: @escaping @Sendable () -> Date, admission: @escaping Admission,
         log: @escaping @Sendable (String) -> Void) {
        self.store = store; self.prices = prices; self.clock = clock; self.admission = admission; self.log = log
    }

    // MARK: Estimate

    /// The reservation, and the charge when usage is missing: input `estimatedInputTokens(body)` tokens at the higher of the
    /// input and cache-write rates, output `maxTokens` (at most `GatewayUsage.maxTokens`, the most any usage is metered for)
    /// at the output rate.
    public static func estimate(_ price: Price, maxTokens: Int, body: Data) -> Double {
        estimate(price, maxTokens: maxTokens, inputTokens: estimatedInputTokens(body))
    }

    static func estimate(_ price: Price, maxTokens: Int, inputTokens: Int) -> Double {
        let input = Double(max(inputTokens, 0)) * max(price.inPerMTok, price.cacheWriteRate)
        let output = Double(estimatedOutputTokens(maxTokens)) * price.outPerMTok
        return (input + output) / 1_000_000
    }

    /// The input tokens a body is reserved for (Ruling 54): `ceil(asciiBytes / 3)` plus two per Unicode scalar at or above
    /// U+0080 — a per-byte count would reserve one token per 3-byte CJK character, which can undercount (undercount fails
    /// open). Bytes that are not UTF-8 count as U+FFFD (two tokens each).
    public static func estimatedInputTokens(_ body: Data) -> Int {
        var ascii = 0, other = 0
        for scalar in String(decoding: body, as: UTF8.self).unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return ascii / 3 + (ascii % 3 == 0 ? 0 : 1) + 2 * other
    }

    static func estimatedOutputTokens(_ maxTokens: Int) -> Int { min(max(maxTokens, 0), GatewayUsage.maxTokens) }

    // MARK: Reserve

    /// Reserves `model` (as the request names it; routed by the grant) for one request with this `body` asking for up to
    /// `maxTokens` output tokens: the row is in the database when this returns. Refused (nothing written): an unrouted or
    /// unpriced model, no caps for the provider, a cap reached, or a meter that cannot record.
    public func reserve(_ g: TurnGrant, model: String, maxTokens: Int, body: Data) throws(GatewayError) -> Reservation {
        let target = try ModelGateway.route(model, grant: g)
        let key = PriceBook.key(provider: target.provider, model: target.model)
        guard let price = prices().price(provider: target.provider, model: target.model) else {
            throw .policy("no price for \(key); run brahma settings model-price \(key) <in> <out>")
        }
        let inputTokens = Self.estimatedInputTokens(body)
        let estimate = Self.estimate(price, maxTokens: maxTokens, inputTokens: inputTokens)
        guard estimate.isFinite, estimate >= 0 else { throw .unavailable("the estimate for \(key) is not a dollar amount") }
        let charge = GatewayCharge(
            companyId: g.companyId, turnId: g.turnId, itemId: g.itemId, agentId: g.agentId, provider: target.provider, model: target.model,
            inputTokens: inputTokens, outputTokens: Self.estimatedOutputTokens(maxTokens), cacheReadTokens: 0,
            cacheWriteTokens: 0, usd: estimate, estimated: true, state: .reserved, at: clock())
        let admission = self.admission
        let id: Int64
        do {
            id = try store.reserveCharge(charge, zone: store.ownerTimeZone()) { caps, day, month in
                guard let caps else {
                    throw GatewayError.policy("no cap set for \(target.provider); run brahma billing \(g.companyId) caps \(target.provider) "
                                              + "--monthly-cap <usd>")
                }
                for (name, split, cap) in [("monthly", month, caps.monthlyUSD), ("daily", day, caps.dailyUSD)] {
                    guard cap.isFinite, cap >= 0 else {
                        throw GatewayError.policy("the \(name) cap for \(target.provider) is not a dollar amount; set it again with "
                                                  + "brahma billing \(g.companyId) caps \(target.provider)")
                    }
                    guard admission(split.committed, split.reserved, cap) else {
                        // Ruling 53: the one refusal vocabulary (400 invalid_request_error) `claude` was seen to end a turn on.
                        throw GatewayError.policy("\(target.provider) \(name) cap of $\(Self.money(cap)) reached for \(g.companyId)")
                    }
                }
            }
        } catch let error as GatewayError {
            throw error
        } catch {
            log("gateway meter: a reservation for \(key) could not be recorded: \(error)")
            throw .unavailable("the meter could not record the request")
        }
        return Reservation(id: id, companyId: g.companyId, provider: target.provider, model: target.model, estimateUSD: estimate,
                           price: price)
    }

    // MARK: Settle

    /// Settles `r` with the provider's **final** `usage` (`settled` at its cost), or at its estimate (`estimated`) when `usage`
    /// is nil. Internal (Ruling 56 m2): a partial usage passed here would be charged as final; callers outside the meter's
    /// tests settle with a `UsageOutcome`. Idempotent: only an open reservation changes.
    func settle(_ r: Reservation, usage: GatewayUsage?) {
        settle(r, UsageOutcome(usage: usage, complete: true))
    }

    /// Settles `r` with what its response came to: a final usage at its cost; anything else (Ruling X1-37) as `estimated` at
    /// max(cost of the usage seen, the reservation) — a response cut short never costs less than it reserved.
    public func settle(_ r: Reservation, _ outcome: UsageOutcome) {
        do {
            let seen = outcome.usage.map { (usage: $0, usd: r.price.cost($0)) }
            if let seen, !(seen.usd.isFinite && seen.usd >= 0) {
                log("gateway meter: charge \(r.id) has a usage cost that is not a dollar amount; charged at its estimate")
                try store.estimateCharge(id: r.id)
            } else if outcome.complete, let seen {
                try store.settleCharge(id: r.id, usage: seen.usage, usd: seen.usd)
            } else if let seen, seen.usd > r.estimateUSD {
                log("gateway meter: charge \(r.id) settled at the usage seen ($\(Self.money(seen.usd)), above its estimate): stream ended early")
                try store.estimateCharge(id: r.id, seen: seen)
            } else {
                if seen != nil { log("gateway meter: charge \(r.id) settled at estimate: stream ended early") }
                try store.estimateCharge(id: r.id)
            }
        } catch {
            log("gateway meter: charge \(r.id) could not be settled; it stays reserved at $\(Self.money(r.estimateUSD)) (\(error))")
        }
    }

    /// Drops `r`: its request never left the gateway (Ruling 23). A release that fails leaves the row reserved, so it is
    /// charged at its estimate (never under-recorded).
    public func release(_ r: Reservation) {
        do {
            try store.releaseReservation(id: r.id)
        } catch {
            log("gateway meter: reservation \(r.id) could not be released; it stays reserved at $\(Self.money(r.estimateUSD)) (\(error))")
        }
    }

    /// Every reservation left open by a gateway that stopped or died becomes `estimated` at its reserved amount. Run before
    /// the gateway serves (`ModelGateway.start`); returns how many there were.
    @discardableResult
    public func recover() throws -> Int {
        try store.recoverReservations()
    }

    static func money(_ value: Double) -> String { String(format: "%.2f", value) }
}
