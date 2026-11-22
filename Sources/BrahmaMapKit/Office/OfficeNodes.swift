import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

/// The office's level of detail, by living-agent count (spec §5.5).
public enum OfficeLOD: Equatable, Sendable {
    /// Everything moves: typing frames, glow pulses (and in Task 7 walks and strolls).
    case full
    /// Figures appear where they belong but do not animate.
    case staticFigures
    /// No figures: desks show state by light, bubbles become 4 pt markers, the doors count.
    case deskOnly
}

/// Z offsets inside a layer, so labels and bubbles stay above the y-sorted figures (`zPosition = -position.y`, a few
/// thousand at most) whatever their depth.
@MainActor
enum OfficeZ {
    static let labels: CGFloat = 50_000
    static let overlay: CGFloat = 100_000
}

// MARK: - Desk

/// One desk (spec §5.3), drawn around the centre of its layout rect (the 24 pt top over the 6 pt face), with its chair at
/// the seat: lamp, monitor (the state light) and its halo, the handle and role, up to two desk items, a Reduce Motion
/// badge, a former agent's box, or an open seat's dashed outline and `HIRING` placard.
///
/// Every string it draws is the model's cleaned text, cut to the desk by `OrgCardNode.fit` (itself `MapText.clean`).
@MainActor
final class OfficeDeskNode: SKNode {
    static let pulseKey = "pulse"
    /// Desk top, front face and the whole depth, in points.
    static let size = CGSize(width: OfficeLayout.desk.w, height: OfficeLayout.desk.h + OfficeLayout.desk.face)
    /// Labels may overhang the desk into the aisle, never into the next desk's label.
    static let labelWidth = CGFloat(OfficeLayout.desk.w + OfficeLayout.pod.aisle - 4)

    private enum Content: Equatable {
        case agent(MapAgent, lod: OfficeLOD, reduceMotion: Bool)
        case vacancy(Vacancy)
    }

    /// The sitter faces down the floor (the chair is above the desk). Set before `configure`.
    var facesDown = false {
        didSet { if facesDown != oldValue { content = nil } }
    }

    private var content: Content?
    /// The monitor's tint: the status colour while lit or dim, `bg1` while off.
    private(set) var screenColor = ThemeHex.bg1
    private(set) var screenState = OfficeTextures.ScreenState.off
    private(set) var lampOn = false
    private(set) var badge: OfficeTextures.BadgeGlyph?
    private var badgeRect: CGRect?
    private(set) var handleText: String?
    private(set) var roleText: String?
    private(set) var hasBox = false
    private(set) var hasPlacard = false
    private(set) var isStruck = false
    private(set) var isVacancy = false
    /// The status-coloured light the screen throws on the desk; it pulses on a typing desk at full LOD.
    private(set) var halo = SKSpriteNode()
    /// Shown from `OfficeScene.textZoom`: the handle (and its strike).
    private let details = SKNode()
    /// Shown from `OfficeScene.itemZoom`: the role and the desk items.
    private let items = SKNode()
    private var itemSprites = 0

    /// Desk items showing now (0 below `itemZoom`).
    var itemCount: Int { items.isHidden ? 0 : itemSprites }

    override init() {
        super.init()
        details.zPosition = OfficeZ.labels
        items.zPosition = OfficeZ.labels
    }

    required init?(coder: NSCoder) { fatalError("OfficeDeskNode is built in code") }

    // MARK: Configure

    /// An agent's desk at rest (spec §5.4): the screen and lamp follow the activity; a typing desk's halo pulses at full
    /// LOD unless `reduceMotion`, which shows the state badge instead; a former agent's desk is dark with a box.
    func configure(agent: MapAgent, zoom: Double, lod: OfficeLOD, reduceMotion: Bool) {
        let next = Content.agent(agent, lod: lod, reduceMotion: reduceMotion)
        guard next != content else { setZoom(zoom); return }
        clear()
        content = next
        buildAgent(agent, lod: lod, reduceMotion: reduceMotion)
        setZoom(zoom)
    }

    /// An open seat: a dashed, unlit desk with its empty chair and the `HIRING` placard; its role title from `itemZoom`.
    func configure(vacancy: Vacancy, zoom: Double) {
        let next = Content.vacancy(vacancy)
        guard next != content else { setZoom(zoom); return }
        clear()
        content = next
        isVacancy = true
        addChild(chair())
        addChild(sprite(OfficeTextures.deskDashed, at: .zero))
        addChild(sprite(OfficeTextures.placard, at: CGPoint(x: 0, y: 3)))
        hasPlacard = true
        let title = OrgCardNode.fit(vacancy.roleTitle, width: Self.labelWidth, size: 8, mono: false)
        roleText = title
        addLabel(title, size: 8, mono: false, color: ThemeHex.text1, y: -11.5, band: Self.roleBand, to: items)
        addChild(items)
        setZoom(zoom)
    }

