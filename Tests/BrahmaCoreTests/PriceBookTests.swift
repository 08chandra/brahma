import Foundation
import Testing
@testable import BrahmaCore

/// Plan X1 Task 6: the pinned price book, owner rows over pinned ones, exact-key lookup (spec §8.2.3), the cost of a usage at
/// the cache rates, and `GatewayUsage`'s per-field clamp (Rulings 11, 36).
@Suite(.scratch) struct PriceBookTests {
    private func owner(_ provider: String, _ model: String, _ inRate: Double, _ outRate: Double, cacheRead: Double? = nil,
                       cacheWrite: Double? = nil) -> PriceRow {
        PriceRow(provider: provider, model: model, inPerMTok: inRate, outPerMTok: outRate, cacheReadPerMTok: cacheRead,
                 cacheWritePerMTok: cacheWrite, setBy: "owner")
    }

    @Test func unknownModelHasNoPrice() {
        let book = PriceBook(owner: [])
        #expect(book.price(provider: "anthropic", model: "claude-unknown-9") == nil)
        #expect(book.price(provider: "openai", model: "claude-opus-5-5") == nil, "a pinned model under another provider is unpriced")
        // No OpenAI-compatible model is pinned (Ruling 36): the owner prices them.
        #expect(PriceBook.pinned.keys.allSatisfy { $0.hasPrefix("anthropic/") }, "\(PriceBook.pinned.keys.sorted())")
        #expect(book.price(provider: "", model: "") == nil)
    }

    @Test func pinsEveryAllowlistedModelId() throws {
        let book = PriceBook(owner: [])
        let ids = ModelAllowlist.models.filter { $0.hasPrefix("claude-") }
        #expect(ids.count == 3)
        for id in ids { #expect(book.price(provider: "anthropic", model: id) != nil, "\(id) is unpriced") }
        // Aliases are never keys: the gateway prices the full id the request names.
        for alias in ["opus", "sonnet", "haiku"] { #expect(book.price(provider: "anthropic", model: alias) == nil) }
        // The claude-api skill's pricing reference (cached 2026-10-06), USD per million tokens.
        // Upper bounds (Ruling 37): the 1-hour cache-write rate, and a tiered model's highest tier.
        #expect(PriceBook.pinned["anthropic/claude-opus-5-5"] == Price(inPerMTok: 4, outPerMTok: 20, cacheReadPerMTok: 0.20, cacheWritePerMTok: 8))
        #expect(PriceBook.pinned["anthropic/claude-sonnet-5-5"] == Price(inPerMTok: 2, outPerMTok: 10, cacheReadPerMTok: 0.20, cacheWritePerMTok: 4))
        #expect(PriceBook.pinned["anthropic/claude-haiku-5-5"] == Price(inPerMTok: 0.50, outPerMTok: 2.50, cacheReadPerMTok: 0.05, cacheWritePerMTok: 1))
        #expect(PriceBook.pinnedOn == "2026-10-06")
        #expect(PriceBook.pinned.values.allSatisfy { p in
            ([p.inPerMTok, p.outPerMTok] + [p.cacheReadPerMTok, p.cacheWritePerMTok].compactMap { $0 }).allSatisfy { $0.isFinite && $0 > 0 }
        })
    }

    /// Ruling 37: a price too low fails open against a dollar cap, so every pinned cache write is the 1-hour rate (2× input,
    /// above the 5-minute 1.25×) and Haiku 5.5 is at its >100K-prompt tier, not its $0.10 / $0.50 short-prompt rates.
    @Test func pinnedPricesAreUpperBounds() throws {
        for (key, p) in PriceBook.pinned {
            #expect(p.cacheWritePerMTok == 2 * p.inPerMTok, "\(key) cache write is not the 1-hour rate")
            #expect(p.cacheWriteRate > 1.25 * p.inPerMTok, "\(key)")
        }
        let haiku = try #require(PriceBook.pinned["anthropic/claude-haiku-5-5"])
        #expect(haiku.inPerMTok == 0.50 && haiku.outPerMTok == 2.50, "\(haiku)")
        #expect(haiku.inPerMTok > 0.10 && haiku.outPerMTok > 0.50, "above the short-prompt tier")
    }

    @Test func ownerRowOverridesPinned() {
        let book = PriceBook(owner: [owner("anthropic", "claude-opus-5-5", 7, 30), owner("openai", "gpt-x", 1, 2, cacheRead: 0.5)])
        #expect(book.price(provider: "anthropic", model: "claude-opus-5-5") == Price(inPerMTok: 7, outPerMTok: 30, cacheReadPerMTok: nil, cacheWritePerMTok: nil))
        #expect(book.price(provider: "openai", model: "gpt-x") == Price(inPerMTok: 1, outPerMTok: 2, cacheReadPerMTok: 0.5, cacheWritePerMTok: nil))
        // The other pinned rows stand.
        #expect(book.price(provider: "anthropic", model: "claude-sonnet-5-5") == PriceBook.pinned["anthropic/claude-sonnet-5-5"])
        // An owner model id holding a slash (OpenRouter's `vendor/model`) is one key, split at the provider's slash only.
        let routed = PriceBook(owner: [owner("openrouter", "acme/model-1", 3, 4)])
        #expect(routed.price(provider: "openrouter", model: "acme/model-1")?.inPerMTok == 3)
        #expect(routed.price(provider: "openrouter", model: "model-1") == nil)
    }

