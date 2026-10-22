import Foundation

/// The groups of item fields the policy distinguishes.
public enum WorkField: Sendable, CaseIterable {
    /// type, title, description, acceptance criteria, check, tier, priority, points, reviewer, team, parent.
    case spec
    /// The assignee (`ownerId`).
    case assignee
    case notes
    case linkedBranch
    case status
    case intensity
}

/// Who may change what on a work item. Pure functions: callers supply the facts (lease holder, kind of role).
///
/// The actor is an agent id, or "owner" / "system" for the human owner and the engine. "Owner" in the field names below
/// (`ownerId`) is the item's assignee, not the human.
public enum WorkPolicy {
    static func isPrivileged(_ actor: String) -> Bool { actor == "owner" || actor == "system" }
    static func isLead(_ kind: RoleKind) -> Bool { kind == .manager || kind == .executive }

    // MARK: Fields

    /// Why `actor` may not edit `field` of `item`, or nil when allowed.
    ///
    /// - owner / system: every field.
    /// - spec fields: not the assignee; the author, the reviewer, a manager or an executive.
    /// - assignee field: a manager or an executive (agents self-assign only through `claim_lease`).
    /// - notes, linked branch and status: the assignee, the lease holder, a manager or an executive.
    /// - intensity: a manager or an executive (the value rules are in `intensityDenial`).
    public static func denial(_ field: WorkField, item: WorkItem, actor: String, actorKind: RoleKind,
                              leaseHolderId: String?) -> String? {
        if isPrivileged(actor) { return nil }
        switch field {
        case .spec:
            if actor == item.ownerId { return "the assignee cannot change an item's spec, acceptance criteria or check" }
            if actor == item.authorId || actor == item.reviewerId || isLead(actorKind) { return nil }
            return "only the item's author, reviewer, a manager or the owner can change its spec"
        case .assignee:
            if isLead(actorKind) { return nil }
            return "only a manager or the owner can assign an item; claim it with claim_lease to take it yourself"
        case .notes, .linkedBranch, .status:
            if actor == item.ownerId || (leaseHolderId != nil && actor == leaseHolderId) || isLead(actorKind) { return nil }
            let what = field == .notes ? "notes" : field == .linkedBranch ? "linked branch" : "status"
            return "only the item's assignee, its lease holder, a manager or the owner can change its \(what)"
        case .intensity:
            if isLead(actorKind) { return nil }
            return "only a manager or the owner can set an item's intensity"
        }
    }

    public static func canEdit(_ field: WorkField, item: WorkItem, actor: String, actorKind: RoleKind,
                               leaseHolderId: String?) -> Bool {
        denial(field, item: item, actor: actor, actorKind: actorKind, leaseHolderId: leaseHolderId) == nil
    }

    /// Managers may set at most `thorough`; `ultra` is the owner's alone.
    public static func intensityDenial(_ value: WorkIntensity, actor: String, actorKind: RoleKind) -> String? {
        if isPrivileged(actor) { return nil }
        if !isLead(actorKind) { return "only a manager or the owner can set an item's intensity" }
        return value == .ultra ? "only the owner can set ultra intensity" : nil
    }

    // MARK: Status

    private static let legal: Set<[WorkItemStatus]> = [
        [.backlog, .ready], [.ready, .backlog],
        [.backlog, .blocked], [.ready, .blocked], [.inProgress, .blocked], [.inReview, .blocked],
        [.blocked, .ready], [.blocked, .inProgress], [.inProgress, .ready], [.done, .ready],
    ]

