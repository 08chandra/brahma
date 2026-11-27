import Foundation

/// The runtimes Brahma knows (spec §8.1.1): the one place a `RuntimeId` is spelled (`RuntimeIdLintTests`). `all` is empty until
/// Task 3 registers the Claude adapter; the Claude model-class map is here already, so `ModelClass` can be resolved today.
public enum RuntimeCatalog {
    public static let claude = RuntimeId(rawValue: "claude")

    /// Every registered runtime. Empty until Task 3.
    public static var all: [any AgentRuntime] { [] }

    public static func runtime(_ id: RuntimeId) -> (any AgentRuntime)? {
        all.first { $0.id == id }
    }

    /// The runtime's own model name for a class: Claude's `deep=opus`, `standard=sonnet`, `fast=haiku`. Nil for a runtime the
    /// catalog has no map for.
    public static func defaultModel(_ c: ModelClass, on id: RuntimeId) -> String? {
        guard id == claude else { return nil }
        switch c {
        case .deep: return "opus"
        case .standard: return "sonnet"
        case .fast: return "haiku"
        }
    }
}
