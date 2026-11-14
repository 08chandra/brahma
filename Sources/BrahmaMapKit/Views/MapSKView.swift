import AppKit
import SpriteKit
import BrahmaAppModel

/// What `MapSKView` needs from the scene it shows: hit tests in scene coordinates, a zoom it clamps itself, and a note that
/// the owner moved the camera by hand. `OrgScene` conforms; Plan 4c's scenes will too.
@MainActor
public protocol MapInteractive: AnyObject {
    var zoom: Double { get set }
    func hit(at scenePoint: CGPoint) -> MapHit?
    func userMovedCamera()
}

/// The context menu, as data. Built only from what `MapController.actions(for:)` returned (nothing is decided per hit type
/// here), so the menu and the controller's rules cannot drift apart.
public enum MapMenu {
    public struct Entry: Equatable, Sendable {
        public var title: String
        public var action: MapAction
    }

    /// One entry per action, in order. Titles that name an agent use `MapText.clean` on the handle (an action carries the
    /// raw name). While a replay is on, the write items (Add vacancy, Fill…, Remove vacancy) are left out: the
    /// controller does not gate them. `Fill…` ends in an ellipsis because a confirmation follows.
    public static func entries(for actions: [MapAction], replaying: Bool) -> [Entry] {
        actions.compactMap { action in
            switch action {
            case .message(let handle):
                return Entry(title: "Message " + at(handle), action: action)
            case .follow:
                return Entry(title: "Follow", action: action)
            case .addVacancy(let handle):
                guard !replaying else { return nil }
                return Entry(title: handle.map { "Add vacancy under " + at($0) } ?? "Add vacancy", action: action)
            case .fill:
                return replaying ? nil : Entry(title: "Fill…", action: action)
            case .removeVacancy:
                return replaying ? nil : Entry(title: "Remove vacancy", action: action)
            }
        }
    }

    /// "@" and the cleaned handle (one leading "@" of the handle itself is not doubled).
    private static func at(_ handle: String) -> String {
        let clean = MapText.clean(handle, max: 32)
        return "@" + (clean.hasPrefix("@") ? String(clean.dropFirst()) : clean)
    }
}

/// Lets a hover through at most 30 times a second. Time is the event's own timestamp.
public struct HoverThrottle: Sendable {
    public var interval: TimeInterval
    private var last: TimeInterval?

    public init(interval: TimeInterval = 1.0 / 30) { self.interval = interval }

    /// Seconds until a hover is allowed again (0 when one is allowed at `t`); the time to wait before flushing the last one.
    public func remaining(at t: TimeInterval) -> TimeInterval {
        guard let last, t >= last else { return 0 }
        return Swift.max(0, interval - (t - last))
    }

    /// Counts a hover delivered at `t` (the trailing flush) as the last one.
    public mutating func record(_ t: TimeInterval) { last = t }

    /// True when a hover at `t` should be handled. A clock that went backwards lets the event through.
    public mutating func allow(_ t: TimeInterval) -> Bool {
        if let last, t >= last, t - last < interval { return false }
        last = t
        return true
    }
}

/// The SpriteKit view of a map: drag to pan, scroll or pinch to zoom (about the cursor), hover and click hit tests (hover
/// at 30 Hz), double click, and the right-click menu. It knows no scene type: hits come from the scene's `MapInteractive`
/// conformance, the menu from `controller.actions(for:)`. Everything it finds goes out through closures.
@MainActor
public final class MapSKView: SKView {
    public weak var controller: MapController?

    /// A click on a hit, with the scene point it landed on. A click on empty chart is not reported.
    public var onClick: ((MapHit, CGPoint) -> Void)?
    public var onDoubleClick: ((MapHit, CGPoint) -> Void)?
    /// The hit under the pointer (nil: nothing) and the pointer in view coordinates with the origin at the top left, the
    /// space a SwiftUI overlay uses. Called at most 30 times a second; nil, nil when the pointer leaves.
    public var onHover: ((MapHit?, CGPoint?) -> Void)?
    public var onMessage: ((String) -> Void)?
    public var onFollow: ((String) -> Void)?
    public var onAddVacancy: ((String?) -> Void)?
    /// Opens the confirmation; nothing fills from here.
    public var onFill: ((String) -> Void)?
    public var onRemoveVacancy: ((String) -> Void)?

