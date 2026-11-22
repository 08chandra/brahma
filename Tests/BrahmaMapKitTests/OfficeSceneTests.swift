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

        let pod = try #require(scene.layout.pods.values.sorted { $0.id < $1.id }.first { $0.managerId != nil })
        let label = pod.labelRect
        #expect(scene.hit(at: CGPoint(x: label.x + 4, y: -(label.y + label.h / 2))) == .team(pod.managerId!))

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
        // Sleep the first living agent: same node, new state.
        let edited = Self.model(agents: 50, edit: { agents in
            if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].state = .sleeping }
        })
        scene.rebuild(model: edited)
        #expect(scene.deskNode(id) === node && !node.lampOn)
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
