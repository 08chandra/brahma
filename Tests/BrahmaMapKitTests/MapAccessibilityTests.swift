import Testing
import Foundation
import SpriteKit
import Metal
import AppKit
@testable import BrahmaCore
@testable import BrahmaAppModel
@testable import BrahmaMapKit

/// VoiceOver and Reduce Motion for the map (spec §5.6): the office's elements (one per desk, the board room and the
/// review, break and mail rooms), none for the org chart (Plan P's frozen inventory), and the system's Reduce Motion
/// reaching both scenes through `MapSKView`.
@MainActor
@Suite(.scratch) struct MapAccessibilityTests {
    static let size = CGSize(width: 1600, height: 900)

    // MARK: - Helpers

    static func view(showing scene: SKScene) -> MapSKView {
        let view = MapSKView(frame: CGRect(origin: .zero, size: size))
        view.presentScene(scene)
        return view
    }

    static func officeView(_ model: MapModel) -> (view: MapSKView, scene: OfficeScene) {
        let scene = OfficeSceneTests.scene(model)
        return (view(showing: scene), scene)
    }

    static func elements(_ view: MapSKView) -> [NSAccessibilityElement] {
        (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    /// The map view answers as a freshly made plain `SKView` does (ruling R33): the same element flag and role, so its
    /// parent's accessibility children (Plan P's frozen inventory) do not change in either mode.
    static func expectPlainSKViewElement(_ view: MapSKView, sourceLocation: SourceLocation = #_sourceLocation) {
        let plain = SKView(frame: CGRect(origin: .zero, size: size))
        plain.presentScene(SKScene(size: size))
        #expect(view.isAccessibilityElement() == plain.isAccessibilityElement(), sourceLocation: sourceLocation)
        #expect(view.accessibilityRole() == plain.accessibilityRole(), sourceLocation: sourceLocation)
    }

    /// The label spec §5.6 gives a desk: the hover card's cleaned handle, role and state, then its item when it has one.
    static func deskLabel(_ card: MapHoverCard) -> String {
        "\(card.handle), \(card.role), \(card.stateLabel)" + (card.item.map { ", " + $0 } ?? "")
    }

    // MARK: - Keys

    /// The office unlock's keyboard route (spec §4.1): the map takes first responder on a click and hands unmodified keys to
    /// `onKey` (shift allowed; command, control and option keys are not its), and being first responder changes nothing in
    /// its accessibility answer (ruling R33).
    @Test func mapViewTakesKeysWithoutChangingItsElement() throws {
        let view = Self.view(showing: OrgScene(size: Self.size))
        var keys: [Character] = []
        view.onKey = { keys.append($0) }
        #expect(view.acceptsFirstResponder)
        func key(_ s: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                          context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false,
                                          keyCode: 0))
        }
        view.keyDown(with: try key("o"))
        view.keyDown(with: try key("F", .shift))
        view.keyDown(with: try key("f", .command))
        view.keyDown(with: try key("f", .control))
        view.keyDown(with: try key("f", .option))
        view.keyDown(with: try key("ic"))
        view.keyDown(with: try key("1"))
        #expect(keys == ["o", "F", "i", "c", "1"])

        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil }
        Self.expectPlainSKViewElement(view)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        #expect(window.firstResponder === view)
        Self.expectPlainSKViewElement(view)
        view.presentScene(OfficeScene(size: Self.size))
        Self.expectPlainSKViewElement(view)
    }

    // MARK: - Items

    @Test func officeItemsOnePerDeskPlusRooms() throws {
        let model = OfficeSceneTests.model(agents: 50, inputs: { $0.openAsks = 3 })
        let scene = OfficeSceneTests.scene(model)
        let items = scene.accessibilityItems(limit: MapSKView.accessibilityLimit)
        let living = OfficeSceneTests.living(model)
        #expect(!model.vacancies.isEmpty, "the synthetic company should hold a vacancy")
        #expect(items.count == living.count + model.vacancies.count + 4)
        #expect(Set(items.map(\.id)).count == items.count)

        // The rooms: the board room speaks the open asks; the others are read by title.
        let board = try #require(items.first { $0.id == "room:board" })
        #expect(board.label == "Board room, owner, 3 open asks")
        #expect(board.hit == .owner)
        #expect(board.frame == scene.roomRect("room:board"))
        for (id, label) in [("room:review", "Review room"), ("room:break", "Break room"), ("room:mail", "Mail room")] {
            let room = try #require(items.first { $0.id == id }, "\(id)")
            #expect(room.label == label)
            #expect(room.frame == scene.roomRect(id))
            #expect(room.hit == nil, "a room the mouse cannot click is not a button")
        }

        // One per desk, in tree order, framed on the desk, pressing what a click on it hits.
        let desks = items.filter { scene.layout.desks[$0.id] != nil }
        #expect(desks.map(\.id) == model.tree.order.filter { scene.layout.desks[$0] != nil })
        for agent in living {
            let item = try #require(desks.first { $0.id == agent.id }, "\(agent.id)")
            let card = try #require(model.hoverCard(agentId: agent.id))
            #expect(item.label == Self.deskLabel(card))
            #expect(item.hit == .agent(agent.id))
            let frame = try #require(scene.deskRect(agent.id))
            #expect(item.frame == frame)
            #expect(scene.hit(at: CGPoint(x: frame.midX, y: frame.midY)) != nil)
        }
        #expect(living.contains { model.agents[$0.id]?.item != nil }, "some desk should speak its item")
        for seat in model.vacancies {
            let item = try #require(desks.first { $0.id == "vacancy:" + seat.id })
            #expect(item.label == "Open seat, \(seat.roleTitle)")
            #expect(item.hit == .vacancy(seat.id))
        }
    }

    @Test func labelsAreCleanText() throws {
        let made = SyntheticCompany.make(agents: 12)
        let running = made.agents.filter { $0.state == .running }
        let id = try #require(running.first?.id)
        let other = try #require(running.dropFirst().first?.id)
        let zalgo = "z" + String(repeating: "\u{0301}\u{0489}", count: 2_500) + "\u{202E}x"
        let role = "\u{202E}" + String(repeating: "r", count: 10_000)
        let model = OfficeSceneTests.model(agents: 12, edit: { agents in
            if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].name = zalgo; agents[i].role = role }
        }, inputs: {
            $0.currentItems[id] = nil
            $0.currentItems[other] = "BRH-1\u{202E}gpj.exe Fix the \u{2066}login\u{2069} flow"
        })
        let agent = try #require(model.agents[id])
        let card = try #require(model.hoverCard(agentId: id))
        let scene = OfficeSceneTests.scene(model)
        let items = scene.accessibilityItems(limit: MapSKView.accessibilityLimit)

        let label = try #require(items.first { $0.id == id }?.label)
        #expect(label == "\(agent.handle), \(agent.role), \(card.stateLabel)")
        #expect(label.count <= 160)
        let itemLabel = try #require(items.first { $0.id == other }?.label)
        let item = try #require(model.agents[other]?.item)
        #expect(itemLabel.hasSuffix(", " + item))
        for text in items.map(\.label) {
            #expect(!text.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) },
                    "\(text.prefix(40))")
        }
    }

    @Test func cappedAt300() {
        let model = OfficeSceneTests.model(agents: 500)
        let scene = OfficeSceneTests.scene(model)
        #expect(scene.lod == .deskOnly)
        #expect(scene.accessibilityItems(limit: MapSKView.accessibilityLimit).count == 300)
        // The rooms come first, so the cap never drops them.
        let first = scene.accessibilityItems(limit: 4).map(\.id)
        #expect(first == ["room:board", "room:review", "room:break", "room:mail"])
        #expect(scene.accessibilityItems(limit: 0).isEmpty)
    }

    @Test func openAsksAgreeInNumber() {
        for (asks, spoken) in [(0, "0 open asks"), (1, "1 open ask"), (3, "3 open asks")] {
            let scene = OfficeSceneTests.scene(OfficeSceneTests.model(agents: 12, inputs: { $0.openAsks = asks }))
            let board = scene.accessibilityItems(limit: 1).first
            #expect(board?.id == "room:board")
            #expect(board?.label == "Board room, owner, " + spoken)
        }
    }

    // MARK: - The view

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func orgSceneExposesNoElements() {
        let c = OrgSceneTests.controller(40)
        let scene = OrgSceneTests.scene(c.model, collapsed: c.collapsed)
        #expect((scene as SKScene) as? MapAccessible == nil, "the org chart joins only with an approved inventory update")
        let view = Self.view(showing: scene)
        #expect((view.accessibilityChildren() ?? []).isEmpty)
        Self.expectPlainSKViewElement(view)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func viewExposesChildrenAndPress() throws {
        let model = OfficeSceneTests.model(agents: 12)
        let (view, scene) = Self.officeView(model)
        Self.expectPlainSKViewElement(view)
        let items = scene.accessibilityItems(limit: MapSKView.accessibilityLimit)
        let elements = Self.elements(view)
        #expect(elements.count == items.count)
        #expect(elements.map { $0.accessibilityLabel() ?? "" } == items.map(\.label))
        #expect(elements.map { $0.accessibilityRole() } == items.map { $0.hit == nil ? .staticText : .button })
        for element in elements { #expect(element.accessibilityParent() as? MapSKView === view) }

        // A press is a click on the desk's centre.
        var clicks: [(MapHit, CGPoint)] = []
        view.onClick = { clicks.append(($0, $1)) }
        let index = try #require(items.firstIndex { scene.layout.desks[$0.id] != nil && !$0.id.hasPrefix("vacancy:") })
        let desk = items[index]
        #expect(elements[index].accessibilityPerformPress())
        #expect(clicks.count == 1)
        #expect(clicks.first?.0 == .agent(desk.id))
        #expect(clicks.first?.1 == CGPoint(x: desk.frame.midX, y: desk.frame.midY))
        // A room with no click does nothing.
        let mail = try #require(items.firstIndex { $0.id == "room:mail" })
        #expect(elements[mail].accessibilityPerformPress() == false)
        #expect(clicks.count == 1)

        // The frame is the desk as the camera shows it now, on screen.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil }
        func expected() -> CGRect {
            let a = scene.convertPoint(toView: CGPoint(x: desk.frame.minX, y: desk.frame.minY))
            let b = scene.convertPoint(toView: CGPoint(x: desk.frame.maxX, y: desk.frame.maxY))
            let local = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            return window.convertToScreen(view.convert(local, to: nil))
        }
        func near(_ r: CGRect, _ s: CGRect) -> Bool {
            abs(r.minX - s.minX) < 0.5 && abs(r.minY - s.minY) < 0.5 && abs(r.width - s.width) < 0.5 && abs(r.height - s.height) < 0.5
        }
        let before = elements[index].accessibilityFrame()
        #expect(near(before, expected()), "\(before) vs \(expected())")
        scene.zoom = 2
        let after = elements[index].accessibilityFrame()
        #expect(near(after, expected()), "\(after) vs \(expected())")
        #expect(abs(after.width - 2 * before.width) < 1, "the frame follows the zoom")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func childrenRebuildOnChangeAtMostOncePerInterval() throws {
        var now: TimeInterval = 100
        let model = OfficeSceneTests.model(agents: 12)
        let (view, scene) = Self.officeView(model)
        view.accessibilityClock = { now }
        let first = Self.elements(view)
        let revision = scene.accessibilityRevision

        // Nothing changed: the same elements, even much later.
        scene.rebuild(model: model)
        #expect(scene.accessibilityRevision == revision)
        now += 10
        #expect(Self.elements(view).map(ObjectIdentifier.init) == first.map(ObjectIdentifier.init))

        // A state change (no structure change): the label is updated in place, on the same element.
        let made = SyntheticCompany.make(agents: 12)
        let running = made.agents.filter { $0.state == .running }.map(\.id)
        let (blocked, leaver, second) = (running[0], running[1], running[2])
        let stuck = OfficeSceneTests.model(agents: 12, edit: { agents in
            if let i = agents.firstIndex(where: { $0.id == blocked }) { agents[i].state = .blocked }
        })
        scene.rebuild(model: stuck)
        #expect(scene.accessibilityRevision != revision)
        let updated = Self.elements(view)
        #expect(updated.map(ObjectIdentifier.init) == first.map(ObjectIdentifier.init))
        let card = try #require(stuck.hoverCard(agentId: blocked))
        #expect(card.stateLabel == "blocked")
        #expect(updated.contains { $0.accessibilityLabel() == Self.deskLabel(card) })

        // An agent leaves within the interval: the children wait it out, then drop its desk and keep the others.
        now += MapSKView.accessibilityInterval / 2
        let fewer = OfficeSceneTests.model(agents: 12, edit: { agents in
            agents.removeAll { $0.id == leaver }
            if let i = agents.firstIndex(where: { $0.id == blocked }) { agents[i].state = .blocked }
        })
        scene.rebuild(model: fewer)
        #expect(Self.elements(view).count == first.count)
        now += MapSKView.accessibilityInterval / 2
        let rebuilt = Self.elements(view)
        #expect(rebuilt.count == first.count - 1)
        let gone = try #require(model.agents[leaver]?.handle)
        #expect(!rebuilt.contains { $0.accessibilityLabel()?.hasPrefix(gone + ",") == true })
        let kept = Set(rebuilt.map(ObjectIdentifier.init))
        #expect(first.filter { kept.contains(ObjectIdentifier($0)) }.count == rebuilt.count, "VoiceOver keeps its place")

        // A second departure right after: at most one rebuild per interval.
        let fewest = OfficeSceneTests.model(agents: 12, edit: { agents in
            agents.removeAll { $0.id == leaver || $0.id == second }
            if let i = agents.firstIndex(where: { $0.id == blocked }) { agents[i].state = .blocked }
        })
        scene.rebuild(model: fewest)
        now += MapSKView.accessibilityInterval * 0.9
        #expect(Self.elements(view).count == first.count - 1)
        now += MapSKView.accessibilityInterval * 0.1
        let latest = Self.elements(view)
        #expect(latest.count == first.count - 2)

        // Another scene (the mode switch): its own elements at once, none carried over.
        let next = OfficeSceneTests.scene(model)
        view.presentScene(next)
        let fresh = Self.elements(view)
        #expect(fresh.count == first.count)
        #expect(Set(fresh.map(ObjectIdentifier.init)).isDisjoint(with: latest.map(ObjectIdentifier.init)))
    }

    // MARK: - Reduce Motion

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func reduceMotionPropagates() throws {
        let office = OfficeScene(size: Self.size)
        let view = Self.view(showing: office)
        view.reduceMotionOverride = true
        #expect((office as MapMotionReducible).reduceMotion == true)
        view.reduceMotionOverride = false
        #expect(office.reduceMotion == false)

        // A scene presented later starts at the view's setting.
        view.reduceMotionOverride = true
        let running = SyntheticCompany.make(agents: 12).agents[1].id
        let people = MapPeople(trust: [running: MapTrust(label: "T2", title: "Trusted", tier: 2)])
        let model = OrgSceneTests.model(agents: 12, people: people) { agents in
            agents[1].state = .running; agents[1].paused = false
        }
        let org = OrgSceneTests.scene(model)
        let card = try #require(org.cardNode(running))
        #expect(card.statusBar.action(forKey: OrgCardNode.pulseKey) != nil, "a running bar pulses by default")
        view.presentScene(org)
        #expect((org as MapMotionReducible).reduceMotion == true)
        #expect(card.statusBar.action(forKey: OrgCardNode.pulseKey) == nil, "no pulse under Reduce Motion")
        #expect(card.statusBar.alpha == 1)
        let chip = try #require(card.details.childNode(withName: "trustChipGroup"))
        card.popTrustChip()
        #expect(chip.action(forKey: OrgCardNode.chipPopKey) == nil && chip.xScale == 1, "no chip pop under Reduce Motion")

        // A rebuilt card stays still; turning it off brings the pulse back.
        org.rebuild(model: model, collapsed: [])
        #expect(org.cardNode(running)?.statusBar.action(forKey: OrgCardNode.pulseKey) == nil)
        view.reduceMotionOverride = false
        #expect(org.reduceMotion == false)
        #expect(org.cardNode(running)?.statusBar.action(forKey: OrgCardNode.pulseKey) != nil)
    }
}
