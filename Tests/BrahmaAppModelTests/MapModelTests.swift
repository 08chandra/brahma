import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// The map's live state: org diffs, comm edges, sprint meetings and the hover and team cards. Pure value code over a
/// 30-agent plan; nothing here touches the Keychain or a store.
@MainActor
@Suite(.scratch) struct MapModelTests {
    let software = SoftwarePack.pack
    let t0: TimeInterval = 1_000

    var base: [Agent] { agentsFromPlan(plan(30, pack: software)) }

    func inputs(_ agents: [Agent], currentItems: [String: String] = [:], blockers: [String: String] = [:],
                vacancies: [Vacancy] = [], meetings: [Meeting] = [], people: MapPeople = .empty) -> MapInputs {
        MapInputs(agents: agents, pack: software, currentItems: currentItems, blockers: blockers, vacancies: vacancies,
                  meetings: meetings, people: people)
    }

    func model(_ agents: [Agent]? = nil) -> MapModel {
        var m = MapModel()
        m.apply(inputs(agents ?? base), now: t0)
        return m
    }

    func dm(_ from: String, _ to: [String], at t: Double = 0, kind: String = "text") -> MapFact {
        .message(MessageFlow(rowId: 1, messageId: "m", companyId: "c", senderId: from, channelId: "ch",
                             channelName: "dm:\(from)", channelKind: .dm, kind: kind, recipientIds: to, team: nil,
                             createdAt: mapFixtureEpoch.addingTimeInterval(t)))
    }

    func post(team: String, from: String, mentions: [String] = []) -> MapFact {
        .message(MessageFlow(rowId: 1, messageId: "m", companyId: "c", senderId: from, channelId: "ch",
                             channelName: "team-\(team)", channelKind: .channel, kind: "text", recipientIds: mentions,
                             team: team, createdAt: mapFixtureEpoch))
    }

    func vacancy(_ id: String, manager: String?, team: String? = nil) -> Vacancy {
        Vacancy(id: id, role: "engineer", roleTitle: "Engineer", managerId: manager, team: team, note: "", source: .org)
    }

    func kinds(_ m: MapModel) -> [VisualKind] { m.pending.map(\.kind) }

    // MARK: - Diffs

    @Test func firstApplyEmitsNothing() {
        let m = model()
        #expect(m.pendingCount == 0)
        #expect(m.agents.count == 30)
        #expect(m.structureRevision > 0)
    }

    @Test func emitEventsFalseEmitsNothing() {
        var m = model()
        var a = base
        a[3].state = .running
        m.apply(inputs(a), now: t0 + 1, emitEvents: false)
        #expect(m.pendingCount == 0)
        #expect(m.agents[a[3].id]?.state == .running)
    }

    @Test func diffEmitsHireLeaveStateReorg() throws {
        var m = model()
        var a = base
        let ics = a.indices.filter { a[$0].managerId == "a-mgr-1" }
        a[ics[0]].state = .killed
        a[ics[1]].state = .running
        a[ics[2]].managerId = "a-cto"
        var hire = a[ics[3]]
        hire.id = "a-new"; hire.name = "new"; hire.createdAt = mapFixtureEpoch.addingTimeInterval(99)
        a.append(hire)
        m.apply(inputs(a), now: t0 + 1)
        let ks = kinds(m)
        #expect(ks.count == 4)
        #expect(ks.filter { $0 == .hire }.count == 1)
        #expect(ks.filter { $0 == .leave }.count == 1)
        #expect(ks.filter { $0 == .stateChange(from: .ready, to: .running) }.count == 1)
        #expect(ks.filter { $0 == .reorg }.count == 1)
        let hired = try #require(m.pending.first { $0.kind == .hire })
        #expect(hired.from == .agent("a-new"))
        #expect(hired.start == t0 + 1)
        #expect(Set(m.pending.map(\.id)).count == 4)
    }

    @Test func teamChangeIsReorgAndRevivalIsStateChange() {
        var m = model()
        var a = base
        a[5].team = "elsewhere"
        m.apply(inputs(a), now: t0 + 1)
        #expect(kinds(m) == [.reorg])
        var b = a
        b[6].state = .killed
        m.apply(inputs(b), now: t0 + 2)
        var c = b
        c[6].state = .ready
        m.apply(inputs(c), now: t0 + 3)
        #expect(kinds(m).suffix(1) == [.stateChange(from: .killed, to: .ready)])
    }

