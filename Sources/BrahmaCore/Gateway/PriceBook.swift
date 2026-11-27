import Foundation

/// One model's price in USD per million tokens. An unset cache rate is the input rate.
public struct Price: Codable, Equatable, Sendable {
    public var inPerMTok: Double
    public var outPerMTok: Double
    public var cacheReadPerMTok: Double?
    public var cacheWritePerMTok: Double?

    public init(inPerMTok: Double, outPerMTok: Double, cacheReadPerMTok: Double?, cacheWritePerMTok: Double?) {
        self.inPerMTok = inPerMTok; self.outPerMTok = outPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok; self.cacheWritePerMTok = cacheWritePerMTok
    }

    /// An owner row's rates.
    public init(_ row: PriceRow) {
        self.init(inPerMTok: row.inPerMTok, outPerMTok: row.outPerMTok, cacheReadPerMTok: row.cacheReadPerMTok,
                  cacheWritePerMTok: row.cacheWritePerMTok)
    }

    /// The cache-read rate in force (the input rate when unset).
    public var cacheReadRate: Double { cacheReadPerMTok ?? inPerMTok }
    /// The cache-write rate in force (the input rate when unset).
    public var cacheWriteRate: Double { cacheWritePerMTok ?? inPerMTok }

    /// What `u` costs in USD.
    public func cost(_ u: GatewayUsage) -> Double {
        (Double(u.inputTokens) * inPerMTok + Double(u.outputTokens) * outPerMTok + Double(u.cacheReadTokens) * cacheReadRate
            + Double(u.cacheWriteTokens) * cacheWriteRate) / 1_000_000
    }
}

/// The prices the gateway meters with (Plan X1 Task 6): rows pinned in code, overridden by the owner's rows (`priceRow`,
/// `brahma settings model-price`). A lookup is by the exact `<provider>/<model>` key: no prefix, alias or wildcard matching, so
/// a model with no row is unpriced and the gateway refuses it (spec §8.2.3, fail closed).
public struct PriceBook: Sendable {
    /// The as-of date of the pinned rows' source, the `claude-api` skill's pricing reference (Ruling 36); the doctor shows it.
    public static let pinnedOn = "2026-10-06"

    /// Keyed `<provider>/<model>`. The Anthropic models `ModelAllowlist.models` resolves to, by full id (X1-0), at that
    /// reference's first-party rates. No OpenAI-compatible model is pinned: the owner prices those (Ruling 36).
    ///
    /// The pinned values are upper bounds (Ruling 37). The meter guards dollar caps, so a price that is too low fails open (a
    /// company spends past its cap) and one that is too high fails closed (a cap trips early). So the cache-write rate is the
    /// 1-hour rate (2× input), never the 5-minute one (1.25×), because the usage does not say which TTL was written. A tiered
    /// model is pinned at its highest tier: Haiku 5.5 is at its rates for prompts above 100K tokens ($0.50 / $2.50), and its
    /// cache rates are derived from that input rate. Cache reads are the reference's stated rates: 0.05× input on Opus 5.5,
    /// $0.20 on Sonnet 5.5, and 0.1× input otherwise. Exact tiering can come later with a tiered `Price`.
    public static let pinned: [String: Price] = [
        "anthropic/claude-opus-5-5": Price(inPerMTok: 4, outPerMTok: 20, cacheReadPerMTok: 0.20, cacheWritePerMTok: 8),
        "anthropic/claude-sonnet-5-5": Price(inPerMTok: 2, outPerMTok: 10, cacheReadPerMTok: 0.20, cacheWritePerMTok: 4),
        "anthropic/claude-haiku-5-5": Price(inPerMTok: 0.50, outPerMTok: 2.50, cacheReadPerMTok: 0.05, cacheWritePerMTok: 1),
    ]

    private let table: [String: Price]

    /// The pinned rows with every owner row laid over them.
    public init(owner: [PriceRow]) {
        var table = Self.pinned
        for row in owner { table[Self.key(provider: row.provider, model: row.model)] = Price(row) }
        self.table = table
    }

    public static func key(provider: String, model: String) -> String { "\(provider)/\(model)" }

    /// The price of exactly this provider's model, or nil when it is unpriced.
    public func price(provider: String, model: String) -> Price? {
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return table[Self.key(provider: provider, model: model)]
    }

    /// Why the owner may not set `row`, or nil. Every rate is finite and not negative; zero is only for a provider whose adapter
    /// is `local`, which X1 does not have (X1b), so a zero rate is refused for every provider (Ruling 36).
    public static func refusal(for row: PriceRow) -> String? {
        let rates = [row.inPerMTok, row.outPerMTok] + [row.cacheReadPerMTok, row.cacheWritePerMTok].compactMap { $0 }
        guard rates.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return "prices must be finite and zero or more dollars per million tokens"
        }
        guard rates.allSatisfy({ $0 > 0 }) else { return "zero prices are only for local providers" }
        return nil
    }
}
