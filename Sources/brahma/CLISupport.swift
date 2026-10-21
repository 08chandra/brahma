import ArgumentParser
import Foundation
import BrahmaCore

/// Agent-controlled text must never reach the terminal raw.
func safe(_ text: String) -> String { TerminalText.sanitize(text) }

func fail(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data("brahma: \(safe(message))\n".utf8))
    return .failure
}

func openStore() throws -> (Store, BrahmaPaths) {
    let paths = BrahmaPaths.fromEnvironment()
    try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    let catalog = PackCatalog.loadOrBuiltin(directory: paths.packsDir) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    return (try Store(path: paths.database.path, catalog: catalog), paths)
}

/// Resolves a company by name or slug, case-insensitively. Ambiguity lists the matches.
func resolveCompany(_ store: Store, _ query: String) throws -> Company {
    let q = query.lowercased()
    let matches = try store.companies().filter { $0.name.lowercased() == q || $0.slug == q }
    switch matches.count {
    case 1: return matches[0]
    case 0: throw fail("no company named '\(query)'")
    default:
        let list = matches.map { "\($0.name) (\($0.slug))" }.joined(separator: ", ")
        throw fail("'\(query)' is ambiguous: \(list)")
    }
}

func resolveAgent(_ store: Store, company: Company, handle: String) throws -> Agent {
    let h = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
    guard let agent = try store.agent(companyId: company.id, name: h) else {
        throw fail("no agent @\(h.lowercased()) in \(company.name)")
    }
    return agent
}

func describe(_ blocker: Blocker?, names: [String: String] = [:]) -> String {
    switch blocker {
    case nil: return ""
    case .agent(let id)?: return "waiting on @\(safe(names[id] ?? String(id.prefix(8))))"
    case .owner(let reason)?: return "waiting on owner: \(safe(reason))"
    case .usageLimit(let until)?: return "usage limit until \(clock(until))"
    case .turnBudget(let until)?: return "turn budget until \(clock(until))"
    case .retry(let until, let failures)?: return "retry after failure #\(failures) at \(clock(until))"
    }
}

func clock(_ date: Date, seconds: Bool = false) -> String {
    let f = DateFormatter()
    f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return f.string(from: date)
}

/// Owner-write commands must not run from an agent's shell (the engine sets BRAHMA_AGENT_ID for every turn).
func requireOwnerShell() throws {
    if ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"] != nil {
        throw fail("owner commands can't run inside an agent turn")
    }
}