    @Test func promotionOnlyWithPeopleData() {
        var m = MapModel()
        let id = base[4].id
        m.apply(inputs(base), now: t0)
        m.apply(inputs(base), now: t0 + 1)
        #expect(m.pendingCount == 0)
        let t1 = MapPeople(trust: [id: MapTrust(label: "T1", title: "Probation", tier: 1)])
        let t2 = MapPeople(trust: [id: MapTrust(label: "T2", title: "Trusted", tier: 2)])
        // Gaining a label is not a promotion: only a change between two labels is.
        m.apply(inputs(base, people: t1), now: t0 + 2)
        #expect(m.pendingCount == 0)
        m.apply(inputs(base, people: t2), now: t0 + 3)
        #expect(kinds(m) == [.promotion(from: "T1", to: "T2")])
        #expect(m.pending.first?.from == .agent(id))
        m.apply(inputs(base), now: t0 + 4)
        #expect(m.pendingCount == 1)
    }

    @Test func structureRevisionOnlyOnStructuralChange() {
        var m = model()
        let r0 = m.structureRevision
        var a = base
        a[4].state = .running
        m.apply(inputs(a, currentItems: [a[4].id: "K-1 x"], blockers: [a[5].id: "Waiting on you: x"]), now: t0 + 1)
        #expect(m.structureRevision == r0)
        a[4].team = "other"
        m.apply(inputs(a), now: t0 + 2)
        #expect(m.structureRevision == r0 + 1)
        m.apply(inputs(a, vacancies: [vacancy("v1", manager: "a-cto")]), now: t0 + 3)
        #expect(m.structureRevision == r0 + 2)
        #expect(m.vacancies.map(\.id) == ["v1"])
        #expect(m.tree.nodes["vacancy:v1"]?.parentId == "a-cto")
        m.apply(inputs(a, vacancies: [vacancy("v1", manager: "a-cto")]), now: t0 + 4)
        #expect(m.structureRevision == r0 + 2)
        a[4].role = "designer"
        m.apply(inputs(a, vacancies: [vacancy("v1", manager: "a-cto")]), now: t0 + 5)
        #expect(m.structureRevision == r0 + 3)
    }

    @Test func killedAndFormerRebuildTree() {
        var m = model()
        let r0 = m.structureRevision
        var a = base
        a[8].state = .killed
        m.apply(inputs(a), now: t0 + 1)
        #expect(m.structureRevision == r0 + 1)
        #expect(m.tree.nodes[a[8].id] == nil)
        m.setShowFormer(true)
        #expect(m.showFormer)
        #expect(m.structureRevision == r0 + 2)
        #expect(m.tree.nodes[a[8].id] != nil)
        m.apply(inputs(a), now: t0 + 2)
        #expect(m.structureRevision == r0 + 2)
    }

    // MARK: - Facts and edges

    @Test func messageFanoutAndBroadcast() throws {
        var m = model()
        m.ingest([dm("a-cto", ["a-mgr-1"])], now: t0)
        #expect(kinds(m) == [.message])
        #expect(m.pending[0].from == .agent("a-cto"))
        #expect(m.pending[0].to == .agent("a-mgr-1"))

        var team = model()
        team.ingest([post(team: "team-1", from: "a-cto")], now: t0)
        #expect(kinds(team) == [.broadcast])
        #expect(team.pending[0].from == .agent("a-mgr-1"))

        var owner = model()
        owner.ingest([dm("owner", ["a-ceo"])], now: t0)
        #expect(owner.pending[0].from == .owner)
        #expect(owner.pending[0].to == .agent("a-ceo"))
        #expect(owner.edges(now: t0).map(\.key) == [EdgeKey(.owner, .agent("a-ceo"))])

        // Mentions: one message each, the sender's broadcast only when the list is cut.
        var few = model()
        few.ingest([post(team: "team-1", from: "a-cto", mentions: ["a-ceo", "a-cpo"])], now: t0)
        #expect(kinds(few) == [.message, .message])
        let others = base.map(\.id).filter { $0 != "a-ceo" }
        var storm = model()
        storm.ingest([post(team: "team-1", from: "a-ceo", mentions: others)], now: t0)
        #expect(storm.pending.filter { $0.kind == .message }.count == MapThrottle.standard.maxFanout)
        let b = try #require(storm.pending.first { $0.kind == .broadcast })
        #expect(b.from == .agent("a-ceo"))
        #expect(storm.pending.count == MapThrottle.standard.maxFanout + 1)
        #expect(storm.edges(now: t0).count == others.count)
    }

