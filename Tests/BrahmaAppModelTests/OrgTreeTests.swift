import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// The org tree and its chart layout: pure value code over `agentsFromPlan` and the software pack. Nothing here touches
/// the Keychain or a store.
@Suite struct OrgTreeTests {
    let software = SoftwarePack.pack

    func tree(_ agents: [Agent], vacancies: [Vacancy] = [], showFormer: Bool = false) -> OrgTree {
        OrgTree.build(agents: agents, pack: software, vacancies: vacancies, showFormer: showFormer)
    }

    func agent(_ handle: String, role: String, manager: String?, team: String? = nil, state: AgentState = .ready,
               at t: Double = 0) -> Agent {
        var a = Agent(id: "a-\(handle)", companyId: "c", name: handle, role: role, model: "sonnet", sessionId: "s",
                      sessionStarted: false, state: state, blocker: nil, requestedBlocker: nil, paused: false,
                      readySince: nil, createdAt: mapFixtureEpoch.addingTimeInterval(t))
        a.managerId = manager.map { "a-\($0)" }
        a.team = team
        return a
    }

    func item(_ key: String, owner: String?, reviewer: String?, status: WorkItemStatus) -> WorkItem {
        WorkItem(id: key, companyId: "c", number: 1, key: key, type: .task, title: key, status: status, authorId: "owner",
                 ownerId: owner, reviewerId: reviewer, createdAt: mapFixtureEpoch, updatedAt: mapFixtureEpoch)
    }

    func row(_ handle: String, role: String = "engineer", manager: String?, team: String? = nil, note: String = "")
        -> OrgVacancy {
        OrgVacancy(id: nil, companyId: "c", role: role, handle: handle, managerHandle: manager, team: team,
                   createdAt: mapFixtureEpoch, filledAt: nil, note: note, removedAt: nil)
    }

    func idsByHandle(_ agents: [Agent]) -> [String: String] {
        Dictionary(agents.filter { $0.state != .killed }.map { ($0.name, $0.id) }, uniquingKeysWith: { f, _ in f })
    }

    // MARK: - Tree

    @Test func boardIsRootCEOFirst() throws {
        let t = tree(agentsFromPlan(plan(30, pack: software)))
        let owner = try #require(t.nodes["owner"])
        #expect(owner.tier == .board)
        #expect(owner.parentId == nil)
        #expect(owner.depth == 0)
        #expect(owner.childIds.first == "a-ceo")
        let ceo = try #require(t.nodes["a-ceo"])
        #expect(ceo.tier == .ceo)
        #expect(ceo.parentId == "owner")
        #expect(ceo.depth == 1)
        #expect(ceo.childIds.contains("a-cpo"))
        #expect(ceo.childIds.contains("a-cto"))
        #expect(t.nodes["a-cpo"]?.tier == .csuite)
        #expect(t.nodes["a-cto"]?.tier == .csuite)
        #expect(t.order.first == "owner")
        #expect(t.order[1] == "a-ceo")
        #expect(Set(t.order) == Set(t.nodes.keys))
        #expect(t.order.count == t.nodes.count)
    }

