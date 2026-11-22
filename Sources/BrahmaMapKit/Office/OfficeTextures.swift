import AppKit
import CoreGraphics
import SpriteKit
import BrahmaAppModel

/// The office's original art, drawn in code (spec §5.3, §7): flat shapes in `ThemeHex` tokens, outlines of one pixel
/// at most, no gradient except the lamp's radial glow, and a faceless "peg" figure whose only limbs are two 2 pt hands.
///
/// Every texture is drawn once with CoreGraphics at `scale`× (as `MotionTextures` and `LabelTextures` do) and cached,
/// so a sprite showing one is sized `points(texture)`. Textures meant to be tinted (`monitor(.lit)`, `lampGlow`,
/// `figureBody`, `badge`) are white, so `SKSpriteNode.color` with `colorBlendFactor = 1` gives the status or
/// department colour; every other texture already carries its token colours.
@MainActor
public enum OfficeTextures {
    /// Pixels per point of every texture.
    public static let scale: CGFloat = 2
    /// The whole figure, body and head, in points.
    public static let figureSize = CGSize(width: 10, height: 16)
    /// Where `figureHead` centres in a `figureSize` frame (origin bottom-left), above every pose's body.
    public static let headCenter = CGPoint(x: 5, y: 12.75)

    /// A monitor's screen: off (dark), dim (40 % white, tinted it is the status colour at 40 %), lit (white).
    public enum ScreenState { case off, dim, lit }
    /// The figure's frames: sitting, two typing frames, two walking frames, standing, and sitting with a raised hand.
    public enum FigurePose: CaseIterable { case sit, typeA, typeB, walkA, walkB, stand, raisedHand }
    /// A speech bubble's one glyph: `!` blocked, `…` waiting on the owner, `✓` checks passed.
    public enum BubbleGlyph: CaseIterable { case exclaim, ellipsis, check }
    /// A Reduce Motion state badge's glyph (spec §5.6): `▶` typing, `✎` reviewing, `✋` blocked, `…` waiting, `⏾` away.
    public enum BadgeGlyph: CaseIterable { case typing, reviewing, blocked, waiting, away }

    /// A texture's size in points.
    public static func points(_ t: SKTexture) -> CGSize {
        let size = t.size()
        return CGSize(width: size.width / scale, height: size.height / scale)
    }

    /// One device pixel, the widest outline any texture draws.
    private static let hair: CGFloat = 1 / scale

    // MARK: - Desks

    /// A desk top, 36 × 24 pt, with a keyboard toward its front edge.
    public static let deskTop: SKTexture = render(36, 24) { c in
        fill(c, CGRect(x: 0, y: 0, width: 36, height: 24), ThemeHex.officeDeskTop, radius: 1)
        outline(c, CGRect(x: 0, y: 0, width: 36, height: 24), ThemeHex.line, radius: 1)
        fill(c, CGRect(x: 12, y: 2.5, width: 12, height: 3.5), ThemeHex.bg4, radius: 0.5)
    }

    /// The desk's 6 pt front face, darker than its top.
    public static let deskFace: SKTexture = render(36, 6) { c in
        fill(c, CGRect(x: 0, y: 0, width: 36, height: 6), ThemeHex.officeDeskFace, radius: 1)
        outline(c, CGRect(x: 0, y: 0, width: 36, height: 6), ThemeHex.line, radius: 1)
    }

    /// An office chair seen from behind: the seat, and the backrest toward the viewer.
    public static let chair: SKTexture = render(12, 8) { c in
        fill(c, CGRect(x: 1, y: 2, width: 10, height: 6), ThemeHex.bg4, radius: 2)
        fill(c, CGRect(x: 0, y: 0, width: 12, height: 3), ThemeHex.lineStrong, radius: 1.5)
    }

    /// The desk monitor, 10 × 7 pt: a bezel on a short stand around the screen, the desk's state light.
    public static func monitor(_ state: ScreenState) -> SKTexture {
        switch state {
        case .off: monitorOff
        case .dim: monitorDim
        case .lit: monitorLit
        }
    }

    private static let monitorOff = drawMonitor(.off)
    private static let monitorDim = drawMonitor(.dim)
    private static let monitorLit = drawMonitor(.lit)