    @Test func handoffFact() {
        var m = model()
        let h = { (to: String?) in MapFact.handoff(HandoffFlow(rowId: 1, id: "h", itemKey: "K-7", authorId: "a-cto",
                                                           toAgentId: to, createdAt: mapFixtureEpoch)) }
        m.ingest([h("a-mgr-1"), h(nil), h("a-ghost")], now: t0)
        #expect(kinds(m) == [.handoff, .handoff])
        #expect(m.pending[0].label == "K-7")
        #expect(m.pending[0].to == .agent("a-mgr-1"))
        #expect(m.pending[1].to == nil)
        #expect(m.edges(now: t0).isEmpty)
    }

    @Test func liveStateFactsIgnored() {
        var m = model()
        m.ingest([.stateChanged(agentId: "a-cto", from: .ready, to: .running, at: mapFixtureEpoch),
                  .hired(agentId: "a-cto", at: mapFixtureEpoch)], now: t0)
        #expect(m.pendingCount == 0)
    }

    @Test func systemAndUnknownDropped() {
        var m = model()
        m.ingest([dm("system", ["a-cto"]), dm("a-cto", ["a-cpo"], kind: "system"), dm("a-cto", ["a-ghost"]),
                  dm("a-ghost", ["a-cto"]), dm("a-cto", ["system"])], now: t0)
        #expect(m.pendingCount == 0)
        #expect(m.edges(now: t0).isEmpty)
        // A partly unknown list keeps its known recipients.
        m.ingest([dm("a-cto", ["a-ghost", "a-cpo"])], now: t0)
        #expect(m.pending.map(\.to) == [.agent("a-cpo")])
    }

    @Test func eventsForUnknownAgentsDropped() {
        var m = model()
        m.ingest([dm("a-cto", ["a-mgr-1"]), dm("a-cto", ["a-cpo"])], now: t0)
        #expect(m.pendingCount == 2)
        m.apply(inputs(base.filter { $0.id != "a-mgr-1" }), now: t0 + 1)
        let named = m.pending.filter { $0.from == .agent("a-mgr-1") || $0.to == .agent("a-mgr-1") }
        #expect(named.isEmpty)
        #expect(m.pending.map(\.to) == [.agent("a-cpo")])
        #expect(m.edges(now: t0 + 1).allSatisfy { $0.key.a != .agent("a-mgr-1") && $0.key.b != .agent("a-mgr-1") })
        #expect(m.edges(now: t0 + 1).count == 1)
    }

    @Test func edgesDecayAndPrune() throws {
        var m = model()
        m.ingest([dm("a-cto", ["a-mgr-1"])], now: t0)
        let key = EdgeKey(.agent("a-mgr-1"), .agent("a-cto"))
        var e = try #require(m.edges(now: t0).first)
        #expect(e.key == key)
        #expect(abs(e.weight - 1) < 1e-9)
        #expect(e.pulse == 1)
        e = try #require(m.edges(now: t0 + 60).first)
        #expect(abs(e.weight - 0.5) < 1e-9)
        #expect(e.pulse == 0)
        #expect(abs(try #require(m.edges(now: t0 + 0.3).first).pulse - 0.5) < 1e-9)
        #expect(m.edges(now: t0 + 300).isEmpty)
        // A second message on the decayed edge adds 1 to the decayed weight.
        m.ingest([dm("a-mgr-1", ["a-cto"])], now: t0 + 60)
        #expect(abs(try #require(m.edges(now: t0 + 60).first).weight - 1.5) < 1e-9)
    }

