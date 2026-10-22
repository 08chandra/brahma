import Foundation
import GRDB

/// Sprints: planning (a `sprintPlan` ask), the ask's effects, completion by cadence, active-time timeboxes, engine standups
/// and closing with a review summary and retro lessons. Every duration is company-active time; standups and posts are
/// system messages, which never wake anybody, while DMs to the lead do.
extension Store {
    static let maxSprintGoal = 500
    static let maxSprintItems = 200
    static let maxSprintSummary = 4000
    static let maxSprintLessons = 4000

    // MARK: Queries

    /// Sprints of a company, oldest first, optionally only some statuses.
    public func sprints(companyId: String, statuses: Set<SprintStatus>? = nil) throws -> [Sprint] {
        try writer.read { db in
            var request = Sprint.filter(Column("companyId") == companyId).order(Column("number"))
            if let statuses { request = request.filter(statuses.map(\.rawValue).contains(Column("status"))) }
            return try request.fetchAll(db)
        }
    }

    public func sprint(id: String) throws -> Sprint? {
        try writer.read { db in try Sprint.fetchOne(db, key: id) }
    }

    /// "Sprint 3", "sprint-3", "S3", "s-3" or "3", within one company.
    public func sprint(companyId: String, ref: String) throws -> Sprint? {
        var text = ref.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["sprint", "s"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        text = String(text.drop { $0 == " " || $0 == "-" || $0 == "_" })
        guard let number = Int(text) else { return nil }
        return try writer.read { db in
            try Sprint.filter(Column("companyId") == companyId && Column("number") == number).fetchOne(db)
        }
    }

    /// The items committed to a sprint, by key number.
    public func sprintItems(sprintId: String) throws -> [WorkItem] {
        try writer.read { db in try Store.sprintItems(db, sprintId: sprintId) }
    }

    static func sprintItems(_ db: Database, sprintId: String) throws -> [WorkItem] {
        try WorkItem.filter(Column("sprintId") == sprintId).order(Column("number")).fetchAll(db)
    }

    public func sprintProgress(_ sprint: Sprint) throws -> SprintProgress {
        SprintProgress(items: try sprintItems(sprintId: sprint.id), milestoneItemId: sprint.milestoneItemId)
    }

    /// The active (or in-review) sprint an agent works in: its team's, else the company-wide one.
    public func currentSprint(companyId: String, team: String?) throws -> Sprint? {
        try writer.read { db in
            let live = [SprintStatus.active, .review].map(\.rawValue)
            if let team, let s = try Sprint.filter(Column("companyId") == companyId && Column("team") == team && live.contains(Column("status")))
                .order(Column("number").desc).fetchOne(db) { return s }
            return try Sprint.filter(Column("companyId") == companyId && Column("team") == nil && live.contains(Column("status")))
                .order(Column("number").desc).fetchOne(db)
        }
    }

    // MARK: Plan

    /// `plan_sprint`: commits items to a new sprint of a team (or the company) and files its `sprintPlan` ask. Gates block
    /// only irreversible work: with the PRD or architecture not yet approved the plan is still filed, its summary starts
    /// `Gates not yet approved: …` and it always needs the owner.
    public func planSprint(companyId: String, by sender: Sender, goal: String, itemKeys: [String], team: String? = nil,
                           cadence: CadenceKind? = nil, milestoneKey: String? = nil, now: Date = Store.now()) throws -> (Sprint, Ask) {
        try writer.write { db in
            let company = try requireCompany(db, companyId)
            guard case .agent = sender else { throw WorkError.invalid("sprints are planned by an agent with plan_sprint") }
            let actor = try resolveActor(db, sender, companyId: companyId)
            guard actor.isLead else { throw WorkError.forbidden("plan_sprint is for managers and executives") }
            let cleanGoal = Store.flat(goal, max: Store.maxSprintGoal)
            guard !cleanGoal.isEmpty else { throw WorkError.invalid("the goal is empty") }
            let team = try Store.validTeam(team)
            let open = SprintStatus.open.map(\.rawValue)
            let scope = Sprint.filter(Column("companyId") == companyId && open.contains(Column("status")))
            if let existing = try (team.map { scope.filter(Column("team") == $0) } ?? scope.filter(Column("team") == nil)).fetchOne(db) {
                throw WorkError.conflict("\(existing.name) is still open for \(team ?? "the company")")
            }
            let kind = cadence ?? company.cadence
            let milestone = milestoneKey.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
            if kind == .milestone, milestone == nil { throw WorkError.invalid("a milestone needs milestone_key") }

            var keys: [String] = []
            for raw in itemKeys + (milestone.map { [$0] } ?? []) {
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if !key.isEmpty, !keys.contains(key) { keys.append(key) }
            }
            guard !keys.isEmpty else { throw WorkError.invalid("plan_sprint needs at least one item") }
            guard keys.count <= Store.maxSprintItems else { throw WorkError.invalid("a sprint holds at most \(Store.maxSprintItems) items") }
            var items: [WorkItem] = []
            for key in keys {
                guard let item = try WorkItem.filter(Column("companyId") == companyId && Column("key") == key).fetchOne(db) else {
                    throw WorkError.notFound("unknown item \(Store.flat(key, max: 40))")
                }
                guard item.status != .done else { throw WorkError.conflict("\(item.key) is done") }
                if let sid = item.sprintId, let other = try Sprint.fetchOne(db, key: sid), other.status.isOpen {
                    throw WorkError.conflict("\(item.key) is already in \(other.name)")
                }
                items.append(item)
            }

            var missing: [String] = []
            if try !Store.hasApproved(db: db, companyId: companyId, kind: .prd) { missing.append("PRD") }
            if try !Store.hasApproved(db: db, companyId: companyId, kind: .architecture) { missing.append("Architecture") }

            let number = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) + 1 FROM sprint WHERE companyId = ?",
                                           arguments: [companyId])) ?? 1
            var sprint = Sprint(id: UUID().uuidString, companyId: companyId, number: number, team: team, goal: cleanGoal, cadence: kind,
                                status: .pendingApproval,
                                milestoneItemId: milestone.flatMap { m in items.first { $0.key == m }?.id },
                                askId: nil, createdAt: now, leadId: actor.id)
            try sprint.insert(db)
            for var item in items {
                item.sprintId = sprint.id
                item.updatedAt = now
                try item.update(db, columns: ["sprintId", "updatedAt"])
                try recordItemEvent(db: db, item: item, actor: actor.id, kind: .sprintChanged, text: "added to \(sprint.name)", now: now)
            }

