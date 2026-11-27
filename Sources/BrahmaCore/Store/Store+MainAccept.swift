import Foundation
import GRDB

/// How the owner accepted a `main` head (Plan X6a ruling R38).
public enum MainAcceptKind: String, Codable, Sendable, DatabaseValueConvertible {
    /// `brahma main accept` with no ref, `brahma merge adopt-main`: `main`'s head (or a commit the owner named) becomes the record.
    case adopt
    /// `brahma main accept <quarantine ref>`: the engine's quarantined commit merged (or fast-forwarded) into `main`.
    case quarantineAccept
}

extension Store {
    /// Records an owner acceptance (`mainAccept`) of `commit`, with the head the record held before (`company.mainCommit`).
    /// Called inside the write that finalizes `mainCommit`, before it, so `previousHead` is the record being replaced. An accept
    /// of the head already recorded adds nothing and writes no row. Owner paths only: `adoptMain(by: .owner)` and
    /// `acceptMainCommit`.
    static func recordMainAccept(_ db: Database, companyId: String, commit: String, kind: MainAcceptKind, now: Date) throws {
        let previous: String? = try Row.fetchOne(db, sql: "SELECT mainCommit FROM company WHERE id = ?", arguments: [companyId])?["mainCommit"]
        guard previous != commit else { return }
        try db.execute(sql: """
            INSERT INTO mainAccept (companyId, "commit", previousHead, kind, createdAt) VALUES (?, ?, ?, ?, ?)
            """, arguments: [companyId, commit, previous, kind, now])
    }
}
