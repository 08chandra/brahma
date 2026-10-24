import Foundation
import GRDB

/// A stored daily digest (`ownerDigest`).
public struct OwnerDigest: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ownerDigest"

    public var id: String
    public var companyId: String
    public var periodStart: Date
    public var periodEnd: Date
    public var markdown: String
    public var createdAt: Date
}

extension Store {
    @discardableResult
    public func saveDigest(companyId: String, digest: Digest, now: Date = Store.now()) throws -> OwnerDigest {
        try writer.write { db in try Store.saveDigest(db: db, companyId: companyId, digest: digest, now: now) }
    }

    static func saveDigest(db: Database, companyId: String, digest: Digest, now: Date) throws -> OwnerDigest {
        let row = OwnerDigest(id: UUID().uuidString, companyId: companyId, periodStart: digest.periodStart,
                              periodEnd: digest.periodEnd, markdown: digest.markdown, createdAt: now)
        try row.insert(db)
        return row
    }

    public func latestDigest(companyId: String) throws -> OwnerDigest? {
        try writer.read { db in
            try OwnerDigest.filter(Column("companyId") == companyId).order(Column("periodEnd").desc, Column("rowid").desc).fetchOne(db)
        }
    }

    /// Where the previous digest stopped; nil when none was ever stored.
    public func lastDigestEnd(companyId: String) throws -> Date? {
        try latestDigest(companyId: companyId)?.periodEnd
    }

    /// The daily job's tail: store the digest and tell the owner, in one transaction.
    func storeDigestAndNotify(company: Company, digest: Digest, now: Date) throws {
        try writer.write { db in
            try Store.saveDigest(db: db, companyId: company.id, digest: digest, now: now)
            try notifyOwner(db: db, companyId: company.id, kind: .digest, urgency: .normal,
                            title: "\(company.name) daily digest", body: digest.notificationBody, now: now)
        }
    }
}

/// The `digest.daily` timer job.
enum DigestJobs {
    static let dailyWindow: TimeInterval = 86_400

    static func daily(_ context: TimerContext) async throws {
        guard let companyId = context.timer.companyId else { return }
        let store = context.store
        let now = context.now
        try await context.blocking.tryRun {
            guard let company = try store.company(id: companyId) else { return }
            let since = try store.lastDigestEnd(companyId: companyId) ?? now.addingTimeInterval(-dailyWindow)
            let digest = try DigestBuilder.build(store: store, companyId: companyId, since: since, now: now, tz: store.ownerTimeZone())
            guard !digest.isEmpty else { return }
            try store.storeDigestAndNotify(company: company, digest: digest, now: now)
        }
    }
}