    /// Back to a blank node for the pool; also drops the glide.
    func reset() {
        removeAllActions()
        clear()
        facesDown = false
    }

    func setZoom(_ zoom: Double) {
        details.isHidden = zoom < OfficeScene.textZoom
        items.isHidden = zoom < OfficeScene.itemZoom
    }

    private func clear() {
        removeAllChildren()
        details.removeAllChildren()
        items.removeAllChildren()
        content = nil
        screenColor = ThemeHex.bg1
        screenState = .off
        lampOn = false
        badge = nil
        badgeRect = nil
        handleText = nil
        roleText = nil
        hasBox = false
        hasPlacard = false
        isStruck = false
        isVacancy = false
        itemSprites = 0
        halo = SKSpriteNode()
    }

    // MARK: Agent

    /// Where things sit on the top, by orientation: the monitor, lamp and desk items on the far side from the sitter;
    /// the handle and role bands between the monitor and the sitter, clear of the seated figure's frame (which starts
    /// 5 pt short of the seat, 19 pt from the desk's centre), of its bubble (beside the body) and of the badge (beyond the
    /// desk's left edge, on the monitor's side).
    private struct Plan {
        var monitorY: CGFloat, handleY: CGFloat, roleY: CGFloat, badgeY: CGFloat
    }

    private var plan: Plan {
        facesDown ? Plan(monitorY: -6, handleY: 9.5, roleY: 1.5, badgeY: -8)
            : Plan(monitorY: 11.5, handleY: 3.5, roleY: -4, badgeY: 13)
    }

    /// The bands behind the handle and the role: a label is drawn over a `bg1` plate (above every figure), so it stays
    /// legible over a screen's glow, and nothing is drawn over it.
    static let handleBand: CGFloat = 8.5
    static let roleBand: CGFloat = 7.5

