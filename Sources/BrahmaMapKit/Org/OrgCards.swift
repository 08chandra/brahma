import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

/// One card of the org chart: an agent, Board, an open seat, or a collapsed subtree's stub. `OrgScene` keeps one node
/// per id and re-`configure`s it when its content changes; a node that leaves the chart goes to a pool and is reused.
///
/// Coordinates are relative to the card's centre, y up. The contents split into the always-visible parts (border, fill,
/// status bar) and `details` (text, chips, meter), which are hidden below `OrgScene.textZoom`; `itemLine` (the current
/// item or a vacancy's note) shows from `OrgScene.itemZoom`.
///
/// Every string that reaches a texture goes through `fit`, which is `MapText.clean` with a cluster cap chosen to fit the
/// card: handles, roles, items, notes, trust labels and perk emoji (the model cleaned them already; this is the second
/// gate), and the fixed labels (`BOARD`, `▸ 3 REPORTS`).
@MainActor
final class OrgCardNode: SKNode {
    struct Segment: Equatable {
        var color: UInt32
        var count: Int
    }

    enum Content: Equatable {
        /// `expanded`: a manager whose reports are drawn, which shows `▾`.
        case agent(MapAgent, expanded: Bool)
        case board
        case vacancy(roleTitle: String, note: String)
        case stub(count: Int, segments: [Segment])
    }

    static let pulseKey = "pulse"
    static let hireKey = "hire"
    static let chipPopKey = "chipPop"
    /// Hire: the card grows from 60 % and fades in over this long, with an accent halo that fades with it.
    static let hireDuration = 0.4
    /// A state change flashes the status bar for this long.
    static let flashDuration = 0.2
    /// A promotion pops the trust chip from 1.4× back to 1× in this long.
    static let chipPopDuration = 0.2

    private(set) var content: Content?
    private(set) var cardSize = CGSize(width: OrgLayout.card.w, height: OrgLayout.card.h)
    /// The bordering sprite (a colored rect behind the fill): `line`, `blocked` for a blocked agent, `accent` for Board.
    private(set) var border = SKSpriteNode()
    private(set) var statusBar = SKSpriteNode()
    let details = SKNode()
    let itemLine = SKNode()
    private var isBoard = false
    /// A vacancy's title label (centered while the note is hidden).
    private(set) var vacancyTitle: SKSpriteNode?
    private var vacancyHasNote = false
    /// The previous status bar of a card that stays running, carried over so its pulse keeps its phase.
    private var reusableBar: SKSpriteNode?

    override init() {
        super.init()
        details.name = "details"
        itemLine.name = "itemLine"
    }

    required init?(coder: NSCoder) { fatalError("OrgCardNode is built in code") }

    // MARK: Configure

    /// Rebuilds the sprites when `content` changed; a no-op otherwise. The node's own actions (a reorg glide) are left
    /// alone: a live update must never cancel or strand one. A running agent whose card stays running keeps its status
    /// bar, so the pulse does not restart on an unrelated change.
    func configure(_ content: Content, zoom: Double) {
        guard content != self.content else { setZoom(zoom); return }
        var keptBar: SKSpriteNode?
        if case .agent(let old, _)? = self.content, case .agent(let new, _) = content,
           Self.displayState(old) == .running, Self.displayState(new) == .running {
            keptBar = statusBar
        }
        clear()
        reusableBar = keptBar
        self.content = content
        switch content {
        case .agent(let agent, let expanded): buildAgent(agent, expanded: expanded)
        case .board: buildBoard()
        case .vacancy(let title, let note): buildVacancy(title: title, note: note)
        case .stub(let count, let segments): buildStub(count: count, segments: segments)
        }
        reusableBar = nil
        setZoom(zoom)
    }

    /// Back to a blank node, ready for the pool: also drops the node's actions (the glide).
    func reset() {
        removeAllActions()
        setScale(1)
        clear()
    }

    /// Drops every sprite and the content, keeping the node's actions.
    private func clear() {
        removeAllChildren()
        details.removeAllChildren()
        itemLine.removeAllChildren()
        // A hire is fading the card in: a content change in the middle must not make it blink to full.
        if action(forKey: Self.hireKey) == nil { alpha = 1 }
        isBoard = false
        content = nil
        border = SKSpriteNode()
        statusBar = SKSpriteNode()
        vacancyTitle = nil
    }

