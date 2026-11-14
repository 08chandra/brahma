import ArgumentParser
import Foundation
import BrahmaCore

/// Owner-side company memory (Plan ML): search it as the owner or as an agent, list entries, delete one, and hand an agent's
/// private facts to another. Every verb is owner-only (`requireOwnerShell()`); agent text is printed through `safe()` after
/// the redactor (whose secrets the store loads non-interactively through `cliSecretVault(interactive: false)`).
struct MemoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Search, list, delete and hand over a company's memory (owner only).",
        discussion: """
            brahma memory <co> search <query> [--as @h]                   search as the owner, or as an agent would
            brahma memory <co> list [--agent @h] [--kind semantic|episodic]  remembered facts and episodes
            brahma memory <co> rm mem:<n>                                 delete an entry (its tombstone stays)
            brahma memory <co> inherit @old @new                          copy @old's private facts to @new
            """)

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "search <query>, list, rm mem:<n>, or inherit @old @new.") var words: [String] = []
    @Option(name: .customLong("as"), help: "With search: search as this agent can.") var reader: String?
    @Option(help: "With list: entries written by, or private to, this agent.") var agent: String?
    @Option(help: "With list: semantic or episodic.") var kind: String?

    enum Action: Equatable {
        case search(String)
        case list
        case remove(Int)
        case inherit(from: String, to: String)
    }

    static func action(_ words: [String]) throws -> Action {
        switch words.first {
        case "search" where words.count >= 2:
            let query = words.dropFirst().joined(separator: " ")
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            return .search(query)
        case "list" where words.count == 1: return .list
        case "rm" where words.count == 2:
            let ref = words[1].lowercased()
            guard ref.hasPrefix("mem:"), let n = Int(ref.dropFirst(4)), n > 0 else {
                throw ValidationError("rm takes a memory ref such as mem:12")
            }
            return .remove(n)
        case "inherit" where words.count == 3: return .inherit(from: words[1], to: words[2])
        default: break
        }
        throw ValidationError("expected 'search <query>', 'list', 'rm mem:<n>' or 'inherit @old @new'")
    }

    func validate() throws {
        let action = try Self.action(words)
        var isSearch = false
        if case .search = action { isSearch = true }
        if reader != nil, !isSearch { throw ValidationError("--as goes only with search") }
        if agent != nil || kind != nil, action != .list { throw ValidationError("--agent and --kind go only with list") }
        if let kind, MemoryEntryKind(rawValue: kind) == nil { throw ValidationError("--kind is semantic or episodic") }
    }

    func run() throws {
        let action = try Self.action(words)
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        func show(_ text: String) {
            // Fail closed: text the redactor could not check is not printed.
            print(safe(store.redactedForDisplay(text) ?? "[withheld: secrets are not loaded; run `brahma secret load`]"))
        }
        do {
            switch action {
            case .search(let query):
                var scope: Reader = .owner
                if let reader { scope = .agent(try resolveAgent(store, company: c, handle: reader).id) }
                let hits = try MemoryIndex(store: store).search(companyId: c.id, scope: scope, query: query,
                                                                limit: MemoryPolicy.maxHits, now: Store.now())
                guard !hits.isEmpty else { print("no results"); return }
                let handles = try handleMap(store, c)
                for hit in hits {
                    let who = hit.authorId.map { $0 == "owner" ? "owner" : $0 == "system" ? "engine" : "@" + (handles[$0] ?? "unknown") } ?? "engine"
                    if hit.tainted {
                        show("\(hit.ref) · \(hit.source) (untrusted: \(hit.taintReason ?? "outside content")) · \(who) · \(day(hit.updatedAt))")
                    } else {
                        show("\(hit.ref) · \(hit.source) · \(who) · \(day(hit.updatedAt)) — \(hit.title)")
                    }
                    if let snippet = hit.snippet { show("    | " + snippet) }
                }
            case .list:
                let agentId = try agent.map { try resolveAgent(store, company: c, handle: $0).id }
                let entries = try store.memoryEntries(companyId: c.id, filter: MemoryEntryFilter(
                    agentId: agentId, kind: kind.flatMap(MemoryEntryKind.init(rawValue:)), includeRemoved: true))
                guard !entries.isEmpty else { print("no memory entries"); return }
                let handles = try handleMap(store, c)
                for e in entries {
                    let author = e.authorId == "system" ? "engine" : e.authorId == "owner" ? "owner" : "@" + (handles[e.authorId] ?? "unknown")
                    var line = "\(e.ref) · \(e.kind.rawValue)/\(e.type.rawValue) · \(scopeLabel(e, handles)) · \(author) · \(day(e.createdAt))"
                    if let key = e.key { line += " · key \(key)" }
                    if e.tainted { line += " · tainted" }
                    if e.contradictedById != nil { line += " · contradicted" }
                    if e.inheritedFromId != nil { line += " · inherited" }
                    if e.purgedAt != nil { line += " · deleted" } else if e.removedAt != nil { line += " · removed" }
                    show(line)
                    if !e.fact.isEmpty { show("    | " + e.fact) }
                }
            case .remove(let number):
                if try store.ownerDeleteMemory(companyId: c.id, number: number) {
                    print("deleted mem:\(number)")
                } else {
                    print("mem:\(number) was already deleted")
                }
            case .inherit(let from, let to):
                let old = try resolveAgent(store, company: c, handle: from), new = try resolveAgent(store, company: c, handle: to)
                let copied = try store.inheritMemory(companyId: c.id, from: old.id, to: new.id)
                print(safe("copied \(copied) memory entr\(copied == 1 ? "y" : "ies") from @\(old.name) to @\(new.name)"))
            }
        } catch let e as WorkError {
            throw fail(e.message)
        }
    }

    private func handleMap(_ store: Store, _ c: Company) throws -> [String: String] {
        Dictionary(try store.agents(companyId: c.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private func scopeLabel(_ e: MemoryEntry, _ handles: [String: String]) -> String {
        switch e.accessKind {
        case "agent": return "private to @" + (handles[e.accessId ?? ""] ?? "unknown")
        case "item": return "item"
        case "team": return "team \(e.accessId ?? "?")"
        default: return e.accessKind
        }
    }

    private func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cliTimeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
