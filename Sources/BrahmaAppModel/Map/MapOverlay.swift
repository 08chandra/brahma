import Foundation

/// One chip in the map's bottom-left overlay.
public struct MapChip: Equatable, Sendable {
    public var text: String
    public var isWarning: Bool
    /// True when the chip has a × (the FOLLOWING chip's stops following).
    public var dismissible: Bool

    public init(text: String, isWarning: Bool, dismissible: Bool) {
        self.text = text; self.isWarning = isWarning; self.dismissible = dismissible
    }
}

/// The pure parts of the panel's overlays (Plan 4b Task 10a): which status chips show, and where the hover card goes.
public enum MapOverlay {
    /// The DROPPED chip shows this long after the queue last dropped traffic.
    public static let droppedChipSeconds: TimeInterval = 10
    static let handleLimit = 40
    /// The `YOU FOUND THE OFFICE` chip shows this long after the unlock (Plan 4c).
    public static let revealDuration: TimeInterval = 3

    /// `YOU FOUND THE OFFICE` first for `revealDuration` from `revealAt` (`MapController.officeRevealAt`),
    /// `AGGREGATE · <rate> MSG/S` while the queue aggregates, `FOLLOWING @h` while following (`followHandle` is the raw handle,
    /// without the `@`; it is cleaned here), `DROPPED <n>` for `droppedChipSeconds` after `stats.lastDropAt`. `now` and
    /// `lastDropAt` are map time.
    public static func chips(stats: MapStats, followHandle: String?, now: TimeInterval,
                             revealAt: TimeInterval? = nil) -> [MapChip] {
        var chips: [MapChip] = []
        if let revealAt, now >= revealAt, now - revealAt < revealDuration {
            chips.append(MapChip(text: "YOU FOUND THE OFFICE", isWarning: false, dismissible: false))
        }
        if stats.aggregate {
            let rate = stats.rate.isFinite ? Int(max(0, stats.rate).rounded()) : 0
            chips.append(MapChip(text: "AGGREGATE · \(rate) MSG/S", isWarning: true, dismissible: false))
        }
        if let followHandle {
            var handle = MapText.clean(followHandle, max: handleLimit)
            if handle.hasPrefix("@") { handle.removeFirst() }
            chips.append(MapChip(text: "FOLLOWING @" + handle, isWarning: false, dismissible: true))
        }
        if let last = stats.lastDropAt, now - last < droppedChipSeconds {
            chips.append(MapChip(text: "DROPPED \(stats.dropped)", isWarning: true, dismissible: false))
        }
        return chips
    }

    /// The origin of a hover card of `size` for a pointer at `p`, inside `bounds` (both from the same top-left origin): `offset`
    /// right of and below the pointer when it fits, else left of or above it, and always fully inside (pinned to the top left
    /// when it is bigger than the panel).
    public static func clamp(_ p: MapPoint2, size: MapPoint2, in bounds: MapPoint2, offset: Double = 12) -> MapPoint2 {
        MapPoint2(x: place(p.x, extent: size.x, within: bounds.x, offset: offset),
                  y: place(p.y, extent: size.y, within: bounds.y, offset: offset))
    }

    private static func place(_ p: Double, extent: Double, within limit: Double, offset: Double) -> Double {
        var origin = p + offset
        if origin + extent > limit { origin = p - offset - extent }
        return max(0, min(origin, limit - extent))
    }
}