    private func buildAgent(_ agent: MapAgent, lod: OfficeLOD, reduceMotion: Bool) {
        let p = plan
        let activity = agent.activity
        let status = ThemeHex.status(agent.state, paused: agent.paused)
        switch activity {
        case .typing, .blocked, .waitingOnOwner:
            screenState = .lit
            screenColor = status
        case .idle, .reviewing, .meeting:
            screenState = .dim
            screenColor = status
        case .away, .gone:
            screenState = .off
            screenColor = ThemeHex.bg1
        }
        lampOn = screenState != .off
        let gone = activity == .gone

        addChild(chair())
        let top = sprite(OfficeTextures.deskTop, at: CGPoint(x: 0, y: 3))
        // The keyboard toward the sitter.
        if facesDown { top.yScale = -1 }
        let face = sprite(OfficeTextures.deskFace, at: CGPoint(x: 0, y: -12))
        if gone { top.alpha = 0.55; face.alpha = 0.55 }
        addChild(top)
        addChild(face)

        let monitorAt = CGPoint(x: -7, y: p.monitorY)
        if screenState == .lit {
            // The screen glows around the monitor, its core kept off the label bands (on the sitter's side).
            halo = sprite(OfficeTextures.screenGlow, at: CGPoint(x: monitorAt.x, y: monitorAt.y + (facesDown ? -1.5 : 1.5)))
            halo.size = CGSize(width: 44, height: 30)
            tint(halo, status)
            halo.name = "halo"
            addChild(halo)
            if activity == .typing && lod == .full && !reduceMotion {
                let half = 0.5 / OfficeScene.pulseHz
                let pulse = SKAction.sequence([.fadeAlpha(to: 0.6, duration: half), .fadeAlpha(to: 1.0, duration: half)])
                pulse.timingMode = .easeInEaseOut
                halo.run(.repeatForever(pulse), withKey: Self.pulseKey)
            }
        }
        let monitor = sprite(OfficeTextures.monitor(screenState), at: monitorAt)
        if screenState != .off { tint(monitor, status) }
        addChild(monitor)

        let lampAt = CGPoint(x: -15, y: p.monitorY + 0.5)
        if lampOn {
            let glow = sprite(OfficeTextures.lampGlow, at: lampAt)
            glow.size = CGSize(width: 30, height: 30)
            glow.alpha = 0.7
            tint(glow, ThemeHex.officeLamp)
            glow.name = "lampGlow"
            addChild(glow)
        }
        let lamp = sprite(OfficeTextures.lamp, at: lampAt)
        tint(lamp, lampOn ? ThemeHex.officeLamp : ThemeHex.lineStrong)
        lamp.name = "lamp"
        addChild(lamp)

        if gone {
            addChild(sprite(OfficeTextures.box, at: CGPoint(x: 7, y: p.monitorY)))
            hasBox = true
        }

        // The handle (from textZoom), struck through for a former agent as on the org card.
        let handle = OrgCardNode.fit(agent.handle, width: Self.labelWidth, size: 9, mono: true)
        handleText = handle
        let handleSprite = addLabel(handle, size: 9, mono: true, color: ThemeHex.text0, y: p.handleY, band: Self.handleBand,
                                    to: details)
        if gone {
            let strike = SKSpriteNode(color: MapPalette.color(ThemeHex.text0),
                                      size: CGSize(width: handleSprite.size.width - 2, height: 1))
            strike.position = CGPoint(x: 0, y: p.handleY)
            strike.name = "strike"
            details.addChild(strike)
            isStruck = true
        }
        addChild(details)

        // The role and up to two desk items (from itemZoom).
        let role = OrgCardNode.fit(agent.role, width: Self.labelWidth, size: 8, mono: false)
        roleText = role
        addLabel(role, size: 8, mono: false, color: ThemeHex.text1, y: p.roleY, band: Self.roleBand, to: items)
        var x = CGFloat(OfficeLayout.desk.w / 2) + 1
        for perk in agent.perks.prefix(2).reversed() {
            let texture = LabelTextures.shared.emoji(OrgCardNode.fit(perk, width: 16, size: 10, mono: false), size: 10)
            let glyph = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
            glyph.anchorPoint = CGPoint(x: 1, y: 0.5)
            glyph.position = CGPoint(x: x, y: p.monitorY)
            glyph.name = "perk"
            items.addChild(glyph)
            x -= glyph.size.width - 1
            itemSprites += 1
        }
        addChild(items)

        if reduceMotion, let glyph = Self.badge(activity) {
            badge = glyph
            badgeRect = CGRect(x: -OfficeLayout.desk.w / 2 - 10, y: p.badgeY - 5, width: 10, height: 10)
            // Just outside the desk's left edge, beside the lamp: off the label bands.
            let chip = sprite(OfficeTextures.badge(glyph), at: CGPoint(x: -OfficeLayout.desk.w / 2 - 5, y: p.badgeY))
            tint(chip, status)
            chip.zPosition = OfficeZ.overlay
            chip.name = "badge"
            addChild(chip)
        }
        // Desk-only LOD: the blocked and waiting bubbles become 4 pt markers.
        if lod == .deskOnly, activity == .blocked || activity == .waitingOnOwner {
            let marker = sprite(OfficeTextures.lamp, at: CGPoint(x: OfficeLayout.desk.w / 2 + 3, y: p.monitorY))
            marker.size = CGSize(width: 4, height: 4)
            tint(marker, ThemeHex.blocked)
            marker.zPosition = OfficeZ.overlay
            marker.name = "marker"
            addChild(marker)
        }
    }

    /// The state badge of spec §5.6; idle and gone have none.
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

    // MARK: Sprites

    /// The chair, at the seat; its backrest toward the viewer when the sitter faces up the floor.
    private func chair() -> SKSpriteNode {
        let seat = CGFloat(Self.size.height / 2 + OfficeLayout.chair.h / 2)
        let chair = sprite(OfficeTextures.chair, at: CGPoint(x: 0, y: facesDown ? seat : -seat))
        if facesDown { chair.yScale = -1 }
        chair.name = "chair"
        return chair
    }

    private func sprite(_ texture: SKTexture, at p: CGPoint) -> SKSpriteNode {
        let s = SKSpriteNode(texture: texture, size: OfficeTextures.points(texture))
        s.position = p
        return s
    }

    private func tint(_ s: SKSpriteNode, _ hex: UInt32) {
        s.color = MapPalette.color(hex)
        s.colorBlendFactor = 1
    }