    /// The refusal for a status change requested through a tool, the CLI or the app, or nil when allowed.
    /// `inReview` and `done` are never targets here: the engine writes them.
    public static func statusDenial(from: WorkItemStatus, to: WorkItemStatus, actor: String, actorKind: RoleKind,
                                    isHolderOrAssignee: Bool, hasLease: Bool, blockedReason: String?) -> WorkError? {
        if to == .inReview || to == .done { return .invalid("status \(to.rawValue) is set by the engine") }
        guard legal.contains([from, to]) else { return .invalid("illegal status change \(from.rawValue) → \(to.rawValue)") }
        if to == .blocked, blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return .invalid("a blocked item needs a reason")
        }
        if from == .blocked, to == .inProgress, !hasLease {
            return .invalid("an item moves from blocked to inProgress only while its lease is held")
        }
        if isPrivileged(actor) { return nil }
        if from == .done, !isLead(actorKind) {
            return .forbidden("only a manager or the owner can reopen a done item")
        }
        if !(isHolderOrAssignee || isLead(actorKind)) {
            return .forbidden("only the item's assignee, its lease holder, a manager or the owner can change its status")
        }
        return nil
    }

    public static func canSetStatus(from: WorkItemStatus, to: WorkItemStatus, actor: String, actorKind: RoleKind,
                                    isHolderOrAssignee: Bool, hasLease: Bool, blockedReason: String?) -> Bool {
        statusDenial(from: from, to: to, actor: actor, actorKind: actorKind, isHolderOrAssignee: isHolderOrAssignee,
                     hasLease: hasLease, blockedReason: blockedReason) == nil
    }

    // MARK: Risk

    /// Paths that serialize merges (lockfiles, manifests, migrations, routers). Task 7 makes the list owner-editable.
    public static let defaultHotPaths = [
        "Package.swift", "Package.resolved", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "Cargo.lock", "go.sum", "Podfile.lock", "**/migrations/**", "**/routes*", "**/router*",
    ]

    private static let sensitiveFragments = [
        ".env", "secret", "credential", "keychain", "entitlements", ".github/workflows", "auth", "password", ".pem", ".p12",
        "id_rsa", "token", "billing", "payment",
    ]

    /// Derived, never stored: `sensitivePath`, `hotPath`, `migration`, `flagged`, `securityLabel`.
    /// Paths come from the item's check; keywords from its title, description and criteria.
    public static func riskTags(_ item: WorkItem) -> Set<String> {
        var tags = Set<String>()
        let paths = item.checkSpec?.paths ?? []
        if paths.contains(where: { p in let l = p.lowercased(); return sensitiveFragments.contains { l.contains($0) } }) {
            tags.insert("sensitivePath")
        }
        if paths.contains(where: { p in defaultHotPaths.contains { globMatches($0, p) } }) { tags.insert("hotPath") }
        let text = [item.title, item.description, item.acceptanceCriteria].joined(separator: " ").lowercased()
        if paths.contains(where: { $0.lowercased().contains("migration") }) || text.contains("migration") || text.contains("migrate") {
            tags.insert("migration")
        }
        if !item.reviewFlags.isEmpty { tags.insert("flagged") }
        if ["security", "vulnerab", "cve-", "exploit", "injection", "xss", "csrf"].contains(where: text.contains) {
            tags.insert("securityLabel")
        }
        return tags
    }

    /// Minimal glob: `*` within a segment, `**` across segments, `?` one character. A pattern with no `/` also matches the
    /// last path component, and a path may name a directory that contains the match.
    static func globMatches(_ pattern: String, _ path: String) -> Bool {
        var re = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            let next = pattern.index(after: i)
            if c == "*" {
                if next < pattern.endIndex, pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    if after < pattern.endIndex, pattern[after] == "/" {
                        re += "(?:.*/)?"
                        i = pattern.index(after: after)
                    } else {
                        re += ".*"
                        i = after
                    }
                    continue
                }
                re += "[^/]*"
            } else if c == "?" {
                re += "[^/]"
            } else {
                re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = next
        }
        re += "$"
        guard let regex = try? NSRegularExpression(pattern: re) else { return false }
        func hit(_ s: String) -> Bool { regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        if hit(path) || hit(path + "/x") { return true }
        if !pattern.contains("/"), let last = path.split(separator: "/").last { return hit(String(last)) }
        return false
    }
}