    @Test func setEdgeWeightsReplaysAndDropsUnknown() {
        var m = model()
        m.ingest([dm("a-cto", ["a-mgr-1"])], now: t0)
        let k = EdgeKey(.agent("a-cpo"), .agent("a-ceo"))
        m.setEdgeWeights([k: 3, EdgeKey(.agent("a-cpo"), .agent("a-ghost")): 5, EdgeKey(.owner, .agent("a-ceo")): 0.01],
                         now: t0 + 10)
        let edges = m.edges(now: t0 + 10)
        #expect(edges.map(\.key) == [k])
        #expect(edges[0].weight == 3)
        #expect(edges[0].pulse == 0)
    }

    @Test func thicknessCurve() {
        #expect(MapEdges.halfLife == 60)
        #expect(MapEdges.minWeight == 0.05)
        #expect(abs(MapEdges.thickness(0) - 1) < 1e-9)
        #expect(abs(MapEdges.thickness(1) - 2) < 1e-9)
        #expect(abs(MapEdges.thickness(1e9) - 5) < 1e-9)
    }

    // MARK: - Cards

    @Test func hoverCardTextIsClean() throws {
        var a = base
        let i = try #require(a.firstIndex { $0.name == "eng-1" })
        a[i].role = "lead\u{202E}x\n"
        let id = a[i].id
        let blocked = a[i + 1].id
        var m = MapModel()
        m.apply(inputs(a, currentItems: [id: "K-1 " + String(repeating: "t", count: 200)],
                       blockers: [blocked: "x\u{202E}y\n" + String(repeating: "z", count: 200)]), now: t0)
        let card = try #require(m.hoverCard(agentId: id))
        #expect(card.role == "leadx")
        let item = try #require(card.item)
        #expect(item.count <= 80)
        #expect(item.hasSuffix("…"))
        #expect(card.blocker == "")
        #expect(card.handle == "@eng-1")
        #expect(card.trust == nil)
        #expect(card.perks.isEmpty)
        #expect(card.meter == nil)
        let b = try #require(m.hoverCard(agentId: blocked))
        #expect(b.blocker.count <= 80)
        #expect(b.blocker.hasSuffix("…"))
        #expect(b.blocker.hasPrefix("xy"))
        #expect(!hasForbidden(b.blocker))
        #expect(m.agents[blocked]?.blocker == b.blocker)
        #expect(m.hoverCard(agentId: "nope") == nil)
        #expect(card.stateLabel == "ready")
        #expect(card.reports == 0)
        #expect(card.manager != nil)
    }

