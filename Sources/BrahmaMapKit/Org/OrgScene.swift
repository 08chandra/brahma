import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

/// The org chart: Board on top, the reporting tree below it in team bands, collapsed subtrees as stubs, dotted lines
/// (reviewer, navigator) between cards. `OrgLayout` decides where everything goes (layout y grows downward; the scene's y
/// points up, so a layout point `(x, y)` is drawn at `(x, -y)`); this class draws it and answers hit tests.
///
/// Layers, back to front: `bg0` background with a `mapGrid` lattice every 24 pt, team bands, connectors, dotted lines,
/// cards and stubs, band labels (over the connectors that enter a band from above). The camera is an `SKCameraNode`;
/// `zoom` is its inverse scale. The live visuals (message particles, comm-edge glow, meeting hulls, the highlight ring and
/// the card animations) are driven by `update(controller:events:now:)` (OrgParticles.swift).
///
/// Rebuilding is incremental: a layout is recomputed only when the tree or the collapsed set changed, card nodes are
/// reused by id (and pooled when a card leaves), and a card whose rect moved glides there in 0.4 s.
@MainActor
public final class OrgScene: SKScene {
    public static let zoomRange = 0.15...3.0
    /// Below this zoom the cards are blank: status bar and border only.
    public static let textZoom = 0.5
    /// From this zoom a card shows its current item (a vacancy its note).
    public static let itemZoom = 1.2
    static let moveDuration = 0.4
    static let gridStep: CGFloat = 24
    /// Grid tile: 64 × 64 cells, so one texture covers a large area with few sprites.
    static let gridTile: CGFloat = 24 * 64
    /// Sibling bands sit `hGap` (16) apart; 3 on each side leaves 10, and each nesting level adds another 3.
    static let bandPadding: CGFloat = 3
    static let bandHeader: CGFloat = 22

    // MARK: Layers

    let cameraNode = SKCameraNode()
    /// Easing, follow, auto-fit and the controller's zoom (MapCamera.swift).
    private(set) lazy var cameraDriver = MapCameraDriver(scene: self, camera: cameraNode, zoomRange: Self.zoomRange)
    private let gridLayer = SKNode()
    private let bandLayer = SKNode()
    private let connectorLayer = SKNode()
    private let dottedLayer = SKNode()
    private let cardLayer = SKNode()
    private let labelLayer = SKNode()
    /// The live visuals' layers and bookkeeping (OrgParticles.swift).
    let motion = MotionState()
    private let connectorShape = SKShapeNode()
    private var gridSprites: [SKSpriteNode] = []
    private var lastCamera: (position: CGPoint, scale: CGFloat, size: CGSize)?

    // MARK: State

