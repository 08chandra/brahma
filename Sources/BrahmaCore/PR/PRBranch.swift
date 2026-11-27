import Foundation

/// The branch an item's verified commit is pushed to in PR mode: `brahma/<KEY>-<slug>` (spec §9.3.4: the engine pushes only to
/// `brahma/*`). The slug is the title lowercased, every run of characters outside `[a-z0-9]` one `-`, trimmed of `-`, at most
/// `maxSlug` characters; an empty slug leaves `brahma/<KEY>`. The title is agent-written, so the rule admits nothing else.
public enum PRBranch {
    public static let prefix = "brahma/"
    public static let maxSlug = 40
    /// The whole ref (`refs/heads/brahma/...`), in bytes.
    public static let maxRefBytes = 100

    /// The branch for an item, refused when the key (the engine's) would make a ref git refuses or one longer than
    /// `maxRefBytes`. The slug is shortened to fit before a long key is refused.
    public static func name(key: String, title: String) -> PRDecision<String> {
        guard key.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            return .refused("item key \(Store.flat(key, max: 70)) cannot name a branch")
        }
        let base = prefix + key
        var slug = slug(title)
        // Room for `-<slug>` within the ref's bytes (the slug is ASCII: one byte a character).
        let room = maxRefBytes - ref(base).utf8.count - 1
        if slug.count > room { slug = trimmed(String(slug.prefix(max(room, 0)))) }
        let name = slug.isEmpty ? base : "\(base)-\(slug)"
        guard ref(name).utf8.count <= maxRefBytes else { return .refused("item key \(Store.flat(key, max: 70)) is too long for a branch") }
        guard isValidBranchName(name) else { return .refused("\(name) is not a valid branch name") }
        return .allowed(name)
    }

    /// `refs/heads/<branch>`.
    public static func ref(_ branch: String) -> String { "refs/heads/" + branch }

    /// The title reduced to `[a-z0-9-]`, at most `maxSlug` characters, no leading or trailing `-`.
    public static func slug(_ title: String) -> String {
        var out = ""
        var dash = false
        for scalar in title.lowercased().unicodeScalars {
            let v = scalar.value
            if (0x61...0x7A).contains(v) || (0x30...0x39).contains(v) {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.unicodeScalars.append(scalar)
                if out.count >= maxSlug { break }
            } else {
                dash = true
            }
        }
        return trimmed(String(out.prefix(maxSlug)))
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }

    /// `git check-ref-format --branch` without running git: what git refuses in a branch name (refs.c `check_refname_component`
    /// plus `--branch`'s leading `-`). The engine's names are ASCII by construction; anything else is refused here.
    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.contains(".."), !name.contains("//"), !name.contains("@{") else { return false }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v >= 0x7F { return false }
            if " ~^:?*[\\".unicodeScalars.contains(scalar) { return false }
        }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component.hasPrefix(".") || component.hasSuffix(".lock") { return false }
        }
        return true
    }
}
