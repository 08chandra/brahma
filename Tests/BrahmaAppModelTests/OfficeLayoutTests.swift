import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// The office floor plan (spec §5.2): a pure function of the `MapModel`. Models come from `SyntheticCompany.make` and
/// hand-built agents of the software pack; nothing here touches the Keychain or a store.
@Suite(.scratch) struct OfficeLayoutTests {
    let software = SoftwarePack.pack

    // MARK: - Fixtures

    func agent(_ handle: String, role: String, manager: String?, team: String? = nil, state: AgentState = .ready)
        -> Agent {
        var a = Agent(id: "a-\(handle)", companyId: "c", name: handle, role: role, model: "sonnet", sessionId: "s",
                      sessionStarted: false, state: state, blocker: nil, requestedBlocker: nil, paused: false,
                      readySince: nil, createdAt: mapFixtureEpoch)
        a.managerId = manager.map { "a-\($0)" }
        a.team = team
        return a
    }

    func vacancy(_ id: String, manager: String?) -> Vacancy {
        Vacancy(id: id, role: "engineer", roleTitle: "Engineer", managerId: manager.map { "a-\($0)" }, team: nil, note: "",
                source: .org)
    }

    func model(_ agents: [Agent], vacancies: [Vacancy] = [], showFormer: Bool = false) -> MapModel {
        var m = MapModel()
        if showFormer { m.setShowFormer(true) }
        m.apply(MapInputs(agents: agents, pack: software, vacancies: vacancies), now: 0)
        return m
    }

    func synthetic(_ n: Int, showFormer: Bool = false) -> MapModel {
        let c = SyntheticCompany.make(agents: n)
        var m = MapModel()
        if showFormer { m.setShowFormer(true) }
        m.apply(MapInputs(agents: c.agents, pack: c.pack, currentItems: c.currentItems, blockers: c.blockers,
                          vacancies: c.vacancies, meetings: c.meetings, people: c.people, itemPhases: c.itemPhases,
                          reviewing: c.reviewing, openAsks: c.openAsks), now: 0)
        return m
    }

    func contains(_ outer: MapRect, _ inner: MapRect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.w <= outer.x + outer.w
            && inner.y + inner.h <= outer.y + outer.h
    }

    func contains(_ r: MapRect, _ p: MapPoint2) -> Bool {
        p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
    }

    func distance(_ a: MapPoint2, _ b: MapPoint2) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    func isAgent(_ id: String) -> Bool { id != "owner" && !id.hasPrefix("vacancy:") }

    func hasOffice(_ tree: OrgTree, _ id: String) -> Bool {
        [.ceo, .csuite, .director].contains(tree.nodes[id]?.tier)
    }

    /// The pod reports of `id`: agent children with no children of their own and no office.
    func podReports(_ tree: OrgTree, _ id: String) -> [String] {
        (tree.nodes[id]?.childIds ?? []).filter {
            isAgent($0) && !hasOffice(tree, $0) && (tree.nodes[$0]?.childIds.isEmpty ?? true)
        }
    }

    func desks(in layout: OfficeLayout, pod: String) -> [OfficeDesk] {
        layout.desks.values.filter { $0.podId == pod }
    }

    // MARK: - Tests

    @Test func pinnedValues() {
        #expect(OfficeLayout.desk == (w: 36, h: 24, face: 6))
        #expect(OfficeLayout.chair == (w: 12, h: 8))
        #expect(OfficeLayout.pod.columns == 2)
        #expect(OfficeLayout.pod.gap == 8 && OfficeLayout.pod.aisle == 16 && OfficeLayout.pod.padding == 12)
        #expect(OfficeLayout.pod.head == 36)
        #expect(OfficeLayout.corridor == 32 && OfficeLayout.wingGap == 48 && OfficeLayout.roomsStrip == 140)
        #expect(OfficeLayout.boardRoom == (w: 200, h: 120))
        #expect(OfficeLayout.ceoOffice == (w: 160, h: 120))
        #expect(OfficeLayout.execOffice == (w: 120, h: 100))
        #expect(OfficeLayout.directorOffice == (w: 120, h: 100))
        #expect(OfficeLayout.reviewRoom == (w: 260, h: 120))
        #expect(OfficeLayout.breakRoom == (w: 180, h: 120))
        #expect(OfficeLayout.mailRoom == (w: 160, h: 120))
        #expect(OfficeLayout.reviewSeats == 12)
        #expect(OfficeLayout.doorSpots == 8)
    }

