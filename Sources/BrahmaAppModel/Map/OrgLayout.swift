import Foundation
import BrahmaCore

/// The elbow from a parent card to a child card.
public struct OrgConnector: Equatable, Sendable {
    public var from: String
    public var to: String
    public var points: [MapPoint2]

    public init(from: String, to: String, points: [MapPoint2]) { self.from = from; self.to = to; self.points = points }
}

/// Where every visible node of an `OrgTree` is drawn. Board is at y = 0 and the tree grows downward; the output is a pure
/// function of the tree and the collapsed set.
///
///     measure(n): collapsed or no visible children → width card.w, height card.h (+ columnGap + stub.h if collapsed)
///       every visible child a leaf and count ≥ 2 → column: width indent + card.w,
///            height card.h + vGap/2 + Σ(child height + columnGap)
///       else horizontal: width max(card.w, Σ child widths + hGap·(k−1)), height card.h + vGap + max child height
///     place(n, x0, y): horizontal → card centred over [x0, x0+width]; column → card at x0, children at x0+indent stacked
///     connectors: elbow parent-bottom-mid → mid-gap y → child-top-mid; column → spine at x0+indent/2 with ticks
///     route(a,b): map ends through visibleAncestor; tree.path; hops ≤ 6 → card mids joined via the connector elbows
///                 on the path; else [mid(a), mid(b)]
public struct OrgLayout: Equatable, Sendable {
    public static let card = (w: 148.0, h: 44.0)
    public static let stub = (w: 148.0, h: 18.0)
    public static let vacancy = (w: 148.0, h: 32.0)
    public static let hGap = 16.0
    public static let vGap = 56.0
    public static let columnGap = 8.0
    public static let indent = 20.0
    /// A route longer than this many tree hops is drawn as a straight line.
    public static let maxTreeHops = 6

    /// Agents, "owner" and "vacancy:<id>".
    public var cards: [String: MapRect] = [:]
    /// Collapsed node → the "N more" stub under its card.
    public var stubs: [String: MapRect] = [:]
    public var connectors: [OrgConnector] = []
    /// Manager node → the bounding box of its visible subtree.
    public var teamBands: [String: MapRect] = [:]
    public var size: (w: Double, h: Double) = (0, 0)

    public init() {}

    public static func == (l: OrgLayout, r: OrgLayout) -> Bool {
        l.cards == r.cards && l.stubs == r.stubs && l.connectors == r.connectors && l.teamBands == r.teamBands
            && l.size.w == r.size.w && l.size.h == r.size.h
    }

    enum Mode { case leaf, column, horizontal }

    struct Measure {
        var w: Double
        var h: Double
        var mode: Mode
    }

    static func cardSize(_ id: String) -> (w: Double, h: Double) { id.hasPrefix("vacancy:") ? vacancy : card }

    // MARK: Make

