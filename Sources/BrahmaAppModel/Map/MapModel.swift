import Foundation
import BrahmaCore

// MARK: - Inputs

/// One snapshot of the company as the controller feeds the map. `currentItems` and `blockers` arrive already redacted and
/// described (`BlockerText.describe`, `Store.redactor` run in `MapController.sync`); the model only cleans them.
/// `vacancies` and `dotted` already include the provider's entries.
public struct MapInputs: Equatable, Sendable {
    public var agents: [Agent]
    public var pack: IndustryPack
    /// Agent id → "KEY title".
    public var currentItems: [String: String]
    /// Agent id → "Waiting on you: …"; absent when the agent has none.
    public var blockers: [String: String]
    public var vacancies: [Vacancy]
    public var dotted: [DottedLink]
    public var meetings: [Meeting]
    public var people: MapPeople

    public init(agents: [Agent], pack: IndustryPack, currentItems: [String: String] = [:], blockers: [String: String] = [:],
                vacancies: [Vacancy] = [], dotted: [DottedLink] = [], meetings: [Meeting] = [], people: MapPeople = .empty) {
        self.agents = agents; self.pack = pack; self.currentItems = currentItems; self.blockers = blockers
        self.vacancies = vacancies; self.dotted = dotted; self.meetings = meetings; self.people = people
    }
}

// MARK: - Agent, edges, cards

/// An agent as the map draws it. Every string is `MapText.clean` output.
public struct MapAgent: Equatable, Sendable, Identifiable {
    public var id: String
    /// "@" + the cleaned handle.
    public var handle: String
    public var role: String
    public var state: AgentState
    public var paused: Bool
    public var team: String?
    public var department: Department
    /// The cleaned blocker line, or "" when the agent has none.
    public var blocker: String
    public var item: String?
    public var trust: MapTrust?
    public var perks: [String]
    public var meter: MapMeter?

    public init(id: String, handle: String, role: String, state: AgentState, paused: Bool = false, team: String? = nil,
                department: Department, blocker: String = "", item: String? = nil, trust: MapTrust? = nil,
                perks: [String] = [], meter: MapMeter? = nil) {
        self.id = id; self.handle = handle; self.role = role; self.state = state; self.paused = paused; self.team = team
        self.department = department; self.blocker = blocker; self.item = item; self.trust = trust; self.perks = perks
        self.meter = meter
    }
}

public struct MapEdge: Equatable, Sendable {
    public var key: EdgeKey
    public var weight: Double
    /// 0…1, linear decay over 0.6 s.
    public var pulse: Double

    public init(key: EdgeKey, weight: Double, pulse: Double) { self.key = key; self.weight = weight; self.pulse = pulse }
}

public enum MapEdges {
    public static let halfLife = 60.0
    public static let minWeight = 0.05
    static let pulseDuration = 0.6

    /// Stroke width in points: `1 + min(4, log2(1 + w))`.
    public static func thickness(_ w: Double) -> Double { 1 + min(4, log2(1 + Swift.max(0, w))) }
}

public struct MapHoverCard: Equatable, Sendable {
    public var handle: String
    public var role: String
    public var stateLabel: String
    public var blocker: String
    public var department: String
    public var state: AgentState
    public var team: String?
    public var item: String?
    public var manager: String?
    public var reports: Int
    public var trust: MapTrust?
    public var perks: [String]
    public var meter: MapMeter?

    public init(handle: String, role: String, stateLabel: String, blocker: String, department: String, state: AgentState,
                team: String?, item: String?, manager: String?, reports: Int, trust: MapTrust?, perks: [String],
                meter: MapMeter?) {
        self.handle = handle; self.role = role; self.stateLabel = stateLabel; self.blocker = blocker
        self.department = department; self.state = state; self.team = team; self.item = item; self.manager = manager
        self.reports = reports; self.trust = trust; self.perks = perks; self.meter = meter
    }
}

public struct MapTeamMember: Equatable, Sendable, Identifiable {
    public var id: String
    public var handle: String
    /// The member's cleaned role.
    public var label: String
    public var state: AgentState

    public init(id: String, handle: String, label: String, state: AgentState) {
        self.id = id; self.handle = handle; self.label = label; self.state = state
    }
}

