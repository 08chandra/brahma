import Testing
import Foundation
@testable import BrahmaAppModel

@Suite(.scratch) struct MapOverlayTests {
    private func stats(aggregate: Bool = false, rate: Double = 0, dropped: Int = 0, lastDropAt: TimeInterval? = nil) -> MapStats {
        MapStats(ingested: 0, spawned: 0, coalesced: 0, aggregated: 0, dropped: dropped, queued: 0, active: 0, rate: rate,
                 aggregate: aggregate, lastDropAt: lastDropAt)
    }

    @Test func chipsShowAggregateFollowingDropped() {
        let now: TimeInterval = 100
        #expect(MapOverlay.chips(stats: stats(), followHandle: nil, now: now) == [])

        let aggregate = MapOverlay.chips(stats: stats(aggregate: true, rate: 42), followHandle: nil, now: now)
        #expect(aggregate == [MapChip(text: "AGGREGATE · 42 MSG/S", isWarning: true, dismissible: false)])
        // Rate is rounded; not aggregating, no chip however busy.
        #expect(MapOverlay.chips(stats: stats(aggregate: true, rate: 41.6), followHandle: nil, now: now).first?.text
                == "AGGREGATE · 42 MSG/S")
        #expect(MapOverlay.chips(stats: stats(aggregate: false, rate: 500), followHandle: nil, now: now) == [])

        // The handle is cleaned (bidi override gone) and the chip can be dismissed.
        let following = MapOverlay.chips(stats: stats(), followHandle: "eng\u{202E}x", now: now)
        #expect(following == [MapChip(text: "FOLLOWING @engx", isWarning: false, dismissible: true)])

        // Dropped shows for 10 s after the last drop.
        let recent = MapOverlay.chips(stats: stats(dropped: 7, lastDropAt: now - 3), followHandle: nil, now: now)
        #expect(recent == [MapChip(text: "DROPPED 7", isWarning: true, dismissible: false)])
        #expect(MapOverlay.chips(stats: stats(dropped: 7, lastDropAt: now - 11), followHandle: nil, now: now) == [])
        #expect(MapOverlay.chips(stats: stats(dropped: 7, lastDropAt: now - 10), followHandle: nil, now: now) == [])
        #expect(MapOverlay.chips(stats: stats(dropped: 7, lastDropAt: nil), followHandle: nil, now: now) == [])

        // All three, in order.
        let all = MapOverlay.chips(stats: stats(aggregate: true, rate: 9, dropped: 2, lastDropAt: now - 1),
                                   followHandle: "cto", now: now)
        #expect(all.map(\.text) == ["AGGREGATE · 9 MSG/S", "FOLLOWING @cto", "DROPPED 2"])
    }

    @Test func followingChipCleansHandleAndAgentText() {
        // A handle that is only invisible characters cleans to the placeholder, never to raw text.
        let chips = MapOverlay.chips(stats: stats(), followHandle: "\u{202E}\u{200B}", now: 0)
        #expect(chips.map(\.text) == ["FOLLOWING @—"])
        // Long handles are clipped.
        let long = MapOverlay.chips(stats: stats(), followHandle: String(repeating: "x", count: 500), now: 0)
        #expect((long.first?.text.count ?? 999) < 80)
    }

    @Test func hoverCardClampedIntoPanel() {
        let bounds = MapPoint2(x: 800, y: 600)
        let size = MapPoint2(x: 240, y: 160)
        // In the middle: 12 pt from the pointer.
        #expect(MapOverlay.clamp(MapPoint2(x: 300, y: 200), size: size, in: bounds) == MapPoint2(x: 312, y: 212))
        #expect(MapOverlay.clamp(MapPoint2(x: 300, y: 200), size: size, in: bounds, offset: 20) == MapPoint2(x: 320, y: 220))
        // Near the right and bottom edges: moves left and up, fully inside.
        let edge = MapOverlay.clamp(MapPoint2(x: 790, y: 590), size: size, in: bounds)
        #expect(edge.x + size.x <= bounds.x); #expect(edge.y + size.y <= bounds.y)
        #expect(edge.x == 790 - 12 - size.x); #expect(edge.y == 590 - 12 - size.y)
        // Never past the top-left either.
        let corner = MapOverlay.clamp(MapPoint2(x: -50, y: -50), size: size, in: bounds)
        #expect(corner.x >= 0); #expect(corner.y >= 0)
        // A card bigger than the panel pins to the origin.
        let huge = MapOverlay.clamp(MapPoint2(x: 100, y: 100), size: MapPoint2(x: 900, y: 700), in: bounds)
        #expect(huge == MapPoint2(x: 0, y: 0))
        // Flipping would run off the left edge: the card pins inside instead.
        let narrow = MapOverlay.clamp(MapPoint2(x: 150, y: 50), size: MapPoint2(x: 200, y: 40), in: MapPoint2(x: 300, y: 300))
        #expect(narrow.x >= 0); #expect(narrow.x + 200 <= 300)
    }
}
