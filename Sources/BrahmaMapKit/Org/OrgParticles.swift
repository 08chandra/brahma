import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

// MARK: - Routes

/// A polyline in scene coordinates with its cumulative lengths, so a particle at fraction `f` of its flight is a lookup.
struct MotionRoute: Equatable {
    private(set) var points: [CGPoint]
    private var cumulative: [CGFloat]

    /// `layoutPoints` are `OrgLayout` coordinates (y down); the scene draws them at `(x, -y)`. Nil for an empty route.
    init?(layoutPoints: [MapPoint2]) {
        guard !layoutPoints.isEmpty else { return nil }
        points = layoutPoints.map { CGPoint(x: $0.x, y: -$0.y) }
        cumulative = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            cumulative.append(cumulative[cumulative.count - 1] + hypot(b.x - a.x, b.y - a.y))
        }
    }

    var start: CGPoint { points[0] }
    var end: CGPoint { points[points.count - 1] }

    func point(at fraction: CGFloat) -> CGPoint {
        let total = cumulative[cumulative.count - 1]
        guard total > 0, points.count > 1 else { return start }
        let d = Swift.min(1, Swift.max(0, fraction)) * total
        var i = 1
        while i < cumulative.count - 1 && cumulative[i] < d { i += 1 }
        let a = points[i - 1], b = points[i]
        let span = cumulative[i] - cumulative[i - 1]
        let f = span > 0 ? (d - cumulative[i - 1]) / span : 0
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

/// What a meeting hull shows (tests read it): the padded rect around the participants' visible cards and the cleaned title.
struct MeetingHull: Equatable {
    var rect: CGRect
    var title: String
}

struct GlowEdge: Equatable {
    var width: CGFloat
    var alpha: CGFloat
}

private struct HullSignature: Equatable {
    var version: Int
    var meetings: [Meeting]
}

// MARK: - Pooled sprites

/// Textures for the particles: a 5 pt dot and a ring, both `accent`.
@MainActor
enum MotionTextures {
    static let dot: SKTexture = render(20) { context, side in
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
    }

    static let ring: SKTexture = render(128) { context, side in
        context.setLineWidth(6)
        context.strokeEllipse(in: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 3, dy: 3))
    }

    private static func render(_ side: Int, _ draw: (CGContext, CGFloat) -> Void) -> SKTexture {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let color = MapPalette.color(ThemeHex.accent).cgColor
        context.setFillColor(color)
        context.setStrokeColor(color)
        draw(context, CGFloat(side))
        let texture = SKTexture(cgImage: context.makeImage()!)
        texture.filteringMode = .linear
        return texture
    }
}

/// One of the 150 pooled sprites: a message dot, a hand-off square or a broadcast ring, with an optional text label child.
@MainActor
final class MotionParticle {
    enum Kind { case dot, square, ring }

    static let dotSize = CGSize(width: 5, height: 5)
    static let squareSize = CGSize(width: 7, height: 7)

    let sprite = SKSpriteNode()
    private(set) var label: SKSpriteNode?
    private(set) var kind = Kind.dot
    var event = VisualEvent(id: 0, kind: .message, from: .owner, start: 0, duration: 1)
    var from = ""
    var to: String?
    var route: MotionRoute?
    var routeVersion = -1

    func configure(event: VisualEvent, from: String, to: String?, route: MotionRoute, version: Int) {
        self.event = event
        self.from = from
        self.to = to
        self.route = route
        routeVersion = version
        switch event.kind {
        case .handoff:
            kind = .square
            sprite.texture = nil
            sprite.color = MapPalette.color(ThemeHex.warning)
            sprite.size = Self.squareSize
        case .broadcast:
            kind = .ring
            sprite.texture = MotionTextures.ring
            sprite.color = .white
            sprite.colorBlendFactor = 0
            sprite.size = CGSize(width: 16, height: 16)
        default:
            kind = .dot
            sprite.texture = MotionTextures.dot
            sprite.color = .white
            sprite.colorBlendFactor = 0
            sprite.size = Self.dotSize
        }
        sprite.alpha = 0
        sprite.position = route.start
        sprite.isHidden = false
        refreshLabel()
    }

