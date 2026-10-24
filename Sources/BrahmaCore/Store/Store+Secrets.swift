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
        guard redactor.hasLoaded else { throw SecretError.secretsNotLoaded }
        return redactor.apply(text)
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

    /// "<count>:<max(updatedAt)>" over all companies: changes whenever a secret is added, replaced or removed.
    public func secretsVersion() throws -> String {
        try writer.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM secret") ?? 0
            let newest = try Date.fetchOne(db, sql: "SELECT MAX(updatedAt) FROM secret")
            return "\(count):" + (newest.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "")
        }
    }

    /// Loads every secret's value from the vault into `redactor` when the secrets changed since the last complete load, or
    /// the last load left some unloaded. Returns whether it (re)loaded. Each secret loads on its own: a vault failure for
    /// one (a locked Keychain, a missing item, a value that is not UTF-8) never stops the others. A failed secret keeps any
    /// value loaded for it before, is retried on the next call (only failed or changed secrets are read again), holds the
    /// store (`secretsHeld`) and, with `logFailures`, is logged once as an `error` activity line in its company, by name and
    /// never with a value. Throws only when the database cannot be read.
    @discardableResult
    public func reloadRedactorIfNeeded(vault: any SecretVault, logFailures: Bool = true) throws -> Bool {
        let version = try secretsVersion()
        guard version != redactor.version || !redactor.hasLoaded else { return false }
        let metas = try writer.read { db in try SecretMeta.order(Column("createdAt"), Column("name")).fetchAll(db) }
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
            // An older value stays redacted until the new one loads (its stale `updatedAt` makes the next call retry).
            if let old = previous[key] { loaded[key] = old }
        }
        redactor.install(loaded: loaded, failed: failures.map(\.meta.name).sorted(),
                         version: failures.isEmpty ? version : nil)
        let fresh = redactor.unlogged(Set(failures.map { "\($0.key)@\($0.meta.updatedAt.timeIntervalSince1970)" }))
        if logFailures {
            let now = Store.now()
            let lines = failures.filter { fresh.contains("\($0.key)@\($0.meta.updatedAt.timeIntervalSince1970)") }.map { f in
                ActivityEvent(companyId: f.meta.companyId, agentId: nil, turnId: nil, kind: .error, text: redactor.apply(
                    "secret \(f.meta.name) could not be loaded (\(Store.flat(f.reason, max: 200))); new turns and agent tool calls are held until it loads. Set it again with `brahma secret set` or remove it with `brahma secret rm`."),
                    createdAt: now)
            }
            // Engine-authored text naming the secret, never its value: written directly, not through `redact`, which throws
            // while the secrets are not loaded.
            if !lines.isEmpty { try writer.write { db in for var line in lines { try line.insert(db) } } }
        }
        return true
    }

    /// `brahma mcp`'s check before every tool call: reloads the redactor (failures go to `diagnostics`, never to the
    /// database), then refuses the call while the store is held (`secretsHeld`) with "secrets are not loaded yet; try again
    /// shortly". Never lets a tool persist agent text the redactor might miss.
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

    /// Removes the metadata and the vault value.
    public func deleteSecret(companyId: String, name: String, vault: any SecretVault) throws {
        let removed = try writer.write { db in
            try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).deleteAll(db)
        }
        guard removed > 0 else { throw SecretError.notFound }
        try vault.delete(companyId: companyId, name: name)
    }
}
