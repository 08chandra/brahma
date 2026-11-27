import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The `"vX5-pr"` schema (Plan X8 Task 1): landing mode on the company, `prLanding`, `trustedLogin`, `issueLink` and the
/// item's origin columns, through the Store API.
@Suite(.scratch) struct StorePRTests {
    static func company(_ store: Store, _ name: String = "Acme") throws -> Company {
        try store.createCompany(name: name, goal: "g", workspacesRoot: try tempDir())
    }

    @Test func defaultsAreLocal() throws {
        let store = try Store.inMemory()
        let c = try Self.company(store)
        let fresh = try store.landing(companyId: c.id)
        #expect(fresh.0 == .local); #expect(fresh.engineMerge == false)
        #expect(c.landing == .local); #expect(c.engineMerge == false)

        try store.setLanding(.pr, engineMerge: true, companyId: c.id)
        let switched = try store.landing(companyId: c.id)
        #expect(switched.0 == .pr); #expect(switched.engineMerge == true)
        #expect(try #require(try store.company(id: c.id)).landing == .pr)

        // Setter-owned: a whole-row update from a stale copy keeps the stored values.
        var stale = c
        stale.goal = "renamed"
        try store.updateCompany(stale)
        let after = try #require(try store.company(id: c.id))
        #expect(after.goal == "renamed"); #expect(after.landing == .pr); #expect(after.engineMerge == true)

        // Back to local, and nothing but the mode changes.
        try store.setLanding(.local, engineMerge: false, companyId: c.id)
        #expect(try store.landing(companyId: c.id) == (.local, engineMerge: false))
        #expect(throws: WorkError.notFound("no such company")) { try store.setLanding(.pr, engineMerge: false, companyId: "nope") }
    }

    /// S35: a restore keeps the stricter landing, whichever database holds it: `local` over `pr`, engine-merge off over on.
    @Test func restoreKeepsTheStricterLanding() throws {
        let store = try Store.inMemory()
        let local = try Self.company(store)
        var pr = local
        pr.landing = .pr; pr.engineMerge = true
        for (live, restored) in [(local, pr), (pr, local)] {
            let (merged, _) = CompanySecurity.stricter(live: live, restored: restored)
            #expect(merged.landing == .local); #expect(merged.engineMerge == false)
        }
        let (_, lines) = CompanySecurity.stricter(live: local, restored: pr)
        #expect(lines.contains("landing kept at local (the snapshot had pr)"), "\(lines)")
        #expect(lines.contains("engine-merge kept at off (the snapshot had on)"), "\(lines)")
        #expect(CompanySecurity.stricter(live: pr, restored: local).1.isEmpty)
    }

    @Test func originURLUniquePerCompany() throws {
        let store = try Store.inMemory()
        let a = try Self.company(store, "Acme"), b = try Self.company(store, "Beta")
        let a1 = try store.createWorkItem(companyId: a.id, by: .owner, draft: WorkItemDraft(type: .task, title: "one"))
        let a2 = try store.createWorkItem(companyId: a.id, by: .owner, draft: WorkItemDraft(type: .task, title: "two"))
        let b1 = try store.createWorkItem(companyId: b.id, by: .owner, draft: WorkItemDraft(type: .task, title: "three"))
        let url = "https://github.com/acme/app/issues/7"
        func setOrigin(_ item: WorkItem, _ origin: ItemOrigin) throws {
            try store.writer.write { db in
                try db.execute(sql: "UPDATE workItem SET originURL = ?, originAuthor = ?, originTrusted = ?, originId = ? WHERE id = ?",
                               arguments: [origin.url, origin.author, origin.trusted, origin.id, item.id])
            }
        }
        try setOrigin(a1, ItemOrigin(url: url, author: "octocat", trusted: false, id: "7"))
        // The same origin in the same company is refused by the index.
        #expect(throws: DatabaseError.self) { try setOrigin(a2, ItemOrigin(url: url, author: "octocat", trusted: false, id: "7")) }
        // Another company may import the same issue.
        try setOrigin(b1, ItemOrigin(url: url, author: "octocat", trusted: true, id: "7"))

        let found = try #require(try store.itemByOrigin(companyId: a.id, originURL: url))
        #expect(found.id == a1.id)
        #expect(found.origin == ItemOrigin(url: url, author: "octocat", trusted: false, id: "7"))
        #expect(try #require(try store.itemByOrigin(companyId: b.id, originURL: url)).id == b1.id)
        #expect(try store.itemByOrigin(companyId: a.id, originURL: "https://github.com/acme/app/issues/8") == nil)
        // Items without an origin never collide (the index is partial).
        let plain = try #require(try store.workItem(id: a2.id))
        #expect(plain.origin == nil); #expect(plain.originTrusted == false)
    }

