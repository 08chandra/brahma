import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct RestoreTests {
    /// A data home with one company and a message, a snapshot of it, and then a later company the snapshot does not have.
    private func scenario() throws -> (env: BackupEnv, snapshot: URL, service: BackupService) {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.post(acme, "findable zebra message")
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        _ = try env.company("Later")
        return (env, snapshot, service)
    }

    @Test func refusesWhileEngineRuns() throws {
        let (env, snapshot, service) = try scenario()
        let plan = try service.planRestore(snapshot: snapshot)
        let lock = try OrchestratorLock.acquire(paths: env.paths)
        #expect(throws: RestoreError.engineRunning) { try service.planRestore(snapshot: snapshot) }
        #expect(throws: RestoreError.engineRunning) { try service.restore(plan) }
        #expect(try env.companyNames(in: env.paths.database) == ["Acme", "Later"])      // untouched
        withExtendedLifetime(lock) {}
    }

    @Test func refusesWhileOtherProcessHasDBOpen() throws {
        let (env, snapshot, service) = try scenario()
        // A real child process holding a connection: sqlite3 reading statements from a pipe keeps the database open.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        child.arguments = [env.paths.database.path]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { try? input.fileHandleForWriting.close(); child.terminate(); child.waitUntilExit() }
        input.fileHandleForWriting.write(Data("SELECT count(*) FROM company;\n".utf8))
        let answer = output.fileHandleForReading.availableData       // it answered, so the connection is open
        #expect(String(decoding: answer, as: UTF8.self).contains("2"))
        let pids = try DBOpeners.pids(of: env.paths.database)
        #expect(pids.contains(child.processIdentifier))
        #expect(!pids.contains(getpid()))                              // the caller is never listed
        #expect(throws: RestoreError.dbOpenElsewhere(pids)) { try service.planRestore(snapshot: snapshot) }
        // Closing the connection lets it through.
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        #expect(try DBOpeners.pids(of: env.paths.database).isEmpty)
        _ = try service.planRestore(snapshot: snapshot)
    }

    @Test func refusesNewerSchema() throws {
        let (env, snapshot, service) = try scenario()
        let future = env.paths.dbBackups.appending(path: "brahma-20991231T000000.000Z-manual.sqlite")
        try FileManager.default.copyItem(at: snapshot, to: future)
        let queue = try DatabaseQueue(path: future.path)
        try queue.write { db in try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v99-from-the-future')") }
        try queue.close()
        #expect(throws: RestoreError.newerSchema) { try service.planRestore(snapshot: future) }
        // `--latest` skips it.
        #expect(service.latestGood()?.url == snapshot)
    }

    @Test func refusesCorruptSnapshot() throws {
        let (env, snapshot, service) = try scenario()
        let bad = env.paths.dbBackups.appending(path: "brahma-20991231T000000.000Z-manual.sqlite")
        var bytes = try Data(contentsOf: snapshot)
        let middle = bytes.count / 2
        bytes.replaceSubrange(middle..<min(bytes.count, middle + 4096), with: Data(repeating: 0xAB, count: min(4096, bytes.count - middle)))
        try bytes.write(to: bad)
        #expect(throws: RestoreError.corrupt) { try service.planRestore(snapshot: bad) }
        let notADatabase = env.root.appending(path: "junk.sqlite")
        try Data("not a database at all, just text".utf8).write(to: notADatabase)
        #expect(throws: RestoreError.corrupt) { try service.planRestore(snapshot: notADatabase) }
        #expect(throws: RestoreError.notFound) { try service.planRestore(snapshot: env.root.appending(path: "missing.sqlite")) }
        #expect(try env.companyNames(in: env.paths.database) == ["Acme", "Later"])
    }

    @Test func dryRunTouchesNothing() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let acme: Company
        let snapshot: URL
        do {
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            snapshot = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
            try store.close()
        }
        // Two commits land after the snapshot: they are kept, and the dry run says so.
        let fixture = GitFixture(existing: URL(fileURLWithPath: acme.workspacePath, isDirectory: true))
        for n in 1...2 {
            try fixture.write("f\(n).txt", "x")
            try fixture.git(["add", "-A"])
            try fixture.git(["commit", "-m", "later \(n)"])
        }
        let before = try snapshotOfTree(paths.home)
        let service = BackupService(paths: paths)
        let plan = try service.planRestore(snapshot: snapshot)
        #expect(plan.reposAhead == [RepoAhead(company: "Acme", commitsAfterSnapshot: 2)])
        #expect(plan.warnings == [RepoAhead(company: "Acme", commitsAfterSnapshot: 2).warning])
        #expect(plan.warnings.first?.contains("Brahma will not adopt them until you review main and accept it") == true)
        let result = try runBrahma(["restore", "--dry-run", snapshot.path], home: home.url)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Acme: repo has 2 commits after the snapshot; they are kept, but Brahma will not adopt them"))
        #expect(result.stdout.contains("nothing was changed"))
        let after = try snapshotOfTree(paths.home)
        #expect(after == before, "changed: \(Set(after).symmetricDifference(Set(before)).sorted())")   // not a byte, not a file, not a marker
        #expect(!FileManager.default.fileExists(atPath: BackupService.restoreMarker(paths: paths).path))
    }

    @Test func restoreIsAtomicRename() async throws {
        let (env, snapshot, service) = try scenario()
        try env.store.close()
        let plan = try service.planRestore(snapshot: snapshot)
        let path = env.paths.database.path
        let done = CallCounter()
        let misses = CallCounter()
        let probe = Thread {
            var st = stat()
            while !done.isSet {
                if stat(path, &st) != 0 { misses.mark() }
            }
        }
        probe.start()
        for _ in 0..<5 { _ = try service.restore(plan) }                   // repeated, to give the probe every chance
        done.mark()
        try await Task.sleep(for: .milliseconds(50))
        #expect(misses.calls == 0)                                         // the live path was never missing
        #expect(try env.companyNames(in: env.paths.database) == ["Acme"])
    }

    @Test func restoreKeepsPrevious() throws {
        let (env, snapshot, service) = try scenario()
        try env.store.close()
        let plan = try service.planRestore(snapshot: snapshot)
        let outcome = try service.restore(plan)
        #expect(try env.companyNames(in: env.paths.database) == ["Acme"])
        let previous = try #require(outcome.previousCopy)
        #expect(previous.lastPathComponent.hasPrefix("brahma.sqlite.pre-restore-"))
        #expect(try env.companyNames(in: previous) == ["Acme", "Later"])    // the database as it was, bytes and all
        let pre = try #require(outcome.preRestoreSnapshot)
        #expect(try env.companyNames(in: pre) == ["Acme", "Later"])
        #expect(service.list().contains { $0.reason == .preRestore && $0.url == pre })
        #expect(!FileManager.default.fileExists(atPath: env.paths.database.path + ".restoring"))
        #expect(!FileManager.default.fileExists(atPath: env.paths.database.path + "-wal"))
        // And the restored database opens, migrated, as a normal store.
        let reopened = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try reopened.companies().map(\.name) == ["Acme"])
    }

    @Test func restoreRebuildsSearchIndex() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.post(acme, "findable zebra message")
        let service = env.service()
        // Stand-in for a VACUUM that renumbered the rowids under an external-content index: the snapshot's index is wrong.
        try env.store.writer.write { db in try db.execute(sql: "INSERT INTO messageFts(messageFts) VALUES('delete-all')") }
        #expect(try env.store.searchMessages(companyId: acme.id, query: "zebra").isEmpty)
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        #expect(outcome.warnings.isEmpty)
        let reopened = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        // Messages written before the snapshot are found by full-text search after the restore ...
        #expect(try reopened.searchMessages(companyId: acme.id, query: "zebra").map(\.text) == ["findable zebra message"])
        // ... and the index agrees with the table.
        try reopened.writer.write { db in try db.execute(sql: "INSERT INTO messageFts(messageFts) VALUES('integrity-check')") }
    }

    // `markerReadoptsRepos` planted a bare marker and expected main's current head adopted: that was the review bypass fixed in
    // Task 12 fix round 1. Its coverage lives in RestoreMarkerTests (happyPathAdoptsRecordedMain and the refusals).

    // MARK: Final review I3: what a restore must not roll back

    /// A data home with one company, two agents and two approved grants (one of them one-use), snapshotted.
    private struct Forward {
        let env: BackupEnv
        let service: BackupService
        let acme: Company
        let eng: Agent, other: Agent
        let always: Grant, once: Grant
        let snapshot: URL

        init() throws {
            let env = try BackupEnv()
            let acme = try env.company("Acme")
            let eng = try env.store.hire(companyId: acme.id, name: "eng-1", role: "engineer", model: "sonnet")
            self.env = env; self.acme = acme; self.eng = eng
            service = env.service()
            other = try env.store.hire(companyId: acme.id, name: "eng-2", role: "engineer", model: "sonnet")
            always = try Self.approve(env, acme, eng, "always.example.com", .agent)
            once = try Self.approve(env, acme, eng, "once.example.com", .once)
            snapshot = try service.snapshot(reason: .manual)
        }

        /// `request_access` by `eng`, approved the owner's way.
        static func approve(_ env: BackupEnv, _ acme: Company, _ eng: Agent, _ domain: String, _ scope: GrantScope,
                            duration: GrantDuration = .always) throws -> Grant {
            _ = try CompanyTools(store: env.store, companyId: acme.id, agentId: eng.id).call(name: "request_access", arguments: [
                "kind": .string("network_domain"), "value": .string(domain), "reason": .string("I need it")])
            let ask = try #require(try env.store.asks(companyId: acme.id).last { $0.kind == .grant })
            let grantEnv = SandboxEnvironment(userHome: try tempDir(), darwinUserTemp: nil, shell: "/bin/zsh")
            return try env.store.approveAccess(askId: ask.id, scope: scope, duration: duration, note: "ok", environment: grantEnv)
        }

        /// Restores the snapshot (the live store closed first) and opens the restored database as the engine would.
        func restore() throws -> (Store, RestoreOutcome) {
            try env.store.close()
            let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
            return (try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir), outcome)
        }

        func grant(_ store: Store, _ g: Grant) throws -> Grant {
            try #require(try store.grants(companyId: acme.id, includeInactive: true).first { $0.id == g.id })
        }
    }

    /// The engine comes back stopped, whatever the snapshot said: the owner resumes it.
    @Test func restoreComesBackStopped() async throws {
        let f = try Forward()
        #expect(try f.env.store.engineStopped() == nil, "neither the snapshot nor the live database was stopped")
        let (restored, _) = try f.restore()
        let stop = try #require(try restored.engineStopped())
        #expect(stop.by == "restore"); #expect(stop.note?.contains(f.snapshot.lastPathComponent) == true)
        #expect(stop.note?.contains("nothing you had turned off was rolled back") == true, "\(stop.note ?? "")")
        // An engine on the restored database admits nothing until the owner resumes it.
        let paths = f.env.paths
        let fake = FakeTurnRunner()
        let orchestrator = Orchestrator(store: restored, runner: fake, paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: TestClock().function, vault: MemoryVault())
        try onWorkspaceProfile(restored, f.acme)
        _ = try MessageRouter(store: restored).sendDM(companyId: f.acme.id, from: .owner, to: f.eng.name, text: "go", now: Date())
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(fake.requests.isEmpty, "a restored engine ran a turn before the owner resumed it")
        #expect(try restored.resumeAfterStop(now: Date()))
    }

    /// Final-review m7: a snapshot taken while a release was `approved` (not started) never carries out that deploy after the
    /// restore without a fresh approval (the owner may have rolled it back since): the release is cancelled ("restored from
    /// backup; propose again") and the restore's notes say so. Every other release is left as the snapshot recorded it.
    @Test func restoreCancelsApprovedReleases() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let devops = try env.store.hire(companyId: acme.id, name: "devops-1", role: "devops", model: "sonnet")
        let plan = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", "dist"])],
                                  stageFrom: ["dist"], cwdPath: "/tmp/brahma-restore-test/upload", network: [],
                                  tokenSecret: "CLOUDFLARE_API_TOKEN", build: nil, outputDir: "dist")
        let t = Date(timeIntervalSince1970: 1_781_000_000)
        func release(_ n: Int, _ status: ReleaseStatus) -> Release {
            var r = Release(companyId: acme.id, number: n, version: "0.\(n).0", status: status, provider: .cloudflarePages, project: "acme",
                            commit: String(repeating: "\(n)", count: 40), build: nil, outputDir: "dist", plan: plan, rollbackPlan: plan,
                            proposedById: devops.id, createdAt: t)
            if status != .proposed { r.approvedAt = t; r.approvedBy = "owner" }
            return r
        }
        try env.store.writer.write { db in
            try release(1, .deployed).insert(db)
            try release(2, .approved).insert(db)
        }
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let r2 = try #require(try restored.release(companyId: acme.id, ref: "R-2"))
        #expect(r2.status == .cancelled)
        #expect(r2.failedReason == "restored from backup; propose again")
        #expect(r2.finishedAt != nil)
        #expect(try restored.release(companyId: acme.id, ref: "R-1")?.status == .deployed)
        #expect(outcome.warnings.contains("Acme: R-2 (release 0.2.0) was approved in the snapshot and is cancelled; propose it again"),
                "\(outcome.warnings)")
        let activity = try restored.writer.read { try ActivityEvent.filter(Column("companyId") == acme.id).fetchAll($0) }.map(\.text)
        #expect(activity.contains("R-2 (release 0.2.0) was cancelled: restored from backup; propose again"), "\(activity)")
        // Resumed, the engine finds nothing to carry out.
        _ = try restored.resumeAfterStop(now: Date())
        #expect(try restored.claimRelease(companyId: acme.id, now: Date()) == nil)
    }

    /// Grants revoked (or used up) after the snapshot stay revoked (used up): carried from the live database.
    @Test func restoreKeepsRevocations() throws {
        let f = try Forward()
        let revoked = try f.env.store.revokeGrant(companyId: f.acme.id, number: f.always.number, now: Date())
        #expect(revoked.revokedAt != nil)
        #expect(try f.env.store.consumeGrants(ids: [f.once.id], turnId: "t-1", now: Date()).isEmpty, "the use was counted")
        let usesAfter = try f.grant(f.env.store, f.once).usesLeft
        let (restored, _) = try f.restore()
        let always = try f.grant(restored, f.always)
        #expect(always.revokedAt != nil, "a grant revoked after the snapshot is active again")
        #expect(always.revokedBy == revoked.revokedBy)
        #expect(try f.grant(restored, f.once).usesLeft == usesAfter, "a one-use grant used after the snapshot is usable again")
        #expect(try restored.grants(companyId: f.acme.id).isEmpty, "no grant is live after the restore")
    }

    /// Every taint mark made after the snapshot survives the restore (agent, company, machine-wide, never-clean commits, the
    /// session and item flags), and the machine-wide mark is set by the restore itself.
    @Test func restoreKeepsTaintMarks() throws {
        let f = try Forward()
        try f.env.store.markTainted(agentId: f.eng.id, source: "web: evil.example", now: Date())
        let neverClean = String(repeating: "c", count: 40)
        try f.env.store.recordTaintedLabCommits([neverClean])
        try f.env.store.writer.write { db in
            try db.execute(sql: "INSERT INTO companyTaint (companyId, source, profile, markedAt) VALUES (?, 'full session', 'full', ?)",
                           arguments: [f.acme.id, Date()])
        }
        let (restored, outcome) = try f.restore()
        #expect(outcome.warnings.isEmpty, "\(outcome.warnings)")
        let own = try restored.writer.read { db in try String.fetchOne(db, sql: "SELECT source FROM labTaint WHERE agentId = ?", arguments: [f.eng.id]) }
        #expect(own?.contains("evil.example") == true, "the agent's lab mark was lost")
        let agent = try #require(try restored.agent(id: f.eng.id))
        #expect(agent.sessionTainted, "the agent's tainted session reads clean again")
        #expect(agent.taintSources.contains("evil.example"))
        #expect(try restored.companyLabTaint(companyId: f.acme.id)?.profile == "full")
        #expect(try restored.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintedLabCommit WHERE sha = ?", arguments: [neverClean]) } == 1)
        let machine = try #require(try restored.machineLabTaint())
        #expect(machine.source?.contains(f.snapshot.lastPathComponent) == true, "the restore did not set the machine-wide mark")
        // Every lab reads as marked until the owner clears it.
        #expect(try restored.labTaint(agentId: f.other.id) != nil)
    }

    /// Lab commits made after the snapshot are never recorded clean: one recorded tainted before the restore stays tainted, and
    /// one never recorded at all is recorded tainted under the restore's machine-wide mark, and still not clean after the
    /// owner's clear unless the engine saw it made in a clean turn.
    @Test func restoreNeverRecordsPostSnapshotLabCommitsClean() throws {
        let f = try Forward()
        let taintedAfter = String(repeating: "a", count: 40), unrecorded = String(repeating: "b", count: 40)
        #expect(try f.env.store.recordLabCommits(agentId: f.eng.id, turnId: nil, shas: [taintedAfter], tainted: true) == 1)
        let (restored, _) = try f.restore()
        // The next clean turn of the agent records the lab's commits.
        _ = try restored.recordLabCommits(agentId: f.eng.id, turnId: nil, shas: [taintedAfter, unrecorded], tainted: false)
        #expect(try restored.labCommitTainted(agentId: f.eng.id, sha: taintedAfter))
        #expect(try restored.labCommitTainted(agentId: f.eng.id, sha: unrecorded))
        // After the owner's machine-wide clear, a commit the engine did not see made in a clean turn still is not clean.
        try restored.clearMachineLabTaint(now: Date())
        let later = String(repeating: "d", count: 40)
        _ = try restored.recordLabCommits(agentId: f.other.id, turnId: nil, shas: [later, taintedAfter], tainted: false)
        #expect(try restored.labCommitTainted(agentId: f.other.id, sha: later))
        #expect(try restored.labCommitTainted(agentId: f.other.id, sha: taintedAfter), "a commit tainted in one lab is clean in another")
    }

    /// Fix-wave F1: a grant that ended on company-active time, or with its sprint, after the snapshot stays ended. Both clocks
    /// are in the database and roll back with it; the restore revokes every grant the live database no longer counts.
    @Test func restoreKeepsExpiredGrantsExpired() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let eng = try env.store.hire(companyId: acme.id, name: "eng-1", role: "engineer", model: "sonnet")
        // No sprint yet: seven active days.
        let timed = try Forward.approve(env, acme, eng, "timed.example.com", .agent, duration: .sprint)
        #expect(timed.expiresActive != nil && timed.sprintId == nil)
        let sprint = Sprint(id: UUID().uuidString, companyId: acme.id, number: 1, team: nil, goal: "g", cadence: .sprint,
                            status: .active, createdAt: Date())
        try env.store.writer.write { db in try sprint.insert(db) }
        let sprintBound = try Forward.approve(env, acme, eng, "sprint.example.com", .agent, duration: .sprint)
        #expect(sprintBound.sprintId == sprint.id)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        #expect(try env.store.grants(companyId: acme.id).count == 2, "both live at the snapshot")
        // After the snapshot: the active week runs out, and the sprint ends.
        try env.store.advanceActive(companyId: acme.id, by: GrantResolver.noSprintTTL + 60)
        try env.store.writer.write { db in
            try db.execute(sql: "UPDATE sprint SET status = ? WHERE id = ?", arguments: [SprintStatus.closed.rawValue, sprint.id])
        }
        #expect(try env.store.grants(companyId: acme.id).isEmpty)
        try env.store.close()
        _ = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        // The restored database's own clocks say both are live again; the restore revoked them.
        #expect(try restored.grants(companyId: acme.id).isEmpty, "a grant that ended after the snapshot is live again")
        for g in [timed, sprintBound] {
            let row = try #require(try restored.grants(companyId: acme.id, includeInactive: true).first { $0.id == g.id })
            #expect(row.revokedAt != nil && row.revokedBy == "restore", "\(g.value)")
        }
    }

    /// Fix-wave F2: what the owner turned off after the snapshot and the restore turns back on is listed in the restore's
    /// warnings, its stop note and its alert, so the owner reviews it before resuming.
    @Test func restoreListsWhatItRolledBack() throws {
        let f = try Forward()
        // After the snapshot the owner removes eng-2.
        try f.env.store.writer.write { db in try db.execute(sql: "UPDATE agent SET state = 'killed' WHERE id = ?", arguments: [f.other.id]) }
        let (restored, outcome) = try f.restore()
        let removed = "@eng-2 (Acme), removed after the snapshot, is back"
        #expect(outcome.warnings.contains { $0.contains(removed) }, "\(outcome.warnings)")
        #expect(!outcome.warnings.contains { $0.contains("@eng-1") })
        let stop = try #require(try restored.engineStopped())
        #expect(stop.note?.contains(removed) == true, "\(stop.note ?? "")")
        let alert = try #require(try restored.asks(companyId: f.acme.id).first {
            $0.kind == .engineAlert && $0.subjectId == Store.engineAlertKey(RestoreCarry.restoreAlertReason) && $0.status == .pendingOwner
        })
        #expect(alert.summary.contains(removed) && alert.summary.contains("stopped"), "\(alert.summary)")
    }

    /// S35: a company profile narrowed after the snapshot (Full in the backup, Sandboxed live) stays narrowed, and is reported.
    @Test func restoreKeepsTheNarrowerProfile() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.updateSandbox(companyId: acme.id, SandboxPatch(profile: .full), userHome: try tempDir())
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.updateSandbox(companyId: acme.id, SandboxPatch(profile: .sandboxed), userHome: try tempDir())
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.company(id: acme.id)?.permissionProfile == .sandboxed, "the restore widened the profile back to Full")
        #expect(outcome.warnings.contains { $0.contains("Acme: profile kept at sandboxed (the snapshot had full)") }, "\(outcome.warnings)")
        #expect(try restored.engineStopped()?.note?.contains("profile kept at sandboxed") == true)
    }

    /// S35: a backup taken under `auto`, restored while the company asks the owner what matters (`important`): it stays
    /// `important`, and the report says so.
    @Test func restoreKeepsTheStricterAutonomy() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.setAutonomy(companyId: acme.id, .auto)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setAutonomy(companyId: acme.id, .important)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.company(id: acme.id)?.autonomy == .important, "the restore loosened autonomy back to auto")
        #expect(outcome.warnings.contains { $0.contains("Acme: autonomy kept at important (the snapshot had auto)") }, "\(outcome.warnings)")
        let alert = try #require(try restored.asks(companyId: acme.id).first {
            $0.kind == .engineAlert && $0.subjectId == Store.engineAlertKey(RestoreCarry.restoreAlertReason)
        })
        #expect(alert.summary.contains("autonomy kept at important"), "\(alert.summary)")
    }

    /// S35: where a restore keeps auto-merge off (the company's switch here, and the owner-wide one), an item the snapshot had
    /// auto-approved and waiting to land loses that approval, as switching auto-merge off live does: it needs a review again.
    @Test func restoreKeepingAutoMergeOffRevokesAutoApprovals() throws {
        for ownerWide in [false, true] {
            let env = try BackupEnv()
            let acme = try env.company("Acme")
            try env.store.setAutoMergeSmall(companyId: acme.id, true)
            let item = try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Small fix", status: .ready), now: Date())
            try env.store.writer.write { db in
                try db.execute(sql: "UPDATE workItem SET autoApproved = 1, status = ?, mergeState = ? WHERE id = ?",
                               arguments: [WorkItemStatus.inReview.rawValue, MergeState.pending.rawValue, item.id])
            }
            let service = env.service()
            let snapshot = try service.snapshot(reason: .manual)
            if ownerWide { try env.store.setAutoMerge(false) } else { try env.store.setAutoMergeSmall(companyId: acme.id, false) }
            try env.store.close()
            let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
            let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
            let after = try #require(try restored.workItem(id: item.id))
            #expect(!after.autoApproved, "an auto-approval from the snapshot survived (owner-wide: \(ownerWide))")
            #expect(after.mergeState == MergeState.none)
            let events = try restored.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM workItemEvent WHERE itemId = ?", arguments: [item.id])
            }
            #expect(events.contains { $0.contains("auto-merge was switched off before it landed") }, "\(events)")
            let line = ownerWide ? "owner-wide auto-merge kept off" : "Acme: auto-merge kept at off"
            #expect(outcome.warnings.contains { $0.contains(line) }, "\(outcome.warnings)")
        }
    }

    /// S36: the owner-wide auto-merge folder list is never widened by a restore: backup [a, b], live [a] keeps [a], reported.
    @Test func restoreKeepsTheNarrowerAutoMergePaths() throws {
        let env = try BackupEnv()
        try env.store.setAutoMergePaths(["docs/**", "tests/**"])
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setAutoMergePaths(["docs/**"])
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        let stored = try restored.writer.read { db in try String.fetchOne(db, sql: "SELECT autoMergePaths FROM ownerSettings WHERE id = 1") }
        #expect(stored.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } == ["docs/**"], "\(stored ?? "nil")")
        #expect(outcome.warnings.contains { $0.contains("owner-wide auto-merge folders kept at docs/** (the snapshot had docs/**, tests/**)") },
                "\(outcome.warnings)")
        // The rule itself: both set, the intersection; one set, the live list.
        #expect(RestoreCarry.Settings.narrowerAutoMergePaths(live: ["a", "c"], restored: ["a", "b"]) == ["a"])
        #expect(RestoreCarry.Settings.narrowerAutoMergePaths(live: nil, restored: ["a"]) == nil)
        #expect(RestoreCarry.Settings.narrowerAutoMergePaths(live: ["a"], restored: nil) == ["a"])
    }

    /// The other direction: a setting the owner loosened after the snapshot goes back to the snapshot's stricter value.
    @Test func restoreNeverLoosensASetting() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.setAutonomy(companyId: acme.id, .everything)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setAutonomy(companyId: acme.id, .auto)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.company(id: acme.id)?.autonomy == .everything)
        #expect(!outcome.warnings.contains { $0.contains("autonomy") }, "\(outcome.warnings)")
    }

    /// When the live database cannot be read, nothing it held can be carried: the restore fails closed (every grant revoked,
    /// every session and open item marked), and still comes back stopped with the machine-wide mark.
    @Test func unreadableLiveDatabaseFailsClosed() throws {
        let f = try Forward()
        try f.env.store.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: f.env.paths.database.path + suffix) }
        try Data(repeating: 0x5a, count: 8192).write(to: f.env.paths.database)
        let outcome = try f.service.restore(try f.service.planRestore(snapshot: f.snapshot))
        #expect(outcome.warnings.contains { $0.contains("could not be read") }, "\(outcome.warnings)")
        let restored = try Store(path: f.env.paths.database.path, backupsDir: f.env.paths.backupsDir)
        #expect(try restored.engineStopped() != nil)
        #expect(try restored.grants(companyId: f.acme.id).isEmpty, "a grant stayed live")
        #expect(try f.grant(restored, f.always).revokedBy == "restore")
        #expect(try restored.agent(id: f.eng.id)?.sessionTainted == true)
        #expect(try restored.machineLabTaint()?.source != nil)
    }

    @Test func cliRestoreOwnerOnly() throws {
        let home = try OwnerTestHome(initOwner: false)
        // No owner key in this data home: refused.
        let noKey = try runBrahma(["restore", "--list"], home: home.url)
        #expect(noKey.status != 0 && noKey.stderr.contains("owner key missing"))
        try #require(try initOwnerKey(home: home.url) == 0, "brahma owner init failed under script")
        // From an agent's shell: refused, even with the key.
        let agent = try runBrahma(["restore", "--list"], home: home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands can't run inside an agent turn"))
        let agentBackup = try runBrahma(["backup", "list"], home: home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agentBackup.status != 0)
        let agentExport = try runBrahma(["export", "acme", "--to", home.url.appending(path: "out").path], home: home.url,
                                        extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agentExport.status != 0)
        // The owner can.
        let owner = try runBrahma(["restore", "--list"], home: home.url)
        #expect(owner.status == 0)
        // Neither argument nor flag: a usage error.
        let neither = try runBrahma(["restore"], home: home.url)
        #expect(neither.status != 0)
    }

    @Test func cliRunRefusesDamagedDatabase() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try Data("this is not a sqlite database, not even close to one".utf8).write(to: paths.database)
        let result = try runBrahma(["run", "--skip-doctor"], home: home.url)
        #expect(result.status == 1)
        #expect(result.stderr.contains("brahma: database check failed ("))
        #expect(result.stderr.contains("). See: brahma restore --list"))
    }
}