            var summary: [String] = []
            if !missing.isEmpty { summary.append("Gates not yet approved: \(missing.joined(separator: ", ")).") }
            summary.append("Goal: \(cleanGoal)")
            summary.append("Team: \(team ?? "company") · cadence: \(kind.rawValue)"
                           + (milestone.map { " · milestone: \($0)" } ?? "")
                           + " · timebox: \(sprint.timeboxDays) active days or \(sprint.timeboxTurns) team turns")
            summary.append("Items (\(items.count)):")
            summary += items.map { "- \($0.key) \(Store.flat($0.title, max: 120))" }
            let ask = try propose(db: db, companyId: companyId, by: sender, kind: .sprintPlan, risk: nil, category: nil,
                                  title: "\(sprint.name): \(Store.flat(cleanGoal, max: 180))", summary: summary.joined(separator: "\n"),
                                  payload: nil, document: nil, itemId: nil, subjectId: sprint.id, supersedes: nil, requestId: nil,
                                  decisionClass: missing.isEmpty ? .taste : .goalChanging, viaOwner: false, now: now)
            sprint.askId = ask.id
            try sprint.update(db)
            try ActivityEvent(companyId: companyId, agentId: actor.id, turnId: nil, kind: .work,
                              text: "\(sprint.name) planned by @\(actor.handle) (\(ask.ref), \(items.count) items)", createdAt: now).insert(db)
            return (sprint, ask)
        }
    }

    // MARK: Ask effects

    /// A `sprintPlan` ask reached a final status: approved starts the sprint, rejected or expired frees its items.
    func applySprintPlanEffects(_ db: Database, ask: Ask, now: Date) throws {
        guard var sprint = try Sprint.filter(Column("askId") == ask.id).fetchOne(db), sprint.companyId == ask.companyId,
              sprint.status == .pendingApproval else { return }
        switch ask.status {
        case .approved:
            sprint.status = .active
            sprint.startedAt = now
            sprint.startedActive = try Store.activeNow(db: db, companyId: sprint.companyId)
            try sprint.update(db)
            let items = try Store.sprintItems(db, sprintId: sprint.id)
            for item in items where item.status == .backlog {
                _ = try engineSetStatus(db: db, itemId: item.id, to: .ready, text: "Backlog → Ready (\(sprint.name) started)", now: now)
            }
            try sprintPost(db, sprint, text: "\(sprint.name) started: \(sprint.goal) (\(items.count) items)", now: now)
            try checkSprintComplete(db, sprintId: sprint.id, now: now)
        case .rejected, .expired:
            sprint.status = .rejected
            sprint.closedAt = now
            sprint.summary = "plan \(ask.ref) \(ask.status.rawValue)"
            try sprint.update(db)
            try releaseSprintItems(db, sprint, text: "removed from \(sprint.name) (plan \(ask.status.rawValue))", toBacklog: false, now: now)
        default:
            break
        }
    }

    /// The owner rescinded an approved sprint plan: the sprint closes as cancelled and its unfinished items go back to the
    /// backlog (work already started is left as it is).
    func reverseSprintPlan(_ db: Database, ask: Ask, now: Date) throws {
        guard var sprint = try Sprint.filter(Column("askId") == ask.id).fetchOne(db), sprint.companyId == ask.companyId,
              sprint.status.isOpen else { return }
        sprint.status = .closed
        sprint.closedAt = now
        sprint.summary = "cancelled: \(ask.ref) rescinded by the owner"
        try sprint.update(db)
        try releaseSprintItems(db, sprint, text: "removed from \(sprint.name) (\(ask.ref) rescinded)", toBacklog: true, now: now)
        try sprintPost(db, sprint, text: "\(sprint.name) was cancelled: \(ask.ref) was rescinded by the owner", now: now)
    }

    /// A PRD or architecture approval no longer stands: the leads of active sprints are told (pending plans were already
    /// rejected by the caller).
    func tellLeadsGateRescinded(_ db: Database, gate: Ask, now: Date) throws {
        let live = [SprintStatus.active, .review].map(\.rawValue)
        let text = "\(gate.ref) (\(gate.kind.title)) was rescinded; new sprint plans need the owner until a new one is approved."
        var told: Set<String> = []
        for sprint in try Sprint.filter(Column("companyId") == gate.companyId && live.contains(Column("status"))).order(Column("number")).fetchAll(db) {
            guard let lead = try sprintLead(db, sprint), told.insert(lead.id).inserted else { continue }
            try alert(db: db, companyId: gate.companyId, agentId: lead.id, text: text, now: now)
        }
    }

    /// Clears `sprintId` on the sprint's unfinished items (done ones keep it as history); `toBacklog` also moves `ready` ones back.
    private func releaseSprintItems(_ db: Database, _ sprint: Sprint, text: String, toBacklog: Bool, now: Date) throws {
        for var item in try Store.sprintItems(db, sprintId: sprint.id) where item.status != .done {
            item.sprintId = nil
            item.updatedAt = now
            try item.update(db, columns: ["sprintId", "updatedAt"])
            try recordItemEvent(db: db, item: item, actor: "system", kind: .sprintChanged, text: text, now: now)
            if toBacklog, item.status == .ready {
                _ = try engineSetStatus(db: db, itemId: item.id, to: .backlog, text: "Ready → Backlog (\(sprint.name) cancelled)", now: now)
            }
        }
    }

    // MARK: Completion and timeboxes

    /// Runs from `completeItem`: an active sprint whose cadence is now complete moves to review and its lead is told.
    func sprintItemCompleted(_ db: Database, item: WorkItem, now: Date) throws {
        guard let sid = item.sprintId else { return }
        try checkSprintComplete(db, sprintId: sid, now: now)
    }

    private func checkSprintComplete(_ db: Database, sprintId: String, now: Date) throws {
        guard let sprint = try Sprint.fetchOne(db, key: sprintId), sprint.status == .active else { return }
        let progress = SprintProgress(items: try Store.sprintItems(db, sprintId: sprint.id), milestoneItemId: sprint.milestoneItemId)
        guard Cadences.of(sprint.cadence).isComplete(progress) else { return }
        try moveToReview(db, sprint, why: "complete",
                         text: "\(sprint.name) is complete. Call close_sprint with the review summary and retro lessons.", now: now)
    }

    private func moveToReview(_ db: Database, _ sprint: Sprint, why: String, text: String, now: Date) throws {
        var s = sprint
        s.status = .review
        try s.update(db)
        try ActivityEvent(companyId: s.companyId, agentId: nil, turnId: nil, kind: .work, text: "\(s.name) is in review (\(why))",
                          createdAt: now).insert(db)
        if let lead = try sprintLead(db, s) { try alert(db: db, companyId: s.companyId, agentId: lead.id, text: text, now: now) }
    }

    /// Who is told about the sprint: whoever planned it, else a live manager of its team.
    func sprintLead(_ db: Database, _ sprint: Sprint) throws -> Agent? {
        if let id = sprint.leadId, let a = try Agent.fetchOne(db, key: id), a.companyId == sprint.companyId, a.state != .killed { return a }
        guard let team = sprint.team, let company = try Company.fetchOne(db, key: sprint.companyId) else { return nil }
        let members = try Agent.filter(Column("companyId") == sprint.companyId && Column("team") == team && Column("state") != "killed")
            .order(Column("createdAt"), Column.rowID).fetchAll(db)
        return members.first { catalog.template(role: $0.role, pack: company.packId).kind == .manager }
    }

    /// Work turns of the sprint's team (every agent for a company sprint) since it started. Infrastructure failures, reset
    /// sessions, usage limits and review turns don't count.
    static func sprintTeamTurns(_ db: Database, _ sprint: Sprint) throws -> Int {
        guard let started = sprint.startedAt else { return 0 }
        var sql = """
            SELECT COUNT(*) FROM turn JOIN agent ON agent.id = turn.agentId
            WHERE turn.companyId = ? AND turn.kind = 'work' AND turn.infra = 0 AND turn.sessionResetReason IS NULL
              AND turn.outcome IN ('succeeded', 'failed') AND turn.startedAt >= ?
            """
        var args: [DatabaseValueConvertible] = [sprint.companyId, started]
        if let team = sprint.team { sql += " AND agent.team = ?"; args.append(team) }
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
    }

    /// The tick's timebox pass: an active sprint past `timeboxDays` active days, or `timeboxTurns` team work turns since it
    /// started, moves to review and its lead is asked to close it. Returns how many moved.
    @discardableResult
    public func enforceTimeboxes(now: Date = Store.now()) throws -> Int {
        try writer.write { db in
            var moved = 0
            for sprint in try Sprint.filter(Column("status") == SprintStatus.active.rawValue).order(Column("companyId"), Column("number")).fetchAll(db) {
                let active = try Store.activeNow(db: db, companyId: sprint.companyId)
                let reason: String
                if active - (sprint.startedActive ?? active) >= Double(sprint.timeboxDays) * Sprint.day {
                    reason = "\(sprint.timeboxDays) active days"
                } else if try Store.sprintTeamTurns(db, sprint) >= sprint.timeboxTurns {
                    reason = "\(sprint.timeboxTurns) team turns"
                } else {
                    continue
                }
                try moveToReview(db, sprint, why: "timebox: \(reason)",
                                 text: "\(sprint.name) reached its timebox (\(reason)). Call close_sprint; unfinished items carry over.", now: now)
                moved += 1
            }
            return moved
        }
    }

    // MARK: Standups

    /// The tick's standup pass: every active sprint whose last standup (or start) is `Sprint.standupInterval` active seconds
    /// ago gets one system post in its team channel (or #general), built from item events. No LLM turn runs and nobody wakes.
    @discardableResult
    public func postStandups(now: Date = Store.now()) throws -> Int {
        try writer.write { db in
            var posted = 0
            for var sprint in try Sprint.filter(Column("status") == SprintStatus.active.rawValue).order(Column("companyId"), Column("number")).fetchAll(db) {
                let active = try Store.activeNow(db: db, companyId: sprint.companyId)
                let since = sprint.lastStandupActive ?? sprint.startedActive ?? active
                guard active - since >= Sprint.standupInterval else { continue }
                try sprintPost(db, sprint, text: try standupText(db, sprint, since: since), now: now)
                sprint.lastStandupActive = active
                try sprint.update(db)
                posted += 1
            }
            return posted
        }
    }

    func standupText(_ db: Database, _ sprint: Sprint, since: Double) throws -> String {
        let items = try Store.sprintItems(db, sprintId: sprint.id)
        let progress = SprintProgress(items: items, milestoneItemId: sprint.milestoneItemId)
        var members = Agent.filter(Column("companyId") == sprint.companyId && Column("state") != "killed")
        if let team = sprint.team { members = members.filter(Column("team") == team) }
        var lines = ["Standup — \(sprint.scopeLabel) — \(sprint.name) (\(progress.done)/\(progress.total) done)"]
        for agent in try members.order(Column("createdAt"), Column.rowID).fetchAll(db) {
            let mine = items.filter { $0.ownerId == agent.id }
            var done: [String] = []
            for item in mine where item.status == .done {
                let at = try Double.fetchOne(db, sql: """
                    SELECT MAX(createdActive) FROM workItemEvent WHERE itemId = ? AND kind IN ('merged', 'statusChanged')
                    """, arguments: [item.id]) ?? -.infinity
                if at >= since { done.append(item.key) }
            }
            var working: [String] = []
            for item in mine where item.status == .inProgress || item.status == .inReview {
                working.append(try Store.standupState(db, item).map { "\(item.key) (\($0))" } ?? item.key)
            }
            let blocked = mine.filter { $0.status == .blocked }.map { item -> String in
                let why = Store.flat(item.blockedReason ?? "", max: 80)
                return why.isEmpty ? item.key : "\(item.key) (\(why))"
            }
            if done.isEmpty, working.isEmpty, blocked.isEmpty {
                lines.append("@\(agent.name) — no item activity")
                continue
            }
            func list(_ keys: [String]) -> String { keys.isEmpty ? "none" : keys.joined(separator: ", ") }
            lines.append("@\(agent.name) — done: \(list(done)) · in progress: \(list(working)) · blocked: \(list(blocked))")
        }
        return lines.joined(separator: "\n")
    }

    /// What an in-progress or in-review item is waiting on, from its latest relevant event.
    private static func standupState(_ db: Database, _ item: WorkItem) throws -> String? {
        if item.status == .inReview { return item.mergeState == .none ? "in review" : "merging" }
        let kinds: [WorkEventKind] = [.verificationFailed, .verificationPassed, .submitted, .changesRequested, .leaseClaimed,
                                      .mergeConflict, .mergeFailed]
        let last = try WorkItemEvent.filter(Column("itemId") == item.id && kinds.map(\.rawValue).contains(Column("kind")))
            .order(Column("id").desc).fetchOne(db)
        switch last?.kind {
        case .verificationFailed?: return "check failed"
        case .changesRequested?: return "changes requested"
        case .mergeConflict?: return "merge conflict"
        case .mergeFailed?: return "merge failed"
        default: return nil
        }
    }

    /// A non-waking system post in the sprint's team channel, or #general when there is none.
    private func sprintPost(_ db: Database, _ sprint: Sprint, text: String, now: Date) throws {
        var channel = "general"
        if let team = sprint.team,
           try Channel.filter(Column("companyId") == sprint.companyId && Column("name") == "team-\(team)").fetchCount(db) > 0 {
            channel = "team-\(team)"
        }
        _ = try MessageRouter(store: self).post(db: db, companyId: sprint.companyId, channel: channel, from: .system, text: text, now: now)
    }

    // MARK: Close

    /// `close_sprint` (a manager or executive, on an `active` or `review` sprint): closes it with the summary
    /// `"<name> closed: <d> of <t> items done. Carried over: <KEYs|none>."` and the agent's text, posts that to #general,
    /// carries unfinished items over (their `sprintId` cleared) and appends the lessons to the team's notes file.
    @discardableResult
    public func closeSprint(sprintId: String, by sender: Sender, summary: String, lessons: String, now: Date = Store.now()) throws -> Sprint {
        let agentSummary = try Store.limitedText(summary, Store.maxSprintSummary, "the summary")
        let lessonText = try Store.limitedText(lessons, Store.maxSprintLessons, "the lessons")
        let (sprint, workspace) = try writer.write { db -> (Sprint, String) in
            guard var sprint = try Sprint.fetchOne(db, key: sprintId) else { throw WorkError.notFound("no such sprint") }
            let actor = try resolveActor(db, sender, companyId: sprint.companyId)
            guard actor.isLead || actor.privileged else { throw WorkError.forbidden("close_sprint is for managers and executives") }
            guard sprint.status == .active || sprint.status == .review else {
                throw WorkError.conflict("\(sprint.name) is \(sprint.status.rawValue)")
            }
            let company = try requireCompany(db, sprint.companyId)
            let items = try Store.sprintItems(db, sprintId: sprint.id)
            let done = items.filter { $0.status == .done }
            let carried = items.filter { $0.status != .done }
            let head = "\(sprint.name) closed: \(done.count) of \(items.count) items done. Carried over: "
                + (carried.isEmpty ? "none" : carried.map(\.key).joined(separator: ", ")) + "."
            sprint.status = .closed
            sprint.closedAt = now
            sprint.summary = agentSummary.map { head + "\n" + $0 } ?? head
            try sprint.update(db)
            try releaseSprintItems(db, sprint, text: "carried over from \(sprint.name)", toBacklog: false, now: now)
            _ = try MessageRouter(store: self).post(db: db, companyId: sprint.companyId, channel: "general", from: .system,
                                                    text: sprint.summary ?? head, now: now)
            try ActivityEvent(companyId: sprint.companyId, agentId: actor.id == "owner" ? nil : actor.id, turnId: nil, kind: .work,
                              text: head, createdAt: now).insert(db)
            return (sprint, company.workspacePath)
        }
        if let lessonText {
            let lines = lessonText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { line -> String in
                    var l = line
                    if l.hasPrefix("- ") || l.hasPrefix("* ") { l.removeFirst(2) }
                    return "- " + l
                }
            if !lines.isEmpty {
                let zone = ownerTimeZone()
                try NotesFile.append(path: NotesFile.path(workspace: URL(fileURLWithPath: workspace), team: sprint.team),
                                     heading: "\(sprint.name) retro — \(NotesFile.day(now, zone))", lines: lines, date: now, timeZone: zone)
            }
        }
        return sprint
    }
}
