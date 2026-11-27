import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct BackupTargetTests {
    /// The shared directory of fake executables (shell scripts) for these bodies, used as the tools' search path. A script that
    /// has to write somewhere test-specific gets the place through `env` (`TMPDIR` passes through to both tools).
    private func fakeBin(_ scripts: [String: String], env: [String: String] = [:]) throws -> (dir: URL, tools: BackupTools) {
        let dir = try FakeTools.bin(scripts)
        return (dir, BackupTools(searchPath: dir.path + ":/usr/bin:/bin", environment: env))
    }

    private func folder(_ name: String = "drive") throws -> URL {
        let url = try tempDir().appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
    }

    // MARK: folders

    @Test func folderTargetMirrorsAndRefusesInsideHome() throws {
        let env = try BackupEnv()
        let acme = try env.company()
        let service = env.service()
        let first = try service.snapshot(reason: .manual)
        let drive = try folder()
        // Inside the data home, inside a workspace, holding the home, or missing: refused.
        for bad in [env.paths.home.appending(path: "nested"), URL(fileURLWithPath: acme.workspacePath), env.paths.home,
                    drive.appending(path: "missing")] {
            try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
            if bad.lastPathComponent == "missing" { try? FileManager.default.removeItem(at: bad) }
            #expect(throws: BackupTargetError.self) {
                try BackupTargets.validate(.folder(path: bad.path), paths: env.paths, workspaces: [URL(fileURLWithPath: acme.workspacePath)])
            }
        }
        #expect(throws: BackupTargetError.self) {
            try BackupTargets.validate(.folder(path: env.root.path), paths: env.paths)      // holds the data home
        }
        let valid = try BackupTargets.validate(.folder(path: drive.path), paths: env.paths)
        #expect(valid == .folder(path: drive.resolvingSymlinksInPath().path))

        let outcome = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        guard case .synced(let files) = outcome else { Issue.record("not synced: \(outcome)"); return }
        #expect(files >= 1)
        let mirrored = drive.appending(path: "studio/db/\(first.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: mirrored.path))
        #expect(inode(mirrored) != inode(first))                    // a copy, never sharing an inode with the data home (S3 #3)
        #expect(try Data(contentsOf: mirrored) == Data(contentsOf: first))
        // A pruned source snapshot leaves the mirror on the next run; a new one arrives.
        let second = try service.snapshot(reason: .hourly)
        try FileManager.default.removeItem(at: first)
        _ = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        #expect(!FileManager.default.fileExists(atPath: mirrored.path))
        #expect(FileManager.default.fileExists(atPath: drive.appending(path: "studio/db/\(second.lastPathComponent)").path))
        // An empty backup set never empties the drive.
        try FileManager.default.removeItem(at: second)
        _ = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        #expect(FileManager.default.fileExists(atPath: drive.appending(path: "studio/db/\(second.lastPathComponent)").path))
    }

    @Test func folderTargetIsProtectedFromAgents() throws {
        let env = try BackupEnv()
        let drive = try folder()
        let link = try tempDir().appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: drive)
        let valid = try BackupTargets.validate(.folder(path: link.path), paths: env.paths)
        try env.store.addBackupTarget(valid)
        try env.store.addBackupTarget(.rclone(remote: "secret"))
        // The one function the sandbox tasks pass as `backupTargets` (Task 1a SandboxScope, Task 2 SandboxBaseline): folder targets, resolved.
        let protected = BackupTargets.protectedFolders(store: env.store)
        #expect(protected == [drive.resolvingSymlinksInPath().standardizedFileURL])
        #expect(!protected.contains { $0.path == link.path })
        // Stored in the database, so a fresh Store sees it.
        let reopened = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(BackupTargets.protectedFolders(store: reopened) == protected)
        #expect(try reopened.backupTargets() == [valid, .rclone(remote: "secret")])
        // Seatbelt-sandboxed checks: the baseline of every run protects the folder target and a folder WAL replica.
        let replica = try folder("replica")
        try env.store.setWALShipping(WALShippingConfig(replica: replica.path))
        let baseline = Orchestrator.checkBaseline(store: env.store, paths: env.paths).protected.map(\.path)
        #expect(baseline.contains(drive.resolvedForSandbox.path), "\(baseline)")
        #expect(baseline.contains(replica.resolvedForSandbox.path), "\(baseline)")
    }

    /// INT-I1: when the backup targets cannot be read (a stored value that does not decode), nothing that builds a sandbox
    /// proceeds as if there were none: the check baseline gets a `problem` (so nothing runs), and a sandbox settings change
    /// is refused.
    @Test func unreadableBackupTargetsFailClosed() throws {
        let env = try BackupEnv()
        let company = try env.company()
        try env.store.writer.write { db in try db.execute(sql: "UPDATE ownerPrefs SET backupTargets = 'not json' WHERE id = 1") }
        #expect(throws: (any Error).self) { _ = try BackupTargets.requiredProtectedFolders(store: env.store) }
        #expect(BackupTargets.protectedFolders(store: env.store).isEmpty, "the display-only reader still degrades")
        let baseline = Orchestrator.checkBaseline(store: env.store, paths: env.paths)
        #expect(baseline.problem?.contains("backup targets") == true, "\(String(describing: baseline.problem))")
        #expect(throws: (any Error).self) {
            try env.store.updateSandbox(companyId: company.id, SandboxPatch(allowedDomains: ["example.com"]), userHome: try tempDir())
        }
    }

    /// INT-M3: a read grant (toolchain read path) overlapping a backup folder is refused, and a folder WAL replica is in every
    /// turn's denyRead (not only the check baseline).
    @Test func backupFoldersAreRefusedAsReadPathsAndDeniedToTurns() async throws {
        let world = try World()
        let company = try world.company("Acme", profile: .sandboxed)
        let drive = try folder()
        try world.store.addBackupTarget(try BackupTargets.validate(.folder(path: drive.path), paths: world.paths))
        #expect(throws: SandboxError.self) {
            try world.store.updateSandbox(companyId: company.id, SandboxPatch(toolchainReadPaths: [drive.path]), userHome: try tempDir())
        }
        let replica = try folder("replica")
        try world.store.setWALShipping(WALShippingConfig(replica: replica.path))
        let eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        try world.dm(company, eng)
        try await world.cycle()
        let request = try #require(world.fake.requests.last { $0.agent.id == eng.id })
        let scope = try #require(request.sandbox)
        #expect(scope.denyRead.map(\.path).contains(replica.resolvedForSandbox.path), "\(scope.denyRead.map(\.path))")
    }

    @Test func folderTargetIsDeniedToSandboxedTurns() async throws {
        let world = try World()
        let company = try world.company("Acme", profile: .sandboxed)
        let eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        let drive = try folder()
        try world.store.addBackupTarget(try BackupTargets.validate(.folder(path: drive.path), paths: world.paths))
        try world.dm(company, eng)
        try await world.cycle()
        // The compiled turn (Task 1a/1b): the backup folder is protected and unreadable.
        let request = try #require(world.fake.requests.last { $0.agent.id == eng.id })
        let scope = try #require(request.sandbox)
        #expect(scope.denyRead.map(\.path).contains(drive.resolvedForSandbox.path), "\(scope.denyRead.map(\.path))")
        #expect(scope.protected.map(\.path).contains(drive.resolvedForSandbox.path), "\(scope.protected.map(\.path))")
        let settings = try TurnProfileCompiler.settingsJSON(TurnProfileCompiler.profile(for: request))
        #expect(settings.contains(drive.resolvedForSandbox.path))
    }

    @Test func unmountedFolderSkippedWithNotice() async throws {
        let env = try BackupEnv()
        _ = try env.company()
        _ = try env.service().snapshot(reason: .manual)
        let gone = try folder("unplugged").appending(path: "Volumes-X")           // never mounted
        try env.store.addBackupTarget(.folder(path: gone.path))
        #expect(BackupTargets.sync(.folder(path: gone.path), paths: env.paths) == .skipped("Backup drive \(gone.path) not connected"))
        let now = Date(timeIntervalSince1970: 1_781_107_200)
        _ = try BackupTargets.syncAll(store: env.store, paths: env.paths, now: now)
        _ = try BackupTargets.syncAll(store: env.store, paths: env.paths, now: now.addingTimeInterval(3600))
        let same = try env.store.allNotices().filter { $0.body == "Backup drive \(gone.path) not connected" }
        #expect(same.count == 1)                                           // one notice a day
        _ = try BackupTargets.syncAll(store: env.store, paths: env.paths, now: now.addingTimeInterval(2 * 86_400))
        #expect(try env.store.allNotices().filter { $0.body == "Backup drive \(gone.path) not connected" }.count == 2)
        // Through the timer job, a skipped drive is not a failure.
        try SystemTimers.ensure(store: env.store, now: now)
        let timer = try #require(env.store.timers(companyId: nil).first { $0.name == "backup.targets" })
        let context = TimerContext(store: env.store, paths: env.paths, timer: timer, now: now, blocking: Blocking())
        try await BackupJobs.targets(context)
        #expect(try env.store.allNotices().allSatisfy { $0.title != "Backup failed" })
    }

    // MARK: rclone

    @Test func rcloneNonCryptRefused() throws {
        let env = try BackupEnv()
        let (_, tools) = try fakeBin(["rclone": """
            if [ "$1" = config ] && [ "$2" = show ]; then
              case "$3" in
                secret) printf '[secret]\\ntype = crypt\\nremote = b2:bucket\\n' ;;
                plain) printf '[plain]\\ntype = s3\\nprovider = AWS\\n' ;;
                *) exit 3 ;;
              esac
              exit 0
            fi
            exit 9
            """])
        #expect(throws: BackupTargetError.invalid("plain is not an rclone crypt remote — Brahma only uploads encrypted backups")) {
            try BackupTargets.validate(.rclone(remote: "plain"), paths: env.paths, tools: tools)
        }
        #expect(throws: BackupTargetError.invalid("nothing is not an rclone crypt remote — Brahma only uploads encrypted backups")) {
            try BackupTargets.validate(.rclone(remote: "nothing:"), paths: env.paths, tools: tools)
        }
        #expect(throws: BackupTargetError.self) { try BackupTargets.validate(.rclone(remote: "--config=/x"), paths: env.paths, tools: tools) }
        #expect(try BackupTargets.validate(.rclone(remote: "secret:"), paths: env.paths, tools: tools) == .rclone(remote: "secret"))
        // No rclone at all: unavailable, never a crash.
        let none = BackupTools(searchPath: try folder("empty").path, environment: [:])
        #expect(throws: BackupTargetError.invalid("rclone is not installed (it is not on PATH)")) {
            try BackupTargets.validate(.rclone(remote: "secret"), paths: env.paths, tools: none)
        }
        _ = try env.service().snapshot(reason: .manual)
        #expect(BackupTargets.sync(.rclone(remote: "secret"), paths: env.paths, tools: none) == .unavailable("rclone is not installed"))
    }

    /// Ruling S5-7 (S5 fix 4): rclone and litestream are found through `ToolPaths` under its rules, never by a PATH walk of
    /// their own. One planted in a company workspace (a forbidden root) is never used, even first on PATH. The safe one
    /// after it is used, and with only the planted one the caller says the tool is not installed. Before the process
    /// installed its tools with the real roots, nothing is looked up at all (Ruling S-c1).
    @Test func plantedRcloneUnderAForbiddenRootIsNeverUsed() throws {
        let env = try BackupEnv()
        let marks = try tempDir()
        let workspace = try tempDir()
        let crypt = "printf '[secret]\\ntype = crypt\\n'"
        for name in ["rclone", "litestream"] {
            try FakeTools.install(at: workspace.appending(path: "bin/\(name)"), "touch \"$TMPDIR/planted-ran\"\n" + crypt)
        }
        let safe = try FakeTools.bin(["rclone": crypt, "litestream": "exit 0"])
        let planted = workspace.appending(path: "bin").path
        let tools = BackupTools(searchPath: planted + ":" + safe.path + ":/usr/bin:/bin", environment: ["TMPDIR": marks.path])
        let onlyPlanted = BackupTools(searchPath: planted + ":/usr/bin:/bin", environment: ["TMPDIR": marks.path])
        ToolPaths.withIsolatedSlot {
            #expect(throws: ToolPathsError.notInstalled) { try tools.find("rclone") }
            #expect(tools.rclone == nil)
            #expect(tools.litestream == nil)
        }
        try ToolPaths.withIsolatedSlot { () throws in
            ToolPaths.install(forbiddenRoots: [workspace], path: "/usr/bin:/bin")
            #expect(tools.rclone == safe.appending(path: "rclone").path)
            #expect(tools.litestream == safe.appending(path: "litestream").path)
            #expect(onlyPlanted.rclone == nil)
            #expect(onlyPlanted.litestream == nil)
            #expect(throws: BackupTargetError.invalid("rclone is not installed (it is not on PATH)")) {
                try BackupTargets.validate(.rclone(remote: "secret"), paths: env.paths, tools: onlyPlanted)
            }
            #expect(throws: WALShippingError.unavailable) {
                try WALShipping.restoreFile(paths: env.paths, replica: "/x", timestamp: Date(), tools: onlyPlanted)
            }
            #expect(try BackupTargets.validate(.rclone(remote: "secret"), paths: env.paths, tools: tools) == .rclone(remote: "secret"))
        }
        #expect(!FileManager.default.fileExists(atPath: marks.appending(path: "planted-ran").path), "a planted tool ran")
    }

    @Test func rcloneSyncRunsWithTheExactArguments() throws {
        let env = try BackupEnv()
        _ = try env.service().snapshot(reason: .manual)
        let dir = try tempDir(), log = dir.appending(path: "rclone.log")
        let (_, tools) = try fakeBin(["rclone": """
            if [ "$1" = config ]; then printf '[secret]\\ntype = crypt\\n'; exit 0; fi
            echo "$@" >> "$TMPDIR/rclone.log"
            exit 0
            """], env: ["TMPDIR": dir.path])
        #expect(BackupTargets.sync(.rclone(remote: "secret"), paths: env.paths, hostname: "studio", tools: tools) == .synced(files: 0))
        let line = try String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(line == "sync \(env.paths.backupsDir.path) secret:studio --fast-list")
        #expect(BackupTargets.rcloneTimeout == 6 * 3600)
        // A remote reconfigured to plain storage is not uploaded to.
        let (_, plain) = try fakeBin(["rclone": "if [ \"$1\" = config ]; then printf 'type = s3\\n'; exit 0; fi\necho uploaded >> \"$TMPDIR/rclone.log\"\nexit 0"],
                                     env: ["TMPDIR": dir.path])
        let outcome = BackupTargets.sync(.rclone(remote: "secret"), paths: env.paths, hostname: "studio", tools: plain)
        guard case .failed(let why) = outcome else { Issue.record("expected failure"); return }
        #expect(why.contains("not an rclone crypt remote"))
        #expect(!(try String(contentsOf: log, encoding: .utf8)).contains("uploaded"))
    }

    // MARK: WAL shipping

    @Test func walShippingConfigAndRestorePlan() throws {
        let env = try BackupEnv()
        let url = try WALShipping.config(paths: env.paths, replica: "/Volumes/Drive/brahma wal")
        #expect(url == env.paths.runDir.appending(path: "litestream.yml"))
        let yaml = try String(contentsOf: url, encoding: .utf8)
        #expect(yaml == """
            dbs:
              - path: "\(env.paths.database.path)"
                replicas:
                  - path: "/Volumes/Drive/brahma wal"

            """)
        var st = stat()
        #expect(stat(url.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(try String(contentsOf: WALShipping.config(paths: env.paths, replica: "s3://bucket/brahma"), encoding: .utf8)
            .contains("- url: \"s3://bucket/brahma\""))
        #expect(WALShipping.replicateArguments(paths: env.paths) == ["replicate", "-config", url.path])
        let when = Date(timeIntervalSince1970: 1_781_107_200)
        #expect(WALShipping.restoreArguments(paths: env.paths, timestamp: when) == [
            "restore", "-config", url.path, "-timestamp", "2026-06-10T16:00:00Z",
            "-o", env.paths.home.appending(path: "brahma.sqlite.restoring").path, env.paths.database.path])

        // The restore: litestream rebuilds into brahma.sqlite.restoring, then Task 12's swap puts it in place.
        _ = try env.company("Before")
        let scratch = try tempDir(), rebuilt = scratch.appending(path: "rebuilt.sqlite")
        _ = try env.service().snapshot(reason: .manual)
        let snapshot = try #require(BackupService(paths: env.paths).list().first).url
        try FileManager.default.copyItem(at: snapshot, to: rebuilt)
        let args = scratch.appending(path: "args.log")
        let (_, tools) = try fakeBin(["litestream": """
            echo "$@" > "$TMPDIR/args.log"
            while [ $# -gt 0 ]; do if [ "$1" = -o ]; then cp "$TMPDIR/rebuilt.sqlite" "$2"; fi; shift; done
            """], env: ["TMPDIR": scratch.path])
        let staged = try WALShipping.restoreFile(paths: env.paths, replica: "/Volumes/Drive/wal", timestamp: when, tools: tools)
        #expect(staged == env.paths.home.appending(path: "brahma.sqlite.restoring"))
        #expect(try String(contentsOf: args, encoding: .utf8).contains("-timestamp 2026-06-10T16:00:00Z"))
        try env.store.close()
        let service = BackupService(paths: env.paths)
        let plan = try service.planRestore(snapshot: staged, date: when)
        let outcome = try service.restore(plan)
        #expect(outcome.previousCopy != nil)                                 // the swap is Task 12's: a byte copy of what was there
        #expect(try env.companyNames(in: env.paths.database) == ["Before"])
        #expect(FileManager.default.fileExists(atPath: BackupService.restoreMarker(paths: env.paths).path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))        // renamed over the database
        // Without litestream: unavailable.
        #expect(throws: WALShippingError.unavailable) {
            try WALShipping.restoreFile(paths: env.paths, replica: "/x", timestamp: when, tools: BackupTools(searchPath: "/nonexistent", environment: [:]))
        }
    }

    @Test func shipperRestartedWithBackoff() async throws {
        #expect(ShipperBackoff.initial == .seconds(5) && ShipperBackoff.ceiling == .seconds(300))
        var backoff = ShipperBackoff()
        #expect((0..<9).map { _ in backoff.take() } == [5, 10, 20, 40, 80, 160, 300, 300, 300].map { Duration.seconds($0) })
        backoff.reset()
        #expect(backoff.take() == .seconds(5))

        let env = try BackupEnv()
        let dir = try tempDir(), runs = dir.appending(path: "runs.log")
        let (_, tools) = try fakeBin(["litestream": "echo \"$@\" >> \"$TMPDIR/runs.log\"\nexit 1"], env: ["TMPDIR": dir.path])
        let delays = Delays()
        // A run's length is measured on an injected clock (one awake second per reading): however long a fake launch takes
        // under load, no run counts as healthy (`ShipperBackoff.healthyRun`), so the backoff never resets mid-test.
        let ticks = Ticks()
        let shipper = WALShipper(executable: try #require(tools.litestream), paths: env.paths, tools: tools, sleeper: { d in
            delays.add(d)
            if delays.count >= 4 { throw CancellationError() }
        }, awakeUptime: { ticks.next() })
        shipper.start()
        // The supervisor loop runs real fake-script launches; under full-suite load they can take far longer than a quick
        // deadline, so wait on the condition (4 backoffs seen, which means 4 starts) with a generous awake-time bound.
        let deadline = AwakeTime.deadline(after: .seconds(300))
        while delays.count < 4, AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(20)) }
        shipper.stop()
        #expect(delays.all == [5, 10, 20, 40].map { Duration.seconds($0) })
        #expect(shipper.startCount == 4)
        let lines = try String(contentsOf: runs, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4 && lines.allSatisfy { $0 == "replicate -config \(env.paths.runDir.appending(path: "litestream.yml").path)" })
    }

    @Test func orchestratorSupervisesLitestreamOnlyWhileEnabled() async throws {
        let env = try BackupEnv()
        let dir = try tempDir(), marker = dir.appending(path: "started")
        let (_, tools) = try fakeBin(["litestream": "echo started >> \"$TMPDIR/started\"\nexec sleep 30"], env: ["TMPDIR": dir.path])
        let off = Orchestrator(store: env.store, runner: FakeTurnRunner(), paths: env.paths, mcpExecutable: "/usr/local/bin/brahma",
                               vault: MemoryVault(), backupTools: tools)
        try await off.start()
        #expect(!FileManager.default.fileExists(atPath: marker.path))        // not enabled: not started
        await off.stopWALShipping()
        try env.store.setWALShipping(WALShippingConfig(replica: try folder("wal").path))
        let on = Orchestrator(store: env.store, runner: FakeTurnRunner(), paths: env.paths, mcpExecutable: "/usr/local/bin/brahma",
                              vault: MemoryVault(), backupTools: tools)
        try await on.start()
        let deadline = AwakeTime.deadline(after: .seconds(20))
        while !FileManager.default.fileExists(atPath: marker.path), AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(FileManager.default.fileExists(atPath: WALShipping.configURL(paths: env.paths).path))
        await on.stopWALShipping()
    }

    // MARK: doctor

    @Test func doctorItemsReportShippingAndTargets() throws {
        let env = try BackupEnv()
        let replica = try folder("wal")
        let (_, tools) = try fakeBin(["litestream": "echo v0.3.13"])
        #expect(WALShipping.doctorItem(replica: nil, tools: tools).status == .pass)
        #expect(WALShipping.doctorItem(replica: replica.path, tools: BackupTools(searchPath: "/nonexistent", environment: [:])).status == .warn)
        #expect(WALShipping.doctorItem(replica: replica.path, tools: tools).status == .warn)         // nothing written yet
        let file = replica.appending(path: "generations/0001.wal")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        let fresh = WALShipping.doctorItem(replica: replica.path, tools: tools)
        #expect(fresh.status == .pass && fresh.detail.contains("v0.3.13"))
        let stale = WALShipping.doctorItem(replica: replica.path, tools: tools, now: Date().addingTimeInterval(700))
        #expect(stale.status == .warn && stale.detail.contains("more than 10"))
        #expect(Doctor.backupTargetsItem(targets: []).status == .pass)
        let gone = replica.appending(path: "nope")
        #expect(Doctor.backupTargetsItem(targets: [.folder(path: replica.path)]).status == .pass)
        #expect(Doctor.backupTargetsItem(targets: [.folder(path: gone.path)]).detail.contains("not connected"))
        #expect(Doctor.backupTargetsItem(targets: [.rclone(remote: "x")], tools: BackupTools(searchPath: "/nonexistent", environment: [:])).status == .warn)
        _ = env
    }

    // MARK: CLI

    @Test func cliTargetCommandsAreOwnerOnlyAndPersist() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let drive = try folder()
        let (bin, _) = try fakeBin(["rclone": "if [ \"$1\" = config ]; then printf '[secret]\\ntype = crypt\\n'; exit 0; fi\nexit 0"])
        let extra = ["PATH": bin.path + ":/usr/bin:/bin"]
        let agent = try runBrahma(["backup", "target", "add", "folder", drive.path], home: home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands can't run inside an agent turn"))
        let inside = try runBrahma(["backup", "target", "add", "folder", paths.home.path], home: home.url)
        #expect(inside.status != 0 && inside.stderr.contains("inside"))
        #expect(try runBrahma(["backup", "target", "add", "folder", drive.path], home: home.url).status == 0)
        #expect(try runBrahma(["backup", "target", "add", "rclone", "secret"], home: home.url, extra: extra).status == 0)
        let listed = try runBrahma(["backup", "targets"], home: home.url)
        #expect(listed.stdout.contains("1  folder ") && listed.stdout.contains("2  rclone secret:"))
        #expect(try runBrahma(["backup", "target", "rm", "1"], home: home.url).status == 0)
        #expect(try runBrahma(["backup", "targets"], home: home.url).stdout.hasPrefix("1  rclone secret:"))
        #expect(try runBrahma(["backup", "target", "rm", "7"], home: home.url).status != 0)
        let now = try runBrahma(["backup", "now", "--targets"], home: home.url, extra: extra)
        #expect(now.status == 0 && now.stdout.contains("snapshot:") && now.stdout.contains("rclone secret:: copied"))
    }

    // MARK: Fix round 1 (S3, I1–I3, m4–m7)

    private func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// A fake long-running litestream: it outlives any test under load (a process whose being alive is asserted must not end
    /// by itself mid-test) and the test kills it, yet it still ends by itself after about 10 min, so a crashed test never
    /// leaves a child behind forever.
    static let longLoop = "i=0\nwhile [ $i -lt 6000 ]; do sleep 0.1; i=$((i+1)); done"

    /// The pid a script wrote as one whole line to `file` (`echo $! > file`), or nil while the line is not complete yet.
    static func pidLine(_ file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Waits on `condition`, bounded by a generous awake-time deadline (full-suite load can slow fake launches a lot).
    private func waitUntil(_ seconds: Int = 120, _ condition: () -> Bool) async throws {
        let deadline = AwakeTime.deadline(after: .seconds(seconds))
        while !condition(), AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(20)) }
    }

    /// The pid the shipper recorded in `<home>/run/litestream.pid`.
    private func recordedPID(_ paths: BrahmaPaths) -> Int32? {
        guard let text = try? String(contentsOf: WALShipper.pidFile(paths: paths), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first.flatMap { Int32($0) }
    }

    @Test func walReplicaInsideHomeRefused() throws {
        let env = try BackupEnv()
        let acme = try env.company()
        let workspace = URL(fileURLWithPath: acme.workspacePath)
        let nested = env.paths.home.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = try tempDir().appending(path: "alias-into-home")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        for bad in [nested.path, env.paths.home.path, workspace.path, alias.path, env.root.path, "relative/wal",
                    try folder().appending(path: "missing").path, "file://\(nested.path)",
                    "s3://AKIAEXAMPLE:secretkey@bucket/brahma", "sftp://user:pw@host/brahma", "/tmp/a\tb", "s3://bucket/a\rb"] {
            #expect(throws: WALShippingError.self, "\(bad.debugDescription) should be refused") {
                try WALShipping.validateReplica(bad, paths: env.paths, workspaces: [workspace])
            }
        }
        do {
            _ = try WALShipping.validateReplica("s3://AKIAEXAMPLE:secretkey@bucket/brahma", paths: env.paths)
        } catch { #expect("\(error)".contains("environment") && !"\(error)".contains("secretkey"), "\(error)") }
        let drive = try folder("wal")
        #expect(try WALShipping.validateReplica(drive.path, paths: env.paths) == drive.resolvingSymlinksInPath().path)
        #expect(try WALShipping.validateReplica("s3://bucket/brahma", paths: env.paths) == "s3://bucket/brahma")
        #expect(try WALShipping.validateReplica("sftp://user@host/brahma", paths: env.paths) == "sftp://user@host/brahma")
    }

    @Test func walReplicaProtected() throws {
        let env = try BackupEnv()
        let drive = try folder("wal")
        let alias = try tempDir().appending(path: "wal-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: drive)
        try env.store.setWALShipping(WALShippingConfig(replica: alias.path))
        #expect(BackupTargets.protectedFolders(store: env.store) == [drive.resolvingSymlinksInPath().standardizedFileURL])
        let target = try folder("target")
        try env.store.addBackupTarget(.folder(path: target.path))
        #expect(Set(BackupTargets.protectedFolders(store: env.store).map(\.path))
                == [drive.resolvingSymlinksInPath().path, target.resolvingSymlinksInPath().path])
        try env.store.setWALShipping(WALShippingConfig(replica: "s3://bucket/x"))
        #expect(BackupTargets.protectedFolders(store: env.store).map(\.path) == [target.resolvingSymlinksInPath().path])
    }

    @Test func corruptLitestreamRestoreFallsBackToSnapshot() throws {
        let env = try BackupEnv()
        _ = try env.company("Before")
        _ = try env.service().snapshot(reason: .manual)
        let good = try #require(BackupService(paths: env.paths).list().first).url
        let when = Date(timeIntervalSince1970: 1_781_107_200)
        // The check itself: a real snapshot passes; garbage, an empty database and a newer schema do not.
        try WALShipping.checkRestored(good)
        let garbage = try tempDir().appending(path: "garbage.sqlite")
        try Data("not a database at all".utf8).write(to: garbage)
        #expect(throws: WALShippingError.self) { try WALShipping.checkRestored(garbage) }
        let empty = try tempDir().appending(path: "empty.sqlite")
        try DatabaseQueue(path: empty.path).write { db in try db.execute(sql: "CREATE TABLE unrelated (x)") }
        #expect(throws: WALShippingError.self) { try WALShipping.checkRestored(empty) }
        let future = try tempDir().appending(path: "future.sqlite")
        try FileManager.default.copyItem(at: good, to: future)
        try DatabaseQueue(path: future.path).write { db in try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v9-from-the-future')") }
        #expect(throws: WALShippingError.self) { try WALShipping.checkRestored(future) }

        // litestream "succeeds" but writes garbage: restoreFile refuses it and leaves no staging file behind.
        let (_, tools) = try fakeBin(["litestream": """
            while [ $# -gt 0 ]; do if [ "$1" = -o ]; then printf 'garbage' > "$2"; fi; shift; done
            exit 0
            """])
        do {
            _ = try WALShipping.restoreFile(paths: env.paths, replica: try folder("wal").path, timestamp: when, tools: tools)
            Issue.record("a garbage rebuild was accepted")
        } catch let error as WALShippingError {
            #expect("\(error)".contains("check"), "\(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: WALShipping.stagingURL(paths: env.paths).path))
    }

    @Test func cliRestoreAtFallsBackWhenTheRebuildIsCorrupt() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let start = Date(timeIntervalSince1970: 1_781_107_200)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        try store.setWALShipping(WALShippingConfig(replica: try folder("wal").path))
        var service = BackupService(paths: paths, writer: store.writer)
        service.now = { start }
        let snapshot = try service.snapshot(reason: .manual)
        try store.close()
        let (bin, _) = try fakeBin(["litestream": """
            while [ $# -gt 0 ]; do if [ "$1" = -o ]; then printf 'garbage' > "$2"; fi; shift; done
            exit 0
            """])
        let iso = ISO8601DateFormatter().string(from: start.addingTimeInterval(5))
        let run = try runBrahma(["restore", "--at", iso], home: home.url, extra: ["PATH": bin.path + ":/usr/bin:/bin"])
        #expect(run.status == 0, "\(run.stdout) \(run.stderr)")
        #expect(run.stdout.contains("using the newest snapshot instead"), "\(run.stdout)")
        #expect(run.stdout.contains("restored \(snapshot.lastPathComponent)"), "\(run.stdout)")
        #expect(!FileManager.default.fileExists(atPath: WALShipping.stagingURL(paths: paths).path))
    }

    @Test func dryRunDoesNotRunLitestream() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let start = Date(timeIntervalSince1970: 1_781_107_200)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        try store.setWALShipping(WALShippingConfig(replica: try folder("wal").path))
        var service = BackupService(paths: paths, writer: store.writer)
        service.now = { start }
        _ = try service.snapshot(reason: .manual)
        try store.close()
        let dir = try tempDir(), marker = dir.appending(path: "ran")
        let (bin, _) = try fakeBin(["litestream": "echo ran > \"$TMPDIR/ran\""])
        let iso = ISO8601DateFormatter().string(from: start.addingTimeInterval(5))
        let run = try runBrahma(["restore", "--at", iso, "--dry-run"], home: home.url,
                                extra: ["PATH": bin.path + ":/usr/bin:/bin", "TMPDIR": dir.path])
        #expect(run.status == 0, "\(run.stdout) \(run.stderr)")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: WALShipping.configURL(paths: paths).path))
        #expect(run.stdout.contains("litestream was not run"), "\(run.stdout)")
    }

    @Test func cliWALEnableRefusesHomeAndCredentials() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let (bin, _) = try fakeBin(["litestream": "echo v0.3.13"])
        let extra = ["PATH": bin.path + ":/usr/bin:/bin"]
        try FileManager.default.createDirectory(at: paths.home.appending(path: "wal"), withIntermediateDirectories: true)
        let inside = try runBrahma(["backup", "wal", "enable", paths.home.appending(path: "wal").path], home: home.url, extra: extra)
        #expect(inside.status != 0 && inside.stderr.contains("inside"), "\(inside.stderr)")
        let creds = try runBrahma(["backup", "wal", "enable", "s3://AKIA:topsecret@bucket/x"], home: home.url, extra: extra)
        #expect(creds.status != 0 && creds.stderr.contains("environment") && !creds.stderr.contains("topsecret"), "\(creds.stderr)")
        let drive = try folder("wal")
        let ok = try runBrahma(["backup", "wal", "enable", drive.path], home: home.url, extra: extra)
        #expect(ok.status == 0, "\(ok.stderr)")
        #expect(ok.stdout.contains(drive.resolvingSymlinksInPath().path))
    }

    @Test func mirrorRefusesSymlinkedComponent() throws {
        let env = try BackupEnv()
        _ = try env.service().snapshot(reason: .manual)
        let drive = try folder()
        let valid = try BackupTargets.validate(.folder(path: drive.path), paths: env.paths)
        let outside = try folder("outside")
        try Data("precious".utf8).write(to: outside.appending(path: "precious.txt"))
        // The host directory is a link out of the target.
        try FileManager.default.createSymbolicLink(at: drive.appending(path: "studio"), withDestinationURL: outside)
        let outcome = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        guard case .failed(let why) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(why.contains("symbolic link"), "\(why)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["precious.txt"])
        #expect(try String(contentsOf: outside.appending(path: "precious.txt"), encoding: .utf8) == "precious")
        // A directory inside the mirror is a link out of the target.
        try FileManager.default.removeItem(at: drive.appending(path: "studio"))
        try FileManager.default.createDirectory(at: drive.appending(path: "studio"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: drive.appending(path: "studio/db"), withDestinationURL: outside)
        let again = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        guard case .failed(let deeper) = again else { Issue.record("expected a refusal, got \(again)"); return }
        #expect(deeper.contains("symbolic link"), "\(deeper)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["precious.txt"])
    }

    @Test func staleRemovalStaysInsideTarget() throws {
        let env = try BackupEnv()
        _ = try env.service().snapshot(reason: .manual)
        let drive = try folder()
        let valid = try BackupTargets.validate(.folder(path: drive.path), paths: env.paths)
        guard case .synced = BackupTargets.sync(valid, paths: env.paths, hostname: "studio") else { Issue.record("not synced"); return }
        let outside = try folder("outside")
        try Data("precious".utf8).write(to: outside.appending(path: "precious.txt"))
        let mirror = drive.appending(path: "studio")
        // Stale entries planted in the mirror: a link to an outside directory, and a stale directory holding a link to an
        // outside file and a file of its own.
        try FileManager.default.createSymbolicLink(at: mirror.appending(path: "old-dir"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: mirror.appending(path: "stale-dir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: mirror.appending(path: "stale-dir/link"),
                                                   withDestinationURL: outside.appending(path: "precious.txt"))
        try Data("old".utf8).write(to: mirror.appending(path: "stale-dir/old.bin"))
        guard case .synced = BackupTargets.sync(valid, paths: env.paths, hostname: "studio") else { Issue.record("not synced"); return }
        var st = stat()
        #expect(lstat(mirror.appending(path: "old-dir").path, &st) != 0)
        #expect(lstat(mirror.appending(path: "stale-dir").path, &st) != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["precious.txt"])
        #expect(try String(contentsOf: outside.appending(path: "precious.txt"), encoding: .utf8) == "precious")
    }

    @Test func sameVolumeTargetCopiesNotLinks() throws {
        let env = try BackupEnv()
        let source = try env.service().snapshot(reason: .manual)
        let drive = try folder()                                             // the same volume as the data home
        let valid = try BackupTargets.validate(.folder(path: drive.path), paths: env.paths)
        _ = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        let mirrored = drive.appending(path: "studio/db/\(source.lastPathComponent)")
        #expect(inode(mirrored) != nil && inode(mirrored) != inode(source))
        var st = stat()
        #expect(stat(source.path, &st) == 0 && st.st_nlink == 1)
        #expect(stat(mirrored.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        // A mirror left by the first version (a hard link to the source) is replaced by a copy.
        try FileManager.default.removeItem(at: mirrored)
        #expect(link(source.path, mirrored.path) == 0)
        _ = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        #expect(inode(mirrored) != inode(source))
        #expect(try Data(contentsOf: mirrored) == Data(contentsOf: source))
    }

    @Test func emptiedMountPointOnTheBootVolumeIsSkipped() throws {
        let env = try BackupEnv()
        _ = try env.service().snapshot(reason: .manual)
        let volumes = try folder("Volumes")                                  // stands in for /Volumes, on the home's volume
        let mount = volumes.appending(path: "Drive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let valid = try BackupTargets.validate(.folder(path: mount.path), paths: env.paths)
        guard case .folder(let stored) = valid else { Issue.record("not a folder"); return }
        let outcome = BackupTargets.sync(valid, paths: env.paths, hostname: "studio", volumesRoot: volumes)
        #expect(outcome == .skipped(BackupTargets.notConnectedNotice(stored)))
        #expect(!FileManager.default.fileExists(atPath: mount.appending(path: "studio").path))
    }

    @Test func storedFolderIsRevalidatedAtEachSync() throws {
        let env = try BackupEnv()
        _ = try env.service().snapshot(reason: .manual)
        let drive = try folder()
        let valid = try BackupTargets.validate(.folder(path: drive.path), paths: env.paths)
        let inside = env.paths.home.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        // After it was added, the folder is replaced by a link into the data home.
        try FileManager.default.removeItem(at: drive)
        try FileManager.default.createSymbolicLink(at: drive, withDestinationURL: inside)
        let outcome = BackupTargets.sync(valid, paths: env.paths, hostname: "studio")
        guard case .failed(let why) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(why.contains("re-add"), "\(why)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: inside.path).isEmpty)
    }

    @Test func symlinkIntoHomeTargetRefused() throws {
        let env = try BackupEnv()
        let inside = env.paths.home.appending(path: "nested")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let link = try tempDir().appending(path: "drive-alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        #expect(throws: BackupTargetError.self) { try BackupTargets.validate(.folder(path: link.path), paths: env.paths) }
    }

    @Test func cryptCheckIsSectionAware() throws {
        let env = try BackupEnv()
        let (_, tools) = try fakeBin(["rclone": """
            if [ "$1" = config ] && [ "$2" = show ]; then
              case "$3" in
                plain) printf '[plain]\\ntype = s3\\nprovider = AWS\\n\\n[other]\\ntype = crypt\\nremote = plain:x\\n' ;;
                headerless) printf 'type = crypt\\n' ;;
                secret) printf '[secret]\\ntype = crypt\\nremote = b2:bucket\\n\\n[b2]\\ntype = b2\\n' ;;
              esac
              exit 0
            fi
            exit 9
            """])
        #expect(throws: BackupTargetError.self) { try BackupTargets.validate(.rclone(remote: "plain"), paths: env.paths, tools: tools) }
        #expect(throws: BackupTargetError.self) { try BackupTargets.validate(.rclone(remote: "headerless"), paths: env.paths, tools: tools) }
        #expect(try BackupTargets.validate(.rclone(remote: "secret"), paths: env.paths, tools: tools) == .rclone(remote: "secret"))
    }

    @Test func quotedEscapesEveryControlCharacter() {
        #expect(WALShipping.quoted("a\tb\rc\nd\u{1}e\u{7f}f\"g\\h") == #""a\tb\rc\nd\u0001e\u007Ff\"g\\h""#)
    }

    @Test func litestreamEnvironmentPassesCredentialsOnlyToLitestream() throws {
        let env = try BackupEnv()
        let scratch = try tempDir(), dump = scratch.appending(path: "env.txt")
        let (dir, _) = try fakeBin(["litestream": "env > \"$TMPDIR/env.txt\"\nexit 1"])
        let tools = BackupTools(searchPath: dir.path + ":/usr/bin:/bin", environment: [
            "AWS_ACCESS_KEY_ID": "AKIAEXAMPLE", "AWS_SECRET_ACCESS_KEY": "s3cr3t", "LITESTREAM_ACCESS_KEY_ID": "lsk",
            "SSH_AUTH_SOCK": "/tmp/agent.sock", "RCLONE_CONFIG": "/r.conf", "HOME": "/Users/x", "GITHUB_TOKEN": "ghp_nope",
            "TMPDIR": scratch.path,
        ])
        #expect(tools.environment["AWS_ACCESS_KEY_ID"] == nil && tools.environment["SSH_AUTH_SOCK"] == nil
                && tools.environment["LITESTREAM_ACCESS_KEY_ID"] == nil)
        #expect(tools.environment["RCLONE_CONFIG"] == "/r.conf")
        let lite = tools.litestreamEnvironment
        #expect(lite["AWS_ACCESS_KEY_ID"] == "AKIAEXAMPLE" && lite["AWS_SECRET_ACCESS_KEY"] == "s3cr3t")
        #expect(lite["LITESTREAM_ACCESS_KEY_ID"] == "lsk" && lite["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
        #expect(lite["GITHUB_TOKEN"] == nil)
        _ = try? WALShipping.restoreFile(paths: env.paths, replica: "s3://bucket/x", timestamp: Date(), tools: tools)
        let seen = try String(contentsOf: dump, encoding: .utf8)
        #expect(seen.contains("AWS_ACCESS_KEY_ID=AKIAEXAMPLE") && seen.contains("SSH_AUTH_SOCK=/tmp/agent.sock"))
        #expect(!seen.contains("GITHUB_TOKEN"))
    }

    @Test func litestreamChildDiesOnStop() async throws {
        let env = try BackupEnv()
        let (_, tools) = try fakeBin(["litestream": "exec sleep 600"])     // alive until stopped, however slow the suite runs
        let shipper = WALShipper(executable: try #require(tools.litestream), paths: env.paths, tools: tools)
        shipper.start()
        try await waitUntil { recordedPID(env.paths) != nil }
        let pid = try #require(recordedPID(env.paths))
        #expect(pidAlive(pid))
        var st = stat()
        #expect(stat(WALShipper.pidFile(paths: env.paths).path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        shipper.stop()
        #expect(!pidAlive(pid))
        #expect(!FileManager.default.fileExists(atPath: WALShipper.pidFile(paths: env.paths).path))
    }

    /// The litestream fake starts a grandchild of its own (like litestream's sftp/ssh helpers); stopping the shipper takes the whole
    /// process group down, with TERM first and KILL after the grace for a leader that ignores TERM.
    @Test(arguments: [false, true]) func stopKillsTheProcessGroup(ignoreTerm: Bool) async throws {
        let env = try BackupEnv()
        let childFile = try tempDir().appending(path: "grandchild.pid")
        // The pid line is written after the trap is set: once it reads whole, the trap is in place (no fixed sleep). The
        // grandchild lives until it is killed, however slow the suite runs.
        let body = (ignoreTerm ? "trap '' TERM\n" : "") + "sleep 600 &\necho $! > '\(childFile.path)'\nwait"
        let (_, tools) = try fakeBin(["litestream": body])
        let shipper = WALShipper(executable: try #require(tools.litestream), paths: env.paths, tools: tools, grace: 0.3)
        shipper.start()
        try await waitUntil { recordedPID(env.paths) != nil && Self.pidLine(childFile) != nil }
        let leader = try #require(recordedPID(env.paths))
        let grandchild = try #require(Self.pidLine(childFile))
        defer { if pidAlive(grandchild) { kill(grandchild, SIGKILL) } }
        #expect(pidAlive(leader) && pidAlive(grandchild))
        shipper.stop()
        #expect(!pidAlive(leader))
        try await waitUntil { !pidAlive(grandchild) }
        #expect(!pidAlive(grandchild), "the litestream child outlived the shipper")
    }

    @Test func stopEscalatesToKill() async throws {
        let env = try BackupEnv()
        let dir = try tempDir(), trapped = dir.appending(path: "trapped")
        // The script says when its trap is set (a file event, no fixed sleep): the stop below has to escalate to KILL.
        let (_, tools) = try fakeBin(["litestream": "trap '' TERM\necho $$ > \"$TMPDIR/trapped\"\n" + Self.longLoop], env: ["TMPDIR": dir.path])
        let shipper = WALShipper(executable: try #require(tools.litestream), paths: env.paths, tools: tools, grace: 0.3)
        shipper.start()
        try await waitUntil { recordedPID(env.paths) != nil && Self.pidLine(trapped) != nil }
        let pid = try #require(recordedPID(env.paths))
        #expect(Self.pidLine(trapped) == pid)
        shipper.stop()
        #expect(!pidAlive(pid))
    }

    @Test func stalePidHandled() async throws {
        let env = try BackupEnv()
        // Both children must stay alive until the test itself ends them, however slow the suite runs (a child that ended by
        // itself would make "killed" and "never killed" pass or fail by timing).
        let (_, tools) = try fakeBin(["litestream": Self.longLoop])
        let litestream = try #require(tools.litestream)
        try BrahmaPaths.ensurePrivateDirectory(env.paths.runDir)
        /// The record this engine writes: pid, config, and the leader's start time (`start` nil: the two-line form of older engines).
        func writePID(_ pid: Int32, start: Double?) throws {
            let third = start.map { "\($0)\n" } ?? ""
            try Data("\(pid)\n\(WALShipping.configURL(paths: env.paths).path)\n\(third)".utf8).write(to: WALShipper.pidFile(paths: env.paths))
        }
        // A litestream for this config left behind by a crashed engine, recorded with its start time: killed before a new one
        // starts. Both children are `OutsideChild`ren, watched by pid: Foundation's `Process.isRunning` reported a long-dead
        // child as running here.
        let stale = try OutsideChild(executable: litestream, arguments: WALShipping.replicateArguments(paths: env.paths))
        defer { stale.end() }
        // The scenario needs a stale process that IS litestream for this config by the time the shipper looks: wait on that
        // event (its argv), not on time.
        let config = WALShipping.configURL(paths: env.paths).path
        try await waitUntil { ProcessArguments.of(stale.pid).map { WALShipper.isLitestream($0, config: config) } ?? false }
        try #require(ProcessArguments.of(stale.pid).map { WALShipper.isLitestream($0, config: config) } == true)
        try writePID(stale.pid, start: try #require(ProcessTable.entry(stale.pid)?.start))
        // An unrelated process whose pid sits in the file is never killed.
        let unrelated = try OutsideChild(executable: "/bin/sleep", arguments: ["600"])
        defer { unrelated.end() }

        let first = WALShipper(executable: litestream, paths: env.paths, tools: tools, grace: 0.5)
        first.start()
        try await waitUntil { !stale.isRunning }
        try #require(!stale.isRunning, "the stale litestream was left running")
        #expect(stale.endedBySignal == true, "the stale litestream was stopped, it did not just end")
        try await waitUntil { recordedPID(env.paths).map { $0 != stale.pid } ?? false }
        first.stop()

        // Task 9c fix round 2: a two-line record (no start time) is stale. A live litestream for this config behind it is not
        // signalled (nothing proves this engine started it), the record is removed, no second litestream is started, and the
        // owner is told (`onPaused`). The same for a record whose start time is not that process's.
        let unproven = try OutsideChild(executable: litestream, arguments: WALShipping.replicateArguments(paths: env.paths))
        defer { unproven.end() }
        try await waitUntil { ProcessArguments.of(unproven.pid).map { WALShipper.isLitestream($0, config: config) } ?? false }
        for start in [nil, (try #require(ProcessTable.entry(unproven.pid)?.start)) - 7] as [Double?] {
            try writePID(unproven.pid, start: start)
            let paused = Paused()
            let shipper = WALShipper(executable: litestream, paths: env.paths, tools: tools, grace: 0.5, onPaused: { paused.set($0) })
            shipper.start()
            #expect(paused.reason == .foreign(pid: unproven.pid), "the owner is told which process holds WAL shipping (start \(start.map { "\($0)" } ?? "missing"))")
            #expect(!shipper.isSupervising, "no second litestream was started")
            #expect(unproven.isRunning && pidAlive(unproven.pid), "the unproven litestream was never signalled")
            #expect(!FileManager.default.fileExists(atPath: WALShipper.pidFile(paths: env.paths).path), "the stale record is gone")
            shipper.stop()
        }
        let notice = WALShipper.pausedNotice(.foreign(pid: unproven.pid))
        #expect(notice.title == "WAL shipping paused" && notice.body.contains("pid \(unproven.pid)") && notice.body.contains("relaunch Brahma"))
        #expect(!notice.body.contains("settings"))

        try await waitUntil { ProcessArguments.of(unrelated.pid)?.first == "/bin/sleep" }
        try writePID(unrelated.pid, start: nil)
        let second = WALShipper(executable: litestream, paths: env.paths, tools: tools, grace: 0.5)
        second.start()
        try await waitUntil { recordedPID(env.paths).map { $0 != unrelated.pid } ?? false }
        #expect(unrelated.isRunning && pidAlive(unrelated.pid))
        second.stop()
    }

    /// Task 9c fix round 3: a live litestream for this config that the engine cannot prove it started blocks EVERY launch, not
    /// only the first: two consecutive starts of one shipper and a fresh shipper (a relaunch) all refuse, with no pid file at
    /// all to go by (the process table is read instead), nothing is signalled, and the owner is told each time. Once the foreign
    /// process is gone, a start launches.
    @Test func foreignLitestreamBlocksEveryLaunch() async throws {
        let env = try BackupEnv()
        let (_, tools) = try fakeBin(["litestream": Self.longLoop])
        let litestream = try #require(tools.litestream)
        try BrahmaPaths.ensurePrivateDirectory(env.paths.runDir)
        let config = WALShipping.configURL(paths: env.paths).path
        let foreign = try OutsideChild(executable: litestream, arguments: WALShipping.replicateArguments(paths: env.paths))
        defer { foreign.end() }
        try await waitUntil { ProcessArguments.of(foreign.pid).map { WALShipper.isLitestream($0, config: config) } ?? false }
        #expect(!FileManager.default.fileExists(atPath: WALShipper.pidFile(paths: env.paths).path), "no pid file names it")
        #expect(WALShipper.foreignLitestream(paths: env.paths, excluding: nil) == .foreign(pid: foreign.pid))
        #expect(WALShipper.foreignLitestream(paths: env.paths, excluding: foreign.pid) == nil, "a shipper's own child is not foreign")
        // S4 fix round 1 (I2): a process table that cannot be read rules no foreign litestream out: launching is refused.
        #expect(WALShipper.foreignLitestream(paths: env.paths, excluding: foreign.pid, table: { nil }) == .tableUnreadable)
        let blind = WALShipper.pausedNotice(.tableUnreadable)
        #expect(blind.title == "WAL shipping paused" && blind.body.contains("process table"), "\(blind.body)")

        let paused = Paused()
        let first = WALShipper(executable: litestream, paths: env.paths, tools: tools, grace: 0.5, onPaused: { paused.set($0) })
        first.start()
        first.start()
        #expect(paused.count == 2 && paused.reason == .foreign(pid: foreign.pid))
        #expect(!first.isSupervising && first.startCount == 0, "no second litestream, on either start")
        let relaunched = WALShipper(executable: litestream, paths: env.paths, tools: tools, grace: 0.5, onPaused: { paused.set($0) })
        relaunched.start()
        #expect(paused.count == 3 && !relaunched.isSupervising && relaunched.startCount == 0)
        #expect(foreign.isRunning && pidAlive(foreign.pid), "the foreign litestream was never signalled")
        #expect(recordedPID(env.paths) == nil)
        first.stop(); relaunched.stop()

        foreign.end()
        try await waitUntil { !foreign.isRunning && ProcessArguments.of(foreign.pid) == nil }
        let after = WALShipper(executable: litestream, paths: env.paths, tools: tools, grace: 0.5, onPaused: { paused.set($0) })
        after.start()
        try await waitUntil { recordedPID(env.paths) != nil }
        #expect(after.isSupervising && after.startCount == 1 && paused.count == 3)
        after.stop()
    }

    /// Task 9c fix round 3 (controller ruling): a spawn whose start time cannot be read is stopped at once (it is our own
    /// unreaped child, provably ours), the spawn is retried once, and a second failure pauses shipping with the notice. Both
    /// children are dead, no pid file is left, and nothing else was signalled.
    @Test func unreadableStartStopsOwnChildRetriesOnceThenPauses() async throws {
        let env = try BackupEnv()
        let (_, tools) = try fakeBin(["litestream": Self.longLoop])
        let litestream = try #require(tools.litestream)
        try BrahmaPaths.ensurePrivateDirectory(env.paths.runDir)
        let paused = Paused()
        // The seam sees each spawned pid (the child is killed before its shell could log anything itself) and reads no start.
        let probed = Probed()
        let shipper = WALShipper(executable: litestream, paths: env.paths, tools: tools, grace: 0.5,
                                 onPaused: { paused.set($0) }, startTimeProbe: { pid in probed.add(pid); return nil })
        shipper.start()
        try await waitUntil { paused.count == 1 }
        #expect(paused.reason == .startUnreadable)
        #expect(shipper.startCount == 2, "the spawn was retried once")
        try await waitUntil { !shipper.isSupervising }
        let pids = probed.pids
        #expect(pids.count == 2, "both spawns were probed: \(pids)")
        for pid in pids { #expect(!pidAlive(pid), "pid \(pid) was stopped") }
        #expect(recordedPID(env.paths) == nil, "no record names a child whose start was never proven")
        let notice = WALShipper.pausedNotice(.startUnreadable)
        #expect(notice.title == "WAL shipping paused" && notice.body.contains("Relaunch Brahma"))
        shipper.stop()
    }

    @Test func stopDuringLaunchDoesNotCrash() async throws {
        let env = try BackupEnv()
        let (_, tools) = try fakeBin(["litestream": "exec sleep 30"])
        let box = ShipperBox()
        let shipper = WALShipper(executable: try #require(tools.litestream), paths: env.paths, tools: tools,
                                 launchProbe: { box.value?.stop() })            // a stop that lands in the launch window
        box.value = shipper
        shipper.start()
        try await AwakeTime.sleep(for: .milliseconds(500))
        #expect(shipper.startCount == 0)
        #expect(recordedPID(env.paths) == nil)
        shipper.stop()
    }

    @Test func runForeverEndStopsLitestream() async throws {
        let env = try BackupEnv()
        let (_, tools) = try fakeBin(["litestream": "exec sleep 30"])
        try env.store.setWALShipping(WALShippingConfig(replica: try folder("wal").path))
        let engine = Orchestrator(store: env.store, runner: FakeTurnRunner(), paths: env.paths, mcpExecutable: "/usr/local/bin/brahma",
                                  vault: MemoryVault(), backupTools: tools)
        try await engine.start()
        try await waitUntil { recordedPID(env.paths) != nil }
        let pid = try #require(recordedPID(env.paths))
        let running = Task { await engine.runForever(interval: .milliseconds(50)) }
        try await AwakeTime.sleep(for: .milliseconds(100))
        running.cancel()
        await running.value
        #expect(!pidAlive(pid))
    }
}

private final class ShipperBox: @unchecked Sendable {
    weak var value: WALShipper?
}

/// An awake-seconds clock that moves one second per reading.
private final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    func next() -> TimeInterval { lock.withLock { t += 1; return t } }
}

private final class Delays: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    func add(_ d: Duration) { lock.withLock { values.append(d) } }
    var count: Int { lock.withLock { values.count } }
    var all: [Duration] { lock.withLock { values } }
}

/// The pids a `startTimeProbe` seam was asked about.
private final class Probed: @unchecked Sendable {
    private let lock = NSLock()
    private var _pids: [Int32] = []
    func add(_ pid: Int32) { lock.withLock { _pids.append(pid) } }
    var pids: [Int32] { lock.withLock { _pids } }
}

/// What `WALShipper` reported through `onPaused`.
private final class Paused: @unchecked Sendable {
    private let lock = NSLock()
    private var _reasons: [WALShipper.PauseReason] = []
    func set(_ reason: WALShipper.PauseReason) { lock.withLock { _reasons.append(reason) } }
    var reason: WALShipper.PauseReason? { lock.withLock { _reasons.last } }
    var count: Int { lock.withLock { _reasons.count } }
}
