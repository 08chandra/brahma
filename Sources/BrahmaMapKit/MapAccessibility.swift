import AppKit
import SpriteKit
import BrahmaAppModel

/// One thing VoiceOver can reach on the map: a desk or a room. Every label is built only from fields that are already
/// `MapText.clean` output (handle, role, state label, item, a vacancy's role title, a room's fixed title) and app-formatted
/// integers; nothing re-reads raw agent text.
public struct MapAccessibilityItem: Equatable {
    /// A desk id (an agent id or `"vacancy:<id>"`) or a room id (`"room:board"` …).
    public var id: String
    public var label: String
    /// In scene coordinates.
    public var frame: CGRect
    /// What a mouse click on it hits; a VoiceOver press does the same. Nil for a room a click does nothing on (it is
    /// read, not pressed).
    public var hit: MapHit?

    public init(id: String, label: String, frame: CGRect, hit: MapHit?) {
        self.id = id; self.label = label; self.frame = frame; self.hit = hit
    }
}

/// A scene that gives VoiceOver elements (spec §5.6). Only `OfficeScene` in 4c: the org chart would add hundreds of
/// entries to Plan P's frozen screen inventory; it can conform later with an approved inventory update.
@MainActor
public protocol MapAccessible: AnyObject {
    /// Changes whenever the items may have changed (structure, states, items, open asks).
    var accessibilityRevision: Int { get }
    /// The items in reading order, at most `limit`.
    func accessibilityItems(limit: Int) -> [MapAccessibilityItem]
}

/// A scene that can turn its motion down for the system's Reduce Motion setting.
@MainActor
public protocol MapMotionReducible: AnyObject {
    var reduceMotion: Bool { get set }
}

/// The element `MapSKView` gives VoiceOver for one item. Its frame is computed when asked, from the camera as it is then,
/// so panning and zooming never leave a stale frame; a press goes through the view's `onClick`, the mouse's path. Not
/// main-actor isolated, like its AppKit superclass; it is made and used on the main thread only.
final class MapAccessibilityElement: NSAccessibilityElement {
    private(set) var item: MapAccessibilityItem
    private weak var view: MapSKView?

    init(item: MapAccessibilityItem, view: MapSKView) {
        self.item = item
        self.view = view
        super.init()
        setAccessibilityElement(true)
        setAccessibilityParent(view)
        apply()
    }

    func update(_ item: MapAccessibilityItem) {
        guard item != self.item else { return }
        self.item = item
        apply()
    }

    private func apply() {
        setAccessibilityRole(item.hit == nil ? .staticText : .button)
        setAccessibilityLabel(item.label)
    }

    // AppKit's accessibility methods are nonisolated; the accessibility client calls them on the main thread, where the
    // view is reached.
    override func accessibilityFrame() -> NSRect {
        guard let view else { return .zero }
        let frame = item.frame
        return MainActor.assumeIsolated { view.screenRect(sceneRect: frame) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let hit = item.hit, let view else { return false }
        let centre = CGPoint(x: item.frame.midX, y: item.frame.midY)
        MainActor.assumeIsolated { view.onClick?(hit, centre) }
        return true
    }
}