    /// The text level of detail and (for Board) the zoom-compensated border.
    func setZoom(_ zoom: Double) {
        details.isHidden = zoom < OrgScene.textZoom
        itemLine.isHidden = zoom < OrgScene.itemZoom
        if isBoard { sizeBoardBorder(zoom) }
        // A vacancy's title sits above its note; with the note hidden it centers.
        vacancyTitle?.position.y = vacancyHasNote && zoom >= OrgScene.itemZoom ? 6 : 0
    }

    // MARK: Agent

    /// A paused agent that is not killed renders like a sleeping one (the model's `displayState`, which is not public).
    static func displayState(_ agent: MapAgent) -> AgentState {
        agent.paused && agent.state != .killed ? .sleeping : agent.state
    }

    private func buildAgent(_ agent: MapAgent, expanded: Bool) {
        let w = OrgLayout.card.w, h = OrgLayout.card.h
        cardSize = CGSize(width: w, height: h)
        let state = Self.displayState(agent)
        let borderHex = state == .blocked ? ThemeHex.blocked : ThemeHex.line
        border = rect(borderHex, w, h)
        border.name = "border"
        addChild(border)
        addChild(rect(ThemeHex.bg2, w - 2, h - 2, name: "fill"))
        let kept = reusableBar
        statusBar = kept ?? rect(ThemeHex.status(agent.state, paused: agent.paused), 3, h - 2, at: CGPoint(x: -w / 2 + 2.5, y: 0))
        statusBar.name = "statusBar"
        addChild(statusBar)
        if state == .running, kept == nil {
            let pulse = SKAction.sequence([
                .fadeAlpha(to: 0.6, duration: 0.5),
                .fadeAlpha(to: 1.0, duration: 0.5),
            ])
            pulse.timingMode = .easeInEaseOut
            statusBar.run(.repeatForever(pulse), withKey: Self.pulseKey)
        }
        if state == .killed { alpha = 0.4 }
        addChild(details)
        addChild(itemLine)

        let left = -w / 2 + 9, right = w / 2 - 5
        // Line 1: the handle, the trust chip on the right.
        var handleRight = right
        if let trust = agent.trust {
            let chip = trustChip(trust, rightEdge: right, y: 12)
            handleRight = chip.minX - 4
        }
        let handleText = Self.fit(agent.handle, width: handleRight - left, size: 11, mono: true)
        let handle = label(handleText, size: 11, mono: true, color: ThemeHex.text0, left: left, y: 12)
        details.addChild(handle)
        if state == .killed {
            let strike = rect(ThemeHex.text0, handle.size.width - 2, 1, at: CGPoint(x: left + (handle.size.width - 2) / 2, y: 12))
            strike.name = "strike"
            details.addChild(strike)
        }

        // Line 2: the role, up to two perk emoji on the right.
        var roleRight = right
        var perkX = right
        for perk in agent.perks.prefix(2).reversed() {
            let texture = LabelTextures.shared.emoji(Self.fit(perk, width: 16, size: 10, mono: false), size: 10)
            let sprite = SKSpriteNode(texture: texture, size: Self.points(texture))
            sprite.anchorPoint = CGPoint(x: 1, y: 0.5)
            sprite.position = CGPoint(x: perkX + 1, y: -1)
            sprite.name = "perk"
            details.addChild(sprite)
            perkX -= sprite.size.width + 1
            roleRight = perkX - 3
        }
        let roleText = Self.fit(agent.role, width: roleRight - left, size: 10, mono: false)
        details.addChild(label(roleText, size: 10, mono: false, color: ThemeHex.text1, left: left, y: -1))

        // Bottom right: the expanded marker, then the meter bar.
        var bottomRight = right
        if expanded {
            let marker = label(Self.fit("▾", width: 12, size: 9, mono: true), size: 9, mono: true, color: ThemeHex.text2,
                               right: right, y: -15)
            details.addChild(marker)
            bottomRight = right - marker.size.width - 2
        }
        if let meter = agent.meter, let fraction = meter.fraction {
            let track = rect(ThemeHex.line, 40, 3, at: CGPoint(x: bottomRight - 20, y: -18.5))
            track.name = "meterBar"
            details.addChild(track)
            let fillColor = fraction >= 0.8 ? ThemeHex.success : fraction >= 0.5 ? ThemeHex.text1 : ThemeHex.danger
            let fillWidth = Swift.max(0, fraction * 40)
            if fillWidth > 0 {
                let fill = rect(fillColor, fillWidth, 3, at: CGPoint(x: bottomRight - 40 + fillWidth / 2, y: -18.5))
                fill.name = "meterFill"
                details.addChild(fill)
            }
            bottomRight -= 44
        }
        // Line 3 (zoom ≥ 1.2): the current item.
        if let item = agent.item {
            let text = Self.fit(item, width: bottomRight - left, size: 9, mono: true)
            itemLine.addChild(label(text, size: 9, mono: true, color: ThemeHex.text2, left: left, y: -14))
        }
    }