    /// The `×n` of a coalesced message, or a hand-off's key; nothing for a lone message and for a ring. Every string goes
    /// through `MapText.clean` (via `fit`) before it becomes a texture.
    func refreshLabel() {
        var text: String?
        switch event.kind {
        case .message where event.count > 1: text = "×\(event.count)"
        case .handoff: text = event.label
        default: break
        }
        guard let text, !text.isEmpty else {
            label?.isHidden = true
            return
        }
        let clean = OrgCardNode.fit(text, width: 72, size: 9, mono: true)
        let texture = LabelTextures.shared.text(clean, size: 9, mono: true, color: ThemeHex.text0)
        let node: SKSpriteNode
        if let label { node = label } else {
            node = SKSpriteNode()
            node.anchorPoint = CGPoint(x: 0, y: 0.5)
            node.position = CGPoint(x: 6, y: 7)
            sprite.addChild(node)
            label = node
        }
        node.texture = texture
        node.size = OrgCardNode.points(texture)
        node.isHidden = false
    }
}

/// A pooled stroke for one comm edge.
@MainActor
final class GlowShape {
    let node = SKShapeNode()
    var key = ""

    init() {
        node.strokeColor = MapPalette.color(ThemeHex.accent)
        node.fillColor = .clear
        node.lineCap = .round
        node.lineJoin = .round
        node.lineWidth = 1
        node.isHidden = true
    }
}

// MARK: - State

/// Everything `OrgScene` keeps for the live visuals. A class, because Swift extensions cannot add stored properties.
@MainActor
final class MotionState {
    /// Particles come from a pool this size.
    static let poolSize = 150
    /// At most this many comm edges are drawn, rebuilt no faster than `edgeInterval`.
    static let edgeLimit = 200
    static let edgeInterval = 0.1
    /// Cards pick up content changes (states, items) at least this often even when the structure did not change.
    static let refreshInterval = 0.25
    static let cameraEase = 0.3

    let particleLayer = SKNode()
    let glowLayer = SKNode()
    let hullLayer = SKNode()
    let highlightLayer = SKNode()
    weak var driver: MapController?
    var timeBase: TimeInterval?
    var controllerId: ObjectIdentifier?
    var lastRebuild = -Double.infinity

    // Particles.
    var free: [MotionParticle] = []
    var used: [Int: MotionParticle] = [:]
    var created = 0
    var routes: [String: MotionRoute] = [:]
    var routesVersion = -1

    // Card animations.
    var waiting: [VisualEvent] = []
    var leaving: [String: (start: TimeInterval, duration: TimeInterval)] = [:]

    // Comm-edge glow.
    var glow: [GlowShape] = []
    var lastGlow = -Double.infinity
    var glowVersion = -1

    // Meeting hulls.
    fileprivate var hullSignature: HullSignature?
    var hulls: [String: MeetingHull] = [:]

    // Highlight ring.
    let ring = SKNode()
    var ringBars: [SKSpriteNode] = []
    var ringRect: CGRect?

    // Camera.
    var camera = CameraState()

    struct CameraState {
        struct Ease {
            var start: TimeInterval
            var from: CGPoint
            var fromScale: CGFloat
            /// A target agent is shown at least this big; nil follows the goal's own zoom (a fit).
            var zoom: Double?
        }

        struct FitKey: Equatable {
            var bounds: CGRect
            var size: CGSize
        }

        var target: CameraTarget?
        var request = false
        var ease: Ease?
        /// Following the chart's bounds: a fit target the owner has not panned or zoomed away from.
        var autoFit = true
        /// The owner is dragging or zooming: a followed card is no longer tracked until the next camera request.
        var suspended = false
        var snapNext = true
        var fitKey: FitKey?
        var lastControllerZoom: Double?
    }
}

// MARK: - Live visuals

extension OrgScene {
    /// The map time a scene driven by `controller` is at: the one place where frames, events and the controller's model meet.
    /// Call once per frame with the events that `controller.frame(now:)` returned (the view does this from
    /// `SKScene.update(_:)`):
    ///
    /// 1. leave events start fading their card, and while one fades the layout is held (the gap closes when it ends);
    /// 2. the cards are rebuilt when the tree, the collapsed set or the former-agents toggle changed (and every 0.25 s for
    ///    state and item changes);
    /// 3. new events spawn their visuals;
    /// 4. particles, comm-edge glow, meeting hulls, the highlight ring and the camera advance to `now`.
    public func update(controller: MapController, events: [VisualEvent], now: TimeInterval) {
        let m = motion
        if m.controllerId != ObjectIdentifier(controller) { resetMotion(for: controller) }
        let model = controller.model
        let collapsed = controller.collapsed

        beginLeaves(events, model: model)
        advanceLeaves(now: now)
        let due = builtRevision != model.structureRevision || builtCollapsed != collapsed
            || now - m.lastRebuild >= MotionState.refreshInterval || now < m.lastRebuild
        if due && m.leaving.isEmpty {
            rebuild(model: model, collapsed: collapsed)
            m.lastRebuild = now
        }

        spawn(events, now: now)
        advanceParticles(model: model, now: now)
        updateGlow(model: model, now: now)
        updateHulls(model: model)
        updateHighlight(controller: controller)
        updateCamera(controller: controller, now: now)
        syncZoom(controller: controller)
    }

