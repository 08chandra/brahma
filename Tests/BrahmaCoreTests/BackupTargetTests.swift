import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite struct BackupTargetTests {
    /// A directory of fake executables (shell scripts) used as the tools' search path.
    private func fakeBin(_ scripts: [String: String]) throws -> (dir: URL, tools: BackupTools) {
        let dir = try tempDir().appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in scripts {
            let url = dir.appending(path: name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            chmod(url.path, 0o755)
        }
        return (dir, BackupTools(searchPath: dir.path + ":/usr/bin:/bin", environment: [:]))
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
        #expect(inode(mirrored) == inode(first))                    // a hard link, not a second copy
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

    @Test func rcloneSyncRunsWithTheExactArguments() throws {
        let env = try BackupEnv()
        _ = try env.service().snapshot(reason: .manual)
        let log = try tempDir().appending(path: "rclone.log")
        let (_, tools) = try fakeBin(["rclone": """
            if [ "$1" = config ]; then printf 'type = crypt\\n'; exit 0; fi
            echo "$@" >> "\(log.path)"
            exit 0
            """])
        #expect(BackupTargets.sync(.rclone(remote: "secret"), paths: env.paths, hostname: "studio", tools: tools) == .synced(files: 0))
        let line = try String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(line == "sync \(env.paths.backupsDir.path) secret:studio --fast-list")
        #expect(BackupTargets.rcloneTimeout == 6 * 3600)
        // A remote reconfigured to plain storage is not uploaded to.
        let (_, plain) = try fakeBin(["rclone": "if [ \"$1\" = config ]; then printf 'type = s3\\n'; exit 0; fi\necho uploaded >> \"\(log.path)\"\nexit 0"])
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
        let rebuilt = try tempDir().appending(path: "rebuilt.sqlite")
        _ = try env.service().snapshot(reason: .manual)
        let snapshot = try #require(BackupService(paths: env.paths).list().first).url
        try FileManager.default.copyItem(at: snapshot, to: rebuilt)
        let args = try tempDir().appending(path: "args.log")
        let (_, tools) = try fakeBin(["litestream": """
            echo "$@" > "\(args.path)"
            while [ $# -gt 0 ]; do if [ "$1" = -o ]; then cp "\(rebuilt.path)" "$2"; fi; shift; done
            """])
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
        let runs = try tempDir().appending(path: "runs.log")
        let (_, tools) = try fakeBin(["litestream": "echo \"$@\" >> \"\(runs.path)\"\nexit 1"])
        let delays = Delays()
        let shipper = WALShipper(executable: try #require(tools.litestream), paths: env.paths, tools: tools, sleeper: { d in
            delays.add(d)
            if delays.count >= 4 { throw CancellationError() }
        })
        shipper.start()
        let deadline = AwakeTime.deadline(after: .seconds(20))
        while delays.count < 4, AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(20)) }
        shipper.stop()
        #expect(delays.all == [5, 10, 20, 40].map { Duration.seconds($0) })
        #expect(shipper.startCount == 4)
        let lines = try String(contentsOf: runs, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4 && lines.allSatisfy { $0 == "replicate -config \(env.paths.runDir.appending(path: "litestream.yml").path)" })
    }

    @Test func orchestratorSupervisesLitestreamOnlyWhileEnabled() async throws {
        let env = try BackupEnv()
        let marker = try tempDir().appending(path: "started")
        let (_, tools) = try fakeBin(["litestream": "echo started >> \"\(marker.path)\"\nexec sleep 30"])
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
        let (bin, _) = try fakeBin(["rclone": "if [ \"$1\" = config ]; then printf 'type = crypt\\n'; exit 0; fi\nexit 0"])
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
}

private final class Delays: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    func add(_ d: Duration) { lock.withLock { values.append(d) } }
    var count: Int { lock.withLock { values.count } }
    var all: [Duration] { lock.withLock { values } }
}
