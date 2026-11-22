import AppKit
import Observation
import SpriteKit
import SwiftUI
import BrahmaAppModel

/// The map in SwiftUI: the scene for `controller.mode` (the org chart's `OrgScene` or the office's `OfficeScene`) in a
/// `MapSKView` that the controller drives. Each frame the scene calls `controller.frame(now:)` and plays what comes back. A
/// mode change cross-fades to the other scene over `modeFade` (at once under Reduce Motion). Clicks go to
/// `controller.handle`, except that a click on a stub (or on a manager's `▾`) expands or collapses the subtree and a double
/// click follows the agent; every click also feeds the office unlock (a Board click counts, any other click breaks the
/// count), and so do keys typed on the focused map. The right-click menu comes from `controller.actions(for:)`; `Fill…`
/// only calls `onFill`, which opens the confirmation sheet.
public struct OrgView: NSViewRepresentable {
    /// The cross-fade between the org chart and the office.
    public static let modeFade: TimeInterval = 0.6

    public var controller: MapController
    public var appModel: AppModel
    /// The pointer over an agent in this view's coordinates, origin at the top left (a SwiftUI overlay's space); nil when the
    /// pointer is not over one.
    @Binding public var hoverPoint: CGPoint?
    /// The manager handle (raw) the seat goes under; nil for Board.
    public var onAddVacancy: (String?) -> Void
    /// The cleaned vacancy id; opens the confirmation sheet and never fills directly.
    public var onFill: (String) -> Void
    /// The agent handle (raw, a lookup key: never show it without `MapText.clean`).
    public var onMessage: (String) -> Void

