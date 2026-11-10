import ArgumentParser
import Foundation
import BrahmaCore

private func stamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = cliTimeZone
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: date)
}

struct BackupGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup", abstract: "Database snapshots and off-machine backup targets (owner only).",
        subcommands: [Now.self, List.self, Target.self, Targets.self, WAL.self])

    struct Now: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take a verified snapshot of the database now.")
        @Flag(help: "Then copy the backups to every off-machine target.") var targets = false
        func run() throws {
            try requireOwnerShell()
            let (store, paths) = try openStore()
            do {
                let url = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
                print(safe("snapshot: \(url.path)"))
            } catch { throw fail("backup failed: \(error)") }
            if targets { try syncTargets(store: store, paths: paths) }
        }
    }

    struct Target: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add or remove an off-machine backup target.", subcommands: [Add.self, Remove.self])

        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a target: an external folder, or an rclone crypt remote.", subcommands: [Folder.self, Rclone.self])

            struct Folder: ParsableCommand {
                static let configuration = CommandConfiguration(
                    commandName: "folder", abstract: "Mirror the backups to a folder (an external drive) under <path>/<hostname>/.")
                @Argument(help: "An existing, writable folder outside Brahma's data and workspaces.") var path: String
                func run() throws { try add(.folder(path: path)) }
            }

            struct Rclone: ParsableCommand {
                static let configuration = CommandConfiguration(
                    commandName: "rclone", abstract: "Upload the backups through an rclone remote of type crypt.")
                @Argument(help: "The remote's name, as in 'rclone config'.") var remote: String
                func run() throws { try add(.rclone(remote: remote)) }
            }
        }

        struct Remove: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove target <n> (see: brahma backup targets).")
            @Argument var n: Int
            func run() throws {
                try requireOwnerShell()
                let (store, _) = try openStore()
                do { print(safe("removed: \(try store.removeBackupTarget(number: n).summary)")) } catch { throw fail("\(error)") }
            }
        }

        private static func add(_ target: BackupTarget) throws {
            try requireOwnerShell()
            let (store, paths) = try openStore()
            do {
                let workspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: true) }
                let valid = try BackupTargets.validate(target, paths: paths, workspaces: workspaces)
                try store.addBackupTarget(valid)
                print(safe("added: \(valid.summary)"))
            } catch { throw fail("\(error)") }
        }
    }

    struct Targets: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the off-machine backup targets.")
        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let list = try store.backupTargets()
            if list.isEmpty { print("no targets (see: brahma backup target add)"); return }
            for (i, target) in list.enumerated() { print(safe("\(i + 1)  \(target.summary)")) }
        }
    }

    struct WAL: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wal", abstract: "Optional Litestream WAL shipping (litestream must be installed). Takes effect when the engine next starts.",
            subcommands: [Enable.self, Disable.self])

        struct Enable: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "enable", abstract: "Ship the write-ahead log to a replica.")
            @Argument(help: "A folder outside Brahma's data and workspaces, or a URL litestream understands (s3://bucket/path). Credentials go in the environment (AWS_*, LITESTREAM_*, SSH_AUTH_SOCK), never in the URL.") var replica: String
            func run() throws {
                try requireOwnerShell()
                let (store, paths) = try openStore()
                guard BackupTools.system.litestream != nil else { throw fail("\(WALShippingError.unavailable)") }
                // A folder replica gets a folder target's checks; a URL may not carry credentials (they stay in the environment).
                let target: String
                do {
                    let workspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: true) }
                    target = try WALShipping.validateReplica(replica, paths: paths, workspaces: workspaces)
                } catch { throw fail("\(error)") }
                try store.setWALShipping(WALShippingConfig(replica: target))
                print(safe("WAL shipping on: \(target) (restart Brahma to begin)"))
            }
        }

        struct Disable: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "disable", abstract: "Stop shipping the write-ahead log.")
            func run() throws {
                try requireOwnerShell()
                let (store, _) = try openStore()
                try store.setWALShipping(nil)
                print("WAL shipping off (restart Brahma to stop it)")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the snapshots, newest first.")
        func run() throws {
            try requireOwnerShell()
            let paths = BrahmaPaths.fromEnvironment()
            printSnapshots(BackupService(paths: paths).list())
        }
    }
}

