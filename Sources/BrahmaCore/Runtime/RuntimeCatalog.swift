import Foundation

/// The runtimes Brahma knows (spec §8.1.1): the one place a `RuntimeId` is spelled (`RuntimeIdLintTests`). Task 3 registers the
/// Claude adapter (`ClaudeRuntime`); the Claude model-class map is here too, so `ModelClass` can be resolved.
public enum RuntimeCatalog {
    public static let claude = RuntimeId(rawValue: "claude")

    /// Every registered runtime, configured for a launcher: the Claude CLI it starts (a command name looked up through
    /// `/usr/bin/env`, or an absolute path) and the environment its children's environments are filtered from.
    public static func all(claudePath: String, baseEnvironment: [String: String]) -> [any AgentRuntime] {
        [ClaudeRuntime(executable: claudePath, baseEnvironment: baseEnvironment)]
    }

    /// Every registered runtime, with the default CLI name and this process's environment.
    public static var all: [any AgentRuntime] {
        all(claudePath: ClaudeRuntime.defaultExecutable, baseEnvironment: ProcessInfo.processInfo.environment)
    }

    /// The registered runtime named `id`; nil (the caller fails closed) for a runtime the catalog does not have.
    public static func runtime(_ id: RuntimeId) -> (any AgentRuntime)? {
        all.first { $0.id == id }
    }

    /// The registered runtime named `id`, configured for a launcher (`all(claudePath:baseEnvironment:)`); nil for an unknown one.
    public static func runtime(_ id: RuntimeId, claudePath: String, baseEnvironment: [String: String]) -> (any AgentRuntime)? {
        all(claudePath: claudePath, baseEnvironment: baseEnvironment).first { $0.id == id }
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