    private static func drawMonitor(_ state: ScreenState) -> SKTexture {
        render(10, 7) { c in
            fill(c, CGRect(x: 4, y: 0, width: 2, height: 1.5), ThemeHex.lineStrong)
            fill(c, CGRect(x: 0, y: 1, width: 10, height: 6), ThemeHex.lineStrong, radius: 1)
            let screen = CGRect(x: 0.5, y: 1.5, width: 9, height: 5)
            switch state {
            case .off:
                fill(c, screen, ThemeHex.bg1, radius: 0.5)
            case .dim:
                fill(c, screen, ThemeHex.bg1, radius: 0.5)
                c.setFillColor(NSColor.white.withAlphaComponent(0.4).cgColor)
                c.addPath(CGPath(roundedRect: screen, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
                c.fillPath()
            case .lit:
                c.setFillColor(NSColor.white.cgColor)
                c.addPath(CGPath(roundedRect: screen, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
                c.fillPath()
            }
        }
    }

    /// The soft pool of light a lit desk throws, 48 pt: the one gradient in the office. White, tinted by the caller.
    public static let lampGlow: SKTexture = render(48, 48) { c in
        let white = NSColor.white
        let colors = [white.withAlphaComponent(0.55).cgColor, white.withAlphaComponent(0.2).cgColor,
                      white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.4, 1]) else { return }
        let center = CGPoint(x: 24, y: 24)
        c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 24, options: [])
    }

    /// The light a lit screen throws on its desk, 40 pt: a white core that holds near full strength, then a soft falloff.
    /// White, tinted by the status colour.
    public static let screenGlow: SKTexture = render(40, 40) { c in
        let white = NSColor.white
        let colors = [white.cgColor, white.withAlphaComponent(0.92).cgColor, white.withAlphaComponent(0.3).cgColor,
                      white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.4, 0.7, 1]) else { return }
        let center = CGPoint(x: 20, y: 20)
        c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 20, options: [])
    }

    /// A desk lamp's shade seen from above, 6 pt: a white disc, tinted `officeLamp` when on and `lineStrong` when off.
    public static let lamp: SKTexture = render(6, 6) { c in
        c.setFillColor(NSColor.white.cgColor)
        c.fillEllipse(in: CGRect(x: 0.5, y: 0.5, width: 5, height: 5))
    }

    /// An open seat's desk (spec §5.2): the 36 pt top and 6 pt face as dashed one-pixel `lineStrong` outlines over a
    /// `bg1` fill, unlit, 36 × 30 pt.
    public static let deskDashed: SKTexture = render(36, 30) { c in
        let top = CGRect(x: 0, y: 6, width: 36, height: 24), face = CGRect(x: 0, y: 0, width: 36, height: 6)
        fill(c, top, ThemeHex.bg1, radius: 1)
        fill(c, face, ThemeHex.bg1, radius: 1)
        c.setStrokeColor(cg(ThemeHex.lineStrong))
        c.setLineWidth(hair)
        c.setLineDash(phase: 0, lengths: [2, 1.5])
        for r in [top, face] {
            c.addPath(CGPath(roundedRect: r.insetBy(dx: hair / 2, dy: hair / 2), cornerWidth: 0.75, cornerHeight: 0.75,
                             transform: nil))
        }
        c.strokePath()
        c.setLineDash(phase: 0, lengths: [])
    }

    // MARK: - Figure

    /// The figure's body in a `figureSize` frame: a rounded peg and two 2 pt hands, white (tinted by department).
    public static func figureBody(_ pose: FigurePose) -> SKTexture {
        if let hit = bodies[pose] { return hit }
        let texture = drawBody(pose)
        bodies[pose] = texture
        return texture
    }

    private static var bodies: [FigurePose: SKTexture] = [:]

    private static func drawBody(_ pose: FigurePose) -> SKTexture {
        // Standing and walking bodies reach the floor; seated ones are shorter (the chair hides the rest).
        let standing = pose == .stand || pose == .walkA || pose == .walkB
        let body = standing ? CGRect(x: 2, y: 0, width: 6, height: 9.5) : CGRect(x: 2, y: 2, width: 6, height: 7.5)
        let hands: (CGPoint, CGPoint) = switch pose {
        case .sit: (CGPoint(x: 1, y: 4.5), CGPoint(x: 9, y: 4.5))
        case .typeA: (CGPoint(x: 1.25, y: 7), CGPoint(x: 8.75, y: 5.5))
        case .typeB: (CGPoint(x: 1.25, y: 5.5), CGPoint(x: 8.75, y: 7))
        case .walkA: (CGPoint(x: 1, y: 5.5), CGPoint(x: 9, y: 3))
        case .walkB: (CGPoint(x: 1, y: 3), CGPoint(x: 9, y: 5.5))
        case .stand: (CGPoint(x: 1, y: 4), CGPoint(x: 9, y: 4))
        case .raisedHand: (CGPoint(x: 1, y: 4.5), CGPoint(x: 9, y: 14.75))
        }
        return render(figureSize.width, figureSize.height) { c in
            c.setFillColor(NSColor.white.cgColor)
            c.addPath(CGPath(roundedRect: body, cornerWidth: 2.75, cornerHeight: 2.75, transform: nil))
            c.fillPath()
            for hand in [hands.0, hands.1] {
                // A one-pixel gap keeps a hand readable where it overlaps the body (both are one tint).
                c.setBlendMode(.clear)
                c.fillEllipse(in: CGRect(x: hand.x - 1.5, y: hand.y - 1.5, width: 3, height: 3))
                c.setBlendMode(.normal)
                c.fillEllipse(in: CGRect(x: hand.x - 1, y: hand.y - 1, width: 2, height: 2))
            }
        }
    }

