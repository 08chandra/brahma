import ArgumentParser
import Foundation
import BrahmaCore

/// The owner's handbook commands (Plan ML): list pages, show one (or an old revision), export the handbook as Markdown, roll a
/// page back, vouch for it, set its status. Every verb is owner-only (`requireOwnerShell()`); agent text is printed through
/// `safe()` after the redactor (loaded non-interactively; text it could not check is withheld).
struct KBCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kb",
        abstract: "List, show, export, roll back, vouch for and set the status of handbook pages (owner only).",
        discussion: """
            brahma kb <co> list                                   every page
            brahma kb <co> show <path> [--rev n]                  a page as the owner sees it, or an old revision
            brahma kb <co> export --to <dir> [--force]            the handbook as Markdown files (an empty folder)
            brahma kb <co> rollback <path> --to <n>               restore revision n as a new revision
            brahma kb <co> vouch <path>                           clear a page's taint
            brahma kb <co> status <path> draft|active|deprecated  set a page's status
            """)

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "list, show <path>, export, rollback <path>, vouch <path>, or status <path> <status>.") var words: [String] = []
    @Option(help: "With show: the revision to show.") var rev: Int?
    @Option(name: .customLong("to"), help: "With export: the folder. With rollback: the revision to restore.") var to: String?
    @Flag(help: "With export: empty a non-empty folder first.") var force = false

    enum Action: Equatable {
        case list
        case show(String)
        case export(String)
        case rollback(String, Int)
        case vouch(String)
        case status(String, KBStatus)
    }

    static func action(_ words: [String], to: String?) throws -> Action {
        switch words.first {
        case "list" where words.count == 1: return .list
        case "show" where words.count == 2: return .show(words[1])
        case "export" where words.count == 1:
            guard let to, !to.isEmpty else { throw ValidationError("export needs --to <dir>") }
            return .export(to)
        case "rollback" where words.count == 2:
            guard let to, let n = Int(to), n > 0 else { throw ValidationError("rollback needs --to <revision number>") }
            return .rollback(words[1], n)
        case "vouch" where words.count == 2: return .vouch(words[1])
        case "status" where words.count == 3:
            guard let status = KBStatus(rawValue: words[2]) else { throw ValidationError("status is draft, active or deprecated") }
            return .status(words[1], status)
        default: break
        }
        throw ValidationError("expected list, show <path>, export --to <dir>, rollback <path> --to <n>, vouch <path> or status <path> draft|active|deprecated")
    }

    func validate() throws {
        let action = try Self.action(words, to: to)
        if rev != nil, case .show = action {} else if rev != nil { throw ValidationError("--rev goes only with show") }
        if force, case .export = action {} else if force { throw ValidationError("--force goes only with export") }
        switch action {
        case .export, .rollback: break
        default: if to != nil { throw ValidationError("--to goes only with export and rollback") }
        }
    }

    func run() throws {
        let action = try Self.action(words, to: to)
        let owner = try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        func show(_ text: String) {
            // Fail closed: text the redactor could not check is not printed.
            print(safe(store.redactedForDisplay(text) ?? "[withheld: secrets are not loaded; run `brahma secret load`]"))
        }
        do {
            switch action {
            case .list:
                let pages = try store.kbPages(companyId: c.id, reader: .owner)
                guard !pages.isEmpty else { print("no handbook pages"); return }
                let handles = Dictionary(try store.agents(companyId: c.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                for p in pages {
                    var line = "kb:\(p.path) · \(p.title) · \(p.status.rawValue) · rev \(p.revision) · \(who(p.ownerId, handles)) · \(day(p.updatedAt))"
                    if p.isAuto { line += " · auto" }
                    if p.tainted { line += " · tainted" }
                    show(line)
                }
            case .show(let path):
                guard let view = try store.kbRead(companyId: c.id, reader: .owner, path: path, revision: rev) else {
                    throw fail(safe("no handbook page \(path)"))
                }
                var head = "kb:\(view.page.path) · \(view.page.title) · \(view.page.status.rawValue) · rev \(view.revision) of \(view.page.revision) · \(day(view.revisionDate))"
                if view.page.autoKind != nil { head += " · auto" }
                if view.tainted { head += " · tainted (\(view.taintReason ?? "outside content"))" }
                show(head)
                print("")
                for line in view.text.components(separatedBy: "\n") { show(line) }
            case .export(let dir):
                let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                let n = try HandbookExporter.export(store: store, companyId: c.id, to: url, force: force)
                print(safe("exported \(n) file\(n == 1 ? "" : "s") to \(url.path)"))
            case .rollback(let path, let n):
                let r = try store.kbRollback(companyId: c.id, path: path, to: n)
                print(safe("rolled kb:\(r.page.path) back to rev \(n) (now rev \(r.revision))"))
            case .vouch(let path):
                try store.kbVouch(companyId: c.id, path: path, owner: owner)
                print(safe("vouched for kb:\(try HandbookPath.normalize(path))"))
            case .status(let path, let status):
                try store.kbSetStatus(companyId: c.id, path: path, status: status)
                print(safe("kb:\(try HandbookPath.normalize(path)) is \(status.rawValue)"))
            }
        } catch let e as WorkError {
            throw fail(safe(e.message))
        } catch let e as ExitCode {
            throw e
        } catch {
            throw fail(safe("\(error)"))
        }
    }

    private func who(_ id: String, _ handles: [String: String]) -> String {
        id == "owner" ? "owner" : id == "system" ? "engine" : "@" + (handles[id] ?? "unknown")
    }

    private func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cliTimeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
