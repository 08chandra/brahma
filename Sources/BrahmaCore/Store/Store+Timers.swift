import Foundation
import GRDB

extension Store {
    /// Creates the timer, or updates it when its action or schedule changed (and then recomputes the next fire).
    /// An unchanged timer is returned as it is, so calling this at every start never moves a pending fire.
    @discardableResult
    public func upsertTimer(companyId: String?, name: String, action: TimerAction, schedule: TimerSchedule,
                            now: Date, timeZone: TimeZone? = nil) throws -> EngineTimer {
        guard schedule.isValid else { throw TimerError.invalidSchedule }
        // Read the zone before the write: it may need a write of its own.
        let zone = timeZone ?? ownerTimeZone()
        return try writer.write { db in
            let existing = try EngineTimer.filter(Column("companyId") == companyId && Column("name") == name).fetchOne(db)
            if var timer = existing {
                guard timer.action != action || timer.schedule != schedule else { return timer }
                guard let first = schedule.firstFire(now: now, timeZone: zone) else { throw TimerError.invalidSchedule }
                timer.action = action
                timer.schedule = schedule
                timer.nextFireAt = first
                try timer.update(db)
                return timer
            }
            guard let first = schedule.firstFire(now: now, timeZone: zone) else { throw TimerError.invalidSchedule }
            let timer = EngineTimer(id: UUID().uuidString, companyId: companyId, name: name, action: action, schedule: schedule,
                                    nextFireAt: first, lastFiredAt: nil, enabled: true, createdAt: now)
            try timer.insert(db)
            return timer
        }
    }

    /// Enabled timers whose fire time has come, earliest first.
    public func dueTimers(now: Date) throws -> [EngineTimer] {
        try writer.read { db in
            try EngineTimer.filter(Column("enabled") == true && Column("nextFireAt") <= now)
                .order(Column("nextFireAt"), Column("name")).fetchAll(db)
        }
    }

    /// Every timer (nil), or one company's together with the engine-wide ones.
    public func timers(companyId: String?) throws -> [EngineTimer] {
        try writer.read { db in
            var request = EngineTimer.all()
            if let companyId { request = request.filter(Column("companyId") == companyId || Column("companyId") == nil) }
            return try request.order(Column("companyId"), Column("name")).fetchAll(db)
        }
    }

    /// One conditional UPDATE: it wins only if the timer is still enabled and still due at `expectedNext`, so two
    /// engines (or two ticks) cannot both fire it. `next == nil` disables the timer (a spent `once`).
    public func claimFire(timerId: String, expectedNext: Date, now: Date, next: Date?) throws -> Bool {
        try writer.write { db in try Store.claimFire(db: db, timerId: timerId, expectedNext: expectedNext, now: now, next: next) }
    }

    static func claimFire(db: Database, timerId: String, expectedNext: Date, now: Date, next: Date?) throws -> Bool {
        try db.execute(sql: """
            UPDATE timer SET lastFiredAt = ?, nextFireAt = COALESCE(?, nextFireAt), enabled = ?
            WHERE id = ? AND enabled = 1 AND nextFireAt = ?
            """, arguments: [now, next, next != nil, timerId, expectedNext])
        return db.changesCount == 1
    }

    /// Disables the timer and logs why (once: only the call that really disabled it logs). An engine-wide timer
    /// logs to every company.
    @discardableResult
    public func disableTimer(_ timer: EngineTimer, reason: String, now: Date) throws -> Bool {
        try writer.write { db in try Store.disableTimer(db: db, timer: timer, reason: reason, now: now) }
    }

    static func disableTimer(db: Database, timer: EngineTimer, reason: String, now: Date) throws -> Bool {
        try db.execute(sql: "UPDATE timer SET enabled = 0 WHERE id = ? AND enabled = 1", arguments: [timer.id])
        guard db.changesCount == 1 else { return false }
        try logTimerError(db: db, timer: timer, text: "timer \(timer.name) disabled: \(reason)", now: now)
        return true
    }

    static func logTimerError(db: Database, timer: EngineTimer, text: String, now: Date) throws {
        let companyIds = try timer.companyId.map { [$0] } ?? Company.fetchAll(db).map(\.id)
        for id in companyIds {
            try ActivityEvent(companyId: id, agentId: nil, turnId: nil, kind: .error, text: String(text.prefix(300)),
                              createdAt: now).insert(db)
        }
    }

    func logTimerError(_ timer: EngineTimer, text: String, now: Date) throws {
        try writer.write { db in try Store.logTimerError(db: db, timer: timer, text: text, now: now) }
    }
}
