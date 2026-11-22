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
/// are reused by id (and pooled when they leave), and a desk whose rect moved glides there in `moveDuration`. The motion
/// (walks, notes, event visuals, strolls, the highlight ring and follow) is driven on map time by
/// `update(controller:events:now:)` (OfficeMotion.swift); a rebuild alone puts every figure where it belongs at once.
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
    /// An idle figure strolls to the break room this long after it sat down (or came back), seeded by its agent id.
    public static let strollRange = 20.0...40.0
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
    /// Walks, notes, event visuals and the highlight ring (OfficeMotion.swift).
    let motion = OfficeMotionState()

    // MARK: State

    public private(set) var layout = OfficeLayout()
    public private(set) var lod = OfficeLOD.full
    public private(set) var contentBounds = CGRect.zero
    /// No typing frames or pulses, and a state badge on every desk (spec §5.6). Starts at the system setting.
    public var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            if reduceMotion { releaseParticles() }
            guard let builtModel else { return }
            rebuild(model: builtModel, replaying: builtReplaying)
            advanceFigures(now: nil)
        }
    }

    private(set) var builtModel: MapModel?
    /// The agents as the floor shows them: the model's, or during a replay its states without the item facets.
    private(set) var shownAgents: [String: MapAgent] = [:]
    /// The last rebuild was of a replay (its item facets hidden).
    private var builtReplaying = false
    private var builtTree: OrgTree?
    private var builtRevision = -1
    /// The structure revision the desks and figures were last refreshed for (the layout may be held at an older one).
    private(set) var contentRevision = -1
    private var hasLayout = false
    private(set) var desks: [String: OfficeDeskNode] = [:]
    private var deskTargets: [String: CGPoint] = [:]
    private var deskPool: [OfficeDeskNode] = []
    private(set) var figures: [String: OfficeFigureNode] = [:]
    private var figurePool: [OfficeFigureNode] = []
    private(set) var rooms: [String: OfficeRoomNode] = [:]
    private var pods: [String: OfficePodNode] = [:]
    private var floorSize: CGSize?
    private var textLevel = -1
    private var lastCamera: (position: CGPoint, scale: CGFloat, size: CGSize)?

    private(set) var driver: MapController?
    private var timeBase: TimeInterval?

    /// Bumped when what VoiceOver hears may have changed (`MapAccessible`).
    public private(set) var accessibilityRevision = 0
    /// Bumped whenever `layout` is replaced.
    private var layoutVersion = 0
    private var accessibilityKey: AccessibilityKey?

    /// Everything `accessibilityItems` reads: the structure, the layout, the agents and the open asks.
    private struct AccessibilityKey: Equatable {
        var structure: Int
        var layout: Int
        var agents: [String: MapAgent]
        var openAsks: Int
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
        backgroundColor = MapPalette.color(ThemeHex.officeFloor)
        scaleMode = .resizeFill
        anchorPoint = .zero
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Notes fly above every figure (whose depth is a few thousand at most) and under the desks' labels.
        let layers: [(SKNode, CGFloat)] = [(floorLayer, -10), (roomLayer, 1), (podLayer, 2), (deskLayer, 3), (figureLayer, 4),
                                           (motion.particleLayer, OfficeZ.labels / 2),
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
    /// the controller's; the walks, notes and effects of a previous controller are dropped.
    public func present(controller: MapController?) {
        driver = controller
        timeBase = nil
        resetMotion(for: controller)
    }

    public override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)
        if let controller = driver {
            let base = timeBase ?? (currentTime - controller.mapNow())
            timeBase = base
            let now = currentTime - base
            update(controller: controller, events: controller.frame(now: now), now: now)
        }
        // A gesture or the camera driver may have moved the camera.
        cameraMovedIfNeeded()
    }

    /// The next `update(controller:…)` rebuilds the floor whatever changed.
    func forceRebuild() {
        builtRevision = -1
        contentRevision = -1
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

    func cameraMovedIfNeeded() {
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
            rooms["room:mail"]?.showKeys(level == 2)
        }
        figureLayer.isHidden = z < Self.figureZoom
    }

    // MARK: Rebuild

    /// Brings the floor in line with `model`: the layout and rooms when the structure changed, then every desk, figure and
    /// room state; every figure is put where it belongs at once (no walks: those are `update(controller:…)`'s).
    public func rebuild(model: MapModel) {
        rebuild(model: model, replaying: false)
        advanceFigures(now: nil)
    }

    /// The rebuild behind `rebuild(model:)` and the driven frame. While a leave plays the layout is held (the leaver's desk
    /// stays where it was until its animation ends; spec §5.4), but states, activities and rooms are refreshed. During a
    /// replay the item facets are not shown (spec §5.7): no reviewing, meetings or parcels.
    func rebuild(model: MapModel, replaying: Bool) {
        builtModel = model
        builtReplaying = replaying
        let tree = model.tree
        let hold = !motion.leaving.isEmpty && hasLayout
        if !hold && (!hasLayout || builtTree != tree || builtRevision != model.structureRevision) {
            let next = OfficeLayout.make(model: model)
            builtTree = tree
            builtRevision = model.structureRevision
            if !hasLayout || next != layout {
                layout = next
                layoutVersion += 1
                hasLayout = true
                motion.layoutChanged()
                rebuildFloor()
                rebuildRooms()
            }
        }
        contentRevision = model.structureRevision
        shownAgents = replaying ? model.agents.mapValues(Self.replayed) : model.agents
        let living = model.agents.values.filter { $0.state != .killed }
        lod = Self.lod(living: living.count)
        rebuildDesks(model)
        let counts = rebuildFigures(model)
        updateRooms(model, waiting: counts.waiting, inReview: counts.inReview, replaying: replaying)
        contentBounds = CGRect(x: 0, y: -layout.size.h, width: layout.size.w, height: layout.size.h)
        let key = AccessibilityKey(structure: model.structureRevision, layout: layoutVersion, agents: model.agents,
                                   openAsks: model.openAsks)
        if key != accessibilityKey {
            accessibilityKey = key
            accessibilityRevision += 1
        }
    }

    /// An agent as a replay shows it: its state only (item phases are not in the timeline), so no review room, meeting
    /// or parcel.
    static func replayed(_ a: MapAgent) -> MapAgent {
        var a = a
        switch a.activity {
        case .reviewing, .meeting: a.activity = a.state == .running ? .typing : .idle
        default: break
        }
        a.shipping = nil
        return a
    }

    private func rebuildDesks(_ model: MapModel) {
        let vacancies = Dictionary(model.vacancies.map { ("vacancy:" + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let z = zoom
        var kept = Set<String>()
        for (id, desk) in layout.desks {
            if motion.leaving[id] != nil, desks[id] != nil {
                // Playing its leave: left as it is until the animation ends.
                kept.insert(id)
                continue
            }
            if let seat = vacancies[id] {
                place(id, desk).configure(vacancy: seat, zoom: z)
            } else if let agent = shownAgents[id] {
                let node = place(id, desk)
                node.isHead = desk.podId.flatMap { layout.pods[$0]?.managerId } == id
                node.configure(agent: agent, zoom: z, lod: lod, reduceMotion: reduceMotion)
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

    /// Where each figure belongs at rest (spec §5.4), in tree order: at the seat typing, idle or blocked (raised hand,
    /// `!`); standing at the board room door waiting on the owner (`…`); at a review-room chair reviewing or in a meeting;
    /// none away or gone, and none at all at desk-only LOD. A figure keeps its review chair or door spot while it stays
    /// there; a newcomer takes the lowest free one. A leaving figure is kept as it is (it fades out). The figures get there
    /// in `advanceFigures`. Returns how many wait at the board room and sit in the review room.
    private func rebuildFigures(_ model: MapModel) -> (waiting: Int, inReview: Int) {
        var review: [String] = [], door: [String] = []
        for id in model.tree.order {
            guard let agent = shownAgents[id], layout.desks[id] != nil, motion.leaving[id] == nil else { continue }
            switch agent.activity {
            case .reviewing, .meeting: review.append(id)
            case .waitingOnOwner: door.append(id)
            default: break
            }
        }
        motion.reviewSeats = Self.assign(review, keeping: motion.reviewSeats)
        motion.doorSpots = Self.assign(door, keeping: motion.doorSpots)

        var kept = Set<String>()
        for id in model.tree.order {
            guard let agent = shownAgents[id], let desk = layout.desks[id] else { continue }
            if motion.leaving[id] != nil {
                if figures[id] != nil { kept.insert(id) }
                continue
            }
            var rest = OfficeMotionState.Rest(spot: Self.point(desk.seat), pose: .sit, bubble: nil, typing: false, idle: false)
            switch agent.activity {
            case .typing:
                rest.pose = .typeA
                rest.typing = lod == .full && !reduceMotion
            case .idle:
                rest.idle = true
            case .blocked:
                rest.pose = .raisedHand
                rest.bubble = .exclaim
            case .waitingOnOwner:
                rest.spot = Self.point(layout.doorSpot(motion.doorSpots[id] ?? 0))
                rest.pose = .stand
                rest.bubble = .ellipsis
            case .reviewing, .meeting:
                rest.spot = Self.point(layout.reviewSeat(motion.reviewSeats[id] ?? 0))
            case .away, .gone:
                continue
            }
            guard lod != .deskOnly else { continue }
            kept.insert(id)
            let node = figures[id] ?? {
                let node = figurePool.popLast() ?? OfficeFigureNode()
                // A figure that appears is where it belongs (it walks only from one place to another).
                node.position = rest.spot
                node.zPosition = -node.position.y
                motion.targets[id] = rest.spot
                figureLayer.addChild(node)
                figures[id] = node
                return node
            }()
            node.tint(agent.department)
            node.collar = agent.trust?.tier
            motion.rests[id] = rest
        }
        // A leaver is out of the tree already; its figure stays until its fade ends.
        for id in motion.leaving.keys where figures[id] != nil { kept.insert(id) }
        for id in figures.keys where !kept.contains(id) {
            guard let node = figures.removeValue(forKey: id) else { continue }
            node.removeFromParent()
            node.reset()
            figurePool.append(node)
            motion.forgetFigure(id)
        }
        return (door.count, review.count)
    }

    /// Spot indices for `ids`: each keeps the one it had, the others take the lowest free ones in order.
    static func assign(_ ids: [String], keeping old: [String: Int]) -> [String: Int] {
        var result: [String: Int] = [:]
        var used = Set<Int>()
        for id in ids {
            if let k = old[id], used.insert(k).inserted { result[id] = k }
        }
        var next = 0
        for id in ids where result[id] == nil {
            while used.contains(next) { next += 1 }
            result[id] = next
            used.insert(next)
        }
        return result
    }

    /// The asks on the board table, the door counters (desk-only LOD), the meeting's door light, the wall of fame (the
    /// first `fameLimit` perks in tree order) and the mail-room parcels.
    private func updateRooms(_ model: MapModel, waiting: Int, inReview: Int, replaying: Bool) {
        let board = rooms["room:board"], review = rooms["room:review"]
        board?.setAsks(model.openAsks)
        board?.count = lod == .deskOnly ? waiting : 0
        review?.count = lod == .deskOnly ? inReview : 0
        let meeting = replaying ? nil : model.meetings.first { m in
            m.participantIds.contains { shownAgents[$0]?.activity == .meeting(m.id) }
        }
        review?.setMeeting(meeting?.title)

        var fame: [String] = []
        for id in model.tree.order {
            guard let agent = model.agents[id], agent.activity != .gone else { continue }
            if fame.count < Self.fameLimit { fame.append(contentsOf: agent.perks.prefix(Self.fameLimit - fame.count)) }
        }
        rooms["room:break"]?.setFame(fame)
        updateParcels()
    }

    /// One parcel per shipping item, in tree order, never a former agent's (Task 2 M1) nor one whose passed parcel has
    /// already left; `✓` on a parcel being stamped. None during a replay (`shownAgents` has no shipping then).
    func updateParcels() {
        guard let model = builtModel, let mail = rooms["room:mail"] else { return }
        motion.departed = motion.departed.filter { shownAgents[$0]?.shipping == .passed }
        var list: [OfficeRoomNode.Parcel] = []
        for id in model.tree.order {
            guard let agent = shownAgents[id], agent.activity != .gone, let phase = agent.shipping,
                  !motion.departed.contains(id) else { continue }
            let key = agent.item.flatMap { $0.split(separator: " ", maxSplits: 1).first.map(String.init) }
            list.append(OfficeRoomNode.Parcel(id: id, phase: phase, key: key, stamped: motion.stamps[id] != nil))
        }
        mail.setParcels(list, spots: list.indices.map { Self.point(layout.mailCounter($0)) })
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
        rooms["room:mail"]?.showKeys(textLevel == 2)
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

    /// Where the camera looks for `id` (spec §5.7): its figure as it is drawn now at full and static LOD, else its desk.
    func figureOrDeskRect(_ id: String) -> CGRect? {
        if lod != .deskOnly, let node = figures[id] {
            let s = OfficeTextures.figureSize
            return CGRect(x: node.position.x - s.width / 2, y: node.position.y - s.height / 2, width: s.width, height: s.height)
        }
        return deskRect(id)
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

// MARK: - Accessibility (spec §5.6)

extension OfficeScene: MapAccessible, MapMotionReducible {
    /// The rooms VoiceOver reads by name besides the board room (a click on them hits nothing, so they are not pressed).
    static let spokenRooms = [("room:review", "Review room"), ("room:break", "Break room"), ("room:mail", "Mail room")]

    /// The rooms first (so the cap never drops them): the board room with its open asks ("1 open ask", else "N open
    /// asks"; ruling R32), then the review, break and mail
    /// rooms by name; then one item per desk in tree order: `"<handle>, <role>, <state>"` and `", <item>"` when the agent
    /// has one (the hover card's cleaned fields), or `"Open seat, <role title>"`. Frames are the layout's rects (a gliding
    /// desk's final one); a desk and the board room press what a click on them hits.
    public func accessibilityItems(limit: Int) -> [MapAccessibilityItem] {
        guard limit > 0, let model = builtModel else { return [] }
        var items: [MapAccessibilityItem] = []
        if let frame = roomRect("room:board") {
            let asks = model.openAsks == 1 ? "1 open ask" : "\(model.openAsks) open asks"
            items.append(MapAccessibilityItem(id: "room:board", label: "Board room, owner, " + asks, frame: frame, hit: .owner))
        }
        for (id, name) in Self.spokenRooms {
            guard let frame = roomRect(id) else { continue }
            items.append(MapAccessibilityItem(id: id, label: name, frame: frame, hit: nil))
        }
        let vacancies = Dictionary(model.vacancies.map { ("vacancy:" + $0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in model.tree.order where items.count < limit {
            guard let desk = layout.desks[id] else { continue }
            let frame = Self.sceneRect(desk.rect)
            if let seat = vacancies[id] {
                items.append(MapAccessibilityItem(id: id, label: "Open seat, " + seat.roleTitle, frame: frame,
                                                  hit: .vacancy(seat.id)))
            } else if let card = model.hoverCard(agentId: id) {
                let label = "\(card.handle), \(card.role), \(card.stateLabel)" + (card.item.map { ", " + $0 } ?? "")
                items.append(MapAccessibilityItem(id: id, label: label, frame: frame, hit: .agent(id)))
            }
        }
        return Array(items.prefix(limit))
    }
}