    private(set) var layout = OrgLayout()
    private(set) var builtTree: OrgTree?
    private(set) var builtCollapsed: Set<String> = []
    private(set) var builtRevision = -1
    /// Bumped whenever the layout changed: cached routes and the shapes drawn from them are stale.
    private(set) var layoutVersion = 0
    private(set) var cards: [String: OrgCardNode] = [:]
    private var stubs: [String: OrgCardNode] = [:]
    private var targets: [String: CGPoint] = [:]
    private var pool: [OrgCardNode] = []
    private var bandSpecs: [BandSpec] = []
    private var dottedSprites: [SKSpriteNode] = []
    private var resolvedDotted: [DottedKind: [Pair]] = [:]
    private var textLevel = Level.items
    public private(set) var contentBounds = CGRect.zero
    /// Reduce Motion (spec §5.6): the running bars stop pulsing and promotions do not pop the trust chip. The other card
    /// animations and the particles are unchanged.
    public var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            for node in cards.values { node.reduceMotion = reduceMotion }
            for node in stubs.values { node.reduceMotion = reduceMotion }
        }
    }

    private enum Level: Int { case blank, text, items }

    private struct Pair: Hashable { var a: CGPoint; var b: CGPoint }

    struct BandSpec: Equatable {
        var id: String
        var rect: CGRect
        var title: String
        var department: Department
    }

    // MARK: Init

    public override init(size: CGSize) {
        super.init(size: size)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = MapPalette.color(ThemeHex.bg0)
        scaleMode = .resizeFill
        anchorPoint = .zero
        for (layer, z) in [(gridLayer, -10), (bandLayer, 0), (connectorLayer, 1), (dottedLayer, 2), (cardLayer, 3), (labelLayer, 4)] {
            layer.zPosition = CGFloat(z)
            addChild(layer)
        }
        // Between the lines and the cards: comm-edge glow and meeting hulls; above the cards: the highlight ring and the
        // particles.
        for (layer, z) in [(motion.glowLayer, 1.5), (motion.hullLayer, 2.5), (motion.highlightLayer, 4.5), (motion.particleLayer, 5)] {
            layer.zPosition = CGFloat(z)
            addChild(layer)
        }
        connectorShape.strokeColor = MapPalette.color(ThemeHex.line)
        connectorShape.lineWidth = 1
        connectorShape.lineJoin = .miter
        connectorLayer.addChild(connectorShape)
        addChild(cameraNode)
        camera = cameraNode
        cameraNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraMoved()
    }

    // MARK: Camera

    /// Magnification, clamped to `zoomRange`.
    public var zoom: Double {
        get { cameraDriver.zoom }
        set {
            cameraDriver.zoom = newValue
            cameraMoved()
        }
    }

    /// Centres the chart and zooms so all of `contentBounds` plus `margin` points shows (clamped to `zoomRange`).
    public func zoomToFit(margin: CGFloat = 40) {
        cameraDriver.zoomToFit(contentBounds: contentBounds, margin: margin)
        cameraMovedIfNeeded()
    }

    /// Where the camera shows all of `contentBounds` plus `margin` points: its centre and (unclamped) zoom. Nil while the
    /// chart or the view is empty.
    func fitGoal(margin: CGFloat = 40) -> (center: CGPoint, zoom: Double)? {
        cameraDriver.fitGoal(contentBounds: contentBounds, margin: margin)
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if cameraNode.parent != nil { cameraMoved() }
    }

    public override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)
        // Driven by a view: one controller frame, then the scene's own. Map time starts at 0 with the first frame.
        if let controller = motion.driver {
            // A scene mounted on a controller that has already run continues at the controller's map time, which kept
            // running (the clock) while nothing was mounted; `lastFrameTime` would be stale by the unmounted interval.
            let base = motion.timeBase ?? (currentTime - controller.mapNow())
            motion.timeBase = base
            let now = currentTime - base
            update(controller: controller, events: controller.frame(now: now), now: now)
        }
        // Another owner (a pan or zoom gesture) may have moved the camera directly.
        cameraMovedIfNeeded()
    }

    /// `cameraMoved()` when the camera or the view changed since it last ran (a gesture, the camera driver).
    func cameraMovedIfNeeded() {
        if let last = lastCamera, last.position == cameraNode.position, last.scale == cameraNode.xScale, last.size == size { return }
        cameraMoved()
    }

    /// Everything that depends on the camera: text level of detail, connector width, the visible grid tiles.
    func cameraMoved() {
        lastCamera = (cameraNode.position, cameraNode.xScale, size)
        let z = zoom
        let level: Level = z < Self.textZoom ? .blank : z < Self.itemZoom ? .text : .items
        if level != textLevel {
            textLevel = level
            for node in cards.values { node.setZoom(z) }
            for node in stubs.values { node.setZoom(z) }
        }
        cards["owner"]?.setZoom(z)
        // One screen pixel whatever the zoom.
        connectorShape.lineWidth = Swift.max(1, CGFloat(1 / z))
        layoutGrid()
    }

    // MARK: Grid

    private static let gridTexture: SKTexture = {
        let cells = Int(gridTile / gridStep)
        let side = Int(gridTile)
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(MapPalette.color(ThemeHex.mapGrid).cgColor)
        for i in 0..<cells {
            let p = CGFloat(i) * gridStep
            context.fill(CGRect(x: p, y: 0, width: 1, height: gridTile))
            context.fill(CGRect(x: 0, y: p, width: gridTile, height: 1))
        }
        let texture = SKTexture(cgImage: context.makeImage()!)
        texture.filteringMode = .linear
        texture.usesMipmaps = true
        return texture
    }()

    /// Sprites for the grid tiles under the camera; the tile grid is anchored at the origin, so lines sit at multiples of 24.
    private func layoutGrid() {
        let sx = cameraNode.xScale, sy = cameraNode.yScale
        let halfW = size.width * sx / 2, halfH = size.height * sy / 2
        let tile = Self.gridTile
        let i0 = Int(((cameraNode.position.x - halfW) / tile).rounded(.down))
        let i1 = Int(((cameraNode.position.x + halfW) / tile).rounded(.down))
        let j0 = Int(((cameraNode.position.y - halfH) / tile).rounded(.down))
        let j1 = Int(((cameraNode.position.y + halfH) / tile).rounded(.down))
        var used = 0
        if i1 >= i0, j1 >= j0, (i1 - i0 + 1) * (j1 - j0 + 1) <= 600 {
            for j in j0...j1 {
                for i in i0...i1 {
                    if used == gridSprites.count {
                        let sprite = SKSpriteNode(texture: Self.gridTexture, size: CGSize(width: tile, height: tile))
                        sprite.anchorPoint = .zero
                        gridLayer.addChild(sprite)
                        gridSprites.append(sprite)
                    }
                    gridSprites[used].position = CGPoint(x: CGFloat(i) * tile, y: CGFloat(j) * tile)
                    gridSprites[used].isHidden = false
                    used += 1
                }
            }
        }
        for k in used..<gridSprites.count { gridSprites[k].isHidden = true }
    }

    // MARK: Rebuild

    /// Recomputes the layout when the tree or the collapsed set changed, then brings the nodes in line with `model`.
    public func rebuild(model: MapModel, collapsed: Set<String>) {
        let tree = model.tree
        let layoutChanged = builtTree != tree || builtCollapsed != collapsed || builtRevision != model.structureRevision
        if layoutChanged {
            layout = OrgLayout.make(tree: tree, collapsed: collapsed)
            layoutVersion += 1
            builtTree = tree
            builtCollapsed = collapsed
            builtRevision = model.structureRevision
        }
        let counts = Self.subtreeCounts(tree: tree, agents: model.agents)
        let vacancies = Dictionary(model.vacancies.map { ("vacancy:" + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let z = zoom
        var moved = false
        var kept = Set<String>()

        for (id, rect) in layout.cards {
            let content: OrgCardNode.Content
            if id == tree.rootId {
                content = .board
            } else if let seat = vacancies[id] {
                content = .vacancy(roleTitle: seat.roleTitle, note: seat.note)
            } else if let agent = model.agents[id] {
                let expanded = tree.nodes[id]?.tier == .manager && !(tree.nodes[id]?.childIds.isEmpty ?? true) && layout.stubs[id] == nil
                content = .agent(agent, expanded: expanded)
            } else {
                continue
            }
            kept.insert(id)
            place(id, content: content, at: Self.center(rect), in: &cards, moved: &moved, zoom: z)
        }
        for id in cards.keys where !kept.contains(id) { retire(id, from: &cards) }

        for (id, rect) in layout.stubs {
            let c = counts[id] ?? Counts()
            let segments = c.segments
            place("stub:" + id, content: .stub(count: c.total, segments: segments), at: Self.center(rect), in: &stubs, moved: &moved, zoom: z)
        }
        for id in stubs.keys where layout.stubs[String(id.dropFirst(5))] == nil { retire(id, from: &stubs) }

        let specs = Self.bands(layout: layout, tree: tree, model: model)
        if layoutChanged || specs != bandSpecs {
            bandSpecs = specs
            rebuildBands(specs)
            rebuildConnectors()
            if layoutChanged && moved { fadeInLines() }
        }
        updateDotted(model: model, collapsed: collapsed)
        updateContentBounds()
        layoutGrid()
    }

    /// Creates, reconfigures or moves the node for `key`.
    private func place(_ key: String, content: OrgCardNode.Content, at point: CGPoint, in nodes: inout [String: OrgCardNode],
                       moved: inout Bool, zoom: Double) {
        if let node = nodes[key] {
            node.reduceMotion = reduceMotion
            node.configure(content, zoom: zoom)
            if targets[key] != point {
                moved = true
                targets[key] = point
                node.removeAction(forKey: "move")
                let move = SKAction.move(to: point, duration: Self.moveDuration)
                move.timingMode = .easeInEaseOut
                node.run(move, withKey: "move")
            }
        } else {
            let node = pool.popLast() ?? OrgCardNode()
            node.reduceMotion = reduceMotion
            node.configure(content, zoom: zoom)
            node.position = point
            targets[key] = point
            cardLayer.addChild(node)
            nodes[key] = node
        }
    }

    private func retire(_ key: String, from nodes: inout [String: OrgCardNode]) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        node.removeFromParent()
        node.reset()
        targets[key] = nil
        pool.append(node)
    }

    /// The lines are redrawn at once; after a move they fade in while the cards glide.
    private func fadeInLines() {
        for layer in [bandLayer, connectorLayer, dottedLayer, labelLayer] {
            layer.removeAction(forKey: "fade")
            layer.alpha = 0
            layer.run(.fadeIn(withDuration: Self.moveDuration), withKey: "fade")
        }
    }

    // MARK: Geometry

    static func center(_ r: MapRect) -> CGPoint { CGPoint(x: r.x + r.w / 2, y: -(r.y + r.h / 2)) }

    static func sceneRect(_ r: MapRect) -> CGRect { CGRect(x: r.x, y: -(r.y + r.h), width: r.w, height: r.h) }

    /// The scene rect of a card by node id: an agent id, `"owner"`, or `"vacancy:<id>"`. The layout's target rect, so it is
    /// already the final one while a card is still gliding there.
    public func cardRect(_ id: String) -> CGRect? { layout.cards[id].map(Self.sceneRect) }

    /// The scene rect of the stub under a collapsed node.
    public func stubRect(_ id: String) -> CGRect? { layout.stubs[id].map(Self.sceneRect) }

    var cardIds: Set<String> { Set(cards.keys) }
    var stubIds: Set<String> { Set(stubs.keys.map { String($0.dropFirst(5)) }) }
    func cardNode(_ id: String) -> OrgCardNode? { cards[id] }
    func stubNode(_ id: String) -> OrgCardNode? { stubs["stub:" + id] }
    var dottedSpriteNames: [String] { dottedLayer.children.compactMap(\.name) }
    var bandRects: [String: CGRect] { Dictionary(bandSpecs.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first }) }

    /// The header strip of a team band: its label, and the part of the band that hits as `.team`.
    func bandLabelRect(_ managerId: String) -> CGRect? {
        guard let band = bandSpecs.first(where: { $0.id == managerId })?.rect else { return nil }
        return CGRect(x: band.minX, y: band.maxY - Self.bandHeader, width: band.width, height: Self.bandHeader)
    }

    private func updateContentBounds() {
        var bounds = CGRect.null
        for r in layout.cards.values { bounds = bounds.union(Self.sceneRect(r)) }
        for r in layout.stubs.values { bounds = bounds.union(Self.sceneRect(r)) }
        for band in bandSpecs { bounds = bounds.union(band.rect) }
        contentBounds = bounds.isNull ? .zero : bounds
    }

    // MARK: Hit test

    /// What lies under a scene point: cards first (agent, Board, open seat), then stubs, then a team band's header strip.
    /// Vacancy results carry the cleaned id the map shows; mapping it to the raw org handle is the controller's job.
    public func hit(at p: CGPoint) -> MapHit? {
        for (id, r) in layout.cards where Self.sceneRect(r).contains(p) {
            if id == "owner" { return .owner }
            if id.hasPrefix("vacancy:") { return .vacancy(String(id.dropFirst("vacancy:".count))) }
            return .agent(id)
        }
        for (id, r) in layout.stubs where Self.sceneRect(r).contains(p) { return .stub(id) }
        // Innermost band first: the smallest header that holds the point.
        for band in bandSpecs.sorted(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            if bandLabelRect(band.id)?.contains(p) == true { return .team(band.id) }
        }
        return nil
    }

    /// True when `p` is on the `▾` of an expanded manager's card (its bottom-right corner), where a click collapses the team
    /// instead of selecting the agent. The marker only shows from `textZoom`.
    func isExpandMarker(_ id: String, at p: CGPoint) -> Bool {
        guard zoom >= Self.textZoom, case .agent(_, let expanded)? = cards[id]?.content, expanded, let r = cardRect(id) else {
            return false
        }
        return p.x >= r.maxX - 20 && p.y <= r.minY + 18
    }

    // MARK: Bands

    /// One band per expanded manager: its subtree's bounding box padded (more above, for the label), and padded again around
    /// any nested manager's band so nested bands never touch.
    static func bands(layout: OrgLayout, tree: OrgTree, model: MapModel) -> [BandSpec] {
        let managers = Set(tree.order.filter { id in
            tree.nodes[id]?.tier == .manager && layout.teamBands[id] != nil && layout.stubs[id] == nil
                && !(tree.nodes[id]?.childIds.isEmpty ?? true)
        })
        var nested: [String: CGRect] = [:]
        var specs: [BandSpec] = []
        let pad = bandPadding
        for id in tree.order.reversed() where managers.contains(id) {
            let base = sceneRect(layout.teamBands[id]!)
            var rect = CGRect(x: base.minX - pad, y: base.minY - pad, width: base.width + 2 * pad, height: base.height + 2 * pad + bandHeader)
            if let inner = nested[id] { rect = rect.union(inner) }
            if let outer = tree.ancestors(id).first(where: managers.contains) {
                nested[outer] = (nested[outer] ?? .null).union(rect.insetBy(dx: -pad, dy: -pad))
            }
            let agent = model.agents[id]
            let department = model.groups.first { $0.id == "team:" + (agent?.team ?? "") }?.department
                ?? agent?.department ?? .engineering
            let title = model.teamCard(managerId: id)?.title ?? department.title
            specs.append(BandSpec(id: id, rect: rect, title: title, department: department))
        }
        return specs
    }

    private func rebuildBands(_ specs: [BandSpec]) {
        bandLayer.removeAllChildren()
        labelLayer.removeAllChildren()
        // Outer bands first, so inner ones draw over them.
        for spec in specs.sorted(by: { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }) {
            let r = spec.rect
            let border = SKSpriteNode(color: MapPalette.color(ThemeHex.line), size: r.size)
            border.position = CGPoint(x: r.midX, y: r.midY)
            bandLayer.addChild(border)
            let fill = SKSpriteNode(color: MapPalette.color(ThemeHex.bg1), size: CGSize(width: r.width - 2, height: r.height - 2))
            fill.position = border.position
            bandLayer.addChild(fill)
            let stripe = SKSpriteNode(color: MapPalette.department(spec.department), size: CGSize(width: r.width - 2, height: 2))
            stripe.position = CGPoint(x: r.midX, y: r.maxY - 2)
            stripe.name = "bandStripe"
            bandLayer.addChild(stripe)

            let text = OrgCardNode.fit(spec.title, width: r.width - 20, size: 10, mono: true)
            let texture = LabelTextures.shared.text(text, size: 10, mono: true, color: ThemeHex.text2)
            let size = OrgCardNode.points(texture)
            let backing = SKSpriteNode(color: MapPalette.color(ThemeHex.bg1), size: CGSize(width: size.width + 6, height: 14))
            backing.anchorPoint = CGPoint(x: 0, y: 0.5)
            backing.position = CGPoint(x: r.minX + 5, y: r.maxY - 12)
            labelLayer.addChild(backing)
            let label = SKSpriteNode(texture: texture, size: size)
            label.anchorPoint = CGPoint(x: 0, y: 0.5)
            label.position = CGPoint(x: r.minX + 8 - 1, y: r.maxY - 12)
            label.name = "bandLabel"
            labelLayer.addChild(label)
        }
    }

    // MARK: Connectors and dotted lines

    private func rebuildConnectors() {
        let path = CGMutablePath()
        for connector in layout.connectors {
            for (i, p) in connector.points.enumerated() {
                let point = CGPoint(x: p.x, y: -p.y)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        connectorShape.path = path
    }

    /// Dashed curves between cards, one batched texture per kind. Ends inside a collapsed subtree attach to the collapsed
    /// node; a link that collapses onto one card is not drawn.
    private func updateDotted(model: MapModel, collapsed: Set<String>) {
        var resolved: [DottedKind: [Pair]] = [:]
        var seen = Set<String>()
        for link in model.dotted {
            let a = model.tree.visibleAncestor(link.from, collapsed: collapsed)
            let b = model.tree.visibleAncestor(link.to, collapsed: collapsed)
            guard a != b, let ra = layout.cards[a], let rb = layout.cards[b],
                  seen.insert("\(a)\u{0}\(b)\u{0}\(link.kind.rawValue)").inserted else { continue }
            resolved[link.kind, default: []].append(Pair(a: Self.center(ra), b: Self.center(rb)))
        }
        guard resolved != resolvedDotted else { return }
        resolvedDotted = resolved
        dottedLayer.removeAllChildren()
        for kind in [DottedKind.other, .navigator, .reviewer] {
            guard let pairs = resolved[kind] else { continue }
            let hex: UInt32 = kind == .reviewer ? ThemeHex.text2 : kind == .navigator ? ThemeHex.accent : ThemeHex.lineStrong
            guard let (texture, bounds) = DottedTexture.render(pairs.map { ($0.a, $0.b) }, color: hex) else { continue }
            let sprite = SKSpriteNode(texture: texture, size: bounds.size)
            sprite.position = CGPoint(x: bounds.midX, y: bounds.midY)
            sprite.name = "dotted-\(kind.rawValue)"
            dottedLayer.addChild(sprite)
        }
    }

    // MARK: Subtree counts

    struct Counts {
        var running = 0, ready = 0, blocked = 0, sleeping = 0, killed = 0
        var total: Int { running + ready + blocked + sleeping + killed }

        mutating func add(_ state: AgentState) {
            switch state {
            case .running: running += 1
            case .ready: ready += 1
            case .blocked: blocked += 1
            case .sleeping: sleeping += 1
            case .killed: killed += 1
            }
        }

        mutating func add(_ o: Counts) {
            running += o.running; ready += o.ready; blocked += o.blocked; sleeping += o.sleeping; killed += o.killed
        }

        var segments: [OrgCardNode.Segment] {
            [(ThemeHex.running, running), (ThemeHex.ready, ready), (ThemeHex.blocked, blocked),
             (ThemeHex.sleeping, sleeping), (ThemeHex.killed, killed)].map { OrgCardNode.Segment(color: $0.0, count: $0.1) }
        }
    }

    /// Per node: the agents below it (not itself, not open seats), by displayed state.
    static func subtreeCounts(tree: OrgTree, agents: [String: MapAgent]) -> [String: Counts] {
        var counts: [String: Counts] = [:]
        for id in tree.order.reversed() {
            guard let parent = tree.nodes[id]?.parentId else { continue }
            var own = counts[id] ?? Counts()
            if let agent = agents[id] { own.add(OrgCardNode.displayState(agent)) }
            counts[parent, default: Counts()].add(own)
        }
        return counts
    }
}

// MARK: - Forced rebuild

extension OrgScene {
    /// The next `update(controller:…)` rebuilds the cards whatever changed.
    func forceRebuild() { builtRevision = -1 }
}

// MARK: - MapScene

extension OrgScene: MapScene {
    public var mode: MapMode { .org }

    /// The card's rect (`cardRect`).
    public func targetRect(_ id: String) -> CGRect? { cardRect(id) }
}
