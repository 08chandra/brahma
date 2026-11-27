import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The soak harness's verdict (Plan X6a Task 7): a checkpoint taken before the engine is killed, then the seven checks after it
/// restarted. Store fixtures for the records, a real `GitFixture` repository for the commits (every case: the checkpoint reads
/// `main` and the item branches through `GitWorkspace`).
///
/// One timeline for every case: the engine started at `started`, the checkpoint was taken at `taken`, the engine was killed
/// and started again at `restarted`, and the verdict is asked for at `now`, 400 s later (the settle time is 300 s).
@Suite(.scratch) struct SoakVerifyTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let started = now.addingTimeInterval(-1000)
    static let taken = now.addingTimeInterval(-900)
    static let restarted = now.addingTimeInterval(-400)

    struct Rig {
        let store: Store
        let git: GitFixture
        let company: Company
        let eng: Agent
        let item: WorkItem
        /// The commit `main` was at when the checkpoint was taken (one above the import commit).
        let mainTip: String
        let importCommit: String

        init() throws {
            store = try Store.inMemory()
            git = try GitFixture(files: ["README.md": "soak\n"])
            importCommit = try git.git(["rev-parse", "refs/heads/main"])
            mainTip = try git.plantCommit(parent: importCommit, path: "a.txt", text: "a\n", message: "landed a")
            try git.git(["update-ref", "refs/heads/main", mainTip])
            company = try MeasureFixtures.company(store, name: "Acme", workspacePath: git.root.path, createdAt: SoakVerifyTests.started.addingTimeInterval(-86_400))
            eng = try MeasureFixtures.agent(store, company: company, name: "eng-1")
            item = try #require(try MeasureFixtures.items(store, company: company, count: 1, now: SoakVerifyTests.started).first)
            // The item claimed, with a commit on its branch; the agent mid-turn when the checkpoint is taken.
            _ = try store.claimLease(itemId: item.id, agentId: eng.id, now: SoakVerifyTests.started)
            let head = try git.plantCommit(parent: mainTip, path: "b.txt", text: "b\n", message: "work on the item")
            try git.git(["update-ref", "refs/heads/item/\(item.key)", head])
            try startTurn(eng, at: SoakVerifyTests.started.addingTimeInterval(30))
        }

        /// The turn start as the engine records it (`beginTurnRecord`): the agent `running` and an `inProgress` turn, in one write.
        @discardableResult
        func startTurn(_ agent: Agent, at: Date) throws -> Turn {
            try store.writer.write { db in
                try db.execute(sql: "UPDATE agent SET state = 'running' WHERE id = ?", arguments: [agent.id])
                let turn = Turn(id: UUID().uuidString, agentId: agent.id, companyId: agent.companyId, startedAt: at, endedAt: nil,
                                outcome: .inProgress, summary: nil, costUSD: nil)
                try turn.insert(db)
                return turn
            }
        }

        func checkpoint() throws -> SoakCheckpoint {
            try SoakCheckpoint.take(store: store, git: git.ws, companyId: company.id, now: SoakVerifyTests.taken,
                                    engineStartedAt: SoakVerifyTests.started)
        }

        /// What a `kill -9` and a restart leave, as the engine's own start does it (`recoverInterruptedTurns`), then the
        /// agent's next turn.
        func killAndRestart() throws {
            _ = try store.recoverInterruptedTurns(now: SoakVerifyTests.restarted)
            try startTurn(eng, at: SoakVerifyTests.restarted.addingTimeInterval(10))
        }

        func verify(_ before: SoakCheckpoint, now: Date = SoakVerifyTests.now,
                    engineStartedAt: Date? = SoakVerifyTests.restarted) throws -> SoakVerdict {
            try SoakVerify.run(before, store: store, git: git.ws, now: now, engineStartedAt: engineStartedAt)
        }

        func sql(_ text: String, _ arguments: StatementArguments = []) throws {
            try store.writer.write { db in try db.execute(sql: text, arguments: arguments) }
        }
    }

    static func check(_ verdict: SoakVerdict, _ name: String) -> SoakCheck? { verdict.checks.first { $0.name == name } }

    @Test func cleanRestartPasses() throws {
        let rig = try Rig()
        try rig.sql("UPDATE workItem SET verifiedCommit = ? WHERE id = ?", [rig.mainTip, rig.item.id])
        let before = try rig.checkpoint()
        #expect(before.companyId == rig.company.id)
        #expect(before.mainTip == rig.mainTip)
        #expect(before.itemHeads[rig.item.key] != nil)
        #expect(before.verifiedCommits == [rig.item.key: rig.mainTip])
        #expect(before.leases == [rig.item.key: rig.eng.id])
        #expect(before.runningTurns.count == 1)
        #expect(before.openBatches.isEmpty && before.releaseExecutions.isEmpty)
        #expect(before.engineStartedAt == SoakVerifyTests.started)

        // The checkpoint file: 0600, written through EngineFiles into the directory the owner named, read back equal.
        let dir = try tempDir().appending(path: "soak-state", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "h01.json")
        try before.write(to: file)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #expect(try SoakCheckpoint.read(from: file) == before)

        try rig.killAndRestart()
        let verdict = try rig.verify(try SoakCheckpoint.read(from: file))
        #expect(verdict.result == .pass, "\(verdict.lines())")
        #expect(verdict.passed)
        #expect(verdict.checks.map(\.name) == SoakVerify.checkNames)
        #expect(verdict.checks.allSatisfy { $0.result == .pass }, "\(verdict.lines())")
        #expect(Self.check(verdict, "interruptedTurnsRecorded")?.detail.contains("1 interrupted") == true, "\(verdict.lines())")
        #expect(Self.check(verdict, "noDuplicateOutsideActions")?.detail.contains("not applicable") == true, "channels are X4")
        #expect(verdict.lines().first?.hasPrefix("soak verify: pass") == true, "\(verdict.lines())")
    }

    @Test func missingCommitFails() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        let head = try #require(before.itemHeads[rig.item.key])
        // The branch deleted and its commit pruned from the object store: lost.
        try rig.git.git(["update-ref", "-d", "refs/heads/item/\(rig.item.key)"])
        try rig.git.git(["reflog", "expire", "--expire=now", "--all"])
        try rig.git.git(["gc", "--prune=now", "--quiet"])
        try rig.killAndRestart()
        let verdict = try rig.verify(before)
        let lost = try #require(Self.check(verdict, "noLostCommits"))
        #expect(lost.result == .fail)
        #expect(lost.detail.contains(String(head.prefix(7))) && lost.detail.contains(rig.item.key), "\(lost.detail)")
        #expect(verdict.result == .fail && !verdict.passed)
    }

    @Test func rewoundMainFails() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.git.git(["update-ref", "refs/heads/main", rig.importCommit])
        try rig.killAndRestart()
        let lost = try #require(Self.check(try rig.verify(before), "noLostCommits"))
        #expect(lost.result == .fail)
        #expect(lost.detail.contains("rewound"), "\(lost.detail)")
    }

    @Test func restoreExplainsRewind() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.git.git(["update-ref", "refs/heads/main", rig.importCommit])
        // The owner restored a snapshot after the checkpoint; it recorded main at the import commit.
        let nonce = UUID().uuidString
        try rig.sql("INSERT INTO restoreEvent (nonce, snapshot, restoredAt) VALUES (?, 'snap', ?)", [nonce, SoakVerifyTests.restarted.addingTimeInterval(-5)])
        try rig.sql("INSERT INTO restoreMain (nonce, companyId, mainCommit) VALUES (?, ?, ?)", [nonce, rig.company.id, rig.importCommit])
        try rig.killAndRestart()
        let lost = try #require(Self.check(try rig.verify(before), "noLostCommits"))
        #expect(lost.result == .pass, "\(lost.detail)")
        #expect(lost.detail.contains("restore"), "\(lost.detail)")
        // Fix round 1 #6: a restore explains the rewind only when main still contains the commit it restored to. Main moved to
        // a commit off the restored one (a sibling of it): unexplained.
        let off = try rig.git.plantCommit(parent: rig.importCommit, path: "z.txt", text: "z\n", message: "elsewhere")
        let restored = try rig.git.plantCommit(parent: rig.importCommit, path: "r.txt", text: "r\n", message: "restored head")
        try rig.sql("UPDATE restoreMain SET mainCommit = ? WHERE nonce = ?", [restored, nonce])
        try rig.git.git(["update-ref", "refs/heads/main", off])
        let unexplained = try #require(Self.check(try rig.verify(before), "noLostCommits"))
        #expect(unexplained.result == .fail, "\(unexplained.detail)")
        #expect(unexplained.detail.contains("rewound") && unexplained.detail.contains("not on main"), "\(unexplained.detail)")
        // A restore before the checkpoint explains nothing.
        let rig2 = try Rig()
        let nonce2 = UUID().uuidString
        try rig2.sql("INSERT INTO restoreEvent (nonce, snapshot, restoredAt) VALUES (?, 'snap', ?)", [nonce2, SoakVerifyTests.started])
        try rig2.sql("INSERT INTO restoreMain (nonce, companyId, mainCommit) VALUES (?, ?, ?)", [nonce2, rig2.company.id, rig2.importCommit])
        let before2 = try rig2.checkpoint()
        try rig2.git.git(["update-ref", "refs/heads/main", rig2.importCommit])
        try rig2.killAndRestart()
        #expect(Self.check(try rig2.verify(before2), "noLostCommits")?.result == .fail)
    }

    /// Fix round 1 #9: a restore over an unreadable database (`restoreEpoch`) explains a rewind the same way.
    @Test func restoreEpochExplainsRewind() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.git.git(["update-ref", "refs/heads/main", rig.importCommit])
        try rig.sql("INSERT INTO restoreEpoch (id, companyId, mainCommit, listed, source, createdAt) VALUES (?, ?, ?, 0, 'snap', ?)",
                    [UUID().uuidString, rig.company.id, rig.importCommit, SoakVerifyTests.restarted.addingTimeInterval(-5)])
        try rig.killAndRestart()
        let lost = try #require(Self.check(try rig.verify(before), "noLostCommits"))
        #expect(lost.result == .pass, "\(lost.detail)")
        #expect(lost.detail.contains("unreadable database"), "\(lost.detail)")
    }

    /// Fix round 1 #1 (ruling R42(a)): a verdict needs an engine that started after the checkpoint. The checkpoint's own
    /// engine start, reused (the engine was never killed, or the probe read a stale start), is `wait`, whatever else holds.
    @Test func staleStartIsWait() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        _ = try rig.store.recoverInterruptedTurns(now: SoakVerifyTests.restarted)   // no running turns left
        for start in [before.engineStartedAt, SoakVerifyTests.taken, nil] {
            let verdict = try rig.verify(before, engineStartedAt: start)
            #expect(verdict.result == .wait, "\(String(describing: start)): \(verdict.lines())")
            let settled = try #require(Self.check(verdict, "settled"))
            #expect(settled.result == .wait)
            #expect(settled.detail.hasPrefix("the engine has not restarted since the checkpoint ("), "\(settled.detail)")
            // Turns are never counted from a start older than the checkpoint.
            #expect(Self.check(verdict, "companyRunning")?.detail.contains("no restart since the checkpoint") == true,
                    "\(verdict.lines())")
        }
    }

    /// Fix round 1 #9: a paused company, or an engine hold, is not running free.
    @Test func pausedOrHeldIsNotRunning() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.killAndRestart()
        #expect(Self.check(try rig.verify(before), "companyRunning")?.result == .pass)
        try rig.sql("UPDATE company SET status = 'paused' WHERE id = ?", [rig.company.id])
        let paused = try #require(Self.check(try rig.verify(before), "companyRunning"))
        #expect(paused.result == .fail && paused.detail.contains("paused"), "\(paused.detail)")
        try rig.sql("UPDATE company SET status = 'running' WHERE id = ?", [rig.company.id])
        try rig.sql("INSERT INTO engineHold (id, reason, detail, since) VALUES (1, 'network', 'offline', ?)", [SoakVerifyTests.restarted])
        let held = try #require(Self.check(try rig.verify(before), "companyRunning"))
        #expect(held.result == .fail && held.detail.contains("on hold (network"), "\(held.detail)")
    }

    /// Fix round 1 #9: a lease whose holder is no agent at all.
    @Test func leaseOfMissingAgentFails() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.killAndRestart()
        try rig.store.writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "UPDATE workLease SET agentId = 'no-such-agent' WHERE itemId = ?", arguments: [rig.item.id])
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let leases = try #require(Self.check(try rig.verify(before), "leasesRecovered"))
        #expect(leases.result == .fail && leases.detail.contains("no longer exists"), "\(leases.detail)")
    }

    @Test func orphanInProgressFails() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.killAndRestart()
        // The lease row gone, the item left in progress: nobody may write it and nobody will pick it up.
        try rig.sql("DELETE FROM workLease WHERE itemId = ?", [rig.item.id])
        let leases = try #require(Self.check(try rig.verify(before), "leasesRecovered"))
        #expect(leases.result == .fail)
        #expect(leases.detail.contains(rig.item.key) && leases.detail.contains("no lease"), "\(leases.detail)")
        // Released properly (the item back to ready): pass.
        try rig.sql("UPDATE workItem SET status = 'ready' WHERE id = ?", [rig.item.id])
        #expect(Self.check(try rig.verify(before), "leasesRecovered")?.result == .pass)
    }

    @Test func killedHolderLeaseFails() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.killAndRestart()
        try rig.sql("UPDATE agent SET state = 'killed' WHERE id = ?", [rig.eng.id])
        try rig.sql("UPDATE turn SET outcome = 'interrupted', endedAt = ? WHERE agentId = ? AND outcome = 'inProgress'", [SoakVerifyTests.now, rig.eng.id])
        let leases = try #require(Self.check(try rig.verify(before), "leasesRecovered"))
        #expect(leases.result == .fail)
        #expect(leases.detail.contains("killed"), "\(leases.detail)")
    }

    @Test func midMergeKillRecovers() throws {
        let rig = try Rig()
        // A batch journaled at `prepared` when the checkpoint is taken (the engine killed mid-merge) ...
        var batch = MergeBatch(companyId: rig.company.id, number: 7, step: .prepared, requestIds: [], startedAt: SoakVerifyTests.taken.addingTimeInterval(-60))
        batch.updatedAt = SoakVerifyTests.taken.addingTimeInterval(-30)
        let row = batch
        try rig.store.writer.write { db in try row.insert(db) }
        let before = try rig.checkpoint()
        #expect(before.openBatches == [batch.id])
        try rig.killAndRestart()
        // ... finished by the restarted engine's recovery.
        try rig.sql("UPDATE mergeBatch SET step = 'done', updatedAt = ?, finishedAt = ? WHERE id = ?",
                    [SoakVerifyTests.restarted.addingTimeInterval(1), SoakVerifyTests.restarted.addingTimeInterval(1), batch.id])
        let verdict = try rig.verify(before)
        let merges = try #require(Self.check(verdict, "noStuckMerges"))
        #expect(merges.result == .pass, "\(merges.detail)")
        #expect(merges.detail.contains("B-7"), "\(merges.detail)")
        #expect(verdict.result == .pass, "\(verdict.lines())")
    }

    @Test func stuckBatchFails() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.killAndRestart()
        var batch = MergeBatch(companyId: rig.company.id, number: 8, step: .rebased, requestIds: [], startedAt: SoakVerifyTests.restarted)
        batch.updatedAt = SoakVerifyTests.restarted.addingTimeInterval(5)
        let row = batch
        try rig.store.writer.write { db in try row.insert(db) }
        // 395 s at `rebased`: not stuck yet.
        #expect(Self.check(try rig.verify(before), "noStuckMerges")?.result == .pass)
        // 705 s later: stuck (past 600 s since the later of its last step and the engine's start).
        let late = SoakVerifyTests.restarted.addingTimeInterval(710)
        let merges = try #require(Self.check(try rig.verify(before, now: late), "noStuckMerges"))
        #expect(merges.result == .fail)
        #expect(merges.detail.contains("B-8") && merges.detail.contains("rebased"), "\(merges.detail)")
    }

    @Test func duplicateDeployFlagged() throws {
        let rig = try Rig()
        let plan = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", "dist"])],
                                  stageFrom: ["dist"], cwdPath: "/tmp/brahma-soak-test/upload", network: ["api.cloudflare.com"],
                                  tokenSecret: "CLOUDFLARE_API_TOKEN", build: "npm run build", outputDir: "dist")
        func release(_ n: Int, _ status: ReleaseStatus, deployStarted: Date?) throws -> Release {
            var r = Release(companyId: rig.company.id, number: n, version: "0.\(n).0", status: status, provider: .cloudflarePages,
                            project: "acme", commit: rig.mainTip, build: "npm run build", outputDir: "dist", plan: plan, rollbackPlan: plan,
                            proposedById: rig.eng.id, createdAt: SoakVerifyTests.started)
            r.deployStartedAt = deployStarted
            let row = r
            try rig.store.writer.write { db in try row.insert(db) }
            return row
        }
        // R-1 was deploying when the checkpoint was taken; the kill interrupts it (recovery never runs it again).
        let r1 = try release(1, .deploying, deployStarted: SoakVerifyTests.taken.addingTimeInterval(-20))
        let before = try rig.checkpoint()
        #expect(before.releaseExecutions == [r1.id: 1])
        try rig.killAndRestart()
        try rig.sql("UPDATE release SET status = 'interrupted' WHERE id = ?", [r1.id])
        #expect(Self.check(try rig.verify(before), "noDuplicateOutsideActions")?.result == .pass)

        // Deployed again: the same commit to the same project after the kill.
        _ = try release(2, .deployed, deployStarted: SoakVerifyTests.restarted.addingTimeInterval(20))
        let dup = try #require(Self.check(try rig.verify(before), "noDuplicateOutsideActions"))
        #expect(dup.result == .fail)
        #expect(dup.detail.contains("R-1") && dup.detail.contains("R-2"), "\(dup.detail)")

        // Executed twice: R-1's deploy step started again after the checkpoint.
        try rig.sql("DELETE FROM release WHERE number = 2 AND companyId = ?", [rig.company.id])
        try rig.sql("UPDATE release SET deployStartedAt = ? WHERE id = ?", [SoakVerifyTests.restarted.addingTimeInterval(5), r1.id])
        let twice = try #require(Self.check(try rig.verify(before), "noDuplicateOutsideActions"))
        #expect(twice.result == .fail)
        #expect(twice.detail.contains("R-1") && twice.detail.contains("twice"), "\(twice.detail)")
    }

    @Test func notSettledIsWait() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        try rig.killAndRestart()
        // Up 100 s of the 300 s settle: wait, not fail.
        let early = try rig.verify(before, engineStartedAt: SoakVerifyTests.now.addingTimeInterval(-100))
        #expect(early.result == .wait && !early.passed)
        #expect(Self.check(early, "settled")?.result == .wait)
        #expect(Self.check(early, "settled")?.detail.contains("100 s") == true, "\(early.lines())")
        // No engine holds the lock: wait.
        let none = try rig.verify(before, engineStartedAt: nil)
        #expect(none.result == .wait)
        #expect(Self.check(none, "settled")?.detail.contains("no engine") == true, "\(none.lines())")
        // A shorter settle (the DEBUG-only override the process test uses) settles sooner.
        let quick = try SoakVerify.run(before, store: rig.store, git: rig.git.ws, now: SoakVerifyTests.now,
                                       engineStartedAt: SoakVerifyTests.now.addingTimeInterval(-100), settle: 60)
        #expect(Self.check(quick, "settled")?.result == .pass)
        #if DEBUG
        #expect(SoakVerify.settle(environment: ["BRAHMA_SOAK_SETTLE_SECONDS": "2"]) == 2)
        #endif
        #expect(SoakVerify.settle(environment: [:]) == SoakVerify.defaultSettle)
        #expect(SoakVerify.settle(environment: ["BRAHMA_SOAK_SETTLE_SECONDS": "-1"]) == SoakVerify.defaultSettle)
    }

    /// The other two checks, from the same timeline: a turn the killed engine left `inProgress`, an agent stuck `running`, an
    /// engine alert filed after the checkpoint.
    @Test func turnsAndCompanyChecks() throws {
        let rig = try Rig()
        let before = try rig.checkpoint()
        // Restarted but the killed engine's turn was never recorded as ended.
        try rig.startTurn(rig.eng, at: SoakVerifyTests.restarted.addingTimeInterval(10))
        let turns = try #require(Self.check(try rig.verify(before), "interruptedTurnsRecorded"))
        #expect(turns.result == .fail, "\(turns.detail)")
        #expect(turns.detail.contains("still in progress"), "\(turns.detail)")

        let rig2 = try Rig()
        let before2 = try rig2.checkpoint()
        _ = try rig2.store.recoverInterruptedTurns(now: SoakVerifyTests.restarted)
        // No turn since the restart: the company is not running yet.
        let idle = try #require(Self.check(try rig2.verify(before2), "companyRunning"))
        #expect(idle.result == .fail && idle.detail.contains("no turn"), "\(idle.detail)")
        try rig2.startTurn(rig2.eng, at: SoakVerifyTests.restarted.addingTimeInterval(10))
        #expect(Self.check(try rig2.verify(before2), "companyRunning")?.result == .pass)
        // An owner ask about recovery after the checkpoint: the owner was touched.
        _ = try MeasureFixtures.ask(rig2.store, company: rig2.company, number: 1, kind: .engineAlert, status: .pendingOwner,
                                    decidedBy: nil, decidedAt: SoakVerifyTests.restarted.addingTimeInterval(30))
        let asked = try #require(Self.check(try rig2.verify(before2), "companyRunning"))
        #expect(asked.result == .fail && asked.detail.contains("A-1"), "\(asked.detail)")
        // An agent left `running` with no turn in progress.
        let rig3 = try Rig()
        let before3 = try rig3.checkpoint()
        try rig3.killAndRestart()
        try rig3.sql("UPDATE turn SET outcome = 'succeeded', endedAt = ? WHERE outcome = 'inProgress'", [SoakVerifyTests.now])
        let stuck = try #require(Self.check(try rig3.verify(before3), "interruptedTurnsRecorded"))
        #expect(stuck.result == .fail && stuck.detail.contains("eng-1"), "\(stuck.detail)")
    }
}
