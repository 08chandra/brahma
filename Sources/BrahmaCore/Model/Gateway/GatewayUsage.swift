import Foundation

/// The tokens one gateway request used, as the provider reported them (Plan X1; defined by Task 6 for `Price.cost`, filled by
/// Task 8's adapters, Ruling 11). Every field is clamped to `0...maxTokens` on the way in, decoding included, so a provider's
/// usage never reaches the meter negative or absurd.
public struct GatewayUsage: Codable, Equatable, Sendable {
    /// The most tokens of any one kind a request is metered for.
    public static let maxTokens = 10_000_000

    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int) {
        self.inputTokens = Self.clamp(inputTokens)
        self.outputTokens = Self.clamp(outputTokens)
        self.cacheReadTokens = Self.clamp(cacheReadTokens)
        self.cacheWriteTokens = Self.clamp(cacheWriteTokens)
    }

    private enum CodingKeys: String, CodingKey { case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens }

    /// Decoding clamps like the initializer; a count that is not an `Int` is a decoding error (the meter then charges its estimate).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(inputTokens: try c.decode(Int.self, forKey: .inputTokens), outputTokens: try c.decode(Int.self, forKey: .outputTokens),
                  cacheReadTokens: try c.decode(Int.self, forKey: .cacheReadTokens),
                  cacheWriteTokens: try c.decode(Int.self, forKey: .cacheWriteTokens))
    }

    private static func clamp(_ n: Int) -> Int { min(max(n, 0), maxTokens) }
}
