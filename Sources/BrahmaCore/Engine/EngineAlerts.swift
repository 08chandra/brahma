import Foundation
import GRDB

/// Messages the engine must put in front of the owner. Task 11 also files a deduplicated `engineAlert` ask.
public enum EngineAlerts {
    /// A system DM to `owner` in every company, plus an `ActivityEvent(.error)`, inside the caller's transaction.
    public static func raise(store: Store, db: Database, text: String, now: Date) throws {
        let router = MessageRouter(store: store)
        for company in try Company.fetchAll(db) {
            try router.sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error, text: text, createdAt: now).insert(db)
        }
    }

    public static func raise(store: Store, text: String, now: Date) throws {
        try store.writer.write { db in try raise(store: store, db: db, text: text, now: now) }
    }
}
