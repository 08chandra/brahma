import Testing
import Foundation
import SpriteKit
import Metal
import AppKit
@testable import BrahmaCore
@testable import BrahmaAppModel
@testable import BrahmaMapKit

/// Scene tests render offscreen through `MapSnapshotter`; Tasks 9a and 9b add the org-chart cases.
@MainActor
@Suite(.scratch) struct OrgSceneTests {
    /// A `bg0` scene with one 100×100 `running` sprite rendered at 400×300: the sprite covers 1/12 of the image.
    /// A BGRA/RGBA mix-up in the snapshotter would make both fractions lie, which is why this test exists.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func snapshotterRendersSolidScene() throws {
        let size = CGSize(width: 400, height: 300)
        let scene = SKScene(size: size)
        scene.scaleMode = .aspectFill
        scene.backgroundColor = MapPalette.color(ThemeHex.bg0)
        let sprite = SKSpriteNode(color: MapPalette.color(ThemeHex.running), size: CGSize(width: 100, height: 100))
        sprite.position = CGPoint(x: 200, y: 150)
        scene.addChild(sprite)
        // The centered sprite is symmetric, so a vertically flipped readback would pass every fraction check. This one
        // sits in the upper-left quadrant (SpriteKit y points up) and must read back there, not in the lower left.
        let marker = SKSpriteNode(color: MapPalette.color(ThemeHex.accent), size: CGSize(width: 40, height: 40))
        marker.position = CGPoint(x: 60, y: 250)
        scene.addChild(marker)