    /// The chip's frame in card coordinates. The sprite named `trustChip` is its border and carries the tier color.
    @discardableResult
    private func trustChip(_ trust: MapTrust, rightEdge: CGFloat, y: CGFloat) -> CGRect {
        let hex = ThemeHex.trustTier(trust.tier)
        let text = Self.fit(trust.label, width: 28, size: 9, mono: true)
        let texture = LabelTextures.shared.text(text, size: 9, weight: .semibold, mono: true, color: hex)
        let size = Self.points(texture)
        let w = size.width + 4, h: CGFloat = 13
        let frame = CGRect(x: rightEdge - w, y: y - h / 2, width: w, height: h)
        // One group per chip, centred on the chip, so a promotion can pop it as a whole.
        let group = SKNode()
        group.name = "trustChipGroup"
        group.position = CGPoint(x: frame.midX, y: y)
        let chipBorder = rect(hex, w, h)
        chipBorder.name = "trustChip"
        group.addChild(chipBorder)
        group.addChild(rect(ThemeHex.bg2, w - 2, h - 2))
        group.addChild(rect(hex, w - 2, h - 2, alpha: 0.15))
        let sprite = SKSpriteNode(texture: texture, size: size)
        group.addChild(sprite)
        details.addChild(group)
        return frame
    }

    // MARK: Event animations

    /// A state change: a `text0` overlay on the status bar that fades out over `flashDuration`. It sits on top of the bar
    /// (which may be pulsing), so nothing has to be restored afterwards.
    func flashStatusBar() {
        guard case .agent? = content else { return }
        childNode(withName: "barFlash")?.removeFromParent()
        let flash = SKSpriteNode(color: MapPalette.color(ThemeHex.text0), size: statusBar.size)
        flash.position = statusBar.position
        flash.name = "barFlash"
        addChild(flash)
        flash.run(.sequence([.fadeOut(withDuration: Self.flashDuration), .removeFromParent()]))
    }

    /// A hire: scale 0.6 → 1 and fade in over `hireDuration`, with an accent rim (a slightly larger `accent` rect behind the
    /// card) that fades out over the same time.
    func playHire() {
        removeAction(forKey: Self.hireKey)
        childNode(withName: "hireFlash")?.removeFromParent()
        let halo = SKSpriteNode(color: MapPalette.color(ThemeHex.accent),
                                size: CGSize(width: cardSize.width + 4, height: cardSize.height + 4))
        halo.name = "hireFlash"
        insertChild(halo, at: 0)
        halo.run(.sequence([.fadeOut(withDuration: Self.hireDuration), .removeFromParent()]))
        setScale(0.6)
        alpha = 0
        let grow = SKAction.scale(to: 1, duration: Self.hireDuration)
        grow.timingMode = .easeOut
        run(.group([grow, .fadeIn(withDuration: Self.hireDuration)]), withKey: Self.hireKey)
    }

    /// A promotion: the chip (already showing the new label and tier color) pops from 1.4× to 1×.
    func popTrustChip() {
        guard let chip = details.childNode(withName: "trustChipGroup") else { return }
        chip.removeAction(forKey: Self.chipPopKey)
        chip.setScale(1.4)
        let settle = SKAction.scale(to: 1, duration: Self.chipPopDuration)
        settle.timingMode = .easeOut
        chip.run(settle, withKey: Self.chipPopKey)
    }

    // MARK: Board, vacancy, stub

