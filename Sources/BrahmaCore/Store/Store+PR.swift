import Foundation
import GRDB

/// PR mode and issue import (Plan X8, `"vX5-pr"`): the company's landing mode, the PR landings the engine watches, the owner's
/// trusted logins and the issue sources. The owner-only writes are the CLI's (behind `requireOwnerShell`) and the app's; no
/// agent tool reaches them.
extension Store {
    // MARK: Landing mode

    /// How the company's approved items reach `main`, and whether the engine may merge a mergeable PR itself.
    public func landing(companyId: String) throws -> (LandingMode, engineMerge: Bool) {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT landing, engineMerge FROM company WHERE id = ?", arguments: [companyId]) else {
                throw WorkError.notFound("no such company")
            }
            return (row["landing"], engineMerge: row["engineMerge"])
        }
    }

    /// What every PR-mode setter says to a non-owner sender (Ruling 21): the landing mode, the trust list and the issue links
    /// are the owner's alone; no agent tool reaches them.
    static let prOwnerOnly = "only the owner can change the landing mode, the trusted logins and the issue links"

    /// Owner only. Records the landing mode; the grant checks are `LandingSwitch.apply`'s, the one caller that should switch to
    /// `pr`. Switching to `local` abandons no open PR landing. `updateCompany` never overwrites either column.
    public func setLanding(_ mode: LandingMode, engineMerge: Bool, companyId: String, by sender: Sender) throws {
        guard sender == .owner else { throw WorkError.forbidden(Self.prOwnerOnly) }
        try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            _ = try Company.filter(key: companyId)
                .updateAll(db, Column("landing").set(to: mode), Column("engineMerge").set(to: engineMerge))
        }
    }

    // MARK: PR landings

    public func prLanding(itemId: String) throws -> PRLanding? {
        try writer.read { db in try PRLanding.fetchOne(db, key: itemId) }
    }

    /// Writes the item's landing whole, with no state check (one row per item). Not an engine path: the landing machine and the
    /// push stage write through the compare-and-set `casPRLanding`/`recordPushStage`; this is for tests and fixtures.
    func upsertPRLanding(_ landing: PRLanding) throws {
        try writer.write { db in try landing.save(db) }
    }

    /// The company's landings still being watched (`PRLandingState.isOpen`), oldest update first.
    public func openPRLandings(companyId: String) throws -> [PRLanding] {
        try writer.read { db in
            try PRLanding.filter(Column("companyId") == companyId && !PRLandingState.closed.map(\.rawValue).contains(Column("state")))
                .order(Column("updatedAt"), Column("itemId")).fetchAll(db)
        }
    }

    /// The landing states that prove the branch reached GitHub. Not `pushing` (it may have failed), and not `abandoned` or
    /// `closedUpstream` (an owner may abandon a landing whose push never landed).
    static let pushedEvidence: [PRLandingState] = [.pushed, .opening, .open, .checksFailed, .changesRequested, .mergeable, .merging, .merged]

    /// Whether some push of the company is known to have reached GitHub: the company's first push asks
    /// (`GitHubRules.firstPushAsks`) until one has. A landing with a PR number is evidence too, whatever its state: GitHub
    /// opened a PR on a pushed branch (Task 3: a resubmit takes an open landing back to `pushing`, keeping its PR).
    public func hasPushedPRLanding(companyId: String) throws -> Bool {
        try writer.read { db in
            try PRLanding.filter(Column("companyId") == companyId
                                 && (Self.pushedEvidence.map(\.rawValue).contains(Column("state")) || Column("prNumber") != nil)).fetchCount(db) > 0
        }
    }

    // MARK: Trusted logins

    /// The company's trusted logins, by login.
    public func trustedLogins(companyId: String) throws -> [TrustedLogin] {
        try writer.read { db in
            try TrustedLogin.filter(Column("companyId") == companyId).order(Column("login")).fetchAll(db)
        }
    }

    /// Owner only. Stored normalized (Ruling 25: `TrustList.normalize`, logins compare case-insensitively); adding a login
    /// already listed, in any case, keeps the first record.
    public func addTrustedLogin(_ login: String, companyId: String, by sender: Sender, now: Date = Store.now()) throws {
        guard sender == .owner else { throw WorkError.forbidden(Self.prOwnerOnly) }
        // Fix round 1: a non-ASCII login could fold onto an ASCII one (U+212A KELVIN SIGN lowercases to `k`); checked as typed.
        guard TrustList.isASCII(login) else { throw WorkError.invalid("a login is ASCII letters, digits and punctuation") }
        let login = TrustList.normalize(login)
        guard !login.isEmpty, login.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw WorkError.invalid("a login has no spaces")
        }
        try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            guard try Self.trustedLoginRows(db, companyId: companyId, login: login).isEmpty else { return }
            try TrustedLogin(companyId: companyId, login: login, addedBy: sender.id, addedAt: now).insert(db, onConflict: .ignore)
        }
    }

    /// Owner only. Removes the login in any case (a row stored before Ruling 25 kept its typed case). Items already imported
    /// keep the trust they were imported with.
    public func removeTrustedLogin(_ login: String, companyId: String, by sender: Sender) throws {
        guard sender == .owner else { throw WorkError.forbidden(Self.prOwnerOnly) }
        try writer.write { db in
            let rows = try Self.trustedLoginRows(db, companyId: companyId, login: login)
            guard !rows.isEmpty else { throw WorkError.notFound("no trusted login '\(login)'") }
            for row in rows { try row.delete(db) }
        }
    }

    /// The company's `trustedLogin` rows that are `login` under Ruling 25 (compared in `TrustList.normalize` form).
    static func trustedLoginRows(_ db: Database, companyId: String, login: String) throws -> [TrustedLogin] {
        let key = TrustList.normalize(login)
        return try TrustedLogin.filter(Column("companyId") == companyId).fetchAll(db).filter { TrustList.normalize($0.login) == key }
    }

    // MARK: Issue links

    public func issueLink(companyId: String, provider: IssueProvider) throws -> IssueLink? {
        try writer.read { db in try IssueLink.fetchOne(db, key: ["companyId": companyId, "provider": provider.rawValue]) }
    }

    /// Owner only. Writes the company's link for the provider (one per provider: the cursor and poll time move with it).
    public func setIssueLink(_ link: IssueLink, by sender: Sender) throws {
        guard sender == .owner else { throw WorkError.forbidden(Self.prOwnerOnly) }
        try writer.write { db in
            guard try Company.fetchOne(db, key: link.companyId) != nil else { throw WorkError.notFound("no such company") }
            try link.save(db)
        }
    }

    /// Owner only.
    public func clearIssueLink(companyId: String, provider: IssueProvider, by sender: Sender) throws {
        guard sender == .owner else { throw WorkError.forbidden(Self.prOwnerOnly) }
        try writer.write { db in
            _ = try IssueLink.filter(Column("companyId") == companyId && Column("provider") == provider.rawValue).deleteAll(db)
        }
    }

    // MARK: Item origin

    /// The item the company imported from `originURL`, if any.
    public func itemByOrigin(companyId: String, originURL: String) throws -> WorkItem? {
        try writer.read { db in
            try WorkItem.filter(Column("companyId") == companyId && Column("originURL") == originURL).fetchOne(db)
        }
    }
}