    /// Makes `controller` drive this scene from `SKScene.update(_:)` (or stops driving with nil).
    public func present(controller: MapController?) {
        motion.driver = controller
        motion.timeBase = nil
        if let controller { resetMotion(for: controller) }
    }

    /// The whole chart in view again, as with the owner's "fit" request (the controller's `camera` is already `.fit`).
    public func requestCamera() {
        motion.camera.request = true
    }

    /// The owner dragged or zoomed: stop easing, stop tracking a followed card, stop refitting.
    public func userMovedCamera() {
        motion.camera.ease = nil
        motion.camera.autoFit = false
        motion.camera.suspended = true
    }

    private func resetMotion(for controller: MapController) {
        let m = motion
        m.controllerId = ObjectIdentifier(controller)
        for (id, _) in m.leaving { cards[id]?.alpha = 1 }
        m.leaving = [:]
        m.waiting = []
        for p in Array(m.used.values) { release(p) }
        m.routes = [:]
        m.routesVersion = -1
        for shape in m.glow { shape.node.isHidden = true }
        m.lastGlow = -.infinity
        m.hullLayer.removeAllChildren()
        m.hulls = [:]
        m.hullSignature = nil
        m.ringRect = nil
        m.ring.isHidden = true
        m.camera = MotionState.CameraState()
        m.lastRebuild = -.infinity
        forceRebuild()
    }

    // MARK: Test and tooling accessors

    var particlesInUse: Int { motion.used.count }
    var particleSpriteCount: Int { motion.created }
    func particleSprite(_ eventId: Int) -> SKSpriteNode? { motion.used[eventId]?.sprite }
    func particleLabel(_ eventId: Int) -> SKSpriteNode? {
        guard let label = motion.used[eventId]?.label, !label.isHidden else { return nil }
        return label
    }
    /// Where a particle is heading now: the last point of its route, in scene coordinates.
    func particleTarget(_ eventId: Int) -> CGPoint? { motion.used[eventId]?.route?.end }
    var leavingIds: Set<String> { Set(motion.leaving.keys) }
    var meetingHulls: [String: MeetingHull] { motion.hulls }
    var highlightRing: CGRect? { motion.ringRect }
    var glowEdges: [GlowEdge] {
        motion.glow.filter { !$0.node.isHidden }.map { GlowEdge(width: $0.node.lineWidth, alpha: $0.node.alpha) }
    }

    // MARK: Routes

    static func nodeId(_ endpoint: MapEndpoint) -> String {
        switch endpoint {
        case .owner: "owner"
        case .agent(let id): id
        }
    }

    /// The path between two nodes as the layout draws it now; ends inside a collapsed subtree move to the collapsed node.
    /// Cached until the layout changes.
    func motionRoute(_ a: String, _ b: String) -> MotionRoute? {
        let m = motion
        if m.routesVersion != layoutVersion || m.routes.count > 4096 {
            m.routes = [:]
            m.routesVersion = layoutVersion
        }
        let key = a + "\u{0}" + b
        if let hit = m.routes[key] { return hit }
        guard let tree = builtTree, let route = MotionRoute(layoutPoints: layout.route(a, b, tree: tree, collapsed: builtCollapsed)) else {
            return nil
        }
        m.routes[key] = route
        return route
    }

    // MARK: Leaves

    /// A killed agent's card fades over the event's duration and stays until then (the layout is held); with former agents
    /// shown it stays on the chart, so there is nothing to fade out of. Only the agent that actually died: an event whose
    /// end was resolved to a collapsed manager is not this agent's.
    private func beginLeaves(_ events: [VisualEvent], model: MapModel) {
        for e in events where e.kind == .leave {
            guard !model.showFormer, case .agent(let id) = e.from, model.agents[id]?.state == .killed,
                  cards[id] != nil, motion.leaving[id] == nil else { continue }
            motion.leaving[id] = (e.start, e.duration)
        }
    }