    /// The figure's round head, 6 pt in `text1`, with no face. Centre it on `headCenter`.
    public static let figureHead: SKTexture = render(6, 6) { c in
        c.setFillColor(cg(ThemeHex.text1))
        c.fillEllipse(in: CGRect(x: 0, y: 0, width: 6, height: 6))
    }

    // MARK: - Things that move

    /// A DM: a 7 × 9 pt sheet of paper with a folded corner and three lines of writing.
    public static let note: SKTexture = render(7, 9) { c in
        let paper = CGMutablePath()
        paper.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 7, y: 0), CGPoint(x: 7, y: 7), CGPoint(x: 5, y: 9),
                                 CGPoint(x: 0, y: 9)])
        paper.closeSubpath()
        c.setFillColor(cg(ThemeHex.text0))
        c.addPath(paper)
        c.fillPath()
        let fold = CGMutablePath()
        fold.addLines(between: [CGPoint(x: 5, y: 9), CGPoint(x: 5, y: 7), CGPoint(x: 7, y: 7)])
        fold.closeSubpath()
        c.setFillColor(cg(ThemeHex.text1))
        c.addPath(fold)
        c.fillPath()
        for (y, w) in [(6.0, 3.0), (4.5, 4.5), (3.0, 4.5), (1.5, 3.0)] {
            fill(c, CGRect(x: 1.25, y: y, width: w, height: hair), ThemeHex.text2)
        }
    }

    /// A hand-off: a 9 × 9 pt `warning` folder with its tab.
    public static let folder: SKTexture = render(9, 9) { c in
        fill(c, CGRect(x: 0, y: 6.5, width: 4, height: 2.5), ThemeHex.warning, radius: 0.75)
        fill(c, CGRect(x: 0, y: 0, width: 9, height: 7.5), ThemeHex.warning, radius: 0.75)
        fill(c, CGRect(x: 0, y: 6.5, width: 9, height: hair), ThemeHex.bg0)
    }

    /// A shipping item: a 10 × 8 pt `bg4` parcel with a lid seam. Its strap is `parcelStrap`, drawn on top.
    public static let parcel: SKTexture = render(10, 8) { c in
        fill(c, CGRect(x: 0, y: 0, width: 10, height: 8), ThemeHex.bg4, radius: 0.5)
        outline(c, CGRect(x: 0, y: 0, width: 10, height: 8), ThemeHex.lineStrong, radius: 0.5)
        fill(c, CGRect(x: 0.5, y: 6, width: 9, height: hair), ThemeHex.lineStrong)
    }

    /// The parcel's cross strap: `warning` while it is being checked, `blocked` once the checks failed.
    public static func parcelStrap(failed: Bool) -> SKTexture { failed ? strapFailed : strapOK }

    private static let strapOK = drawStrap(ThemeHex.warning)
    private static let strapFailed = drawStrap(ThemeHex.blocked)

    private static func drawStrap(_ hex: UInt32) -> SKTexture {
        render(10, 8) { c in
            fill(c, CGRect(x: 4.25, y: 0, width: 1.5, height: 8), hex)
            fill(c, CGRect(x: 0, y: 3.25, width: 10, height: 1.5), hex)
        }
    }

    /// A former agent's moving box, 14 × 10 pt: the open top and a hand slot.
    public static let box: SKTexture = render(14, 10) { c in
        fill(c, CGRect(x: 1, y: 6, width: 12, height: 4), ThemeHex.bg1, radius: 0.5)
        outline(c, CGRect(x: 1, y: 6, width: 12, height: 4), ThemeHex.lineStrong, radius: 0.5)
        fill(c, CGRect(x: 0, y: 0, width: 14, height: 7), ThemeHex.bg4, radius: 0.5)
        outline(c, CGRect(x: 0, y: 0, width: 14, height: 7), ThemeHex.lineStrong, radius: 0.5)
        fill(c, CGRect(x: 5, y: 4, width: 4, height: 1.25), ThemeHex.bg1, radius: 0.6)
    }

    /// A hire's balloon, 8 × 16 pt: a `text0` balloon on a one-pixel string.
    public static let balloon: SKTexture = render(8, 16) { c in
        c.setFillColor(cg(ThemeHex.text0))
        c.fillEllipse(in: CGRect(x: 0.5, y: 6.5, width: 7, height: 9))
        let knot = CGMutablePath()
        knot.addLines(between: [CGPoint(x: 3.25, y: 6.75), CGPoint(x: 4.75, y: 6.75), CGPoint(x: 4, y: 5.5)])
        knot.closeSubpath()
        c.addPath(knot)
        c.fillPath()
        let string = CGMutablePath()
        string.move(to: CGPoint(x: 4, y: 5.5))
        string.addCurve(to: CGPoint(x: 4, y: 0), control1: CGPoint(x: 2.5, y: 3.5), control2: CGPoint(x: 5.5, y: 2))
        c.setStrokeColor(cg(ThemeHex.text1))
        c.setLineWidth(hair)
        c.addPath(string)
        c.strokePath()
    }

    // MARK: - Bubbles and badges

    /// A 12 pt `text0` speech bubble (tail at the bottom left) with one glyph drawn as a path.
    public static func bubble(_ g: BubbleGlyph) -> SKTexture {
        switch g {
        case .exclaim: bubbleExclaim
        case .ellipsis: bubbleEllipsis
        case .check: bubbleCheck
        }
    }

    private static let bubbleExclaim = drawBubble(.exclaim)
    private static let bubbleEllipsis = drawBubble(.ellipsis)
    private static let bubbleCheck = drawBubble(.check)

    private static func drawBubble(_ g: BubbleGlyph) -> SKTexture {
        render(12, 12) { c in
            fill(c, CGRect(x: 0, y: 2.5, width: 12, height: 9.5), ThemeHex.text0, radius: 3)
            let tail = CGMutablePath()
            tail.addLines(between: [CGPoint(x: 2.5, y: 3), CGPoint(x: 5.5, y: 3), CGPoint(x: 2, y: 0)])
            tail.closeSubpath()
            c.addPath(tail)
            c.fillPath()
            switch g {
            case .exclaim:
                fill(c, CGRect(x: 5.25, y: 6.5, width: 1.5, height: 4), ThemeHex.blocked, radius: 0.75)
                c.fillEllipse(in: CGRect(x: 5.2, y: 3.9, width: 1.6, height: 1.6))
            case .ellipsis:
                c.setFillColor(cg(ThemeHex.bg2))
                for x in [3.5, 6.0, 8.5] {
                    c.fillEllipse(in: CGRect(x: x - 0.9, y: 6.35, width: 1.8, height: 1.8))
                }
            case .check:
                let tick = CGMutablePath()
                tick.addLines(between: [CGPoint(x: 3.5, y: 7.5), CGPoint(x: 5.25, y: 5.5), CGPoint(x: 8.75, y: 9.5)])
                c.setStrokeColor(cg(ThemeHex.success))
                c.setLineWidth(1.4)
                c.setLineCap(.round)
                c.setLineJoin(.round)
                c.addPath(tick)
                c.strokePath()
            }
        }
    }

    /// A 10 pt state badge in the org chip's style: a white chip (tinted by the status colour) with the glyph cut out.
    public static func badge(_ g: BadgeGlyph) -> SKTexture {
        if let hit = badges[g] { return hit }
        let texture = drawBadge(g)
        badges[g] = texture
        return texture
    }

    private static var badges: [BadgeGlyph: SKTexture] = [:]

    private static func drawBadge(_ g: BadgeGlyph) -> SKTexture {
        render(10, 10) { c in
            c.setFillColor(NSColor.white.cgColor)
            c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 10, height: 10), cornerWidth: 2.5, cornerHeight: 2.5,
                             transform: nil))
            c.fillPath()
            // The glyph is punched out of the chip.
            c.setBlendMode(.clear)
            switch g {
            case .typing:
                let play = CGMutablePath()
                play.addLines(between: [CGPoint(x: 3.5, y: 2.5), CGPoint(x: 3.5, y: 7.5), CGPoint(x: 7.5, y: 5)])
                play.closeSubpath()
                c.addPath(play)
                c.fillPath()
            case .reviewing:
                // A pencil pointing to the lower left.
                c.saveGState()
                c.translateBy(x: 5, y: 5)
                c.rotate(by: -3 * .pi / 4)
                c.fill(CGRect(x: -3.6, y: -0.9, width: 4.6, height: 1.8))
                let tip = CGMutablePath()
                tip.addLines(between: [CGPoint(x: 1.5, y: -0.9), CGPoint(x: 1.5, y: 0.9), CGPoint(x: 3.5, y: 0)])
                tip.closeSubpath()
                c.addPath(tip)
                c.fillPath()
                c.restoreGState()
            case .blocked:
                // A raised hand: a palm, four fingers and a thumb.
                c.addPath(CGPath(roundedRect: CGRect(x: 3.2, y: 1.8, width: 4.2, height: 3.8), cornerWidth: 1.2,
                                 cornerHeight: 1.2, transform: nil))
                c.fillPath()
                for (x, top) in [(3.2, 7.4), (4.3, 8.2), (5.4, 8.2), (6.5, 7.6)] {
                    c.addPath(CGPath(roundedRect: CGRect(x: x, y: 4.5, width: 0.9, height: top - 4.5), cornerWidth: 0.45,
                                     cornerHeight: 0.45, transform: nil))
                    c.fillPath()
                }
                c.saveGState()
                c.translateBy(x: 3.4, y: 3.4)
                c.rotate(by: .pi / 4)
                c.addPath(CGPath(roundedRect: CGRect(x: -0.45, y: 0, width: 0.9, height: 2.6), cornerWidth: 0.45,
                                 cornerHeight: 0.45, transform: nil))
                c.fillPath()
                c.restoreGState()
            case .waiting:
                for x in [2.6, 5.0, 7.4] {
                    c.fillEllipse(in: CGRect(x: x - 0.85, y: 4.15, width: 1.7, height: 1.7))
                }
            case .away:
                // A crescent: a disc, then the overlapping disc painted back.
                c.fillEllipse(in: CGRect(x: 2, y: 2, width: 6, height: 6))
                c.setBlendMode(.normal)
                c.saveGState()
                c.addEllipse(in: CGRect(x: 2, y: 2, width: 6, height: 6))
                c.clip()
                c.setFillColor(NSColor.white.cgColor)
                c.fillEllipse(in: CGRect(x: 3.8, y: 3.4, width: 5.2, height: 5.2))
                c.restoreGState()
            }
            c.setBlendMode(.normal)
        }
    }

    /// A vacancy's `HIRING` sign: mono 8 `warning` text (via `LabelTextures`) on a `bg1` card with a hairline border.
    public static let placard: SKTexture = {
        let label = LabelTextures.shared.text("HIRING", size: 8, mono: true, color: ThemeHex.warning)
        let text = points(label)
        let w = (text.width + 2).rounded(.up), h = (text.height + 1).rounded(.up)
        let image = label.cgImage()
        return render(w, h) { c in
            fill(c, CGRect(x: 0, y: 0, width: w, height: h), ThemeHex.bg1, radius: 1)
            outline(c, CGRect(x: 0, y: 0, width: w, height: h), ThemeHex.warning, radius: 1)
            c.draw(image, in: CGRect(x: (w - text.width) / 2, y: (h - text.height) / 2, width: text.width, height: text.height))
        }
    }()

    // MARK: - Rooms

    /// A pod's pin board, 20 × 10 pt, with two cards already pinned.
    public static let pinBoard: SKTexture = render(20, 10) { c in
        fill(c, CGRect(x: 0, y: 0, width: 20, height: 10), ThemeHex.bg4, radius: 0.5)
        outline(c, CGRect(x: 0, y: 0, width: 20, height: 10), ThemeHex.lineStrong, radius: 0.5)
        fill(c, CGRect(x: 3, y: 2.5, width: 4.5, height: 5), ThemeHex.text2)
        fill(c, CGRect(x: 10, y: 3.5, width: 5, height: 4), ThemeHex.text2)
    }

    /// The review room's long table, 120 pt wide: a `bg3` top over a 6 pt `bg2` face.
    public static let table: SKTexture = furniture(width: 120, top: 24)

    /// A counter (break room, mail room), 64 pt wide: a `bg3` top over a 6 pt `bg2` face.
    public static let counter: SKTexture = furniture(width: 64, top: 12)

    /// The break-room sofa, 40 × 16 pt: a `bg4` back and arms around two `accentDim` seat cushions.
    public static let sofa: SKTexture = render(40, 16) { c in
        fill(c, CGRect(x: 0, y: 8, width: 40, height: 8), ThemeHex.bg4, radius: 2)
        fill(c, CGRect(x: 0, y: 0, width: 5, height: 12), ThemeHex.bg4, radius: 1.5)
        fill(c, CGRect(x: 35, y: 0, width: 5, height: 12), ThemeHex.bg4, radius: 1.5)
        fill(c, CGRect(x: 5.5, y: 0, width: 14.25, height: 9), ThemeHex.accentDim, radius: 1)
        fill(c, CGRect(x: 20.25, y: 0, width: 14.25, height: 9), ThemeHex.accentDim, radius: 1)
    }

    /// The wall of fame, 72 × 14 pt: an open `bg2` shelf in a `lineStrong` frame, room for six 10 pt glyphs.
    public static let shelf: SKTexture = render(72, 14) { c in
        fill(c, CGRect(x: 0, y: 0, width: 72, height: 14), ThemeHex.bg2)
        fill(c, CGRect(x: 0, y: 0, width: 72, height: 1.5), ThemeHex.lineStrong)
        fill(c, CGRect(x: 0, y: 13, width: 72, height: 1), ThemeHex.lineStrong)
        fill(c, CGRect(x: 0, y: 0, width: 1, height: 14), ThemeHex.lineStrong)
        fill(c, CGRect(x: 71, y: 0, width: 1, height: 14), ThemeHex.lineStrong)
    }

    /// A door as a floor plan draws it, 16 pt: the leaf at the hinge and its swing as a one-pixel arc.
    public static let door: SKTexture = render(16, 16) { c in
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: 15.5, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        c.setStrokeColor(cg(ThemeHex.line))
        c.setLineWidth(hair)
        c.addPath(arc)
        c.strokePath()
        fill(c, CGRect(x: 0, y: 0, width: 1.5, height: 16), ThemeHex.officeWall)
    }

    /// A 24 pt wall run, 3 pt thick, solid `officeWall` (stretches without artefacts).
    public static let wallH: SKTexture = render(24, 3) { c in
        fill(c, CGRect(x: 0, y: 0, width: 24, height: 3), ThemeHex.officeWall)
    }

    /// `wallH` upright.
    public static let wallV: SKTexture = render(3, 24) { c in
        fill(c, CGRect(x: 0, y: 0, width: 3, height: 24), ThemeHex.officeWall)
    }

    /// One 24 pt floor tile: a 1 pt `mapGrid` seam on its left and bottom edges, as `OrgScene`'s map lattice.
    public static let floorTile: SKTexture = render(24, 24) { c in
        fill(c, CGRect(x: 0, y: 0, width: 1, height: 24), ThemeHex.mapGrid)
        fill(c, CGRect(x: 0, y: 0, width: 24, height: 1), ThemeHex.mapGrid)
    }

    // MARK: - Tile sheet

    /// Every texture and variant on a `bg0` 800 × 400 scene, labelled, plus four assembled desks, for a human to review
    /// the art without running the app (`office-tiles.png`). Tinted textures are shown tinted as the office uses them.
    public static func tileSheet() -> SKScene {
        let scene = SKScene(size: CGSize(width: 800, height: 400))
        scene.backgroundColor = MapPalette.color(ThemeHex.bg0)
        scene.anchorPoint = .zero
        var sheet = Sheet(scene: scene)

        sheet.add("deskTop", sprite(deskTop))
        sheet.add("deskFace", sprite(deskFace))
        sheet.add("chair", sprite(chair))
        sheet.add("mon.off", sprite(monitor(.off)))
        sheet.add("mon.dim", sprite(monitor(.dim), tint: ThemeHex.ready))
        sheet.add("mon.lit", sprite(monitor(.lit)))
        sheet.add("lit.run", sprite(monitor(.lit), tint: ThemeHex.running))
        sheet.add("lit.blk", sprite(monitor(.lit), tint: ThemeHex.blocked))
        sheet.add("glow", sprite(lampGlow, mag: 1, tint: ThemeHex.officeLamp))
        sheet.add("screen", sprite(screenGlow, mag: 1, tint: ThemeHex.running))
        sheet.add("lamp", sprite(lamp, tint: ThemeHex.officeLamp))
        sheet.add("dashed", sprite(deskDashed))
        sheet.add("head", sprite(figureHead))
        for (i, pose) in FigurePose.allCases.enumerated() {
            sheet.add("\(pose)", figure(pose, tint: ThemeHex.series[i % ThemeHex.series.count], mag: 2))
        }
        sheet.newRow()
        sheet.add("note", sprite(note))
        sheet.add("folder", sprite(folder))
        sheet.add("parcel", sprite(parcel))
        sheet.add("strap", parcelWithStrap(failed: false))
        sheet.add("failed", parcelWithStrap(failed: true))
        sheet.add("box", sprite(box))
        sheet.add("balloon", sprite(balloon))
        for g in BubbleGlyph.allCases { sheet.add("\(g)", sprite(bubble(g))) }
        let badgeTints: [BadgeGlyph: UInt32] = [.typing: ThemeHex.running, .reviewing: ThemeHex.ready,
                                               .blocked: ThemeHex.blocked, .waiting: ThemeHex.blocked,
                                               .away: ThemeHex.sleeping]
        for g in BadgeGlyph.allCases { sheet.add("\(g)", sprite(badge(g), tint: badgeTints[g])) }
        sheet.add("placard", sprite(placard))
        sheet.newRow()
        sheet.add("table", sprite(table, mag: 1))
        sheet.add("counter", sprite(counter, mag: 1))
        sheet.add("sofa", sprite(sofa))
        sheet.add("shelf", sprite(shelf, mag: 1))
        sheet.add("pinBoard", sprite(pinBoard))
        sheet.add("door", sprite(door))
        sheet.add("wallH", sprite(wallH))
        sheet.add("wallV", sprite(wallV))
        sheet.add("floorTile", sprite(floorTile))
        sheet.newRow()
        sheet.add("running", assembledDesk(screen: .lit, color: ThemeHex.running, pose: .typeA, bubble: nil))
        sheet.add("blocked", assembledDesk(screen: .lit, color: ThemeHex.blocked, pose: .raisedHand, bubble: .exclaim))
        sheet.add("ready", assembledDesk(screen: .dim, color: ThemeHex.ready, pose: .sit, bubble: nil))
        sheet.add("away", assembledDesk(screen: .off, color: nil, pose: nil, bubble: nil))
        sheet.add("vacancy", assembledDesk(screen: .off, color: nil, pose: nil, bubble: nil, placard: true))
        return scene
    }

    /// A left-to-right, top-to-bottom flow of labelled samples.
    @MainActor private struct Sheet {
        let scene: SKScene
        var x: CGFloat = 14
        var top: CGFloat = 386
        var rowHeight: CGFloat = 0

        init(scene: SKScene) { self.scene = scene }

        mutating func newRow() {
            guard rowHeight > 0 else { return }
            x = 14
            top -= rowHeight + 12
            rowHeight = 0
        }

        /// Adds `node` (drawn from its bottom-left corner, `size` points) with `name` under it.
        mutating func add(_ name: String, _ sample: (node: SKNode, size: CGSize)) {
            let labelTexture = LabelTextures.shared.text(name, size: 8, mono: true, color: ThemeHex.text2)
            let labelSize = CGSize(width: labelTexture.size().width / LabelTextures.scale,
                                   height: labelTexture.size().height / LabelTextures.scale)
            let width = max(sample.size.width, labelSize.width)
            if x + width > scene.size.width - 14 { newRow() }
            sample.node.position = CGPoint(x: x + (width - sample.size.width) / 2, y: top - sample.size.height)
            scene.addChild(sample.node)
            let label = SKSpriteNode(texture: labelTexture, size: labelSize)
            label.position = CGPoint(x: x + width / 2, y: top - sample.size.height - 3 - labelSize.height / 2)
            scene.addChild(label)
            rowHeight = max(rowHeight, sample.size.height + 3 + labelSize.height)
            x += width + 14
        }
    }

    private static func sprite(_ t: SKTexture, mag: CGFloat = 2, tint: UInt32? = nil) -> (node: SKNode, size: CGSize) {
        let p = points(t)
        let size = CGSize(width: p.width * mag, height: p.height * mag)
        let node = SKSpriteNode(texture: t, size: size)
        node.anchorPoint = .zero
        if let tint {
            node.color = MapPalette.color(tint)
            node.colorBlendFactor = 1
        }
        return (node, size)
    }

    private static func figure(_ pose: FigurePose, tint: UInt32, mag: CGFloat) -> (node: SKNode, size: CGSize) {
        let node = SKNode()
        let body = SKSpriteNode(texture: figureBody(pose), size: figureSize)
        body.anchorPoint = .zero
        body.color = MapPalette.color(tint)
        body.colorBlendFactor = 1
        node.addChild(body)
        let head = SKSpriteNode(texture: figureHead, size: points(figureHead))
        head.position = headCenter
        node.addChild(head)
        node.setScale(mag)
        return (node, CGSize(width: figureSize.width * mag, height: figureSize.height * mag))
    }

    private static func parcelWithStrap(failed: Bool) -> (node: SKNode, size: CGSize) {
        let sample = sprite(parcel)
        let strap = SKSpriteNode(texture: parcelStrap(failed: failed), size: sample.size)
        strap.anchorPoint = .zero
        sample.node.addChild(strap)
        return sample
    }

    /// One desk as the office will assemble it (Task 5 owns the real composition): chair, face, top, glow, monitor,
    /// and the figure seated in front with its back to the viewer.
    private static func assembledDesk(screen: ScreenState, color: UInt32?, pose: FigurePose?, bubble glyph: BubbleGlyph?,
                                      placard showPlacard: Bool = false) -> (node: SKNode, size: CGSize) {
        let mag: CGFloat = 2
        let node = SKNode()
        func add(_ t: SKTexture, at p: CGPoint, tint: UInt32? = nil, alpha: CGFloat = 1, z: CGFloat) {
            let s = SKSpriteNode(texture: t, size: points(t))
            s.anchorPoint = .zero
            s.position = p
            s.zPosition = z
            s.alpha = alpha
            if let tint { s.color = MapPalette.color(tint); s.colorBlendFactor = 1 }
            node.addChild(s)
        }
        // Desk origin at (0, 10): the chair and figure sit in front of (below) it.
        if showPlacard {
            add(deskDashed, at: CGPoint(x: 0, y: 10), z: 0)
        } else {
            add(deskFace, at: CGPoint(x: 0, y: 10), z: 0)
            add(deskTop, at: CGPoint(x: 0, y: 16), z: 0)
        }
        if let color {
            add(lampGlow, at: CGPoint(x: 18 - 24, y: 34.5 - 24), tint: color, alpha: 0.8, z: 1)
        }
        add(monitor(screen), at: CGPoint(x: 13, y: 31), tint: color, z: 2)
        add(chair, at: CGPoint(x: 12, y: 0), z: 3)
        if let pose {
            add(figureBody(pose), at: CGPoint(x: 13, y: 3), tint: ThemeHex.series[0], z: 4)
            add(figureHead, at: CGPoint(x: 13 + headCenter.x - 3, y: 3 + headCenter.y - 3), z: 4)
        }
        if let glyph {
            add(bubble(glyph), at: CGPoint(x: 24, y: 17), z: 5)
        }
        if showPlacard {
            let p = points(placard)
            add(placard, at: CGPoint(x: (36 - p.width) / 2, y: 18), z: 5)
        }
        node.setScale(mag)
        return (node, CGSize(width: 36 * mag, height: 40 * mag))
    }

    // MARK: - Drawing

    private static func cg(_ hex: UInt32) -> CGColor {
        MapPalette.color(hex).cgColor
    }

    private static func fill(_ c: CGContext, _ r: CGRect, _ hex: UInt32, radius: CGFloat = 0) {
        c.setFillColor(cg(hex))
        if radius > 0 {
            c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            c.fillPath()
        } else {
            c.fill(r)
        }
    }

    /// A one-pixel border just inside `r`.
    private static func outline(_ c: CGContext, _ r: CGRect, _ hex: UInt32, radius: CGFloat = 0) {
        let inset = r.insetBy(dx: hair / 2, dy: hair / 2)
        let rr = max(0, radius - hair / 2)
        c.setStrokeColor(cg(hex))
        c.setLineWidth(hair)
        c.addPath(CGPath(roundedRect: inset, cornerWidth: rr, cornerHeight: rr, transform: nil))
        c.strokePath()
    }

    /// A transparent `w` × `h` pt canvas at `scale`×, drawn in points, origin bottom-left.
    private static func render(_ w: CGFloat, _ h: CGFloat, _ draw: (CGContext) -> Void) -> SKTexture {
        let width = Int((w * scale).rounded()), height = Int((h * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        draw(context)
        guard let image = context.makeImage() else { return SKTexture() }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        return texture
    }

    /// The private furniture shape: a `bg3` top of height `top` over a 6 pt `bg2` front face, hairline `line` edges.
    private static func furniture(width: CGFloat, top: CGFloat) -> SKTexture {
        render(width, top + 6) { c in
            fill(c, CGRect(x: 0, y: 6, width: width, height: top), ThemeHex.officeDeskTop, radius: 1)
            outline(c, CGRect(x: 0, y: 6, width: width, height: top), ThemeHex.line, radius: 1)
            fill(c, CGRect(x: 0, y: 0, width: width, height: 6.5), ThemeHex.officeDeskFace, radius: 1)
            outline(c, CGRect(x: 0, y: 0, width: width, height: 6.5), ThemeHex.line, radius: 1)
        }
    }
}