    private func buildBoard() {
        let w = OrgLayout.card.w, h = OrgLayout.card.h
        cardSize = CGSize(width: w, height: h)
        isBoard = true
        border = rect(ThemeHex.accent, w, h)
        border.name = "border"
        addChild(border)
        addChild(rect(ThemeHex.bg2, w, h, name: "fill"))
        addChild(details)
        addChild(itemLine)
        let left = -w / 2 + 12
        details.addChild(label(Self.fit("BOARD", width: 120, size: 11, mono: true), size: 11, mono: true, color: ThemeHex.text0,
                               left: left, y: 7))
        details.addChild(label(Self.fit("OWNER", width: 120, size: 10, mono: false), size: 10, mono: false,
                               color: ThemeHex.text1, left: left, y: -8))
    }

    /// Board's border is 2 screen pixels whatever the zoom (a hairline would vanish on the zoomed-out chart).
    private func sizeBoardBorder(_ zoom: Double) {
        let t = Swift.min(8, Swift.max(1, 2 / CGFloat(zoom)))
        border.size = CGSize(width: cardSize.width + 2 * t, height: cardSize.height + 2 * t)
    }

    private func buildVacancy(title: String, note: String) {
        let w = OrgLayout.vacancy.w, h = OrgLayout.vacancy.h
        cardSize = CGSize(width: w, height: h)
        addChild(rect(ThemeHex.bg1, w, h, name: "fill"))
        let outline = CGPath(rect: CGRect(x: -w / 2 + 0.5, y: -h / 2 + 0.5, width: w - 1, height: h - 1), transform: nil)
        let dashed = SKShapeNode(path: outline.copy(dashingWithPhase: 0, lengths: [4, 3]))
        dashed.strokeColor = MapPalette.color(ThemeHex.lineStrong)
        dashed.fillColor = .clear
        dashed.lineWidth = 1
        dashed.isAntialiased = false
        dashed.name = "dashedBorder"
        addChild(dashed)
        addChild(details)
        addChild(itemLine)
        let left = -w / 2 + 8
        let text = Self.fit(("OPEN · " + title).uppercased(), width: w - 16, size: 10, mono: true)
        let titleSprite = label(text, size: 10, mono: true, color: ThemeHex.text2, left: left, y: 0)
        details.addChild(titleSprite)
        vacancyTitle = titleSprite
        vacancyHasNote = !note.isEmpty
        if !note.isEmpty {
            itemLine.addChild(label(Self.fit(note, width: w - 16, size: 9, mono: true), size: 9, mono: true,
                                    color: ThemeHex.text2, left: left, y: -7))
        }
    }

    private func buildStub(count: Int, segments: [Segment]) {
        let w = OrgLayout.stub.w, h = OrgLayout.stub.h
        cardSize = CGSize(width: w, height: h)
        addChild(details)
        addChild(itemLine)
        let words = count == 1 ? "REPORT" : "REPORTS"
        details.addChild(label(Self.fit("▸ \(count) \(words)", width: w - 4, size: 10, mono: true), size: 10, mono: true,
                               color: ThemeHex.text1, left: -w / 2 + 2, y: 3.5))
        // The state micro-bar: 148 × 3, segments proportional to the subtree's counts.
        let y = -h / 2 + 1.5
        let total = segments.reduce(0) { $0 + $1.count }
        guard total > 0 else {
            addChild(rect(ThemeHex.line, w, 3, at: CGPoint(x: 0, y: y), name: "microBar"))
            return
        }
        let widths = Self.apportion(segments.map(\.count), total: Int(w))
        var x = -w / 2
        for (segment, width) in zip(segments, widths) where width > 0 {
            let part = rect(segment.color, CGFloat(width), 3, at: CGPoint(x: x + CGFloat(width) / 2, y: y), name: "microBar")
            addChild(part)
            x += CGFloat(width)
        }
    }

    /// `counts` scaled to whole `total` points by largest remainder; every nonzero count keeps at least one point.
    static func apportion(_ counts: [Int], total: Int) -> [Int] {
        let sum = counts.reduce(0, +)
        guard sum > 0, total > 0 else { return counts.map { _ in 0 } }
        var result = counts.map { $0 * total / sum }
        var remainders = counts.enumerated().map { ($0.offset, ($0.element * total) % sum) }
        remainders.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        var left = total - result.reduce(0, +)
        for (i, _) in remainders where left > 0 { result[i] += 1; left -= 1 }
        for i in result.indices where counts[i] > 0 && result[i] == 0 {
            if let widest = result.indices.max(by: { result[$0] < result[$1] }), result[widest] > 1 {
                result[widest] -= 1; result[i] = 1
            }
        }
        return result
    }

