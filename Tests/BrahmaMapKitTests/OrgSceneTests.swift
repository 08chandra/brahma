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

    /// A live update (an item changing) reconfigures a card; it must not cancel or strand a reorg glide in flight.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func contentChangeMidGlideStillArrives() throws {
        let made = SyntheticCompany.make(agents: 40)
        func model(_ agents: [Agent], items: [String: String] = [:]) -> MapModel {
            var m = MapModel()
            m.apply(MapInputs(agents: agents, pack: made.pack, currentItems: items, vacancies: made.vacancies), now: 0)
            return m
        }
        let before = model(made.agents)
        let scene = Self.scene(before)
        let tree = before.tree
        let leaf = try #require(tree.order.last { id in
            id != "owner" && !id.hasPrefix("vacancy:") && (tree.nodes[id]?.childIds.isEmpty ?? false)
                && before.agents[id]?.state != .killed })
        let newManager = try #require(tree.order.first { id in
            id != "owner" && id != tree.nodes[leaf]?.parentId && tree.nodes[id]?.tier == .manager && !(tree.nodes[id]?.childIds.isEmpty ?? true) })
        var agents = made.agents
        agents[try #require(agents.firstIndex { $0.id == leaf })].managerId = newManager

        let node = try #require(scene.cardNode(leaf))
        let oldRect = try #require(scene.cardRect(leaf))
        scene.rebuild(model: model(agents), collapsed: [])
        let newRect = try #require(scene.cardRect(leaf))
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 10))
        let mid = node.position
        #expect(mid != CGPoint(x: oldRect.midX, y: oldRect.midY) && mid != CGPoint(x: newRect.midX, y: newRect.midY),
                "the glide is under way")

        // The same card gets a current item mid-glide: same layout, new content.
        let contentBefore = node.content
        scene.rebuild(model: model(agents, items: [leaf: "BRH-9 A fresh item"]), collapsed: [])
        #expect(node.content != contentBefore, "the card was reconfigured")
        #expect(node === scene.cardNode(leaf))
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 36))
        #expect(abs(node.position.x - newRect.midX) < 0.5, "x \(node.position.x) vs \(newRect.midX)")
        #expect(abs(node.position.y - newRect.midY) < 0.5, "y \(node.position.y) vs \(newRect.midY)")
    }

    @Test func pulseSurvivesUnrelatedContentChange() throws {
        var ids: [String] = []
        func model(item: String?) -> MapModel {
            let made = SyntheticCompany.make(agents: 12)
            var agents = made.agents
            ids = agents.map(\.id)
            agents[1].state = .running; agents[1].paused = false
            var m = MapModel()
            m.apply(MapInputs(agents: agents, pack: made.pack, currentItems: item.map { [agents[1].id: $0] } ?? [:]), now: 0)
            return m
        }
        let scene = Self.scene(model(item: nil))
        let card = try #require(scene.cardNode(ids[1]))
        let bar = card.statusBar
        #expect(bar.action(forKey: OrgCardNode.pulseKey) != nil)
        scene.rebuild(model: model(item: "BRH-1 something"), collapsed: [])
        #expect(card.content != nil)
        #expect(card.statusBar === bar, "the running bar and its pulse carry over")
        #expect(bar.action(forKey: OrgCardNode.pulseKey) != nil)
        #expect(bar.parent === card)
    }

    @Test func bandsNeverTouchEachOtherOrForeignCards() throws {
        let model = Self.model(agents: 40)
        let scene = Self.scene(model)
        let bands = scene.bandRects.sorted { $0.key < $1.key }
        #expect(bands.count >= 3)
        for (i, a) in bands.enumerated() {
            for b in bands[(i + 1)...] where !a.value.contains(b.value) && !b.value.contains(a.value) {
                #expect(!a.value.insetBy(dx: -3, dy: -3).intersects(b.value), "\(a.key) and \(b.key) are less than 6 pt apart")
            }
            // Only the manager's own subtree may lie inside its band.
            var subtree: Set<String> = [a.key]
            var walk = model.tree.nodes[a.key]?.childIds ?? []
            while let id = walk.popLast() { subtree.insert(id); walk.append(contentsOf: model.tree.nodes[id]?.childIds ?? []) }
            for id in scene.cardIds where !subtree.contains(id) {
                let r = try #require(scene.cardRect(id))
                #expect(!a.value.intersects(r), "\(id) overlaps the band of \(a.key)")
            }
        }
    }

    @Test func vacancyTitleCentersWhileNoteIsHidden() throws {
        let made = SyntheticCompany.make(agents: 40)
        var vacancy = try #require(made.vacancies.first)
        vacancy.note = "Backfill for the platform team"
        var model = MapModel()
        model.apply(MapInputs(agents: made.agents, pack: made.pack, vacancies: [vacancy]), now: 0)
        let scene = Self.scene(model)
        let card = try #require(scene.cardNode("vacancy:\(vacancy.id)"))
        let title = try #require(card.vacancyTitle)
        scene.zoom = 1.0
        #expect(card.itemLine.isHidden); #expect(title.position.y == 0, "the lone title is centered")
        scene.zoom = 1.5
        #expect(!card.itemLine.isHidden); #expect(title.position.y == 6, "title makes room for the note")
        scene.zoom = 0.4
        #expect(title.position.y == 0)
    }

    // MARK: - Task 9b: motion

    /// One frame per 1/60 s from `from` through `to`, the way the view drives the scene; returns the last frame time.
    @discardableResult
    static func run(_ scene: OrgScene, _ c: MapController, from: TimeInterval = 0, to: TimeInterval,
                    dt: TimeInterval = 1.0 / 60, each: (TimeInterval) -> Void = { _ in }) -> TimeInterval {
        var t = from, last = from
        while t <= to + 1e-9 {
            scene.update(controller: c, events: c.frame(now: t), now: t)
            each(t)
            last = t
            t += dt
        }
        return last
    }

    /// Re-applies the synthetic world (after a test edited it) so the model emits the diff's events.
    static func reapply(_ c: MapController, now: TimeInterval = 0, edit: (inout MapInputs) -> Void = { _ in }) {
        var inputs = MapController.inputs(c.synthetic!)
        edit(&inputs)
        c.model.apply(inputs, now: now)
    }

    @Test func particlesPooledAndBounded() throws {
        let c = Self.controller(40)
        // Keep every message a particle: aggregate mode would swallow the burst and leave the pool untouched.
        c.model.throttle.aggregateEnter = .infinity
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        var traffic = SyntheticTraffic(seed: 3)
        let facts = traffic.facts(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1),
                                  agents: c.synthetic!.agents, rate: 2000, burst: nil)
        #expect(facts.count >= 2000)
        c.model.ingest(facts, now: 0)
        #expect(c.model.stats.ingested >= 2000)
        var peak = 0
        Self.run(scene, c, to: 2.0) { _ in
            peak = Swift.max(peak, scene.particlesInUse)
            #expect(scene.particlesInUse <= 150)
        }
        #expect(peak > 100, "the pool is exercised: peak \(peak)")
        #expect(scene.particleSpriteCount <= 150, "sprites are pooled, never beyond 150: \(scene.particleSpriteCount)")
    }

    @Test func inFlightParticleRetargetsOnCollapse() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        scene.update(controller: c, events: [], now: 0)
        let tree = c.model.tree
        let leaf = try #require(tree.order.first { id in
            guard id != "owner", !id.hasPrefix("vacancy:"), tree.nodes[id]?.childIds.isEmpty == true,
                  let parent = tree.nodes[id]?.parentId else { return false }
            return tree.nodes[parent]?.tier == .manager && tree.nodes[parent]?.parentId != nil
        })
        let manager = try #require(tree.nodes[leaf]?.parentId)
        let event = VisualEvent(id: 9001, kind: .message, from: .owner, to: .agent(leaf), start: 0, duration: 0.9)
        scene.update(controller: c, events: [event], now: 0.1)
        let before = try #require(scene.particleTarget(9001))
        #expect(before == (try #require(scene.cardRect(leaf))).center)

        c.toggleSubtree(manager)
        #expect(c.collapsed.contains(manager))
        scene.update(controller: c, events: [], now: 0.2)
        let after = try #require(scene.particleTarget(9001))
        #expect(after == (try #require(scene.cardRect(manager))).center, "retargeted to the visible ancestor")
        #expect(scene.cardNode(leaf) == nil)
    }

    @Test func leaveFadesAndRemoves() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        scene.update(controller: c, events: c.frame(now: 0), now: 0)
        let victim = try #require(c.synthetic!.agents.first { a in
            a.state != .killed && c.model.tree.nodes[a.id]?.childIds.isEmpty == true && a.managerId != nil
        })
        let index = try #require(c.synthetic!.agents.firstIndex { $0.id == victim.id })
        c.synthetic!.agents[index].state = .killed
        Self.reapply(c)
        #expect(!c.model.showFormer)

        Self.run(scene, c, from: 0.1, to: 0.8)
        let node = try #require(scene.cardNode(victim.id), "the card stays while it fades")
        #expect(scene.leavingIds == [victim.id])
        #expect(node.alpha < 0.8 && node.alpha > 0.1, "fading: \(node.alpha)")
        Self.run(scene, c, from: 0.8, to: 1.7)
        #expect(scene.cardNode(victim.id) == nil, "removed after the 1.5 s fade")
        #expect(scene.leavingIds.isEmpty)
        #expect(!scene.cardIds.contains(victim.id))
        #expect(scene.cardRect(victim.id) == nil, "the layout closed the gap")
    }

    @Test func meetingHullCoversParticipants() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        // A team of three living agents with a planning meeting whose title carries a control character.
        let living = c.synthetic!.agents.filter { $0.state != .killed && $0.team != nil }
        let team = try #require(Dictionary(grouping: living, by: \.team!).values.first { $0.count >= 3 })
        let ids = team.prefix(3).map(\.id)
        let title = "SPRINT\u{202E}\u{7} 1 PLANNING"
        Self.reapply(c) {
            $0.meetings = [Meeting(id: "sprint-t", kind: .sprintPlanning, title: title, participantIds: ids)]
        }
        Self.run(scene, c, to: 0.2)
        let hull = try #require(scene.meetingHulls["sprint-t"])
        for id in ids {
            let card = try #require(scene.cardRect(id))
            #expect(hull.rect.contains(card), "\(id) inside the hull")
        }
        #expect(hull.title == MapText.clean(title, max: 40))
        #expect(!hull.title.contains("\u{202E}"))
        // The hull goes away with the meeting.
        Self.reapply(c, now: 0.3) { $0.meetings = [] }
        Self.run(scene, c, from: 0.3, to: 0.5)
        #expect(scene.meetingHulls.isEmpty)
    }

    @Test func highlightRingExpires() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        scene.update(controller: c, events: c.frame(now: 0), now: 0)
        let id = try #require(c.synthetic!.agents.first { $0.state != .killed && $0.managerId != nil }?.id)
        c.jump(to: id)
        Self.run(scene, c, from: 0.1, to: 0.3)
        let card = try #require(scene.cardRect(id))
        let ring = try #require(scene.highlightRing, "ring while highlighted")
        #expect(ring.contains(card))
        #expect(ring.width - card.width <= 12, "a tight ring")
        Self.run(scene, c, from: 0.3, to: 1.7)
        #expect(c.highlightId == nil)
        #expect(scene.highlightRing == nil, "ring gone after 1.6 s of frames")
    }

    @Test func menusComeFromActions() async throws {
        // Pure mapping: titles come from the actions, writes are dropped during a replay, handles are cleaned.
        let all: [MapAction] = [.message(handle: "cto"), .follow(agentId: "a-1"), .addVacancy(managerHandle: "cto"),
                                .fill(handle: "eng-1"), .removeVacancy(handle: "eng-1")]
        #expect(MapMenu.entries(for: all, replaying: false).map(\.title)
                == ["Message @cto", "Follow", "Add vacancy under @cto", "Fill…", "Remove vacancy"])
        #expect(MapMenu.entries(for: all, replaying: true).map(\.title) == ["Message @cto", "Follow"])
        #expect(MapMenu.entries(for: [.addVacancy(managerHandle: nil)], replaying: false).map(\.title) == ["Add vacancy"])
        #expect(MapMenu.entries(for: [.fill(handle: "x"), .removeVacancy(handle: "x"), .addVacancy(managerHandle: nil)],
                                replaying: true).isEmpty)
        let evil = "cto\u{202E}\n\u{7}" + String(repeating: "x", count: 80)
        for entry in MapMenu.entries(for: [.message(handle: evil), .addVacancy(managerHandle: evil)], replaying: false) {
            #expect(!entry.title.contains("\u{202E}") && !entry.title.contains("\n") && !entry.title.contains("\u{7}"), "\(entry.title)")
            #expect(entry.title.count <= 60)
        }
        #expect(MapMenu.entries(for: [.message(handle: evil)], replaying: false).first?.title
                == "Message @" + MapText.clean(evil, max: 32))

        // From a live company: an org vacancy offers Fill… and Remove vacancy; a provider's seat and any hit on the demo offer nothing.
        let dir = try tempDir()
        let store = try Store(path: dir.appending(path: "brahma.db").path)
        let workspaces = try tempDir().appending(path: "workspaces", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        let company = try store.createCompany(name: "Acme", goal: "Build", workspacesRoot: workspaces)
        _ = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "sonnet")
        let cto = try store.hire(companyId: company.id, name: "cto", role: "cto", model: "sonnet")
        let row = try store.addVacancy(companyId: company.id, role: "engineer", managerHandle: "cto", team: nil, note: "")
        let provider = StaticPeople(MapPeople(vacancies: [
            Vacancy(id: "x-1", role: "designer", roleTitle: "Designer", managerId: cto.id, team: nil, note: "", source: .org),
        ]))
        let live = MapController(source: .live(store: store, companyId: company.id), people: provider,
                                 defaults: UserDefaults(suiteName: UUID().uuidString)!)
        live.sync(snapshot: try Snapshot.load(store: store, selectedCompanyId: company.id))
        await live.poll()
        #expect(live.model.vacancies.contains { $0.id == "x-1" && $0.source == .provider })
        func titles(_ c: MapController, _ hit: MapHit) -> [String] {
            MapMenu.entries(for: c.actions(for: hit), replaying: c.replay != nil).map(\.title)
        }
        #expect(titles(live, .vacancy(row.handle)) == ["Fill…", "Remove vacancy"])
        #expect(titles(live, .vacancy("x-1")).isEmpty)
        #expect(titles(live, .stub(cto.id)).isEmpty)
        #expect(titles(live, .owner) == ["Add vacancy"])
        #expect(titles(live, .agent(cto.id)) == ["Message @cto", "Follow", "Add vacancy under @cto"])
        let demo = Self.controller(40)
        let demoVacancy = try #require(demo.model.vacancies.first?.id)
        for hit: MapHit in [.agent(demo.model.agents.keys.sorted()[0]), .owner, .vacancy(demoVacancy), .stub("x"), .team("x")] {
            #expect(titles(demo, hit).isEmpty, "\(hit)")
        }
    }

    @Test func hoverIsThrottledTo30Hz() {
        var throttle = HoverThrottle()
        let verdicts = [100.000, 100.010, 100.030, 100.034, 100.050, 100.068].map { throttle.allow($0) }
        #expect(verdicts == [true, false, false, true, false, true])
        let afterJump = throttle.allow(50.0)
        #expect(afterJump, "a clock that jumped back is not stuck")
        var count = 0
        var t = 0.0
        var fast = HoverThrottle()
        while t < 1 { if fast.allow(t) { count += 1 }; t += 0.001 }
        #expect(count >= 29 && count <= 31, "\(count) in a second")
    }

    @Test func eventVisualsByKind() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        scene.update(controller: c, events: [], now: 0)
        let ids = c.model.tree.order.filter { $0 != "owner" && !$0.hasPrefix("vacancy:") }
        let (a, b) = (ids[1], ids[5])
        let events = [
            VisualEvent(id: 1, kind: .message, from: .agent(a), to: .agent(b), count: 3, label: "×3", start: 0, duration: 0.9),
            VisualEvent(id: 2, kind: .handoff, from: .agent(a), to: .agent(b), label: "BRH-7\u{202E}", start: 0, duration: 1.4),
            VisualEvent(id: 3, kind: .broadcast, from: .agent(a), start: 0, duration: 0.6),
        ]
        scene.update(controller: c, events: events, now: 0.3)
        let dot = try #require(scene.particleSprite(1))
        #expect(dot.size == CGSize(width: 5, height: 5))
        #expect(scene.particleLabel(1) != nil, "×n label on a coalesced particle")
        let square = try #require(scene.particleSprite(2))
        #expect(square.size == CGSize(width: 7, height: 7))
        #expect(Self.hex(square.color) == ThemeHex.warning)
        #expect(scene.particleLabel(2) != nil, "the key label")
        let ring = try #require(scene.particleSprite(3))
        let small = ring.size.width
        scene.update(controller: c, events: [], now: 0.5)
        #expect(try #require(scene.particleSprite(3)).size.width > small, "the ring expands")
        let rect = try #require(scene.cardRect(a))
        #expect(abs(ring.position.x - rect.midX) < 0.5 && abs(ring.position.y - rect.midY) < 0.5, "the ring sits on the card")
        // A single message has no count label.
        scene.update(controller: c, events: [VisualEvent(id: 4, kind: .message, from: .agent(a), to: .agent(b), start: 0.5, duration: 0.9)], now: 0.5)
        #expect(scene.particleLabel(4) == nil)
        // Done after their duration.
        scene.update(controller: c, events: [], now: 3)
        #expect(scene.particlesInUse == 0)
    }

    @Test func glowEdgesAreBoundedAndWeighted() throws {
        let c = Self.controller(40)
        c.model.throttle.aggregateEnter = .infinity
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        var traffic = SyntheticTraffic(seed: 5)
        var t = 0.0
        Self.run(scene, c, to: 1.0) { now in
            let facts = traffic.facts(from: Date(timeIntervalSince1970: t), to: Date(timeIntervalSince1970: now + 1.0 / 60),
                                      agents: c.synthetic!.agents, rate: 60, burst: nil)
            t = now + 1.0 / 60
            c.model.ingest(facts, now: now)
        }
        let edges = c.model.edges(now: 1.0)
        #expect(!edges.isEmpty)
        let glow = scene.glowEdges
        #expect(!glow.isEmpty && glow.count <= 200)
        let heaviest = try #require(glow.max { $0.width < $1.width })
        #expect(heaviest.width > 1 && heaviest.width <= 5, "width follows MapEdges.thickness")
        #expect(glow.allSatisfy { $0.alpha > 0 && $0.alpha <= 1 })
    }

    @Test func cameraEasesToFollowedAgentAndBack() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        scene.update(controller: c, events: [], now: 0)
        let camera = try #require(scene.camera)
        let fitCenter = scene.contentBounds.center
        #expect(abs(camera.position.x - fitCenter.x) < 0.5 && abs(camera.position.y - fitCenter.y) < 0.5, "starts fitted")
        let fitZoom = scene.zoom

        let id = try #require(c.synthetic!.agents.first { $0.state != .killed && $0.managerId != nil }?.id)
        c.follow(id)
        scene.update(controller: c, events: [], now: 1.0)
        scene.update(controller: c, events: [], now: 1.15)
        let rect = try #require(scene.cardRect(id))
        let halfway = camera.position
        #expect(abs(halfway.x - rect.midX) > 0.5 || abs(halfway.y - rect.midY) > 0.5, "0.3 s ease: not there yet at 0.15 s")
        scene.update(controller: c, events: [], now: 1.4)
        #expect(abs(camera.position.x - rect.midX) < 0.5 && abs(camera.position.y - rect.midY) < 0.5)
        #expect(scene.zoom >= 1.0 - 1e-9)

        // While following, the camera tracks the card as it moves.
        let node = try #require(scene.cardNode(id))
        node.position.x += 80
        scene.update(controller: c, events: [], now: 1.5)
        #expect(abs(camera.position.x - node.position.x) < 0.5)
        #expect(c.zoom == scene.zoom, "the scene's zoom is written to the controller")

        c.zoomToFit()
        scene.update(controller: c, events: [], now: 2.0)
        scene.update(controller: c, events: [], now: 2.4)
        #expect(abs(camera.position.x - fitCenter.x) < 0.5 && abs(camera.position.y - fitCenter.y) < 0.5)
        #expect(abs(scene.zoom - fitZoom) < 1e-6)
    }

    @Test func hireStateChangeAndPromotionPlayOnTheCard() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        let id = try #require(c.synthetic!.agents.first { $0.state != .killed && $0.managerId != nil }?.id)
        Self.reapply(c) { $0.people = MapPeople(trust: [id: MapTrust(label: "T2", title: "Trusted", tier: 2)]) }
        scene.update(controller: c, events: [], now: 0)
        let node = try #require(scene.cardNode(id))
        let promotion = VisualEvent(id: 1, kind: .promotion(from: "T1", to: "T2"), from: .agent(id), start: 0, duration: 1.2)
        scene.update(controller: c, events: [promotion], now: 0.05)
        let chip = try #require(node.childNode(withName: ".//trustChipGroup"))
        #expect(abs(chip.xScale - 1.4) < 1e-6, "the chip pops from 1.4")
        #expect(Self.hex((node.childNode(withName: ".//trustChip") as? SKSpriteNode)?.color) == ThemeHex.success, "recolored to the new tier")

        scene.update(controller: c, events: [VisualEvent(id: 2, kind: .stateChange(from: .ready, to: .running), from: .agent(id),
                                                          start: 0.1, duration: 0.2)], now: 0.1)
        #expect(node.childNode(withName: ".//barFlash") != nil, "the bar flashes")

        scene.update(controller: c, events: [VisualEvent(id: 3, kind: .hire, from: .agent(id), start: 0.1, duration: 0.4)], now: 0.1)
        #expect(abs(node.xScale - 0.6) < 1e-6 && node.alpha == 0, "a hire starts at 60 % and transparent")
        #expect(node.childNode(withName: ".//hireFlash") != nil, "with an accent border flash")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func cardEffectsSettle() throws {
        let c = Self.controller(40)
        let scene = OrgScene(size: CGSize(width: 1600, height: 900))
        let id = try #require(c.synthetic!.agents.first { $0.state != .killed && $0.managerId != nil }?.id)
        Self.reapply(c) { $0.people = MapPeople(trust: [id: MapTrust(label: "T2", title: "Trusted", tier: 2)]) }
        scene.update(controller: c, events: [], now: 0)
        let node = try #require(scene.cardNode(id))
        scene.update(controller: c, events: [
            VisualEvent(id: 1, kind: .promotion(from: "T1", to: "T2"), from: .agent(id), start: 0, duration: 1.2),
            VisualEvent(id: 3, kind: .hire, from: .agent(id), start: 0, duration: 0.4),
            VisualEvent(id: 2, kind: .stateChange(from: .ready, to: .running), from: .agent(id), start: 0, duration: 0.2),
        ], now: 0.05)
        _ = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 60))
        #expect(abs(node.xScale - 1) < 1e-6 && abs(node.alpha - 1) < 1e-6, "the hire settled: \(node.xScale) \(node.alpha)")
        #expect(abs(try #require(node.childNode(withName: ".//trustChipGroup")).xScale - 1) < 1e-6)
        #expect(node.childNode(withName: ".//barFlash") == nil && node.childNode(withName: ".//hireFlash") == nil)
    }

    /// A 50 msg/s burst for 60 frames lights the tree: more accent pixels than the static chart.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func flowSnapshot() throws {
        let size = CGSize(width: 1600, height: 900)
        let still = Self.controller(40)
        let stillScene = OrgScene(size: size)
        Self.run(stillScene, still, to: 0.05)
        stillScene.zoomToFit()
        let base = try #require(MapSnapshotter.render(scene: stillScene, size: size, steps: 60))
        let baseAccent = MapSnapshotter.fraction(base, near: ThemeHex.accent)

        let c = Self.controller(40)
        let scene = OrgScene(size: size)
        var traffic = SyntheticTraffic(seed: 11)
        var t = 0.0
        Self.run(scene, c, to: 1.0) { now in
            let facts = traffic.facts(from: Date(timeIntervalSince1970: t), to: Date(timeIntervalSince1970: now + 1.0 / 60),
                                      agents: c.synthetic!.agents, rate: 50, burst: nil)
            t = now + 1.0 / 60
            c.model.ingest(facts, now: now)
        }
        scene.zoomToFit()
        let image = try #require(MapSnapshotter.render(scene: scene, size: size, steps: 2))
        let accent = MapSnapshotter.fraction(image, near: ThemeHex.accent)
        #expect(accent > baseAccent, "flow \(accent) vs static \(baseAccent)")
        #expect(MapSnapshotter.fraction(image, near: ThemeHex.bg0) > 0.3)
        #expect(scene.meetingHulls.count == 1, "the synthetic sprint meeting is drawn")
        MapSnapshotter.writeIfRequested(image, name: "org-40-flow")
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

/// A fixed people answer for the live-controller menu test.
struct StaticPeople: MapPeopleProviding {
    let people: MapPeople
    init(_ people: MapPeople) { self.people = people }
    func load(store: Store, companyId: String, now: Date) throws -> MapPeople { people }
}

