import SpriteKit
import BrahmaAppModel

/// A scene that shows the map in one `MapMode`: the org chart (`OrgScene`) or the office (`OfficeScene`). A host holds
/// one as `any MapScene`, points it at a controller, and asks it where an agent is drawn.
@MainActor
public protocol MapScene: SKScene, MapInteractive {
    var mode: MapMode { get }
    /// Makes `controller` drive the scene from `SKScene.update(_:)`, or stops driving with nil.
    func present(controller: MapController?)
    /// Centres the content and zooms so all of `contentBounds` plus `margin` points shows.
    func zoomToFit(margin: CGFloat)
    /// Everything the scene draws, in scene coordinates.
    var contentBounds: CGRect { get }
    /// Where an agent (or `"owner"`, or `"vacancy:<id>"`) is drawn: its card in the org chart, its desk in the office.
    func targetRect(_ id: String) -> CGRect?
}

/// The scene for a mode.
@MainActor
public enum MapSceneFactory {
    public static func make(_ mode: MapMode, size: CGSize) -> any MapScene {
        switch mode {
        case .org: OrgScene(size: size)
        case .office: OfficeScene(size: size)
        }
    }
}
