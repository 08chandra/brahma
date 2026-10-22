import Foundation

/// Categories no autonomy preset ever approves. A pack can add categories, never remove these.
public enum ReservedMatters {
    public static let categories = ["money", "outbound", "termination", "prompt-change", "contracts", "pricing", "legal", "press",
                                    "exec-staffing", "permissions", "connectors", "stage", "data-deletion", "engine-code"]
    /// Everyday categories an `other` ask may name.
    public static let ordinary = ["general", "process", "tooling", "design", "research"]

    public static func isReserved(_ category: String?, pack: IndustryPack) -> Bool {
        isReserved(category, extra: pack.reservedCategories)
    }

    public static func isReserved(_ category: String?, extra: [String]) -> Bool {
        guard let c = normalize(category) else { return false }
        return categories.contains(c) || extra.contains { normalize($0) == c }
    }

    /// Built-in, pack-added and ordinary categories, in the order an error message lists them.
    public static func allowed(extra: [String]) -> [String] {
        var seen = Set<String>()
        return (categories + extra.compactMap(normalize) + ordinary).filter { seen.insert($0).inserted }
    }

    static func normalize(_ category: String?) -> String? {
        guard let c = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !c.isEmpty else { return nil }
        return c
    }
}
