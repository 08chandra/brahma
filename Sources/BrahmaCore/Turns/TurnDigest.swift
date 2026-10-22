import Foundation
import GRDB

/// Everything the turn-start orientation is built from, read from the store and the workspace. Plain data: `TurnDigest.render`
/// turns it into text without touching either.
public struct TurnContext {
    public struct RosterEntry: Equatable, Sendable { public var handle: String; public var role: String; public var state: AgentState }

    public var roleCard: String
    /// The playbook of the current item's type in the agent's role template (`Playbook (<type>):`), if there is one.
    public var playbook: (type: String, text: String)?
    public var manager: String?
    public var reports: [String]
    public var team: String?
    public var roster: [RosterEntry]
    public var item: WorkItem?
    public var lease: WorkLease?
    public var leaseUntil: Date?
    public var worktreePath: String?
    public var recentCommits: [String]
    public var latestRun: VerificationRun?
    public var progressPath: String?
    public var latestHandoffPath: String?
    public var pendingReviewCount: Int
    public var notices: [PendingNotice]
    public var collapsedNotices: Int
    public var inbox: [(InboxItem, Message, Channel)]
    public var channelCounts: [(channel: String, count: Int)]
    public var handles: [String: String]
    public var timeZone: TimeZone
    /// The reviewer's notes when the item came back with changes requested (full text).
    public var reviewNotes: String?
    /// The newest plan recorded for the item (a plan turn's result).
    public var plan: String?
    /// The agent's own asks that are still open.
    public var openAsks: [Ask]
    /// Summaries of the last turns of this scope, oldest first, for a session that starts over.
    public var recentSummaries: [String]
    /// What the engine delivers when the turn succeeds.
    public var inboxItemIds: [Int64]
    public var quietItemIds: [Int64]
    public var noticeIds: [Int64]
    /// Set by the orchestrator when the session starts over: the Continuity block is rendered.
    public var fresh: Bool = false

    public var scope: SessionScope { item.map { .item($0.id) } ?? .base }

    /// True when only non-waking notices (nothing to answer) were delivered: a notice turn.
    public var onlyNotices: Bool { inbox.isEmpty && quietItemIds.isEmpty && !noticeIds.isEmpty }

    /// Reads the orientation inputs of one agent's next work turn. A git failure gives no commits, never an error.
    public static func load(store: Store, paths: BrahmaPaths, agent: Agent, company: Company) throws -> TurnContext {
        let template = store.catalog.template(role: agent.role, pack: company.packId)
        let card = (try? RoleCards.load(paths: paths, agent: agent, company: company, template: template))
            ?? String(template.prompt.prefix(RoleCards.maxChars))
        let everyone = try store.agents(companyId: company.id)
        let handles = Dictionary(everyone.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let live = everyone.filter { $0.state != .killed }
        let manager = agent.managerId.flatMap { id in live.first { $0.id == id }?.name }
        let reports = live.filter { $0.managerId == agent.id }.map(\.name).sorted()
        let roster = live.filter { $0.id != agent.id }.sorted { $0.name < $1.name }
            .map { RosterEntry(handle: $0.name, role: $0.role, state: $0.state) }

        let inbox = try store.pendingInbox(agentId: agent.id)
        let quiet = try store.pendingQuietItems(agentId: agent.id)
        let batch = try store.noticeBatch(agentId: agent.id, limit: WorkNoticeDigest.maxNotices)

        var item: WorkItem?
        let lease = try store.lease(agentId: agent.id)
        if let lease { item = try store.workItem(id: lease.itemId) } else { item = try store.currentItemWithoutLease(agentId: agent.id) }

        var c = TurnContext(
            roleCard: card, playbook: nil, manager: manager, reports: reports, team: agent.team, roster: roster, item: item,
            lease: lease, leaseUntil: nil, worktreePath: nil, recentCommits: [], latestRun: nil, progressPath: nil,
            latestHandoffPath: nil, pendingReviewCount: try store.pendingReviews(agentId: agent.id).count,
            notices: batch.shown, collapsedNotices: batch.collapsedIds.count, inbox: inbox,
            channelCounts: Store.channelCounts(quiet), handles: handles, timeZone: store.ownerTimeZone(), reviewNotes: nil, plan: nil,
            openAsks: try store.asks(companyId: company.id, statuses: [.pendingInternal, .pendingOwner])
                .filter { $0.requesterId == agent.id }.prefix(TurnDigest.maxAsks).map { $0 },
            recentSummaries: [], inboxItemIds: inbox.compactMap(\.0.id), quietItemIds: quiet.map(\.id), noticeIds: batch.deliveredIds)
        c.recentSummaries = (try? store.recentTurnSummaries(agentId: agent.id, scope: c.scope)) ?? []

        guard let item else { return c }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = store.gitWorkspace(root: workspace, companyId: company.id)
        if let text = template.playbooks[item.type.rawValue], !text.isEmpty { c.playbook = (item.type.rawValue, text) }
        if let lease {
            c.leaseUntil = lease.expiresAt(activeNow: store.activeNow(companyId: company.id), now: Store.now())
            c.worktreePath = git.worktreePath(key: item.key).path
        }
        c.recentCommits = (try? git.log(base: GitWorkspace.mainRef, head: git.branchRef(key: item.key), limit: TurnDigest.maxCommits)) ?? []
        c.latestRun = try store.latestVerification(itemId: item.id)
        c.progressPath = ProgressFile.path(workspace: workspace, key: item.key).path
        c.latestHandoffPath = try store.latestHandoff(itemId: item.id)?.path
        let events = try store.itemEvents(itemId: item.id, limit: 200)
        if let returned = events.last(where: { $0.kind == .changesRequested }),
           !events.contains(where: { $0.kind == .submitted && ($0.id ?? 0) > (returned.id ?? 0) }) {
            c.reviewNotes = returned.text
        }
        c.plan = events.last(where: { $0.kind == .planWritten })?.text
        return c
    }
}

/// The text a work turn starts with: who you are, what you are working on, what changed. Everything an agent wrote is either
/// flattened to one line or a quoted block (`    | ` before every line), so it can never look like a heading or an instruction.
public enum TurnDigest {
    public static let maxRoleCard = 6000
    public static let maxCriteria = 1500
    public static let maxTailLines = 20
    public static let maxCommits = 5
    public static let maxRoster = 40
    public static let maxPlaybook = 2500
    public static let maxPlan = 2500
    public static let maxSummary = 1000
    public static let maxAsks = 10
    public static let maxReports = 20
    static let maxReviewNotes = 8192

