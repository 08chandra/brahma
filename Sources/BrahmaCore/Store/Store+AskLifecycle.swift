import Foundation
import GRDB

/// Pinned numbers of the ask lifecycle. Every duration is company-active seconds: paused time and engine holds don't count.
public enum AskLifecycle {
    public static let day: TimeInterval = 86_400
    /// Reminders to the owner for an ask in `pendingOwner`: at 1 and at 3 active days.
    public static let ownerReminders: [TimeInterval] = [1 * day, 3 * day]
    /// The internal approver is reminded after this long in `pendingInternal`...
    public static let internalReminder: TimeInterval = 1 * day
    /// ...and the ask is rerouted after this long.
    public static let internalEscalate: TimeInterval = 3 * day
    /// A paused approver's asks are rerouted after the approver has been paused this long.
    public static let pausedReroute: TimeInterval = 1 * day
    static let maxAncestorHops = 32
}

/// Sweep, escalation and rescind. Owner decisions (`ownerRescind`) are called only by the owner CLI and the app.
extension Store {
    // MARK: Sweep

    /// The tick's pass over open asks (active time): expiry, owner reminders, internal aging and paused-approver
    /// rerouting. Returns how many asks changed.
    @discardableResult
    public func sweepAsks(now: Date = Store.now()) throws -> Int {
        try writer.write { db in
            var changed = 0
            let open = [AskStatus.pendingInternal, .pendingOwner].map(\.rawValue)
            for company in try Company.fetchAll(db) {
                let active = try Store.activeNow(db: db, companyId: company.id)
                let asks = try Ask.filter(Column("companyId") == company.id && open.contains(Column("status")))
                    .order(Column("number")).fetchAll(db)
                for var ask in asks {
                    if try sweepOne(db, ask: &ask, company: company, active: active, now: now) { changed += 1 }
                }
            }
            return changed
        }
    }