    private var hoverThrottle = HoverThrottle()
    /// The latest hover the throttle held back (view point, and the event time it is due at).
    private var pendingHover: (point: CGPoint, at: TimeInterval)?
    private var flushScheduled = false
    private var trackingArea: NSTrackingArea?
    private var drag: (start: CGPoint, camera: CGPoint, moved: Bool)?
    /// Pointer travel below this is a click, not a drag.
    private static let dragSlop: CGFloat = 3

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) { fatalError("MapSKView is built in code") }

    private var interactive: MapInteractive? { scene as? MapInteractive }

    // MARK: Tracking

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Hit tests

    private func scenePoint(_ event: NSEvent) -> CGPoint? {
        guard let scene else { return nil }
        return scene.convertPoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func hit(_ event: NSEvent) -> (hit: MapHit, point: CGPoint)? {
        guard let point = scenePoint(event), let hit = interactive?.hit(at: point) else { return nil }
        return (hit, point)
    }

    // MARK: Mouse

    public override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let wait = hoverThrottle.remaining(at: event.timestamp)
        if wait <= 0, hoverThrottle.allow(event.timestamp) {
            pendingHover = nil
            deliverHover(at: local)
            return
        }
        // Too soon: keep the latest position and deliver it when the interval is up, so the pointer's resting place is
        // never lost to the throttle.
        pendingHover = (local, event.timestamp + wait)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flushHover() }
    }

    private func flushHover() {
        flushScheduled = false
        guard let pending = pendingHover else { return }
        pendingHover = nil
        hoverThrottle.record(pending.at)
        deliverHover(at: pending.point)
    }

    private func deliverHover(at local: CGPoint) {
        var found: MapHit?
        if let scene {
            found = interactive?.hit(at: scene.convertPoint(fromView: local))
        }
        onHover?(found, CGPoint(x: local.x, y: bounds.height - local.y))
    }

    public override func mouseExited(with event: NSEvent) {
        pendingHover = nil
        onHover?(nil, nil)
    }

    public override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        drag = (start, scene?.camera?.position ?? .zero, false)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard var d = drag, let camera = scene?.camera else { return }
        let here = convert(event.locationInWindow, from: nil)
        let dx = here.x - d.start.x, dy = here.y - d.start.y
        if !d.moved && hypot(dx, dy) < Self.dragSlop { return }
        d.moved = true
        drag = d
        // The chart follows the pointer: the camera moves the other way, by the screen distance in scene points.
        camera.position = CGPoint(x: d.camera.x - dx * camera.xScale, y: d.camera.y - dy * camera.yScale)
        interactive?.userMovedCamera()
    }

    public override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard drag?.moved == false, let found = hit(event) else { return }
        if event.clickCount >= 2 { onDoubleClick?(found.hit, found.point) } else { onClick?(found.hit, found.point) }
    }

    // MARK: Zoom

    public override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        zoom(by: exp(delta * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)), at: convert(event.locationInWindow, from: nil))
    }

    public override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    /// Zooms by `factor` (the scene clamps to its range) keeping the scene point under `viewPoint` where it is.
    private func zoom(by factor: CGFloat, at viewPoint: CGPoint) {
        guard factor.isFinite, factor > 0, let scene, let interactive, let camera = scene.camera else { return }
        let before = scene.convertPoint(fromView: viewPoint)
        interactive.zoom *= Double(factor)
        let after = scene.convertPoint(fromView: viewPoint)
        camera.position = CGPoint(x: camera.position.x + before.x - after.x, y: camera.position.y + before.y - after.y)
        interactive.userMovedCamera()
    }

    // MARK: Context menu

    /// Right click (and control click): the menu for what is under the pointer, from `controller.actions(for:)` and nothing
    /// else; no menu when there are no actions.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller, let found = hit(event) else { return nil }
        let entries = MapMenu.entries(for: controller.actions(for: found.hit), replaying: controller.replay != nil)
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            menu.addItem(ActionMenuItem(title: entry.title) { [weak self] in self?.perform(entry.action) })
        }
        return menu
    }

    private func perform(_ action: MapAction) {
        switch action {
        case .message(let handle): onMessage?(handle)
        case .follow(let id): onFollow?(id)
        case .addVacancy(let manager): onAddVacancy?(manager)
        case .fill(let handle): onFill?(handle)
        case .removeVacancy(let handle): onRemoveVacancy?(handle)
        }
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("ActionMenuItem is built in code") }

    @objc private func fire() { handler() }
}

extension OrgScene: MapInteractive {}