    public static func render(_ c: TurnContext, agent: Agent, company: Company) -> String {
        var out: [String] = ["# Orientation"]
        out.append("Role card (re-read from file every turn):")
        out.append(ReviewDigest.quote(c.roleCard, maxChars: maxRoleCard))
        out.append("Operating rules:")
        out.append(OperatingRules.text)
        if let playbook = c.playbook {
            out.append("Playbook (\(ReviewDigest.flat(playbook.type, max: 40))):")
            out.append(ReviewDigest.quote(playbook.text, maxChars: maxPlaybook))
        }

        let reports = c.reports.prefix(maxReports).map { "@\($0)" }.joined(separator: ", ")
        let more = c.reports.count > maxReports ? " and \(c.reports.count - maxReports) more" : ""
        out.append("Org: you report to @\(c.manager ?? "owner") · reports: \(c.reports.isEmpty ? "none" : reports + more)"
                   + " · team: \(c.team.map { ReviewDigest.flat($0, max: 60) } ?? "none")")
        out.append("Team roster:")
        if c.roster.isEmpty { out.append("- (nobody else yet)") }
        for r in c.roster.prefix(maxRoster) {
            out.append("- @\(r.handle) — \(ReviewDigest.flat(r.role, max: 40)) — \(r.state.rawValue)")
        }
        if c.roster.count > maxRoster { out.append("(\(c.roster.count - maxRoster) more: use list_agents)") }

        out.append("## Current work")
        if let item = c.item { out += currentWork(item, c) } else {
            out.append("No current item. Use list_work and claim_lease to pick up Ready work.")
        }
        if c.fresh, let block = continuity(c) { out.append(block) }

        if c.pendingReviewCount > 0 {
            out.append("## Reviews waiting for you: \(c.pendingReviewCount) (each runs in its own review turn)")
        }
        if let work = WorkNoticeDigest.render(c.notices, collapsed: c.collapsedNotices, handles: c.handles) {
            var lines = work.components(separatedBy: "\n")
            lines[0] = "## " + (lines[0].hasSuffix(":") ? String(lines[0].dropLast()) : lines[0])
            out.append(lines.joined(separator: "\n"))
        }
        // With only work updates there is no "nothing new" line.
        if !(c.inbox.isEmpty && c.channelCounts.isEmpty && !c.notices.isEmpty) {
            out.append("# Inbox")
            out.append(InboxDigest.render(agent: agent, company: company, items: c.inbox, handles: c.handles, unread: c.channelCounts))
        }
        return out.joined(separator: "\n")
    }

