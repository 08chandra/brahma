import Foundation
import GRDB

/// One point on the path to live (Plan L Task 13, v2 §4.9 scorecard). `name` is one of `CompanyMilestones.order`.
public struct Milestone: Equatable, Sendable {
    /// `goal | prd | architecture | firstMerge | firstPreview | live | firstPost`.
    public var name: String
    public var at: Date

    public init(name: String, at: Date) { self.name = name; self.at = at }

    /// The strip's label: `FIRST MERGE`, `LIVE`, …
    public var displayName: String { CompanyMilestones.displayNames[name] ?? name.uppercased() }
}

/// What a stretch between two milestones cost: the turns that started in it and what the owner had to do in it.
public struct MilestonePhase: Equatable, Sendable {
    public var from: String
    /// A milestone name, or `now` for the stretch after the latest milestone.
    public var to: String
    /// The sum of `turn.costUSD` over turns with `startedAt` in `[from.at, to.at)` (a nil cost counts 0).
    public var costLE: Double
    /// Owner touches in `(from.at, to.at]`: asks the owner decided, answered, rescinded or replanned (`ownerDecidedAt`, which
    /// includes human tasks done or declined) and messages the owner sent. The end is inclusive so the decision that makes a
    /// milestone (the gate approval) counts toward the phase it closes.
    public var ownerTouches: Int

    public init(from: String, to: String, costLE: Double, ownerTouches: Int) {
        self.from = from; self.to = to; self.costLE = costLE; self.ownerTouches = ownerTouches
    }
}

public struct MilestoneReport: Equatable, Sendable {
    public var milestones: [Milestone]
    public var phases: [MilestonePhase]
    public var totalLE: Double
    public var totalTouches: Int

    public init(milestones: [Milestone], phases: [MilestonePhase], totalLE: Double, totalTouches: Int) {
        self.milestones = milestones; self.phases = phases; self.totalLE = totalLE; self.totalTouches = totalTouches
    }

    public static let empty = MilestoneReport(milestones: [], phases: [], totalLE: 0, totalTouches: 0)

    /// The goal's time (the company's creation), from which every offset is measured.
    public var goalAt: Date? { milestones.first { $0.name == "goal" }?.at ?? milestones.first?.at }

    /// `h:mm` from a number of seconds (never negative; hours grow past 24).
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 3600):" + String(format: "%02d", (total / 60) % 60)
    }

    /// `+h:mm` since the goal for a milestone (`0:00` for the goal itself).
    public func offset(_ m: Milestone) -> String {
        guard let goal = goalAt, m.name != "goal" else { return Self.elapsed(0) }
        return "+" + Self.elapsed(m.at.timeIntervalSince(goal))
    }

    public static func money(_ usd: Double) -> String { String(format: "$%.2f", usd) }

    /// `brahma milestones`: `goal           0:00`, then one line per phase named by the milestone that ends it
    /// (`prd           +0:52   $3.10   2 touches`; the last one is `now`), then `total $14.80, 7 owner touches`.
    public func lines(now: Date? = nil) -> [String] {
        guard let goal = goalAt else { return ["(no milestones yet)"] }
        var out = ["goal".padding(toLength: 14, withPad: " ", startingAt: 0) + " " + Self.elapsed(0)]
        let byName = Dictionary(milestones.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for phase in phases {
            let at: Date? = phase.to == "now" ? now : byName[phase.to]?.at
            let when = at.map { "+" + Self.elapsed($0.timeIntervalSince(goal)) } ?? "+?"
            out.append(phase.to.padding(toLength: 14, withPad: " ", startingAt: 0) + when + "   " + Self.money(phase.costLE)
                       + "   \(phase.ownerTouches) touches")
        }
        out.append("total \(Self.money(totalLE)), \(totalTouches) owner touches")
        return out
    }

    /// The Releases strip: `GOAL 0:00`, `PRD +0:52`, …, `LIVE +3:10`.
    public func chipTitles() -> [String] { milestones.map { "\($0.displayName) \(offset($0))" } }

    /// The strip's totals chip: `$14.80 · 7 TOUCHES`.
    public var totalsTitle: String { "\(Self.money(totalLE)) · \(totalTouches) TOUCHES" }
}