    /// A text sprite centred at (0, `y`) over a `bg1` plate `band` points tall, added to `parent`.
    @discardableResult
    private func addLabel(_ text: String, size: CGFloat, mono: Bool, color: UInt32, y: CGFloat, band: CGFloat,
                          to parent: SKNode) -> SKSpriteNode {
        let texture = LabelTextures.shared.text(text, size: size, mono: mono, color: color)
        let s = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
        s.position = CGPoint(x: 0, y: y)
        let plate = SKSpriteNode(color: MapPalette.color(ThemeHex.bg1), size: CGSize(width: s.size.width - 1, height: band))
        plate.alpha = 0.8
        plate.position = s.position
        // Under every text of the desk, so the role's plate never clips the handle's descenders.
        plate.zPosition = -1
        plate.name = "plate"
        parent.addChild(plate)
        parent.addChild(s)
        return s
    }

    /// The label plates showing now, in the parent's coordinates.
    var labelFrames: [CGRect] {
        [details, items].filter { !$0.isHidden && $0.parent != nil }.flatMap { layer in
            layer.children.filter { $0.name == "plate" }.map { $0.frame.offsetBy(dx: position.x, dy: position.y) }
        }
    }

    /// The Reduce Motion badge's frame in the parent's coordinates, nil without one.
    var badgeFrame: CGRect? { badgeRect?.offsetBy(dx: position.x, dy: position.y) }
}

// MARK: - Figure

/// A worker (spec §5.3): a department-tinted peg body and a `text1` head in a 10 × 16 pt frame, a 1 pt trust collar when a
/// provider supplies a tier, and a speech bubble. The node's position is where the figure is: its seat (seated poses sit
/// on the chair) or the spot it stands on.
@MainActor
final class OfficeFigureNode: SKNode {
    static let typingKey = "typing"

    let body = SKSpriteNode(texture: OfficeTextures.figureBody(.sit), size: OfficeTextures.figureSize)
    let head = SKSpriteNode(texture: OfficeTextures.figureHead, size: OfficeTextures.points(OfficeTextures.figureHead))
    private let collarSprite = SKSpriteNode(color: .white, size: CGSize(width: 6, height: 1))
    private let bubbleSprite = SKSpriteNode()

    var pose = OfficeTextures.FigurePose.sit {
        didSet { if pose != oldValue { applyPose() } }
    }

    /// The trust tier (0…3) the collar shows, nil for none.
    var collar: Int? {
        didSet { applyCollar() }
    }

    private(set) var collarColor: UInt32?
    private(set) var bubble: OfficeTextures.BubbleGlyph?

    /// The bubble's frame in scene coordinates, nil without one.
    var bubbleFrame: CGRect? {
        bubble == nil ? nil : CGRect(origin: CGPoint(x: position.x + bubbleSprite.position.x, y: position.y + bubbleSprite.position.y),
                                     size: bubbleSprite.size)
    }

    override init() {
        super.init()
        body.anchorPoint = .zero
        addChild(body)
        addChild(head)
        collarSprite.isHidden = true
        addChild(collarSprite)
        bubbleSprite.anchorPoint = .zero
        bubbleSprite.zPosition = OfficeZ.overlay
        bubbleSprite.isHidden = true
        addChild(bubbleSprite)
        applyPose()
    }

    required init?(coder: NSCoder) { fatalError("OfficeFigureNode is built in code") }

    /// Seated frames drop 5 pt so the body rests on the chair at the seat; standing frames stand on the spot.
    private var frameBottom: CGFloat {
        switch pose {
        case .stand, .walkA, .walkB: 0
        default: -5
        }
    }

    /// The figure's frame in scene coordinates (for hit tests).
    var frameRect: CGRect {
        let s = OfficeTextures.figureSize
        return CGRect(x: position.x - s.width / 2, y: position.y + frameBottom, width: s.width, height: s.height)
    }

    func tint(_ d: Department) {
        body.color = MapPalette.department(d)
        body.colorBlendFactor = 1
    }

    /// Alternates the two typing frames at `OfficeScene.typingHz`, or holds `typeA`.
    func setTyping(_ on: Bool) {
        guard on != (body.action(forKey: Self.typingKey) != nil) else { return }
        if on {
            pose = .typeA
            let frames = [OfficeTextures.figureBody(.typeA), OfficeTextures.figureBody(.typeB)]
            body.run(.repeatForever(.animate(with: frames, timePerFrame: 0.5 / OfficeScene.typingHz)), withKey: Self.typingKey)
        } else {
            body.removeAction(forKey: Self.typingKey)
            body.texture = OfficeTextures.figureBody(pose)
        }
    }

