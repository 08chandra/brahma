import Foundation

/// The class of a model, independent of its runtime (Plan X1, spec §8.1.1): what a mode asks for, which `RuntimeCatalog.defaultModel`
/// turns into the runtime's own model name. Callers pass the family from `ModelAllowlist.family(model)` (`opus`, `sonnet`,
/// `haiku`, or the raw value for anything else), so this type never parses a model id itself.
public enum ModelClass: String, Codable, Sendable, CaseIterable {
    case deep, standard, fast

    /// `opus`→deep, `sonnet`→standard, `haiku`→fast; nil for any other family.
    public static func of(family: String) -> ModelClass? {
        switch family {
        case "opus": .deep
        case "sonnet": .standard
        case "haiku": .fast
        default: nil
        }
    }
}