    @Test func noPrefixMatching() {
        let book = PriceBook(owner: [owner("openai", "gpt-x", 1, 2)])
        for model in ["claude-opus-5-5-x", "claude-opus-5", "claude-opus", "claude-opus-5-5-20260401", "CLAUDE-OPUS-5-5", " claude-opus-5-5"] {
            #expect(book.price(provider: "anthropic", model: model) == nil, "\(model)")
        }
        for model in ["gpt-x-mini", "gpt", "gpt-x*"] { #expect(book.price(provider: "openai", model: model) == nil, "\(model)") }
        #expect(book.price(provider: "anthropic", model: "claude-opus-5-5") != nil)
    }

    @Test func costUsesCacheRates() {
        let p = Price(inPerMTok: 4, outPerMTok: 20, cacheReadPerMTok: 0.2, cacheWritePerMTok: 5)
        let u = GatewayUsage(inputTokens: 1_000_000, outputTokens: 500_000, cacheReadTokens: 2_000_000, cacheWriteTokens: 100_000)
        // 4 + 10 + 0.4 + 0.5
        #expect(abs(p.cost(u) - 14.9) < 1e-9, "\(p.cost(u))")
        // Unset cache rates are the input rate.
        let plain = Price(inPerMTok: 3, outPerMTok: 15, cacheReadPerMTok: nil, cacheWritePerMTok: nil)
        let cached = GatewayUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)
        #expect(abs(plain.cost(cached) - 6) < 1e-9, "\(plain.cost(cached))")
        #expect(p.cost(GatewayUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)) == 0)
        // An owner row's price is that row's rates.
        #expect(Price(owner("x", "y", 1, 2, cacheWrite: 9)) == Price(inPerMTok: 1, outPerMTok: 2, cacheReadPerMTok: nil, cacheWritePerMTok: 9))
    }

    @Test func usageIsClampedPerField() throws {
        let u = GatewayUsage(inputTokens: -5, outputTokens: 20_000_000, cacheReadTokens: Int.max, cacheWriteTokens: Int.min)
        #expect(u == GatewayUsage(inputTokens: 0, outputTokens: 10_000_000, cacheReadTokens: 10_000_000, cacheWriteTokens: 0))
        #expect(GatewayUsage.maxTokens == 10_000_000)
        let kept = GatewayUsage(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4)
        #expect([kept.inputTokens, kept.outputTokens, kept.cacheReadTokens, kept.cacheWriteTokens] == [Int]([1, 2, 3, 4]))
        // Decoding clamps too: a provider's usage never reaches the meter out of range.
        let json = #"{"inputTokens":-1,"outputTokens":99999999999,"cacheReadTokens":7,"cacheWriteTokens":10000000}"#
        let decoded = try JSONDecoder().decode(GatewayUsage.self, from: Data(json.utf8))
        #expect(decoded == GatewayUsage(inputTokens: 0, outputTokens: 10_000_000, cacheReadTokens: 7, cacheWriteTokens: 10_000_000))
        let round = try JSONDecoder().decode(GatewayUsage.self, from: try JSONEncoder().encode(kept))
        #expect(round == kept)
    }

    @Test func refusesNonFiniteNegativeAndZeroRows() {
        #expect(PriceBook.refusal(for: owner("openai", "gpt-x", 1, 2, cacheRead: 0.5, cacheWrite: 1)) == nil)
        for bad in [owner("openai", "gpt-x", -1, 2), owner("openai", "gpt-x", .nan, 2), owner("openai", "gpt-x", 1, .infinity),
                    owner("openai", "gpt-x", 1, 2, cacheRead: -0.1), owner("openai", "gpt-x", 1, 2, cacheWrite: .nan)] {
            #expect(PriceBook.refusal(for: bad) == "prices must be finite and zero or more dollars per million tokens", "\(bad)")
        }
        // No `local` adapter exists yet (X1b), so zero is refused for every provider (Ruling 36).
        for zero in [owner("openai", "gpt-x", 0, 2), owner("anthropic", "m", 1, 0), owner("groq", "m", 1, 2, cacheRead: 0),
                     owner("openai", "gpt-x", 1, 2, cacheWrite: 0)] {
            #expect(PriceBook.refusal(for: zero) == "zero prices are only for local providers", "\(zero)")
        }
    }
}
