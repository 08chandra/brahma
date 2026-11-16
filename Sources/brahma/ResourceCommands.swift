import ArgumentParser
import Foundation
import BrahmaCore

/// The owner's resources (Plan ML Task 6c): add files or a folder, add a link, list them, vouch for one, change its scope,
/// purge it. Every verb is owner-only (`requireOwnerShell()`); the secret vault comes from `cliSecretVault(interactive:
/// false)`, the resource vault is the data home's. Names and other text an outside source chose are printed through `safe()`
/// after the redactor (text it could not check is withheld).
struct ResourceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resource",
        abstract: "Add, list, vouch for, rescope and purge a company's resources (owner only).",
        discussion: """
            brahma resource <co> add <path…> [--scope <s>] [--untrusted|--vouch] [--redact|--anyway]   files, or one folder
            brahma resource <co> link <url> [--scope <s>]                                                a link (never fetched)
            brahma resource <co> list                                                                     every resource
            brahma resource <co> vouch F-<n>                                                              clear its taint
            brahma resource <co> scope F-<n> <s>                                                          change who reads it
            brahma resource <co> purge F-<n> --yes                                                        delete its file and search text
            Scopes <s>: company (the default), team:<team>, agent:@<handle>, item:<KEY>.
            """)

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "add <path…>, link <url>, list, vouch F-<n>, scope F-<n> <scope>, or purge F-<n>.") var words: [String] = []
    @Option(help: "With add and link: company, team:<team>, agent:@<handle> or item:<KEY>.") var scope: String?
    @Flag(help: "With add: agents read it as untrusted data.") var untrusted = false
    @Flag(help: "With add: you vouch for it (trusted, whatever its type).") var vouch = false
    @Flag(help: "With add: upload a redacted copy of a file that looks like it holds a secret.") var redact = false
    @Flag(help: "With add: upload it as is, flagged (never a value stored as a secret).") var anyway = false
    @Flag(help: "With purge: yes, delete it.") var yes = false

    enum Action: Equatable {
        case add([String])
        case link(String)
        case list
        case vouch(Int)
        case scope(Int, String)
        case purge(Int)
    }

    /// A scope as typed; resolved against the company in `run`.
    enum ScopeSpec: Equatable {
        case company
        case team(String)
        case agent(String)
        case item(String)
    }

    static func ref(_ text: String) throws -> Int {
        let t = text.uppercased()
        guard t.hasPrefix("F-"), let n = Int(t.dropFirst(2)), n > 0, "F-\(n)" == t else {
            throw ValidationError("expected a resource ref such as F-12")
        }
        return n
    }

    static func scopeSpec(_ text: String) throws -> ScopeSpec {
        if text == "company" { return .company }
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[1].isEmpty {
            switch parts[0] {
            case "team": return .team(parts[1])
            case "agent": return .agent(parts[1].hasPrefix("@") ? String(parts[1].dropFirst()) : parts[1])
            case "item": return .item(parts[1])
            default: break
            }
        }
        throw ValidationError("a scope is company, team:<team>, agent:@<handle> or item:<KEY>")
    }

    static func action(_ words: [String]) throws -> Action {
        switch words.first {
        case "add" where words.count >= 2: return .add(Array(words.dropFirst()))
        case "link" where words.count == 2: return .link(words[1])
        case "list" where words.count == 1: return .list
        case "vouch" where words.count == 2: return .vouch(try ref(words[1]))
        case "scope" where words.count == 3:
            _ = try scopeSpec(words[2])
            return .scope(try ref(words[1]), words[2])
        case "purge" where words.count == 2: return .purge(try ref(words[1]))
        default: break
        }
        throw ValidationError("expected add <path…>, link <url>, list, vouch F-<n>, scope F-<n> <scope> or purge F-<n> --yes")
    }

    func validate() throws {
        let action = try Self.action(words)
        var isAdd = false, isLink = false, isPurge = false
        switch action {
        case .add: isAdd = true
        case .link: isLink = true
        case .purge: isPurge = true
        default: break
        }
        if let scope {
            guard isAdd || isLink else { throw ValidationError("--scope goes only with add and link") }
            _ = try Self.scopeSpec(scope)
        }
        if untrusted || vouch || redact || anyway, !isAdd {
            throw ValidationError("--untrusted, --vouch, --redact and --anyway go only with add")
        }
        if untrusted && vouch { throw ValidationError("choose --untrusted or --vouch, not both") }
        if redact && anyway { throw ValidationError("choose --redact or --anyway, not both") }
        if yes, !isPurge { throw ValidationError("--yes goes only with purge") }
        if isPurge, !yes {
            throw ValidationError("purge deletes the file and its search text for good (backups and transcripts made since it was added still contain it); add --yes")
        }
    }

    func run() throws {
        let action = try Self.action(words)
        try requireOwnerShell()
        let (store, paths) = try openStore()
        let c = try resolveCompany(store, company)
        let contentVault = ContentVault(paths: paths)
        func show(_ text: String) {
            // Fail closed: text the redactor could not check is not printed.
            print(safe(store.redactedForDisplay(text) ?? "[withheld: secrets are not loaded; run `brahma secret load`]"))
        }
        func warn(_ text: String) { FileHandle.standardError.write(Data("brahma: \(safe(text))\n".utf8)) }
        func resolvedScope() throws -> AccessClass {
            try resolve(scope.map(Self.scopeSpec) ?? .company, store: store, company: c)
        }
        do {
            switch action {
            case .add(let files):
                let secretVault = try cliSecretVault(interactive: false)
                let known = try store.knownSecretValues(companyId: c.id, vault: secretVault)
                let urls = files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                let plan = try ResourceIntake.inspect(urls: urls, knownValues: known)
                for refusal in plan.refusals { warn("\(refusal.name): \(refusal.reason)") }
                for skipped in plan.skipped { warn("skipped \(skipped)") }
                guard !plan.items.isEmpty else { throw fail("there is nothing to add") }
                let findings = plan.items.flatMap { item in item.findings.map { (item.displayName, $0) } }
                if !findings.isEmpty, !redact, !anyway {
                    for (name, f) in findings { warn("\(name) looks like it contains a secret (\(f.label), line \(f.line))") }
                    throw fail("add --redact to upload a redacted copy, or --anyway to upload it flagged (never a stored secret's value)")
                }
                let drop = ResourceDrop(context: .cli, scope: try resolvedScope(),
                                        trust: untrusted ? .untrusted : vouch ? .vouched : .asDetected,
                                        secretChoice: redact ? .uploadRedacted : anyway ? .uploadAnyway : .none)
                let rows = try store.addResources(companyId: c.id, plan: plan, drop: drop, contentVault: contentVault,
                                                  secretVault: secretVault, knownValues: known, paths: paths)
                for r in rows { show("added " + line(r, store: store, company: c)) }
            case .link(let url):
                let drop = ResourceDrop(context: .cli, scope: try resolvedScope())
                let r = try store.addLink(companyId: c.id, url: url, drop: drop, contentVault: contentVault)
                show("added " + line(r, store: store, company: c))
            case .list:
                let rows = try store.resources(companyId: c.id, reader: .owner, includePurged: true)
                guard !rows.isEmpty else { print("no resources"); return }
                // A folder counts its live files only (one purged on its own is a tombstone).
                var live: [String: Int] = [:]
                for r in rows where r.parentId != nil && r.purgedAt == nil { live[r.parentId!, default: 0] += 1 }
                for r in rows {
                    show((r.parentId == nil ? "" : "    ") + line(r, store: store, company: c, files: r.kind == .folder ? live[r.id] ?? 0 : nil))
                }
            case .vouch(let n):
                let rows = try store.vouchResource(companyId: c.id, number: n, contentVault: contentVault, paths: paths)
                print("vouched for F-\(n)" + (rows.count > 1 ? " and its \(rows.count - 1) files" : ""))
            case .scope(let n, let text):
                let scope = try resolve(try Self.scopeSpec(text), store: store, company: c)
                try store.setResourceScope(companyId: c.id, number: n, scope: scope, futureHolders: false,
                                           contentVault: contentVault, paths: paths)
                show("F-\(n) is now \(try store.resourceScopeLabel(scope, companyId: c.id))")
            case .purge(let n):
                // Every snapshot that may still hold it: the database's and the data home's (the vault).
                let backups = BackupService(paths: paths).list().map { (name: $0.name, takenAt: $0.date) }
                    + HomeSnapshot.list(paths: paths).map { (name: $0.name, takenAt: $0.date) }
                let report = try store.purgeResource(companyId: c.id, number: n, backups: backups, contentVault: contentVault,
                                                     paths: paths)
                print("purged F-\(n); \(report.backups.count) backups and \(report.transcripts.count) transcripts made since it was added still contain it")
                for name in report.backups { show("  backup \(name) contains purged content · delete or re-create") }
                for turn in report.transcripts { show("  transcript of turn \(turn)") }
            }
        } catch let e as ResourceError {
            throw fail(e.message)
        } catch let e as WorkError {
            throw fail(e.message)
        } catch let e as ExitCode {
            throw e
        } catch {
            throw fail("\(error)")
        }
    }

    private func resolve(_ spec: ScopeSpec, store: Store, company c: Company) throws -> AccessClass {
        switch spec {
        case .company: return .company
        case .team(let t): return .team(t)
        case .agent(let h): return .agent(try resolveAgent(store, company: c, handle: h).id)
        case .item(let key):
            guard let item = try store.workItem(companyId: c.id, key: key.uppercased()) else { throw fail("no work item \(key)") }
            return .item(item.id)
        }
    }

    /// `F-<n> · <kind> · "<name>" [· <k> files] · <size> · <scope> · FROM YOU | EXTERNAL (<why>) [· REDACTED | FLAGGED] [· mirrored <path>]
    /// · added <day> [· purged <day> (<k> backups and <t> transcripts still contain it)]`.
    private func line(_ r: Resource, store: Store, company c: Company, files: Int? = nil) -> String {
        var kind = r.kind.rawValue
        if let fileKind = r.fileKind { kind += " " + fileKind }
        var text = "\(r.ref) · \(kind) · \"\(r.displayName)\""
        if let files { text += " · \(files) files" }
        if r.kind != .link { text += " · \(ResourceText.size(r.bytes))" }
        text += " · " + ((try? store.resourceScopeLabel(r.scope, companyId: c.id)) ?? r.scopeKind)
        text += r.tainted ? " · EXTERNAL (\(r.taintReason ?? "outside content"))" : " · FROM YOU"
        switch r.secretScan {
        case .redacted: text += " · REDACTED"
        case .flagged: text += " · FLAGGED"
        case .none: break
        }
        if let mirror = r.mirrorPath { text += " · mirrored \(mirror)" }
        text += " · added \(day(r.createdAt))"
        if let purged = r.purgedAt {
            text += " · purged \(day(purged))"
            if let raw = r.purgeReport, let report = try? JSONDecoder().decode(PurgeReport.self, from: Data(raw.utf8)) {
                text += " (\(report.backups.count) backups and \(report.transcripts.count) transcripts still contain it)"
            }
        }
        return text
    }

    private func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cliTimeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