    private static func ageText(_ age: TimeInterval) -> String {
        let days = max(1, Int(age / AskLifecycle.day))
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private func sweepOne(_ db: Database, ask: inout Ask, company: Company, active: Double, now: Date) throws -> Bool {
        if let expires = ask.expiresActive, expires <= active {
            try settle(db, ask: &ask, status: .expired, decidedBy: "system", tellRequesterToo: false, now: now)
            try tellRequester(db, ask, text: "\(ask.ref) expired (not approved)", now: now)
            return true
        }
        let age = active - ask.statusSinceActive
        switch ask.status {
        case .pendingOwner:
            let due = AskLifecycle.ownerReminders.filter { age >= $0 }.count
            guard due > ask.remindCount else { return false }
            ask.remindCount = due
            ask.notifiedAt = nil
            ask.updatedAt = now
            try ask.update(db)
            // C5 fix round 3: the title as `enterPendingOwner` shows it (gated final string; held back while the engine's
            // values aren't loaded in full), never raw a day later.
            let text = "Reminder: \(ask.ref) has waited \(Store.ageText(age)): "
                + Self.ownerShownTitle(ask, knownValues: engineKnownValues(db: db, companyId: company.id))
            try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .approval, text: text, createdAt: now).insert(db)
            return true
        case .pendingInternal:
            guard let approverId = ask.internalApproverId, let approver = try Agent.fetchOne(db, key: approverId) else {
                try reroute(db, ask: &ask, company: company, to: nil, now: now)
                return true
            }
            if approver.paused, let since = approver.pausedActive, active - since >= AskLifecycle.pausedReroute {
                let next = try internalApprover(db, company: company, kind: ask.kind, requesterId: ask.requesterId, excluding: [approver.id])
                try reroute(db, ask: &ask, company: company, to: next, now: now)
                return true
            }
            if age >= AskLifecycle.internalEscalate {
                try reroute(db, ask: &ask, company: company, to: try nearestAncestor(db, of: approver, notRequester: ask.requesterId), now: now)
                return true
            }
            if age >= AskLifecycle.internalReminder, ask.remindCount == 0 {
                ask.remindCount = 1
                ask.updatedAt = now
                try ask.update(db)
                if approver.state != .killed {
                    try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: approver.name,
                                                          text: "Reminder: \(ask.ref) waits for your decision", now: now)
                }
                return true
            }
            return false
        default:
            return false
        }
    }

    /// The agent's nearest non-killed ancestor (by manager) who is not the requester.
    func nearestAncestor(_ db: Database, of agent: Agent, notRequester requesterId: String) throws -> Agent? {
        var seen: Set<String> = [agent.id]
        var next = agent.managerId
        for _ in 0..<AskLifecycle.maxAncestorHops {
            guard let id = next, seen.insert(id).inserted, let a = try Agent.fetchOne(db, key: id) else { return nil }
            if a.state != .killed, a.id != requesterId { return a }
            next = a.managerId
        }
        return nil
    }

    /// Hands a `pendingInternal` ask to another approver (clock and reminders restart), or to the owner when there is none.
    func reroute(_ db: Database, ask: inout Ask, company: Company, to approver: Agent?, now: Date) throws {
        guard let approver else {
            ask.updatedAt = now
            try enterPendingOwner(db, ask: &ask, company: company, knownValues: engineKnownValues(db: db, companyId: company.id), now: now)
            try ask.update(db)
            return
        }
        ask.internalApproverId = approver.id
        ask.statusSinceActive = try Store.activeNow(db: db, companyId: company.id)
        ask.remindCount = 0
        ask.updatedAt = now
        try ask.update(db)
        let text = "\(ask.ref) needs your decision: \(try Store.displayTitle(db, ask)): \(ask.title) (rerouted to you; decide with the decide tool)"
        try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: approver.name, text: text, now: now)
    }

    // MARK: Escalation

    /// The agent that takes an escalated ask: a non-killed, non-paused agent covering the CEO role who is neither the requester
    /// nor the approver. The acting CEO covers the role and comes first.
    private func escalationTarget(_ db: Database, company: Company, excluding: Set<String>) throws -> Agent? {
        guard let pack = catalog.pack(company.packId) else { return nil }
        let roles = pack.rolesCovering("ceo")
        let found = try Agent.filter(Column("companyId") == company.id && roles.contains(Column("role")) && Column("state") != "killed"
                                     && Column("paused") == false)
            .order(Column("createdAt"), Column.rowID).fetchAll(db)
        let acting = try Store.actingCEOs(db, companyId: company.id).filter { !$0.paused }
        return (acting + found).first { !excluding.contains($0.id) }
    }

    /// `escalate_decision`: once per ask. The internal approver may escalate while the ask is `pendingInternal`, the requester
    /// after an internal rejection. The ask goes to the CEO-covering agent (not the requester or approver), else to the owner.
    @discardableResult
    public func escalate(askId: String, by sender: Sender, reason: String, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            var ask = try requireAsk(db, askId)
            guard case .agent(let agentId) = sender, let agent = try Agent.fetchOne(db, key: agentId),
                  agent.companyId == ask.companyId else { throw WorkError.forbidden("not in your company") }
            guard agent.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            guard ask.kind.isDecision else { throw WorkError.invalid("\(ask.ref) is not a decision; it can't be escalated") }
            guard ask.escalatedAt == nil else { throw WorkError.conflict("\(ask.ref) was already escalated") }
            let rejectedInternally = ask.status == .rejected && ask.internalDecidedAt != nil && ask.ownerDecidedAt == nil
                && ask.decidedBy?.hasPrefix("@") == true
            guard ask.status == .pendingInternal || rejectedInternally else {
                throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)")
            }
            let isApprover = ask.status == .pendingInternal && ask.internalApproverId == agentId
            let isRequester = rejectedInternally && ask.requesterId == agentId
            guard isApprover || isRequester else {
                throw WorkError.forbidden("only @\(try Store.handle(db, ask.internalApproverId)) can escalate \(ask.ref)"
                                          + (rejectedInternally ? " (or its requester)" : ""))
            }
            guard let why = try Store.limitedText(reason, Store.maxAskField, "the reason") else { throw WorkError.invalid("the reason is empty") }
            let company = try requireCompany(db, ask.companyId)
            let flatWhy = Store.flat(why, max: Store.maxAskField)
            var exclude: Set<String> = [ask.requesterId]
            if let current = ask.internalApproverId { exclude.insert(current) }
            let target = try escalationTarget(db, company: company, excluding: exclude)

            ask.escalatedAt = now
            ask.decidedBy = nil
            ask.internalDecidedAt = nil
            ask.updatedAt = now
            let line = "Escalated: \(ask.ref) by @\(agent.name): \(flatWhy)"
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .approval, text: line, createdAt: now).insert(db)
            if let target {
                ask.status = .pendingInternal
                ask.internalApproverId = target.id
                ask.statusSinceActive = try Store.activeNow(db: db, companyId: company.id)
                ask.remindCount = 0
                try ask.update(db)
                let text = "\(ask.ref) (\(try Store.displayTitle(db, ask)): \(ask.title)) was escalated to you by @\(agent.name): \(flatWhy) (decide with the decide tool)"
                try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: target.name, text: text, now: now)
            } else {
                try enterPendingOwner(db, ask: &ask, company: company, knownValues: engineKnownValues(db: db, companyId: company.id), now: now)
                try ask.update(db)
            }
            return ask
        }
    }

    // MARK: Rescind

    /// The owner takes back an approved ask (a policy-approved FYI too): `rescinded`, then its effects are reversed.
    @discardableResult
    public func ownerRescind(askId: String, note: String = "", now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            var ask = try requireAsk(db, askId)
            guard ask.status == .approved else {
                throw WorkError.conflict(ask.status == .rescinded ? "\(ask.ref) is already rescinded"
                                         : "\(ask.ref) is \(ask.status.rawValue), not approved; only approved asks can be rescinded")
            }
            // Approving the engine's quarantine ask merged its recorded commit into main: that cannot be taken back here.
            if let ref = Store.quarantineRef(of: ask) {
                throw WorkError.conflict("\(ask.ref) approved \(ref), and it was merged into main; a merge cannot be rescinded. "
                                         + "To undo it, revert that commit on main in the workspace and accept main again (brahma main accept).")
            }
            let why = Store.flat(note, max: Store.maxAskField)
            let tail = why.isEmpty ? "" : ": \(why)"
            ask.status = .rescinded
            ask.rescindedAt = now
            ask.statusSinceActive = try Store.activeNow(db: db, companyId: ask.companyId)
            ask.updatedAt = now
            try ask.update(db)
            try ActivityEvent(companyId: ask.companyId, agentId: nil, turnId: nil, kind: .approval,
                              text: "\(ask.ref) was rescinded by the owner\(tail)", createdAt: now).insert(db)
            try reverseAskEffects(db, ask: ask, now: now)
            // The requester and the internal approver are told.
            let text = "\(ask.ref) was rescinded by the owner\(tail)"
            var told: Set<String> = []
            for id in [ask.requesterId, ask.internalApproverId ?? ""] where told.insert(id).inserted {
                try tell(db, companyId: ask.companyId, agentId: id, text: text, now: now)
            }
            return ask
        }
    }

    /// A system DM to a live agent (nothing for "system", "" or a killed agent).
    private func tell(_ db: Database, companyId: String, agentId: String, text: String, now: Date) throws {
        guard let a = try Agent.fetchOne(db, key: agentId), a.companyId == companyId, a.state != .killed else { return }
        try MessageRouter(store: self).sendDM(db: db, companyId: companyId, from: .system, to: a.name, text: text, now: now)
    }

    /// Undoes what an approved ask set in motion. Its status is already `rescinded`.
    func reverseAskEffects(_ db: Database, ask: Ask, now: Date) throws {
        switch ask.kind {
        case .prd, .architecture:
            // Plans that wait on a gate that no longer stands are rejected.
            guard try !Store.hasApproved(db: db, companyId: ask.companyId, kind: ask.kind) else { return }
            let open = [AskStatus.pendingInternal, .pendingOwner].map(\.rawValue)
            let plans = try Ask.filter(Column("companyId") == ask.companyId && Column("kind") == AskKind.sprintPlan
                                       && open.contains(Column("status"))).order(Column("number")).fetchAll(db)
            for var plan in plans {
                plan.ownerNote = "gate \(ask.ref) was rescinded"
                try settle(db, ask: &plan, status: .rejected, decidedBy: "system", tellRequesterToo: false, now: now)
                try tellRequester(db, plan, text: "\(plan.ref) rejected: gate \(ask.ref) was rescinded", now: now)
            }
            // Rejecting a plan rejects its sprint and frees its items (`applySprintPlanEffects`); the leads of active sprints are told.
            try tellLeadsGateRescinded(db, gate: ask, now: now)
        case .release:
            let text = "Release \(ask.ref) was rescinded; roll back the release."
            var told: Set<String> = []
            if told.insert(ask.requesterId).inserted { try tell(db, companyId: ask.companyId, agentId: ask.requesterId, text: text, now: now) }
            if let company = try Company.fetchOne(db, key: ask.companyId), let pack = catalog.pack(company.packId) {
                let roles = pack.rolesCovering("cto")
                let ctos = try Agent.filter(Column("companyId") == ask.companyId && roles.contains(Column("role")) && Column("state") != "killed")
                    .order(Column("createdAt"), Column.rowID).fetchAll(db)
                for a in ctos where told.insert(a.id).inserted { try tell(db, companyId: ask.companyId, agentId: a.id, text: text, now: now) }
            }
        case .sprintPlan:
            try reverseSprintPlan(db, ask: ask, now: now)
        case .deploy:
            try reverseDeployEffects(db, ask: ask, now: now)
        case .grant:
            // The access it granted is gone from the next turn.
            try revokeGrants(db, askId: ask.id, now: now)
        case .other:
            // The engine's Simulator ask (Plan 4a): the iOS preview loses the owner's approval.
            try reverseSimulatorApproval(db, ask: ask, now: now)
        default:
            break
        }
    }

    // MARK: Engine alerts

    static func engineAlertKey(_ reason: String) -> String { "hold:\(reason)" }

    /// Files one unresolved `engineAlert` ask per reason in the company (a repeat changes nothing). Runs in the caller's transaction
    /// and sends no DM of its own (`EngineAlerts.raise` has).
    func fileEngineAlert(_ db: Database, company: Company, reason: String, text: String, now: Date) throws {
        try Store.fileEngineAlert(db, company: company, reason: reason, text: text, now: now)
    }

    /// `fileEngineAlert` without a store (a restore writes into a database no store has open yet).
    static func fileEngineAlert(_ db: Database, company: Company, reason: String, text: String, now: Date) throws {
        let key = Store.engineAlertKey(reason)
        let open = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert
                                  && Column("status") == AskStatus.pendingOwner.rawValue && Column("subjectId") == key).fetchCount(db)
        guard open == 0 else { return }
        let active = try Store.activeNow(db: db, companyId: company.id)
        let number = try Store.nextAskNumber(db: db, companyId: company.id)
        let summary = Store.stripControls(text, keepNewlines: true)
        var ask = Ask(id: UUID().uuidString, companyId: company.id, number: number, kind: .engineAlert, risk: .defaultFor(.engineAlert),
                      requesterId: "system", title: Store.flat(text, max: Store.maxAskTitle), summary: summary, status: .pendingOwner,
                      createdActive: active, statusSinceActive: active, createdAt: now, updatedAt: now)
        ask.subjectId = key
        // The raise already DMed the owner and logged the alert; the ask only puts it in the Inbox.
        try ask.insert(db)
    }

    /// The hold for these reasons is over: their unresolved alerts answer themselves with "resolved".
    func resolveEngineAlerts(_ db: Database, reasons: [String], now: Date) throws {
        let keys = reasons.map(Store.engineAlertKey)
        let alerts = try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                                    && keys.contains(Column("subjectId"))).order(Column("companyId"), Column("number")).fetchAll(db)
        for var ask in alerts {
            ask.ownerNote = "resolved"
            ask.ownerAnswer = "resolved"
            try settle(db, ask: &ask, status: .answered, decidedBy: "system", tellRequesterToo: false, now: now)
        }
    }
}
