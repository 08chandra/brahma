import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

/// The office (Plan 4c, spec §5): the company as a night office lit by its screens, in a 3/4 top-down "dollhouse" view.
/// `OfficeLayout` decides where everything goes (layout y grows downward; a layout point `(x, y)` is drawn at `(x, -y)`, as
/// `OrgScene`); this class draws it, puts the figures where their activity says, and answers hit tests.
///
/// Layers, back to front: floor tiles, room floors and pod carpets, walls and room furniture, pods (label, pin board),
/// desks, figures (y-sorted: `zPosition = -position.y`), bubbles and badges (`OfficeZ.overlay`), the highlight ring and the
/// chip layer. The level of detail follows the living-agent count (`lod(living:)`), never the frame time.
///
/// Rebuilding is incremental: the layout and the rooms are remade only when the structure changed; desk and figure nodes
/// are reused by id (and pooled when they leave), and a desk whose rect moved glides there in `moveDuration`.
@MainActor
public final class OfficeScene: SKScene, MapScene {
    public static let zoomRange = 0.15...3.0
    /// Below this zoom desks lose their text.
    public static let textZoom = 0.5
    /// From this zoom desks show roles and desk items.
    public static let itemZoom = 1.2
    /// Below this zoom figures hide (they would be a pixel).
    public static let figureZoom = 0.3
    /// Living agents up to this: full animation.
    public static let fullLOD = 50
    /// Living agents up to this: static figures; above it, desk state only.
    public static let staticLOD = 150
    public static let moveDuration = 0.4
    public static let walkDuration = 0.8
    public static let typingHz = 4.0
    public static let pulseHz = 1.0
    /// Folders on the board table before it shows `9+`.
    public static let askFolders = 9
    /// Perk glyphs on the break room's wall of fame.
    public static let fameLimit = 6
    /// Desks pick up state changes at least this often while a controller drives the scene.
    static let refreshInterval = 0.25
    /// One floor texture covers 64 × 64 tiles of 24 pt.
    static let floorTile: CGFloat = 24 * 64

    public var mode: MapMode { .office }

    /// The level of detail for `living` agents (spec §5.5).
    public static func lod(living: Int) -> OfficeLOD {
        living <= fullLOD ? .full : living <= staticLOD ? .staticFigures : .deskOnly
    }

    // MARK: Layers

    let cameraNode = SKCameraNode()
    /// Easing, follow, auto-fit and the controller's zoom. The scene owns its driver, which holds the scene unowned.
    private(set) lazy var cameraDriver = MapCameraDriver(scene: self, camera: cameraNode, zoomRange: Self.zoomRange)
    private let floorLayer = SKNode()
    private let roomLayer = SKNode()
    private let podLayer = SKNode()
    private let deskLayer = SKNode()
    private let figureLayer = SKNode()
    let highlightLayer = SKNode()
    let chipLayer = SKNode()

    // MARK: State

    public private(set) var layout = OfficeLayout()
    public private(set) var lod = OfficeLOD.full
    public private(set) var contentBounds = CGRect.zero
    /// No typing frames or pulses, and a state badge on every desk (spec §5.6). Starts at the system setting.
    public var reduceMotion = false {
        didSet { if reduceMotion != oldValue, let builtModel { rebuild(model: builtModel) } }
    }

    private var builtModel: MapModel?
    private var builtTree: OrgTree?
    private var builtRevision = -1
    private var hasLayout = false
    private var desks: [String: OfficeDeskNode] = [:]
    private var deskTargets: [String: CGPoint] = [:]
    private var deskPool: [OfficeDeskNode] = []
    private var figures: [String: OfficeFigureNode] = [:]
    private var figurePool: [OfficeFigureNode] = []
    private var rooms: [String: OfficeRoomNode] = [:]
    private var pods: [String: OfficePodNode] = [:]
    private var floorSize: CGSize?
    private var textLevel = -1
    private var lastCamera: (position: CGPoint, scale: CGFloat, size: CGSize)?