    func setBubble(_ glyph: OfficeTextures.BubbleGlyph?) {
        bubble = glyph
        bubbleSprite.isHidden = glyph == nil
        guard let glyph else { return }
        let texture = OfficeTextures.bubble(glyph)
        bubbleSprite.texture = texture
        bubbleSprite.size = OfficeTextures.points(texture)
    }

    func reset() {
        removeAllActions()
        body.removeAllActions()
        pose = .sit
        collar = nil
        setBubble(nil)
        alpha = 1
    }

    private func applyPose() {
        body.removeAction(forKey: Self.typingKey)
        body.texture = OfficeTextures.figureBody(pose)
        let y = frameBottom, half = OfficeTextures.figureSize.width / 2
        body.position = CGPoint(x: -half, y: y)
        head.position = CGPoint(x: OfficeTextures.headCenter.x - half, y: y + OfficeTextures.headCenter.y)
        collarSprite.position = CGPoint(x: 0, y: y + 9.5)
        // Seated: beside the body, clear of the desk's text; standing: over the head.
        bubbleSprite.position = y < 0 ? CGPoint(x: 4, y: y + 2) : CGPoint(x: 2, y: y + OfficeTextures.figureSize.height - 1)
    }

    private func applyCollar() {
        collarColor = collar.map(ThemeHex.trustTier)
        collarSprite.isHidden = collarColor == nil
        if let collarColor { collarSprite.color = MapPalette.color(collarColor) }
    }
}

// MARK: - Room

/// A walled room (spec §5.2), drawn in scene coordinates (the node stays at the origin): its floor, walls with a door
/// gap and a door, the title, and the furniture of its kind — the board table with the open asks as folders, the review
/// table and its chairs, the break room's counter, sofa and wall of fame, the mail room's counter and parcels.
@MainActor
final class OfficeRoomNode: SKNode {
    static let wall: CGFloat = 3

    let room: OfficeRoom
    /// The review room's door light: a meeting is on.
    var doorLit = false {
        didSet { applyDoorLight() }
    }

    /// Desk-only LOD: how many agents the door stands for (review room: in it; board room: waiting at it). 0 hides it.
    var count = 0 {
        didSet { if count != oldValue { applyCount() } }
    }

    /// Folders on the board table.
    private(set) var askFolders = 0
    /// `9+` when there are more asks than folders.
    private(set) var askLabel: String?
    private(set) var fame: [String] = []
    private(set) var parcels = 0

    private let furniture = SKNode()
    private let asks = SKNode()
    private let shelf = SKNode()
    private let mail = SKNode()
    private var doorLight: SKSpriteNode?
    private var countLabel: SKSpriteNode?
    private var meetingLabel: SKSpriteNode?
    private var meetingTitle: String?

    init(room: OfficeRoom, layout: OfficeLayout) {
        self.room = room
        super.init()
        build(layout)
    }

    required init?(coder: NSCoder) { fatalError("OfficeRoomNode is built in code") }

    /// The room's rect, y up.
    var rect: CGRect { OfficeScene.sceneRect(room.rect) }

    private var doorOnTop: Bool { room.door.y <= room.rect.y }

    private func build(_ layout: OfficeLayout) {
        let r = rect
        let floor = SKSpriteNode(color: MapPalette.color(ThemeHex.officeRoomFloor), size: r.size)
        floor.position = CGPoint(x: r.midX, y: r.midY)
        floor.zPosition = -1
        floor.name = "floor"
        addChild(floor)

        // Walls: the door wall has a 16 pt gap; the CEO's corridor wall is glass.
        let door = CGPoint(x: room.door.x, y: -room.door.y)
        let gap: CGFloat = 16
        let doorY = door.y
        let glass = room.kind == .ceo
        for (y, isDoorWall) in [(r.maxY, doorOnTop), (r.minY, !doorOnTop)] {
            if isDoorWall {
                addWall(CGRect(x: r.minX, y: y - Self.wall / 2, width: door.x - gap / 2 - r.minX, height: Self.wall),
                        glass: glass && !doorOnTop)
                addWall(CGRect(x: door.x + gap / 2, y: y - Self.wall / 2, width: r.maxX - door.x - gap / 2, height: Self.wall),
                        glass: glass && !doorOnTop)
            } else {
                addWall(CGRect(x: r.minX, y: y - Self.wall / 2, width: r.width, height: Self.wall), glass: false)
            }
        }
        for x in [r.minX, r.maxX] {
            addWall(CGRect(x: x - Self.wall / 2, y: r.minY, width: Self.wall, height: r.height), glass: false)
        }
        let leaf = SKSpriteNode(texture: OfficeTextures.door, size: OfficeTextures.points(OfficeTextures.door))
        leaf.anchorPoint = .zero
        leaf.position = CGPoint(x: door.x - gap / 2, y: doorY)
        // The door swings into the room: up from a bottom wall, down from a top wall.
        if doorOnTop { leaf.yScale = -1 }
        leaf.name = "door"
        addChild(leaf)

        let title = OrgCardNode.fit(room.title, width: r.width - 12, size: 9, mono: true)
        let texture = LabelTextures.shared.text(title, size: 9, mono: true, color: ThemeHex.text2)
        let label = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
        label.anchorPoint = CGPoint(x: 0, y: 1)
        label.position = CGPoint(x: r.minX + 6, y: r.maxY - 4)
        label.name = "title"
        addChild(label)

        addChild(furniture)
        switch room.kind {
        case .board: buildBoard(r)
        case .review: buildReview(r, layout)
        case .breakRoom: buildBreak(r, layout)
        case .mail: buildMail(r)
        case .ceo, .executive, .director: break
        }
    }

