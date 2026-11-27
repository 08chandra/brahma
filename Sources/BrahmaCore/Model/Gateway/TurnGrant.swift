import Foundation

/// What one turn's gateway token entitles it to (Plan X1 Task 7, Ruling 14): the turn it belongs to, and which request models
/// the gateway will serve for it and where they go.
public struct TurnGrant: Sendable, Equatable {
    /// Where an alias is served: a provider and that provider's model id (Ruling 14). Nested because `BrahmaCore` already has a
    /// `RoutedTarget` (Show routing); R's module split can lift it to `BrahmaModel.RoutedTarget` unchanged.
    public struct RoutedTarget: Sendable, Equatable, Hashable, Codable {
        public var provider: String
        public var model: String

        public init(provider: String, model: String) {
            self.provider = provider; self.model = model
        }
    }

    public var turnId: String
    public var companyId: String
    public var agentId: String
    public var itemId: String?
    /// The decision class's provider (Ruling 14); each alias names its own target.
    public var provider: String
    /// Request model (e.g. `brahma-standard`) → the provider and upstream model that serve it.
    public var aliases: [String: RoutedTarget]
    /// Anthropic billing: the Claude model ids accepted as sent (passed through unchanged).
    public var passThroughFamilies: Set<String>
    /// Models that must not receive `tools`.
    public var textOnlyModels: Set<String>

    public init(turnId: String, companyId: String, agentId: String, itemId: String? = nil, provider: String,
                aliases: [String: RoutedTarget] = [:], passThroughFamilies: Set<String> = [], textOnlyModels: Set<String> = []) {
        self.turnId = turnId; self.companyId = companyId; self.agentId = agentId; self.itemId = itemId; self.provider = provider
        self.aliases = aliases; self.passThroughFamilies = passThroughFamilies; self.textOnlyModels = textOnlyModels
    }
}