    private var driver: MapController?
    private var timeBase: TimeInterval?
    private var lastRebuild = -Double.infinity

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
        backgroundColor = MapPalette.color(ThemeHex.officeFloor)
        scaleMode = .resizeFill
        anchorPoint = .zero
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let layers: [(SKNode, CGFloat)] = [(floorLayer, -10), (roomLayer, 1), (podLayer, 2), (deskLayer, 3), (figureLayer, 4),
                                           (highlightLayer, 2 * OfficeZ.overlay), (chipLayer, 2 * OfficeZ.overlay + 1)]
        for (layer, z) in layers {
            layer.zPosition = z
            addChild(layer)
        }
        addChild(cameraNode)
        camera = cameraNode
        cameraNode.position = CGPoint(x: size.width / 2, y: size.height / 2)
        cameraMoved()
    }

    // MARK: Driving

    /// Makes `controller` drive this scene from `SKScene.update(_:)` (or stops driving with nil). Map time continues from
    /// the controller's.
    public func present(controller: MapController?) {
        driver = controller
        timeBase = nil
        lastRebuild = -.infinity
        builtRevision = -1
        cameraDriver.reset()
    }

    public override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)
        if let controller = driver {
            let base = timeBase ?? (currentTime - controller.mapNow())
            timeBase = base
            let now = currentTime - base
            // The events are the office's to play from Task 7; at rest the frame only advances the controller.
            _ = controller.frame(now: now)
            let model = controller.model
            if builtRevision != model.structureRevision || now - lastRebuild >= Self.refreshInterval || now < lastRebuild {
                rebuild(model: model)
                lastRebuild = now
            }
            cameraDriver.update(controller: controller, now: now, targetRect: deskRect, contentBounds: contentBounds)
            cameraDriver.syncZoom(controller: controller)
        }
        // A gesture or the camera driver may have moved the camera.
        cameraMovedIfNeeded()
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

    /// Centres the floor and zooms so all of it plus `margin` points shows (clamped to `zoomRange`).
    public func zoomToFit(margin: CGFloat = 40) {
        cameraDriver.zoomToFit(contentBounds: contentBounds, margin: margin)
        cameraMovedIfNeeded()
    }

    /// The owner dragged or zoomed: stop easing, stop tracking a followed desk, stop refitting.
    public func userMovedCamera() {
        cameraDriver.userMoved()
    }

    public override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if cameraNode.parent != nil { cameraMoved() }
    }

    private func cameraMovedIfNeeded() {
        if let last = lastCamera, last.position == cameraNode.position, last.scale == cameraNode.xScale, last.size == size { return }
        cameraMoved()
    }

    /// Everything that depends on the zoom: desk text and items, figure visibility.
    private func cameraMoved() {
        lastCamera = (cameraNode.position, cameraNode.xScale, size)
        let z = zoom
        let level = z < Self.textZoom ? 0 : z < Self.itemZoom ? 1 : 2
        if level != textLevel {
            textLevel = level
            for node in desks.values { node.setZoom(z) }
        }
        figureLayer.isHidden = z < Self.figureZoom
    }

    // MARK: Rebuild

    /// Brings the floor in line with `model`: the layout and rooms when the structure changed, then every desk, figure and
    /// room state.
    public func rebuild(model: MapModel) {
        builtModel = model
        let tree = model.tree
        if !hasLayout || builtTree != tree || builtRevision != model.structureRevision {
            let next = OfficeLayout.make(model: model)
            builtTree = tree
            builtRevision = model.structureRevision
            if !hasLayout || next != layout {
                layout = next
                hasLayout = true
                rebuildFloor()
                rebuildRooms()
            }
        }
        let living = model.agents.values.filter { $0.state != .killed }
        lod = Self.lod(living: living.count)
        rebuildDesks(model)
        let counts = rebuildFigures(model)
        updateRooms(model, waiting: counts.waiting, inReview: counts.inReview)
        contentBounds = CGRect(x: 0, y: -layout.size.h, width: layout.size.w, height: layout.size.h)
    }

    private func rebuildDesks(_ model: MapModel) {
        let vacancies = Dictionary(model.vacancies.map { ("vacancy:" + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let z = zoom
        var kept = Set<String>()
        for (id, desk) in layout.desks {
            if let seat = vacancies[id] {
                place(id, desk).configure(vacancy: seat, zoom: z)
            } else if let agent = model.agents[id] {
                place(id, desk).configure(agent: agent, zoom: z, lod: lod, reduceMotion: reduceMotion)
            } else {
                continue
            }
            kept.insert(id)
        }
        for id in desks.keys where !kept.contains(id) {
            guard let node = desks.removeValue(forKey: id) else { continue }
            node.removeFromParent()
            node.reset()
            deskTargets[id] = nil
            deskPool.append(node)
        }
    }

    /// The node for desk `id`, created or reused, facing its way and at (or gliding to) its rect.
    private func place(_ id: String, _ desk: OfficeDesk) -> OfficeDeskNode {
        let point = Self.center(desk.rect)
        if let node = desks[id] {
            node.facesDown = desk.facesDown
            if deskTargets[id] != point {
                deskTargets[id] = point
                node.removeAction(forKey: "move")
                let move = SKAction.move(to: point, duration: Self.moveDuration)
                move.timingMode = .easeInEaseOut
                node.run(move, withKey: "move")
            }
            return node
        }
        let node = deskPool.popLast() ?? OfficeDeskNode()
        node.facesDown = desk.facesDown
        node.position = point
        deskTargets[id] = point
        deskLayer.addChild(node)
        desks[id] = node
        return node
    }

    /// Figures at rest (spec §5.4), in tree order: at the seat typing, idle or blocked (raised hand, `!`); standing at the
    /// board room door waiting on the owner (`…`); at a review-room chair reviewing or in a meeting; none away or gone.
    /// None at all at desk-only LOD. Returns how many wait at the board room and sit in the review room.
    private func rebuildFigures(_ model: MapModel) -> (waiting: Int, inReview: Int) {
        var kept = Set<String>()
        var waiting = 0, inReview = 0
        for id in model.tree.order {
            guard let agent = model.agents[id], let desk = layout.desks[id] else { continue }
            let spot: MapPoint2
            var pose = OfficeTextures.FigurePose.sit
            var bubble: OfficeTextures.BubbleGlyph?
            switch agent.activity {
            case .typing:
                spot = desk.seat
                pose = .typeA
            case .idle:
                spot = desk.seat
            case .blocked:
                spot = desk.seat
                pose = .raisedHand
                bubble = .exclaim
            case .waitingOnOwner:
                spot = layout.doorSpot(waiting)
                waiting += 1
                pose = .stand
                bubble = .ellipsis
            case .reviewing, .meeting:
                spot = layout.reviewSeat(inReview)
                inReview += 1
            case .away, .gone:
                continue
            }
            guard lod != .deskOnly else { continue }
            kept.insert(id)
            let node = figures[id] ?? {
                let node = figurePool.popLast() ?? OfficeFigureNode()
                figureLayer.addChild(node)
                figures[id] = node
                return node
            }()
            node.tint(agent.department)
            node.collar = agent.trust?.tier
            node.pose = pose
            node.setTyping(agent.activity == .typing && lod == .full && !reduceMotion)
            node.setBubble(bubble)
            node.position = CGPoint(x: spot.x, y: -spot.y)
            node.zPosition = -node.position.y
        }
        for id in figures.keys where !kept.contains(id) {
            guard let node = figures.removeValue(forKey: id) else { continue }
            node.removeFromParent()
            node.reset()
            figurePool.append(node)
        }
        return (waiting, inReview)
    }

    /// The asks on the board table, the door counters (desk-only LOD), the meeting's door light, the wall of fame (the
    /// first `fameLimit` perks in tree order) and the mail-room parcels (never a former agent's).
    private func updateRooms(_ model: MapModel, waiting: Int, inReview: Int) {
        let board = rooms["room:board"], review = rooms["room:review"]
        board?.setAsks(model.openAsks)
        board?.count = lod == .deskOnly ? waiting : 0
        review?.count = lod == .deskOnly ? inReview : 0
        let meeting = model.meetings.first { m in
            m.participantIds.contains { model.agents[$0]?.activity == .meeting(m.id) }
        }
        review?.setMeeting(meeting?.title)

        var fame: [String] = []
        var parcels: [MapItemPhase] = []
        for id in model.tree.order {
            guard let agent = model.agents[id], agent.activity != .gone else { continue }
            if fame.count < Self.fameLimit { fame.append(contentsOf: agent.perks.prefix(Self.fameLimit - fame.count)) }
            if let phase = agent.shipping { parcels.append(phase) }
        }
        rooms["room:break"]?.setFame(fame)
        rooms["room:mail"]?.setParcels(parcels, spots: parcels.indices.map { Self.point(layout.mailCounter($0)) })
    }

    // MARK: Floor and rooms

    /// The floor's 24 pt tiles (`OfficeTextures.floorTile`), 64 × 64 to a texture.
    private static let floorTexture: SKTexture = {
        let side = Int(floorTile)
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let tile = OfficeTextures.floorTile.cgImage()
        let step = Int(OfficeTextures.points(OfficeTextures.floorTile).width)
        context.interpolationQuality = .high
        for y in stride(from: 0, to: side, by: step) {
            for x in stride(from: 0, to: side, by: step) {
                context.draw(tile, in: CGRect(x: x, y: y, width: step, height: step))
            }
        }
        let texture = SKTexture(cgImage: context.makeImage()!)
        texture.filteringMode = .linear
        texture.usesMipmaps = true
        return texture
    }()

    /// Floor tiles over the layout's rect (cropped at its right and bottom edges) and the building's outer wall.
    private func rebuildFloor() {
        let size = CGSize(width: layout.size.w, height: layout.size.h)
        guard size != floorSize else { return }
        floorSize = size
        floorLayer.removeAllChildren()
        let t = Self.floorTile
        var top: CGFloat = 0
        while top < size.height {
            let h = Swift.min(t, size.height - top)
            var left: CGFloat = 0
            while left < size.width {
                let w = Swift.min(t, size.width - left)
                let texture = SKTexture(rect: CGRect(x: 0, y: 1 - h / t, width: w / t, height: h / t), in: Self.floorTexture)
                let sprite = SKSpriteNode(texture: texture, size: CGSize(width: w, height: h))
                sprite.anchorPoint = CGPoint(x: 0, y: 1)
                sprite.position = CGPoint(x: left, y: -top)
                sprite.name = "floor"
                floorLayer.addChild(sprite)
                left += t
            }
            top += t
        }
        let wall = OfficeRoomNode.wall
        let edges = [CGRect(x: 0, y: -wall / 2, width: size.width, height: wall),
                     CGRect(x: 0, y: -size.height - wall / 2, width: size.width, height: wall),
                     CGRect(x: -wall / 2, y: -size.height, width: wall, height: size.height),
                     CGRect(x: size.width - wall / 2, y: -size.height, width: wall, height: size.height)]
        for r in edges where size.width > 0 && size.height > 0 {
            let sprite = SKSpriteNode(texture: r.width >= r.height ? OfficeTextures.wallH : OfficeTextures.wallV, size: r.size)
            sprite.position = CGPoint(x: r.midX, y: r.midY)
            sprite.zPosition = 11
            sprite.name = "outerWall"
            floorLayer.addChild(sprite)
        }
    }

    private func rebuildRooms() {
        roomLayer.removeAllChildren()
        podLayer.removeAllChildren()
        rooms = [:]
        pods = [:]
        for room in layout.rooms.values.sorted(by: { $0.id < $1.id }) {
            let node = OfficeRoomNode(room: room, layout: layout)
            roomLayer.addChild(node)
            rooms[room.id] = node
        }
        if let ante = layout.anteroom {
            let r = Self.sceneRect(ante)
            let floor = SKSpriteNode(color: MapPalette.color(ThemeHex.bg1), size: r.size)
            floor.position = CGPoint(x: r.midX, y: r.midY)
            floor.zPosition = -1
            floor.name = "anteroom"
            roomLayer.addChild(floor)
        }
        for pod in layout.pods.values.sorted(by: { $0.id < $1.id }) {
            let node = OfficePodNode(pod: pod, hasHead: hasHead(pod))
            podLayer.addChild(node)
            pods[pod.id] = node
        }
    }

    // MARK: Geometry

    static func center(_ r: MapRect) -> CGPoint { CGPoint(x: r.x + r.w / 2, y: -(r.y + r.h / 2)) }

    static func sceneRect(_ r: MapRect) -> CGRect { CGRect(x: r.x, y: -(r.y + r.h), width: r.w, height: r.h) }

    static func point(_ p: MapPoint2) -> CGPoint { CGPoint(x: p.x, y: -p.y) }

    /// The scene rect of a desk (top and front face) by id: an agent id or `"vacancy:<id>"`. The layout's rect, so it is
    /// already the final one while the desk glides there.
    public func deskRect(_ id: String) -> CGRect? { layout.desks[id].map { Self.sceneRect($0.rect) } }

    /// The scene rect of a room: `"room:board"`, `"room:ceo"`, `"office:<agentId>"`, `"room:review"`, `"room:break"`,
    /// `"room:mail"`.
    public func roomRect(_ id: String) -> CGRect? { layout.rooms[id].map { Self.sceneRect($0.rect) } }

    /// The desk: where the camera goes to show an agent.
    public func targetRect(_ id: String) -> CGRect? { deskRect(id) }

    // MARK: Hit test

    /// What lies under a scene point: a figure (the frontmost), a desk (an agent or an open seat), the board room (the
    /// owner), the label of a pod with a head desk (its manager's team); else nothing.
    public func hit(at p: CGPoint) -> MapHit? {
        if !figureLayer.isHidden {
            let under = figures.filter { $0.value.frameRect.contains(p) }
            if let front = under.max(by: { ($0.value.zPosition, $1.key) < ($1.value.zPosition, $0.key) }) { return .agent(front.key) }
        }
        for (id, desk) in layout.desks where Self.sceneRect(desk.rect).contains(p) {
            if id.hasPrefix("vacancy:") { return .vacancy(String(id.dropFirst("vacancy:".count))) }
            return .agent(id)
        }
        if let board = roomRect("room:board"), board.contains(p) { return .owner }
        for pod in layout.pods.values.sorted(by: { $0.id < $1.id }) where hasHead(pod) {
            if let manager = pod.managerId, Self.sceneRect(pod.labelRect).contains(p) { return .team(manager) }
        }
        return nil
    }

    /// The pod's manager sits at its head desk (spec §5.2): only such a pod's label hits `.team`. A pod whose owner has
    /// an office (CEO, C-suite, director), and a department pod, has no head desk and no team hit.
    func hasHead(_ pod: OfficePod) -> Bool {
        guard let manager = pod.managerId else { return false }
        return layout.desks[manager]?.podId == pod.id
    }

    // MARK: Test and tooling accessors

    func deskNode(_ id: String) -> OfficeDeskNode? { desks[id] }
    func figureNode(_ id: String) -> OfficeFigureNode? { figures[id] }
    func roomNode(_ id: String) -> OfficeRoomNode? { rooms[id] }
    var allFigureNodes: [OfficeFigureNode] { Array(figures.values) }
    var allDeskNodes: [OfficeDeskNode] { Array(desks.values) }
    func podNode(_ id: String) -> OfficePodNode? { pods[id] }
    var fameGlyphs: [String] { rooms["room:break"]?.fame ?? [] }
    var roomNodeCount: Int { rooms.count }
    var deskCount: Int { desks.count }
}