    func hasForbidden(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            u.properties.generalCategory == .control || u.properties.generalCategory == .format
                || u.properties.generalCategory == .lineSeparator || u.properties.generalCategory == .paragraphSeparator
                || u.value == 0x2028 || u.value == 0x2029
        }
    }

    @Test func peopleDataIsCleanedAndAttached() throws {
        let id = base[4].id
        let people = MapPeople(trust: [id: MapTrust(label: "T\u{202E}2\n", title: String(repeating: "q", count: 200), tier: 9)],
                               perks: [id: ["🏆", "⭐\n", "🔥"]],
                               meters: [id: MapMeter(line: String(repeating: "m", count: 200), fraction: 7)])
        var m = MapModel()
        m.apply(inputs(base, people: people), now: t0)
        let card = try #require(m.hoverCard(agentId: id))
        let trust = try #require(card.trust)
        #expect(trust.label == "T2")
        #expect(trust.title.count <= 40)
        #expect(trust.tier == 3)
        #expect(card.perks == ["🏆", "⭐"])
        let meter = try #require(card.meter)
        #expect(meter.line.count <= 40)
        #expect(meter.fraction == 1)
    }

    func texts(_ h: MapHoverCard) -> [String] {
        [h.handle, h.role, h.stateLabel, h.blocker, h.department] + [h.team, h.item, h.manager].compactMap { $0 }
            + (h.trust.map { [$0.label, $0.title] } ?? []) + h.perks + (h.meter.map { [$0.line] } ?? [])
    }

    @Test func teamCardTextIsClean() throws {
        var a = base
        let mgr = try #require(a.firstIndex { $0.name == "mgr-1" })
        for i in a.indices where a[i].team == a[mgr].team { a[i].team = "a\u{202E}b" }
        a[mgr].name = "m\u{202E}gr\n"
        let report = try #require(a.firstIndex { $0.managerId == "a-mgr-1" })
        a[report].role = "e\u{2028}ng\u{202E}"
        a[report].name = "x\u{202E}y\n"
        let rid = a[report].id
        var m = MapModel()
        m.apply(inputs(a, currentItems: [rid: "K-2\u{2029}t\u{202E}" + String(repeating: "i", count: 200)],
                       blockers: [rid: "Waiting\u{202E}\n" + String(repeating: "b", count: 200)]), now: t0)
        let card = try #require(m.teamCard(managerId: "a-mgr-1"))
        #expect(card.title.hasPrefix("TEAM-AB · "))
        let manager = try #require(m.hoverCard(agentId: "a-mgr-1"))
        let member = try #require(m.hoverCard(agentId: rid))
        // The ids are keys, not text; every other string is scanned.
        var strings = [card.title, card.lead] + texts(manager) + texts(member)
        for mem in card.members { strings += [mem.handle, mem.label] }
        #expect(strings.count > 20)
        for s in strings { #expect(!hasForbidden(s), "\(s.debugDescription)") }
        #expect(card.lead == "@mgr")
        #expect(member.handle == "@xy" && member.role == "e ng" && member.manager == "@mgr")
        #expect(member.blocker.hasPrefix("Waiting") && member.blocker.count <= 80)
        #expect(card.members.contains { $0.handle == "@xy" && $0.label == "e ng" })
    }

    @Test func teamTitleRulesForGeneratedAndNamedTeams() throws {
        // Generated teams are "team-<i>" and read "TEAM-1"; a pack's small-team name gets the prefix.
        var m = model()
        #expect(m.teamCard(managerId: "a-mgr-1")?.title == "TEAM-1 · ENGINEERING")
        var a = base
        let name = software.org.smallTeamName
        for i in a.indices where a[i].team == "team-1" { a[i].team = name }
        m.apply(inputs(a), now: t0 + 1)
        #expect(m.teamCard(managerId: "a-mgr-1")?.title == "TEAM-\(name.uppercased()) · ENGINEERING")
        for i in a.indices where a[i].team == name { a[i].team = "TEAMWORK" }
        m.apply(inputs(a), now: t0 + 2)
        #expect(m.teamCard(managerId: "a-mgr-1")?.title == "TEAMWORK · ENGINEERING")
    }

    @Test func pausedRendersLikeSleeping() throws {
        var a = base
        let ids = a.indices.filter { a[$0].managerId == "a-mgr-1" }
        a[ids[0]].state = .running; a[ids[0]].paused = true
        a[ids[1]].state = .killed; a[ids[1]].paused = true
        a[ids[2]].state = .blocked; a[ids[2]].paused = true
        var m = MapModel()
        m.apply(inputs(a), now: t0)
        let card = try #require(m.teamCard(managerId: "a-mgr-1"))
        let member = try #require(card.members.first { $0.id == a[ids[0]].id })
        #expect(member.state == .sleeping)
        #expect(card.members.first { $0.id == a[ids[2]].id }?.state == .sleeping)
        #expect(card.counts.running == 0)
        #expect(card.counts.blocked == 0)
        #expect(card.counts.sleeping == 2)
        #expect(card.counts.killed == 0)
        let hover = try #require(m.hoverCard(agentId: a[ids[0]].id))
        #expect(hover.state == .sleeping)
        #expect(hover.stateLabel == "running (pausing)")
        // A paused killed agent stays killed.
        #expect(m.hoverCard(agentId: a[ids[1]].id)?.state == .killed)
        // The map agent keeps the raw state and flag for the renderer.
        #expect(m.agents[a[ids[0]].id]?.state == .running)
        #expect(m.agents[a[ids[0]].id]?.paused == true)
    }

    @Test func trustLabelThatCleansToNothingIsAbsent() {
        var m = MapModel()
        let id = base[4].id
        func people(_ label: String) -> MapPeople { MapPeople(trust: [id: MapTrust(label: label, title: "x", tier: 1)]) }
        m.apply(inputs(base, people: people("\u{202E}\u{200B}")), now: t0)
        #expect(m.agents[id]?.trust == nil)
        m.apply(inputs(base, people: people("T2")), now: t0 + 1)
        #expect(m.pendingCount == 0)
        m.apply(inputs(base, people: people("\u{202E}")), now: t0 + 2)
        m.apply(inputs(base, people: people("T3")), now: t0 + 3)
        #expect(m.pendingCount == 0)
        m.apply(inputs(base, people: people("T4")), now: t0 + 4)
        #expect(kinds(m) == [.promotion(from: "T3", to: "T4")])
    }

    @Test func teamCardCountsAndVacancies() throws {
        let a = base
        let reports = a.filter { $0.managerId == "a-mgr-1" }
        #expect(reports.count >= 2)
        var m = MapModel()
        m.apply(inputs(a, vacancies: [vacancy("v1", manager: "a-mgr-1", team: "team-1"), vacancy("v2", manager: "a-cto")]), now: t0)
        let card = try #require(m.teamCard(managerId: "a-mgr-1"))
        #expect(card.title == "TEAM-1 · ENGINEERING")
        #expect(card.counts.total == reports.count)
        #expect(card.members.count == reports.count)
        #expect(card.vacancies == 1)
        #expect(card.lead == "@mgr-1")
        #expect(m.teamCard(managerId: "a-ceo") == nil)
        #expect(m.teamCard(managerId: "a-ghost") == nil)
        let hover = try #require(m.hoverCard(agentId: "a-mgr-1"))
        #expect(hover.reports == reports.count)
        #expect(hover.manager == "@cto")
        #expect(hover.team == "team-1")
        #expect(hover.department == "ENGINEERING")
    }

    // MARK: - Meetings

    @Test func meetingsFromSprints() throws {
        let a = base
        let planning = Meetings.detect(agents: a, pack: software, sprints: [sprintFixture(number: 2, team: "team-1", status: .pendingApproval)])
        let meeting = try #require(planning.first)
        #expect(planning.count == 1)
        #expect(meeting.kind == .sprintPlanning)
        #expect(meeting.title == "SPRINT 2 PLANNING")
        #expect(meeting.id == "sprint:sprint-2")
        #expect(meeting.participantIds.first == "a-mgr-1")
        #expect(Set(meeting.participantIds) == Set(a.filter { $0.team == "team-1" }.map(\.id)))
        let review = Meetings.detect(agents: a, pack: software, sprints: [sprintFixture(number: 2, team: "team-1", status: .review)])
        #expect(review.map(\.title) == ["SPRINT 2 REVIEW"])
        #expect(review.map(\.kind) == [.sprintReview])
        for s in [SprintStatus.active, .closed, .rejected] {
            #expect(Meetings.detect(agents: a, pack: software, sprints: [sprintFixture(number: 2, team: "team-1", status: s)]).isEmpty)
        }

        // A diff: meetingStart, then meetingEnd from the first participant.
        var m = model(a)
        m.apply(inputs(a, meetings: planning), now: t0 + 1)
        #expect(kinds(m) == [.meetingStart("sprint:sprint-2")])
        #expect(m.pending[0].from == .agent("a-mgr-1"))
        #expect(m.meetings == planning)
        m.apply(inputs(a, meetings: planning), now: t0 + 2)
        #expect(m.pendingCount == 1)
        m.apply(inputs(a), now: t0 + 3)
        #expect(kinds(m) == [.meetingStart("sprint:sprint-2"), .meetingEnd("sprint:sprint-2")])
        #expect(m.pending[1].from == .agent("a-mgr-1"))
    }

    @Test func meetingRules() {
        var a = base
        // Killed agents never attend; a lone attendee is no meeting; a company-wide sprint seats managers and executives.
        let team1 = a.indices.filter { a[$0].team == "team-1" }
        for i in team1.dropFirst() { a[i].state = .killed }
        #expect(Meetings.detect(agents: a, pack: software, sprints: [sprintFixture(number: 1, team: "team-1", status: .review)]).isEmpty)
        let wide = Meetings.detect(agents: base, pack: software, sprints: [sprintFixture(number: 3, team: nil, status: .pendingApproval)])
        let kindsSeen = Set(wide[0].participantIds.compactMap { id in base.first { $0.id == id }.flatMap { software.role($0.role)?.kind } })
        #expect(kindsSeen.isSubset(of: [.manager, .executive]))
        #expect(wide[0].participantIds.count <= 12)
        #expect(Set(wide[0].participantIds).count == wide[0].participantIds.count)
        // Cap of 12 on a big team.
        var big = base
        let lead = big.first { $0.name == "mgr-1" }!
        for n in 0..<20 {
            var x = lead; x.id = "x\(n)"; x.name = "x\(n)"; x.role = "engineer"; x.createdAt = mapFixtureEpoch.addingTimeInterval(100 + Double(n))
            big.append(x)
        }
        let capped = Meetings.detect(agents: big, pack: software, sprints: [sprintFixture(number: 1, team: "team-1", status: .review)])
        #expect(capped[0].participantIds.count == 12)
        #expect(capped[0].participantIds.first == "a-mgr-1")
    }

    // MARK: - Office: item phases and activity (Plan 4c)

    @Test func phaseOfItemFacets() {
        let rows: [(WorkItemStatus, MergeState, VerificationStatus?, MapItemPhase)] = [
            (.inProgress, .none, nil, .working),
            (.inReview, .none, nil, .inReview),
            (.inProgress, .pending, nil, .merging),
            (.inReview, .none, .running, .checking),
            (.inProgress, .none, .passed, .passed),
            (.inProgress, .none, .timedOut, .failed),
            // Precedence: a merge beats a running check; a queued check beats review; review beats an old result.
            (.inReview, .verifying, .running, .merging),
            (.inReview, .none, .queued, .checking),
            (.inReview, .none, .failed, .inReview),
            (.inProgress, .none, .failed, .failed),
            (.inProgress, .none, .error, .failed),
            (.inProgress, .none, .inconclusive, .working),
        ]
        for (status, merge, run, want) in rows {
            #expect(MapItemPhase.of(status: status, mergeState: merge, run: run) == want, "\(status) \(merge) \(String(describing: run))")
        }
        #expect([MapItemPhase.working, .inReview].allSatisfy { !$0.isShipping })
        #expect([MapItemPhase.checking, .merging, .passed, .failed].allSatisfy { $0.isShipping })
    }

    @Test func activityTable() {
        typealias Row = (state: AgentState, paused: Bool, owner: Bool, reviewing: Bool, meeting: String?, want: OfficeActivity)
        let rows: [Row] = [
            (.running, false, false, false, nil, .typing),
            (.running, false, false, true, nil, .reviewing),
            (.ready, false, false, true, nil, .reviewing),
            (.running, false, false, false, "m1", .meeting("m1")),
            (.ready, false, false, false, "m1", .meeting("m1")),
            (.running, false, false, true, "m1", .meeting("m1")),
            (.blocked, false, true, false, nil, .waitingOnOwner),
            (.blocked, false, false, false, nil, .blocked),
            (.blocked, false, false, true, "m1", .blocked),
            (.ready, false, false, false, nil, .idle),
            (.sleeping, false, false, false, nil, .away),
            (.sleeping, false, false, true, "m1", .away),
            (.running, true, false, false, nil, .away),
            (.ready, true, false, true, nil, .away),
            (.blocked, true, true, false, nil, .away),
            (.killed, false, false, false, nil, .gone),
            (.killed, true, true, true, "m1", .gone),
        ]
        for r in rows {
            let got = OfficeActivity.of(state: r.state, paused: r.paused, waitingOnOwner: r.owner, reviewing: r.reviewing,
                                        meetingId: r.meeting)
            #expect(got == r.want, "\(r)")
        }
    }

    @Test func reviewerOfInReviewItemIsReviewing() throws {
        var a = base
        let ids = a.indices.filter { a[$0].managerId == "a-mgr-1" }
        let owner = a[ids[0]].id, reviewer = a[ids[1]].id, sleeper = a[ids[2]].id
        a[ids[0]].state = .running
        a[ids[1]].state = .running
        a[ids[2]].state = .sleeping
        var m = MapModel()
        var i = inputs(a)
        i.itemPhases = [owner: .inReview]
        i.reviewing = [reviewer, sleeper, "a-not-here"]
        m.apply(i, now: t0)
        #expect(m.agents[reviewer]?.activity == .reviewing)
        #expect(m.agents[owner]?.activity == .typing)
        #expect(m.agents[sleeper]?.activity == .away)
        #expect(m.agents["a-not-here"] == nil)
        #expect(m.agents["a-mgr-1"]?.activity == .idle)
    }

    @Test func ownerBlockerIsWaitingOnOwner() throws {
        var a = base
        let ids = a.indices.filter { a[$0].managerId == "a-mgr-1" }
        a[ids[0]].state = .blocked; a[ids[0]].blocker = .owner(reason: "pick a tier")
        a[ids[1]].state = .blocked; a[ids[1]].blocker = .agent(a[ids[2]].id)
        var m = MapModel()
        m.apply(inputs(a), now: t0)
        let waiting = try #require(m.agents[a[ids[0]].id])
        #expect(waiting.waitingOnOwner)
        #expect(waiting.activity == .waitingOnOwner)
        let blocked = try #require(m.agents[a[ids[1]].id])
        #expect(!blocked.waitingOnOwner)
        #expect(blocked.activity == .blocked)
        #expect(m.agents[a[ids[2]].id]?.waitingOnOwner == false)
    }

    @Test func meetingParticipantIsInTheFirstMeeting() throws {
        var a = base
        let team = a.indices.filter { a[$0].team == "team-1" }.map { a[$0].id }
        for i in a.indices where team.contains(a[i].id) { a[i].state = .running }
        let b = Meeting(id: "b", kind: .other, title: "B", participantIds: [team[0], team[1]])
        let c = Meeting(id: "a", kind: .other, title: "A", participantIds: [team[1], team[2]])
        var m = MapModel()
        m.apply(inputs(a, meetings: [b, c]), now: t0)
        #expect(m.agents[team[0]]?.activity == .meeting("b"))
        #expect(m.agents[team[1]]?.activity == .meeting("a"), "meetings sorted by id: the first that lists the agent")
        #expect(m.agents[team[2]]?.activity == .meeting("a"))
    }

    @Test func shippingFromPhase() throws {
        let a = base
        var m = MapModel()
        var i = inputs(a)
        i.itemPhases = [a[3].id: .merging, a[4].id: .working, a[5].id: .inReview, a[6].id: .failed]
        m.apply(i, now: t0)
        #expect(m.agents[a[3].id]?.shipping == .merging)
        #expect(m.agents[a[4].id]?.shipping == nil)
        #expect(m.agents[a[5].id]?.shipping == nil)
        #expect(m.agents[a[6].id]?.shipping == .failed)
        #expect(m.agents[a[7].id]?.shipping == nil)
        #expect(m.phase(agentId: a[3].id) == .merging)
        #expect(m.phase(agentId: a[7].id) == nil)
        #expect(m.phase(agentId: "a-not-here") == nil)
    }

    @Test func phaseChangeEmitsEvent() throws {
        let a = base
        let id = a[3].id, other = a[4].id
        var m = MapModel()
        var i = inputs(a)
        i.itemPhases = [id: .working]
        m.apply(i, now: t0)
        i.itemPhases = [id: .checking]
        m.apply(i, now: t0 + 1)
        #expect(kinds(m) == [.phaseChange(from: .working, to: .checking)])
        #expect(m.pending.first?.from == .agent(id))
        // Absent counts as working: no event for working ↔ absent; an item appearing in a later phase is a change.
        i.itemPhases = [id: .checking, other: .working]
        m.apply(i, now: t0 + 2)
        #expect(m.pendingCount == 1)
        i.itemPhases = [other: .merging]
        m.apply(i, now: t0 + 3)
        #expect(m.pendingCount == 3)
        let later = m.pending.dropFirst().map { "\($0.kind) \($0.from)" }.sorted()
        #expect(later == ["\(VisualKind.phaseChange(from: .checking, to: .working)) \(MapEndpoint.agent(id))",
                          "\(VisualKind.phaseChange(from: .working, to: .merging)) \(MapEndpoint.agent(other))"].sorted())
    }

    @Test func openAsksClamped() {
        var m = MapModel()
        #expect(m.openAsks == 0)
        var i = inputs(base)
        i.openAsks = -3
        m.apply(i, now: t0)
        #expect(m.openAsks == 0)
        i.openAsks = 12
        m.apply(i, now: t0 + 1)
        #expect(m.openAsks == 12)
    }
}