    @Test func everyNewTableMapped() throws {
        let store = try Store.inMemory()
        let (tables, indexes) = try store.writer.read { db in
            (Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")),
             Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")))
        }
        for table in ["prLanding", "trustedLogin", "issueLink"] { #expect(tables.contains(table), "\(table)") }
        #expect(indexes.contains("workItem_origin"))
        func columns(_ table: String) throws -> [String: (type: String, notNull: Bool, defaultValue: String?)] {
            try store.writer.read { db in
                var out: [String: (String, Bool, String?)] = [:]
                for row in try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))") {
                    out[row["name"]] = (row["type"], (row["notnull"] as Int) == 1, row["dflt_value"])
                }
                return out
            }
        }
        let company = try columns("company")
        #expect(company["landing"]?.notNull == true); #expect(company["landing"]?.defaultValue == "'local'")
        #expect(company["engineMerge"]?.notNull == true); #expect(company["engineMerge"]?.defaultValue == "0")
        let item = try columns("workItem")
        for column in ["originURL", "originAuthor", "originId"] { #expect(item[column]?.notNull == false, "\(column)") }
        #expect(item["originTrusted"]?.notNull == true); #expect(item["originTrusted"]?.defaultValue == "0")
        let pr = try columns("prLanding")
        for column in ["itemId", "companyId", "branch", "pushedSHA", "state", "updatedAt"] { #expect(pr[column]?.notNull == true, "\(column)") }
        for column in ["prNumber", "prURL", "lastPolled", "lastError", "mergedSHA"] { #expect(pr[column]?.notNull == false, "\(column)") }
        #expect(Set(try columns("trustedLogin").keys) == ["companyId", "login", "addedBy", "addedAt"])
        #expect(Set(try columns("issueLink").keys) == ["companyId", "provider", "target", "label", "cursor", "lastPolled"])

        // Every record type maps onto its table: a round trip through the Store API.
        let c = try Self.company(store)
        let item1 = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "one"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var landing = PRLanding(itemId: item1.id, companyId: c.id, branch: "brahma/ACME-1", pushedSHA: String(repeating: "a", count: 40),
                                state: .pushed, updatedAt: now)
        try store.upsertPRLanding(landing)
        #expect(try store.prLanding(itemId: item1.id) == landing)
        landing.state = .open; landing.prNumber = 12; landing.prURL = "https://github.com/acme/app/pull/12"; landing.lastPolled = now
        try store.upsertPRLanding(landing)
        #expect(try store.prLanding(itemId: item1.id) == landing)
        #expect(try store.openPRLandings(companyId: c.id) == [landing])
        landing.state = .merged; landing.mergedSHA = String(repeating: "b", count: 40)
        try store.upsertPRLanding(landing)
        #expect(try store.openPRLandings(companyId: c.id).isEmpty)
        #expect(try store.prLanding(itemId: "missing") == nil)

        try store.addTrustedLogin("octocat", companyId: c.id, by: .owner, now: now)
        try store.addTrustedLogin("Hubot", companyId: c.id, by: .owner, now: now)
        #expect(try store.trustedLogins(companyId: c.id) == [TrustedLogin(companyId: c.id, login: "Hubot", addedBy: "owner", addedAt: now),
                                                             TrustedLogin(companyId: c.id, login: "octocat", addedBy: "owner", addedAt: now)])
        #expect(throws: WorkError.forbidden(Store.trustOwnerOnly)) { try store.addTrustedLogin("x", companyId: c.id, by: .agent("a1")) }
        #expect(throws: WorkError.self) { try store.addTrustedLogin(" ", companyId: c.id, by: .owner) }
        try store.removeTrustedLogin("octocat", companyId: c.id, by: .owner)
        #expect(try store.trustedLogins(companyId: c.id).map(\.login) == ["Hubot"])
        #expect(throws: WorkError.notFound("no trusted login 'ghost'")) { try store.removeTrustedLogin("ghost", companyId: c.id, by: .owner) }

        let link = IssueLink(companyId: c.id, provider: .github, target: "acme/app", label: "brahma", cursor: nil, lastPolled: nil)
        try store.setIssueLink(link)
        #expect(try store.issueLink(companyId: c.id, provider: .github) == link)
        #expect(try store.issueLink(companyId: c.id, provider: .linear) == nil)
        var moved = link; moved.cursor = "2026-01-01T00:00:00Z"; moved.lastPolled = now
        try store.setIssueLink(moved)
        #expect(try store.issueLink(companyId: c.id, provider: .github) == moved)
        try store.clearIssueLink(companyId: c.id, provider: .github)
        #expect(try store.issueLink(companyId: c.id, provider: .github) == nil)
    }
}
