import Testing
import Foundation
import SpriteKit
import Metal
import AppKit
@testable import BrahmaCore
@testable import BrahmaAppModel
@testable import BrahmaMapKit

/// The office floor at rest (spec §5.1–5.5, §5.7): rooms, pods, desks, resting figures, level of detail, hit tests and the
/// snapshots. Models are built from `SyntheticCompany.make` directly, with its item phases, reviewers, perks and open
/// asks (ruling R15: the demo controller does not pass them yet).
@MainActor
@Suite(.scratch) struct OfficeSceneTests {
    static let size = CGSize(width: 1600, height: 900)

    // MARK: - Helpers

    /// The synthetic company's first `n` agents' worth of structure with `edit` applied to the agents and `inputs` to the
    /// assembled inputs (phases, reviewers, people and asks default to the synthetic company's).
    static func model(agents n: Int = 12, showFormer: Bool = false, edit: (inout [Agent]) -> Void = { _ in },
                      inputs: (inout MapInputs) -> Void = { _ in }) -> MapModel {
        let made = SyntheticCompany.make(agents: n)
        var agents = made.agents
        edit(&agents)
        var input = MapInputs(agents: agents, pack: made.pack, currentItems: made.currentItems, blockers: made.blockers,
                              vacancies: made.vacancies, meetings: made.meetings, people: made.people,
                              itemPhases: made.itemPhases, reviewing: made.reviewing, openAsks: made.openAsks)
        inputs(&input)
        var model = MapModel()
        model.setShowFormer(showFormer)
        model.apply(input, now: 0)
        return model
    }

    static func scene(_ model: MapModel, reduceMotion: Bool = false) -> OfficeScene {
        let scene = OfficeScene(size: size)
        scene.reduceMotion = reduceMotion
        scene.rebuild(model: model)
        return scene
    }

    static func living(_ model: MapModel) -> [MapAgent] {
        model.agents.values.filter { $0.state != .killed }.sorted { $0.id < $1.id }
    }

    /// A layout point as the scene draws it (y up).
    static func scenePoint(_ p: MapPoint2) -> CGPoint { CGPoint(x: p.x, y: -p.y) }