public struct MapTeamCard: Equatable, Sendable {
    /// "TEAM-1 · ENGINEERING".
    public var title: String
    public var lead: String
    public var counts: StateCounts
    public var members: [MapTeamMember]
    public var vacancies: Int

    public init(title: String, lead: String, counts: StateCounts, members: [MapTeamMember], vacancies: Int) {
        self.title = title; self.lead = lead; self.counts = counts; self.members = members; self.vacancies = vacancies
    }
}

// MARK: - Model

/// The map's live state: who is on the chart, what changed since the last snapshot, who talked to whom, which meetings
/// are on. Pure value code; `step` (MapQueue.swift) drains `pending` through the throttle into `active`.
public struct MapModel: Sendable {
    /// Queue and fan-out limits; `ingest` reads `maxFanout`, `step` the rest.
    public var throttle = MapThrottle.standard

    public private(set) var agents: [String: MapAgent] = [:]
    public private(set) var tree = OrgTree(nodes: ["owner": OrgNode(id: "owner", tier: .board, parentId: nil, childIds: [],
                                                                     depth: 0)], order: ["owner"])
    public private(set) var groups: [MapGroup] = []
    public private(set) var meetings: [Meeting] = []
    public private(set) var vacancies: [Vacancy] = []
    public private(set) var dotted: [DottedLink] = []
    /// Bumped when membership, managers, teams, roles or vacancies change (and when `showFormer` flips).
    public private(set) var structureRevision = 0
    public private(set) var showFormer = false

    /// Events waiting for `step`. `start` is the enqueue time and `duration` is 0 until the queue spawns them.
    var pending: [VisualEvent] = []
    public var pendingCount: Int { pending.count }
    /// Spawned events, counters and the message-fact times behind `rate` (MapQueue.swift).
    var queue = QueueState()

    private var raw: [String: Agent] = [:]
    private var roleKinds: [String: RoleKind] = [:]
    private var reportIds: [String: [String]] = [:]
    private var trustLabels: [String: String] = [:]
    private var key = StructureKey()
    private var pack: IndustryPack?
    private var hasApplied = false
    private var nextEventId = 1
    private var edgeStates: [EdgeKey: EdgeState] = [:]

    public init() {}

    struct EdgeState: Sendable {
        var weight: Double
        var at: TimeInterval
        var pulseAt: TimeInterval?
    }

    struct StructureKey: Equatable, Sendable {
        struct Member: Equatable, Sendable {
            var id: String, name: String, role: String, managerId: String?, team: String?, killed: Bool
        }
        var members: [Member] = []
        var vacancies: [Vacancy] = []
        var pack = ""
        var showFormer = false
    }

    // MARK: Apply

