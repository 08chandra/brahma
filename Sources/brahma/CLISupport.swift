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
    // The secret store is chosen before anything else: a refused choice fails the command, never falls back.
    do { try PlatformSecretVault.refuseMemory(try PlatformSecretVault.resolve(paths: paths)) } catch { throw fail("\(error)") }
    try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    let catalog = PackCatalog.loadOrBuiltin(directory: paths.packsDir) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    let store = try Store(path: paths.database.path, catalog: catalog)
    cliTimeZone = store.ownerTimeZone()
    // Every write of redactable text fails closed until the redactor has loaded the secrets (`Store.secretsHeld`). The load
    // is lazy: it runs once, non-interactively, on the first redacting write, so read-only commands never touch the vault.
    // An agent's shell (BRAHMA_AGENT_ID) never reads secret values: its writes keep failing closed.
    if ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"] == nil {
        store.redactorLoader = { [store] in
            guard let vault = try? cliSecretVault(interactive: false) else { return }
            _ = try? store.reloadRedactorIfNeeded(vault: vault, logFailures: false)
            guard store.secretsHeld else { return }
            let failed = store.redactor.failedNames
            let names = failed.isEmpty ? "" : " (\(safe(failed.joined(separator: ", "))))"
            FileHandle.standardError.write(Data("brahma: secrets not loaded\(names); run `brahma secret load` in Terminal, then try again\n".utf8))
        }
    }
    return (store, paths)
}

nonisolated(unsafe) private var cliSecretWarned = false

/// The secret store for this process (`PlatformSecretVault`: the Keychain, or a dev/demo home's file store chosen by
/// `BRAHMA_SECRET_STORE`, refused for the default data home, for unknown values and, in the CLI, for `memory`).
/// `interactive` only for explicit owner actions (`brahma secret set|rm|load`): every other read never prompts. Prints the
/// dev/demo warning once, the first time a non-production store is used.
func cliSecretVault(interactive: Bool) throws -> any SecretVault {
    let selection: PlatformSecretVault.Selection
    do {
        selection = try PlatformSecretVault.resolve(paths: BrahmaPaths.fromEnvironment(), interactive: interactive)
        try PlatformSecretVault.refuseMemory(selection)
    } catch { throw fail("\(error)") }
    if let warning = selection.warning, !cliSecretWarned {
        cliSecretWarned = true
        FileHandle.standardError.write(Data("brahma: \(safe(warning))\n".utf8))
    }
    return selection.vault
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
    case .workItem(_, let key)?: return "waiting on \(safe(key))"
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

/// The owner-key store for this process: the Keychain, or (dev/demo homes only) the file store chosen by
/// `BRAHMA_OWNER_KEY_STORE=file`, which is refused for the default data home and for unknown values.
func ownerKeyStore(for paths: BrahmaPaths) throws -> any OwnerKeyStore {
    let selection: PlatformOwnerKeyStore.Selection
    do { selection = try PlatformOwnerKeyStore.resolve(paths: paths) } catch { throw fail("\(error)") }
    if let warning = selection.warning { FileHandle.standardError.write(Data("brahma: \(safe(warning))\n".utf8)) }
    return selection.store
}

/// Owner-write commands must not run from an agent's shell: the engine sets BRAHMA_AGENT_ID for every turn, and
/// `<home>/owner.key` must hash to the value held in the Keychain (default deny). No owner command ever creates the
/// key; only the app and `brahma owner init` do. Nothing skips this check; `BRAHMA_OWNER_KEY_STORE=file` only moves
/// the hash into a temp/demo data home.
///
/// This is a deterrent, not a security boundary: until 5-lite read-denies the data home and Keychain services to
/// agents, an agent shell can still read the key and hash, or fake a TTY with `script`.
func requireOwnerShell() throws {
    if ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"] != nil {
        throw fail("owner commands can't run inside an agent turn")
    }
    let paths = BrahmaPaths.fromEnvironment()
    guard OwnerKey.verify(paths: paths, store: try ownerKeyStore(for: paths)) else {
        throw fail("owner key missing or invalid; run 'brahma owner init' in Terminal or open the app")
    }
    // The key is keyed on the canonical data home; the database we are about to open must really live in it.
    guard OwnerKey.databaseIsInsideHome(paths: paths) else {
        throw fail("the database is a symlink or lies outside the data home; refusing owner command")
    }
}
