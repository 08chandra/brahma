import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

/// 64-bit FNV-1a over the UTF-8 bytes: the seed of an agent's stroll intervals.
private func fnv1a(_ s: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in s.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

// MARK: - State

/// Everything `OfficeScene` keeps for its motion (spec §5.4–5.7): where each figure rests and where it is heading, the
/// walks under way, idle strolls, notes and folders from the shared particle pool (`MotionState.poolSize`), the leave,
/// hire, promotion, flash and stamp effects, and the highlight ring. A class, because Swift extensions cannot add stored
/// properties. Everything here runs on map time, so a frame at a given `now` is reproducible.
@MainActor
final class OfficeMotionState {
    /// Where a figure belongs at rest and how it looks there (set by the rebuild).
    struct Rest: Equatable {
        var spot: CGPoint
        var pose: OfficeTextures.FigurePose
        var bubble: OfficeTextures.BubbleGlyph?
        /// Hands alternate (full LOD, no Reduce Motion).
        var typing: Bool
        /// Idle at the desk: may stroll.
        var idle: Bool
    }

    /// A walk from `from` to `to` along `route`, started at `start`; it takes `OfficeScene.walkDuration`.
    struct Walk {
        var from: CGPoint
        var to: CGPoint
        var start: TimeInterval
        var route: MotionRoute
    }

    /// What a figure shows now; applied to its node only when it changes.
    struct Look: Equatable {
        var pose: OfficeTextures.FigurePose
        var bubble: OfficeTextures.BubbleGlyph?
        var typing: Bool
    }

    /// An idle figure away at the break room's sofa until `until` (then it walks back).
    struct Stroll {
        var until: TimeInterval
        var spot: CGPoint
        var seat: Int
    }

    struct RouteKey: Hashable {
        var ax: Double, ay: Double, bx: Double, by: Double
    }

    /// The sender's hand gesture on a message.
    static let gesture = 0.2
    /// How long a stroller sits on the sofa before walking back.
    static let strollStay = 4.0
    /// Walking frames per second.
    static let stepHz = 6.0
    /// The balloon of a hire drifts up this far while it fades.
    static let balloonRise: CGFloat = 24
    static let balloonDuration = 2.0
    /// A passed check's `✓` stays on its parcel this long, then the parcel leaves.
    static let stampDuration = 1.0
    /// A Reduce Motion event flash.
    static let flashDuration = 0.2
    /// A promotion's trophy pops (scale 0 → 1.2 → 1) over this, as the org chart's trust chip; it stays, then fades out
    /// by `trophyDuration`.
    static let trophyPop = 1.2
    static let trophyDuration = 2.4

    let particleLayer = SKNode()
    var controllerId: ObjectIdentifier?
    var lastRebuild = -Double.infinity
    var needsRebuild = false

    // Figures.
    var rests: [String: Rest] = [:]
    /// Where each figure is heading (or stands), in scene coordinates.
    var targets: [String: CGPoint] = [:]
    var walks: [String: Walk] = [:]
    var looks: [String: Look] = [:]
    /// The sender's gesture ends at this map time.
    var gestures: [String: TimeInterval] = [:]
    /// The next stroll of an idle figure (map time).
    var strolls: [String: TimeInterval] = [:]
    var strolling: [String: Stroll] = [:]
    var strollRNG: [String: SplitMix64] = [:]
    /// Review-room chair and board-door spot indices, kept while an agent stays there.
    var reviewSeats: [String: Int] = [:]
    var doorSpots: [String: Int] = [:]

    // Particles.
    var free: [MotionParticle] = []
    var used: [Int: MotionParticle] = [:]
    var created = 0
    /// The flight fraction at which a retargeted particle's route begins.
    var routeStart: [Int: CGFloat] = [:]

    // Corridor routes, per layout.
    var graph: OfficeLayout.RouteGraph?
    var routes: [RouteKey: MotionRoute] = [:]

    // Event visuals.
    var leaving: [String: (start: TimeInterval, duration: TimeInterval)] = [:]
    var waiting: [VisualEvent] = []
    var balloons: [String: (node: SKSpriteNode, base: CGPoint, start: TimeInterval)] = [:]
    var trophies: [String: (node: SKSpriteNode, start: TimeInterval)] = [:]
    var flashes: [String: TimeInterval] = [:]
    /// Parcels being stamped `✓` (a passed check), since this map time.
    var stamps: [String: TimeInterval] = [:]
    /// Agents whose passed parcel has left the mail room (until their phase changes).
    var departed: Set<String> = []

    // Highlight ring.
    let ring = SKNode()
    var ringBars: [SKSpriteNode] = []
    var ringRect: CGRect?

    /// The layout changed: its routes are stale.
    func layoutChanged() {
        graph = nil
        routes = [:]
    }

    /// The figure left the floor (away, gone, desk-only LOD).
    func forgetFigure(_ id: String) {
        rests[id] = nil
        targets[id] = nil
        walks[id] = nil
        looks[id] = nil
        gestures[id] = nil
        strolls[id] = nil
        strolling[id] = nil
    }
}

// MARK: - Driving

extension OfficeScene {
    /// One frame of the office driven by `controller` at map time `now`, with the events `controller.frame(now:)` returned
    /// (the view calls this from `SKScene.update(_:)`):
    ///
    /// 1. leave events start the desk-cleared animation, and while one plays the layout is held;
    /// 2. the floor is rebuilt when the structure changed, on a content event (`stateChange`, `phaseChange`, `promotion`),
    ///    when a leave ended, and every `refreshInterval` for states and item facets;
    /// 3. new events spawn their visuals (spec §5.4);
    /// 4. figures, notes, effects, the highlight ring and the camera advance to `now`.
    public func update(controller: MapController, events: [VisualEvent], now: TimeInterval) {
        let m = motion
        if m.controllerId != ObjectIdentifier(controller) { resetMotion(for: controller) }
        let model = controller.model
        let replaying = controller.isReplaying

        beginLeaves(events, model: model, now: now)
        advanceLeaves(now: now)
        // A content event's desk still shows the old content: refresh first, then play the effect on it.
        let contentEvent = events.contains(where: Self.isContentEvent) || m.waiting.contains(where: Self.isContentEvent)
        let due = m.needsRebuild || contentRevision != model.structureRevision || contentEvent
            || now - m.lastRebuild >= Self.refreshInterval || now < m.lastRebuild
        if due {
            m.needsRebuild = false
            rebuild(model: model, replaying: replaying)
            m.lastRebuild = now
        }

        let aggregate = model.stats.aggregate
        spawn(events, now: now, aggregate: aggregate, replaying: replaying)
        advanceFigures(now: now)
        advanceParticles(now: now, aggregate: aggregate)
        advanceEffects(now: now)
        updateHighlight(controller: controller)
        cameraDriver.update(controller: controller, now: now, targetRect: { self.figureOrDeskRect($0) },
                            contentBounds: contentBounds)
        cameraDriver.syncZoom(controller: controller)
        cameraMovedIfNeeded()
    }

    private static func isContentEvent(_ e: VisualEvent) -> Bool {
        switch e.kind {
        case .stateChange, .promotion, .phaseChange: true
        default: false
        }
    }

    /// Drops the previous controller's walks, notes and effects (figures snap to where they were heading) and rebuilds
    /// on the next frame.
    func resetMotion(for controller: MapController?) {
        let m = motion
        m.controllerId = controller.map(ObjectIdentifier.init)
        for id in m.leaving.keys {
            figures[id]?.alpha = 1
            desks[id]?.invalidate()
        }
        m.leaving = [:]
        m.waiting = []
        for p in Array(m.used.values) { release(p) }
        for (_, b) in m.balloons { b.node.removeFromParent() }
        m.balloons = [:]
        for (_, t) in m.trophies { t.node.removeFromParent() }
        m.trophies = [:]
        for id in m.flashes.keys { desks[id]?.setFlash(nil) }
        m.flashes = [:]
        m.stamps = [:]
        m.departed = []
        for (id, node) in figures {
            if let target = m.targets[id] { node.position = target }
        }
        m.walks = [:]
        m.strolls = [:]
        m.strolling = [:]
        m.gestures = [:]
        m.looks = [:]
        m.ringRect = nil
        m.ring.isHidden = true
        cameraDriver.reset()
        m.lastRebuild = -.infinity
        m.needsRebuild = true
        forceRebuild()
    }

    // MARK: Leaves

    /// A killed agent's desk plays its leave (1.5 s; 0.2 s under Reduce Motion, a cross-fade) and the layout is held
    /// until it ends.
    private func beginLeaves(_ events: [VisualEvent], model: MapModel, now: TimeInterval) {
        for e in events where e.kind == .leave {
            guard case .agent(let id) = e.from, model.agents[id]?.state == .killed, desks[id] != nil,
                  motion.leaving[id] == nil else { continue }
            motion.leaving[id] = (now, reduceMotion ? Swift.min(e.duration, OfficeMotionState.flashDuration) : e.duration)
        }
    }

    /// The figure fades, the desk items slide into a box and the lamp goes out; at the end the layout closes the gap.
    private func advanceLeaves(now: TimeInterval) {
        for (id, leave) in motion.leaving {
            let t = leave.duration > 0 ? (now - leave.start) / leave.duration : 1
            if t >= 1 || now < leave.start || desks[id] == nil {
                motion.leaving[id] = nil
                figures[id]?.alpha = 1
                desks[id]?.invalidate()
                motion.needsRebuild = true
            } else {
                let f = CGFloat(Swift.max(0, t))
                figures[id]?.alpha = 1 - f
                desks[id]?.setLeaving(f)
            }
        }
    }

    // MARK: Spawning

    private func spawn(_ events: [VisualEvent], now: TimeInterval, aggregate: Bool, replaying: Bool) {
        let m = motion
        for e in events {
            switch e.kind {
            case .message, .handoff, .broadcast:
                let from = OrgScene.nodeId(e.from)
                // Reduce Motion: no travelling notes; the sender's desk flashes instead.
                if reduceMotion {
                    if desks[from] != nil { m.flashes[from] = now }
                    continue
                }
                spawnParticle(e, aggregate: aggregate)
                if e.kind == .message, !aggregate, lod != .deskOnly, figures[from] != nil {
                    m.gestures[from] = now + OfficeMotionState.gesture
                }
            case .phaseChange(_, let to):
                // Item phases are not replayed (spec §5.7), and a former agent ships nothing (Task 2 M1).
                guard !replaying, case .agent(let id) = e.from, let agent = shownAgents[id], agent.activity != .gone else { continue }
                m.departed.remove(id)
                m.stamps[id] = to == .passed ? now : nil
                updateParcels()
            case .meetingStart:
                if !replaying { rooms["room:review"]?.setMeeting(e.label) }
            case .meetingEnd:
                rooms["room:review"]?.setMeeting(nil)
            case .stateChange, .hire, .promotion:
                m.waiting.append(e)
            // A leave is `beginLeaves`; a reorg is the layout moving the desks (they glide) and the figures (they walk).
            case .leave, .reorg:
                break
            }
        }
        if m.waiting.count > 256 { m.waiting.removeFirst(m.waiting.count - 256) }
        // Desk effects play on the desk as it is now; one whose desk is not there yet (or is playing a leave) waits a
        // little.
        m.waiting.removeAll { e in
            guard case .agent(let id) = e.from else { return true }
            if let desk = desks[id], m.leaving[id] == nil {
                playDeskEffect(e, id: id, desk: desk, now: now)
                return true
            }
            return now > e.start + e.duration + 0.5
        }
    }

    private func playDeskEffect(_ e: VisualEvent, id: String, desk: OfficeDeskNode, now: TimeInterval) {
        switch e.kind {
        case .stateChange: desk.crossFadeScreen(duration: e.duration)
        case .hire: playHire(id, desk: desk, now: now)
        case .promotion: playPromotion(id, desk: desk, now: now)
        default: break
        }
    }

    /// The new desk slides in from its pod's aisle in `moveDuration` and a balloon on a string drifts up and fades over
    /// 2 s (spec §5.4); under Reduce Motion the desk only fades in.
    private func playHire(_ id: String, desk: OfficeDeskNode, now: TimeInterval) {
        guard let rect = layout.desks[id]?.rect else { return }
        let target = Self.center(rect)
        desk.removeAction(forKey: "hireFade")
        desk.alpha = 0
        if reduceMotion {
            desk.run(.fadeIn(withDuration: OfficeMotionState.flashDuration), withKey: "hireFade")
            return
        }
        desk.run(.fadeIn(withDuration: Self.moveDuration), withKey: "hireFade")
        if let pod = layout.desks[id]?.podId.flatMap({ layout.pods[$0] }) {
            let aisle = pod.rect.x + OfficeLayout.pod.padding + OfficeLayout.desk.w + OfficeLayout.pod.aisle / 2
            desk.removeAction(forKey: "move")
            desk.position = CGPoint(x: aisle, y: target.y)
            let slide = SKAction.move(to: target, duration: Self.moveDuration)
            slide.timingMode = .easeOut
            desk.run(slide, withKey: "move")
        }
        motion.balloons[id]?.node.removeFromParent()
        let size = OfficeTextures.points(OfficeTextures.balloon)
        let balloon = SKSpriteNode(texture: OfficeTextures.balloon, size: size)
        balloon.anchorPoint = CGPoint(x: 0.5, y: 0)
        let base = CGPoint(x: OfficeLayout.desk.w / 2 - 3, y: OfficeDeskNode.size.height / 2)
        balloon.position = base
        balloon.zPosition = OfficeZ.overlay
        balloon.name = "balloon"
        desk.addChild(balloon)
        motion.balloons[id] = (balloon, base, now)
    }

    /// A trophy pops on the desk's corner: scale 0 → 1.2 → 1 over the event's 1.2 s (the org chip pop), then it fades.
    private func playPromotion(_ id: String, desk: OfficeDeskNode, now: TimeInterval) {
        motion.trophies[id]?.node.removeFromParent()
        let texture = LabelTextures.shared.emoji("🏆", size: 10)
        let natural = OrgCardNode.points(texture)
        let scale = natural.height > 0 ? OfficeDeskNode.perkHeight / natural.height : 1
        let trophy = SKSpriteNode(texture: texture, size: CGSize(width: natural.width * scale, height: OfficeDeskNode.perkHeight))
        trophy.position = desk.cornerPoint
        trophy.zPosition = OfficeZ.labels + 1
        trophy.setScale(reduceMotion ? 1 : 0)
        trophy.name = "trophy"
        desk.addChild(trophy)
        motion.trophies[id] = (trophy, now)
    }

    // MARK: Particles

    /// A note (or folder, or broadcast note / ring) from the shared pool; nothing when the pool is exhausted or the sender
    /// has no place on the floor.
    private func spawnParticle(_ e: VisualEvent, aggregate: Bool) {
        let m = motion
        guard m.used[e.id] == nil else { return }
        let from = OrgScene.nodeId(e.from)
        let to = e.to.map(OrgScene.nodeId)
        guard let start = endLocation(from) else { return }
        let deskOnly = lod == .deskOnly
        let route: MotionRoute
        let kind: MotionParticle.Kind
        switch e.kind {
        case .message:
            guard let to, let end = endLocation(to) else { return }
            route = corridorRoute(start, end)
            // Aggregate mode and desk-only LOD: the org chart's dots.
            kind = aggregate || deskOnly ? .dot : .note
        case .handoff:
            let end = to.flatMap(endLocation) ?? Self.point(layout.mailCounter(0))
            route = corridorRoute(start, end)
            kind = deskOnly ? .square : .folder
        default:
            // A broadcast: a note pinned on the sender's pod board, or a ring at an executive's (or the board room's)
            // door.
            if let board = layout.desks[from]?.podId.flatMap({ layout.pods[$0]?.board }) {
                route = MotionRoute(layoutPoints: [board])!
                kind = deskOnly ? .ring : .note
            } else if let door = doorPoint(from) {
                route = MotionRoute(layoutPoints: [door])!
                kind = .ring
            } else {
                return
            }
        }
        let particle: MotionParticle
        if let reused = m.free.popLast() {
            particle = reused
        } else if m.created < MotionState.poolSize {
            particle = MotionParticle()
            m.created += 1
            m.particleLayer.addChild(particle.sprite)
        } else {
            return
        }
        particle.configure(event: e, from: from, to: to, route: route, version: 0, kind: kind)
        m.used[e.id] = particle
        m.routeStart[e.id] = 0
    }

    private func release(_ p: MotionParticle) {
        p.sprite.isHidden = true
        p.label?.isHidden = true
        motion.used[p.event.id] = nil
        motion.routeStart[p.event.id] = nil
        motion.free.append(p)
    }

    /// Where a note to or from `id` starts or ends: the owner at the board room's door, a living agent at its seat; nil
    /// for an agent who is gone or has no desk.
    func endLocation(_ id: String) -> CGPoint? {
        if id == "owner" { return layout.location(.owner).map(Self.point) }
        guard let agent = builtModel?.agents[id], agent.state != .killed else { return nil }
        return layout.location(.agent(id)).map(Self.point)
    }

    /// The door of the sender's office (or the board room's, for the owner), in layout coordinates.
    private func doorPoint(_ id: String) -> MapPoint2? {
        if id == "owner" { return layout.rooms["room:board"]?.door }
        return layout.desks[id]?.roomId.flatMap { layout.rooms[$0]?.door }
    }

    /// Notes travel, folders travel (to the recipient, or the mail room), broadcast notes fade where they are pinned and
    /// rings expand. A flight whose end moved more than 1 pt, or whose recipient is gone, turns on the spot towards the
    /// new place (the sender's seat for a gone recipient) and lands on time. In aggregate mode notes in flight become dots.
    private func advanceParticles(now: TimeInterval, aggregate: Bool) {
        let m = motion
        guard !m.used.isEmpty else { return }
        let mail = Self.point(layout.mailCounter(0))
        var expired: [MotionParticle] = []
        for p in m.used.values {
            let e = p.event
            let t = e.duration > 0 ? (now - e.start) / e.duration : 1
            if t >= 1 { expired.append(p); continue }
            let f = CGFloat(Swift.max(0, t))
            // Aggregate mode: notes (travelling or pinned) become the org chart's dots.
            if aggregate, p.kind == .note { p.setKind(.dot) }
            switch e.kind {
            case .message, .handoff:
                let wanted = e.kind == .handoff && p.to == nil ? mail : p.to.flatMap(endLocation)
                guard let end = wanted ?? endLocation(p.from), let route = p.route else {
                    expired.append(p)
                    continue
                }
                if hypot(end.x - route.end.x, end.y - route.end.y) > 1 {
                    p.route = corridorRoute(p.sprite.position, end)
                    m.routeStart[e.id] = f
                }
                let f0 = m.routeStart[e.id] ?? 0
                let g = f0 < 1 ? (f - f0) / (1 - f0) : 1
                p.sprite.position = p.route?.point(at: g) ?? end
                p.sprite.alpha = Swift.min(1, f / 0.1, (1 - f) / 0.1)
            default:
                guard let route = p.route else { expired.append(p); continue }
                p.sprite.position = route.start
                if p.kind == .ring {
                    let side = 16 + 32 * f
                    p.sprite.size = CGSize(width: side, height: side)
                    p.sprite.alpha = 0.9 * (1 - f)
                } else {
                    p.sprite.alpha = 1 - f
                }
            }
            p.sprite.isHidden = false
        }
        for p in expired { release(p) }
    }

    // MARK: Routes

    /// The corridor route between two scene points (`OfficeLayout.route`), cached per layout with the layout's corridor
    /// graph.
    func corridorRoute(_ a: CGPoint, _ b: CGPoint) -> MotionRoute {
        let m = motion
        let key = OfficeMotionState.RouteKey(ax: a.x, ay: a.y, bx: b.x, by: b.y)
        if let hit = m.routes[key] { return hit }
        if m.graph == nil { m.graph = layout.routeGraph() }
        if m.routes.count > 4096 { m.routes = [:] }
        let points = layout.route(from: MapPoint2(x: a.x, y: -a.y), to: MapPoint2(x: b.x, y: -b.y), graph: m.graph)
        let route = MotionRoute(layoutPoints: points) ?? MotionRoute(layoutPoints: [MapPoint2(x: b.x, y: -b.y)])!
        m.routes[key] = route
        return route
    }

    /// A walk's path: straight within one pod or room (a seat to the next), else along the corridors.
    private func walkRoute(_ a: CGPoint, _ b: CGPoint) -> MotionRoute {
        let pa = MapPoint2(x: a.x, y: -a.y), pb = MapPoint2(x: b.x, y: -b.y)
        func inside(_ r: MapRect, _ p: MapPoint2) -> Bool { p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h }
        let areas = layout.pods.values.map(\.rect) + layout.rooms.values.map(\.rect)
        if areas.contains(where: { inside($0, pa) && inside($0, pb) }) {
            return MotionRoute(layoutPoints: [pa, pb])!
        }
        return corridorRoute(a, b)
    }

    // MARK: Figures

    /// Moves every figure towards where it belongs. At full LOD (no Reduce Motion, driven) a figure whose destination
    /// moved more than 1 pt walks there in `walkDuration` (ease in-out) from wherever it is, retargeting on the next frame
    /// when the destination changes again; otherwise (static LOD, Reduce Motion, an undriven rebuild: `now` nil) it is
    /// put there. Idle figures stroll to the sofa and back at full LOD only. Figures sort by depth.
    func advanceFigures(now: TimeInterval?) {
        let m = motion
        let animate = now != nil && lod == .full && !reduceMotion
        if animate, let now {
            scheduleStrolls(now: now)
        } else if !m.strolling.isEmpty || !m.strolls.isEmpty {
            m.strolling = [:]
            m.strolls = [:]
        }
        for (id, node) in figures {
            guard let rest = m.rests[id] else { continue }
            let stroll = m.strolling[id]
            let dest = stroll?.spot ?? rest.spot
            if let target = m.targets[id], hypot(target.x - dest.x, target.y - dest.y) <= 1 {
                // Still heading there.
            } else if m.leaving[id] == nil {
                m.targets[id] = dest
                if animate, let now {
                    m.walks[id] = OfficeMotionState.Walk(from: node.position, to: dest, start: now,
                                                         route: walkRoute(node.position, dest))
                } else {
                    m.walks[id] = nil
                    node.position = dest
                }
            }
            var look: OfficeMotionState.Look?
            if let walk = m.walks[id] {
                if !animate {
                    m.walks[id] = nil
                    node.position = walk.to
                } else if let now {
                    let t = Swift.max(0, (now - walk.start) / Self.walkDuration)
                    if t >= 1 {
                        m.walks[id] = nil
                        node.position = walk.to
                    } else {
                        let eased = CGFloat(t * t * (3 - 2 * t))
                        node.position = walk.route.point(at: eased)
                        let step = Int((now - walk.start) * OfficeMotionState.stepHz) % 2
                        look = .init(pose: step == 0 ? .walkA : .walkB, bubble: nil, typing: false)
                    }
                }
            }
            if look == nil {
                if let stroll {
                    look = .init(pose: stroll.seat < 3 ? .sit : .stand, bubble: nil, typing: false)
                } else if let now, let until = m.gestures[id], until > now, !rest.typing {
                    look = .init(pose: .typeA, bubble: rest.bubble, typing: false)
                } else {
                    if let now, let until = m.gestures[id], until <= now { m.gestures[id] = nil }
                    look = .init(pose: rest.pose, bubble: rest.bubble, typing: rest.typing)
                }
            }
            if let look, m.looks[id] != look {
                m.looks[id] = look
                node.pose = look.pose
                node.setTyping(look.typing)
                node.setBubble(look.bubble)
            }
            node.zPosition = -node.position.y
        }
    }

    /// Idle figures stroll to the break room's sofa every `strollRange` (each agent's intervals drawn from a generator
    /// seeded by the FNV-1a of its id), sit there `strollStay`, and walk back. A figure that stops being idle walks back
    /// at once.
    private func scheduleStrolls(now: TimeInterval) {
        let m = motion
        guard layout.rooms["room:break"] != nil else { return }
        for (id, rest) in m.rests where figures[id] != nil {
            guard rest.idle, m.leaving[id] == nil else {
                m.strolls[id] = nil
                m.strolling[id] = nil
                continue
            }
            if let s = m.strolling[id] {
                if now >= s.until {
                    m.strolling[id] = nil
                    m.strolls[id] = now + nextStrollInterval(id)
                }
            } else if let next = m.strolls[id] {
                if now >= next {
                    let taken = Set(m.strolling.values.map(\.seat))
                    var seat = 0
                    while taken.contains(seat) { seat += 1 }
                    m.strolling[id] = OfficeMotionState.Stroll(until: now + Self.walkDuration + OfficeMotionState.strollStay,
                                                               spot: sofaSpot(seat), seat: seat)
                    m.strolls[id] = nil
                }
            } else {
                m.strolls[id] = now + nextStrollInterval(id)
            }
        }
    }

    private func nextStrollInterval(_ id: String) -> TimeInterval {
        var rng = motion.strollRNG[id] ?? SplitMix64(seed: fnv1a(id))
        let u = Double(rng.next() >> 11) / Double(UInt64(1) << 53)
        motion.strollRNG[id] = rng
        return Self.strollRange.lowerBound + u * (Self.strollRange.upperBound - Self.strollRange.lowerBound)
    }

    /// The `k`th stroller's place: three seats on the sofa, then standing spots across the room.
    func sofaSpot(_ k: Int) -> CGPoint {
        guard let r = roomRect("room:break") else { return .zero }
        let sofa = OfficeRoomNode.sofaCenter(r)
        if k < 3 { return CGPoint(x: sofa.x + CGFloat(k - 1) * 12, y: sofa.y + 2) }
        let j = k - 3
        let step: CGFloat = 14
        let perLine = Swift.max(1, Int((r.width - 48) / step))
        return CGPoint(x: r.minX + 24 + CGFloat(j % perLine) * step, y: r.midY - 16)
    }

    // MARK: Effects

    /// Balloons drift and fade, trophies pop and fade, Reduce Motion flashes run their 0.2 s, and a stamped parcel leaves
    /// after its second.
    private func advanceEffects(now: TimeInterval) {
        let m = motion
        for (id, b) in m.balloons {
            let t = (now - b.start) / OfficeMotionState.balloonDuration
            guard t < 1, t >= 0, let desk = desks[id] else {
                b.node.removeFromParent()
                m.balloons[id] = nil
                continue
            }
            // A reconfigured desk drops its children: hang the balloon on it again.
            if b.node.parent !== desk { b.node.removeFromParent(); desk.addChild(b.node) }
            b.node.position = CGPoint(x: b.base.x, y: b.base.y + OfficeMotionState.balloonRise * CGFloat(t))
            b.node.alpha = CGFloat(1 - t)
        }
        for (id, trophy) in m.trophies {
            let t = now - trophy.start
            guard t < OfficeMotionState.trophyDuration, t >= 0, let desk = desks[id] else {
                trophy.node.removeFromParent()
                m.trophies[id] = nil
                continue
            }
            if trophy.node.parent !== desk { trophy.node.removeFromParent(); desk.addChild(trophy.node) }
            if reduceMotion {
                trophy.node.setScale(1)
                trophy.node.alpha = CGFloat(Swift.min(1, t / OfficeMotionState.flashDuration))
            } else {
                let pop = OfficeMotionState.trophyPop / 2
                let scale = t < pop ? 1.2 * t / pop : t < 2 * pop ? 1.2 - 0.2 * (t - pop) / pop : 1
                trophy.node.setScale(CGFloat(scale))
            }
            let fade = OfficeMotionState.trophyDuration - 0.3
            if t > fade { trophy.node.alpha = CGFloat(Swift.max(0, 1 - (t - fade) / 0.3)) }
        }
        for (id, start) in m.flashes {
            let t = (now - start) / OfficeMotionState.flashDuration
            if t >= 1 || t < 0 || desks[id] == nil {
                desks[id]?.setFlash(nil)
                m.flashes[id] = nil
            } else {
                desks[id]?.setFlash(CGFloat(t))
            }
        }
        var stampsEnded = false
        for (id, start) in m.stamps where now - start >= OfficeMotionState.stampDuration || now < start {
            m.stamps[id] = nil
            m.departed.insert(id)
            stampsEnded = true
        }
        if stampsEnded { updateParcels() }
    }

    // MARK: Highlight

    /// The jump target's desk gets a 2 pt `accent` ring for as long as the controller keeps it highlighted (1.5 s).
    private func updateHighlight(controller: MapController) {
        let m = motion
        guard let id = controller.highlightId, let rect = deskRect(id) else {
            m.ring.isHidden = true
            m.ringRect = nil
            return
        }
        if m.ringBars.isEmpty {
            for _ in 0..<4 {
                let bar = SKSpriteNode(color: MapPalette.color(ThemeHex.accent), size: .zero)
                m.ring.addChild(bar)
                m.ringBars.append(bar)
            }
            highlightLayer.addChild(m.ring)
        }
        // 2 pt at normal zoom, 2 screen pixels when zoomed out.
        let t = Swift.max(2, 2 / CGFloat(zoom))
        let outer = rect.insetBy(dx: -(t + 1), dy: -(t + 1))
        let sizes = [CGSize(width: outer.width, height: t), CGSize(width: outer.width, height: t),
                     CGSize(width: t, height: outer.height - 2 * t), CGSize(width: t, height: outer.height - 2 * t)]
        let points = [CGPoint(x: outer.midX, y: outer.maxY - t / 2), CGPoint(x: outer.midX, y: outer.minY + t / 2),
                      CGPoint(x: outer.minX + t / 2, y: outer.midY), CGPoint(x: outer.maxX - t / 2, y: outer.midY)]
        for (bar, (size, point)) in zip(m.ringBars, zip(sizes, points)) {
            bar.size = size
            bar.position = point
        }
        m.ring.isHidden = false
        m.ringRect = outer
    }

    // MARK: Test and tooling accessors

    func figurePosition(_ id: String) -> CGPoint? { figures[id]?.position }
    /// Where a figure is heading (or stands); nil without a figure.
    func figureTarget(_ id: String) -> CGPoint? { figures[id] == nil ? nil : motion.targets[id] }
    var walkingIds: Set<String> { Set(motion.walks.keys) }
    var particlesInUse: Int { motion.used.count }
    var particleSpriteCount: Int { motion.created }
    func particleSprite(_ eventId: Int) -> SKSpriteNode? { motion.used[eventId]?.sprite }
    func particleKind(_ eventId: Int) -> MotionParticle.Kind? { motion.used[eventId]?.kind }
    var particleKinds: [MotionParticle.Kind] { motion.used.values.map(\.kind) }
    /// Where a particle is heading now: the last point of its route, in scene coordinates.
    func particleTarget(_ eventId: Int) -> CGPoint? { motion.used[eventId]?.route?.end }
    var parcelCount: Int { rooms["room:mail"]?.parcels ?? 0 }
    /// Who has a review-room chair, by chair.
    var reviewOccupants: [String] { motion.reviewSeats.sorted { $0.value < $1.value }.map(\.key) }
    /// Who stands at the board room's door, by spot.
    var doorQueue: [String] { motion.doorSpots.sorted { $0.value < $1.value }.map(\.key) }
    var leavingIds: Set<String> { Set(motion.leaving.keys) }
    var flashingDesks: Set<String> { Set(motion.flashes.keys) }
    var highlightRing: CGRect? { motion.ringRect }
}