/// The scorecard, computed from existing rows (no table of its own):
/// - `goal`: the company's `createdAt`;
/// - `prd`, `architecture`: the first approved gate ask's `ownerDecidedAt` (under 3a's combined gate — a small company with no
///   architecture ask — both take the approved `prd` ask's time);
/// - `firstMerge`: the first `merged` item event;
/// - `firstPreview`: the first `.preview` activity saying a preview is running (`PreviewRunner`'s line);
/// - `live`: the first deployed release's `deployedAt`;
/// - `firstPost`: the first answered `launch-post` human task.
/// Missing milestones are left out. Phases run between consecutive milestones (sorted by time, ties in this order) and from
/// the latest one to `now`.
public enum CompanyMilestones {
    public static let order = ["goal", "prd", "architecture", "firstMerge", "firstPreview", "live", "firstPost"]
    public static let displayNames: [String: String] = [
        "goal": "GOAL", "prd": "PRD", "architecture": "ARCHITECTURE", "firstMerge": "FIRST MERGE", "firstPreview": "FIRST PREVIEW",
        "live": "LIVE", "firstPost": "FIRST POST",
    ]
    /// What `PreviewRunner` writes when a preview comes up: `Preview <name> running at <url>`.
    static let previewRunningMarker = " running at "

    public static func load(store: Store, companyId: String, now: Date) throws -> MilestoneReport {
        try store.writer.read { db in try load(db, companyId: companyId, now: now) }
    }

    static func load(_ db: Database, companyId: String, now: Date) throws -> MilestoneReport {
        guard let company = try Company.fetchOne(db, key: companyId) else { return .empty }
        var found: [String: Date] = ["goal": company.createdAt]

        func firstApproved(_ kind: AskKind) throws -> Date? {
            try Date.fetchOne(db, sql: "SELECT MIN(ownerDecidedAt) FROM ask WHERE companyId = ? AND kind = ? AND status = ? AND ownerDecidedAt IS NOT NULL",
                              arguments: [companyId, kind.rawValue, AskStatus.approved.rawValue])
        }
        let prd = try firstApproved(.prd)
        found["prd"] = prd
        if let arch = try firstApproved(.architecture) {
            found["architecture"] = arch
        } else if let prd, try Store.hasApproved(db: db, companyId: companyId, kind: .architecture) {
            found["architecture"] = prd
        }
        found["firstMerge"] = try Date.fetchOne(db, sql: "SELECT MIN(createdAt) FROM workItemEvent WHERE companyId = ? AND kind = ?",
                                                arguments: [companyId, WorkEventKind.merged.rawValue])
        found["firstPreview"] = try Date.fetchOne(
            db, sql: "SELECT MIN(createdAt) FROM activityEvent WHERE companyId = ? AND kind = ? AND text LIKE ? ESCAPE '\\'",
            arguments: [companyId, ActivityKind.preview.rawValue, "Preview %\(previewRunningMarker)%"])
        found["live"] = try Date.fetchOne(db, sql: "SELECT MIN(deployedAt) FROM release WHERE companyId = ? AND deployedAt IS NOT NULL",
                                          arguments: [companyId])
        let answered = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.humanTask.rawValue
                                      && Column("status") == AskStatus.answered.rawValue).order(Column("ownerDecidedAt")).fetchAll(db)
        found["firstPost"] = answered.first { HumanTask.from($0)?.template == .launchPost }?.ownerDecidedAt

        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let milestones = order.compactMap { name in found[name].map { Milestone(name: name, at: $0) } }
            .sorted { a, b in a.at != b.at ? a.at < b.at : (rank[a.name] ?? 0) < (rank[b.name] ?? 0) }

        func cost(_ from: Date, _ to: Date) throws -> Double {
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM turn WHERE companyId = ? AND startedAt >= ? AND startedAt < ?",
                                arguments: [companyId, from, to]) ?? 0
        }
        /// Touches in `(from, to]`; the first phase also takes its start, so a kickoff posted the moment the company was
        /// created counts.
        func touches(_ from: Date, _ to: Date, includeStart: Bool) throws -> Int {
            let lower = includeStart ? ">=" : ">"
            let asks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ask WHERE companyId = ? AND ownerDecidedAt \(lower) ? AND ownerDecidedAt <= ?",
                                        arguments: [companyId, from, to]) ?? 0
            let messages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE companyId = ? AND senderId = 'owner' AND createdAt \(lower) ? AND createdAt <= ?",
                                            arguments: [companyId, from, to]) ?? 0
            return asks + messages
        }
        var phases: [MilestonePhase] = []
        for (i, m) in milestones.enumerated() {
            let (toName, toAt) = i + 1 < milestones.count ? (milestones[i + 1].name, milestones[i + 1].at) : ("now", max(now, m.at))
            phases.append(MilestonePhase(from: m.name, to: toName, costLE: try cost(m.at, toAt),
                                         ownerTouches: try touches(m.at, toAt, includeStart: i == 0)))
        }
        return MilestoneReport(milestones: milestones, phases: phases, totalLE: phases.map(\.costLE).reduce(0, +),
                               totalTouches: phases.map(\.ownerTouches).reduce(0, +))
    }
}
