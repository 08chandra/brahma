import ArgumentParser
import Foundation
import BrahmaCore

/// A company's merge queue (Plan 4a Task 2). `list` (the default) is read-only; `settings` with options, `retry` and `resume` are
/// owner-write commands (`requireOwnerShell`). Only the engine (`MergeQueue`) ever claims, checks or lands a request: these
/// commands record the owner's settings and requests. Every agent-controlled field (the main check command, an item's key, a
/// request's detail, an agent's name) and the hold's reason print through `safe()`.
struct MergeGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge", abstract: "A company's merge queue: list it, change its settings, retry a failed merge, resume a held queue.",
        subcommands: [List.self, Settings.self, Retry.self, Resume.self, AdoptMain.self], defaultSubcommand: List.self)

    /// `main <sha7> · batch <n> · <strategy title> · main check: <cmd|none>[ · HELD: <reason>]`.
    static func header(_ c: Company) -> String {
        var parts = ["main \(c.mainCommit.map { String($0.prefix(7)) } ?? "-")", "batch \(c.mergeBatchSize)", c.mergeStrategy.title,
                     "main check: \(c.mainCheck?.command ?? "none")"]
        if let hold = c.mergeHold { parts.append("HELD: \(hold)") }
        return safe(parts.joined(separator: " · "))
    }

    /// `M-<n>  <KEY>  <status>  @<owner>  <detail|sha7>`.
    static func line(_ r: MergeRequest, item: WorkItem?, names: [String: String]) -> String {
        let owner = item?.ownerId.flatMap { names[$0] }.map { "@\($0)" } ?? "-"
        let detail: String
        switch r.status {
        case .bounced, .failed: detail = String((r.detail ?? r.failure?.rawValue ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
        case .merged: detail = String((r.mergedCommit ?? r.headCommit).prefix(7))
        default: detail = String(r.headCommit.prefix(7))
        }
        return safe(["\(r.ref)", item?.key ?? "-", r.status.rawValue, owner, detail].joined(separator: "  "))
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The queue: the settings line, then each merge request, oldest first.")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            print(MergeGroup.header(c))
            let names = Dictionary(try store.agents(companyId: c.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let requests = try store.mergeRequests(companyId: c.id)
            // The open ones and the latest few that finished.
            let open = requests.filter { $0.status.isOpen }
            let recent = requests.filter { !$0.status.isOpen }.suffix(20)
            for r in (Array(recent) + open).sorted(by: { $0.number < $1.number }) {
                print(MergeGroup.line(r, item: try store.workItem(id: r.itemId), names: names))
            }
        }
    }

    struct Settings: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the merge settings, or change them (owner only): batch size, strategy, the main check.")
        @Argument(help: "Company name or slug.") var company: String
        @Option(help: "How many approved items are merged and checked together (1 to 8).") var batch: Int?
        @Option(help: "ff (rebase and fast-forward) or merge (rebase, then a merge commit).") var strategy: String?
        @Option(name: .customLong("main-check"), help: "The command every merge candidate must pass before it lands.") var mainCheck: String?
        @Option(name: .customLong("main-timeout"), help: "Seconds the main check may run (1 to 3600; 600 by default).") var mainTimeout: Int?
        @Flag(name: .customLong("clear-main-check"), help: "Remove the main check.") var clearMainCheck = false

        func run() throws {
            let changing = batch != nil || strategy != nil || mainCheck != nil || mainTimeout != nil || clearMainCheck
            if changing { try requireOwnerShell() }
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            guard changing else {
                print(MergeGroup.header(c))
                print("strategy: \(c.mergeStrategy.rawValue)")
                if let check = c.mainCheck { print(safe("main check timeout: \(check.timeoutSeconds) s")) }
                return
            }
            if clearMainCheck, mainCheck != nil || mainTimeout != nil { throw fail("--clear-main-check cannot be combined with --main-check or --main-timeout") }
            var settings = try store.mergeSettings(companyId: c.id)
            if let batch { settings.batchSize = batch }
            if let strategy {
                guard let value = MergeStrategy(rawValue: strategy.lowercased()) else { throw fail("the strategy must be ff or merge") }
                settings.strategy = value
            }
            if clearMainCheck {
                settings.mainCheck = nil
            } else if let mainCheck {
                settings.mainCheck = CheckSpec(command: mainCheck, timeoutSeconds: mainTimeout ?? 600)
            } else if let mainTimeout {
                guard var check = settings.mainCheck else { throw fail("there is no main check to give a timeout; set one with --main-check") }
                check.timeoutSeconds = mainTimeout
                settings.mainCheck = check
            }
            do { try store.setMergeSettings(companyId: c.id, settings, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            guard let fresh = try store.company(id: c.id) else { return }
            print(MergeGroup.header(fresh))
        }
    }

    struct Retry: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Put a failed merge back in the queue (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The merge request (M-3) or its item's key (ACME-12).") var request: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            guard let r = try store.mergeRequest(companyId: c.id, ref: request) else { throw fail("no merge request \(request)") }
            do { try store.requestMergeRetry(requestId: r.id, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            let fresh = try store.latestMergeRequest(itemId: r.itemId)
            print(safe("\(r.ref) is back in the queue as \(fresh?.ref ?? "a new request"); the engine merges it next."))
            // `M-2 queued` for scripts: the new request's ref and status on one line.
            if let fresh { print(safe("\(fresh.ref) \(fresh.status.rawValue)")) }
        }
    }

    struct AdoptMain: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "adopt-main",
            abstract: "Make main as it stands the engine's record (owner only), or move main to a tip the main guard saved (refs/brahma/foreign/...) and record that.")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "A commit, or a ref the main guard saved (refs/brahma/foreign/<yyyyMMdd-HHmmss>-<n>). Without it, main's current head.") var commit: String?

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let adopted: String
            do { adopted = try store.adoptMain(companyId: c.id, by: .owner, commit: commit) } catch let e as WorkError { throw fail(e.message) }
            print(safe("\(c.name): main adopted at \(adopted.prefix(7))"))
        }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Release a held merge queue (owner only).")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let changed: Bool
            do { changed = try store.resumeMergeQueue(companyId: c.id, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            guard changed else { print("The merge queue is not held."); return }
            print("Merge queue resumed.")
        }
    }
}