    private static func currentWork(_ item: WorkItem, _ c: TurnContext) -> [String] {
        let zone = c.timeZone
        var out: [String] = []
        var head = "\(item.key) · \(ReviewDigest.flat(item.type.rawValue, max: 40)) · tier \(item.tier.label) · \(item.status.title)"
        if let until = c.leaseUntil { head += " · lease until \(ReviewDigest.clock(until, zone))" }
        out.append(head)
        out.append("Title: \(ReviewDigest.flat(item.title, max: 200))")
        out.append("Acceptance criteria:")
        out.append(ReviewDigest.quote(item.acceptanceCriteria, maxChars: maxCriteria))
        if let spec = item.checkSpec {
            out.append("Check (rev \(item.checkRevision)): \(ReviewDigest.flat(spec.command, max: 400)) — last run: \(runText(c.latestRun, zone))")
            if let run = c.latestRun, run.status == .failed || run.status == .timedOut || run.status == .error {
                out.append(ReviewDigest.quote(tail(run.outputTail ?? ""), maxChars: Store.tailLimit, empty: "(no output)"))
            }
        } else {
            out.append("Check: none")
        }
        if let path = c.worktreePath {
            out.append("Worktree: \(path) (branch item/\(item.key))")
        } else {
            out.append("Lease: none (claim_lease before changing files)")
        }
        out.append("Recent commits:")
        if c.recentCommits.isEmpty {
            out.append(ReviewDigest.quote("", maxChars: 10, empty: "(none)"))
        } else {
            out.append(c.recentCommits.prefix(maxCommits).map { ReviewDigest.quote(ReviewDigest.flat($0, max: 200), maxChars: 400) }
                .joined(separator: "\n"))
        }
        if let path = c.progressPath { out.append("Progress file: \(path)") }
        out.append("Latest hand-off: \(c.latestHandoffPath ?? "none")")
        if !item.reviewFlags.isEmpty {
            out.append("Review flags: \(item.reviewFlags.prefix(10).map { ReviewDigest.flat($0, max: 200) }.joined(separator: "; "))")
        }
        if item.status == .blocked {
            out.append("Blocked: \(ReviewDigest.flat(item.blockedReason ?? "no reason given", max: 300))")
        }
        if let notes = c.reviewNotes {
            out.append("Review feedback (changes requested; address every point):")
            out.append(ReviewDigest.quote(notes, maxChars: maxReviewNotes))
        }
        return out
    }

    private static func continuity(_ c: TurnContext) -> String? {
        var out: [String] = []
        for (i, s) in c.recentSummaries.suffix(3).enumerated() {
            out.append("Earlier turn \(i + 1) of \(min(c.recentSummaries.count, 3)) (oldest first):")
            out.append(ReviewDigest.quote(String(ReviewDigest.clean(s).suffix(maxSummary)), maxChars: maxSummary))
        }
        if let plan = c.plan {
            out.append("Plan:")
            out.append(ReviewDigest.quote(plan, maxChars: maxPlan))
        }
        if !c.openAsks.isEmpty {
            out.append("Your open asks:")
            for a in c.openAsks.prefix(maxAsks) {
                out.append("- \(a.ref) · \(ReviewDigest.flat(a.kind.rawValue, max: 40)) · \(a.status.rawValue) · \(ReviewDigest.flat(a.title, max: 200))")
            }
        }
        guard !out.isEmpty else { return nil }
        var head = ["Continuity: your previous session ended; this one starts fresh. The files are the truth; read them before you act."]
        if let path = c.progressPath { head.append("Progress file: \(path)") }
        return (head + out).joined(separator: "\n")
    }

    private static func runText(_ run: VerificationRun?, _ zone: TimeZone) -> String {
        guard let run else { return "none" }
        let status: String
        switch run.status {
        case .passed: status = "passed"
        case .failed: status = "failed" + (run.exitCode.map { " (exit \($0))" } ?? "")
        case .timedOut: status = "timed out"
        case .inconclusive: status = "inconclusive"
        case .running: status = "running"
        case .queued: status = "queued"
        case .error: status = "error"
        }
        guard let at = run.finishedAt ?? run.startedAt else { return status }
        return status + " at " + ReviewDigest.clock(at, zone)
    }

    private static func tail(_ text: String) -> String {
        var lines = ReviewDigest.clean(text).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.suffix(maxTailLines).map { String($0.prefix(300)) }.joined(separator: "\n")
    }
}

extension Store {
    /// The agent's newest assigned item that is in progress or blocked, for an agent that holds no lease.
    func currentItemWithoutLease(agentId: String) throws -> WorkItem? {
        try writer.read { db in
            try WorkItem.fetchOne(db, sql: """
                SELECT * FROM workItem WHERE ownerId = ? AND status IN ('inProgress', 'blocked')
                ORDER BY updatedAt DESC, number DESC LIMIT 1
                """, arguments: [agentId])
        }
    }
}
