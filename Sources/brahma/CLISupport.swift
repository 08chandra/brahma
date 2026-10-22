import ArgumentParser
import Foundation
import BrahmaCore
import BrahmaKeychain

/// Agent-controlled text must never reach the terminal raw.
func safe(_ text: String) -> String { TerminalText.sanitize(text) }

func fail(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data("brahma: \(safe(message))\n".utf8))
    return .failure
}

/// The owner's time zone for `clock()`, set by `openStore()`. A CLI process is single-threaded for output.
nonisolated(unsafe) var cliTimeZone: TimeZone = .current

func openStore() throws -> (Store, BrahmaPaths) {
    let paths = BrahmaPaths.fromEnvironment()
    try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    let catalog = PackCatalog.loadOrBuiltin(directory: paths.packsDir) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    let store = try Store(path: paths.database.path, catalog: catalog)
    cliTimeZone = store.ownerTimeZone()
    return (store, paths)
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
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = cliTimeZone
    f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return f.string(from: date)
}

/// Owner-write commands must not run from an agent's shell: the engine sets BRAHMA_AGENT_ID for every turn, and
/// `<home>/owner.key` must hash to the value held in the Keychain (default deny). No owner command ever creates the
/// key; only the app and `brahma owner init` do. There is no environment variable or flag that skips this check.
///
/// This is a deterrent, not a security boundary: until 5-lite read-denies the data home and Keychain services to
/// agents, an agent shell can still read the key and hash, or fake a TTY with `script`.
func requireOwnerShell() throws {
    if ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"] != nil {
        throw fail("owner commands can't run inside an agent turn")
    }
    let paths = BrahmaPaths.fromEnvironment()
    guard OwnerKey.verify(paths: paths, store: PlatformOwnerKeyStore.make()) else {
        throw fail("owner key missing or invalid; run 'brahma owner init' in Terminal or open the app")
    }
    // The key is keyed on the canonical data home; the database we are about to open must really live in it.
    guard OwnerKey.databaseIsInsideHome(paths: paths) else {
        throw fail("the database is a symlink or lies outside the data home; refusing owner command")
    }
}
