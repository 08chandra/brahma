import Foundation

/// One metered gateway request (`gatewayCharge`, `"vX1-gateway"`). A reservation is recorded `reserved` before the request goes
/// upstream and settled from the provider's usage (`settled`), or from the estimate when the usage is missing (`estimated`).
public struct GatewayCharge: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case reserved, settled, estimated
    }

    /// Assigned by the store (`recordCharge`); nil before.
    public var id: Int64?
    public var companyId: String
    /// nil for an engine request outside a turn (a capability probe).
    public var turnId: String?
    public var itemId: String?
    public var agentId: String?
    public var provider: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var usd: Double
    public var estimated: Bool
    public var state: State
    public var at: Date

    public init(id: Int64? = nil, companyId: String, turnId: String?, itemId: String?, agentId: String?, provider: String,
                model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, usd: Double,
                estimated: Bool, state: State = .settled, at: Date) {
        self.id = id; self.companyId = companyId; self.turnId = turnId; self.itemId = itemId; self.agentId = agentId
        self.provider = provider; self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheWriteTokens = cacheWriteTokens; self.usd = usd
        self.estimated = estimated; self.state = state; self.at = at
    }
}