final class RestoreEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RestoreEvent] = []
    func add(_ e: RestoreEvent) { lock.withLock { events.append(e) } }
    var all: [RestoreEvent] { lock.withLock { events } }
}

struct BrahmaResult { var status: Int32; var stdout: String; var stderr: String }

/// Runs the built `brahma` against a throwaway data home (file owner-key store, never the Keychain).
func runBrahma(_ args: [String], home: URL, extra: [String: String] = [:]) throws -> BrahmaResult {
    let p = Process()
    p.executableURL = brahmaExecutableURL()
    p.arguments = args
    p.environment = cliEnvironment(home: home).merging(extra) { $1 }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return BrahmaResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
}

/// Every file under `root` with its size and modification time (and the bytes of the small ones): equal means untouched.
func snapshotOfTree(_ root: URL) throws -> [String] {
    var rows: [String] = []
    let fm = FileManager.default
    guard let walker = fm.enumerator(atPath: root.path) else { return rows }
    for case let rel as String in walker {
        let attrs = try fm.attributesOfItem(atPath: root.appending(path: rel).path)
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // The engine lock file is created empty by the first check that looks at the lock; it holds nothing.
        if rel == "orchestrator.lock" { continue }
        rows.append("\(rel) \(size) \(mtime)")
    }
    return rows.sorted()
}
