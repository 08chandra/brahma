import Foundation
import GRDB

/// What one item may spend, by its effort tier. One budget unit, three caps: turns, counted tokens
/// (`TurnUsage.counted`: input, output and cache creation) and cost in `total_cost_usd` list-equivalent dollars.
public struct TierBudget: Equatable, Sendable {
    public var maxTurns: Int
    public var maxTokens: Int
    public var maxCostLE: Double
    /// The model `auto` agents use on this tier; nil keeps the role's default.
    public var model: String?

    public init(maxTurns: Int, maxTokens: Int, maxCostLE: Double, model: String?) {
        self.maxTurns = maxTurns; self.maxTokens = maxTokens; self.maxCostLE = maxCostLE; self.model = model
    }

    public static let small = TierBudget(maxTurns: 6, maxTokens: 300_000, maxCostLE: 3, model: nil)
    public static let medium = TierBudget(maxTurns: 15, maxTokens: 1_000_000, maxCostLE: 10, model: nil)
    public static let large = TierBudget(maxTurns: 30, maxTokens: 3_000_000, maxCostLE: 40, model: "opus")

    public static func of(_ tier: EffortTier) -> TierBudget {
        switch tier {
        case .s: small
        case .m: medium
        case .l: large
        }
    }
}

/// An item's spending so far: work turns that were not infrastructure failures or session resets.
public struct ItemUsage: Equatable, Sendable {
    public var turns = 0
    /// `TurnUsage.counted` summed over the turns.
    public var tokens = 0
    public var costLE = 0.0

    public init(turns: Int = 0, tokens: Int = 0, costLE: Double = 0) {
        self.turns = turns; self.tokens = tokens; self.costLE = costLE
    }
}

public enum BudgetText {
    /// `16/15 turns, 1050k/1000k tokens, $11.20/$10.00`, plus `≈4% of week` once the weekly calibration exists.
    public static func parts(usage: ItemUsage, budget: TierBudget, costCapLE: Double, pctPerDollar: Double?) -> String {
        var text = "\(usage.turns)/\(budget.maxTurns) turns, \(usage.tokens / 1000)k/\(budget.maxTokens / 1000)k tokens, "
            + "$\(money(usage.costLE))/$\(money(costCapLE))"
        if let pctPerDollar, pctPerDollar > 0 {
            text += ", ≈\(Int((usage.costLE * pctPerDollar * 100).rounded()))% of week"
        }
        return text
    }

    static func money(_ value: Double) -> String { String(format: "%.2f", value) }
}

extension Store {
    /// Turns, counted tokens and cost recorded against the item. Review turns, infrastructure failures and session
    /// resets are not part of it; an interrupted or usage-limited turn adds its tokens and cost but is not a turn.
    public func itemUsage(itemId: String) throws -> ItemUsage {
        try writer.read { db in try Store.itemUsage(db: db, itemId: itemId) }
    }

    static func itemUsage(db: Database, itemId: String) throws -> ItemUsage {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN outcome IN ('succeeded', 'failed') THEN 1 ELSE 0 END), 0) AS turns,
                   COALESCE(SUM(inputTokens + outputTokens + cacheCreationTokens), 0) AS tokens,
                   COALESCE(SUM(costLE), 0) AS cost
            FROM turn
            WHERE itemId = ? AND kind = 'work' AND infra = 0 AND sessionResetReason IS NULL
              AND (stopReason IS NULL OR stopReason <> 'sessionReset')
            """, arguments: [itemId])
        return ItemUsage(turns: row?["turns"] ?? 0, tokens: row?["tokens"] ?? 0, costLE: row?["cost"] ?? 0)
    }
}
