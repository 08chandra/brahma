import Foundation
import BrahmaCore

/// The map's view of the company: the org chart, or (Plan 4c) the office. `org` stays first.
public enum MapMode: String, Codable, CaseIterable, Equatable, Sendable {
    case org
    /// The easter-egg office skin (Plan 4c): shown only once the owner has unlocked it (`MapController.officeUnlocked`).
    case office

    public var title: String {
        switch self {
        case .org: "ORG"
        case .office: "OFFICE"
        }
    }
}

/// The department an agent's role belongs to: the group a teamless agent joins, and the color family of a team.
public enum Department: String, CaseIterable, Equatable, Sendable {
    case csuite, engineering, design, research, sales, operations, finance, people, quality

    public var title: String {
        switch self {
        case .csuite: "C-SUITE"
        case .engineering: "ENGINEERING"
        case .design: "DESIGN"
        case .research: "RESEARCH"
        case .sales: "SALES"
        case .operations: "OPERATIONS"
        case .finance: "FINANCE"
        case .people: "PEOPLE"
        case .quality: "QUALITY"
        }
    }

    /// Substring rules on the lowercased role, first match wins; an executive kind is always the C-suite.
    static let rules: [(needles: [String], department: Department)] = [
        (["hr", "people", "recruit", "perf"], .people),
        (["qa", "test", "quality"], .quality),
        (["design", "ux", "ui", "brand", "art"], .design),
        (["visionary", "research", "rnd", "r&d", "lab", "scien"], .research),
        (["finance", "account", "bank", "treasur"], .finance),
        (["devops", "sre", "infra", "engineer", "eng", "dev", "architect", "backend", "frontend", "mobile", "security"],
         .engineering),
        (["ops", "fulfil", "logistic", "warehouse", "supply"], .operations),
        (["sales", "market", "growth", "content", "social", "support"], .sales),
    ]

    public static func of(role: String, kind: RoleKind?) -> Department {
        if kind == .executive { return .csuite }
        let role = role.lowercased()
        for rule in rules where rule.needles.contains(where: role.contains) { return rule.department }
        return .engineering
    }
}

/// One end of a flow on the map. 4c adds `group`.
public enum MapEndpoint: Hashable, Comparable, Sendable {
    case agent(String)
    case owner

    /// `.owner` sorts before every agent; agents sort by id.
    public static func < (l: MapEndpoint, r: MapEndpoint) -> Bool {
        switch (l, r) {
        case (.owner, .owner): false
        case (.owner, .agent): true
        case (.agent, .owner): false
        case let (.agent(a), .agent(b)): a < b
        }
    }
}

/// An unordered pair of endpoints: `EdgeKey(x, y) == EdgeKey(y, x)`. The smaller end is stored first.
public struct EdgeKey: Hashable, Sendable {
    public let a: MapEndpoint
    public let b: MapEndpoint

    public init(_ x: MapEndpoint, _ y: MapEndpoint) {
        if y < x { a = y; b = x } else { a = x; b = y }
    }
}

/// Something that happened in the company, as the map ingests it.
public enum MapFact: Equatable, Sendable {
    case message(MessageFlow)
    case handoff(HandoffFlow)
    case stateChanged(agentId: String, from: AgentState, to: AgentState, at: Date)
    case hired(agentId: String, at: Date)

    public var at: Date {
        switch self {
        case .message(let m): m.createdAt
        case .handoff(let h): h.createdAt
        case .stateChanged(_, _, _, let at): at
        case .hired(_, let at): at
        }
    }
}

public enum VisualKind: Hashable, Sendable {
    case message, broadcast, handoff
    case stateChange(from: AgentState, to: AgentState)
    case hire, leave, reorg
    case promotion(from: String, to: String)
    case meetingStart(String)
    case meetingEnd(String)
}

/// One animation the scene plays: `start` and `duration` are in map time (seconds).
public struct VisualEvent: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: VisualKind
    public var from: MapEndpoint
    public var to: MapEndpoint?
    public var count: Int
    public var label: String?
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(id: Int, kind: VisualKind, from: MapEndpoint, to: MapEndpoint? = nil, count: Int = 1, label: String? = nil,
                start: TimeInterval, duration: TimeInterval) {
        self.id = id; self.kind = kind; self.from = from; self.to = to; self.count = count; self.label = label
        self.start = start; self.duration = duration
    }
}

public enum MeetingKind: String, Equatable, Sendable {
    case sprintPlanning, sprintReview, other
}

public struct Meeting: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: MeetingKind
    public var title: String
    public var participantIds: [String]

    public init(id: String, kind: MeetingKind, title: String, participantIds: [String]) {
        self.id = id; self.kind = kind; self.title = title; self.participantIds = participantIds
    }
}

/// What a click or hover on the map landed on.
public enum MapHit: Equatable, Sendable {
    case agent(String)
    case owner
    case vacancy(String)
    case stub(String)
    /// The manager id of a team band.
    case team(String)
}

public enum VacancySource: Equatable, Sendable {
    /// A row of 3a's `orgVacancy`: the only kind the owner can fill or remove.
    case org
    /// Supplied by a `MapPeopleProviding`: display only.
    case provider
}

/// An open seat on the chart.
public struct Vacancy: Identifiable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var roleTitle: String
    public var managerId: String?
    public var team: String?
    public var note: String
    public var source: VacancySource

    public init(id: String, role: String, roleTitle: String, managerId: String?, team: String?, note: String,
                source: VacancySource) {
        self.id = id; self.role = role; self.roleTitle = roleTitle; self.managerId = managerId; self.team = team
        self.note = note; self.source = source
    }

    /// Every displayed string through `MapText.clean`: id, role and title 40, team 32 (nil stays nil), note 80 (empty
    /// stays empty). `managerId` is a lookup key, never drawn.
    public func cleaned() -> Vacancy {
        var v = self
        v.id = MapText.clean(id, max: 40)
        v.role = MapText.clean(role, max: 40)
        v.roleTitle = MapText.clean(roleTitle, max: 40)
        v.team = team.map { MapText.clean($0, max: 32) }
        v.note = note.isEmpty ? "" : MapText.clean(note, max: 80)
        return v
    }
}

// MARK: - Geometry

public struct MapPoint2: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct MapRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }

    public var mid: MapPoint2 { MapPoint2(x: x + w / 2, y: y + h / 2) }

    /// True when the interiors overlap; rects that only touch along an edge do not intersect.
    public func intersects(_ o: MapRect) -> Bool {
        x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h
    }
}