    /// Takes a snapshot. The tree and groups are rebuilt only when the structural key changes. With `emitEvents` and a
    /// previous snapshot, the difference becomes visual events in `pending`.
    public mutating func apply(_ inputs: MapInputs, now: TimeInterval, emitEvents: Bool = true) {
        let oldRaw = raw, oldTrust = trustLabels, oldMeetings = meetings
        let kinds = Dictionary(inputs.pack.roles.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var newRaw: [String: Agent] = [:]
        for a in inputs.agents { newRaw[a.id] = a }
        pack = inputs.pack
        roleKinds = kinds
        raw = newRaw

        var mapped: [String: MapAgent] = [:]
        mapped.reserveCapacity(newRaw.count)
        var trust: [String: String] = [:]
        for (id, a) in newRaw {
            let m = Self.makeAgent(a, kinds: kinds, item: inputs.currentItems[id], blocker: inputs.blockers[id],
                                   people: inputs.people)
            mapped[id] = m
            if let t = m.trust { trust[id] = t.label }
        }
        agents = mapped
        trustLabels = trust

        var seen = Set<String>()
        vacancies = inputs.vacancies.map { $0.cleaned() }.filter { seen.insert($0.id).inserted }
        dotted = inputs.dotted.map { var d = $0; d.itemKey = MapText.clean(d.itemKey, max: 40); return d }
        meetings = inputs.meetings.compactMap { m in
            let ids = m.participantIds.filter { mapped[$0] != nil }
            guard ids.count >= 2 else { return nil }
            var m = m
            m.title = MapText.clean(m.title, max: 40)
            m.participantIds = ids
            return m
        }

        let sorted = newRaw.values.sorted { ($0.createdAt, $0.name, $0.id) < ($1.createdAt, $1.name, $1.id) }
        var reports: [String: [String]] = [:]
        for a in sorted where a.state != .killed { if let m = a.managerId { reports[m, default: []].append(a.id) } }
        reportIds = reports

        let newKey = StructureKey(
            members: newRaw.values.map { .init(id: $0.id, name: $0.name, role: $0.role, managerId: $0.managerId, team: $0.team,
                                               killed: $0.state == .killed) }.sorted { $0.id < $1.id },
            vacancies: vacancies, pack: Self.signature(inputs.pack), showFormer: showFormer)
        if newKey != key {
            key = newKey
            rebuild()
        }

        if emitEvents && hasApplied {
            diff(old: oldRaw, oldTrust: oldTrust, oldMeetings: oldMeetings, now: now)
        }
        hasApplied = true
        dropUnknown(now: now)
    }

    public mutating func setShowFormer(_ on: Bool) {
        guard on != showFormer else { return }
        showFormer = on
        key.showFormer = on
        rebuild()
    }

    private mutating func rebuild() {
        guard let pack else { return }
        tree = OrgTree.build(agents: Array(raw.values), pack: pack, vacancies: vacancies, showFormer: showFormer)
        groups = MapGrouping.make(agents: Array(raw.values), roleKinds: roleKinds)
        structureRevision += 1
    }

    static func signature(_ pack: IndustryPack) -> String {
        ([pack.id, String(pack.version), pack.org.director] + pack.roles.map { "\($0.id):\($0.kind.rawValue)" }
            + pack.rolesCovering("ceo")).joined(separator: "|")
    }

    static func makeAgent(_ a: Agent, kinds: [String: RoleKind], item: String?, blocker: String?, people: MapPeople) -> MapAgent {
        // A label that cleans to the empty marker (only stripped scalars) is no label: the trust is absent.
        let trust = people.trust[a.id].flatMap { t -> MapTrust? in
            let label = MapText.clean(t.label, max: 8)
            guard label != MapText.empty else { return nil }
            return MapTrust(label: label, title: MapText.clean(t.title, max: 40), tier: Swift.min(3, Swift.max(0, t.tier)))
        }
        let perks = (people.perks[a.id] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(2).map { MapText.clean($0, max: 8) }
        let meter = people.meters[a.id].map { m in
            MapMeter(line: MapText.clean(m.line, max: 40),
                     fraction: m.fraction.flatMap { $0.isFinite ? Swift.min(1, Swift.max(0, $0)) : nil })
        }
        return MapAgent(id: a.id, handle: "@" + MapText.clean(a.name, max: 40), role: MapText.clean(a.role, max: 40),
                        state: a.state, paused: a.paused,
                        team: (a.team?.isEmpty ?? true) ? nil : MapText.clean(a.team, max: 32),
                        department: Department.of(role: a.role, kind: kinds[a.role]),
                        blocker: (blocker?.isEmpty ?? true) ? "" : MapText.clean(blocker, max: 80),
                        item: (item?.isEmpty ?? true) ? nil : MapText.clean(item, max: 80),
                        trust: trust, perks: Array(perks), meter: meter)
    }

    // MARK: Diff

    private mutating func diff(old: [String: Agent], oldTrust: [String: String], oldMeetings: [Meeting], now: TimeInterval) {
        for id in raw.keys.sorted() {
            let new = raw[id]!
            guard let was = old[id] else { emit(.hire, from: .agent(id), now: now); continue }
            if was.state != new.state {
                if new.state == .killed { emit(.leave, from: .agent(id), now: now) }
                else { emit(.stateChange(from: was.state, to: new.state), from: .agent(id), now: now) }
            }
            if was.managerId != new.managerId || was.team != new.team { emit(.reorg, from: .agent(id), now: now) }
            if let from = oldTrust[id], let to = trustLabels[id], from != to {
                emit(.promotion(from: from, to: to), from: .agent(id), now: now)
            }
        }
        let oldIds = Set(oldMeetings.map(\.id)), newIds = Set(meetings.map(\.id))
        for m in meetings.sorted(by: { $0.id < $1.id }) where !oldIds.contains(m.id) {
            if let first = m.participantIds.first { emit(.meetingStart(m.id), from: .agent(first), label: m.title, now: now) }
        }
        for m in oldMeetings.sorted(by: { $0.id < $1.id }) where !newIds.contains(m.id) {
            if let first = m.participantIds.first, agents[first] != nil {
                emit(.meetingEnd(m.id), from: .agent(first), label: m.title, now: now)
            }
        }
    }

    private mutating func emit(_ kind: VisualKind, from: MapEndpoint, to: MapEndpoint? = nil, label: String? = nil,
                               now: TimeInterval) {
        pending.append(VisualEvent(id: nextEventId, kind: kind, from: from, to: to, label: label, start: now, duration: 0))
        nextEventId += 1
        queue.ingested += 1
    }

    /// The world changed under the queue: events and edges that name an agent no longer in the company are dropped. The
    /// events are counted in `dropped`, so every ingested event stays accounted for.
    private mutating func dropUnknown(now: TimeInterval) {
        func known(_ e: MapEndpoint?) -> Bool {
            switch e {
            case nil, .owner?: true
            case .agent(let id)?: agents[id] != nil
            }
        }
        let before = pending.count
        pending.removeAll { !known($0.from) || !known($0.to) }
        if pending.count < before {
            queue.dropped += before - pending.count
            queue.lastDropAt = now
        }
        edgeStates = edgeStates.filter { known($0.key.a) && known($0.key.b) }
    }

    // MARK: Facts

    public mutating func ingest(_ facts: [MapFact], now: TimeInterval) {
        for fact in facts {
            switch fact {
            case .message(let f):
                queue.recordFact(now)
                ingestMessage(f, now: now)
            case .handoff(let h): ingestHandoff(h, now: now)
            case .stateChanged, .hired: break   // the snapshot diff covers them
            }
        }
        pruneEdges(now: now)
    }

    private func endpoint(_ id: String) -> MapEndpoint? {
        if id == "owner" { return .owner }
        if id == "system" { return nil }
        return agents[id] != nil ? .agent(id) : nil
    }

    private mutating func ingestMessage(_ f: MessageFlow, now: TimeInterval) {
        guard f.kind != "system", let sender = endpoint(f.senderId) else { return }
        var seen: Set<MapEndpoint> = []
        var recipients: [MapEndpoint] = []
        for r in f.recipientIds {
            if let e = endpoint(r), e != sender, seen.insert(e).inserted { recipients.append(e) }
        }
        // Every recipient named is unknown or the sender: nothing to draw.
        if !f.recipientIds.isEmpty && recipients.isEmpty { return }
        for r in recipients { bump(EdgeKey(sender, r), now: now) }
        for r in recipients.prefix(throttle.maxFanout) { emit(.message, from: sender, to: r, now: now) }
        if recipients.isEmpty {
            emit(.broadcast, from: teamLead(f.team).map { .agent($0) } ?? sender, now: now)
        } else if recipients.count > throttle.maxFanout {
            emit(.broadcast, from: sender, now: now)
        }
    }

    private func teamLead(_ team: String?) -> String? {
        guard let team, let id = groups.first(where: { $0.id == "team:\(team)" })?.leadId,
              let lead = raw[id], lead.state != .killed else { return nil }
        return id
    }

    private mutating func ingestHandoff(_ h: HandoffFlow, now: TimeInterval) {
        guard let author = endpoint(h.authorId) else { return }
        var to: MapEndpoint?
        if let id = h.toAgentId {
            guard let e = endpoint(id) else { return }
            to = e
        }
        emit(.handoff, from: author, to: to, label: MapText.clean(h.itemKey, max: 40), now: now)
    }

    // MARK: Edges

    private static func decayed(_ s: EdgeState, at now: TimeInterval) -> Double {
        s.weight * pow(0.5, Swift.max(0, now - s.at) / MapEdges.halfLife)
    }

    private mutating func bump(_ k: EdgeKey, now: TimeInterval) {
        let w = edgeStates[k].map { Self.decayed($0, at: now) } ?? 0
        edgeStates[k] = EdgeState(weight: w + 1, at: now, pulseAt: now)
    }

    mutating func pruneEdges(now: TimeInterval) {
        edgeStates = edgeStates.filter { Self.decayed($0.value, at: now) >= MapEdges.minWeight }
    }

    /// Aggregate mode: a message that is not drawn as a particle still lights its edge. An edge that does not exist is
    /// not created.
    mutating func pulseEdge(_ k: EdgeKey, now: TimeInterval) {
        edgeStates[k]?.pulseAt = now
    }

    /// Replay: replaces every comm edge with the given weights as of `now`, without a pulse. Unknown ends and weights
    /// below the minimum are dropped.
    public mutating func setEdgeWeights(_ w: [EdgeKey: Double], now: TimeInterval) {
        func known(_ e: MapEndpoint) -> Bool {
            if case .agent(let id) = e { return agents[id] != nil }
            return true
        }
        edgeStates = [:]
        for (k, weight) in w where weight.isFinite && weight >= MapEdges.minWeight && known(k.a) && known(k.b) {
            edgeStates[k] = EdgeState(weight: weight, at: now, pulseAt: nil)
        }
    }

    /// Comm edges decayed to `now` as `w·0.5^(Δt/60)`, those below 0.05 dropped. Reporting lines are not edges; they are
    /// the layout's connectors.
    public func edges(now: TimeInterval) -> [MapEdge] {
        var result: [MapEdge] = []
        for (k, s) in edgeStates {
            let w = Self.decayed(s, at: now)
            guard w >= MapEdges.minWeight else { continue }
            let pulse = s.pulseAt.map { Swift.min(1, Swift.max(0, 1 - (now - $0) / MapEdges.pulseDuration)) } ?? 0
            result.append(MapEdge(key: k, weight: w, pulse: pulse))
        }
        return result.sorted { ($0.key.a, $0.key.b) < ($1.key.a, $1.key.b) }
    }

    // MARK: Cards

    /// A paused agent that is not killed renders like a sleeping one.
    static func displayState(_ state: AgentState, paused: Bool) -> AgentState {
        paused && state != .killed ? .sleeping : state
    }

    private static func displayState(_ a: Agent) -> AgentState { displayState(a.state, paused: a.paused) }

    public func hoverCard(agentId: String) -> MapHoverCard? {
        guard let a = agents[agentId], let r = raw[agentId] else { return nil }
        let managerId = tree.nodes[agentId] != nil ? tree.nodes[agentId]?.parentId : r.managerId
        return MapHoverCard(handle: a.handle, role: a.role, stateLabel: AgentBadge.label(r), blocker: a.blocker,
                            department: a.department.title, state: Self.displayState(a.state, paused: a.paused), team: a.team, item: a.item,
                            manager: managerId.flatMap { agents[$0]?.handle }, reports: reportIds[agentId]?.count ?? 0,
                            trust: a.trust, perks: a.perks, meter: a.meter)
    }

    /// The card of a team band, keyed by the band's manager. Members are the manager's active direct reports.
    public func teamCard(managerId: String) -> MapTeamCard? {
        guard let lead = agents[managerId], let manager = raw[managerId],
              let label = tree.teamLabel(managerId, agents: raw) else { return nil }
        let department = groups.first { $0.id == "team:\(manager.team ?? "")" }?.department ?? lead.department
        let members = (reportIds[managerId] ?? []).compactMap { agents[$0] }
        // A generated team is already "TEAM-1"; a named one ("core") gets the prefix.
        let name = label.hasPrefix("TEAM") ? label : "TEAM-" + label
        return MapTeamCard(title: name + " · " + department.title, lead: lead.handle,
                           counts: StateCounts(members.compactMap { raw[$0.id] }.map { var a = $0; a.state = Self.displayState(a); return a }),
                           members: members.map {
                               MapTeamMember(id: $0.id, handle: $0.handle, label: $0.role,
                                             state: Self.displayState($0.state, paused: $0.paused))
                           },
                           vacancies: vacancies.filter { $0.managerId == managerId }.count)
    }
}
