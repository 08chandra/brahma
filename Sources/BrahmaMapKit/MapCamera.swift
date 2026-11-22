import SpriteKit
import BrahmaAppModel

/// The map's camera, shared by the org chart and the office: it eases an `SKCameraNode` over 0.3 s to the controller's
/// `camera` target, keeps a `.fit` target fitted while the content grows (until the owner pans or zooms), tracks a followed
/// agent as it moves, snaps on the first frame instead of easing, and keeps `controller.zoom` and the camera one value.
///
/// The driver knows nothing about what the scene draws: each frame the scene hands it the rect of a target id (as drawn
/// now) and the bounds of its content. It moves the camera node only; a scene that derives anything from the camera (level of
/// detail, line widths) compares the node after `update` and `syncZoom`.
@MainActor
final class MapCameraDriver {
    /// The ease to a new target, in seconds.
    static let ease: TimeInterval = 0.3

    private struct Ease {
        var start: TimeInterval
        var from: CGPoint
        var fromScale: CGFloat
        /// A target agent is shown at least this big; nil follows the goal's own zoom (a fit).
        var zoom: Double?
    }

    private struct FitKey: Equatable {
        var bounds: CGRect
        var size: CGSize
    }

    private unowned let scene: SKScene
    let camera: SKCameraNode
    let zoomRange: ClosedRange<Double>

    private var target: CameraTarget?
    /// The controller's `cameraRequest` this driver has acted on.
    private var requestSeen = 0
    private var easing: Ease?
    /// Following the content's bounds: a fit target the owner has not panned or zoomed away from.
    private var autoFit = true
    /// The owner is dragging or zooming: a followed agent is no longer tracked until the next camera request.
    private var suspended = false
    private var snapNext = true
    private var fitKey: FitKey?
    private var lastControllerZoom: Double?

    init(scene: SKScene, camera: SKCameraNode, zoomRange: ClosedRange<Double>) {
        self.scene = scene
        self.camera = camera
        self.zoomRange = zoomRange
    }

    /// Magnification (the camera's inverse scale), clamped to `zoomRange`.
    var zoom: Double {
        get { 1 / Double(camera.xScale) }
        set { camera.setScale(CGFloat(1 / clamp(newValue))) }
    }

    /// Forgets everything about the previous controller: the next `update` snaps to its target.
    func reset() {
        target = nil
        requestSeen = 0
        easing = nil
        autoFit = true
        suspended = false
        snapNext = true
        fitKey = nil
        lastControllerZoom = nil
    }

    /// The owner dragged or zoomed: stop easing, stop tracking a followed agent, stop refitting.
    func userMoved() {
        easing = nil
        autoFit = false
        suspended = true
    }

    /// Centres `contentBounds` and zooms so all of it plus `margin` points shows (clamped to `zoomRange`).
    func zoomToFit(contentBounds: CGRect, margin: CGFloat) {
        guard let goal = fitGoal(contentBounds: contentBounds, margin: margin) else { return }
        camera.position = goal.center
        zoom = goal.zoom
    }

    /// Where the camera shows all of `contentBounds` plus `margin` points: its centre and (unclamped) zoom. Nil while the
    /// content or the view is empty.
    func fitGoal(contentBounds: CGRect, margin: CGFloat = 40) -> (center: CGPoint, zoom: Double)? {
        let size = scene.size
        guard contentBounds.width > 0, contentBounds.height > 0, size.width > 0, size.height > 0 else { return nil }
        let fit = Swift.min(size.width / (contentBounds.width + 2 * margin), size.height / (contentBounds.height + 2 * margin))
        return (CGPoint(x: contentBounds.midX, y: contentBounds.midY), Double(fit))
    }

    /// Eases the camera over 0.3 s to the controller's `camera` target: `.fit` shows all of `contentBounds` (and keeps
    /// showing it as the content grows, until the owner pans or zooms), `.agent` centres `targetRect(id)`, at least at
    /// 100 %, and while the owner is following it the camera tracks the rect as it moves. The first frame snaps instead of
    /// easing.
    func update(controller: MapController, now: TimeInterval, targetRect: (String) -> CGRect?, contentBounds: CGRect) {
        let target = controller.camera
        if self.target != target || requestSeen != controller.cameraRequest {
            let first = self.target == nil
            self.target = target
            requestSeen = controller.cameraRequest
            suspended = false
            if case .fit = target { autoFit = true } else { autoFit = false }
            if first {
                snapNext = true
                easing = nil
            } else {
                var zoomGoal: Double?
                if case .agent = target { zoomGoal = Swift.max(zoom, 1) }
                easing = Ease(start: now, from: camera.position, fromScale: camera.xScale, zoom: zoomGoal)
            }
        }

        let goal: (center: CGPoint, zoom: Double)?
        switch target {
        case .fit:
            goal = fitGoal(contentBounds: contentBounds).map { ($0.center, clamp($0.zoom)) }
        case .agent(let id):
            goal = targetRect(id).map { (CGPoint(x: $0.midX, y: $0.midY), easing?.zoom ?? Swift.max(zoom, 1)) }
        }
        guard let goal else { return }

        if case .fit = target, autoFit {
            let key = FitKey(bounds: contentBounds, size: scene.size)
            if key != fitKey {
                fitKey = key
                if !snapNext && easing == nil {
                    easing = Ease(start: now, from: camera.position, fromScale: camera.xScale, zoom: nil)
                }
            }
        }
        if snapNext {
            camera.position = goal.center
            zoom = goal.zoom
            snapNext = false
            easing = nil
            return
        }
        if let ease = easing {
            let p = Swift.min(1, Swift.max(0, (now - ease.start) / Self.ease))
            let s = CGFloat(p * p * (3 - 2 * p))
            let toScale = 1 / CGFloat(clamp(ease.zoom ?? goal.zoom))
            camera.position = CGPoint(x: ease.from.x + (goal.center.x - ease.from.x) * s,
                                      y: ease.from.y + (goal.center.y - ease.from.y) * s)
            zoom = Double(1 / (ease.fromScale + (toScale - ease.fromScale) * s))
            if p >= 1 { easing = nil }
        } else if case .agent(let id) = target, controller.follow == id, !suspended {
            camera.position = goal.center
        }
    }

    /// `controller.zoom` and the camera stay one value: the camera's zoom (gestures, easing) is written to the controller;
    /// a zoom set on the controller from outside (a control) moves the camera.
    func syncZoom(controller: MapController) {
        if let last = lastControllerZoom, controller.zoom != last {
            easing = nil
            autoFit = false
            zoom = controller.zoom
        } else if abs(controller.zoom - zoom) > 1e-9 {
            controller.zoom = zoom
        }
        lastControllerZoom = controller.zoom
    }

    private func clamp(_ z: Double) -> Double {
        Swift.min(zoomRange.upperBound, Swift.max(zoomRange.lowerBound, z.isFinite ? z : 1))
    }
}