        let image = try #require(MapSnapshotter.render(scene: scene, size: size))
        #expect(image.width == 400); #expect(image.height == 300)
        #expect(MapSnapshotter.fraction(image, near: ThemeHex.bg0) > 0.8)
        let running = MapSnapshotter.fraction(image, near: ThemeHex.running)
        #expect(abs(running - 1.0 / 12.0) < 0.01, "running fraction \(running)")
        // A channel swap would put the green sprite somewhere else entirely.
        #expect(MapSnapshotter.fraction(image, near: 0x67A432) < 0.001)
        // Image rows run top to bottom: scene y 250 of 300 is image row 50.
        #expect(Self.pixel(image, x: 60, y: 50) == ThemeHex.accent, "marker not in the upper left")
        #expect(Self.pixel(image, x: 60, y: 250) == ThemeHex.bg0, "readback is vertically flipped")
        #expect(Self.pixel(image, x: 340, y: 50) == ThemeHex.bg0)
        #expect(Self.pixel(image, x: 200, y: 150) == ThemeHex.running)
        #expect(MapSnapshotter.png(image) != nil)
        MapSnapshotter.writeIfRequested(image, name: "solid-scene")
    }

    // MARK: - Helpers

    /// `0xRRGGBB` of the pixel at (`x`, `y`), row 0 on top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> UInt32? {
        guard let data = MapSnapshotter.rgba(image), x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let i = (y * image.width + x) * 4
        return UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
    }

    static func hex(_ color: NSColor?) -> UInt32? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    static func controller(_ agents: Int, seed: UInt64 = 7) -> MapController {
        MapController(source: .synthetic(agents: agents, rate: 0, seed: seed), defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    static func scene(_ model: MapModel, collapsed: Set<String> = []) -> OrgScene {
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        scene.rebuild(model: model, collapsed: collapsed)
        return scene
    }

    /// A model over the synthetic company's first `n` agents' worth of structure, with `edit` applied to the agents.
    static func model(agents n: Int = 12, showFormer: Bool = false, people: MapPeople = .empty,
                      links: Bool = false, edit: (inout [Agent]) -> Void = { _ in }) -> MapModel {
        let made = SyntheticCompany.make(agents: n)
        var agents = made.agents
        edit(&agents)
        var model = MapModel()
        model.setShowFormer(showFormer)
        model.apply(MapInputs(agents: agents, pack: made.pack, currentItems: made.currentItems, blockers: made.blockers,
                              vacancies: made.vacancies, dotted: links ? sampleLinks(agents) : [], meetings: made.meetings,
                              people: people), now: 0)
        return model
    }

    /// Reviewer links between living agents a few seats apart, plus one navigator and one other link.
    static func sampleLinks(_ agents: [Agent]) -> [DottedLink] {
        let living = agents.filter { $0.state != .killed }.sorted { $0.id < $1.id }
        guard living.count > 20 else { return [] }
        var links: [DottedLink] = []
        for k in 0..<6 {
            links.append(DottedLink(from: living[k * 2].id, to: living[k * 2 + 9].id, kind: .reviewer, itemKey: "BRH-\(100 + k)"))
        }
        links.append(DottedLink(from: living[3].id, to: living[17].id, kind: .navigator, itemKey: "BRH-200"))
        links.append(DottedLink(from: living[1].id, to: living[19].id, kind: .other, itemKey: "BRH-201"))
        return links
    }

    static func defaultCollapsed(_ model: MapModel) -> Set<String> {
        let active = model.agents.values.filter { $0.state != .killed }.count
        return model.tree.collapsed(defaults: model.tree.defaultCollapsed(activeCount: active), overrides: [:], focus: nil)
    }

    // MARK: - Cards

    @Test func rebuildOneCardPerVisibleAgent() {
        let c = Self.controller(40)
        let scene = Self.scene(c.model, collapsed: c.collapsed)
        let active = c.model.agents.values.filter { $0.state != .killed }.count
        #expect(c.model.agents.count > active, "the synthetic company should hold a killed agent")
        #expect(scene.cardIds.count == active + 1 + c.model.vacancies.count)
        #expect(scene.cardIds.contains("owner"))
        for a in c.model.agents.values {
            #expect((scene.cardIds.contains(a.id)) == (a.state != .killed), "\(a.handle)")
        }
        for v in c.model.vacancies { #expect(scene.cardIds.contains("vacancy:\(v.id)")) }
        #expect(scene.stubIds.isEmpty)
        // Rebuilding the same model reuses every node.
        let before = scene.cardIds.compactMap { scene.cardNode($0) }
        scene.rebuild(model: c.model, collapsed: c.collapsed)
        let after = scene.cardIds.compactMap { scene.cardNode($0) }
        #expect(Set(before.map(ObjectIdentifier.init)) == Set(after.map(ObjectIdentifier.init)))
    }

    @Test func defaultCollapseShowsStubsAt300() {
        let c = Self.controller(300)
        let collapsed = c.collapsed
        let scene = Self.scene(c.model, collapsed: collapsed)
        let tree = c.model.tree
        let managersWithReports = tree.nodes.values.filter { $0.tier == .manager && !$0.childIds.isEmpty }.map(\.id)
        #expect(!managersWithReports.isEmpty)
        #expect(scene.stubIds == Set(managersWithReports))
        #expect(scene.stubIds == collapsed)
        // No card of anything under a collapsed manager.
        for m in collapsed {
            var walk = tree.nodes[m]!.childIds
            while let id = walk.popLast() {
                #expect(scene.cardNode(id) == nil, "\(id) under collapsed \(m)")
                walk.append(contentsOf: tree.nodes[id]?.childIds ?? [])
            }
        }
        #expect(scene.contentBounds.width < 12_000)
        #expect(scene.contentBounds.width > 0)
    }

    @Test func cardColorsFromTokens() throws {
        var ids: [String] = []
        let model = Self.model(agents: 12, showFormer: true) { agents in
            ids = agents.map(\.id)
            agents[1].state = .running; agents[1].paused = false
            agents[2].state = .running; agents[2].paused = true
            agents[3].state = .blocked
            agents[4].state = .ready
            agents[5].state = .sleeping
            agents[6].state = .killed
            agents[7].state = .blocked; agents[7].paused = true
        }
        let scene = Self.scene(model)
        func card(_ i: Int) throws -> OrgCardNode { try #require(scene.cardNode(ids[i]), "card \(i)") }
        let running = try card(1)
        #expect(Self.hex(running.statusBar.color) == ThemeHex.running)
        #expect(running.statusBar.action(forKey: OrgCardNode.pulseKey) != nil, "running pulses")
        #expect(Self.hex(running.border.color) == ThemeHex.line)

        let paused = try card(2)
        #expect(Self.hex(paused.statusBar.color) == ThemeHex.sleeping, "paused renders like sleeping")
        #expect(paused.statusBar.action(forKey: OrgCardNode.pulseKey) == nil, "only running pulses")

        let blocked = try card(3)
        #expect(Self.hex(blocked.statusBar.color) == ThemeHex.blocked)
        #expect(Self.hex(blocked.border.color) == ThemeHex.blocked)

        #expect(Self.hex(try card(4).statusBar.color) == ThemeHex.ready)
        #expect(Self.hex(try card(5).statusBar.color) == ThemeHex.sleeping)

        let killed = try card(6)
        #expect(abs(killed.alpha - 0.4) < 0.001)
        #expect(killed.childNode(withName: ".//strike") != nil, "the handle is struck through")
        #expect(running.alpha == 1)

        // A paused blocked agent is a sleeping one: no blocked border.
        let pausedBlocked = try card(7)
        #expect(Self.hex(pausedBlocked.statusBar.color) == ThemeHex.sleeping)
        #expect(Self.hex(pausedBlocked.border.color) == ThemeHex.line)
    }

    @Test func optionalPeopleHiddenWhenAbsent() throws {
        var ids: [String] = []
        let bare = Self.model(agents: 12) { ids = $0.map(\.id) }
        let bareScene = Self.scene(bare)
        for id in ids where bare.agents[id] != nil && bare.agents[id]!.state != .killed {
            let card = try #require(bareScene.cardNode(id))
            #expect(card.childNode(withName: ".//trustChip") == nil)
            #expect(card.childNode(withName: ".//perk") == nil)
            #expect(card.childNode(withName: ".//meterBar") == nil)
        }

        let people = MapPeople(trust: [ids[1]: MapTrust(label: "T2", title: "Trusted", tier: 2),
                                       ids[2]: MapTrust(label: "T0", title: "New", tier: 0)],
                               perks: [ids[1]: ["🚀", "🔥", "🎯"]],
                               meters: [ids[1]: MapMeter(line: "4 ITEMS", fraction: 0.9),
                                        ids[2]: MapMeter(line: "x", fraction: 0.4),
                                        ids[3]: MapMeter(line: "y", fraction: 0.6),
                                        ids[4]: MapMeter(line: "no fraction", fraction: nil)])
        let model = Self.model(agents: 12, people: people) { agents in
            for i in 1...4 { agents[i].state = .ready }
        }
        let scene = Self.scene(model)
        let t2 = try #require(scene.cardNode(ids[1]))
        let chip = try #require(t2.childNode(withName: ".//trustChip") as? SKSpriteNode)
        #expect(Self.hex(chip.color) == ThemeHex.success, "T2 chip is success")
        var perks = 0
        t2.enumerateChildNodes(withName: ".//perk") { _, _ in perks += 1 }
        #expect(perks == 2, "at most two perks")
        let fill = try #require(t2.childNode(withName: ".//meterFill") as? SKSpriteNode)
        #expect(Self.hex(fill.color) == ThemeHex.success, "0.9 is success")
        let track = try #require(t2.childNode(withName: ".//meterBar") as? SKSpriteNode)
        #expect(track.size == CGSize(width: 40, height: 3))

        let t0 = try #require(scene.cardNode(ids[2]))
        #expect(Self.hex((t0.childNode(withName: ".//trustChip") as? SKSpriteNode)?.color) == ThemeHex.warning)
        #expect(Self.hex((t0.childNode(withName: ".//meterFill") as? SKSpriteNode)?.color) == ThemeHex.danger, "0.4 is danger")
        let mid = try #require(scene.cardNode(ids[3]))
        #expect(Self.hex((mid.childNode(withName: ".//meterFill") as? SKSpriteNode)?.color) == ThemeHex.text1, "0.6 is text1")
        #expect(try #require(scene.cardNode(ids[4])).childNode(withName: ".//meterBar") == nil, "no fraction, no bar")
    }

    @Test func zoomLevelsGateTextAndItems() throws {
        let c = Self.controller(40)
        let scene = Self.scene(c.model, collapsed: c.collapsed)
        let withItem = try #require(c.model.agents.values.first { $0.item != nil && $0.state != .killed })
        let card = try #require(scene.cardNode(withItem.id))
        scene.zoom = 1.0
        #expect(!card.details.isHidden); #expect(card.itemLine.isHidden)
        scene.zoom = 1.5
        #expect(!card.details.isHidden); #expect(!card.itemLine.isHidden)
        scene.zoom = 0.4
        #expect(card.details.isHidden); #expect(card.itemLine.isHidden)
        #expect(!card.statusBar.isHidden, "the status bar stays at every zoom")
        scene.zoom = 99
        #expect(abs(scene.zoom - OrgScene.zoomRange.upperBound) < 1e-6)
        scene.zoom = 0.001
        #expect(abs(scene.zoom - OrgScene.zoomRange.lowerBound) < 1e-6)
    }

    @Test func hitTestCardsStubsVacancyBoard() throws {
        let c = Self.controller(40)
        let scene = Self.scene(c.model, collapsed: c.collapsed)
        let agent = try #require(c.model.agents.values.first { $0.state != .killed })
        #expect(scene.hit(at: try #require(scene.cardRect(agent.id)).center) == .agent(agent.id))
        #expect(scene.hit(at: try #require(scene.cardRect("owner")).center) == .owner)
        let vacancy = try #require(c.model.vacancies.first)
        #expect(scene.hit(at: try #require(scene.cardRect("vacancy:\(vacancy.id)")).center) == .vacancy(vacancy.id))
        #expect(scene.hit(at: CGPoint(x: -5000, y: 5000)) == nil)

        // A team band's label strip hits the band's manager; its body does not.
        let (manager, band) = try #require(scene.bandRects.sorted { $0.key < $1.key }.first)
        #expect(scene.hit(at: CGPoint(x: band.minX + 12, y: band.maxY - 5)) == .team(manager))
        #expect(scene.bandLabelRect(manager) != nil)

        // Stubs, in the collapsed 300-agent company.
        let big = Self.controller(300)
        let bigScene = Self.scene(big.model, collapsed: big.collapsed)
        let stubOwner = try #require(bigScene.stubIds.sorted().first)
        #expect(bigScene.hit(at: try #require(bigScene.stubRect(stubOwner)).center) == .stub(stubOwner))
        #expect(bigScene.hit(at: try #require(bigScene.cardRect(stubOwner)).center) == .agent(stubOwner))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func reorgAnimatesToNewRect() throws {
        let made = SyntheticCompany.make(agents: 40)
        func model(_ agents: [Agent]) -> MapModel {
            var m = MapModel()
            m.apply(MapInputs(agents: agents, pack: made.pack, vacancies: made.vacancies), now: 0)
            return m
        }
        let before = model(made.agents)
        let scene = Self.scene(before)
        // Move the last living leaf under another manager so some card has to travel.
        let tree = before.tree
        let leaf = try #require(tree.order.last { id in
            id != "owner" && !id.hasPrefix("vacancy:") && (tree.nodes[id]?.childIds.isEmpty ?? false)
                && before.agents[id]?.state != .killed })
        let newManager = try #require(tree.order.first { id in
            id != "owner" && id != tree.nodes[leaf]?.parentId && tree.nodes[id]?.tier == .manager && !(tree.nodes[id]?.childIds.isEmpty ?? true) })
        var agents = made.agents
        let index = try #require(agents.firstIndex { $0.id == leaf })
        agents[index].managerId = newManager
        let after = model(agents)
        #expect(after.tree != before.tree)

        let oldRect = try #require(scene.cardRect(leaf))
        let node = try #require(scene.cardNode(leaf))
        scene.rebuild(model: after, collapsed: [])
        let newRect = try #require(scene.cardRect(leaf))
        #expect(newRect != oldRect)
        #expect(node === scene.cardNode(leaf), "the node is reused")
        #expect(abs(node.position.x - oldRect.midX) < 0.5 && abs(node.position.y - oldRect.midY) < 0.5,
                "the card has not jumped yet")
        // 0.4 s of 60 Hz frames, with margin, through the offscreen renderer (it steps the scene's actions).
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 36))
        #expect(abs(node.position.x - newRect.midX) < 0.5, "x \(node.position.x) vs \(newRect.midX)")
        #expect(abs(node.position.y - newRect.midY) < 0.5, "y \(node.position.y) vs \(newRect.midY)")
    }

    // MARK: - Snapshots

    @Test func dottedLinesDrawOneBatchedSpritePerKind() throws {
        let model = Self.model(agents: 40, links: true)
        #expect(model.dotted.count == 8)
        let scene = Self.scene(model)
        #expect(Set(scene.dottedSpriteNames) == ["dotted-reviewer", "dotted-navigator", "dotted-other"])
        // Collapsing every manager moves link ends onto the collapsed card; links inside one subtree vanish.
        let collapsed = Set(model.tree.nodes.values.filter { $0.tier == .manager && !$0.childIds.isEmpty }.map(\.id))
        scene.rebuild(model: model, collapsed: collapsed)
        #expect(scene.dottedSpriteNames.count <= 3)
        let none = Self.scene(Self.model(agents: 40))
        #expect(none.dottedSpriteNames.isEmpty)
    }

    // MARK: - Snapshots

    /// 60 frames is one full pulse cycle: the running status bars are back at full alpha, so their color is the token's.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func orgSnapshots() throws {
        let size = CGSize(width: 1600, height: 900)
        for n in [40, 300] {
            let model = Self.model(agents: n, links: true)
            let scene = OrgScene(size: size)
            scene.rebuild(model: model, collapsed: Self.defaultCollapsed(model))
            scene.zoomToFit()
            let image = try #require(MapSnapshotter.render(scene: scene, size: size, steps: 60))
            #expect(image.width == 1600 && image.height == 900)
            let bg = MapSnapshotter.fraction(image, near: ThemeHex.bg0)
            let running = MapSnapshotter.fraction(image, near: ThemeHex.running)
            let accent = MapSnapshotter.fraction(image, near: ThemeHex.accent)
            #expect(bg > 0.4, "org-\(n) bg0 \(bg)")
            #expect(running > 0.0005, "org-\(n) running \(running)")
            #expect(accent > 0, "org-\(n) accent \(accent)")
            MapSnapshotter.writeIfRequested(image, name: "org-\(n)")

            if n == 40 {
                // A zoom 1.5 crop around a card with a current item, so the item lines show.
                let candidates = model.agents.values.filter { $0.item != nil && $0.state != .killed }.sorted { $0.id < $1.id }
                let withItem = try #require(candidates.first { $0.state == .running } ?? candidates.first)
                let rect = try #require(scene.cardRect(withItem.id))
                scene.zoom = 1.5
                scene.camera?.position = CGPoint(x: rect.midX, y: rect.midY - 60)
                let detail = try #require(MapSnapshotter.render(scene: scene, size: size, steps: 60))
                #expect(MapSnapshotter.fraction(detail, near: ThemeHex.bg0) > 0.4)
                #expect(MapSnapshotter.fraction(detail, near: ThemeHex.text2) > 0, "item lines draw")
                MapSnapshotter.writeIfRequested(detail, name: "org-40-detail")
            }
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