    static func near(_ a: CGPoint?, _ b: CGPoint, within d: CGFloat = 1) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= d && abs(a.y - b.y) <= d
    }

    /// The badge spec §5.6 gives each activity; idle and gone have none.
    static func badge(_ a: OfficeActivity) -> OfficeTextures.BadgeGlyph? {
        switch a {
        case .typing: .typing
        case .reviewing, .meeting: .reviewing
        case .blocked: .blocked
        case .waitingOnOwner: .waiting
        case .away: .away
        case .idle, .gone: nil
        }
    }

    // MARK: - Floor

    @Test func oneDeskPerLivingAgentAndRooms() throws {
        let model = Self.model(agents: 50)
        let scene = Self.scene(model)
        #expect(scene.mode == .office)
        let killed = model.agents.values.filter { $0.state == .killed }
        for agent in Self.living(model) { #expect(scene.deskNode(agent.id) != nil, "desk for \(agent.id)") }
        for agent in killed { #expect(scene.deskNode(agent.id) == nil, "no desk for killed \(agent.id)") }
        for v in model.vacancies { #expect(scene.deskNode("vacancy:" + v.id) != nil) }
        for id in ["room:board", "room:ceo", "room:review", "room:break", "room:mail"] {
            #expect(scene.roomRect(id) != nil, "\(id)")
        }
        // Every desk is drawn at its layout rect, y flipped.
        let ceo = try #require(model.tree.order.first { model.tree.nodes[$0]?.tier == .ceo })
        let r = try #require(scene.layout.desks[ceo]?.rect)
        #expect(scene.deskRect(ceo) == CGRect(x: r.x, y: -(r.y + r.h), width: r.w, height: r.h))
        #expect(scene.targetRect(ceo) == scene.deskRect(ceo))
        #expect(scene.roomRect("room:ceo")?.contains(try #require(scene.deskRect(ceo)).center) == true)
    }

    @Test func hitTests() throws {
        let model = Self.model(agents: 50)
        let scene = Self.scene(model)
        let agent = try #require(Self.living(model).first)
        #expect(scene.hit(at: try #require(scene.deskRect(agent.id)).center) == .agent(agent.id))

        // The HIRING desk: dashed, unlit, with its placard.
        let vacancy = try #require(model.vacancies.first)
        let seat = try #require(scene.deskNode("vacancy:" + vacancy.id))
        #expect(seat.isVacancy && seat.hasPlacard && !seat.lampOn)
        #expect(scene.hit(at: try #require(scene.deskRect("vacancy:" + vacancy.id)).center) == .vacancy(vacancy.id))

        #expect(scene.hit(at: try #require(scene.roomRect("room:board")).center) == .owner)

        // Only a pod whose manager sits at its head desk has a team hit (spec §5.2); a pod whose owner has an office
        // (here the CEO's or a director's) has none, nor has a department pod.
        func labelPoint(_ pod: OfficePod) -> CGPoint { CGPoint(x: pod.labelRect.x + 4, y: -(pod.labelRect.y + pod.labelRect.h / 2)) }
        let pods = scene.layout.pods.values.sorted { $0.id < $1.id }
        let headed = try #require(pods.first { p in p.managerId.map { scene.layout.desks[$0]?.podId == p.id } ?? false })
        #expect(scene.hit(at: labelPoint(headed)) == .team(headed.managerId!))
        let officeOwned = pods.filter { p in p.managerId.map { scene.layout.desks[$0]?.roomId != nil } ?? false }
        #expect(!officeOwned.isEmpty)
        for pod in officeOwned { #expect(scene.hit(at: labelPoint(pod)) == nil, "\(pod.id)") }
        for pod in pods where pod.managerId == nil { #expect(scene.hit(at: labelPoint(pod)) == nil, "\(pod.id)") }

        #expect(scene.hit(at: CGPoint(x: -500, y: 500)) == nil)
        let corridor = try #require(scene.layout.corridors.first)
        #expect(scene.hit(at: CGPoint(x: corridor.x + corridor.w / 2, y: -(corridor.y + corridor.h / 2))) == nil)

        // A figure away from its desk hits its agent too: a reviewer in the review room.
        let reviewer = try #require(Self.living(model).first {
            if case .meeting = $0.activity { return true }
            return $0.activity == .reviewing
        })
        let figure = try #require(scene.figureNode(reviewer.id))
        #expect(scene.hit(at: CGPoint(x: figure.position.x, y: figure.position.y + 6)) == .agent(reviewer.id))
    }

    @Test func lodByCount() throws {
        #expect(OfficeScene.lod(living: 0) == .full)
        #expect(OfficeScene.lod(living: 50) == .full)
        #expect(OfficeScene.lod(living: 51) == .staticFigures)
        #expect(OfficeScene.lod(living: 150) == .staticFigures)
        #expect(OfficeScene.lod(living: 151) == .deskOnly)
        for n in [50, 150, 300] {
            let model = Self.model(agents: n)
            let scene = Self.scene(model)
            let living = Self.living(model)
            #expect(scene.lod == OfficeScene.lod(living: living.count), "\(n)")
            if scene.lod == .deskOnly {
                for a in living { #expect(scene.figureNode(a.id) == nil) }
                // Desk-only: the doors count who is in the review room and who waits at the board room.
                let inReview = living.filter {
                    if case .meeting = $0.activity { return true }
                    return $0.activity == .reviewing
                }.count
                #expect(scene.roomNode("room:review")?.count == inReview)
                #expect(scene.roomNode("room:board")?.count == living.filter { $0.activity == .waitingOnOwner }.count)
            } else {
                #expect(living.contains { scene.figureNode($0.id) != nil })
            }
        }
        // Static LOD: no typing frames.
        let mid = Self.scene(Self.model(agents: 150))
        #expect(mid.lod == .staticFigures)
        for node in mid.allFigureNodes { #expect(node.body.action(forKey: OfficeFigureNode.typingKey) == nil) }
    }

    /// Pinned states on a 12-agent company: everyone ready and unblocked except the six under test.
    @Test func screenAndFigureFollowActivity() throws {
        let made = SyntheticCompany.make(agents: 12)
        let picks = made.agents.filter { $0.state != .killed }.map(\.id)
        let (running, ready, blocked, waiting, sleeping, reviewing) = (picks[1], picks[2], picks[3], picks[4], picks[5], picks[6])
        let model = Self.model(agents: 12, edit: { agents in
            for i in agents.indices where agents[i].state != .killed {
                agents[i].state = .ready
                agents[i].blocker = nil
                switch agents[i].id {
                case running: agents[i].state = .running
                case blocked: agents[i].state = .blocked; agents[i].blocker = .workItem(id: "w-1", key: "BRH-1")
                case waiting: agents[i].state = .blocked; agents[i].blocker = .owner(reason: "sign off")
                case sleeping: agents[i].state = .sleeping
                default: break
                }
            }
        }, inputs: { $0.meetings = []; $0.reviewing = [reviewing] })
        let scene = Self.scene(model)
        #expect(scene.lod == .full)

        let typing = try #require(scene.deskNode(running))
        #expect(typing.screenColor == ThemeHex.running && typing.screenState == .lit && typing.lampOn)
        let typist = try #require(scene.figureNode(running))
        #expect(typist.pose == .typeA || typist.pose == .typeB)
        #expect(Self.near(typist.position, Self.scenePoint(try #require(scene.layout.desks[running]?.seat))))
        #expect(typist.body.action(forKey: OfficeFigureNode.typingKey) != nil, "hands alternate at full LOD")
        #expect(typing.halo.action(forKey: OfficeDeskNode.pulseKey) != nil, "the glow pulses")

        let idle = try #require(scene.deskNode(ready))
        #expect(idle.screenColor == ThemeHex.ready && idle.screenState == .dim && idle.lampOn)
        #expect(scene.figureNode(ready)?.pose == .sit)
        #expect(scene.figureNode(ready)?.bubble == nil)

        let stuck = try #require(scene.deskNode(blocked))
        #expect(stuck.screenColor == ThemeHex.blocked && stuck.screenState == .lit)
        #expect(scene.figureNode(blocked)?.pose == .raisedHand)
        #expect(scene.figureNode(blocked)?.bubble == .exclaim)

        #expect(scene.deskNode(waiting)?.screenColor == ThemeHex.blocked)
        let waiter = try #require(scene.figureNode(waiting))
        #expect(waiter.pose == .stand && waiter.bubble == .ellipsis)
        #expect(Self.near(waiter.position, Self.scenePoint(scene.layout.doorSpot(0))))

        let away = try #require(scene.deskNode(sleeping))
        #expect(!away.lampOn && away.screenState == .off && away.screenColor == ThemeHex.bg1)
        #expect(scene.figureNode(sleeping) == nil)

        #expect(scene.deskNode(reviewing)?.screenState == .dim)
        let reviewer = try #require(scene.figureNode(reviewing))
        #expect(reviewer.pose == .sit)
        #expect(Self.near(reviewer.position, Self.scenePoint(scene.layout.reviewSeat(0))))

        // Figures sort by depth: the lower on screen, the nearer.
        #expect(waiter.zPosition == -waiter.position.y)
    }

    @Test func trustCollarFromProvider() throws {
        let made = SyntheticCompany.make(agents: 12)
        let id = try #require(made.agents.first { $0.state == .running }?.id)
        let model = Self.model(agents: 12, inputs: {
            $0.meetings = []
            $0.reviewing = []
            $0.people = MapPeople(trust: [id: MapTrust(label: "T2", title: "Trusted", tier: 2)])
        })
        let scene = Self.scene(model)
        #expect(scene.figureNode(id)?.collar == 2)
        #expect(scene.figureNode(id)?.collarColor == ThemeHex.trustTier(2))
        let other = try #require(Self.living(model).first { $0.id != id && scene.figureNode($0.id) != nil })
        #expect(scene.figureNode(other.id)?.collar == nil)
    }

    @Test func formerDeskShowsBox() throws {
        let model = Self.model(agents: 50, showFormer: true)
        let scene = Self.scene(model)
        let gone = try #require(model.agents.values.first { $0.state == .killed })
        let desk = try #require(scene.deskNode(gone.id))
        #expect(desk.hasBox && !desk.lampOn && desk.isStruck && desk.screenState == .off)
        #expect(scene.figureNode(gone.id) == nil)
        // A killed agent keeps its phase (Task 2 M1), but never gets a parcel.
        let shipping = Self.living(model).filter { $0.shipping != nil }.count
        #expect(scene.roomNode("room:mail")?.parcels == shipping)
    }

    @Test func reduceMotionShowsBadges() throws {
        let model = Self.model(agents: 50)
        let still = Self.scene(model, reduceMotion: true)
        for agent in Self.living(model) {
            let desk = try #require(still.deskNode(agent.id))
            #expect(desk.badge == Self.badge(agent.activity), "\(agent.id) \(agent.activity)")
            #expect(desk.halo.action(forKey: OfficeDeskNode.pulseKey) == nil)
        }
        #expect(Self.living(model).contains { still.deskNode($0.id)?.badge != nil })
        for node in still.allFigureNodes { #expect(node.body.action(forKey: OfficeFigureNode.typingKey) == nil) }

        // Without Reduce Motion: no badges, and the running desks pulse.
        let moving = Self.scene(model)
        #expect(Self.living(model).allSatisfy { moving.deskNode($0.id)?.badge == nil })
        #expect(Self.living(model).contains { moving.deskNode($0.id)?.halo.action(forKey: OfficeDeskNode.pulseKey) != nil })

        // Turning it on later reconfigures the desks in place.
        moving.reduceMotion = true
        #expect(Self.living(model).allSatisfy { moving.deskNode($0.id)?.badge == Self.badge($0.activity) })
    }

    @Test func perksAndAsks() throws {
        let made = SyntheticCompany.make(agents: 50)
        let living = made.agents.filter { $0.state != .killed }.map(\.id)
        let perks: [String: [String]] = [living[0]: ["☕", "🏆"], living[1]: ["🔥", "⭐"], living[2]: ["🍜", "☕"],
                                         living[3]: ["⭐"]]
        let model = Self.model(agents: 50, inputs: { $0.people = MapPeople(perks: perks); $0.openAsks = 12 })
        let scene = Self.scene(model)
        let desk = try #require(scene.deskNode(living[0]))
        scene.zoom = 1.5
        #expect(desk.itemCount == 2)
        scene.zoom = 1.0
        #expect(desk.itemCount == 0)

        // The wall of fame: the first six perks in tree order.
        let expected = Array(model.tree.order.flatMap { model.agents[$0]?.perks ?? [] }.prefix(OfficeScene.fameLimit))
        #expect(scene.fameGlyphs.count == 6)
        #expect(scene.fameGlyphs == expected)

        let board = try #require(scene.roomNode("room:board"))
        #expect(board.askFolders == 9 && board.askLabel == "9+")
        let few = Self.scene(Self.model(agents: 50, inputs: { $0.openAsks = 3 }))
        #expect(few.roomNode("room:board")?.askFolders == 3)
        #expect(few.roomNode("room:board")?.askLabel == nil)
    }

    @Test func deskTextIsClean() throws {
        let made = SyntheticCompany.make(agents: 12)
        let id = try #require(made.agents.first { $0.state == .running }?.id)
        let zalgo = "z" + String(repeating: "\u{0301}\u{0489}", count: 2_500) + "\u{202E}x"
        let role = String(repeating: "r", count: 10_000)
        let model = Self.model(agents: 12, edit: { agents in
            if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].name = zalgo; agents[i].role = role }
        })
        let agent = try #require(model.agents[id])
        #expect(agent.handle.count <= 41 && agent.role.count <= 40)
        let scene = Self.scene(model)
        scene.zoom = 1.5
        let desk = try #require(scene.deskNode(id))
        let handle = try #require(desk.handleText), roleText = try #require(desk.roleText)
        // The handle fits the desk whole; the role is the model's cleaned role, cut to the desk (a cut ends in "…").
        #expect(handle == agent.handle)
        #expect(roleText.count <= 40 && roleText == MapText.clean(agent.role, max: roleText.count))
        for text in [handle, roleText] {
            #expect(!text.unicodeScalars.contains("\u{202E}"))
            #expect(text.unicodeScalars.count <= 41 * 8)
        }
    }

    @Test func emptyCompanyShowsRoomsOnly() throws {
        var model = MapModel()
        model.apply(MapInputs(agents: [], pack: SoftwarePack.pack), now: 0)
        let scene = Self.scene(model)
        // No CEO, so no corner office: the board room and the three shared rooms.
        #expect(Set(scene.layout.rooms.keys) == ["room:board", "room:review", "room:break", "room:mail"])
        #expect(scene.roomNodeCount == 4)
        #expect(scene.deskCount == 0)
        #expect(!scene.contentBounds.isEmpty)
        scene.zoomToFit(margin: 40)
        #expect(OfficeScene.zoomRange.contains(scene.zoom))
        #expect(scene.hit(at: try #require(scene.roomRect("room:board")).center) == .owner)
    }

    @Test func factoryMakesEitherScene() {
        #expect(MapSceneFactory.make(.org, size: Self.size) is OrgScene)
        #expect(MapSceneFactory.make(.office, size: Self.size) is OfficeScene)
        #expect(MapSceneFactory.make(.org, size: Self.size).mode == .org)
        #expect(MapSceneFactory.make(.office, size: Self.size).mode == .office)
    }

    @Test func desksAreReusedAndGlide() throws {
        let model = Self.model(agents: 50)
        let scene = Self.scene(model)
        let id = try #require(Self.living(model).first?.id)
        let node = try #require(scene.deskNode(id))
        scene.rebuild(model: model)
        #expect(scene.deskNode(id) === node, "same node across rebuilds")
        #expect(node.action(forKey: "move") == nil, "an unmoved desk does not glide")
        // Sleep the first living agent: same node, new state.
        let edited = Self.model(agents: 50, edit: { agents in
            if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].state = .sleeping }
        })
        scene.rebuild(model: edited)
        #expect(scene.deskNode(id) === node && !node.lampOn)

        // A leave closes the gap: the next desk of the pod takes the free slot, gliding there.
        let move = try Self.movedDesk(scene: scene, model: model)
        #expect(move.node.action(forKey: "move") != nil)
        #expect(Self.near(move.node.position, move.from.center), "the desk has not jumped")
    }

    /// Kills the first member of a pod with two or more agent members and rebuilds: the second member's desk moves to the
    /// first slot. Returns its node and its rects before and after.
    static func movedDesk(scene: OfficeScene, model: MapModel) throws -> (node: OfficeDeskNode, from: CGRect, to: CGRect) {
        scene.rebuild(model: model)
        let layout = scene.layout
        let pod = try #require(layout.pods.values.sorted { $0.id < $1.id }.first { pod in
            model.tree.order.filter { layout.desks[$0]?.podId == pod.id && $0 != pod.managerId && model.agents[$0] != nil }.count >= 2
        })
        let members = model.tree.order.filter { layout.desks[$0]?.podId == pod.id && $0 != pod.managerId && model.agents[$0] != nil }
        let (leaver, mover) = (members[0], members[1])
        let from = try #require(scene.deskRect(mover))
        let node = try #require(scene.deskNode(mover))
        let after = Self.model(agents: 50, edit: { agents in
            if let i = agents.firstIndex(where: { $0.id == leaver }) { agents[i].state = .killed }
        })
        scene.rebuild(model: after)
        let to = try #require(scene.deskRect(mover))
        #expect(to != from, "the desk moved")
        #expect(scene.deskNode(mover) === node, "the node is reused")
        return (node, from, to)
    }

    /// Half way through `moveDuration` the desk is about half way; after it, it is at its new rect.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func movedDeskGlidesOverMoveDuration() throws {
        let model = Self.model(agents: 50)
        let scene = Self.scene(model)
        let move = try Self.movedDesk(scene: scene, model: model)
        let a = move.from.center, b = move.to.center
        let span = hypot(b.x - a.x, b.y - a.y)
        // The renderer's first frame starts the action: 1 + 12 frames at 60 Hz is moveDuration / 2.
        let half = Int((OfficeScene.moveDuration / 2 * 60).rounded())
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: half + 1))
        let p = move.node.position
        let progress = hypot(p.x - a.x, p.y - a.y) / span
        #expect(progress > 0.35 && progress < 0.65, "progress \(progress) at moveDuration / 2")
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 36))
        #expect(Self.near(move.node.position, b, within: 0.5), "\(move.node.position) vs \(b)")
    }

    /// No figure, bubble or badge covers a desk's handle or role, and no figure or bubble covers a pod's title, at zoom
    /// 1.5 (both text lines showing): full LOD with and without Reduce Motion, and static LOD.
    @Test func labelsAreNeverCovered() throws {
        for (n, reduceMotion) in [(12, false), (50, false), (50, true), (150, false)] {
            let model = Self.model(agents: n)
            let scene = Self.scene(model, reduceMotion: reduceMotion)
            scene.zoom = 1.5
            var covers: [(String, CGRect)] = []
            for figure in scene.allFigureNodes {
                covers.append(("figure", figure.frameRect))
                if let bubble = figure.bubbleFrame { covers.append(("bubble", bubble)) }
            }
            for desk in scene.allDeskNodes {
                if let badge = desk.badgeFrame { covers.append(("badge", badge)) }
                // R27: the desk items keep to their corner, off every label.
                covers += desk.perkFrames.map { ("perk", $0) }
            }
            #expect(!covers.isEmpty)
            #expect(covers.contains { $0.0 == "perk" }, "office-\(n): the synthetic perks are drawn")
            var labels: [CGRect] = scene.allDeskNodes.flatMap(\.labelFrames)
            #expect(labels.count >= 2 * Self.living(model).count, "handle and role on every desk")
            labels += scene.layout.pods.keys.compactMap { scene.podNode($0)?.labelFrame }
            for label in labels {
                for (kind, rect) in covers where rect.intersects(label) {
                    Issue.record("office-\(n)\(reduceMotion ? "-rm" : ""): a \(kind) at \(rect) covers the label at \(label)")
                }
            }
            // R27: no Reduce Motion badge sits on a figure (a head desk's used to sit on the first row's seated head).
            for desk in scene.allDeskNodes {
                guard let badge = desk.badgeFrame else { continue }
                for figure in scene.allFigureNodes where figure.frameRect.intersects(badge) {
                    Issue.record("office-\(n)-rm: the badge at \(badge) covers the figure at \(figure.frameRect)")
                }
            }
        }
    }


    // MARK: - Motion (Task 7)

    /// A synthetic controller in office mode (seed 42, as `model(agents:)`) whose model carries the synthetic office facets
    /// (ruling R15: built here, not by the controller's synthetic path), `edit` applied. Returns the inputs, which a test
    /// edits and re-applies to make the model emit its events.
    static func officeController(_ n: Int, edit: (inout MapInputs) -> Void = { _ in }) -> (c: MapController, inputs: MapInputs) {
        let c = MapController(source: .synthetic(agents: n, rate: 0, seed: 42), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        c.mode = .office
        let made = SyntheticCompany.make(agents: n, seed: 42, companyId: "demo")
        var inputs = MapController.inputs(c.synthetic!)
        inputs.itemPhases = made.itemPhases
        inputs.reviewing = made.reviewing
        inputs.people = made.people
        inputs.openAsks = made.openAsks
        edit(&inputs)
        c.model.apply(inputs, now: 0, emitEvents: false)
        return (c, inputs)
    }

    /// One frame per `dt` from `from` through `to`, the way the view drives the scene; returns the last frame time.
    @discardableResult
    static func run(_ scene: OfficeScene, _ c: MapController, from: TimeInterval = 0, to: TimeInterval,
                    dt: TimeInterval = 1.0 / 60, each: (TimeInterval, [VisualEvent]) -> Void = { _, _ in }) -> TimeInterval {
        var t = from, last = from
        while t <= to + 1e-9 {
            let events = c.frame(now: t)
            scene.update(controller: c, events: events, now: t)
            each(t, events)
            last = t
            t += dt
        }
        return last
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// The distance from `p` to the polyline `points`.
    static func distance(_ p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        var best = distance(p, first)
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? Swift.max(0, Swift.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
            best = Swift.min(best, distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy)))
        }
        return best
    }

    /// Living agents with a figure at their seat (typing or idle), in tree order, from a driven scene.
    static func seated(_ scene: OfficeScene, _ c: MapController, activity: OfficeActivity? = nil) -> [String] {
        c.model.tree.order.filter { id in
            guard let a = c.model.agents[id], a.activity == .typing || a.activity == .idle, scene.figureNode(id) != nil
            else { return false }
            return activity.map { a.activity == $0 } ?? true
        }
    }

    /// Runs frames from `from` until `id`'s figure heads for `target` (at most 0.5 s); returns that frame's time.
    static func runUntilTarget(_ scene: OfficeScene, _ c: MapController, _ id: String, _ target: CGPoint,
                               from: TimeInterval) throws -> TimeInterval {
        var t = from
        while t < from + 0.5 {
            scene.update(controller: c, events: c.frame(now: t), now: t)
            if near(scene.figureTarget(id), target) { return t }
            t += 1.0 / 60
        }
        Issue.record("\(id) never headed for \(target)")
        throw CancellationError()
    }

    @Test func walkToReviewRoomOnReviewing() throws {
        let (c, base) = Self.officeController(12) { $0.meetings = []; $0.reviewing = [] }
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 0.2)
        #expect(scene.lod == .full)
        let id = try #require(Self.seated(scene, c).first)
        let seat = Self.scenePoint(try #require(scene.layout.desks[id]?.seat))
        #expect(Self.near(scene.figurePosition(id), seat))

        var inputs = base
        inputs.reviewing = [id]
        c.model.apply(inputs, now: 0.2)
        let chair = Self.scenePoint(scene.layout.reviewSeat(0))
        let t0 = try Self.runUntilTarget(scene, c, id, chair, from: 0.21)
        #expect(scene.figureTarget(id) == chair)
        #expect(scene.reviewOccupants == [id])
        #expect(scene.walkingIds.contains(id))

        Self.run(scene, c, from: t0 + 1.0 / 60, to: t0 + 0.4)
        let mid = try #require(scene.figurePosition(id))
        #expect(Self.distance(mid, seat) > 2 && Self.distance(mid, chair) > 2, "on its way at \(mid)")
        let figure = try #require(scene.figureNode(id))
        #expect(figure.pose == .walkA || figure.pose == .walkB)

        Self.run(scene, c, from: t0 + 0.4 + 1.0 / 60, to: t0 + 0.8 + 1.0 / 60)
        #expect(Self.near(scene.figurePosition(id), chair), "\(String(describing: scene.figurePosition(id))) vs \(chair)")
        #expect(!scene.walkingIds.contains(id))
        #expect(figure.pose == .sit)
    }

    @Test func messageNoteFollowsCorridorRoute() throws {
        let (c, _) = Self.officeController(12) { $0.meetings = []; $0.reviewing = [] }
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 0.1)
        let layout = scene.layout
        // A sender idle at its desk, and a recipient in another pod or room.
        let idle = Self.seated(scene, c, activity: .idle)
        let a = try #require(idle.first)
        let b = try #require(Self.seated(scene, c).first { $0 != a && layout.desks[$0]?.podId != layout.desks[a]?.podId })
        let from = try #require(layout.location(.agent(a))), to = try #require(layout.location(.agent(b)))

        let e = VisualEvent(id: 9001, kind: .message, from: .agent(a), to: .agent(b), start: 0.1, duration: 0.9)
        scene.update(controller: c, events: [e], now: 0.1)
        #expect(scene.particleKind(9001) == .note)
        #expect(scene.particleSprite(9001)?.texture != nil)
        #expect(scene.particleTarget(9001) == Self.scenePoint(to))
        // The sender's hand gesture: 0.2 s of typing.
        #expect(scene.figureNode(a)?.pose == .typeA)

        let route = layout.route(from: from, to: to).map(Self.scenePoint)
        #expect(route.count >= 3, "a corridor route")
        for t in [0.3, 0.55, 0.8] {
            scene.update(controller: c, events: [], now: t)
            let p = try #require(scene.particleSprite(9001)?.position)
            #expect(Self.distance(p, toPolyline: route) <= 1, "t \(t): \(p) off the route")
        }
        #expect(scene.figureNode(a)?.pose == .sit, "the gesture is over")
        scene.update(controller: c, events: [], now: 1.05)
        #expect(scene.particlesInUse == 0)
    }

    @Test func handoffWithoutRecipientGoesToMailRoom() throws {
        let (c, _) = Self.officeController(12)
        let scene = OfficeScene(size: Self.size)
        Self.run(scene, c, to: 0.1)
        let a = try #require(Self.seated(scene, c).first)
        let e = VisualEvent(id: 77, kind: .handoff, from: .agent(a), label: "BRH-7", start: 0.1, duration: 1.4)
        scene.update(controller: c, events: [e], now: 0.1)
        #expect(scene.particleKind(77) == .folder)
        #expect(scene.particleTarget(77) == Self.scenePoint(scene.layout.mailCounter(0)))
        // At the end of its 1.4 s flight it lands on the counter.
        scene.update(controller: c, events: [], now: 1.4999)
        #expect(Self.near(scene.particleSprite(77)?.position, Self.scenePoint(scene.layout.mailCounter(0)), within: 2))
    }

    @Test func phaseChangeStampsParcel() throws {
        let (c, base) = Self.officeController(12) { $0.itemPhases = [:] }
        let scene = OfficeScene(size: Self.size)
        Self.run(scene, c, to: 0.1)
        #expect(scene.parcelCount == 0)
        let id = try #require(c.model.tree.order.first { c.model.agents[$0]?.item != nil && c.model.agents[$0]?.state != .killed })
        let item = try #require(c.model.agents[id]?.item)
        let mail = try #require(scene.roomNode("room:mail"))

        var inputs = base
        inputs.itemPhases = [id: .checking]
        c.model.apply(inputs, now: 0.1)
        Self.run(scene, c, from: 0.1, to: 0.3)
        #expect(scene.parcelCount == 1)
        #expect(mail.parcelKey(id) == String(item.prefix { $0 != " " }), "the item key")
        #expect(mail.strapColor(id) == ThemeHex.warning)

        inputs.itemPhases = [id: .passed]
        c.model.apply(inputs, now: 0.3)
        Self.run(scene, c, from: 0.3, to: 0.5)
        #expect(mail.stampedParcels == [id], "✓ on the parcel")
        #expect(scene.parcelCount == 1)
        Self.run(scene, c, from: 0.5, to: 1.4)
        #expect(scene.parcelCount == 0, "the stamped parcel left after 1 s")

        inputs.itemPhases = [id: .failed]
        c.model.apply(inputs, now: 1.4)
        Self.run(scene, c, from: 1.4, to: 1.6)
        #expect(scene.parcelCount == 1)
        #expect(mail.strapColor(id) == ThemeHex.blocked)
        #expect(mail.stampedParcels.isEmpty)

        inputs.itemPhases = [id: .working]
        c.model.apply(inputs, now: 1.6)
        Self.run(scene, c, from: 1.6, to: 1.8)
        #expect(scene.parcelCount == 0, "back at work: the parcel is removed")
    }

    @Test func hireBalloonAndLeaveClearsDesk() throws {
        let made = SyntheticCompany.make(agents: 12)
        let hired = try #require(made.agents.last { a in
            a.state != .killed && a.managerId != nil && !made.agents.contains { $0.managerId == a.id }
        })
        let (c, base) = Self.officeController(12) { $0.meetings = []; $0.reviewing = [] }
        var without = base
        without.agents.removeAll { $0.id == hired.id }
        c.model.apply(without, now: 0, emitEvents: false)
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 0.1)
        #expect(scene.deskNode(hired.id) == nil)

        // The hire: the desk arrives with a balloon that drifts up and is gone after 2 s.
        c.model.apply(base, now: 0.1)
        var sawHire = false
        Self.run(scene, c, from: 0.1, to: 0.3) { _, events in sawHire = sawHire || events.contains { $0.kind == .hire } }
        #expect(sawHire)
        let desk = try #require(scene.deskNode(hired.id))
        let balloon = try #require(desk.childNode(withName: "balloon"), "a balloon on the new desk")
        let y0 = balloon.position.y
        Self.run(scene, c, from: 0.3, to: 1.2)
        #expect(balloon.position.y > y0 + 8 && balloon.alpha < 0.8, "it rises and fades")
        Self.run(scene, c, from: 1.2, to: 2.4)
        #expect(desk.childNode(withName: "balloon") == nil, "gone after 2 s")

        // The leave: 1.5 s with the layout held, then the desk is gone and the gap closed.
        let victim = try #require(Self.seated(scene, c).first { id in id != hired.id && !made.agents.contains { $0.managerId == id } })
        var killed = base
        let i = try #require(killed.agents.firstIndex { $0.id == victim })
        killed.agents[i].state = .killed
        c.model.apply(killed, now: 2.4)
        Self.run(scene, c, from: 2.4, to: 3.1)
        #expect(scene.leavingIds == [victim])
        #expect(scene.deskNode(victim) != nil, "the desk stays while it clears")
        #expect(scene.layout.desks[victim] != nil, "the layout is held")
        let figure = try #require(scene.figureNode(victim))
        #expect(figure.alpha < 0.8 && figure.alpha > 0.1, "the figure fades: \(figure.alpha)")
        #expect(scene.deskNode(victim)?.childNode(withName: "leaveBox") != nil, "the items go into a box")
        Self.run(scene, c, from: 3.1, to: 4.0)
        #expect(scene.leavingIds.isEmpty)
        #expect(scene.deskNode(victim) == nil)
        #expect(scene.figureNode(victim) == nil)
        #expect(scene.layout.desks[victim] == nil, "the layout was rebuilt without it")
    }

    /// R3: (a) a figure walking to the review room whose review ends (its item's owner was killed) heads back to its own
    /// seat on the next frame; (b) a figure killed mid-walk is removed, and nothing crashes.
    @Test func retargetWhenAgentKilledMidWalk() throws {
        let (c, base) = Self.officeController(12) { $0.meetings = []; $0.reviewing = [] }
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 0.2)
        let seated = Self.seated(scene, c)
        let leaves = seated.filter { id in !c.model.tree.order.contains { c.model.tree.nodes[$0]?.parentId == id } }
        let reviewer = try #require(seated.first)
        let owner = try #require(leaves.first { $0 != reviewer })
        let seat = Self.scenePoint(try #require(scene.layout.desks[reviewer]?.seat))

        var inputs = base
        inputs.reviewing = [reviewer]
        c.model.apply(inputs, now: 0.2)
        let chair = Self.scenePoint(scene.layout.reviewSeat(0))
        let t0 = try Self.runUntilTarget(scene, c, reviewer, chair, from: 0.21)
        Self.run(scene, c, from: t0 + 1.0 / 60, to: t0 + 0.3)
        let mid = try #require(scene.figurePosition(reviewer))
        #expect(scene.walkingIds.contains(reviewer))

        // (a) The owner is killed: the review is over (the controller drops a reviewer whose owner is gone).
        var killed = inputs
        let i = try #require(killed.agents.firstIndex { $0.id == owner })
        killed.agents[i].state = .killed
        killed.reviewing = []
        c.model.apply(killed, now: t0 + 0.3)
        let t1 = t0 + 0.3 + 1.0 / 60
        scene.update(controller: c, events: c.frame(now: t1), now: t1)
        #expect(scene.figureTarget(reviewer) == seat, "heads back to its own seat on the next frame")
        #expect(Self.distance(try #require(scene.figurePosition(reviewer)), mid) < 12, "from where it was, no jump")
        Self.run(scene, c, from: t1 + 1.0 / 60, to: t1 + 0.9)
        #expect(Self.near(scene.figurePosition(reviewer), seat))

        // (b) The walker itself is killed mid-walk.
        inputs = killed
        inputs.reviewing = [reviewer]
        let t2 = t1 + 2.0
        Self.run(scene, c, from: t1 + 0.9, to: t2)
        c.model.apply(inputs, now: t2)
        let t3 = try Self.runUntilTarget(scene, c, reviewer, chair, from: t2 + 1.0 / 60)
        Self.run(scene, c, from: t3 + 1.0 / 60, to: t3 + 0.3)
        #expect(scene.walkingIds.contains(reviewer))
        let j = try #require(inputs.agents.firstIndex { $0.id == reviewer })
        inputs.agents[j].state = .killed
        inputs.reviewing = []
        c.model.apply(inputs, now: t3 + 0.3)
        Self.run(scene, c, from: t3 + 0.3 + 1.0 / 60, to: t3 + 2.0)
        #expect(scene.figureNode(reviewer) == nil, "removed")
        #expect(!scene.walkingIds.contains(reviewer))
        #expect(scene.figureTarget(reviewer) == nil)
    }

    @Test func noteRetargetsWhenRecipientLeaves() throws {
        let (c, base) = Self.officeController(12) { $0.meetings = []; $0.reviewing = [] }
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 0.1)
        let seated = Self.seated(scene, c)
        let leaves = seated.filter { id in !c.model.tree.order.contains { c.model.tree.nodes[$0]?.parentId == id } }
        let b = try #require(leaves.last)
        let a = try #require(seated.first { $0 != b })
        let e = VisualEvent(id: 4242, kind: .message, from: .agent(a), to: .agent(b), start: 0.1, duration: 0.9)
        scene.update(controller: c, events: [e], now: 0.1)
        scene.update(controller: c, events: [], now: 0.3)
        #expect(scene.particleTarget(4242) == Self.scenePoint(try #require(scene.layout.location(.agent(b)))))
        let before = try #require(scene.particleSprite(4242)?.position)

        var inputs = base
        let i = try #require(inputs.agents.firstIndex { $0.id == b })
        inputs.agents[i].state = .killed
        c.model.apply(inputs, now: 0.3)
        scene.update(controller: c, events: c.frame(now: 0.32), now: 0.32)
        let sender = Self.scenePoint(try #require(scene.layout.location(.agent(a))))
        #expect(scene.particleTarget(4242) == sender, "back to the sender's seat")
        #expect(Self.distance(try #require(scene.particleSprite(4242)?.position), before) < 20, "no jump")
        scene.update(controller: c, events: c.frame(now: 0.99), now: 0.99)
        #expect(Self.near(scene.particleSprite(4242)?.position, sender, within: 2))
    }

    @Test func staticLODTeleports() throws {
        let (c, base) = Self.officeController(80) { $0.meetings = []; $0.reviewing = [] }
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 0.1)
        #expect(scene.lod == .staticFigures)
        let id = try #require(Self.seated(scene, c).first)
        var inputs = base
        inputs.reviewing = [id]
        c.model.apply(inputs, now: 0.1)
        let chair = Self.scenePoint(scene.layout.reviewSeat(0))
        _ = try Self.runUntilTarget(scene, c, id, chair, from: 0.11)
        #expect(scene.figurePosition(id) == chair, "it appears at its destination")
        #expect(scene.walkingIds.isEmpty)
        // No strolls at static LOD either.
        Self.run(scene, c, from: 0.5, to: 45, dt: 0.25)
        #expect(scene.walkingIds.isEmpty)
    }

    @Test func reduceMotionNoWalkNoNotes() throws {
        let (c, base) = Self.officeController(12) { $0.meetings = []; $0.reviewing = [] }
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = true
        Self.run(scene, c, to: 0.1)
        #expect(scene.lod == .full)
        let seated = Self.seated(scene, c)
        let id = try #require(seated.first)
        var inputs = base
        inputs.reviewing = [id]
        c.model.apply(inputs, now: 0.1)
        let chair = Self.scenePoint(scene.layout.reviewSeat(0))
        _ = try Self.runUntilTarget(scene, c, id, chair, from: 0.11)
        #expect(scene.figurePosition(id) == chair)
        #expect(scene.walkingIds.isEmpty)

        let a = try #require(seated.first { $0 != id }), b = try #require(seated.last { $0 != id && $0 != a })
        let e = VisualEvent(id: 5, kind: .message, from: .agent(a), to: .agent(b), start: 0.7, duration: 0.9)
        scene.update(controller: c, events: [e], now: 0.7)
        #expect(scene.particlesInUse == 0, "no travelling notes")
        #expect(scene.flashingDesks == [a])
        #expect(scene.deskNode(a)?.isFlashing == true)
        scene.update(controller: c, events: [], now: 0.95)
        #expect(scene.flashingDesks.isEmpty, "a 0.2 s flash")
        #expect(scene.deskNode(a)?.isFlashing == false)
        Self.run(scene, c, from: 1.0, to: 45, dt: 0.25)
        #expect(scene.walkingIds.isEmpty, "no strolls")
    }

    @Test func idleStrollsOnlyAtFullLOD() throws {
        for (n, strolls) in [(12, true), (80, false)] {
            let (c, _) = Self.officeController(n) { $0.meetings = []; $0.reviewing = [] }
            let scene = OfficeScene(size: Self.size)
            scene.reduceMotion = false
            Self.run(scene, c, to: 0.1)
            let idle = Self.seated(scene, c, activity: .idle)
            #expect(!idle.isEmpty, "\(n): idle agents")
            let room = try #require(scene.roomRect("room:break"))
            var visited = Set<String>()
            Self.run(scene, c, from: 0.1, to: 40, dt: 0.05) { _, _ in
                for id in idle where room.contains(scene.figureTarget(id) ?? .zero) { visited.insert(id) }
            }
            if strolls {
                #expect(!visited.isEmpty, "an idle figure strolled to the break room")
            } else {
                #expect(visited.isEmpty, "no strolls above fullLOD")
            }
        }
    }

    @Test func followAndHighlight() throws {
        let (c, _) = Self.officeController(12)
        let scene = OfficeScene(size: Self.size)
        Self.run(scene, c, to: 0.1)
        let camera = try #require(scene.camera)
        let id = try #require(Self.seated(scene, c).first)
        c.follow(id)
        Self.run(scene, c, from: 0.1 + 1.0 / 60, to: 0.45)
        let figure = try #require(scene.figurePosition(id))
        #expect(Self.near(camera.position, figure), "\(camera.position) vs \(figure)")

        let other = try #require(Self.seated(scene, c).last)
        c.jump(to: other)
        Self.run(scene, c, from: 0.5, to: 0.7)
        let desk = try #require(scene.deskRect(other))
        let ring = try #require(scene.highlightRing, "ring while highlighted")
        #expect(ring.contains(desk) && ring.width - desk.width <= 12)
        Self.run(scene, c, from: 0.7, to: 2.1)
        #expect(c.highlightId == nil)
        #expect(scene.highlightRing == nil, "ring gone after 1.5 s")
    }

    @Test func burstStaysBoundedInOffice() throws {
        let (c, base) = Self.officeController(50)
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        let agents = c.synthetic!.agents
        var traffic = SyntheticTraffic(seed: 5)
        // A few messages first: notes in flight.
        c.model.ingest(traffic.facts(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 0.6),
                                     agents: agents, rate: 10, burst: nil), now: 0)
        Self.run(scene, c, to: 0.3)
        #expect(scene.particleKinds.contains(.note), "notes before the burst")

        // 2 000 messages in one poll, and an agent leaves in the same poll.
        let burst = traffic.facts(from: Date(timeIntervalSince1970: 1), to: Date(timeIntervalSince1970: 2),
                                  agents: agents, rate: 2000, burst: nil)
        #expect(burst.count >= 2000)
        c.model.ingest(burst, now: 0.3)
        let victim = try #require(Self.seated(scene, c).last)
        var inputs = base
        let i = try #require(inputs.agents.firstIndex { $0.id == victim })
        inputs.agents[i].state = .killed
        c.model.apply(inputs, now: 0.3)

        var sawAggregate = false, sawLeave = false
        Self.run(scene, c, from: 0.3, to: 2.3) { _, events in
            #expect(scene.particlesInUse <= MotionState.poolSize)
            #expect(scene.particleSpriteCount <= MotionState.poolSize)
            if c.model.stats.aggregate {
                sawAggregate = true
                #expect(scene.particleKinds.allSatisfy { $0 != .note }, "aggregate mode: notes become dots")
            }
            if events.contains(where: { $0.kind == .leave }) { sawLeave = true }
        }
        #expect(sawAggregate, "aggregate within 2 s")
        #expect(sawLeave, "structural events still spawn")
        #expect(scene.figureNode(victim) == nil && scene.deskNode(victim) == nil, "the leave played out")
    }

    /// Spec §5.7 (carry): item phases are not in the replay timeline, so while the controller replays the office shows
    /// states only — no one walks to or sits in the review room, no parcels, the meeting light is off, and a phase change
    /// is ignored — also after Reduce Motion is toggled. (`enterReplay()` reads a live store's history and is a no-op for
    /// a synthetic controller; the scene reads only `isReplaying`, set here through `@testable`.)
    @Test func replayIgnoresItemFacets() throws {
        let made = SyntheticCompany.make(agents: 12)
        let shipper = try #require(made.agents.first { $0.state != .killed && made.currentItems[$0.id] != nil }?.id)
        let (c, base) = Self.officeController(12) { $0.itemPhases[shipper] = .checking }
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 1.5)
        let inRoom = c.model.tree.order.filter {
            guard let a = c.model.agents[$0] else { return false }
            if case .meeting = a.activity { return true }
            return a.activity == .reviewing
        }
        #expect(!inRoom.isEmpty && !scene.reviewOccupants.isEmpty, "live: reviewers and the meeting are in the room")
        #expect(scene.parcelCount > 0)
        #expect(scene.roomNode("room:review")?.doorLit == true)

        func expectStatesOnly(_ when: String) throws {
            #expect(scene.reviewOccupants.isEmpty, "\(when): nobody in the review room")
            for id in inRoom {
                let seat = Self.scenePoint(try #require(scene.layout.desks[id]?.seat))
                #expect(scene.figureNode(id) == nil || scene.figureTarget(id) == seat, "\(when): \(id) at its desk")
            }
            #expect(scene.parcelCount == 0, "\(when): no parcels")
            #expect(scene.roomNode("room:review")?.doorLit == false, "\(when): the meeting light is off")
        }
        c.isReplaying = true
        Self.run(scene, c, from: 1.5, to: 2.0)
        try expectStatesOnly("replay")

        var inputs = base
        inputs.itemPhases[shipper] = .passed
        c.model.apply(inputs, now: 2.0)
        var sawPhase = false
        Self.run(scene, c, from: 2.0, to: 2.4) { _, events in
            sawPhase = sawPhase || events.contains { if case .phaseChange = $0.kind { return true }; return false }
        }
        #expect(sawPhase, "the phase change reached the scene")
        try expectStatesOnly("replay, after a phase change")
        #expect(scene.roomNode("room:mail")?.stampedParcels.isEmpty == true)

        scene.reduceMotion = true
        try expectStatesOnly("replay, Reduce Motion on")
        Self.run(scene, c, from: 2.4, to: 2.8)
        try expectStatesOnly("replay, Reduce Motion on, later")
        scene.reduceMotion = false
        Self.run(scene, c, from: 2.8, to: 3.2)
        try expectStatesOnly("replay, Reduce Motion off again")

        c.isReplaying = false
        Self.run(scene, c, from: 3.2, to: 3.6)
        #expect(!scene.reviewOccupants.isEmpty && scene.parcelCount > 0, "live again: the facets are back")
    }

    /// The hire's slide (spec §5.4): the new desk starts at its pod's aisle and reaches its rect in `moveDuration`,
    /// fading in. SKActions advance only when rendered, so frames are rendered as `movedDeskGlidesOverMoveDuration` does.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func hireSlidesInFromTheAisle() throws {
        let probe = OfficeLayout.make(model: Self.model(agents: 12))
        let made = SyntheticCompany.make(agents: 12)
        let hired = try #require(made.agents.last { a in
            a.state != .killed && a.managerId != nil && !made.agents.contains { $0.managerId == a.id }
                && probe.desks[a.id]?.podId != nil
        })
        let (c, base) = Self.officeController(12) { $0.meetings = []; $0.reviewing = [] }
        var without = base
        without.agents.removeAll { $0.id == hired.id }
        c.model.apply(without, now: 0, emitEvents: false)
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        Self.run(scene, c, to: 0.1)
        c.model.apply(base, now: 0.1)
        Self.run(scene, c, from: 0.1, to: 0.15)
        let desk = try #require(scene.deskNode(hired.id))
        let rect = try #require(scene.layout.desks[hired.id]?.rect)
        let podId = try #require(scene.layout.desks[hired.id]?.podId)
        let pod = try #require(scene.layout.pods[podId])
        let aisle = pod.rect.x + OfficeLayout.pod.padding + OfficeLayout.desk.w + OfficeLayout.pod.aisle / 2
        let target = CGPoint(x: rect.x + rect.w / 2, y: -(rect.y + rect.h / 2))
        #expect(abs(desk.position.x - aisle) < 0.5 && abs(desk.position.y - target.y) < 0.5, "starts at the aisle")
        #expect(desk.alpha == 0, "and fades in")
        #expect(abs(aisle - target.x) > 10, "a real slide")

        let half = Int((OfficeScene.moveDuration / 2 * 60).rounded())
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: half + 1))
        let progress = (desk.position.x - aisle) / (target.x - aisle)
        #expect(progress > 0.3 && progress < 0.95, "on its way at moveDuration / 2: \(progress)")
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 36))
        #expect(Self.near(desk.position, target, within: 0.5), "\(desk.position) vs \(target)")
        #expect(desk.alpha > 0.99)
    }

    /// Routes walk around the furniture `OfficeLayout.furniture` lists; the rooms draw it there.
    @Test func furnitureIsDrawnWhereRoutesGoAround() throws {
        let scene = Self.scene(Self.model(agents: 50))
        for id in ["room:board", "room:review", "room:mail", "room:break"] {
            let node = try #require(scene.roomNode(id))
            let drawn = node.obstacleFrames.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
            let planned = scene.layout.furniture(id).map(OfficeScene.sceneRect).sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
            #expect(drawn.count == planned.count, "\(id)")
            for (d, p) in zip(drawn, planned) {
                #expect(abs(d.minX - p.minX) <= 1 && abs(d.minY - p.minY) <= 1 && abs(d.width - p.width) <= 1
                        && abs(d.height - p.height) <= 1, "\(id): drawn \(d) vs routed around \(p)")
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func officeFlowSnapshot() throws {
        let (c, _) = Self.officeController(50)
        let scene = OfficeScene(size: Self.size)
        scene.reduceMotion = false
        let agents = c.synthetic!.agents
        var traffic = SyntheticTraffic(seed: 11)
        var t = 0.0
        var handoff = 0
        Self.run(scene, c, to: 3.0) { now, _ in
            let facts = traffic.facts(from: Date(timeIntervalSince1970: t), to: Date(timeIntervalSince1970: now + 1.0 / 60),
                                      agents: agents, rate: 15, burst: nil)
            t = now + 1.0 / 60
            c.model.ingest(facts, now: now)
            // A hand-off to the mail room now and then.
            if Int(now * 60) % 45 == 0, let from = agents.filter({ $0.state == .running }).dropFirst(handoff % 5).first {
                handoff += 1
                scene.update(controller: c, events: [VisualEvent(id: 900_000 + handoff, kind: .handoff, from: .agent(from.id),
                                                                  label: "BRH-\(100 + handoff)", start: now, duration: 1.4)], now: now)
            }
        }
        #expect(scene.particleKinds.contains(.note), "notes in flight")
        #expect(!scene.reviewOccupants.isEmpty, "someone in the review room")
        #expect(scene.parcelCount > 0, "parcels in the mail room")
        scene.zoomToFit(margin: 40)
        let image = try #require(MapSnapshotter.render(scene: scene, size: Self.size, steps: 2))
        #expect(MapSnapshotter.fraction(image, near: ThemeHex.bg0) > 0.3)
        MapSnapshotter.writeIfRequested(image, name: "office-50-flow")
    }

    // MARK: - Snapshots

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func officeSnapshots() throws {
        for n in [12, 50, 300] {
            let model = Self.model(agents: n)
            let scene = Self.scene(model)
            scene.zoomToFit(margin: 40)
            let image = try #require(MapSnapshotter.render(scene: scene, size: Self.size, steps: 60))
            #expect(image.width == 1600 && image.height == 900)
            let bg = MapSnapshotter.fraction(image, near: ThemeHex.bg0)
            let running = MapSnapshotter.fraction(image, near: ThemeHex.running)
            let lamp = MapSnapshotter.fraction(image, near: ThemeHex.officeLamp)
            #expect(bg > 0.3, "office-\(n) bg0 \(bg)")
            #expect(running > 0.0005, "office-\(n) running \(running)")
            if n <= 50 { #expect(lamp > 0, "office-\(n) lamp \(lamp)") }
            MapSnapshotter.writeIfRequested(image, name: "office-\(n)")

            guard n == 50 else { continue }
            // A zoom 1.5 crop of the fullest pod (then the most typing desks): handles, roles and desk items readable.
            let layout = scene.layout
            func lit(_ p: OfficePod) -> Int {
                layout.desks.values.filter { $0.podId == p.id && model.agents[$0.id]?.activity == .typing }.count
            }
            func desks(_ p: OfficePod) -> Int { layout.desks.values.filter { $0.podId == p.id }.count }
            let pod = try #require(layout.pods.values.max { a, b in (desks(a), lit(a), b.id) < (desks(b), lit(b), a.id) })
            scene.zoom = 1.5
            scene.camera?.position = CGPoint(x: pod.rect.mid.x, y: -pod.rect.mid.y)
            let detail = try #require(MapSnapshotter.render(scene: scene, size: Self.size, steps: 60))
            #expect(MapSnapshotter.fraction(detail, near: ThemeHex.text0) > 0, "handles draw")
            MapSnapshotter.writeIfRequested(detail, name: "office-50-detail")

            let still = Self.scene(model, reduceMotion: true)
            still.zoomToFit(margin: 40)
            let calm = try #require(MapSnapshotter.render(scene: still, size: Self.size, steps: 60))
            #expect(MapSnapshotter.fraction(calm, near: ThemeHex.bg0) > 0.3)
            MapSnapshotter.writeIfRequested(calm, name: "office-50-reduce-motion")
        }
    }
}