    private func advanceLeaves(now: TimeInterval) {
        for (id, fade) in motion.leaving {
            let t = fade.duration > 0 ? (now - fade.start) / fade.duration : 1
            if t >= 1 || cards[id] == nil {
                cards[id]?.alpha = 1
                motion.leaving[id] = nil
            } else {
                cards[id]?.alpha = CGFloat(Swift.max(0, 1 - Swift.max(0, t)))
            }
        }
    }

    // MARK: Spawning

    private func spawn(_ events: [VisualEvent], now: TimeInterval) {
        let m = motion
        for e in events {
            switch e.kind {
            case .message, .handoff, .broadcast: spawnParticle(e)
            case .stateChange, .hire, .promotion: m.waiting.append(e)
            // A leave is `beginLeaves`; a reorg is the layout moving the card (Task 9a); a meeting is drawn from the model.
            case .leave, .reorg, .meetingStart, .meetingEnd: break
            }
        }
        if m.waiting.count > 256 { m.waiting.removeFirst(m.waiting.count - 256) }
        // Card animations play on the card as it is now; one whose card is not there yet (the layout is held, or the next
        // rebuild creates it) waits a little.
        m.waiting.removeAll { e in
            let id = Self.nodeId(e.from)
            if cards[id] != nil { return playCardEffect(e, on: id) }
            return now > e.start + e.duration + 0.5
        }
    }

    private func playCardEffect(_ e: VisualEvent, on id: String) -> Bool {
        guard let node = cards[id] else { return true }
        switch e.kind {
        case .stateChange: node.flashStatusBar()
        case .hire: node.playHire()
        case .promotion: node.popTrustChip()
        default: break
        }
        return true
    }

    private func spawnParticle(_ e: VisualEvent) {
        let m = motion
        guard m.used[e.id] == nil else { return }
        let from = Self.nodeId(e.from)
        let to = e.to.map(Self.nodeId)
        guard let route = motionRoute(from, to ?? from) else { return }
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
        particle.configure(event: e, from: from, to: to, route: route, version: layoutVersion)
        m.used[e.id] = particle
    }

    private func release(_ p: MotionParticle) {
        p.sprite.isHidden = true
        p.label?.isHidden = true
        motion.used[p.event.id] = nil
        motion.free.append(p)
    }

    // MARK: Particles

    private func advanceParticles(model: MapModel, now: TimeInterval) {
        let m = motion
        guard !m.used.isEmpty else { return }
        // A message that coalesces into one in flight raises its count.
        for e in model.active where e.count > 1 {
            if let p = m.used[e.id], p.event.count != e.count {
                p.event.count = e.count
                p.refreshLabel()
            }
        }
        var expired: [MotionParticle] = []
        for p in m.used.values {
            let e = p.event
            let t = e.duration > 0 ? (now - e.start) / e.duration : 1
            if t >= 1 { expired.append(p); continue }
            let f = CGFloat(Swift.max(0, t))
            // After a collapse or any layout change the flight is re-routed: a particle heading into a hidden card
            // heads for the visible ancestor instead.
            if p.routeVersion != layoutVersion {
                p.route = motionRoute(p.from, p.to ?? p.from)
                p.routeVersion = layoutVersion
            }
            guard let route = p.route else {
                p.sprite.isHidden = true
                continue
            }
            p.sprite.isHidden = false
            switch p.kind {
            case .dot, .square:
                p.sprite.position = route.point(at: f)
                p.sprite.alpha = Swift.min(1, f / 0.1, (1 - f) / 0.1)
            case .ring:
                // An expanding ring on the card: 16 pt to 140 pt, fading out.
                let side = 16 + 124 * f
                p.sprite.size = CGSize(width: side, height: side)
                p.sprite.position = route.start
                p.sprite.alpha = 0.9 * (1 - f)
            }
        }
        for p in expired { release(p) }
    }

    // MARK: Comm-edge glow

