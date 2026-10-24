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
        commandName: "backup", abstract: "Database snapshots (owner only).", subcommands: [Now.self, List.self])

    struct Now: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take a verified snapshot of the database now.")
        func run() throws {
            try requireOwnerShell()
            let (store, paths) = try openStore()
            do {
                let url = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .manual)
                print(safe("snapshot: \(url.path)"))
            } catch { throw fail("backup failed: \(error)") }
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
        if latest {
            guard let info = service.latestGood() else { throw fail("no snapshot passes its integrity check (see: brahma restore --list)") }
            snapshot = info.url
        } else if let at, let when = parseISO8601(at) {
            guard let info = service.snapshot(atOrBefore: when) else {
                throw fail("no snapshot at or before \(stamp(when)) passes its integrity check (see: brahma restore --list)")
            }
            snapshot = info.url
        } else {
            snapshot = URL(fileURLWithPath: path ?? "")
        }
        let plan: RestorePlan
        do { plan = try service.planRestore(snapshot: snapshot) } catch { throw fail("\(error)") }
        for warning in plan.warnings { print(safe("warning: \(warning)")) }
        if withFiles && plan.homeSnapshot == nil {
            throw fail("there is no data-home snapshot at or before \(plan.snapshotDate.map(stamp) ?? "that snapshot"); nothing was changed "
                + "(restore without --with-files to bring back the database only)")
        }
        if dryRun {
            let when = plan.snapshotDate.map { " taken \(stamp($0))" } ?? ""
            print(safe("dry run: would restore \(snapshot.lastPathComponent)\(when); nothing was changed"))
            if withFiles, let home = plan.homeSnapshot {
                print(safe("dry run: would also put the files back from \(home.url.lastPathComponent) (\(stamp(home.date)))"))
            }
            return
        }
        do {
            let outcome = try service.restore(plan, withFiles: withFiles)
            for warning in outcome.warnings { print(safe("warning: \(warning)")) }
            if let previous = outcome.previousCopy { print(safe("previous database kept: \(previous.path)")) }
            if let kept = outcome.filesPreRestore {
                print(safe("\(outcome.filesRestored) files restored; what they replaced is kept in \(kept.path)"))
            }
            print(safe("restored \(snapshot.lastPathComponent); Brahma re-adopts the repositories when it next starts"))
        } catch { throw fail("\(error)") }
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
            print(safe("\(c.name): exported to \(result.directory.path)"))
        } catch { throw fail("export failed: \(error)") }
    }
}