    public init(controller: MapController, appModel: AppModel, hoverPoint: Binding<CGPoint?>,
                onAddVacancy: @escaping (String?) -> Void, onFill: @escaping (String) -> Void,
                onMessage: @escaping (String) -> Void) {
        self.controller = controller
        self.appModel = appModel
        self._hoverPoint = hoverPoint
        self.onAddVacancy = onAddVacancy
        self.onFill = onFill
        self.onMessage = onMessage
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MapSKView {
        let view = MapSKView(frame: .zero)
        view.preferredFramesPerSecond = 60
        let scene = MapSceneFactory.make(controller.mode, size: CGSize(width: 800, height: 600))
        view.presentScene(scene)
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.scene = scene
        coordinator.wire(view)
        coordinator.attach(controller, to: view)
        return view
    }

    public func updateNSView(_ view: MapSKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.observed !== controller { coordinator.attach(controller, to: view) }
        coordinator.syncMode(view)
    }

    public static func dismantleNSView(_ view: MapSKView, coordinator: Coordinator) {
        coordinator.detach()
        view.controller = nil
        coordinator.scene?.present(controller: nil)
        (view.scene as? MapScene)?.present(controller: nil)
        view.presentScene(nil)
    }

    /// Shows the scene for `controller.mode` in `view` unless `old` already is that mode's scene, and returns the scene now
    /// shown. The old scene stops reading the controller first, so the org chart does not rebuild fully expanded from the
    /// office's empty `collapsed` while it fades out; the new one cross-fades in over `modeFade` (at once under Reduce
    /// Motion) and is pointed at the controller. The camera then fits the new floor, unless an agent is followed: a followed
    /// agent stays followed in the other scene.
    @discardableResult
    static func switchScene(in view: MapSKView, from old: (any MapScene)?, to controller: MapController) -> any MapScene {
        if let old, old.mode == controller.mode { return old }
        old?.present(controller: nil)
        let scene = MapSceneFactory.make(controller.mode, size: old?.size ?? CGSize(width: 800, height: 600))
        if old == nil || view.shouldReduceMotion {
            view.presentScene(scene)
        } else {
            view.presentScene(scene, transition: .crossFade(withDuration: modeFade))
        }
        scene.present(controller: controller)
        if controller.follow == nil { controller.zoomToFit() }
        return scene
    }

    @MainActor
    public final class Coordinator {
        fileprivate var parent: OrgView!
        /// The scene this view presented last (during a cross-fade `view.scene` can still be the old one).
        fileprivate weak var scene: (any MapScene)?
        fileprivate private(set) weak var observed: MapController?

        fileprivate func wire(_ view: MapSKView) {
            view.onClick = { [weak self] hit, point in self?.click(hit, at: point) }
            view.onDoubleClick = { [weak self] hit, _ in self?.doubleClick(hit) }
            view.onHover = { [weak self] hit, point in self?.hover(hit, point) }
            view.onKey = { [weak self] c in self?.key(c) }
            view.onMessage = { [weak self] handle in self?.parent.onMessage(handle) }
            view.onFollow = { [weak self] id in self?.parent.controller.follow(id) }
            view.onAddVacancy = { [weak self] manager in self?.parent.onAddVacancy(manager) }
            view.onFill = { [weak self] handle in self?.parent.onFill(handle) }
            view.onRemoveVacancy = { [weak self] handle in self?.removeVacancy(handle) }
        }

        /// Points the view and scene at `controller` (a new company, or a new store), and shows its mode's scene.
        fileprivate func attach(_ controller: MapController, to view: MapSKView) {
            observed = controller
            view.controller = controller
            scene?.present(controller: controller)
            syncMode(view)
            observeMode(of: controller, in: view)
        }

        fileprivate func detach() {
            observed = nil
        }

        /// Shows the scene for the observed controller's mode.
        fileprivate func syncMode(_ view: MapSKView) {
            guard let controller = observed else { return }
            scene = OrgView.switchScene(in: view, from: scene, to: controller)
        }

        /// Follows `controller.mode` directly: the panel around this view does not read the mode, so nothing guarantees an
        /// `updateNSView` when an unlock switches it. Re-armed after each change while `controller` is the observed one.
        private func observeMode(of controller: MapController, in view: MapSKView) {
            withObservationTracking {
                _ = controller.mode
            } onChange: { [weak self, weak view, weak controller] in
                Task { @MainActor in
                    guard let self, let view, let controller, self.observed === controller else { return }
                    self.syncMode(view)
                    self.observeMode(of: controller, in: view)
                }
            }
        }

        private func click(_ hit: MapHit, at point: CGPoint) {
            let controller = parent.controller
            guard !controller.isInvalidated else { return }
            countForUnlock(hit)
            switch hit {
            case .stub(let id):
                controller.toggleSubtree(id)
            case .agent(let id) where (scene as? OrgScene)?.isExpandMarker(id, at: point) == true:
                controller.toggleSubtree(id)
            default:
                controller.handle(hit, appModel: parent.appModel)
            }
        }

        /// AppKit counts quick clicks up (2, 3, …), so every Board click after the first in a quick run arrives here: they
        /// count for the unlock too.
        private func doubleClick(_ hit: MapHit) {
            let controller = parent.controller
            guard !controller.isInvalidated else { return }
            countForUnlock(hit)
            if case .agent(let id) = hit { controller.follow(id) }
        }

        /// A click on the Board (its card, or the board room in the office) counts toward the unlock; any other click
        /// breaks the count. Both are no-ops once the office is unlocked.
        private func countForUnlock(_ hit: MapHit) {
            if case .owner = hit { parent.controller.officeBoardClick() } else { parent.controller.officeOtherClick() }
        }

        private func key(_ c: Character) {
            let controller = parent.controller
            guard !controller.isInvalidated else { return }
            controller.officeKey(c)
        }

        private func hover(_ hit: MapHit?, _ point: CGPoint?) {
            if case .agent(let id)? = hit, let point {
                // Observed state: set only what changed, so a still pointer does not invalidate views at 30 Hz.
                if parent.controller.hoveredAgentId != id { parent.controller.hoveredAgentId = id }
                parent.hoverPoint = point
            } else {
                if parent.controller.hoveredAgentId != nil { parent.controller.hoveredAgentId = nil }
                if parent.hoverPoint != nil { parent.hoverPoint = nil }
            }
        }

        private func removeVacancy(_ handle: String) {
            let controller = parent.controller
            let appModel = parent.appModel
            Task { @MainActor in
                do {
                    try await controller.removeVacancy(handle: handle)
                } catch {
                    appModel.errorMessage = "Couldn't remove the vacancy: " + MapText.clean(error.localizedDescription, max: 120)
                }
            }
        }
    }
}
