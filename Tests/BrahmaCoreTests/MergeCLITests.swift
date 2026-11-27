import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// `brahma merge` (Plan 4a Task 2): the queue's list and settings, the owner's retry and resume. Reading is open to every
/// shell; every write refuses an agent's shell; agent-controlled text prints only through `safe()`.
@Suite(.scratch) struct MergeCLITests {
    static let esc = "\u{1B}"
    static let hostile = "\u{1B}[2J\u{1B}]0;pwned\u{07}boom\u{1B}[31m red"

    struct Rig {
        let owner: OwnerTestHome
        let store: Store
        let company: Company
        let agent: Agent
        var home: URL { owner.url }

        init() throws {
            owner = try OwnerTestHome()
            let made = try brahma(["company", "create", "Acme", "--goal", "g"], home: owner.url)
            #expect(made.status == 0, "\(made.stderr)")
            store = try Store(path: ownerPaths(owner.url).database.path)
            company = try #require(try store.companies().first)
            agent = try #require(try store.agents(companyId: company.id).first)
        }

        /// An item (owned by `agent`) and a request for it as the queue leaves it.
        @discardableResult
        func request(_ number: Int, status: MergeRequestStatus, title: String = "Work",
                     _ change: (inout MergeRequest) -> Void = { _ in }) throws -> (WorkItem, MergeRequest) {
            let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: title, checkSpec: CheckSpec(command: "make test"), tier: .m, status: .ready))
            try store.writer.write { db in
                var i = try #require(try WorkItem.fetchOne(db, key: item.id))
                i.ownerId = agent.id
                try i.update(db)
            }
            var r = MergeRequest(companyId: company.id, itemId: item.id, number: number, status: status,
                                 headCommit: String(repeating: "\(number)", count: 40), enqueuedAt: Date())
            change(&r)
            let row = r
            try store.writer.write { db in try row.insert(db) }
            return (item, row)
        }
    }

    @Test func mergeListAndSettings() throws {
        let rig = try Rig()
        let (queuedItem, _) = try rig.request(1, status: .queued)
        let (bouncedItem, _) = try rig.request(2, status: .bounced) {
            $0.failure = .itemCheckFailed; $0.detail = "its check failed (exit 1) \(Self.hostile)"
        }
        let (mergedItem, merged) = try rig.request(3, status: .merged) { $0.mergedCommit = String(repeating: "c", count: 40) }
        // Empty settings, then the list.
        let empty = try brahma(["merge", "Acme"], home: rig.home)
        #expect(empty.status == 0, "\(empty.stderr)")
        let main = rig.company.mainCommit.map { String($0.prefix(7)) } ?? "-"
        var lines = empty.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first == "main \(main) · batch 1 · Rebase + fast-forward · main check: none · landing local", "\(empty.stdout)")
        let name = rig.agent.name
        #expect(lines.contains { $0.hasPrefix("M-1  \(queuedItem.key)  queued  @\(name)  ") }, "\(empty.stdout)")
        #expect(lines.contains { $0.hasPrefix("M-2  \(bouncedItem.key)  bounced  @\(name)  its check failed (exit 1)") }, "\(empty.stdout)")
        #expect(lines.contains("M-3  \(mergedItem.key)  merged  @\(name)  ccccccc"), "\(empty.stdout)")
        #expect(!empty.stdout.contains(Self.esc) && !empty.stdout.contains("\u{07}"))
        _ = merged
        // `list` is the same as the default.
        #expect(try brahma(["merge", "list", "Acme"], home: rig.home).stdout == empty.stdout)
        // Settings: show, then change.
        let shown = try brahma(["merge", "settings", "Acme"], home: rig.home)
        #expect(shown.status == 0 && shown.stdout.contains("batch 1") && shown.stdout.contains("ff"), "\(shown.stdout)")
        let set = try brahma(["merge", "settings", "Acme", "--batch", "3", "--strategy", "merge", "--main-check", "make smoke \(Self.hostile)",
                              "--main-timeout", "90"], home: rig.home)
        #expect(set.status == 0, "\(set.stderr)")
        #expect(!set.stdout.contains(Self.esc))
        let stored = try rig.store.mergeSettings(companyId: rig.company.id)
        #expect(stored.batchSize == 3 && stored.strategy == .merge && stored.mainCheck?.timeoutSeconds == 90)
        #expect(stored.mainCheck?.command.hasPrefix("make smoke") == true)
        lines = try brahma(["merge", "Acme"], home: rig.home).stdout.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("main \(main) · batch 3 · Rebase + merge commit · main check: make smoke") == true, "\(lines.first ?? "")")
        #expect(lines.first?.contains(Self.esc) == false)
        // A held queue says so.
        try rig.store.setMergeHold(companyId: rig.company.id, reason: "the main check fails on main itself")
        lines = try brahma(["merge", "Acme"], home: rig.home).stdout.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasSuffix(" · HELD: the main check fails on main itself") == true, "\(lines.first ?? "")")
        // Bad values are refused, nothing changes; clearing the check works.
        for args in [["--batch", "0"], ["--batch", "9"], ["--strategy", "squash"], ["--main-timeout", "0"],
                     ["--main-check", "x", "--clear-main-check"]] {
            let bad = try brahma(["merge", "settings", "Acme"] + args, home: rig.home)
            #expect(bad.status != 0, "\(args)")
        }
        #expect(try rig.store.mergeSettings(companyId: rig.company.id).batchSize == 3)
        let cleared = try brahma(["merge", "settings", "Acme", "--clear-main-check"], home: rig.home)
        #expect(cleared.status == 0, "\(cleared.stderr)")
        #expect(try rig.store.mergeSettings(companyId: rig.company.id).mainCheck == nil)
        // `brahma status` shows the open count (the queued request).
        let status = try brahma(["status"], home: rig.home)
        #expect(status.stdout.contains("  merge queue: 1 open"), "\(status.stdout)")
    }

    @Test func mergeSettingsRefusedInAgentShell() throws {
        let rig = try Rig()
        let env = ["BRAHMA_AGENT_ID": rig.agent.id]
        for args in [["merge", "settings", "Acme", "--batch", "4"], ["merge", "resume", "Acme"], ["merge", "retry", "Acme", "M-1"]] {
            let r = try brahma(args, home: rig.home, env: env)
            #expect(r.status == 1, "\(args)")
            #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(args): \(r.stderr)")
        }
        #expect(try rig.store.mergeSettings(companyId: rig.company.id).batchSize == 1)
        // Reading is fine in an agent's shell.
        #expect(try brahma(["merge", "Acme"], home: rig.home, env: env).status == 0)
        #expect(try brahma(["merge", "settings", "Acme"], home: rig.home, env: env).status == 0)
    }

    /// Plan X8 Task 4 fix round 1: `brahma merge abandon-pr` is the owner's way out of a PR landing held for good. An agent's
    /// shell is refused; the owner's abandons it and the item goes back to its owner agent.
    @Test func mergeAbandonPR() throws {
        let rig = try Rig()
        let (item, request) = try rig.request(1, status: .handedToPR) { $0.candidateCommit = String(repeating: "1", count: 40) }
        try rig.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inReview', mergeState = 'verifying' WHERE id = ?", arguments: [item.id])
        }
        try rig.store.upsertPRLanding(PRLanding(itemId: item.id, companyId: rig.company.id, branch: "brahma/\(item.key)",
                                                pushedSHA: request.headCommit, prNumber: 4, state: .pushing, lastError: "[rejected] (non-fast-forward)",
                                                updatedAt: Date()))
        let refused = try brahma(["merge", "abandon-pr", "Acme", item.key], home: rig.home, env: ["BRAHMA_AGENT_ID": rig.agent.id])
        #expect(refused.status == 1 && refused.stderr.contains("owner commands can't run inside an agent turn"), "\(refused.stderr)")
        #expect(try rig.store.prLanding(itemId: item.id)?.state == .pushing)
        let missing = try brahma(["merge", "abandon-pr", "Acme", "ACME-99"], home: rig.home)
        #expect(missing.status == 1 && missing.stderr.contains("no item ACME-99"), "\(missing.stderr)")
        let done = try brahma(["merge", "abandon-pr", "Acme", item.key, "--reason", "branch moved"], home: rig.home)
        #expect(done.status == 0 && done.stdout.contains("\(item.key): PR landing abandoned"), "\(done.stderr)")
        let landing = try #require(try rig.store.prLanding(itemId: item.id))
        #expect(landing.state == .abandoned && landing.lastError == "abandoned by the owner: branch moved")
        #expect(try rig.store.workItem(id: item.id)?.status == .inProgress)
        #expect(try rig.store.mergeRequest(id: request.id)?.status == .bounced)
        let again = try brahma(["merge", "abandon-pr", "Acme", item.key], home: rig.home)
        #expect(again.status == 1 && again.stderr.contains("already abandoned"), "\(again.stderr)")
    }

    @Test func mergeRetryRequeues() throws {
        let rig = try Rig()
        let (item, failed) = try rig.request(1, status: .failed) { $0.failure = .engineError; $0.detail = "git failed 3 times" }
        // The item is still approved and waiting.
        let (i2, _) = (item, failed)
        try rig.store.writer.write { db in
            var i = try #require(try WorkItem.fetchOne(db, key: i2.id))
            i.status = .inReview; i.verifiedCommit = failed.headCommit; i.mergeState = .none
            try i.update(db)
        }
        let bad = try brahma(["merge", "retry", "Acme", "M-99"], home: rig.home)
        #expect(bad.status == 1 && bad.stderr.contains("no merge request M-99"), "\(bad.stderr)")
        let byRef = try brahma(["merge", "retry", "Acme", "M-1"], home: rig.home)
        #expect(byRef.status == 0, "\(byRef.stderr)")
        #expect(byRef.stdout.contains("M-2 queued"), "\(byRef.stdout)")
        let queued = try rig.store.mergeRequests(companyId: rig.company.id, statuses: [.queued])
        #expect(queued.count == 1 && queued[0].itemId == item.id && queued[0].headCommit == failed.headCommit)
        // By key: the same item already has one in the queue, so it is refused.
        let again = try brahma(["merge", "retry", "Acme", item.key], home: rig.home)
        #expect(again.status == 1, "\(again.stdout)")
        #expect(try rig.store.mergeRequests(companyId: rig.company.id, statuses: [.queued]).count == 1)
    }

    /// `brahma merge adopt-main` (Plan 4a Task 3): the owner makes main's head the record, or moves main to a tip the main
    /// guard saved and records that; an agent's shell is refused and the record does not move.
    @Test func mergeAdoptMain() throws {
        let rig = try Rig()
        let root = URL(fileURLWithPath: rig.company.workspacePath, isDirectory: true)
        let f = GitFixture(existing: root)
        let before = try #require(rig.company.mainCommit)
        try f.write("owner.txt", "the owner's change")
        try f.git(["add", "-A", "--", "owner.txt"])
        try f.git(["commit", "--quiet", "-m", "by hand \(Self.hostile)"])
        let head = try f.git(["rev-parse", "refs/heads/main"])
        #expect(head != before)
        let refused = try brahma(["merge", "adopt-main", "Acme"], home: rig.home, env: ["BRAHMA_AGENT_ID": rig.agent.id])
        #expect(refused.status == 1 && refused.stderr.contains("owner commands can't run inside an agent turn"), "\(refused.stderr)")
        #expect(try rig.store.company(id: rig.company.id)?.mainCommit == before)
        let adopted = try brahma(["merge", "adopt-main", "Acme"], home: rig.home)
        #expect(adopted.status == 0, "\(adopted.stderr)")
        #expect(adopted.stdout.contains("Acme: main adopted at \(head.prefix(7)) (\(head))"), "\(adopted.stdout)")
        #expect(try rig.store.company(id: rig.company.id)?.mainCommit == head)
        // A saved tip, by its ref: main moves there, the checkout follows, the record is written.
        let saved = "refs/brahma/foreign/20260101-000000-1"
        try f.git(["update-ref", saved, head])
        try f.git(["reset", "--hard", "--quiet", before])
        try rig.store.writer.write { db in try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [before, rig.company.id]) }
        let byRef = try brahma(["merge", "adopt-main", "Acme", saved], home: rig.home)
        #expect(byRef.status == 0, "\(byRef.stderr)")
        #expect(try f.git(["rev-parse", "refs/heads/main"]) == head)
        #expect(try rig.store.company(id: rig.company.id)?.mainCommit == head)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "owner.txt").path))
        // Something that names no commit is refused; nothing changes.
        let bad = try brahma(["merge", "adopt-main", "Acme", "refs/brahma/foreign/none"], home: rig.home)
        #expect(bad.status == 1 && bad.stderr.contains("names no commit"), "\(bad.stderr)")
        #expect(try rig.store.company(id: rig.company.id)?.mainCommit == head)
        #expect(!bad.stderr.contains(Self.esc) && !adopted.stdout.contains(Self.esc))
    }

    @Test func mergeResumeClearsHold() throws {
        let rig = try Rig()
        let none = try brahma(["merge", "resume", "Acme"], home: rig.home)
        #expect(none.status == 0 && none.stdout.contains("not held"), "\(none.stdout)")
        try rig.store.setMergeHold(companyId: rig.company.id, reason: "the main check fails on main itself")
        let resumed = try brahma(["merge", "resume", "Acme"], home: rig.home)
        #expect(resumed.status == 0, "\(resumed.stderr)")
        #expect(resumed.stdout.contains("Merge queue resumed"), "\(resumed.stdout)")
        #expect(try rig.store.company(id: rig.company.id)?.mergeHold == nil)
        // A hold because the root did not follow main is refused while the root differs from main (here: a stray file), and
        // released once it matches.
        try rig.store.setMergeHold(companyId: rig.company.id, reason: "the root checkout did not follow main after ACME-1 landed; its files still hold the old tree")
        let stray = URL(fileURLWithPath: rig.company.workspacePath).appending(path: "stray.txt")
        try "left over".write(to: stray, atomically: true, encoding: .utf8)
        let refused = try brahma(["merge", "resume", "Acme"], home: rig.home)
        #expect(refused.status == 1 && refused.stderr.contains("does not match main"), "\(refused.stderr)")
        #expect(try rig.store.company(id: rig.company.id)?.mergeHold != nil)
        try FileManager.default.removeItem(at: stray)
        #expect(try brahma(["merge", "resume", "Acme"], home: rig.home).status == 0)
        #expect(try rig.store.company(id: rig.company.id)?.mergeHold == nil)
    }
}