    /// The comm edges as accent strokes along the routes: alpha `min(0.8, w/4)` plus the pulse, width `MapEdges.thickness`.
    /// At most 200 (the heaviest), rebuilt at 10 Hz or when the layout changes.
    private func updateGlow(model: MapModel, now: TimeInterval) {
        let m = motion
        guard now - m.lastGlow >= MotionState.edgeInterval || now < m.lastGlow || m.glowVersion != layoutVersion else { return }
        m.lastGlow = now
        m.glowVersion = layoutVersion
        var edges = model.edges(now: now)
        if edges.count > MotionState.edgeLimit {
            edges = edges.enumerated().sorted { $0.element.weight != $1.element.weight ? $0.element.weight > $1.element.weight : $0.offset < $1.offset }
                .prefix(MotionState.edgeLimit).map(\.element)
        }
        var used = 0
        for edge in edges {
            let a = edge.key.a, b = edge.key.b
            guard let route = motionRoute(Self.nodeId(a), Self.nodeId(b)), route.points.count >= 2 else { continue }
            if used == m.glow.count {
                let shape = GlowShape()
                m.glowLayer.addChild(shape.node)
                m.glow.append(shape)
            }
            let shape = m.glow[used]
            let key = "\(Self.nodeId(a))\u{0}\(Self.nodeId(b))\u{0}\(layoutVersion)"
            if shape.key != key || shape.node.path == nil {
                let path = CGMutablePath()
                path.addLines(between: route.points)
                shape.node.path = path
                shape.key = key
            }
            let width = CGFloat(MapEdges.thickness(edge.weight))
            if abs(shape.node.lineWidth - width) > 0.02 { shape.node.lineWidth = width }
            shape.node.alpha = CGFloat(Swift.min(1, Swift.min(0.8, edge.weight / 4) + edge.pulse))
            shape.node.isHidden = false
            used += 1
        }
        for k in used..<m.glow.count { m.glow[k].node.isHidden = true }
    }

    // MARK: Meeting hulls

    /// A dashed `accent` hull around the visible cards of each meeting's participants (those inside a collapsed subtree
    /// stand in as that subtree's card), with the cleaned title in mono 10 `accent`. A meeting with fewer than two visible
    /// cards has no hull.
    private func updateHulls(model: MapModel) {
        let m = motion
        let signature = HullSignature(version: layoutVersion, meetings: model.meetings)
        guard signature != m.hullSignature else { return }
        m.hullSignature = signature
        m.hullLayer.removeAllChildren()
        m.hulls = [:]
        guard let tree = builtTree else { return }
        let pad: CGFloat = 6, labelBand: CGFloat = 14
        for meeting in model.meetings {
            var rects: [CGRect] = []
            var seen = Set<String>()
            for id in meeting.participantIds {
                let visible = tree.visibleAncestor(id, collapsed: builtCollapsed)
                if seen.insert(visible).inserted, let r = layout.cards[visible] { rects.append(Self.sceneRect(r)) }
            }
            guard rects.count >= 2 else { continue }
            var rect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }.insetBy(dx: -pad, dy: -pad)
            // The title sits in a strip along the bottom edge: the top is where a team band prints its own label.
            rect.origin.y -= labelBand
            rect.size.height += labelBand
            let outline = CGPath(rect: rect, transform: nil).copy(dashingWithPhase: 0, lengths: [6, 4])
            let hull = SKShapeNode(path: outline)
            hull.strokeColor = MapPalette.color(ThemeHex.accent)
            hull.fillColor = .clear
            hull.lineWidth = 1.5
            hull.name = "meetingHull"
            m.hullLayer.addChild(hull)

            let title = OrgCardNode.fit(meeting.title, width: rect.width - 12, size: 10, mono: true)
            let texture = LabelTextures.shared.text(title, size: 10, mono: true, color: ThemeHex.accent)
            let label = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
            label.anchorPoint = CGPoint(x: 0, y: 0.5)
            label.position = CGPoint(x: rect.minX + 6, y: rect.minY + 9)
            label.name = "meetingTitle"
            m.hullLayer.addChild(label)
            m.hulls[meeting.id] = MeetingHull(rect: rect, title: title)
        }
    }

    // MARK: Highlight

    /// The jump target gets a 2 pt `accent` ring for as long as the controller keeps it highlighted (1.5 s of frames).
    private func updateHighlight(controller: MapController) {
        let m = motion
        guard let id = controller.highlightId, let rect = currentCardRect(id) else {
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
            m.highlightLayer.addChild(m.ring)
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

    /// A card's rect as it is drawn now (mid-glide included), else where the layout puts it.
    func currentCardRect(_ id: String) -> CGRect? {
        if let node = cards[id] {
            return CGRect(x: node.position.x - node.cardSize.width / 2, y: node.position.y - node.cardSize.height / 2,
                          width: node.cardSize.width, height: node.cardSize.height)
        }
        return cardRect(id)
    }
}
