import AppKit
import SpriteKit
import BrahmaCore
import BrahmaAppModel

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