    // MARK: Sprites

    private func rect(_ hex: UInt32, _ w: CGFloat, _ h: CGFloat, alpha: CGFloat = 1, at p: CGPoint = .zero,
                      name: String? = nil) -> SKSpriteNode {
        let sprite = SKSpriteNode(color: MapPalette.color(hex), size: CGSize(width: w, height: h))
        sprite.alpha = alpha
        sprite.position = p
        sprite.name = name
        return sprite
    }

    /// A text sprite whose left (or right) edge of the glyphs is at `left` (`right`); the texture has 1 pt of padding.
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool, color: UInt32,
                       left: CGFloat? = nil, right: CGFloat? = nil, y: CGFloat) -> SKSpriteNode {
        let texture = LabelTextures.shared.text(text, size: size, weight: weight, mono: mono, color: color)
        let sprite = SKSpriteNode(texture: texture, size: Self.points(texture))
        if let left {
            sprite.anchorPoint = CGPoint(x: 0, y: 0.5)
            sprite.position = CGPoint(x: left - 1, y: y)
        } else if let right {
            sprite.anchorPoint = CGPoint(x: 1, y: 0.5)
            sprite.position = CGPoint(x: right + 1, y: y)
        }
        return sprite
    }

    static func points(_ texture: SKTexture) -> CGSize {
        let s = texture.size()
        return CGSize(width: s.width / LabelTextures.scale, height: s.height / LabelTextures.scale)
    }

    // MARK: Fitting text

    /// `s` cut to the most clusters that fit in `width` points: `MapText.clean(s, max:)`, so a cut ends in "…" and the
    /// result is clean whatever the caller passed.
    static func fit(_ s: String, width: CGFloat, size: CGFloat, mono: Bool, weight: NSFont.Weight = .regular) -> String {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        func measure(_ text: String) -> CGFloat { NSAttributedString(string: text, attributes: [.font: font]).size().width }
        let clusters = Swift.max(1, s.count)
        let average = mono ? size * 0.6 : size * 0.5
        var cap = Swift.min(clusters, Swift.max(1, Int(width / average) + 2))
        var text = MapText.clean(s, max: cap)
        while cap > 1, measure(text) > width {
            cap -= 1
            text = MapText.clean(s, max: cap)
        }
        return text
    }
}

// MARK: - Batched dotted lines

@MainActor
enum DottedTexture {
    /// A dashed quadratic curve between two points, bowed to one side.
    static func control(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = Swift.max(1, (dx * dx + dy * dy).squareRoot())
        let bow = Swift.min(80, distance * 0.2)
        return CGPoint(x: (a.x + b.x) / 2 - dy / distance * bow, y: (a.y + b.y) / 2 + dx / distance * bow)
    }

    /// One texture holding every curve of a kind, and the scene rect it covers. Resolution is 2 px/pt, lowered so one
    /// texture stays within 6 M pixels and 8192 on a side. Nil when there are no curves.
    static func render(_ curves: [(CGPoint, CGPoint)], color: UInt32) -> (texture: SKTexture, bounds: CGRect)? {
        guard !curves.isEmpty else { return nil }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for (a, b) in curves {
            for p in [a, b, control(a, b)] {
                minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
                minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
            }
        }
        let bounds = CGRect(x: minX - 4, y: minY - 4, width: maxX - minX + 8, height: maxY - minY + 8)
        let area = bounds.width * bounds.height
        let scale = Swift.min(2, (6_000_000 / Swift.max(1, area)).squareRoot(), 8192 / Swift.max(bounds.width, bounds.height))
        let width = Swift.max(1, Int((bounds.width * scale).rounded(.up)))
        let height = Swift.max(1, Int((bounds.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setStrokeColor(MapPalette.color(color).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 4])
        for (a, b) in curves {
            context.move(to: a)
            let c = control(a, b)
            context.addQuadCurve(to: b, control: c)
            context.strokePath()
        }
        guard let image = context.makeImage() else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        return (texture, bounds)
    }
}
