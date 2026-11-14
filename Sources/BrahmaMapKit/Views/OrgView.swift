import AppKit
import SpriteKit
import SwiftUI
import BrahmaAppModel

/// The org chart in SwiftUI: a `MapSKView` showing an `OrgScene` that the controller drives. Each frame the scene calls
/// `controller.frame(now:)` and plays what comes back; the scene rebuilds when the tree, the collapsed set or the
/// former-agents toggle changed. Clicks go to `controller.handle`, except that a click on a stub (or on a manager's `▾`)
/// expands or collapses the subtree and a double click follows the agent. The right-click menu comes from
/// `controller.actions(for:)`; `Fill…` only calls `onFill`, which opens the confirmation sheet.
public struct OrgView: NSViewRepresentable {
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
        let scene = OrgScene(size: CGSize(width: 800, height: 600))
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
    }

    public static func dismantleNSView(_ view: MapSKView, coordinator: Coordinator) {
        coordinator.detach()
        view.controller = nil
        (view.scene as? OrgScene)?.present(controller: nil)
        view.presentScene(nil)
    }

    @MainActor
    public final class Coordinator {
        fileprivate var parent: OrgView!
        fileprivate weak var scene: OrgScene?
        fileprivate private(set) weak var observed: MapController?

        fileprivate func wire(_ view: MapSKView) {
            view.onClick = { [weak self] hit, point in self?.click(hit, at: point) }
            view.onDoubleClick = { [weak self] hit, _ in
                if case .agent(let id) = hit { self?.parent.controller.follow(id) }
            }
            view.onHover = { [weak self] hit, point in self?.hover(hit, point) }
            view.onMessage = { [weak self] handle in self?.parent.onMessage(handle) }
            view.onFollow = { [weak self] id in self?.parent.controller.follow(id) }
            view.onAddVacancy = { [weak self] manager in self?.parent.onAddVacancy(manager) }
            view.onFill = { [weak self] handle in self?.parent.onFill(handle) }
            view.onRemoveVacancy = { [weak self] handle in self?.removeVacancy(handle) }
        }

        /// Points the view and scene at `controller` (a new company, or a new store).
        fileprivate func attach(_ controller: MapController, to view: MapSKView) {
            observed = controller
            view.controller = controller
            scene?.present(controller: controller)
        }

        fileprivate func detach() {
            observed = nil
        }

        private func click(_ hit: MapHit, at point: CGPoint) {
            let controller = parent.controller
            guard !controller.isInvalidated else { return }
            switch hit {
            case .stub(let id):
                controller.toggleSubtree(id)
            case .agent(let id) where scene?.isExpandMarker(id, at: point) == true:
                controller.toggleSubtree(id)
            default:
                controller.handle(hit, appModel: parent.appModel)
            }
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
