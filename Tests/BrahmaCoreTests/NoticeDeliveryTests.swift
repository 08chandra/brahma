import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// 7-core: the notice store contract. The delivery plan (`NoticeDelivery.plan`) is a later task.
@Suite struct NoticeDeliveryTests {
    func makeStore() throws -> (Store, Company) {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "Ship it", workspacesRoot: try tempDir())
        return (store, company)
    }

    @Test func notifyOwnerContract() throws {
        let (store, company) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_781_107_200)

        // The simple form is a normal-urgency system notice, undelivered, with newlines and controls flattened.
        try store.notifyOwner(companyId: company.id, title: "Backup\nfailed\r\n\u{1B}[31mred", body: "line one\nline two\t\u{7}end", now: now)
        let first = try #require(try store.undeliveredNotices().first)
        #expect(first.companyId == company.id)
        #expect(first.kind == .system)
        #expect(first.urgency == .normal)
        #expect(first.title == "Backup failed   [31mred")
        #expect(first.body == "line one line two  end")
        #expect(first.createdAt == now)
        #expect(first.deliveredAt == nil)
        #expect(!first.title.contains("\n") && !first.body.contains("\n"))

        // The full form takes kind and urgency, inside the caller's transaction.
        try store.writer.write { db in
            try store.notifyOwner(db: db, companyId: company.id, kind: .digest, urgency: .urgent, title: "Digest", body: "ready",
                                  now: now.addingTimeInterval(1))
        }
        let pending = try store.undeliveredNotices()
        #expect(pending.map(\.title) == ["Backup failed   [31mred", "Digest"])
        #expect(pending.last?.kind == .digest && pending.last?.urgency == .urgent)
        #expect(try #require(pending.first?.id) < #require(pending.last?.id))

        // Delivery is marked once and keeps its first time.
        try store.markNoticesDelivered(ids: [try #require(pending.first?.id)], now: now.addingTimeInterval(60))
        #expect(try store.undeliveredNotices().map(\.title) == ["Digest"])
        try store.markNoticesDelivered(ids: [try #require(pending.first?.id)], now: now.addingTimeInterval(120))
        let all = try store.allNotices()
        #expect(all.count == 2)
        #expect(all.first?.deliveredAt == now.addingTimeInterval(60))
        try store.markNoticesDelivered(ids: [], now: now)

        // A deleted company takes its notices with it.
        try store.writer.write { db in _ = try Company.deleteOne(db, key: company.id) }
        #expect(try store.allNotices().isEmpty)
    }

    @Test func urgencyFromBlockedCount() {
        #expect(NoticeUrgency.blockedThreshold == 3)
        #expect(NoticeUrgency.of(blockedCount: 0) == .normal)
        #expect(NoticeUrgency.of(blockedCount: 2) == .normal)
        #expect(NoticeUrgency.of(blockedCount: 3) == .urgent)
        #expect(NoticeUrgency.of(blockedCount: 40) == .urgent)
    }
}
