import Foundation

/// The forbidden-domain rule and the one check every owner-set domain passes; the pattern rules are `DomainMatcher`'s.
public enum SandboxDomains {
    /// Anthropic's API and apps: nested `claude` must have no route to them (the V-9 barrier is network plus exec, Task 3).
    static let forbiddenRoots = ["anthropic.com", "claude.ai", "claude.com"]

    public static func normalize(_ s: String) -> String { DomainMatcher.normalize(s) }

    /// The pattern covers one of Anthropic's domains: it is one of them, a subdomain of one, or a parent of one.
    public static func isForbidden(_ pattern: String) -> Bool {
        let p = normalize(pattern)
        let base = p.hasPrefix("*.") ? String(p.dropFirst(2)) : p
        if base == "*" || base.isEmpty { return true }
        return forbiddenRoots.contains { root in base == root || base.hasSuffix("." + root) || root.hasSuffix("." + base) }
    }

    /// Refuses a forbidden domain first (so any Anthropic name reports as such), then an invalid one.
    public static func check(_ domain: String) throws {
        if isForbidden(domain) { throw SandboxError.forbiddenDomain(normalize(domain)) }
        if !DomainMatcher.isValidPattern(domain) { throw SandboxError.invalidDomain(domain) }
    }
}
