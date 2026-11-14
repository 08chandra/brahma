import Testing
import Foundation
import AppKit
import SpriteKit
@testable import BrahmaAppModel
@testable import BrahmaMapKit

/// CoreText label textures and the LRU behind them. No GPU: `SKTexture(cgImage:)` and CoreGraphics run anywhere.
@MainActor
@Suite(.scratch) struct LabelTexturesTests {
    @Test func lruEvictsLeastRecentlyUsed() {
        let cache = LRUCache<Int, String>(capacity: 3)
        cache[1] = "a"; cache[2] = "b"; cache[3] = "c"
        #expect(cache.keysByRecency == [3, 2, 1])
        _ = cache[1]                                   // 1 becomes the most recent
        #expect(cache.keysByRecency == [1, 3, 2])
        cache[4] = "d"                                 // 2 is the least recent and goes
        #expect(cache.count == 3)
        #expect(cache[2] == nil)
        #expect(cache.keysByRecency == [4, 1, 3])
        cache[3] = "C"                                 // overwrite refreshes recency without growing
        #expect(cache.count == 3)
        #expect(cache[3] == "C")
        #expect(cache.keysByRecency == [3, 4, 1])
        cache[4] = nil
        #expect(cache.count == 2)
        #expect(cache.keysByRecency == [3, 1])
        cache.removeAll()
        #expect(cache.count == 0); #expect(cache.keysByRecency.isEmpty)
    }

    @Test func texturesAreCachedPerKeyAndCapped() {
        let textures = LabelTextures(capacity: 5)
        let a = textures.text("@ceo", size: 11, mono: true, color: ThemeHex.text0)
        #expect(textures.text("@ceo", size: 11, mono: true, color: ThemeHex.text0) === a)
        let b = textures.text("@ceo", size: 11, mono: false, color: ThemeHex.text0)
        #expect(b !== a)
        #expect(textures.text("@ceo", size: 11, mono: true, color: ThemeHex.text1) !== a)
        #expect(textures.text("@ceo", size: 12, mono: true, color: ThemeHex.text0) !== a)
        #expect(textures.text("@ceo", size: 11, weight: .semibold, mono: true, color: ThemeHex.text0) !== a)
        #expect(textures.count == 5)
        // Reading `a` makes it the most recent, so `b` is now the least recent and is the one a sixth entry evicts.
        #expect(textures.text("@ceo", size: 11, mono: true, color: ThemeHex.text0) === a)
        _ = textures.text("sixth", size: 10, mono: false, color: ThemeHex.text2)
        #expect(textures.count == 5)
        #expect(textures.text("@ceo", size: 11, mono: true, color: ThemeHex.text0) === a)
        #expect(textures.text("@ceo", size: 11, mono: false, color: ThemeHex.text0) !== b)   // redrawn: it was evicted
        #expect(textures.count == 5)
    }

    @Test func texturesAreDrawnAtTwoTimesScale() {
        let textures = LabelTextures(capacity: 10)
        let texture = textures.text("TEAM-1 · ENGINEERING", size: 10, mono: true, color: ThemeHex.text2)
        let size = texture.size()
        #expect(size.width > 100 * LabelTextures.scale)   // ~20 glyphs of a 10 pt mono font, at 2×
        #expect(size.height >= 10 * LabelTextures.scale)
        #expect(size.height < 20 * LabelTextures.scale)
        // Blank and empty input still yield a texture.
        #expect(textures.text("", size: 10, mono: false, color: ThemeHex.text0).size().width >= 1)
        #expect(textures.emoji("🚀", size: 12).size().width >= 12 * LabelTextures.scale)
    }
}