    @Test func tiersFromRoleKinds() throws {
        let agents = agentsFromPlan(plan(120, pack: software))
        let t = tree(agents)
        let director = try #require(agents.first { $0.role == "director" })
        #expect(t.nodes[director.id]?.tier == .director)
        for a in agents where a.role == "manager" { #expect(t.nodes[a.id]?.tier == .manager) }
        for a in agents where a.role == "engineer" { #expect(t.nodes[a.id]?.tier == .ic) }
        for a in agents where a.role == "qa" || a.role == "designer" || a.role == "architect" {
            #expect(t.nodes[a.id]?.tier == .ic)
        }
        let small = agentsFromPlan(plan(8, pack: software))
        let st = tree(small)
        let merged = try #require(small.first { $0.role == "ceo-cpo" })
        #expect(st.nodes[merged.id]?.tier == .ceo)
        #expect(st.nodes["owner"]?.childIds.first == merged.id)
        let ctoArch = try #require(small.first { $0.role == "cto-architect" })
        #expect(st.nodes[ctoArch.id]?.tier == .csuite)
        #expect(OrgTier.board < OrgTier.ceo && OrgTier.ceo < OrgTier.csuite && OrgTier.csuite < OrgTier.director
                && OrgTier.director < OrgTier.manager && OrgTier.manager < OrgTier.ic)
    }

    @Test func rootsAndOrphansHangUnderBoard() throws {
        var flat = agentsFromPlan(plan(30, pack: software))
        for i in flat.indices { flat[i].managerId = nil }
        let ft = tree(flat)
        let owner = try #require(ft.nodes["owner"])
        #expect(owner.childIds.count == flat.count)
        #expect(owner.childIds.first == "a-ceo")
        #expect(flat.allSatisfy { ft.nodes[$0.id]?.parentId == "owner" })
        // Tiers then handle: the executives follow the CEO, the ICs end the row.
        let tiers = owner.childIds.map { ft.nodes[$0]!.tier }
        #expect(tiers == tiers.sorted())

        var agents = agentsFromPlan(plan(30, pack: software))
        let mgr = try #require(agents.firstIndex { $0.name == "mgr-1" })
        agents[mgr].state = .killed
        let reports = agents.filter { $0.managerId == "a-mgr-1" }
        #expect(!reports.isEmpty)
        let kt = tree(agents)
        #expect(kt.nodes["a-mgr-1"] == nil)
        for r in reports { #expect(kt.nodes[r.id]?.parentId == "owner") }
        #expect(kt.nodes["a-cto"]?.childIds.contains("a-mgr-1") == false)
        // With former agents shown, the killed manager appears but its reports still hang under Board.
        let st = tree(agents, showFormer: true)
        #expect(st.nodes["a-mgr-1"]?.parentId == "a-cto")
        for r in reports { #expect(st.nodes[r.id]?.parentId == "owner") }
    }

    @Test func boardRootsOrderedByTierThenHandleNotReports() throws {
        // Two same-tier orphans under Board; the later handle has a report. Board orders them by handle alone.
        let agents = [agent("aaa", role: "engineer", manager: nil),
                      agent("zzz", role: "engineer", manager: nil),
                      agent("rep", role: "engineer", manager: "zzz")]
        let t = tree(agents)
        #expect(try #require(t.nodes["owner"]).childIds == ["a-aaa", "a-zzz"])
        // Any other parent still puts the manager with reports first.
        let under = [agent("boss", role: "engineer", manager: nil),
                     agent("aaa", role: "engineer", manager: "boss"),
                     agent("zzz", role: "engineer", manager: "boss"),
                     agent("rep", role: "engineer", manager: "zzz")]
        #expect(try #require(tree(under).nodes["a-boss"]).childIds == ["a-zzz", "a-aaa"])
    }

    @Test func cycleBrokenDeterministically() throws {
        let a = agent("alpha", role: "engineer", manager: "beta")
        let b = agent("beta", role: "engineer", manager: "alpha")
        let c = agent("gamma", role: "engineer", manager: "alpha")   // a tail into the cycle keeps its manager
        let t1 = tree([b, c, a])
        let t2 = tree([a, b, c])
        #expect(t1 == t2)
        #expect(t1.nodes["a-alpha"]?.parentId == "owner")
        #expect(t1.nodes["a-beta"]?.parentId == "a-alpha")
        #expect(t1.nodes["a-gamma"]?.parentId == "a-alpha")
        #expect(t1.nodes["a-alpha"]?.depth == 1)
        #expect(t1.nodes["a-beta"]?.depth == 2)
        // A self-loop is a cycle of one.
        let s = agent("solo", role: "engineer", manager: "solo")
        #expect(tree([s]).nodes["a-solo"]?.parentId == "owner")
        // Every node is reachable from Board exactly once.
        #expect(t1.order.count == 4)
    }

    @Test func vacanciesPlaced() throws {
        let agents = agentsFromPlan(plan(30, pack: software))
        let ids = idsByHandle(agents)
        let under = Vacancy(row: row("eng-99", manager: "mgr-1", team: "team-1", note: "backfill"), pack: software,
                            agentIdsByHandle: ids)
        #expect(under.id == "eng-99")
        #expect(under.managerId == "a-mgr-1")
        #expect(under.roleTitle == "Engineer")
        #expect(under.note == "backfill")
        #expect(under.source == .org)
        #expect(under.team == "team-1")
        let noManager = Vacancy(row: row("eng-98", manager: nil), pack: software, agentIdsByHandle: ids)
        #expect(noManager.managerId == nil)
        let unknownRole = Vacancy(row: row("x-1", role: "wizard", manager: "ceo"), pack: software, agentIdsByHandle: ids)
        #expect(unknownRole.roleTitle == "wizard")

        var killedAgents = agents
        killedAgents[killedAgents.firstIndex { $0.name == "mgr-2" }!].state = .killed
        let killedIds = idsByHandle(killedAgents)
        let underKilled = Vacancy(row: row("eng-97", manager: "mgr-2"), pack: software, agentIdsByHandle: killedIds)
        #expect(underKilled.managerId == nil)

        let t = tree(agents, vacancies: [under, noManager])
        let mgr = try #require(t.nodes["a-mgr-1"])
        #expect(mgr.childIds.last == "vacancy:eng-99")
        #expect(t.nodes["vacancy:eng-99"]?.parentId == "a-mgr-1")
        #expect(t.nodes["vacancy:eng-99"]?.tier == .ic)
        #expect(t.nodes["vacancy:eng-98"]?.parentId == "owner")
        #expect(t.nodes["owner"]?.childIds.last == "vacancy:eng-98")

        // A vacancy whose manager id is a killed (omitted) agent hangs under Board too.
        var stale = under
        stale.managerId = "a-mgr-2"
        let kt = tree(killedAgents, vacancies: [stale])
        #expect(kt.nodes["vacancy:eng-99"]?.parentId == "owner")
    }

    @Test func reviewerDottedLinks() {
        let agents: Set<String> = ["a-eng-1", "a-eng-2", "a-mgr-1"]
        let one = DottedLinks.reviewers(items: [item("W-1", owner: "a-eng-1", reviewer: "a-mgr-1", status: .inProgress)],
                                        agents: agents)
        #expect(one == [DottedLink(from: "a-mgr-1", to: "a-eng-1", kind: .reviewer, itemKey: "W-1")])
        #expect(DottedLinks.reviewers(items: [item("W-2", owner: "a-eng-1", reviewer: "a-mgr-1", status: .done)],
                                      agents: agents).isEmpty)
        #expect(DottedLinks.reviewers(items: [item("W-3", owner: "a-eng-1", reviewer: "a-killed", status: .inReview)],
                                      agents: agents).isEmpty)
        #expect(DottedLinks.reviewers(items: [item("W-4", owner: nil, reviewer: "a-mgr-1", status: .inReview)],
                                      agents: agents).isEmpty)
        #expect(DottedLinks.reviewers(items: [item("W-5", owner: "a-eng-1", reviewer: nil, status: .inReview)],
                                      agents: agents).isEmpty)
        let two = DottedLinks.reviewers(items: [
            item("W-10", owner: "a-eng-1", reviewer: "a-mgr-1", status: .inReview),
            item("W-9", owner: "a-eng-1", reviewer: "a-mgr-1", status: .inProgress),
            item("W-11", owner: "a-eng-2", reviewer: "a-mgr-1", status: .inProgress),
        ], agents: agents)
        #expect(two.count == 2)
        #expect(two.first { $0.to == "a-eng-1" }?.itemKey == "W-9")
        #expect(two.first { $0.to == "a-eng-2" }?.itemKey == "W-11")
    }

    @Test func defaultCollapseAboveSixty() throws {
        let sixty = agentsFromPlan(plan(60, pack: software))
        let t60 = tree(sixty)
        #expect(t60.defaultCollapsed(activeCount: 60).isEmpty)
        let sixtyOne = agentsFromPlan(plan(61, pack: software))
        let t61 = tree(sixtyOne)
        let collapsed = t61.defaultCollapsed(activeCount: 61)
        let managersWithReports = sixtyOne.filter { a in a.role == "manager" && !(t61.nodes[a.id]?.childIds.isEmpty ?? true) }
        #expect(!managersWithReports.isEmpty)
        #expect(collapsed == Set(managersWithReports.map(\.id)))
        #expect(sixtyOne.contains { $0.role == "director" })
        for a in sixtyOne where a.role == "director" || t61.nodes[a.id]?.tier == .csuite || a.role == "ceo" {
            #expect(!collapsed.contains(a.id))
        }
        #expect(!collapsed.contains("owner"))
        // A manager without reports is never collapsed.
        let lone = [agent("ceo", role: "ceo", manager: nil), agent("mgr-1", role: "manager", manager: "ceo")]
        #expect(tree(lone).defaultCollapsed(activeCount: 61).isEmpty)
    }

    @Test func focusAndOverrides() throws {
        let big = agentsFromPlan(plan(120, pack: software))
        let bt = tree(big)
        let defaults = bt.defaultCollapsed(activeCount: 120)
        let eng7 = try #require(big.first { $0.name == "eng-7" })
        let manager = try #require(eng7.managerId)
        #expect(defaults.contains(manager))
        let focused = bt.collapsed(defaults: defaults, overrides: [:], focus: eng7.id)
        #expect(!focused.contains(manager))
        for ancestor in bt.ancestors(eng7.id) { #expect(!focused.contains(ancestor)) }
        #expect(focused.isSubset(of: defaults))
        #expect(focused.count == defaults.count - 1)
        // Overrides win over defaults in both directions.
        let expanded = bt.collapsed(defaults: defaults, overrides: [manager: true], focus: nil)
        #expect(!expanded.contains(manager))
        #expect(bt.collapsed(defaults: defaults, overrides: [:], focus: nil) == defaults)

        let small = agentsFromPlan(plan(30, pack: software))
        let st = tree(small)
        #expect(st.defaultCollapsed(activeCount: 30).isEmpty)
        let c = st.collapsed(defaults: [], overrides: ["a-mgr-2": false], focus: nil)
        #expect(c == ["a-mgr-2"])
        // Focus beats an override on an ancestor: the focused agent is always reachable.
        let eng = try #require(small.first { $0.managerId == "a-mgr-2" })
        #expect(st.collapsed(defaults: [], overrides: ["a-mgr-2": false], focus: eng.id).isEmpty)

        // visibleAncestor: the topmost collapsed ancestor, or the node itself.
        #expect(st.visibleAncestor(eng.id, collapsed: c) == "a-mgr-2")
        #expect(st.visibleAncestor(eng.id, collapsed: []) == eng.id)
        #expect(st.visibleAncestor("a-mgr-2", collapsed: c) == "a-mgr-2")
        #expect(st.visibleAncestor(eng.id, collapsed: ["a-mgr-2", "a-cto"]) == "a-cto")
        #expect(st.ancestors(eng.id) == ["a-mgr-2", "a-cto", "a-ceo", "owner"])
        #expect(st.ancestors("owner").isEmpty)
        #expect(st.path(eng.id, "a-cpo") == [eng.id, "a-mgr-2", "a-cto", "a-ceo", "a-cpo"])
        #expect(st.path(eng.id, eng.id) == [eng.id])
        #expect(st.path("a-ceo", eng.id) == ["a-ceo", "a-cto", "a-mgr-2", eng.id])
        #expect(st.path(eng.id, "nope").isEmpty)
    }

    @Test func teamLabelsFromManagers() throws {
        let agents = agentsFromPlan(plan(30, pack: software))
        let t = tree(agents)
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        #expect(t.teamLabel("a-mgr-1", agents: byId) == "TEAM-1")
        #expect(t.teamLabel("a-cto", agents: byId) == nil)
        #expect(t.teamLabel("a-eng-1", agents: byId) == nil)
        #expect(t.teamLabel("owner", agents: byId) == nil)
        var long = agent("mgr-9", role: "manager", manager: "ceo", team: String(repeating: "ß", count: 40))
        long.team = String(repeating: "ß", count: 40)
        let lt = tree([agent("ceo", role: "ceo", manager: nil), long])
        let label = try #require(lt.teamLabel(long.id, agents: [long.id: long]))
        #expect(label.count <= 32)
        #expect(label.hasPrefix("SS"))
    }

    @Test func searchPrefixThenContains() {
        let agents = agentsFromPlan(plan(30, pack: software))
        let t = tree(agents)
        let handles = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
        let roles = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.role) })
        let eng1 = t.search("eng-1", handles: handles, roles: roles)
        #expect(eng1.first == "a-eng-1")
        #expect(eng1.dropFirst().first == "a-eng-10")
        #expect(eng1 == ["a-eng-1", "a-eng-10", "a-eng-11", "a-eng-12", "a-eng-13", "a-eng-14", "a-eng-15", "a-eng-16"])
        #expect(t.search("ENG-1", handles: handles, roles: roles) == eng1)
        let qa = t.search("qa", handles: handles, roles: roles)
        #expect(qa == ["a-qa-1", "a-qa-2", "a-qa-3"])
        // Role-only matches come after handle matches.
        let byRole = t.search("engineer", handles: handles, roles: roles)
        #expect(byRole.count == agents.filter { $0.role == "engineer" }.count)
        #expect(byRole.allSatisfy { roles[$0] == "engineer" })
        let mixed = t.search("mgr", handles: handles, roles: roles)
        #expect(mixed == ["a-mgr-1", "a-mgr-2", "a-mgr-3"])
        #expect(t.search("", handles: handles, roles: roles).isEmpty)
        #expect(t.search("   ", handles: handles, roles: roles).isEmpty)
        #expect(t.search("zzz", handles: handles, roles: roles).isEmpty)
        let big = agentsFromPlan(plan(120, pack: software))
        let bt = tree(big)
        let many = bt.search("eng", handles: Dictionary(uniqueKeysWithValues: big.map { ($0.id, $0.name) }),
                             roles: Dictionary(uniqueKeysWithValues: big.map { ($0.id, $0.role) }))
        #expect(many.count == OrgTree.searchLimit)
        // Only agent ids: never the owner or a vacancy.
        var withExtras = handles
        withExtras["owner"] = "owner"
        withExtras["vacancy:eng-50"] = "eng-50"
        #expect(!t.search("owner", handles: withExtras, roles: roles).contains("owner"))
        #expect(!t.search("eng-50", handles: withExtras, roles: roles).contains("vacancy:eng-50"))
        // An id with no node (a killed or hidden agent still present in `handles`) is never returned.
        withExtras["a-ghost"] = "eng-ghost"
        #expect(!t.search("eng-ghost", handles: withExtras, roles: roles).contains("a-ghost"))
        #expect(t.search("ghost", handles: withExtras, roles: roles).isEmpty)
    }

    // MARK: - Layout

    func assertNoOverlap(_ layout: OrgLayout, sourceLocation: SourceLocation = #_sourceLocation) {
        let rects = Array(layout.cards.values) + Array(layout.stubs.values)
        var overlaps = 0
        for i in rects.indices {
            for j in rects.indices where j > i && rects[i].intersects(rects[j]) { overlaps += 1 }
        }
        #expect(overlaps == 0, "\(overlaps) overlapping rects", sourceLocation: sourceLocation)
    }

    @Test func layoutNoOverlap() {
        for n in [300, 500] {
            let agents = agentsFromPlan(plan(n, pack: software))
            let t = tree(agents)
            let collapsed = t.defaultCollapsed(activeCount: n)
            let layout = OrgLayout.make(tree: t, collapsed: collapsed)
            assertNoOverlap(layout)
            // Every visible node has a card, every collapsed node a stub, nothing else.
            let visible = t.order.filter { id in !t.ancestors(id).contains { collapsed.contains($0) } }
            #expect(Set(layout.cards.keys) == Set(visible))
            #expect(Set(layout.stubs.keys) == collapsed)
            #expect(layout.cards["owner"]?.y == 0)
            #expect(layout.cards.values.allSatisfy { $0.x >= 0 && $0.y >= 0 })
            #expect(layout.size.w > 0 && layout.size.h > 0)
            #expect(layout.cards.values.allSatisfy { $0.x + $0.w <= layout.size.w && $0.y + $0.h <= layout.size.h })
            if n == 300 { #expect(layout.size.w < 12_000) }
            // Every visible non-root node has exactly one connector from its parent.
            for id in visible where id != "owner" {
                #expect(layout.connectors.filter { $0.to == id }.count == 1)
                #expect(layout.connectors.first { $0.to == id }?.from == t.nodes[id]?.parentId)
            }
            // Team bands cover their manager's subtree.
            for (manager, band) in layout.teamBands {
                #expect(t.nodes[manager]?.tier == .manager)
                let card = layout.cards[manager]!
                #expect(band.x <= card.x && band.y <= card.y && band.x + band.w >= card.x + card.w)
            }
            // Deterministic.
            #expect(OrgLayout.make(tree: t, collapsed: collapsed) == layout)
        }
        // Fully expanded at 300 still never overlaps.
        let t = tree(agentsFromPlan(plan(300, pack: software)))
        assertNoOverlap(OrgLayout.make(tree: t, collapsed: []))
    }

    @Test func icColumnLayout() throws {
        var agents = [agent("ceo", role: "ceo", manager: nil), agent("mgr-1", role: "manager", manager: "ceo", team: "t")]
        for i in 1...5 { agents.append(agent("eng-\(i)", role: "engineer", manager: "mgr-1", team: "t", at: Double(i))) }
        let t = tree(agents)
        let layout = OrgLayout.make(tree: t, collapsed: [])
        let mgr = try #require(layout.cards["a-mgr-1"])
        let kids = t.nodes["a-mgr-1"]!.childIds.map { layout.cards[$0]! }
        #expect(kids.count == 5)
        #expect(kids.allSatisfy { $0.x == mgr.x + OrgLayout.indent })
        #expect(kids.first?.y == mgr.y + OrgLayout.card.h + OrgLayout.vGap / 2)
        for (a, b) in zip(kids, kids.dropFirst()) { #expect(b.y - a.y == 52) }
        #expect(kids.allSatisfy { $0.w == 148 && $0.h == 44 })
        // Column connectors: a spine at x0 + indent/2 with a tick to each child.
        let spineX = mgr.x + OrgLayout.indent / 2
        for (child, rect) in zip(t.nodes["a-mgr-1"]!.childIds, kids) {
            let c = try #require(layout.connectors.first { $0.from == "a-mgr-1" && $0.to == child })
            #expect(c.points.first == MapPoint2(x: spineX, y: mgr.y + mgr.h))
            #expect(c.points.last == MapPoint2(x: rect.x, y: rect.mid.y))
        }
        // The band of the manager spans the manager and the column.
        let band = try #require(layout.teamBands["a-mgr-1"])
        #expect(band.x == mgr.x && band.y == mgr.y)
        #expect(band.y + band.h == kids.last!.y + kids.last!.h)
        assertNoOverlap(layout)

        // Collapsed: the manager keeps its card and gains a stub just below it; the ICs have no cards.
        let collapsedLayout = OrgLayout.make(tree: t, collapsed: ["a-mgr-1"])
        let cm = try #require(collapsedLayout.cards["a-mgr-1"])
        let stub = try #require(collapsedLayout.stubs["a-mgr-1"])
        #expect(stub.x == cm.x && stub.y == cm.y + cm.h + OrgLayout.columnGap)
        #expect(stub.w == OrgLayout.stub.w && stub.h == OrgLayout.stub.h)
        #expect(collapsedLayout.cards["a-eng-1"] == nil)
        // A vacancy card is 148 × 32.
        let v = Vacancy(id: "eng-6", role: "engineer", roleTitle: "Engineer", managerId: "a-mgr-1", team: "t", note: "",
                        source: .org)
        let vt = tree(agents, vacancies: [v])
        let vl = OrgLayout.make(tree: vt, collapsed: [])
        let vc = try #require(vl.cards["vacancy:eng-6"])
        #expect(vc.w == OrgLayout.vacancy.w && vc.h == OrgLayout.vacancy.h)
        #expect(vc.x == mgr.x + OrgLayout.indent)
        assertNoOverlap(vl)
    }

    @Test func routeViaLCAOrStraight() throws {
        let agents = agentsFromPlan(plan(30, pack: software))
        let t = tree(agents)
        let layout = OrgLayout.make(tree: t, collapsed: [])
        let team = agents.filter { $0.managerId == "a-mgr-1" && $0.role == "engineer" }
        let (a, b) = (team[0].id, team[1].id)
        let same = layout.route(a, b, tree: t, collapsed: [])
        #expect(same.first == layout.cards[a]?.mid)
        #expect(same.last == layout.cards[b]?.mid)
        #expect(same.contains(layout.cards["a-mgr-1"]!.mid))
        #expect(same.count > 3)
        // A route is one polyline; the elbows between card mids come from the connectors.
        let up = try #require(layout.connectors.first { $0.to == a })
        for p in up.points { #expect(same.contains(p)) }

        // Designer under the CPO to an engineer deep under the CTO: more than six hops → a straight line.
        let big = agentsFromPlan(plan(300, pack: software))
        let bt = tree(big)
        let bl = OrgLayout.make(tree: bt, collapsed: [])
        let designer = try #require(big.first { $0.role == "designer" })
        let eng = try #require(big.first { $0.role == "engineer" })
        #expect(bt.path(designer.id, eng.id).count - 1 > OrgLayout.maxTreeHops)
        let far = bl.route(designer.id, eng.id, tree: bt, collapsed: [])
        #expect(far == [bl.cards[designer.id]!.mid, bl.cards[eng.id]!.mid])

        // A collapsed end maps to the collapsed manager's card.
        let collapsed: Set<String> = ["a-mgr-1"]
        let cl = OrgLayout.make(tree: t, collapsed: collapsed)
        let toCEO = cl.route(a, "a-ceo", tree: t, collapsed: collapsed)
        #expect(toCEO.first == cl.cards["a-mgr-1"]?.mid)
        #expect(toCEO.last == cl.cards["a-ceo"]?.mid)
        // Both ends under the same collapsed manager: one point, the manager.
        #expect(cl.route(a, b, tree: t, collapsed: collapsed) == [cl.cards["a-mgr-1"]!.mid])
        #expect(layout.route(a, "ghost", tree: t, collapsed: []).isEmpty)
    }

    @Test func emptyAndSingle() throws {
        let empty = OrgLayout.make(tree: tree([]), collapsed: [])
        #expect(empty.cards.count == 1)
        let owner = try #require(empty.cards["owner"])
        #expect(owner.y == 0)
        #expect(owner.w == OrgLayout.card.w && owner.h == OrgLayout.card.h)
        #expect(empty.stubs.isEmpty && empty.connectors.isEmpty && empty.teamBands.isEmpty)
        #expect(empty.size.w == OrgLayout.card.w && empty.size.h == OrgLayout.card.h)

        let one = agent("ceo", role: "ceo", manager: nil)
        let t = tree([one])
        let single = OrgLayout.make(tree: t, collapsed: [])
        #expect(single.cards.count == 2)
        let ceo = try #require(single.cards["a-ceo"])
        #expect(ceo.y == OrgLayout.card.h + OrgLayout.vGap)
        #expect(ceo.mid.x == single.cards["owner"]?.mid.x)
        #expect(single.connectors.count == 1)
        #expect(single.connectors.first?.from == "owner" && single.connectors.first?.to == "a-ceo")
        #expect(t.defaultCollapsed(activeCount: 1).isEmpty)
        #expect(t.teamLabel("a-ceo", agents: [one.id: one]) == nil)
    }
}
