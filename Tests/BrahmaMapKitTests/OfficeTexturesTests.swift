import Testing
import Foundation
import SpriteKit
import Metal
@testable import BrahmaAppModel
@testable import BrahmaMapKit

/// The office's procedural art (spec §5.3, §7). Texture drawing is CoreGraphics only; rendering through
/// `MapSnapshotter` needs a Metal device.
@MainActor
@Suite(.scratch) struct OfficeTexturesTests {
    /// Every texture, one entry per enum variant, with the point size it must have when it is pinned.
    private func all() -> [(name: String, texture: SKTexture, points: CGSize?)] {
        var out: [(String, SKTexture, CGSize?)] = [
            ("deskTop", OfficeTextures.deskTop, CGSize(width: 36, height: 24)),
            ("deskFace", OfficeTextures.deskFace, CGSize(width: 36, height: 6)),
            ("chair", OfficeTextures.chair, CGSize(width: 12, height: 8)),
            ("lampGlow", OfficeTextures.lampGlow, CGSize(width: 48, height: 48)),
            ("figureHead", OfficeTextures.figureHead, nil),
            ("note", OfficeTextures.note, CGSize(width: 7, height: 9)),
            ("folder", OfficeTextures.folder, CGSize(width: 9, height: 9)),
            ("parcel", OfficeTextures.parcel, CGSize(width: 10, height: 8)),
            ("box", OfficeTextures.box, nil),
            ("balloon", OfficeTextures.balloon, nil),
            ("placard", OfficeTextures.placard, nil),
            ("pinBoard", OfficeTextures.pinBoard, nil),
            ("table", OfficeTextures.table, nil),
            ("counter", OfficeTextures.counter, nil),
            ("sofa", OfficeTextures.sofa, nil),
            ("shelf", OfficeTextures.shelf, nil),
            ("door", OfficeTextures.door, nil),
            ("wallH", OfficeTextures.wallH, nil),
            ("wallV", OfficeTextures.wallV, nil),
            ("floorTile", OfficeTextures.floorTile, CGSize(width: 24, height: 24)),
        ]
        for s in [OfficeTextures.ScreenState.off, .dim, .lit] {
            out.append(("monitor(\(s))", OfficeTextures.monitor(s), CGSize(width: 10, height: 7)))
        }
        for p in OfficeTextures.FigurePose.allCases {
            out.append(("figureBody(\(p))", OfficeTextures.figureBody(p), OfficeTextures.figureSize))
        }
        for failed in [false, true] {
            out.append(("parcelStrap(\(failed))", OfficeTextures.parcelStrap(failed: failed), CGSize(width: 10, height: 8)))
        }
        for g in OfficeTextures.BubbleGlyph.allCases {
            out.append(("bubble(\(g))", OfficeTextures.bubble(g), CGSize(width: 12, height: 12)))
        }
        for g in OfficeTextures.BadgeGlyph.allCases {
            out.append(("badge(\(g))", OfficeTextures.badge(g), nil))
        }
        return out
    }

    @Test func everyTextureIsDrawn() {
        #expect(OfficeTextures.scale == 2)
        #expect(OfficeTextures.figureSize == CGSize(width: 10, height: 16))
        for (name, texture, points) in all() {
            let size = texture.size()
            #expect(size.width > 1 && size.height > 1, "\(name) is empty")
            if let points {
                #expect(OfficeTextures.points(texture) == points, "\(name)")
            }
        }
        // Cached: the same instance every time.
        #expect(OfficeTextures.monitor(.lit) === OfficeTextures.monitor(.lit))
        #expect(OfficeTextures.figureBody(.typeA) === OfficeTextures.figureBody(.typeA))
        #expect(OfficeTextures.bubble(.check) === OfficeTextures.bubble(.check))
        #expect(OfficeTextures.badge(.away) === OfficeTextures.badge(.away))
        // The two typing frames and the two walking frames differ (the hands alternate).
        #expect(png(OfficeTextures.figureBody(.typeA)) != png(OfficeTextures.figureBody(.typeB)))
        #expect(png(OfficeTextures.figureBody(.walkA)) != png(OfficeTextures.figureBody(.walkB)))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func monitorLitIsWhiteForTinting() throws {
        let scene = SKScene(size: CGSize(width: 40, height: 28))
        scene.backgroundColor = MapPalette.color(ThemeHex.bg0)
        let sprite = SKSpriteNode(texture: OfficeTextures.monitor(.lit), size: scene.size)
        sprite.position = CGPoint(x: scene.size.width / 2, y: scene.size.height / 2)
        scene.addChild(sprite)
        let image = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 1))
        #expect(MapSnapshotter.fraction(image, near: 0xFFFFFF) > 0.3)
        // Dim is not white; off is the dark screen.
        sprite.texture = OfficeTextures.monitor(.off)
        let off = try #require(MapSnapshotter.render(scene: scene, size: scene.size, steps: 1))
        #expect(MapSnapshotter.fraction(off, near: 0xFFFFFF) < 0.01)
        #expect(MapSnapshotter.fraction(off, near: ThemeHex.bg1, tolerance: 6) > 0.3)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"))
    func tileSheet() throws {
        let scene = OfficeTextures.tileSheet()
        #expect(scene.size == CGSize(width: 800, height: 400))
        let image = try #require(MapSnapshotter.render(scene: scene, size: CGSize(width: 800, height: 400), steps: 1))
        #expect(MapSnapshotter.fraction(image, near: ThemeHex.bg0, tolerance: 6) > 0.5)
        MapSnapshotter.writeIfRequested(image, name: "office-tiles")
    }

    private func png(_ t: SKTexture) -> Data? {
        MapSnapshotter.png(t.cgImage())
    }
}
