import Foundation
import GRDB

/// What the database knows about a secret. The value lives only in the `SecretVault`.
public struct SecretMeta: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "secret"

    public var id: String
    public var companyId: String
    public var name: String
    /// A test key may be handed to an agent's environment for the item it works on; any other secret is engine-held.
    public var isTest: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
}

extension Store {
    // MARK: Redaction

    /// The one helper every Store write of agent- or tool-produced text goes through. Throws `secretsNotLoaded` until the
    /// redactor has completed a load in this process (when the database had secrets at open): fail closed, never store
    /// text that might hold an unredacted secret.
    func redact(_ text: String) throws -> String {
        if !redactor.hasLoaded, let load = redactor.takeLoader() { load() }
        guard redactor.hasLoaded else { throw SecretError.secretsNotLoaded }
        return redactor.apply(text)
    }

    /// A loader `redact` runs once, on the first redacting write before the redactor has loaded (instead of throwing at
    /// once). The CLI sets it to a non-interactive load, so read-only commands never touch the vault. It may run inside a
    /// write transaction: it must read the database only through `reloadRedactorIfNeeded` (reentrant reads) and must not
    /// log (`logFailures: false`).
    public var redactorLoader: (@Sendable () -> Void)? {
        get { redactor.lazyLoader }
        set { redactor.lazyLoader = newValue }
    }

    func redact(_ text: String?) throws -> String? {
        guard let text else { return nil }
        return try redact(text)
    }

    func redact(_ spec: CheckSpec?) throws -> CheckSpec? {
        guard var spec else { return nil }
        spec.command = try redact(spec.command)
        spec.paths = try spec.paths.map { try redact($0) }
        return spec
    }

    /// Whether this process must hold everything that would store agent text: the redactor has never completed a load, or
    /// the last reload left a secret unloaded. The engine admits no turn, check, merge or dispatch while it is true, and
    /// `brahma mcp` refuses tool calls (`prepareForToolCall`). With no secrets it is never true.
    public var secretsHeld: Bool { !redactor.hasLoaded || !redactor.failedNames.isEmpty }

    /// Sets the redactor's starting state when the store opens: a database with no secrets is a complete (empty) load; one
    /// with secrets stays unloaded, so writes fail closed until `reloadRedactorIfNeeded` succeeds.
    func initializeRedactor() throws {
        let version = try secretsVersion()
        if version == "0:" { redactor.update([], version: version) }
    }

    /// "<count>:<max(updatedAt)>" over all companies: changes whenever a secret is added, replaced, removed or loaded by the
    /// owner (`ownerLoadSecrets`). A reentrant read: the lazy loader may call it inside a write transaction.
    public func secretsVersion() throws -> String {
        try writer.unsafeReentrantRead { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM secret") ?? 0
            let newest = try Date.fetchOne(db, sql: "SELECT MAX(updatedAt) FROM secret")
            return "\(count):" + (newest.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "")
        }
    }

    /// Whether the redactor is behind the database: a secret was added, replaced or removed since the last complete load,
    /// or the last load left some unloaded. The engine holds admission while it is true (the reload runs in the background).
    public func secretsReloadNeeded() throws -> Bool {
        try secretsVersion() != redactor.version || !redactor.hasLoaded
    }

    /// Whether a background reload should run now: one is needed and its backoff (after failed reads) has passed.
    public func redactorReloadDue() throws -> Bool {
        let version = try secretsVersion()
        guard version != redactor.version || !redactor.hasLoaded else { return false }
        return redactor.retryDue(version: version)
    }

