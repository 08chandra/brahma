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

    /// The one helper every Store write of agent- or tool-produced text goes through.
    func redact(_ text: String) -> String { redactor.apply(text) }

    func redact(_ text: String?) -> String? { text.map(redactor.apply) }

    func redact(_ spec: CheckSpec?) -> CheckSpec? {
        guard var spec else { return nil }
        spec.command = redactor.apply(spec.command)
        spec.paths = spec.paths.map(redactor.apply)
        return spec
    }

    /// "<count>:<max(updatedAt)>" over all companies: changes whenever a secret is added, replaced or removed.
    public func secretsVersion() throws -> String {
        try writer.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM secret") ?? 0
            let newest = try Date.fetchOne(db, sql: "SELECT MAX(updatedAt) FROM secret")
            return "\(count):" + (newest.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "")
        }
    }

    /// Loads every secret's value from the vault into `redactor` when the secrets changed since the last load. Returns
    /// whether it reloaded. A value the vault no longer has is skipped; any other vault failure throws and leaves the
    /// old set (and version) in place, so the next call retries.
    @discardableResult
    public func reloadRedactorIfNeeded(vault: any SecretVault) throws -> Bool {
        let version = try secretsVersion()
        guard version != redactor.version else { return false }
        let metas = try writer.read { db in try SecretMeta.order(Column("createdAt"), Column("name")).fetchAll(db) }
        var values: [(name: String, value: String)] = []
        for meta in metas {
            if let value = try vault.value(companyId: meta.companyId, name: meta.name) { values.append((meta.name, value)) }
        }
        redactor.update(values, version: version)
        return true
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
        guard !ChildEnvironment.isReserved(name) else { throw SecretError.reservedName }
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