    private func addWall(_ r: CGRect, glass: Bool) {
        guard r.width > 0, r.height > 0 else { return }
        let texture = r.width >= r.height ? OfficeTextures.wallH : OfficeTextures.wallV
        let wall = SKSpriteNode(texture: texture, size: r.size)
        wall.position = CGPoint(x: r.midX, y: r.midY)
        if glass {
            wall.color = MapPalette.color(ThemeHex.officeGlass)
            wall.colorBlendFactor = 1
            wall.size.height = 1.5
            wall.alpha = 0.85
            wall.name = "glass"
        } else {
            wall.name = "wall"
        }
        addChild(wall)
    }

    // MARK: Furniture

    /// A sprite of `texture` stretched to `size` points, keeping `edge` points on every side unstretched.
    private func stretched(_ texture: SKTexture, to size: CGSize, edge: CGFloat = 2, face: CGFloat = 7) -> SKSpriteNode {
        let p = OfficeTextures.points(texture)
        let s = SKSpriteNode(texture: texture, size: p)
        s.centerRect = CGRect(x: edge / p.width, y: face / p.height, width: 1 - 2 * edge / p.width,
                              height: Swift.max(0.01, 1 - (face + edge) / p.height))
        s.xScale = size.width / p.width
        s.yScale = size.height / p.height
        return s
    }

    private func put(_ texture: SKTexture, at p: CGPoint, flipY: Bool = false, rotate: CGFloat = 0) {
        let s = SKSpriteNode(texture: texture, size: OfficeTextures.points(texture))
        s.position = p
        if flipY { s.yScale = -1 }
        s.zRotation = rotate
        furniture.addChild(s)
    }

    /// The board table with four chairs a side; the asks lie on it as folders.
    private func buildBoard(_ r: CGRect) {
        let table = stretched(OfficeTextures.table, to: CGSize(width: 120, height: 36))
        table.position = CGPoint(x: r.midX, y: r.midY - 4)
        furniture.addChild(table)
        for k in 0..<4 {
            let x = r.midX - 45 + CGFloat(k) * 30
            put(OfficeTextures.chair, at: CGPoint(x: x, y: r.midY + 19), flipY: true)
            put(OfficeTextures.chair, at: CGPoint(x: x, y: r.midY - 27))
        }
        asks.position = CGPoint(x: r.midX, y: r.midY + 2)
        asks.zPosition = 1
        addChild(asks)
    }

    /// Up to `OfficeScene.askFolders` folders, and `9+` beside them when there are more asks.
    func setAsks(_ n: Int) {
        let shown = Swift.min(Swift.max(0, n), OfficeScene.askFolders)
        let label = n > OfficeScene.askFolders ? "\(OfficeScene.askFolders)+" : nil
        guard shown != askFolders || label != askLabel else { return }
        askFolders = shown
        askLabel = label
        asks.removeAllChildren()
        let pitch: CGFloat = 11
        for k in 0..<shown {
            let folder = SKSpriteNode(texture: OfficeTextures.folder, size: OfficeTextures.points(OfficeTextures.folder))
            folder.position = CGPoint(x: -52 + CGFloat(k) * pitch, y: 0)
            folder.name = "ask"
            asks.addChild(folder)
        }
        if let label {
            let texture = LabelTextures.shared.text(label, size: 9, mono: true, color: ThemeHex.text0)
            let sprite = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
            sprite.anchorPoint = CGPoint(x: 1, y: 0.5)
            sprite.position = CGPoint(x: 56, y: 0)
            sprite.name = "askLabel"
            asks.addChild(sprite)
        }
    }