    /// Loads every secret's value from the vault into `redactor` when the secrets changed since the last complete load, or
    /// the last load left some unloaded, and the retry backoff allows it (`force` skips the backoff: explicit owner actions).
    /// Returns whether it (re)loaded. Each secret loads on its own: a vault failure for one (a locked Keychain, a read that
    /// would need the owner's permission, a missing item, a value that is not UTF-8) never stops the others. A failed secret
    /// keeps any value loaded for it before and holds the store (`secretsHeld`); failed reads are retried after 5 s, doubling
    /// to 5 min of awake time, and at once when the secrets version changes (only failed or changed secrets are read again).
    /// With `logFailures` (the engine) each failure is logged once as an `error` activity line in its company, by name and
    /// never with a value, and each hold episode writes one owner notice. Throws only when the database cannot be read.
    @discardableResult
    public func reloadRedactorIfNeeded(vault: any SecretVault, logFailures: Bool = true, force: Bool = false) throws -> Bool {
        let version = try secretsVersion()
        guard version != redactor.version || !redactor.hasLoaded else { return false }
        guard force || redactor.retryDue(version: version) else { return false }
        let metas = try writer.unsafeReentrantRead { db in try SecretMeta.order(Column("createdAt"), Column("name")).fetchAll(db) }
        let previous = redactor.cachedValues()
        var loaded: [String: Redactor.Loaded] = [:]
        var failures: [(meta: SecretMeta, key: String, reason: String)] = []
        for meta in metas {
            let key = "\(meta.companyId):\(meta.name)"
            if let cached = previous[key], cached.updatedAt == meta.updatedAt { loaded[key] = cached; continue }
            let reason: String
            do {
                if let value = try vault.value(companyId: meta.companyId, name: meta.name) {
                    loaded[key] = Redactor.Loaded(name: meta.name, updatedAt: meta.updatedAt, value: value)
                    continue
                }
                reason = "the vault has no value for it"
            } catch {
                reason = "\(error)"
            }
            failures.append((meta, key, reason))
            // An older value stays redacted until the new one loads (its stale `updatedAt` makes the next read retry).
            if let old = previous[key] { loaded[key] = old }
        }
        redactor.install(loaded: loaded, failed: failures.map(\.meta.name).sorted(),
                         version: failures.isEmpty ? version : nil)
        redactor.recordAttempt(version: version, failed: !failures.isEmpty)
        redactor.setFailureReasons(Dictionary(failures.map { ($0.meta.name, Store.flat($0.reason, max: 200)) }, uniquingKeysWith: { a, _ in a }))
        if failures.isEmpty { _ = redactor.holdEpisode(held: false) }
        let fresh = redactor.unlogged(Set(failures.map { "\($0.key)@\($0.meta.updatedAt.timeIntervalSince1970)" }))
        if logFailures {
            let now = Store.now()
            var lines = failures.filter { fresh.contains("\($0.key)@\($0.meta.updatedAt.timeIntervalSince1970)") }.map { f in
                ActivityEvent(companyId: f.meta.companyId, agentId: nil, turnId: nil, kind: .error, text: redactor.apply(
                    "secret \(f.meta.name) could not be loaded (\(Store.flat(f.reason, max: 200))); new turns and agent tool calls are held until it loads. Run `brahma secret load` (or press Load secrets in the app), set it again with `brahma secret set`, or remove it with `brahma secret rm`."),
                    createdAt: now)
            }
            // One owner notice per hold episode, so the app shows why agents stopped.
            var notice: OwnerNotice?
            if redactor.holdEpisode(held: !failures.isEmpty) {
                notice = OwnerNotice(companyId: nil, kind: .system, urgency: .normal, title: "Secrets need your permission",
                                     body: "Brahma can't read \(failures.count) secret(s) without your permission; agents are paused. Run `brahma secret load` or press Load secrets in the app.",
                                     createdAt: now)
            }
            // Engine-authored text naming secrets, never their values: written directly, not through `redact`, which throws
            // while the secrets are not loaded.
            if !lines.isEmpty || notice != nil {
                try writer.write { db in
                    for i in lines.indices { try lines[i].insert(db) }
                    if var n = notice { try n.insert(db) }
                }
            }
        }
        return true
    }

