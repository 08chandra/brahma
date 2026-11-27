import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan S Task S4 (spec §6.7, B8): `EngineAlerts.raise` takes a required `AlertScope`. `.company(id)` files the DM, the
/// activity line and the `engineAlert` ask in that company only (an unknown id throws); `.allCompanies(<named reason>)`
/// reaches every company and is kept for engine-wide conditions, among them every engine hold.
@Suite(.scratch) struct AlertScopeTests {
    struct Two {
        let store: Store
        let a: Company, b: Company
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            store = try Store.inMemory()
            a = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            b = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
        }

        /// What one company holds of an alert whose text contains `marker`: owner DMs, activity lines, engine-alert asks.
        func footprint(_ company: Company, _ marker: String) throws -> (dms: Int, activity: Int, asks: Int) {
            try store.writer.read { db in
                let dms = try Message.filter(Column("companyId") == company.id && Column("senderId") == "system")
                    .fetchAll(db).filter { $0.text.contains(marker) }.count
                let activity = try ActivityEvent.filter(Column("companyId") == company.id).fetchAll(db)
                    .filter { $0.kind == .error && $0.text.contains(marker) }.count
                let asks = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert)
                    .fetchAll(db).filter { $0.summary.contains(marker) }.count
                return (dms, activity, asks)
            }
        }
    }

    @Test func companyScopeTouchesOneCompany() throws {
        let t = try Two()
        try EngineAlerts.raise(store: t.store, text: "only-acme alert", now: t.now, reason: "probe:a", scope: .company(t.a.id))
        let inA = try t.footprint(t.a, "only-acme alert"), inB = try t.footprint(t.b, "only-acme alert")
        #expect(inA.dms == 1 && inA.activity == 1 && inA.asks == 1, "\(inA)")
        #expect(inB.dms == 0 && inB.activity == 0 && inB.asks == 0, "\(inB)")
        // The same in the caller's transaction.
        try t.store.writer.write { db in
            try EngineAlerts.raise(store: t.store, db: db, text: "only-globex alert", now: t.now, reason: "probe:b", scope: .company(t.b.id))
        }
        let gA = try t.footprint(t.a, "only-globex alert"), gB = try t.footprint(t.b, "only-globex alert")
        #expect(gA.dms == 0 && gA.activity == 0 && gA.asks == 0, "\(gA)")
        #expect(gB.dms == 1 && gB.activity == 1 && gB.asks == 1, "\(gB)")
    }

    @Test func allCompaniesReachesEvery() throws {
        let t = try Two()
        for alert in GlobalAlert.allCases {
            let marker = "engine-wide \(alert.rawValue)"
            try EngineAlerts.raise(store: t.store, text: marker, now: t.now, reason: "probe-\(alert.rawValue)", scope: .allCompanies(alert))
            for company in [t.a, t.b] {
                let f = try t.footprint(company, marker)
                #expect(f.dms == 1 && f.activity == 1 && f.asks == 1, "\(alert) in \(company.name): \(f)")
            }
        }
    }

    /// A hold pauses the whole engine: the alert a hold raises (`HoldReason.alertScope`, what the health rules pass after
    /// `Store.setHold`) is `.allCompanies(.engineHold)` for every reason, and it reaches every company.
    @Test func everyHoldReasonIsGlobal() throws {
        #expect(HoldReason.allCases.count == 4)
        for reason in HoldReason.allCases {
            #expect(reason.alertScope == .allCompanies(.engineHold), "\(reason)")
            let t = try Two()
            #expect(try t.store.setHold(reason: reason, detail: "probe", now: t.now))
            let marker = "hold alert \(reason.rawValue)"
            try EngineAlerts.raise(store: t.store, text: marker, now: t.now, reason: reason.rawValue, scope: reason.alertScope)
            for company in [t.a, t.b] {
                let f = try t.footprint(company, marker)
                #expect(f.dms == 1 && f.activity == 1 && f.asks == 1, "\(reason) in \(company.name): \(f)")
            }
        }
    }

    /// A company that does not exist is an error, never a silent no-op (and never a broadcast); nothing is written.
    @Test func unknownCompanyThrows() throws {
        let t = try Two()
        #expect(throws: WorkError.self) {
            try EngineAlerts.raise(store: t.store, text: "lost alert", now: t.now, reason: "probe", scope: .company("no-such-company"))
        }
        #expect(throws: WorkError.self) {
            try t.store.writer.write { db in
                try EngineAlerts.raise(store: t.store, db: db, text: "lost alert", now: t.now, reason: "probe", scope: .company(""))
            }
        }
        for company in [t.a, t.b] {
            let f = try t.footprint(company, "lost alert")
            #expect(f.dms == 0 && f.activity == 0 && f.asks == 0, "\(company.name): \(f)")
        }
    }
}
