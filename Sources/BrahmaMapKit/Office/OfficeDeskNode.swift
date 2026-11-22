import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

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

    /// A pod's head desk (its manager's, alone at the top of the pod): the Reduce Motion badge goes to its right, clear of
    /// the first row's seated figures below-left. Set before `configure`.
    var isHead = false {
        didSet { if isHead != oldValue { content = nil } }
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
    /// Where each desk item rests (a leave slides them into the box from here).
    private var perkHomes: [CGPoint] = []
    private var leaveBox: SKSpriteNode?
    /// A Reduce Motion event flash is playing on the badge (or the monitor of a desk without one).
    private(set) var isFlashing = false

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

    /// Back to a blank node for the pool; also drops the glide (and a hire's fade-in).
    func reset() {
        removeAllActions()
        clear()
        facesDown = false
        isHead = false
        alpha = 1
    }

    /// The next `configure` rebuilds the desk even if its content did not change (after a leave or flash was cut short).
    func invalidate() { content = nil }

    /// The far corner of the top where the desk items sit: a promotion's trophy pops here.
    var cornerPoint: CGPoint { CGPoint(x: OfficeLayout.desk.w / 2 - 5, y: plan.perkY) }

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
        perkHomes = []
        leaveBox = nil
        isFlashing = false
        halo = SKSpriteNode()
    }

    // MARK: Agent

    /// Where things sit on the top, by orientation: the monitor, lamp and desk items on the far side from the sitter;
    /// the handle and role bands between the monitor and the sitter, clear of the seated figure's frame (which starts
    /// 5 pt short of the seat, 19 pt from the desk's centre), of its bubble (beside the body) and of the badge (beyond the
    /// desk's left edge, on the monitor's side). The desk items keep to the far corner strip beside the monitor, between
    /// the handle (or role) band and the desk's edge, `perkHeight` tall.
    private struct Plan {
        var monitorY: CGFloat, handleY: CGFloat, roleY: CGFloat, badgeY: CGFloat, perkY: CGFloat
    }

    private var plan: Plan {
        facesDown ? Plan(monitorY: -6, handleY: 9.5, roleY: 1.5, badgeY: -8, perkY: -6)
            : Plan(monitorY: 11.5, handleY: 3.5, roleY: -4, badgeY: 13, perkY: 11.75)
    }

    /// A desk item's glyph height: the strip between a label band and the desk's far edge.
    static let perkHeight: CGFloat = 7

    /// The badge's centre: beyond the desk's left edge on the monitor's side; a head desk's beside its right edge, level
    /// with the desk's middle, where nothing sits (the first row's figures are below it, the pin board left of it).
    private var badgeCenter: CGPoint {
        isHead ? CGPoint(x: OfficeLayout.desk.w / 2 + 12, y: -2) : CGPoint(x: -OfficeLayout.desk.w / 2 - 5, y: plan.badgeY)
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
        monitor.name = "monitor"
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
        // The desk items: 10 pt glyphs drawn `perkHeight` tall in the far corner, right to left from the desk's edge.
        var x = CGFloat(OfficeLayout.desk.w / 2) - 1
        for perk in agent.perks.prefix(2).reversed() {
            let texture = LabelTextures.shared.emoji(OrgCardNode.fit(perk, width: 16, size: 10, mono: false), size: 10)
            let natural = OrgCardNode.points(texture)
            let scale = natural.height > 0 ? Self.perkHeight / natural.height : 1
            let glyph = SKSpriteNode(texture: texture, size: CGSize(width: natural.width * scale, height: Self.perkHeight))
            glyph.anchorPoint = CGPoint(x: 1, y: 0.5)
            glyph.position = CGPoint(x: x, y: p.perkY)
            glyph.name = "perk"
            items.addChild(glyph)
            perkHomes.append(glyph.position)
            x -= glyph.size.width
            itemSprites += 1
        }
        addChild(items)

        if reduceMotion, let glyph = Self.badge(activity) {
            badge = glyph
            let at = badgeCenter
            badgeRect = CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)
            // Just outside the desk's edge, beside the lamp (a head desk's beside its right edge): off the label bands.
            let chip = sprite(OfficeTextures.badge(glyph), at: at)
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

    /// The desk items showing now, in the parent's coordinates.
    var perkFrames: [CGRect] {
        guard !items.isHidden, items.parent != nil else { return [] }
        return items.children.filter { $0.name == "perk" }.map { $0.frame.offsetBy(dx: position.x, dy: position.y) }
    }

    // MARK: Effects (driven by the scene on map time, OfficeMotion.swift)

    /// The leave (spec §5.4) at fraction `t` of its 1.5 s: the desk items slide into a box that fades in where a former
    /// agent's box sits, the screen glow and the lamp go out.
    func setLeaving(_ t: CGFloat) {
        let t = Swift.min(1, Swift.max(0, t))
        let boxAt = CGPoint(x: 7, y: plan.monitorY)
        if leaveBox == nil {
            let box = sprite(OfficeTextures.box, at: boxAt)
            box.alpha = 0
            box.name = "leaveBox"
            addChild(box)
            leaveBox = box
            halo.removeAction(forKey: Self.pulseKey)
        }
        leaveBox?.alpha = t
        for (glyph, home) in zip(items.children.filter { $0.name == "perk" }, perkHomes) {
            glyph.position = CGPoint(x: home.x + (boxAt.x + 4 - home.x) * t, y: home.y + (boxAt.y - home.y) * t)
            glyph.alpha = 1 - t
        }
        halo.alpha = 1 - t
        childNode(withName: "lampGlow")?.alpha = 0.7 * (1 - t)
        if t >= 0.5, let lamp = childNode(withName: "lamp") as? SKSpriteNode {
            lamp.color = MapPalette.color(ThemeHex.lineStrong)
            lampOn = false
        }
    }

    /// A Reduce Motion event (spec §5.6): the badge (or, on a desk without one, the monitor) dims and comes back over
    /// 0.2 s; `t` is the fraction played, nil when it is over.
    func setFlash(_ t: CGFloat?) {
        let target = childNode(withName: "badge") ?? childNode(withName: "monitor")
        isFlashing = t != nil
        target?.alpha = t.map { 0.3 + 0.7 * Swift.min(1, Swift.max(0, $0)) } ?? 1
    }

    /// A state change (spec §5.4): the screen cross-fades in to its new colour in `duration`.
    func crossFadeScreen(duration: TimeInterval) {
        guard let monitor = childNode(withName: "monitor") else { return }
        monitor.removeAction(forKey: "crossFade")
        monitor.alpha = 0.3
        monitor.run(.fadeAlpha(to: 1, duration: duration), withKey: "crossFade")
    }
}