    /// An explicit owner action (`brahma secret load`, the app's Load secrets): reads every secret with `vault` (the
    /// interactive one, so macOS may ask the owner), ignoring the backoff. It first touches every secret's `updatedAt`, so
    /// other processes (the engine, `brahma mcp`) see a new secrets version and retry their background reads at once.
    /// Returns how many loaded and which failed, with the reason (never a value).
    public func ownerLoadSecrets(vault: any SecretVault, now: Date = Store.now()) throws -> (loaded: Int, failed: [(name: String, reason: String)]) {
        try writer.write { db in
            let newest = try Date.fetchOne(db, sql: "SELECT MAX(updatedAt) FROM secret")
            // Strictly newer than any stored time, so the version always changes (a clock that went back cannot hide it).
            let stamp = max(now, (newest ?? now).addingTimeInterval(0.001))
            try db.execute(sql: "UPDATE secret SET updatedAt = ?", arguments: [stamp])
        }
        try reloadRedactorIfNeeded(vault: vault, logFailures: false, force: true)
        let metas = try secretsMetas()
        let failed = redactor.failedNames
        let reasons = redactor.lastFailureReasons()
        return (metas.count - failed.count, failed.map { ($0, reasons[$0] ?? "not loaded") })
    }

    /// How many secrets the database holds (all companies).
    public func secretCount() throws -> Int {
        try writer.read { db in try SecretMeta.fetchCount(db) }
    }

    private func secretsMetas() throws -> [SecretMeta] {
        try writer.read { db in try SecretMeta.fetchAll(db) }
    }

    /// `brahma mcp`'s check before every tool call: a non-interactive background reload (with the same backoff; failures go
    /// to `diagnostics`, never to the database), then the call is refused while the store is held (`secretsHeld`) with
    /// "secrets are not loaded yet; try again shortly". Never lets a tool persist agent text the redactor might miss.
    public func prepareForToolCall(vault: any SecretVault, diagnostics: (String) -> Void = { _ in }) throws {
        do { try reloadRedactorIfNeeded(vault: vault, logFailures: false) } catch { diagnostics("could not reload secrets: \(error)") }
        guard !secretsHeld else {
            let failed = redactor.failedNames
            if !failed.isEmpty { diagnostics("secrets not loaded: \(failed.joined(separator: ", "))") }
            throw ToolError(message: SecretError.secretsNotLoaded.message)
        }
    }

    // MARK: Owner-side API

    public func secrets(companyId: String) throws -> [SecretMeta] {
        try writer.read { db in
            try SecretMeta.filter(Column("companyId") == companyId).order(Column("name")).fetchAll(db)
        }
    }

    /// Stores the value in the vault and its metadata in the database. The value never goes to the database. The
    /// redactor of a running engine picks the new value up on its next tick.
    public func setSecret(companyId: String, name: String, value: String, isTest: Bool, vault: any SecretVault,
                          now: Date = Store.now()) throws {
        guard SecretName.isValid(name) else { throw SecretError.invalidName }
        if isTest {
            // A test key goes into agents' environments: only names `SecretName.isInjectable` accepts.
            guard SecretName.isInjectable(name) else { throw SecretError.notInjectable }
        } else {
            guard !ChildEnvironment.isReserved(name) else { throw SecretError.reservedName }
        }
        guard !value.isEmpty else { throw SecretError.emptyValue }
        guard try company(id: companyId) != nil else { throw SecretError.unknownCompany }
        // Vault first: a vault that cannot store leaves no metadata row for a value that is not there.
        try vault.set(companyId: companyId, name: name, value: value)
        try writer.write { db in
            if var row = try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).fetchOne(db) {
                row.isTest = isTest
                row.updatedAt = now
                try row.update(db)
            } else {
                try SecretMeta(id: UUID().uuidString, companyId: companyId, name: name, isTest: isTest, createdAt: now,
                               updatedAt: now, lastUsedAt: nil).insert(db)
            }
        }
    }

    /// Removes the vault value, then the metadata: a vault that cannot delete (a denied prompt) leaves the row, so the owner
    /// can retry instead of orphaning the value. Deleting a value the vault does not have is not an error.
    public func deleteSecret(companyId: String, name: String, vault: any SecretVault) throws {
        let exists = try writer.read { db in
            try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).fetchCount(db) > 0
        }
        guard exists else { throw SecretError.notFound }
        try vault.delete(companyId: companyId, name: name)
        _ = try writer.write { db in
            try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).deleteAll(db)
        }
    }
}
