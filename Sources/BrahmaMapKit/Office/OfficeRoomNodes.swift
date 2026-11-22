import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

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
    private var parcelList: [Parcel] = []
    private var parcelSpots: [CGPoint] = []
    private var parcelNodes: [String: SKSpriteNode] = [:]
    private var parcelKeys: [String: String] = [:]
    private var showsKeys = false

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

    private func put(_ texture: SKTexture, at p: CGPoint, flipY: Bool = false, rotate: CGFloat = 0, name: String? = nil) {
        let s = SKSpriteNode(texture: texture, size: OfficeTextures.points(texture))
        s.position = p
        s.name = name
        if flipY { s.yScale = -1 }
        s.zRotation = rotate
        furniture.addChild(s)
    }

    /// The board table with four chairs a side; the asks lie on it as folders.
    private func buildBoard(_ r: CGRect) {
        let table = stretched(OfficeTextures.table, to: CGSize(width: 120, height: 36))
        table.position = CGPoint(x: r.midX, y: r.midY - 4)
        table.name = "obstacle"
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
        table.name = "obstacle"
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

    /// The furniture routes walk around, as drawn (scene coordinates): it must match `OfficeLayout.furniture`.
    var obstacleFrames: [CGRect] { furniture.children.filter { $0.name == "obstacle" }.map(\.frame) }

    /// The sofa's centre in a break room of rect `r` (scene coordinates); idle figures sit on it (`OfficeLayout.sofaSeat`).
    static func sofaCenter(_ r: CGRect) -> CGPoint { CGPoint(x: r.maxX - 36, y: r.midY + 6) }

    /// A counter, the sofa, and the wall of fame on its shelf.
    private func buildBreak(_ r: CGRect, _ layout: OfficeLayout) {
        let counter = OfficeTextures.counter
        put(counter, at: CGPoint(x: r.minX + 12 + OfficeTextures.points(counter).width / 2, y: r.maxY - 32), name: "obstacle")
        put(OfficeTextures.sofa, at: Self.sofaCenter(r), name: "obstacle")
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
        counter.name = "obstacle"
        furniture.addChild(counter)
        mail.zPosition = 1
        addChild(mail)
    }

    /// One mail-room parcel: whose item it is, its phase (a failed check gives it a `blocked` strap), the item key it is
    /// labelled with (cleaned model text), and whether it is being stamped (the `✓` bubble of a passed check).
    struct Parcel: Equatable {
        var id: String
        var phase: MapItemPhase
        var key: String?
        var stamped: Bool
    }

    /// One parcel per shipping item at `spots`, reusing each item's node. A no-op when nothing changed: the scene calls it
    /// on every refresh. Keys alternate above and below the parcels so neighbours' keys do not run into each other.
    func setParcels(_ list: [Parcel], spots: [CGPoint]) {
        guard list != parcelList || spots != parcelSpots else { return }
        parcelList = list
        parcelSpots = spots
        parcels = list.count
        var next: [String: SKSpriteNode] = [:]
        let size = OfficeTextures.points(OfficeTextures.parcel)
        for (k, (item, p)) in zip(list, spots).enumerated() {
            let parcel: SKSpriteNode
            if let old = parcelNodes[item.id] {
                parcel = old
            } else {
                parcel = SKSpriteNode(texture: OfficeTextures.parcel, size: size)
                parcel.name = "parcel"
                let strap = SKSpriteNode(texture: OfficeTextures.parcelStrap(failed: false), size: size)
                strap.name = "strap"
                parcel.addChild(strap)
                let check = SKSpriteNode(texture: OfficeTextures.bubble(.check), size: OfficeTextures.points(OfficeTextures.bubble(.check)))
                check.anchorPoint = CGPoint(x: 0, y: 0)
                check.position = CGPoint(x: 1, y: size.height / 2)
                check.zPosition = 2
                check.name = "check"
                parcel.addChild(check)
                mail.addChild(parcel)
            }
            parcel.position = p
            (parcel.childNode(withName: "strap") as? SKSpriteNode)?.texture = OfficeTextures.parcelStrap(failed: item.phase == .failed)
            parcel.childNode(withName: "check")?.isHidden = !item.stamped
            parcel.childNode(withName: "key")?.removeFromParent()
            if let key = item.key {
                let text = OrgCardNode.fit(key, width: 28, size: 6, mono: true)
                let texture = LabelTextures.shared.text(text, size: 6, mono: true, color: ThemeHex.text1)
                let label = SKSpriteNode(texture: texture, size: OrgCardNode.points(texture))
                label.position = CGPoint(x: 0, y: k % 2 == 0 ? size.height / 2 + 3 : -size.height / 2 - 3)
                label.isHidden = !showsKeys
                label.name = "key"
                parcel.addChild(label)
                parcelKeys[item.id] = text
            } else {
                parcelKeys[item.id] = nil
            }
            next[item.id] = parcel
        }
        for (id, node) in parcelNodes where next[id] == nil {
            node.removeFromParent()
            parcelKeys[id] = nil
        }
        parcelNodes = next
    }

    /// The parcels' item keys show from `OfficeScene.itemZoom`, as the desks' roles do.
    func showKeys(_ on: Bool) {
        guard on != showsKeys else { return }
        showsKeys = on
        for node in parcelNodes.values { node.childNode(withName: "key")?.isHidden = !on }
    }

    /// The parcels in counter order (agent ids).
    var parcelIds: [String] { parcelList.map(\.id) }
    /// The parcels showing a `✓` bubble.
    var stampedParcels: Set<String> { Set(parcelList.filter(\.stamped).map(\.id)) }
    /// The strap colour of an item's parcel: `blocked` after a failed check, else `warning`; nil without a parcel.
    func strapColor(_ id: String) -> UInt32? {
        parcelList.first { $0.id == id }.map { $0.phase == .failed ? ThemeHex.blocked : ThemeHex.warning }
    }
    /// The key drawn on an item's parcel.
    func parcelKey(_ id: String) -> String? { parcelKeys[id] }
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
