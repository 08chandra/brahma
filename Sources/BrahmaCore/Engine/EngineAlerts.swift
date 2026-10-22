import Foundation
import GRDB

/// Messages the engine must put in front of the owner. Each also files one `engineAlert` ask per hold reason in every company
/// (a repeat for the same reason changes nothing); the ask answers itself with "resolved" when the hold ends
/// (`Store.clearHold`, or a hold of a higher precedence replacing it).
public enum EngineAlerts {
    /// The reason that keys the alert ask when the caller names none and there is no hold.
    static let generalReason = "doctor"

    /// A system DM to `owner` in every company, an `ActivityEvent(.error)` and the `engineAlert` ask, inside the caller's
    /// transaction. `reason` defaults to the current engine hold's reason. `companyId` limits it to that company.
    public static func raise(store: Store, db: Database, text: String, now: Date, reason: String? = nil,
                             companyId: String? = nil) throws {
        let router = MessageRouter(store: store)
        let key = try reason ?? EngineHold.fetchOne(db, key: 1)?.reason.rawValue ?? generalReason
        for company in try Company.fetchAll(db) where companyId == nil || company.id == companyId {
            try router.sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error, text: text, createdAt: now).insert(db)
            try store.fileEngineAlert(db, company: company, reason: key, text: text, now: now)
        }
    }

    public static func raise(store: Store, text: String, now: Date, reason: String? = nil, companyId: String? = nil) throws {
        try store.writer.write { db in try raise(store: store, db: db, text: text, now: now, reason: reason, companyId: companyId) }
    }

    /// The reason that keys the alert about an engine file under `.brahma/` that was a link or not a regular file.
    public static let engineFileReason = "engine-file"

    static func engineFileText(_ problem: UnsafeEngineFile) -> String {
        "The engine refused to write through \(Store.flat(problem.path, max: 400)): it \(problem.problem). Something in the "
            + "workspace (an agent, or another program) put it there; nothing outside the workspace was written. Check the file."
    }
}

extension Store {
    /// Raises the engine alert for a link or odd file found where the engine keeps its own files, in the caller's transaction.
    func alertEngineFile(db: Database, _ problem: UnsafeEngineFile, companyId: String, now: Date) throws {
        try EngineAlerts.raise(store: self, db: db, text: EngineAlerts.engineFileText(problem), now: now,
                               reason: EngineAlerts.engineFileReason, companyId: companyId)
    }

    /// The same in its own transaction; never throws (the alert is best effort, the caller reports its own error).
    func alertEngineFile(_ problem: UnsafeEngineFile, companyId: String, now: Date = Store.now()) {
        try? writer.write { db in try alertEngineFile(db: db, problem, companyId: companyId, now: now) }
    }
}