    @Test(arguments: [12, 50, 300]) func everyLivingAgentHasADesk(n: Int) {
        let m = synthetic(n)
        let layout = OfficeLayout.make(model: m)
        let living = Set(m.agents.values.filter { $0.state != .killed }.map(\.id))
        let killed = Set(m.agents.values.filter { $0.state == .killed }.map(\.id))
        #expect(living.isSubset(of: Set(layout.desks.keys)))
        #expect(killed.isDisjoint(with: Set(layout.desks.keys)))
        // Every vacancy on the chart has a desk too, and nothing else does.
        let seats = Set(m.tree.order.filter { $0.hasPrefix("vacancy:") })
        #expect(Set(layout.desks.keys) == living.union(seats))
        for (id, d) in layout.desks { #expect(d.id == id) }

        let former = OfficeLayout.make(model: synthetic(n, showFormer: true))
        #expect(living.union(killed).isSubset(of: Set(former.desks.keys)))
    }

    @Test func noDeskOrRoomOverlaps() {
        let layout = OfficeLayout.make(model: synthetic(300))
        let desks = layout.desks.values.sorted { $0.id < $1.id }
        for (i, a) in desks.enumerated() {
            for b in desks[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(a.id) overlaps \(b.id)") }
        }
        for d in desks {
            for room in layout.rooms.values where room.id != d.roomId {
                #expect(!d.rect.intersects(room.rect), "\(d.id) intersects \(room.id)")
            }
            if let r = d.roomId { #expect(contains(layout.rooms[r]!.rect, d.rect), "\(d.id) outside \(r)") }
            if let p = d.podId { #expect(contains(layout.pods[p]!.rect, d.rect), "\(d.id) outside \(p)") }
            for c in layout.corridors { #expect(!d.rect.intersects(c), "\(d.id) in a corridor") }
            #expect(d.rect.w == OfficeLayout.desk.w && d.rect.h == OfficeLayout.desk.h + OfficeLayout.desk.face)
        }
        let pods = layout.pods.values.sorted { $0.id < $1.id }
        for (i, a) in pods.enumerated() {
            for b in pods[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(a.id) overlaps \(b.id)") }
            for room in layout.rooms.values { #expect(!a.rect.intersects(room.rect), "\(a.id) intersects \(room.id)") }
            for c in layout.corridors { #expect(!a.rect.intersects(c), "\(a.id) in a corridor") }
            #expect(!a.labelRect.intersects(a.rect))
        }
        let rooms = layout.rooms.values.sorted { $0.id < $1.id }
        for (i, a) in rooms.enumerated() {
            for b in rooms[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(a.id) overlaps \(b.id)") }
            for c in layout.corridors { #expect(!a.rect.intersects(c), "\(a.id) in a corridor") }
            #expect(a.rect.x >= 0 && a.rect.y >= 0 && a.rect.x + a.rect.w <= layout.size.w
                    && a.rect.y + a.rect.h <= layout.size.h)
        }
    }

    @Test func ceoCornerAndExecutiveOffices() throws {
        let m = synthetic(50)
        let layout = OfficeLayout.make(model: m)
        let ceo = try #require(layout.rooms["room:ceo"])
        #expect(ceo.kind == .ceo)
        #expect(ceo.title == "CEO")
        #expect(ceo.rect.x + ceo.rect.w == layout.size.w)
        #expect(ceo.rect.y == 0)
        #expect(ceo.rect.w == OfficeLayout.ceoOffice.w && ceo.rect.h == OfficeLayout.ceoOffice.h)
        let board = try #require(layout.rooms["room:board"])
        #expect(board.rect == MapRect(x: 0, y: 0, w: 200, h: 120))
        #expect(board.title == "BOARD ROOM")
        let ceoId = try #require(m.tree.order.first { m.tree.nodes[$0]?.tier == .ceo })
        #expect(layout.desks[ceoId]?.roomId == "room:ceo")

        let csuite = m.tree.order.filter { m.tree.nodes[$0]?.tier == .csuite }
        #expect(!csuite.isEmpty)
        let execRooms = layout.rooms.values.filter { if case .executive = $0.kind { true } else { false } }
        #expect(execRooms.count == csuite.count)
        var lastX = board.rect.x + board.rect.w
        for id in csuite {
            let room = try #require(layout.rooms["office:\(id)"])
            #expect(room.kind == .executive(agentId: id))
            #expect(room.title == m.agents[id]?.role)
            #expect(room.rect.y == 0 && room.rect.x >= lastX)
            #expect(room.rect.w == OfficeLayout.execOffice.w && room.rect.h == OfficeLayout.execOffice.h)
            lastX = room.rect.x + room.rect.w
            #expect(layout.desks[id]?.roomId == room.id)
        }
        #expect(lastX <= ceo.rect.x)
        for (id, title) in [("room:review", "REVIEW"), ("room:break", "BREAK ROOM"), ("room:mail", "MAIL ROOM")] {
            #expect(layout.rooms[id]?.title == title)
        }
    }

    @Test func roomsStripAlongTheBottom() throws {
        let layout = OfficeLayout.make(model: synthetic(50))
        let brk = try #require(layout.rooms["room:break"]), review = try #require(layout.rooms["room:review"])
        let mail = try #require(layout.rooms["room:mail"])
        let stripY = layout.size.h - OfficeLayout.roomsStrip
        for r in [brk, review, mail] { #expect(r.rect.y >= stripY && r.rect.y + r.rect.h <= layout.size.h) }
        #expect(brk.rect.x == 0)
        #expect(abs(review.rect.mid.x - layout.size.w / 2) < 0.001)
        #expect(mail.rect.x + mail.rect.w == layout.size.w)
        // Nothing but the shared rooms below the strip line.
        for d in layout.desks.values { #expect(d.rect.y + d.rect.h <= stripY) }
    }

    @Test func podPerManagerInsideItsWing() throws {
        let m = synthetic(300)
        let tree = m.tree
        let layout = OfficeLayout.make(model: m)
        for id in tree.order where isAgent(id) && !podReports(tree, id).isEmpty {
            let pod = try #require(layout.pods["pod:\(id)"], "no pod for \(id)")
            #expect(pod.managerId == id)
            let held = Set(desks(in: layout, pod: pod.id).map(\.id))
            #expect(Set(podReports(tree, id)).isSubset(of: held))
        }
        for pod in layout.pods.values {
            guard let owner = pod.managerId else { continue }
            let director = ([owner] + tree.ancestors(owner)).first { tree.nodes[$0]?.tier == .director }
            let wing = try #require(layout.wings.first { $0.podIds.contains(pod.id) })
            if let director {
                #expect(wing.id == "wing:\(director)")
                #expect(wing.officeId == "office:\(director)")
            } else {
                #expect(wing.id == "wing:floor")
                #expect(wing.title == "FLOOR")
            }
            #expect(contains(wing.rect, pod.rect))
            #expect(contains(wing.rect, pod.labelRect))
        }
        let pods = layout.pods.values.sorted { $0.id < $1.id }
        for (i, a) in pods.enumerated() {
            for b in pods[(i + 1)...] { #expect(!a.rect.intersects(b.rect)) }
        }
        let wings = layout.wings
        for (i, a) in wings.enumerated() {
            for b in wings[(i + 1)...] { #expect(!a.rect.intersects(b.rect), "\(a.id) overlaps \(b.id)") }
        }
        for d in tree.order where tree.nodes[d]?.tier == .director {
            let wing = try #require(layout.wings.first { $0.id == "wing:\(d)" })
            let office = try #require(layout.rooms["office:\(d)"])
            #expect(office.kind == .director(agentId: d))
            #expect(contains(wing.rect, office.rect))
        }
    }

    @Test func podHeightAndDeskPlacement() throws {
        // A manager with five ICs: head desk plus three rows of two.
        var agents = [agent("ceo", role: "ceo", manager: nil), agent("m", role: "manager", manager: "ceo", team: "core")]
        for i in 1...5 { agents.append(agent("e\(i)", role: "engineer", manager: "m", team: "core")) }
        let m = model(agents)
        let layout = OfficeLayout.make(model: m)
        let pod = try #require(layout.pods["pod:a-m"])
        let row = OfficeLayout.desk.h + OfficeLayout.desk.face + OfficeLayout.chair.h + OfficeLayout.pod.gap
        #expect(pod.rect.h == OfficeLayout.pod.head + 3 * row)
        #expect(pod.rect.w == 2 * OfficeLayout.pod.padding + 2 * OfficeLayout.desk.w + OfficeLayout.pod.aisle)
        #expect(pod.title == m.teamCard(managerId: "a-m")?.title)
        let head = try #require(layout.desks["a-m"])
        #expect(head.podId == pod.id)
        #expect(head.rect.y + head.rect.h <= pod.rect.y + OfficeLayout.pod.head)
        #expect(head.facesDown)
        for i in 1...5 {
            let d = try #require(layout.desks["a-e\(i)"])
            #expect(d.podId == pod.id)
            #expect(d.rect.y >= pod.rect.y + OfficeLayout.pod.head)
            #expect(contains(pod.rect, d.seat))
        }
        // Facing pairs: the first row faces down, the second up.
        let rows = Dictionary(grouping: desks(in: layout, pod: pod.id).filter { $0.id != "a-m" }, by: \.rect.y)
        let ys = rows.keys.sorted()
        #expect(ys.count == 3)
        #expect(rows[ys[0]]!.allSatisfy { $0.facesDown })
        #expect(rows[ys[1]]!.allSatisfy { !$0.facesDown })
        #expect(contains(pod.rect, pod.board))
    }

    @Test func everyTreeShapeGetsDesks() throws {
        // CEO + 4 ICs: the corner office and one pod without a head desk.
        do {
            var agents = [agent("ceo", role: "ceo", manager: nil)]
            for i in 1...4 { agents.append(agent("e\(i)", role: "engineer", manager: "ceo")) }
            let m = model(agents)
            let layout = OfficeLayout.make(model: m)
            #expect(layout.rooms["room:ceo"] != nil)
            let pod = try #require(layout.pods["pod:a-ceo"])
            #expect(desks(in: layout, pod: pod.id).count == 4)
            #expect(layout.desks["a-ceo"]?.roomId == "room:ceo")
            #expect(layout.desks["a-ceo"]?.podId == nil)
            #expect(pod.title == pod.department.title)
            #expect(Set(layout.desks.keys) == Set(agents.map(\.id)))
        }
        // A director with 2 direct ICs and 2 managers: the director's pod first in its wing.
        do {
            var agents = [agent("ceo", role: "ceo", manager: nil), agent("cto", role: "cto", manager: "ceo"),
                          agent("dir", role: "director", manager: "cto"),
                          agent("i1", role: "engineer", manager: "dir"), agent("i2", role: "engineer", manager: "dir"),
                          agent("m1", role: "manager", manager: "dir", team: "t1"),
                          agent("m2", role: "manager", manager: "dir", team: "t2")]
            for i in 1...2 {
                agents.append(agent("x\(i)", role: "engineer", manager: "m1", team: "t1"))
                agents.append(agent("y\(i)", role: "engineer", manager: "m2", team: "t2"))
            }
            let layout = OfficeLayout.make(model: model(agents))
            let wing = try #require(layout.wings.first { $0.id == "wing:a-dir" })
            #expect(wing.officeId == "office:a-dir")
            #expect(wing.podIds == ["pod:a-dir", "pod:a-m1", "pod:a-m2"])
            let office = try #require(layout.rooms["office:a-dir"])
            let pd = try #require(layout.pods["pod:a-dir"]), p1 = try #require(layout.pods["pod:a-m1"])
            let p2 = try #require(layout.pods["pod:a-m2"])
            #expect(office.rect.x < pd.rect.x && pd.rect.x < p1.rect.x && p1.rect.x < p2.rect.x)
            #expect(Set(desks(in: layout, pod: "pod:a-dir").map(\.id)) == ["a-i1", "a-i2"])
            #expect(layout.desks["a-dir"]?.roomId == "office:a-dir")
            #expect(layout.desks["a-m1"]?.podId == "pod:a-m1")
            #expect(Set(layout.desks.keys) == Set(agents.map(\.id)))
        }
        // A manager whose report is a manager-with-reports: two sibling pods, the parent's first, never nested.
        do {
            let agents = [agent("ceo", role: "ceo", manager: nil), agent("m1", role: "manager", manager: "ceo"),
                          agent("m2", role: "manager", manager: "m1"),
                          agent("e1", role: "engineer", manager: "m2"), agent("e2", role: "engineer", manager: "m2")]
            let layout = OfficeLayout.make(model: model(agents))
            let p1 = try #require(layout.pods["pod:a-m1"]), p2 = try #require(layout.pods["pod:a-m2"])
            #expect(p1.rect.x < p2.rect.x)
            #expect(!p1.rect.intersects(p2.rect))
            #expect(layout.desks["a-m1"]?.podId == p1.id)
            #expect(layout.desks["a-m2"]?.podId == p2.id)
            #expect(layout.wings.first { $0.id == "wing:floor" }?.podIds == ["pod:a-m1", "pod:a-m2"])
            #expect(Set(layout.desks.keys) == Set(agents.map(\.id)))
        }
        // An executive with 3 IC reports: an office plus a pod in the FLOOR wing.
        do {
            var agents = [agent("ceo", role: "ceo", manager: nil), agent("cto", role: "cto", manager: "ceo")]
            for i in 1...3 { agents.append(agent("e\(i)", role: "engineer", manager: "cto")) }
            let layout = OfficeLayout.make(model: model(agents))
            #expect(layout.rooms["office:a-cto"]?.kind == .executive(agentId: "a-cto"))
            let floor = try #require(layout.wings.first { $0.id == "wing:floor" })
            #expect(floor.title == "FLOOR" && floor.officeId == nil)
            #expect(floor.podIds == ["pod:a-cto"])
            #expect(desks(in: layout, pod: "pod:a-cto").count == 3)
            #expect(layout.desks["a-cto"]?.roomId == "office:a-cto")
            #expect(layout.pods["pod:a-ceo"] == nil)
        }
    }

    @Test func vacancyPlacement() throws {
        let agents = [agent("ceo", role: "ceo", manager: nil), agent("m1", role: "manager", manager: "ceo"),
                      agent("e1", role: "engineer", manager: "m1"), agent("e2", role: "engineer", manager: "m1"),
                      agent("m2", role: "manager", manager: "ceo"),
                      agent("gone", role: "manager", manager: "ceo", state: .killed)]
        let vacancies = [vacancy("v1", manager: "m1"), vacancy("v2", manager: "absent"), vacancy("v3", manager: "gone"),
                         vacancy("v4", manager: "m2")]
        let layout = OfficeLayout.make(model: model(agents, vacancies: vacancies))
        // With a living manager: the last desk of that manager's pod.
        let v1 = try #require(layout.desks["vacancy:v1"])
        #expect(v1.podId == "pod:a-m1")
        let pod1 = desks(in: layout, pod: "pod:a-m1")
        #expect(pod1.count == 4)
        let last = pod1.max { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
        #expect(last?.id == "vacancy:v1")
        // A manager whose only report is the seat gets a pod for it.
        #expect(layout.desks["vacancy:v4"]?.podId == "pod:a-m2")
        #expect(layout.desks["a-m2"]?.podId == "pod:a-m2")
        // Without one (absent or killed): the anteroom beside the board room.
        let board = try #require(layout.rooms["room:board"])
        let ante = try #require(layout.anteroom)
        #expect(ante.x == board.rect.x + board.rect.w && ante.y == 0)
        #expect(!ante.intersects(board.rect))
        for id in ["vacancy:v2", "vacancy:v3"] {
            let d = try #require(layout.desks[id])
            #expect(d.podId == nil && d.roomId == nil)
            #expect(contains(ante, d.rect))
        }
        for room in layout.rooms.values { #expect(!ante.intersects(room.rect)) }
        // No orphan seat, no anteroom.
        #expect(OfficeLayout.make(model: model(agents)).anteroom == nil)
    }

    @Test func oddOrgs() throws {
        // Zero agents: the board room and the shared rooms, no desks.
        for m in [MapModel(), model([])] {
            let empty = OfficeLayout.make(model: m)
            #expect(Set(empty.rooms.keys) == ["room:board", "room:review", "room:break", "room:mail"])
            #expect(empty.desks.isEmpty && empty.pods.isEmpty)
            #expect(empty.size.w > 0 && empty.size.h > 0)
            #expect(empty.location(.owner) == empty.rooms["room:board"]?.door)
        }
        // No managers (every agent a root): department pods.
        let roots = [agent("e1", role: "engineer", manager: nil), agent("e2", role: "engineer", manager: nil),
                     agent("d1", role: "designer", manager: nil), agent("q1", role: "qa", manager: nil)]
        let flat = OfficeLayout.make(model: model(roots))
        #expect(Set(flat.pods.keys) == ["pod:dept:engineering", "pod:dept:design", "pod:dept:quality"])
        #expect(flat.pods["pod:dept:design"]?.title == "DESIGN")
        #expect(flat.pods["pod:dept:design"]?.managerId == nil)
        #expect(desks(in: flat, pod: "pod:dept:engineering").count == 2)
        #expect(Set(flat.desks.keys) == Set(roots.map(\.id)))
        #expect(flat.wings.map(\.id) == ["wing:floor"])
        // Department pods come after the floor wing's manager pods.
        let mixed = OfficeLayout.make(model: model(roots + [agent("m", role: "manager", manager: nil),
                                                            agent("x", role: "engineer", manager: "m")]))
        #expect(mixed.wings.first?.podIds.first == "pod:a-m")
        // Only executives: offices only.
        let execs = [agent("ceo", role: "ceo", manager: nil), agent("cto", role: "cto", manager: "ceo"),
                     agent("cpo", role: "cpo", manager: "ceo")]
        let top = OfficeLayout.make(model: model(execs))
        #expect(top.pods.isEmpty && top.wings.isEmpty)
        #expect(top.rooms["room:ceo"] != nil && top.rooms["office:a-cto"] != nil && top.rooms["office:a-cpo"] != nil)
        #expect(top.desks.values.allSatisfy { $0.roomId != nil })
        #expect(top.desks.count == 3)
        // 300 desks in roughly 2 600 × 1 500 (spec §5.2); 500 agents fit the pinned bounds.
        let mid = OfficeLayout.make(model: synthetic(300))
        #expect(mid.size.w <= 2700 && mid.size.h <= 1500, "\(mid.size)")
        let big = OfficeLayout.make(model: synthetic(500))
        #expect(big.size.w <= 3000, "w \(big.size.w)")
        #expect(big.size.h <= 1800, "h \(big.size.h)")
    }

    @Test func deterministicAndStableUnderHire() throws {
        let c = SyntheticCompany.make(agents: 50)
        let m = synthetic(50)
        let a = OfficeLayout.make(model: m), b = OfficeLayout.make(model: m)
        #expect(a == b)
        #expect(a == OfficeLayout.make(model: synthetic(50)))

        // Hire a leaf IC (sorting last) into the last pod.
        let lastPodId = try #require(a.wings.last?.podIds.last)
        let lastPod = try #require(a.pods[lastPodId])
        let manager = try #require(lastPod.managerId)
        var hire = Agent(id: "demo-zzz-1", companyId: "demo", name: "zzz-1", role: "engineer", model: "sonnet",
                         sessionId: "s", sessionStarted: false, state: .ready, paused: false,
                         createdAt: mapFixtureEpoch.addingTimeInterval(10_000))
        hire.managerId = manager
        var grown = MapModel()
        grown.apply(MapInputs(agents: c.agents + [hire], pack: c.pack, vacancies: c.vacancies), now: 0)
        let after = OfficeLayout.make(model: grown)
        #expect(after.desks[hire.id]?.podId == lastPodId)
        for (id, desk) in a.desks where desk.podId != lastPodId {
            #expect(after.desks[id]?.rect == desk.rect, "\(id) moved")
        }
        for (id, pod) in a.pods where id != lastPodId { #expect(after.pods[id]?.rect == pod.rect, "\(id) moved") }
    }

    // MARK: Routes

    /// Points along the segment every 0.5 pt, ends included.
    func samples(_ p: MapPoint2, _ q: MapPoint2) -> [MapPoint2] {
        let n = max(1, Int((distance(p, q) / 0.5).rounded(.up)))
        return (0...n).map { i in
            let t = Double(i) / Double(n)
            return MapPoint2(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
        }
    }

    /// True when the segment crosses the rect's interior.
    func crossesInterior(_ p: MapPoint2, _ q: MapPoint2, _ r: MapRect) -> Bool {
        let minX = min(p.x, q.x), maxX = max(p.x, q.x), minY = min(p.y, q.y), maxY = max(p.y, q.y)
        if minX == maxX { return r.x < minX && minX < r.x + r.w && minY < r.y + r.h && r.y < maxY }
        return r.y < minY && minY < r.y + r.h && minX < r.x + r.w && r.x < maxX
    }

    func endArea(_ layout: OfficeLayout, _ desk: OfficeDesk) -> MapRect? {
        desk.podId.flatMap { layout.pods[$0]?.rect } ?? desk.roomId.flatMap { layout.rooms[$0]?.rect }
    }

    func checkRoute(_ layout: OfficeLayout, from: MapPoint2, to: MapPoint2, ends: [MapRect]) {
        let route = layout.route(from: from, to: to)
        #expect(route.first == from)
        #expect(route.last == to)
        guard route.count >= 2 else { return }
        for (p, q) in zip(route, route.dropFirst()) {
            #expect(p.x == q.x || p.y == q.y, "diagonal segment \(p) → \(q)")
        }
        let allowed = layout.corridors + ends
        let segments = Array(zip(route, route.dropFirst()))
        guard segments.count > 2 else { return }
        for (p, q) in segments[1..<(segments.count - 1)] {
            for s in samples(p, q) {
                #expect(allowed.contains { contains($0, s) }, "\(s) of \(p) → \(q) outside the corridors")
            }
            for d in layout.desks.values {
                #expect(!crossesInterior(p, q, d.rect), "\(p) → \(q) crosses desk \(d.id)")
            }
        }
    }

    @Test func routesStayInCorridors() {
        let layout = OfficeLayout.make(model: synthetic(50))
        let ids = layout.desks.keys.filter { !$0.hasPrefix("vacancy:") }.sorted()
        var rng = SplitMix64(seed: 7)
        for _ in 0..<40 {
            let a = layout.desks[ids[Int.random(in: 0..<ids.count, using: &rng)]]!
            let b = layout.desks[ids[Int.random(in: 0..<ids.count, using: &rng)]]!
            checkRoute(layout, from: a.seat, to: b.seat, ends: [endArea(layout, b)].compactMap { $0 })
        }
        // The owner's door, the review room and the mail room.
        let board = layout.rooms["room:board"]!, review = layout.rooms["room:review"]!
        let any = layout.desks[ids[0]]!
        checkRoute(layout, from: board.door, to: layout.reviewSeat(3), ends: [review.rect])
        checkRoute(layout, from: any.seat, to: layout.mailCounter(0), ends: [layout.rooms["room:mail"]!.rect])
        checkRoute(layout, from: layout.doorSpot(2), to: any.seat, ends: [endArea(layout, any)].compactMap { $0 })
        // Same point: a one-point route.
        #expect(layout.route(from: any.seat, to: any.seat) == [any.seat])
    }

    @Test func locationsAndSeats() throws {
        let m = synthetic(50)
        let layout = OfficeLayout.make(model: m)
        let board = try #require(layout.rooms["room:board"])
        #expect(layout.location(.owner) == board.door)
        for (id, desk) in layout.desks where isAgent(id) { #expect(layout.location(.agent(id)) == desk.seat) }
        #expect(layout.location(.agent("nobody")) == nil)

        let review = try #require(layout.rooms["room:review"])
        let seats = (0..<OfficeLayout.reviewSeats).map(layout.reviewSeat)
        #expect(Set(seats).count == OfficeLayout.reviewSeats)
        for s in seats { #expect(contains(review.rect, s)) }
        for i in [12, 13, 40, 400] {
            #expect(contains(review.rect, layout.reviewSeat(i)))
            #expect(!seats.contains(layout.reviewSeat(i)))
        }

        let spots = (0..<OfficeLayout.doorSpots).map(layout.doorSpot)
        #expect(Set(spots).count == OfficeLayout.doorSpots)
        for s in spots {
            #expect(!contains(board.rect, s))
            #expect(distance(s, board.door) <= 2 * OfficeLayout.corridor)
        }
        for i in [8, 9, 60, 300] {
            let s = layout.doorSpot(i)
            #expect(!contains(board.rect, s) && !spots.contains(s))
            #expect(s.x >= 0 && s.x <= layout.size.w && s.y >= 0 && s.y <= layout.size.h)
        }

        #expect(contains(try #require(layout.rooms["room:break"]).rect, layout.fameShelf()))
        let mail = try #require(layout.rooms["room:mail"])
        let counters = (0..<9).map(layout.mailCounter)
        #expect(Set(counters).count == 9)
        for i in [0, 5, 9, 27, 100] { #expect(contains(mail.rect, layout.mailCounter(i))) }
    }
}