    /// The long table and its twelve chairs (`OfficeLayout.reviewSeat(0..<12)`).
    private func buildReview(_ r: CGRect, _ layout: OfficeLayout) {
        // The table is where the layout's chairs say: 10 pt inside the end chairs, 8 pt inside the side rows.
        let ends = (layout.reviewSeat(10), layout.reviewSeat(11)), sides = (layout.reviewSeat(0), layout.reviewSeat(5))
        let size = CGSize(width: ends.1.x - ends.0.x - 20, height: sides.1.y - sides.0.y - 16)
        let table = stretched(OfficeTextures.table, to: size)
        table.position = CGPoint(x: (ends.0.x + ends.1.x) / 2, y: -(sides.0.y + sides.1.y) / 2)
        furniture.addChild(table)
        let mid = room.rect.mid
        for i in 0..<OfficeLayout.reviewSeats {
            let seat = layout.reviewSeat(i)
            let p = CGPoint(x: seat.x, y: -seat.y)
            if i >= 10 {
                put(OfficeTextures.chair, at: p, rotate: seat.x < mid.x ? -.pi / 2 : .pi / 2)
            } else {
                // Above the table the sitter faces down: the backrest is away from the viewer.
                put(OfficeTextures.chair, at: p, flipY: seat.y < mid.y)
            }
        }
        let light = SKSpriteNode(color: MapPalette.color(ThemeHex.bg4), size: CGSize(width: 8, height: 3))
        light.position = CGPoint(x: room.door.x + 14, y: -room.door.y - 10)
        light.name = "doorLight"
        addChild(light)
        doorLight = light
    }

    /// The meeting on in the review room: the door light and its title (cleaned by the model), or nil.
    func setMeeting(_ title: String?) {
        doorLit = title != nil
        guard title != meetingTitle else { return }
        meetingTitle = title
        meetingLabel?.removeFromParent()
        meetingLabel = nil
        guard let title, doorLight != nil else { return }
        let text = OrgCardNode.fit(title, width: rect.width / 2 - 24, size: 8, mono: true)
        let texture = LabelTextures.shared.text(text, size: 8, mono: true, color: ThemeHex.accent)
        let label = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
        label.anchorPoint = CGPoint(x: 0, y: 0.5)
        label.position = CGPoint(x: room.door.x + 22, y: -room.door.y - 10)
        label.name = "meetingTitle"
        addChild(label)
        meetingLabel = label
    }

    private func applyDoorLight() {
        doorLight?.color = MapPalette.color(doorLit ? ThemeHex.accent : ThemeHex.bg4)
    }

    private func applyCount() {
        countLabel?.removeFromParent()
        countLabel = nil
        guard count > 0 else { return }
        let texture = LabelTextures.shared.text("\(count)", size: 10, weight: .semibold, mono: true, color: ThemeHex.text0)
        let backing = SKSpriteNode(color: MapPalette.color(ThemeHex.bg4), size: CGSize(width: OrgCardNode.points(texture).width + 6,
                                                                                         height: 14))
        let label = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
        backing.addChild(label)
        let outside: CGFloat = doorOnTop ? 10 : -10
        backing.position = CGPoint(x: room.door.x, y: -room.door.y + outside)
        backing.zPosition = OfficeZ.overlay
        backing.name = "doorCount"
        addChild(backing)
        countLabel = backing
    }

    /// A counter, the sofa, and the wall of fame on its shelf.
    private func buildBreak(_ r: CGRect, _ layout: OfficeLayout) {
        let counter = OfficeTextures.counter
        put(counter, at: CGPoint(x: r.minX + 12 + OfficeTextures.points(counter).width / 2, y: r.maxY - 32))
        put(OfficeTextures.sofa, at: CGPoint(x: r.maxX - 36, y: r.midY + 6))
        let spot = layout.fameShelf()
        let board = SKSpriteNode(texture: OfficeTextures.shelf, size: OfficeTextures.points(OfficeTextures.shelf))
        board.position = CGPoint(x: spot.x, y: -spot.y)
        furniture.addChild(board)
        shelf.position = board.position
        shelf.zPosition = 1
        addChild(shelf)
    }

