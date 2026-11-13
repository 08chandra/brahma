import Testing
import Foundation
import SpriteKit
import Metal
@testable import BrahmaCore
@testable import BrahmaAppModel
@testable import BrahmaMapKit

/// Scene tests render offscreen through `MapSnapshotter`; Tasks 9a and 9b add the org-chart cases.
@MainActor
@Suite struct OrgSceneTests {
    /// A `bg0` scene with one 100×100 `running` sprite rendered at 400×300: the sprite covers 1/12 of the image.
    /// A BGRA/RGBA mix-up in the snapshotter would make both fractions lie, which is why this test exists.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func snapshotterRendersSolidScene() throws {
        let size = CGSize(width: 400, height: 300)
        let scene = SKScene(size: size)
        scene.scaleMode = .aspectFill
        scene.backgroundColor = MapPalette.color(ThemeHex.bg0)
        let sprite = SKSpriteNode(color: MapPalette.color(ThemeHex.running), size: CGSize(width: 100, height: 100))
        sprite.position = CGPoint(x: 200, y: 150)
        scene.addChild(sprite)

        let image = try #require(MapSnapshotter.render(scene: scene, size: size))
        #expect(image.width == 400); #expect(image.height == 300)
        #expect(MapSnapshotter.fraction(image, near: ThemeHex.bg0) > 0.8)
        let running = MapSnapshotter.fraction(image, near: ThemeHex.running)
        #expect(abs(running - 1.0 / 12.0) < 0.01, "running fraction \(running)")
        // A channel swap would put the green sprite somewhere else entirely.
        #expect(MapSnapshotter.fraction(image, near: 0x67A432) < 0.001)
        #expect(MapSnapshotter.png(image) != nil)
        MapSnapshotter.writeIfRequested(image, name: "solid-scene")
    }
}
