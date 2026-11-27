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

/// An item's spending so far: work turns that were not infrastructure failures or session resets, plus every dollar the
/// model gateway charged for it (Plan X1 Task 9).
public struct ItemUsage: Equatable, Sendable {
    public var turns = 0
    /// `TurnUsage.counted` summed over the turns.
    public var tokens = 0
    /// The subscription turns' list-equivalent cost (`turn.costLE`; gateway turns leave it nil).
    public var costLE = 0.0
    /// The gateway's charges for the item (`gatewayCharge`, every state: an open reservation counts at its estimate).
    public var meteredUSD = 0.0

    /// What the item's cost cap is held against: subscription $LE plus gateway dollars, so item budgets bound gateway spend
    /// too (spec §8.2.3).
    public var cost: Double { costLE + meteredUSD }

    public init(turns: Int = 0, tokens: Int = 0, costLE: Double = 0, meteredUSD: Double = 0) {
        self.turns = turns; self.tokens = tokens; self.costLE = costLE; self.meteredUSD = meteredUSD
    }
}

public enum BudgetText {
    /// What the over-budget DM tells the manager: usage is counted per item, so an unblock alone re-blocks after one more turn.
    public static let escalationAdvice = "Usage is counted per item, so unblocking it as is blocks it again after one more turn. "
        + "Raise the tier or boost the budget, split the item or reassign it."

    /// `16/15 turns, 1050k/1000k tokens, $11.20/$10.00`, plus `≈4% of week` once the weekly calibration exists.
    public static func parts(usage: ItemUsage, budget: TierBudget, costCapLE: Double, pctPerDollar: Double?) -> String {
        var text = "\(usage.turns)/\(budget.maxTurns) turns, \(usage.tokens / 1000)k/\(budget.maxTokens / 1000)k tokens, "
            + "$\(money(usage.cost))/$\(money(costCapLE))"
        // The week share calibrates subscription $LE; gateway dollars are not part of the weekly subscription window.
        if let pctPerDollar, pctPerDollar > 0 {
            text += ", ≈\(Int((usage.costLE * pctPerDollar * 100).rounded()))% of week"
        }
        return text
    }

    static func money(_ value: Double) -> String { String(format: "%.2f", value) }
}

extension Store {
    /// Turns, counted tokens and cost recorded against the item. Review turns, infrastructure failures and session
    /// resets are not part of it; an interrupted or usage-limited turn adds its tokens and cost but is not a turn. An Ultra
    /// turn's tokens are left out of the tier token cap (its $LE cap governs it, Task 14u); it still counts as one turn.
    /// `meteredUSD` is every gateway charge carrying the item, whatever turn made it: those dollars were spent (fail closed).
    public func itemUsage(itemId: String) throws -> ItemUsage {
        try writer.read { db in try Store.itemUsage(db: db, itemId: itemId) }
    }

    static func itemUsage(db: Database, itemId: String) throws -> ItemUsage {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN outcome IN ('succeeded', 'failed') THEN 1 ELSE 0 END), 0) AS turns,
                   COALESCE(SUM(CASE WHEN mode = 'ultra' THEN 0 ELSE inputTokens + outputTokens + cacheCreationTokens END), 0) AS tokens,
                   COALESCE(SUM(costLE), 0) AS cost
            FROM turn
            WHERE itemId = ? AND kind = 'work' AND infra = 0 AND sessionResetReason IS NULL
              AND (stopReason IS NULL OR stopReason <> 'sessionReset')
            """, arguments: [itemId])
        let metered = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(usd), 0) FROM gatewayCharge WHERE itemId = ?",
                                          arguments: [itemId]) ?? 0
        return ItemUsage(turns: row?["turns"] ?? 0, tokens: row?["tokens"] ?? 0, costLE: row?["cost"] ?? 0, meteredUSD: metered)
    }
}