private func syncTargets(store: Store, paths: BrahmaPaths) throws {
    let results: [TargetResult]
    do { results = try BackupTargets.syncAll(store: store, paths: paths) } catch { throw fail("target backup failed: \(error)") }
    if results.isEmpty { print("no targets (see: brahma backup target add)"); return }
    var failed = false
    for result in results {
        switch result.outcome {
        case .synced(let files): print(safe("\(result.target.summary): copied (\(files) files)"))
        case .skipped(let why): print(safe("\(result.target.summary): skipped, \(why)"))
        case .unavailable(let why): failed = true; print(safe("\(result.target.summary): unavailable, \(why)"))
        case .failed(let why): failed = true; print(safe("\(result.target.summary): FAILED, \(why)"))
        }
    }
    if failed { throw ExitCode.failure }
}

private func printSnapshots(_ list: [BackupInfo]) {
    if list.isEmpty { print("no snapshots"); return }
    for info in list { print(safe("\(stamp(info.date))  \(info.reason.rawValue)  \(info.url.path)")) }
}

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore the database from a snapshot (owner only). Quit the app and 'brahma run' first.",
        discussion: "The current database is kept next to it as brahma.sqlite.pre-restore-<time>. Git repositories are never touched; "
            + "when Brahma starts it re-adopts each main the snapshot recorded. Commits made after the snapshot are kept, but Brahma "
            + "alerts you and holds that company until you review main and accept it (brahma main accept).")

    @Flag(help: "List the snapshots instead.") var list = false
    @Flag(help: "Restore the newest snapshot that passes its integrity check.") var latest = false
    @Option(help: "Restore the newest snapshot taken at or before this time (ISO-8601, e.g. 2026-06-10T14:30:00Z).") var at: String?
    @Flag(name: .customLong("with-files"), help: "Also put the data home's files (archives, transcripts, role cards) back, from the newest data-home snapshot at or before the database snapshot.") var withFiles = false
    @Flag(name: .customLong("dry-run"), help: "Check the snapshot and show what would happen; change nothing.") var dryRun = false
    @Argument(help: "The snapshot file to restore.") var path: String?

    func validate() throws {
        if list { return }
        let chosen = [latest, path != nil, at != nil].filter { $0 }.count
        guard chosen == 1 else { throw ValidationError("give one of a snapshot path, --latest or --at <time> (see: brahma restore --list)") }
        if let at, parseISO8601(at) == nil { throw ValidationError("--at wants an ISO-8601 time such as 2026-06-10T14:30:00Z, not '\(at)'") }
    }

    func run() throws {
        try requireOwnerShell()
        let paths = BrahmaPaths.fromEnvironment()
        let service = BackupService(paths: paths)
        if list { printSnapshots(service.list()); return }
        let snapshot: URL
        var walDate: Date?
        if latest {
            guard let info = service.latestGood() else { throw fail("no snapshot passes its integrity check (see: brahma restore --list)") }
            snapshot = info.url
        } else if let at, let when = parseISO8601(at) {
            if let walFile = walRestore(paths: paths, at: when, dryRun: dryRun) {
                snapshot = walFile
                walDate = when
            } else {
                guard let info = service.snapshot(atOrBefore: when) else {
                    throw fail("no snapshot at or before \(stamp(when)) passes its integrity check (see: brahma restore --list)")
                }
                snapshot = info.url
            }
        } else {
            snapshot = URL(fileURLWithPath: path ?? "")
        }
        let plan: RestorePlan
        do { plan = try service.planRestore(snapshot: snapshot, date: walDate) } catch {
            if walDate != nil { try? FileManager.default.removeItem(at: snapshot) }
            throw fail("\(error)")
        }
        for warning in plan.warnings { print(safe("warning: \(warning)")) }
        if withFiles && plan.homeSnapshot == nil {
            throw fail("there is no data-home snapshot at or before \(plan.snapshotDate.map(stamp) ?? "that snapshot"); nothing was changed "
                + "(restore without --with-files to bring back the database only)")
        }
        if dryRun {
            if walDate != nil { try? FileManager.default.removeItem(at: snapshot) }
            let when = plan.snapshotDate.map { " taken \(stamp($0))" } ?? ""
            print(safe("dry run: would restore \(snapshot.lastPathComponent)\(when); nothing was changed"))
            if withFiles, let home = plan.homeSnapshot {
                print(safe("dry run: would also put the files back from \(homeSnapshotText(home, databaseDate: plan.snapshotDate))"))
            }
            return
        }
        do {
            let outcome = try service.restore(plan, withFiles: withFiles)
            for warning in outcome.warnings { print(safe("warning: \(warning)")) }
            if let previous = outcome.previousCopy { print(safe("previous database kept: \(previous.path)")) }
            if let home = outcome.filesSnapshot {
                print(safe("files from \(homeSnapshotText(home, databaseDate: plan.snapshotDate)): \(outcome.filesRestored) restored"))
            }
            for entry in outcome.filesRefused { print(safe("warning: not restored: \(entry)")) }
            if let kept = outcome.filesPreRestore {
                print(safe("what the files replaced is kept in \(kept.path)"))
            }
            print(safe("restored \(snapshot.lastPathComponent); Brahma starts stopped: check grants and lab marks "
                + "(the machine-wide lab mark is set), then 'brahma resume'; it re-adopts the repositories after the resume"))
        } catch { throw fail("\(error)") }
    }
}