    /// Up to `OfficeScene.fameLimit` perk glyphs on the shelf, left to right.
    func setFame(_ glyphs: [String]) {
        let glyphs = Array(glyphs.prefix(OfficeScene.fameLimit))
        guard glyphs != fame else { return }
        fame = glyphs
        shelf.removeAllChildren()
        let pitch: CGFloat = 12
        for (k, g) in glyphs.enumerated() {
            let texture = LabelTextures.shared.emoji(OrgCardNode.fit(g, width: 16, size: 10, mono: false), size: 10)
            let sprite = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
            sprite.position = CGPoint(x: (CGFloat(k) - CGFloat(OfficeScene.fameLimit - 1) / 2) * pitch, y: 1)
            sprite.name = "fame"
            shelf.addChild(sprite)
        }
    }

    /// The mail counter: three lines of nine parcel spots (`OfficeLayout.mailCounter`).
    private func buildMail(_ r: CGRect) {
        let counter = stretched(OfficeTextures.counter, to: CGSize(width: r.width - 16, height: 52))
        counter.position = CGPoint(x: r.midX, y: r.midY - 3)
        furniture.addChild(counter)
        mail.zPosition = 1
        addChild(mail)
    }

    /// One parcel per shipping item at `spots`, its strap `blocked` once the checks failed.
    func setParcels(_ phases: [MapItemPhase], spots: [CGPoint]) {
        mail.removeAllChildren()
        parcels = phases.count
        for (phase, p) in zip(phases, spots) {
            let size = OfficeTextures.points(OfficeTextures.parcel)
            let parcel = SKSpriteNode(texture: OfficeTextures.parcel, size: size)
            parcel.position = p
            parcel.name = "parcel"
            let strap = SKSpriteNode(texture: OfficeTextures.parcelStrap(failed: phase == .failed), size: size)
            parcel.addChild(strap)
            mail.addChild(parcel)
        }
    }
}

// MARK: - Pod

/// A team's carpet (its department colour at `officeCarpetAlpha`), the title in the band above it, and the pin board in
/// the head row. Drawn in scene coordinates (the node stays at the origin).
///
/// A pod with a head desk has its manager sitting at the top centre, and that figure (and its bubble) reaches into the
/// title band: the title then keeps to the band's left half, cut to its team part (`TEAM-1` of `TEAM-1 · ENGINEERING`;
/// the carpet carries the department) when the whole title does not fit there.
@MainActor
final class OfficePodNode: SKNode {
    let pod: OfficePod
    private(set) var title = ""
    /// The title's frame in scene coordinates.
    private(set) var labelFrame = CGRect.zero

    init(pod: OfficePod, hasHead: Bool) {
        self.pod = pod
        super.init()
        let r = OfficeScene.sceneRect(pod.rect)
        let carpet = SKSpriteNode(color: MapPalette.department(pod.department), size: r.size)
        carpet.alpha = CGFloat(ThemeHex.officeCarpetAlpha)
        carpet.position = CGPoint(x: r.midX, y: r.midY)
        // Under the walls and desks: the room-floor depth.
        carpet.zPosition = -2
        carpet.name = "carpet"
        addChild(carpet)

        let band = OfficeScene.sceneRect(pod.labelRect)
        if hasHead {
            // Left of the head figure: the band's half less the figure's half-width and a margin.
            let width = band.width / 2 - OfficeTextures.figureSize.width / 2 - 4
            title = OrgCardNode.fit(pod.title, width: width, size: 10, mono: true)
            if title != pod.title, let team = pod.title.components(separatedBy: " · ").first, team != pod.title {
                title = OrgCardNode.fit(team, width: width, size: 10, mono: true)
            }
        } else {
            title = OrgCardNode.fit(pod.title, width: band.width - 4, size: 10, mono: true)
        }
        let texture = LabelTextures.shared.text(title, size: 10, mono: true, color: ThemeHex.text2)
        let label = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
        label.anchorPoint = CGPoint(x: 0, y: 0.5)
        label.position = CGPoint(x: band.minX + 1, y: band.midY)
        label.name = "podLabel"
        addChild(label)
        labelFrame = label.frame

        let board = SKSpriteNode(texture: OfficeTextures.pinBoard, size: OfficeTextures.points(OfficeTextures.pinBoard))
        board.position = CGPoint(x: pod.board.x, y: -pod.board.y)
        board.name = "pinBoard"
        addChild(board)
    }

    required init?(coder: NSCoder) { fatalError("OfficePodNode is built in code") }
}
