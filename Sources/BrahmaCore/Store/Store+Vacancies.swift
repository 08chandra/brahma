import Foundation
import GRDB

/// Plan 4b, Task 1b: the owner adds and removes open seats over 3a's `orgVacancy`. Owner-only: the callers are the CLI
/// (`brahma org vacancy add|remove`, behind `requireOwnerShell`) and the app; no agent tool reaches these. `vacancies(companyId:)`
/// and `fillVacancy` (Store+Org.swift) are 3a's and stay as shipped, now skipping removed rows.
extension Store {
    /// The longest note the owner can attach to a seat (counted before redaction).
    public static let vacancyNoteLimit = 280

    /// The team-name rule `joinOrgChannels` applies when it derives `team-<name>` (the same literal; 3a's code is left as it is).
    private static let teamNamePattern = "^[a-z0-9][a-z0-9_-]{0,63}$"

    /// Trimmed, one leading `@` stripped, lowercased.
    public static func normalizedHandle(_ raw: String) -> String {
        var handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if handle.hasPrefix("@") { handle.removeFirst() }
        return handle.lowercased()
    }

    /// Adds an open seat for `role` and returns its row. One write transaction validates, picks the handle
    /// (`<role.handlePrefix>-<n>` over every agent and every vacancy row of the company), redacts the note and inserts.
    /// The note goes through `redact(_:)`, the fail-closed path every stored text takes: until the redactor has loaded the
    /// vault's secrets the write throws `SecretError.secretsNotLoaded` rather than store a note that might hold one (a
    /// database with no secrets counts as loaded, so a fresh company never waits).
    ///
    /// Refuses, in this order: the company's pack is not installed; the role is not in the pack; the note is over
    /// `vacancyNoteLimit` characters; the team fails the channel rule; the manager is not an agent of this company
    /// (`forbidden`), is killed, or is itself an open seat. A unique index on `(companyId, handle)` is the backstop for two
    /// racing writers: a constraint failure is reported as `WorkError.conflict`.
    @discardableResult
    public func addVacancy(companyId: String, role rawRole: String, managerHandle rawManager: String?, team rawTeam: String?,
                           note: String, now: Date = Store.now()) throws -> OrgVacancy {
        let role = rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let manager = rawManager.map(Self.normalizedHandle).flatMap { $0.isEmpty ? nil : $0 }
        let team = rawTeam.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        do {
            return try writer.write { db in
                guard let company = try Company.fetchOne(db, key: companyId) else { throw StoreError.notFound }
                guard let pack = catalog.pack(company.packId) else {
                    throw WorkError.invalid("company pack \(company.packId) is not installed")
                }
                guard let template = pack.role(role) else { throw WorkError.invalid("unknown role \(role)") }
                guard note.count <= Self.vacancyNoteLimit else {
                    throw WorkError.invalid("vacancy notes are at most \(Self.vacancyNoteLimit) characters")
                }
                if let team, team.range(of: Self.teamNamePattern, options: .regularExpression) == nil {
                    throw WorkError.invalid("team names are lowercase letters, digits, - and _")
                }
                if let manager {
                    if let seated = try Agent.filter(Column("companyId") == companyId && Column("name") == manager).fetchOne(db) {
                        if seated.state == .killed { throw WorkError.invalid("@\(manager) is no longer with the company") }
                    } else if try OrgVacancy.filter(Column("companyId") == companyId && Column("handle") == manager
                                                    && Column("filledAt") == nil && Column("removedAt") == nil).fetchCount(db) > 0 {
                        throw WorkError.invalid("@\(manager) is an open seat; pick a seated manager")
                    } else {
                        throw WorkError.forbidden("not in your company")
                    }
                }
                let handle = try Store.nextHandle(db, companyId: companyId, prefix: template.handlePrefix)
                var row = OrgVacancy(id: nil, companyId: companyId, role: role, handle: handle, managerHandle: manager, team: team,
                                     createdAt: now, filledAt: nil, note: try redact(note), removedAt: nil)
                try row.insert(db)
                return row
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw WorkError.conflict("handle was just taken; try again")
        }
    }

    /// Takes an open seat back: sets `removedAt`, never deletes (the handle stays reserved). An unknown or already removed
    /// handle is `StoreError.notFound`; a filled seat is `WorkError.conflict`.
    public func removeVacancy(companyId: String, handle rawHandle: String, now: Date = Store.now()) throws {
        let handle = Self.normalizedHandle(rawHandle)
        try writer.write { db in
            guard var row = try OrgVacancy.filter(Column("companyId") == companyId && Column("handle") == handle
                                                  && Column("removedAt") == nil).fetchOne(db)
            else { throw StoreError.notFound }
            guard row.filledAt == nil else { throw WorkError.conflict("@\(handle) is already filled") }
            row.removedAt = now
            try row.update(db)
        }
    }
}