/// `home-<stamp> (taken <time>, 5h 7m before the database snapshot)`: which data-home snapshot a `--with-files` restore uses
/// and how much older than the database snapshot it is (it is the newest one at or before it, so it may be up to a day older).
private func homeSnapshotText(_ home: HomeSnapshotInfo, databaseDate: Date?) -> String {
    var text = "\(home.name) (taken \(stamp(home.date))"
    if let databaseDate {
        let gap = max(0, Int(databaseDate.timeIntervalSince(home.date)))
        let age: String
        switch gap {
        case ..<60: age = "\(gap)s"
        case ..<3600: age = "\(gap / 60)m"
        case ..<86_400: age = "\(gap / 3600)h \(gap % 3600 / 60)m"
        default: age = "\(gap / 86_400)d \(gap % 86_400 / 3600)h"
        }
        text += ", \(age) before the database snapshot"
    }
    return text + ")"
}

/// With WAL shipping on, a point-in-time restore is rebuilt by litestream into `<home>/brahma.sqlite.restoring` and then swapped in
/// by the ordinary restore. Nil when WAL shipping is off or litestream cannot produce the file (the snapshots are used instead,
/// with a warning when it was on).
///
/// A dry run runs nothing and writes nothing (no litestream, no `litestream.yml`): it says what a real restore would try first.
private func walRestore(paths: BrahmaPaths, at when: Date, dryRun: Bool) -> URL? {
    guard let replica = WALShipping.configuredReplica(paths: paths) else { return nil }
    if dryRun {
        print(safe("dry run: WAL shipping is on, so a real restore first has litestream rebuild \(stamp(when)) from \(replica) "
            + "(checked before it is used) and falls back to the snapshot below if that fails; litestream was not run"))
        return nil
    }
    do {
        return try WALShipping.restoreFile(paths: paths, replica: replica, timestamp: when)
    } catch {
        print(safe("warning: \(error); using the newest snapshot instead"))
        return nil
    }
}

/// ISO-8601 with or without fractional seconds.
private func parseISO8601(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return plain.date(from: text) ?? fractional.date(from: text)
}

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export one company (its rows, repository bundle, files and roles) to a new directory (owner only).")
    @Argument var company: String
    @Option(help: "The directory to create.") var to: String
    @Flag(name: .customLong("no-workspace"), help: "Leave the repository bundle out.") var noWorkspace = false

    func run() throws {
        try requireOwnerShell()
        let (store, paths) = try openStore()
        let c = try resolveCompany(store, company)
        do {
            let result = try CompanyExporter.export(store: store, paths: paths, company: c, to: URL(fileURLWithPath: to),
                                                    includeWorkspace: !noWorkspace)
            for entry in result.skipped { print(safe("warning: not exported: \(entry)")) }
            print(safe("\(c.name): exported to \(result.directory.path)"))
        } catch { throw fail("export failed: \(error)") }
    }
}