    public static func make(tree: OrgTree, collapsed: Set<String>) -> OrgLayout {
        func node(_ id: String) -> OrgNode? { tree.nodes[id] }
        func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) && !(node(id)?.childIds.isEmpty ?? true) }
        func visibleChildren(_ id: String) -> [String] { isCollapsed(id) ? [] : (node(id)?.childIds ?? []) }

        // Measure bottom-up: `order` is pre-order, so every descendant follows its ancestor.
        var measures: [String: Measure] = [:]
        for id in tree.order.reversed() {
            let kids = visibleChildren(id)
            let own = cardSize(id)
            if kids.isEmpty {
                measures[id] = Measure(w: own.w, h: own.h + (isCollapsed(id) ? columnGap + stub.h : 0), mode: .leaf)
            } else if kids.count >= 2, kids.allSatisfy({ visibleChildren($0).isEmpty }) {
                let h = kids.reduce(own.h + vGap / 2) { $0 + measures[$1]!.h + columnGap }
                measures[id] = Measure(w: indent + card.w, h: h, mode: .column)
            } else {
                let total = kids.reduce(0) { $0 + measures[$1]!.w } + hGap * Double(kids.count - 1)
                let tallest = kids.map { measures[$0]!.h }.max() ?? 0
                measures[id] = Measure(w: max(own.w, total), h: own.h + vGap + tallest, mode: .horizontal)
            }
        }

        // Place top-down from Board at (0, 0), children in tree order.
        var layout = OrgLayout()
        var stack: [(id: String, x0: Double, y: Double)] = [(tree.rootId, 0, 0)]
        while let top = stack.popLast() {
            let (id, x0, y) = top
            guard let m = measures[id] else { continue }
            let own = cardSize(id)
            let kids = visibleChildren(id)
            let rect: MapRect
            switch m.mode {
            case .leaf:
                rect = MapRect(x: x0, y: y, w: own.w, h: own.h)
                if isCollapsed(id) {
                    layout.stubs[id] = MapRect(x: x0, y: y + own.h + columnGap, w: stub.w, h: stub.h)
                }
            case .column:
                rect = MapRect(x: x0, y: y, w: own.w, h: own.h)
                let spineX = x0 + indent / 2
                var cy = y + own.h + vGap / 2
                var pending: [(id: String, x0: Double, y: Double)] = []
                for k in kids {
                    let kh = cardSize(k).h
                    layout.connectors.append(OrgConnector(from: id, to: k, points: [
                        MapPoint2(x: spineX, y: y + own.h),
                        MapPoint2(x: spineX, y: cy + kh / 2),
                        MapPoint2(x: x0 + indent, y: cy + kh / 2),
                    ]))
                    pending.append((k, x0 + indent, cy))
                    cy += measures[k]!.h + columnGap
                }
                stack.append(contentsOf: pending.reversed())
            case .horizontal:
                rect = MapRect(x: x0 + (m.w - own.w) / 2, y: y, w: own.w, h: own.h)
                let total = kids.reduce(0) { $0 + measures[$1]!.w } + hGap * Double(kids.count - 1)
                var cx = x0 + (m.w - total) / 2
                let childY = y + own.h + vGap
                let gapY = y + own.h + vGap / 2
                var pending: [(id: String, x0: Double, y: Double)] = []
                for k in kids {
                    let km = measures[k]!
                    let kw = cardSize(k).w
                    // A child's card is centred over its own width whatever its mode (a leaf or column is as wide as its card).
                    let childMidX = cx + (km.mode == .horizontal ? km.w / 2 : kw / 2)
                    layout.connectors.append(OrgConnector(from: id, to: k, points: [
                        MapPoint2(x: rect.mid.x, y: y + own.h),
                        MapPoint2(x: rect.mid.x, y: gapY),
                        MapPoint2(x: childMidX, y: gapY),
                        MapPoint2(x: childMidX, y: childY),
                    ]))
                    pending.append((k, cx, childY))
                    cx += km.w + hGap
                }
                stack.append(contentsOf: pending.reversed())
            }
            layout.cards[id] = rect
        }

        // Team bands: a manager's card, stub and visible descendants.
        for id in tree.order where node(id)?.tier == .manager && layout.cards[id] != nil {
            var band = layout.cards[id]!
            var walk = [id]
            while let n = walk.popLast() {
                for r in [layout.cards[n], layout.stubs[n]].compactMap({ $0 }) { band = union(band, r) }
                walk.append(contentsOf: visibleChildren(n))
            }
            layout.teamBands[id] = band
        }

        var w = 0.0, h = 0.0
        for r in layout.cards.values { w = max(w, r.x + r.w); h = max(h, r.y + r.h) }
        for r in layout.stubs.values { w = max(w, r.x + r.w); h = max(h, r.y + r.h) }
        layout.size = (w, h)
        return layout
    }

    static func union(_ a: MapRect, _ b: MapRect) -> MapRect {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return MapRect(x: x, y: y, w: max(a.x + a.w, b.x + b.w) - x, h: max(a.y + a.h, b.y + b.h) - y)
    }

    // MARK: Route

    /// The polyline a flow between `a` and `b` follows: card mids joined by the connector elbows along the tree path
    /// when it is at most `maxTreeHops` long, else a straight line. Ends inside a collapsed subtree move to the collapsed
    /// node. Empty when either end is unknown.
    public func route(_ a: String, _ b: String, tree: OrgTree, collapsed: Set<String>) -> [MapPoint2] {
        let a1 = tree.visibleAncestor(a, collapsed: collapsed), b1 = tree.visibleAncestor(b, collapsed: collapsed)
        guard let ca = cards[a1], let cb = cards[b1] else { return [] }
        let path = tree.path(a1, b1)
        guard !path.isEmpty else { return [] }
        if path.count == 1 { return [ca.mid] }
        if path.count - 1 > OrgLayout.maxTreeHops { return [ca.mid, cb.mid] }
        var byEnds: [String: OrgConnector] = [:]
        for c in connectors { byEnds["\(c.from)\u{0}\(c.to)"] = c }
        var points = [ca.mid]
        for (x, y) in zip(path, path.dropFirst()) {
            if let down = byEnds["\(x)\u{0}\(y)"] {
                points.append(contentsOf: down.points)
            } else if let up = byEnds["\(y)\u{0}\(x)"] {
                points.append(contentsOf: up.points.reversed())
            }
            if let mid = cards[y]?.mid { points.append(mid) }
        }
        return points
    }
}
