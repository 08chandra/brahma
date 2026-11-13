import AppKit
import CoreText
import SpriteKit
import BrahmaAppModel

/// Text rendered once into `SKTexture`s and reused: the map draws hundreds of labels per frame, and `SKLabelNode`
/// re-lays out on every change. Glyphs are drawn with CoreText at `scale`× (2×), so a sprite showing one of these
/// textures should be sized `texture.size() / LabelTextures.scale` points.
///
/// Callers pass `MapText.clean` output only: every string here is already length-capped and stripped of control,
/// bidi and invisible scalars, and nothing is re-cleaned (a clean string is idempotent under `clean`, but the cap
/// a caller chose is theirs to keep).
@MainActor
public final class LabelTextures {
    public static let shared = LabelTextures()

    /// Pixels per point of every texture.
    public static let scale: CGFloat = 2
    /// Entries kept before the least recently used one goes.
    public static let capacity = 4000

    struct Key: Hashable {
        var string: String
        var size: CGFloat
        var weight: CGFloat
        var mono: Bool
        var color: UInt32
    }

    let cache: LRUCache<Key, SKTexture>

    init(capacity: Int = LabelTextures.capacity) {
        cache = LRUCache(capacity: capacity)
    }

    /// The number of cached textures (tests).
    var count: Int { cache.count }

    /// A texture of `s` (already `MapText.clean`ed) in the system font, SF Mono when `mono`, in the `0xRRGGBB` color.
    public func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool, color: UInt32) -> SKTexture {
        let key = Key(string: s, size: size, weight: weight.rawValue, mono: mono, color: color)
        if let hit = cache[key] { return hit }
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let texture = Self.draw(s, font: font, color: MapPalette.color(color))
        cache[key] = texture
        return texture
    }

    /// A texture of an emoji string (already `MapText.clean`ed). Color glyphs ignore the foreground color, so this is
    /// `text` in the regular system font and `text0`.
    public func emoji(_ s: String, size: CGFloat) -> SKTexture {
        text(s, size: size, weight: .regular, mono: false, color: ThemeHex.text0)
    }

    /// Draws one line with CoreText into a `scale`× bitmap. Empty or blank strings still yield a 1×1 clear texture.
    static func draw(_ s: String, font: NSFont, color: NSColor) -> SKTexture {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        // Color emoji and italics overhang the advance; the image bounds cover them.
        let imageBounds = CTLineGetImageBounds(line, nil)
        let left = min(0, imageBounds.minX)
        let right = max(advance, imageBounds.maxX)
        let widthPoints = max(1, ceil(right - left) + 2)
        let heightPoints = max(1, ceil(ascent + descent) + 2)
        let width = Int(widthPoints * scale), height = Int(heightPoints * scale)

        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SKTexture()
        }
        context.scaleBy(x: scale, y: scale)
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(false)   // no subpixel color fringes over a dark transparent background
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.textPosition = CGPoint(x: 1 - left, y: 1 + descent)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return SKTexture() }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        return texture
    }
}

/// A fixed-capacity least-recently-used cache: a dictionary of list nodes plus a doubly linked recency list, so
/// lookup, insert and eviction are all O(1). Reading an entry makes it the most recent.
final class LRUCache<Key: Hashable, Value> {
    final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?
        init(key: Key, value: Value) { self.key = key; self.value = value }
    }

    let capacity: Int
    private var nodes: [Key: Node] = [:]
    /// Most recent.
    private var head: Node?
    /// Least recent.
    private var tail: Node?

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { nodes.count }

    /// The keys from most to least recently used (tests).
    var keysByRecency: [Key] {
        var out: [Key] = []
        var node = head
        while let n = node { out.append(n.key); node = n.next }
        return out
    }

    subscript(key: Key) -> Value? {
        get {
            guard let node = nodes[key] else { return nil }
            moveToFront(node)
            return node.value
        }
        set {
            if let value = newValue {
                if let node = nodes[key] {
                    node.value = value
                    moveToFront(node)
                } else {
                    let node = Node(key: key, value: value)
                    nodes[key] = node
                    pushFront(node)
                    if nodes.count > capacity, let last = tail { remove(last); nodes[last.key] = nil }
                }
            } else if let node = nodes[key] {
                remove(node); nodes[key] = nil
            }
        }
    }

    func removeAll() {
        nodes.removeAll(); head = nil; tail = nil
    }

    private func pushFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func remove(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil; node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        remove(node)
        pushFront(node)
    }
}
