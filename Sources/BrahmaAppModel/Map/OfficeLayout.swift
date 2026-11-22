import Foundation
import BrahmaCore

/// What an office room is for.
public enum OfficeRoomKind: Hashable, Sendable {
    case board, ceo
    case executive(agentId: String)
    case director(agentId: String)
    case review, breakRoom, mail
}

/// A walled room: the board room, an office, or a shared room of the bottom strip.
public struct OfficeRoom: Identifiable, Equatable, Sendable {
    /// "room:board" | "room:ceo" | "office:<agentId>" | "room:review" | "room:break" | "room:mail".
    public var id: String
    public var kind: OfficeRoomKind
    public var rect: MapRect
    /// A fixed title; an executive office's cleaned role; a director office's cleaned handle (it names the wing).
    public var title: String
    /// The middle of the wall that faces the corridor.
    public var door: MapPoint2

    public init(id: String, kind: OfficeRoomKind, rect: MapRect, title: String, door: MapPoint2) {
        self.id = id; self.kind = kind; self.rect = rect; self.title = title; self.door = door
    }
}

/// A team's carpet: the head desk (when its owner has no office) above two facing columns of desks.
public struct OfficePod: Identifiable, Equatable, Sendable {
    /// "pod:<managerId>" | "pod:dept:<department>".
    public var id: String
    public var managerId: String?
    public var rect: MapRect
    /// The team card title, or the department title.
    public var title: String
    public var department: Department
    /// The band just above the pod that holds its title.
    public var labelRect: MapRect
    /// The pin board in the head row, where a broadcast note is pinned.
    public var board: MapPoint2

    public init(id: String, managerId: String?, rect: MapRect, title: String, department: Department, labelRect: MapRect,
                board: MapPoint2) {
        self.id = id; self.managerId = managerId; self.rect = rect; self.title = title; self.department = department
        self.labelRect = labelRect; self.board = board
    }
}

/// One desk: its top and front face (`rect`), and the chair's centre (`seat`).
public struct OfficeDesk: Identifiable, Equatable, Sendable {
    /// The agent id, or "vacancy:<id>".
    public var id: String
    public var rect: MapRect
    public var seat: MapPoint2
    public var podId: String?
    /// The office the desk stands in. Nil for a pod desk and for a seat in the board room's anteroom.
    public var roomId: String?
    /// The sitter faces down the floor: the chair is above the desk. Otherwise it is below.
    public var facesDown: Bool

    public init(id: String, rect: MapRect, seat: MapPoint2, podId: String?, roomId: String?, facesDown: Bool) {
        self.id = id; self.rect = rect; self.seat = seat; self.podId = podId; self.roomId = roomId
        self.facesDown = facesDown
    }
}

/// A director's office and pods, or the FLOOR wing for the pods under no director.
public struct OfficeWing: Identifiable, Equatable, Sendable {
    /// "wing:<directorId>" | "wing:floor".
    public var id: String
    /// The director's handle, or "FLOOR".
    public var title: String
    /// The bounding box of the wing's office, pods and pod labels.
    public var rect: MapRect
    public var officeId: String?
    /// In placement order (tree order, department pods last).
    public var podIds: [String]

    public init(id: String, title: String, rect: MapRect, officeId: String?, podIds: [String]) {
        self.id = id; self.title = title; self.rect = rect; self.officeId = officeId; self.podIds = podIds
    }
}

/// The office floor plan (spec §5.2): a pure function of the `MapModel`. y grows downward from the top wall.
///
///     top strip (y 0):  board room at x 0 · the anteroom (orphan seats) · one office per C-suite agent · CEO flush right
///     corridor
///     wing rows:        [left corridor] wing · wingGap · wing … [corridor];
///                       a wing: its office · corridor · pod · corridor · pod …
///                       a 16 pt label band above the items; a corridor below; rows wrap at max(1 600, top strip width),
///                       widened in corridor steps while that brings the floor closer to 5 : 3 (500 agents ≤ 3 000 × 1 800)
///     rooms strip:      break room at x 0 · review room centred · mail room flush right (the last `roomsStrip` points)
///
///     pods:   a pod per agent whose reports include an agent with no reports and no office, or a seat; also for an
///             office-less agent whose reports all have their own (its head desk). Head desk = the owner, unless the owner
///             has an office (CEO, C-suite, director). Members: those reports in tree order, then the seats.
///     wings:  per director in tree order (its office, then the pods whose nearest director-or-self is it); then FLOOR
///             (the pods under no director, then a pod per department for the office-less, report-less roots)
///     route:  start → nearest corridor point → corridor centrelines (shortest, Manhattan) → nearest point to the end → end
public struct OfficeLayout: Equatable, Sendable {
    public static let desk = (w: 36.0, h: 24.0, face: 6.0)
    public static let chair = (w: 12.0, h: 8.0)
    public static let pod = (columns: 2, gap: 8.0, aisle: 16.0, padding: 12.0, head: 36.0)
    public static let corridor = 32.0
    public static let wingGap = 48.0
    public static let roomsStrip = 140.0
    public static let boardRoom = (w: 200.0, h: 120.0)
    public static let ceoOffice = (w: 160.0, h: 120.0)
    public static let execOffice = (w: 120.0, h: 100.0)
    public static let directorOffice = (w: 120.0, h: 100.0)
    public static let reviewRoom = (w: 260.0, h: 120.0)
    public static let breakRoom = (w: 180.0, h: 120.0)
    public static let mailRoom = (w: 160.0, h: 120.0)
    public static let reviewSeats = 12
    public static let doorSpots = 8

    /// The band above a wing row's items that holds the pod labels.
    static let labelBand = 16.0
    /// Wing rows wrap past the wider of this and the top strip at least; wider when that brings the floor closer to
    /// `aspect` (w : h), searched in corridor steps up to `maxWrapGrowth` more.
    static let minRowWidth = 1600.0
    static let aspect = 5.0 / 3.0
    static let maxWrapGrowth = 2400.0
    /// Distance between standing spots (a figure is 10 pt wide).
    static let spotSpacing = 14.0
    static let reviewTable = (w: 160.0, h: 40.0)

    /// The desk top plus its front face.
    static var deskDepth: Double { desk.h + desk.face }
    static var podWidth: Double {
        2 * pod.padding + Double(pod.columns) * desk.w + Double(pod.columns - 1) * pod.aisle
    }
    static var podRow: Double { desk.h + desk.face + chair.h + pod.gap }
    static func podHeight(desks n: Int) -> Double {
        pod.head + Double((n + pod.columns - 1) / pod.columns) * podRow
    }

    public var rooms: [String: OfficeRoom] = [:]
    public var pods: [String: OfficePod] = [:]
    public var desks: [String: OfficeDesk] = [:]
    public var corridors: [MapRect] = []
    public var wings: [OfficeWing] = []
    /// Beside the board room: the seats whose manager is gone. Nil when there are none.
    public var anteroom: MapRect?
    public var size: (w: Double, h: Double) = (0, 0)

    public init() {}

    public static func == (l: OfficeLayout, r: OfficeLayout) -> Bool {
        l.rooms == r.rooms && l.pods == r.pods && l.desks == r.desks && l.corridors == r.corridors && l.wings == r.wings
            && l.anteroom == r.anteroom && l.size.w == r.size.w && l.size.h == r.size.h
    }

    // MARK: - Make

    struct PodSpec {
        var id: String
        var managerId: String?
        var head: String?
        var members: [String]
        var title: String
        var department: Department
    }

    enum Item {
        case office(String)
        case pod(PodSpec)

        var size: (w: Double, h: Double) {
            switch self {
            case .office: (OfficeLayout.directorOffice.w, OfficeLayout.directorOffice.h)
            case .pod(let p): (OfficeLayout.podWidth, OfficeLayout.podHeight(desks: p.members.count))
            }
        }
    }

    struct WingSpec {
        var id: String
        var title: String
        var officeId: String?
        var items: [Item]
    }

    struct Placed {
        var item: Item
        var x: Double
        var wing: Int
    }

    struct Row {
        var y = 0.0
        var h = 0.0
        /// Vertical corridors: (x, width).
        var aisles: [(x: Double, w: Double)] = [(0, OfficeLayout.corridor)]
        var placed: [Placed] = []
        var end = OfficeLayout.corridor
    }

    public static func make(model: MapModel) -> OfficeLayout {
        let tree = model.tree
        func isAgent(_ id: String) -> Bool { id != tree.rootId && !id.hasPrefix("vacancy:") && tree.nodes[id] != nil }
        func isSeat(_ id: String) -> Bool { id.hasPrefix("vacancy:") }
        func hasOffice(_ id: String) -> Bool {
            switch tree.nodes[id]?.tier {
            case .ceo?, .csuite?, .director?: true
            default: false
            }
        }
        func hasReports(_ id: String) -> Bool { !(tree.nodes[id]?.childIds.isEmpty ?? true) }
        func department(_ id: String) -> Department { model.agents[id]?.department ?? .engineering }

        // The team band a manager leads gives its pod's carpet the colour of its card title.
        var teamDepartment: [String: Department] = [:]
        for g in model.groups where g.id.hasPrefix("team:") { for id in g.memberIds { teamDepartment[id] = g.department } }
        /// The owner's team department; else the most common department among the members (ties in enum order); else
        /// the owner's.
        func podDepartment(owner: String, members: [String]) -> Department {
            if let d = teamDepartment[owner], model.teamCard(managerId: owner) != nil { return d }
            var counts: [Department: Int] = [:]
            for m in members where isAgent(m) { counts[department(m), default: 0] += 1 }
            var best: Department?
            for d in Department.allCases {
                guard let c = counts[d] else { continue }
                if best == nil || c > counts[best!]! { best = d }
            }
            return best ?? department(owner)
        }

        // 1. Walk the tree: offices, pods, department members and orphan seats.
        var ceoId: String?
        var execIds: [String] = []
        var directorIds: [String] = []
        var agentPods: [PodSpec] = []
        var deptMembers: [Department: [String]] = [:]
        var orphanSeats: [String] = []
        for id in tree.order {
            guard let node = tree.nodes[id] else { continue }
            if id == tree.rootId {
                for k in node.childIds {
                    if isSeat(k) { orphanSeats.append(k) }
                    else if !hasOffice(k) && !hasReports(k) { deptMembers[department(k), default: []].append(k) }
                }
                continue
            }
            guard isAgent(id) else { continue }
            switch node.tier {
            case .ceo: if ceoId == nil { ceoId = id } else { execIds.append(id) }
            case .csuite: execIds.append(id)
            case .director: directorIds.append(id)
            default: break
            }
            let reports = node.childIds.filter { isAgent($0) && !hasOffice($0) && !hasReports($0) }
            let seats = node.childIds.filter(isSeat)
            let head = hasOffice(id) ? nil : id
            guard !reports.isEmpty || !seats.isEmpty || (head != nil && hasReports(id)) else { continue }
            let dept = podDepartment(owner: id, members: reports)
            agentPods.append(PodSpec(id: "pod:\(id)", managerId: id, head: head, members: reports + seats,
                                     title: model.teamCard(managerId: id)?.title ?? dept.title, department: dept))
        }

        // 2. Wings: each director's, then FLOOR (pods under no director, then the department pods).
        var byDirector: [String: [PodSpec]] = [:]
        var floor: [PodSpec] = []
        for p in agentPods {
            let owner = p.managerId!
            if let d = ([owner] + tree.ancestors(owner)).first(where: { tree.nodes[$0]?.tier == .director }) {
                byDirector[d, default: []].append(p)
            } else {
                floor.append(p)
            }
        }
        for d in Department.allCases {
            guard let members = deptMembers[d] else { continue }
            floor.append(PodSpec(id: "pod:dept:\(d.rawValue)", managerId: nil, head: nil, members: members, title: d.title,
                                 department: d))
        }
        var wingSpecs: [WingSpec] = directorIds.map { d in
            WingSpec(id: "wing:\(d)", title: model.agents[d]?.handle ?? MapText.empty, officeId: "office:\(d)",
                     items: [.office(d)] + (byDirector[d] ?? []).map(Item.pod))
        }
        if !floor.isEmpty {
            wingSpecs.append(WingSpec(id: "wing:floor", title: "FLOOR", officeId: nil, items: floor.map(Item.pod)))
        }

        // 3. The top strip's widths.
        let anteRows = (orphanSeats.count + pod.columns - 1) / pod.columns
        let anteW = orphanSeats.isEmpty ? 0 : podWidth
        let anteH = orphanSeats.isEmpty ? 0 : max(boardRoom.h, pod.padding + Double(anteRows) * podRow)
        let topH = max(boardRoom.h, anteH)
        let stripW = boardRoom.w + anteW + Double(execIds.count) * execOffice.w + (ceoId == nil ? 0 : ceoOffice.w)
        let roomsW = breakRoom.w + reviewRoom.w + mailRoom.w + 2 * corridor

        // 4. Wing rows: the narrowest wrap width from max(1 600, top strip) whose floor comes closest to `aspect`.
        func floorSize(_ rows: [Row]) -> (w: Double, h: Double) {
            let h = rows.reduce(topH + corridor) { $0 + $1.h + corridor } + roomsStrip
            return (max(rows.map { $0.end + corridor }.max() ?? 0, stripW, roomsW), h)
        }
        let minWrap = max(minRowWidth, stripW)
        var rows = pack(wingSpecs, maxRowW: minWrap)
        var best = floorSize(rows)
        var wrap = minWrap
        while rows.count > 1 && wrap < minWrap + maxWrapGrowth {
            wrap += corridor
            let candidate = pack(wingSpecs, maxRowW: wrap)
            let size = floorSize(candidate)
            if max(size.w, size.h * aspect) < max(best.w, best.h * aspect) { rows = candidate; best = size }
        }
        var y = topH + corridor
        for i in rows.indices {
            rows[i].y = y
            y += rows[i].h + corridor
        }
        let stripY = y
        let w = best.w

        var layout = OfficeLayout()
        layout.size = (w, stripY + roomsStrip)

        // 5. Corridors: below the top strip, each row's aisles, below each row.
        layout.corridors.append(MapRect(x: 0, y: topH, w: w, h: corridor))
        for row in rows {
            for a in row.aisles { layout.corridors.append(MapRect(x: a.x, y: row.y, w: a.w, h: row.h)) }
            layout.corridors.append(MapRect(x: 0, y: row.y + row.h, w: w, h: corridor))
        }

        // 6. Rooms and their desks.
        func addRoom(_ id: String, _ kind: OfficeRoomKind, _ rect: MapRect, _ title: String, doorOnTop: Bool) {
            let door = MapPoint2(x: rect.mid.x, y: doorOnTop ? rect.y : rect.y + rect.h)
            layout.rooms[id] = OfficeRoom(id: id, kind: kind, rect: rect, title: title, door: door)
        }
        /// A top-strip office's desk faces its door (the chair below it); a director's faces down from below its door.
        func addOfficeDesk(_ agentId: String, room: String, _ rect: MapRect, facesDown: Bool) {
            let deskY = facesDown ? rect.mid.y - 10 : rect.mid.y - 20
            layout.desks[agentId] = desk(agentId, x: rect.mid.x - desk.w / 2, y: deskY, facesDown: facesDown, podId: nil,
                                         roomId: room)
        }
        func role(_ id: String) -> String { model.agents[id]?.role ?? MapText.empty }
        func handle(_ id: String) -> String { model.agents[id]?.handle ?? MapText.empty }

        addRoom("room:board", .board, MapRect(x: 0, y: 0, w: boardRoom.w, h: boardRoom.h), "BOARD ROOM", doorOnTop: false)
        if !orphanSeats.isEmpty {
            let ante = MapRect(x: boardRoom.w, y: 0, w: anteW, h: anteH)
            layout.anteroom = ante
            for (k, seat) in orphanSeats.enumerated() {
                let x = ante.x + pod.padding + Double(k % pod.columns) * (desk.w + pod.aisle)
                let deskY = ante.y + pod.padding + Double(k / pod.columns) * podRow
                layout.desks[seat] = desk(seat, x: x, y: deskY, facesDown: false, podId: nil, roomId: nil)
            }
        }
        var x = boardRoom.w + anteW
        for id in execIds {
            let rect = MapRect(x: x, y: 0, w: execOffice.w, h: execOffice.h)
            addRoom("office:\(id)", .executive(agentId: id), rect, role(id), doorOnTop: false)
            addOfficeDesk(id, room: "office:\(id)", rect, facesDown: false)
            x += execOffice.w
        }
        if let ceoId {
            let rect = MapRect(x: w - ceoOffice.w, y: 0, w: ceoOffice.w, h: ceoOffice.h)
            addRoom("room:ceo", .ceo, rect, "CEO", doorOnTop: false)
            addOfficeDesk(ceoId, room: "room:ceo", rect, facesDown: false)
        }
        addRoom("room:break", .breakRoom, MapRect(x: 0, y: stripY, w: breakRoom.w, h: breakRoom.h), "BREAK ROOM",
                doorOnTop: true)
        addRoom("room:review", .review, MapRect(x: (w - reviewRoom.w) / 2, y: stripY, w: reviewRoom.w, h: reviewRoom.h),
                "REVIEW", doorOnTop: true)
        addRoom("room:mail", .mail, MapRect(x: w - mailRoom.w, y: stripY, w: mailRoom.w, h: mailRoom.h), "MAIL ROOM",
                doorOnTop: true)

        // 7. Wing items: director offices and pods.
        var wingRects: [Int: MapRect] = [:]
        var wingPods: [Int: [String]] = [:]
        for row in rows {
            for placed in row.placed {
                let size = placed.item.size
                let top = row.y + labelBand
                let rect = MapRect(x: placed.x, y: top, w: size.w, h: size.h)
                let band = MapRect(x: placed.x, y: row.y, w: size.w, h: labelBand + size.h)
                wingRects[placed.wing] = wingRects[placed.wing].map { union($0, band) } ?? band
                switch placed.item {
                case .office(let d):
                    addRoom("office:\(d)", .director(agentId: d), rect, handle(d), doorOnTop: true)
                    addOfficeDesk(d, room: "office:\(d)", rect, facesDown: true)
                case .pod(let spec):
                    wingPods[placed.wing, default: []].append(spec.id)
                    layout.pods[spec.id] = OfficePod(
                        id: spec.id, managerId: spec.managerId, rect: rect, title: spec.title, department: spec.department,
                        labelRect: MapRect(x: rect.x, y: row.y, w: rect.w, h: labelBand),
                        board: MapPoint2(x: rect.x + pod.padding + 10, y: rect.y + pod.head / 2))
                    if let head = spec.head {
                        layout.desks[head] = desk(head, x: rect.mid.x - desk.w / 2, y: rect.y + pod.head - deskDepth,
                                                  facesDown: true, podId: spec.id, roomId: nil)
                    }
                    for (k, member) in spec.members.enumerated() {
                        let rowY = rect.y + pod.head + Double(k / pod.columns) * podRow
                        // Facing pairs: even rows face down (chair above), odd rows up (chair below).
                        let down = (k / pod.columns) % 2 == 0
                        let deskX = rect.x + pod.padding + Double(k % pod.columns) * (desk.w + pod.aisle)
                        layout.desks[member] = desk(member, x: deskX, y: down ? rowY + chair.h : rowY, facesDown: down,
                                                    podId: spec.id, roomId: nil)
                    }
                }
            }
        }
        layout.wings = wingSpecs.enumerated().compactMap { i, spec in
            guard let rect = wingRects[i] else { return nil }
            return OfficeWing(id: spec.id, title: spec.title, rect: rect, officeId: spec.officeId, podIds: wingPods[i] ?? [])
        }
        return layout
    }

    /// Lays the wings left to right in rows no wider than `maxRowW`: a wing that does not fit the current row starts a
    /// new one; a wing wider than a row wraps its own items and the next wing starts a fresh row. Each row gets a corridor
    /// on its left, between items (`wingGap` between wings) and on its right; `y` is left for the caller.
    static func pack(_ wings: [WingSpec], maxRowW: Double) -> [Row] {
        var rows: [Row] = []
        var forceNewRow = false
        for (wi, wing) in wings.enumerated() {
            let sizes = wing.items.map(\.size)
            let wingW = sizes.reduce(0) { $0 + $1.w } + corridor * Double(sizes.count - 1)
            if rows.isEmpty || forceNewRow
                || (!rows[rows.count - 1].placed.isEmpty && rows[rows.count - 1].end + wingGap + wingW + corridor > maxRowW) {
                rows.append(Row())
            }
            if !rows[rows.count - 1].placed.isEmpty {
                rows[rows.count - 1].aisles.append((rows[rows.count - 1].end, wingGap))
                rows[rows.count - 1].end += wingGap
            }
            forceNewRow = false
            for (k, item) in wing.items.enumerated() {
                if k > 0 {
                    if rows[rows.count - 1].end + corridor + sizes[k].w + corridor > maxRowW {
                        rows.append(Row())
                        forceNewRow = true
                    } else {
                        rows[rows.count - 1].aisles.append((rows[rows.count - 1].end, corridor))
                        rows[rows.count - 1].end += corridor
                    }
                }
                rows[rows.count - 1].placed.append(Placed(item: item, x: rows[rows.count - 1].end, wing: wi))
                rows[rows.count - 1].end += sizes[k].w
            }
        }
        for i in rows.indices {
            rows[i].aisles.append((rows[i].end, corridor))
            rows[i].h = labelBand + (rows[i].placed.map { $0.item.size.h }.max() ?? 0)
        }
        return rows
    }

    /// A desk whose top-left is (x, y); the seat is the centre of the chair, above the desk when it faces down.
    static func desk(_ id: String, x: Double, y: Double, facesDown: Bool, podId: String?, roomId: String?) -> OfficeDesk {
        let rect = MapRect(x: x, y: y, w: desk.w, h: deskDepth)
        let seatY = facesDown ? y - chair.h / 2 : y + deskDepth + chair.h / 2
        return OfficeDesk(id: id, rect: rect, seat: MapPoint2(x: rect.mid.x, y: seatY), podId: podId, roomId: roomId,
                          facesDown: facesDown)
    }

    static func union(_ a: MapRect, _ b: MapRect) -> MapRect {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return MapRect(x: x, y: y, w: max(a.x + a.w, b.x + b.w) - x, h: max(a.y + a.h, b.y + b.h) - y)
    }

    // MARK: - Places

    /// The owner stands at the board room's door; an agent sits at its desk. Nil for an agent without a desk.
    public func location(_ e: MapEndpoint) -> MapPoint2? {
        switch e {
        case .owner: rooms["room:board"]?.door
        case .agent(let id): desks[id]?.seat
        }
    }

    /// The first `reviewSeats` are chairs around the review table (five along each long side, one at each end); later
    /// indices stand along the bottom wall, then the top wall, repeating.
    public func reviewSeat(_ index: Int) -> MapPoint2 {
        guard let room = rooms["room:review"]?.rect else { return MapPoint2(x: 0, y: 0) }
        let t = OfficeLayout.reviewTable
        let table = MapRect(x: room.mid.x - t.w / 2, y: room.mid.y - t.h / 2, w: t.w, h: t.h)
        let i = max(0, index)
        let pitch = (t.w - 32) / 4
        switch i {
        case 0..<5: return MapPoint2(x: table.x + 16 + Double(i) * pitch, y: table.y - 8)
        case 5..<10: return MapPoint2(x: table.x + 16 + Double(i - 5) * pitch, y: table.y + table.h + 8)
        case 10: return MapPoint2(x: table.x - 10, y: table.mid.y)
        case 11: return MapPoint2(x: table.x + table.w + 10, y: table.mid.y)
        default:
            let k = i - OfficeLayout.reviewSeats
            let perLine = max(1, Int((room.w - 20) / OfficeLayout.spotSpacing))
            let x = room.x + 10 + Double(k % perLine) * OfficeLayout.spotSpacing
            return MapPoint2(x: x, y: (k / perLine) % 2 == 0 ? room.y + room.h - 10 : room.y + 10)
        }
    }

    /// The first `doorSpots` stand in a line centred under the board room's door; later indices queue on to the right
    /// along the wall, wrapping back with a half-step offset when they reach the far wall.
    public func doorSpot(_ index: Int) -> MapPoint2 {
        guard let door = rooms["room:board"]?.door else { return MapPoint2(x: 0, y: 0) }
        let step = OfficeLayout.spotSpacing
        let y = door.y + OfficeLayout.corridor / 2
        let i = max(0, index)
        let half = Double(OfficeLayout.doorSpots - 1) / 2
        if i < OfficeLayout.doorSpots { return MapPoint2(x: door.x + (Double(i) - half) * step, y: y) }
        let k = i - OfficeLayout.doorSpots
        let startX = door.x + (half + 1) * step
        let perLane = max(1, Int((size.w - 16 - startX) / step) + 1)
        return MapPoint2(x: startX + Double(k % perLane) * step + ((k / perLane) % 2 == 0 ? 0 : step / 2), y: y)
    }

    /// The middle of the break room's shelf, along its bottom wall: the wall of fame.
    public func fameShelf() -> MapPoint2 {
        guard let room = rooms["room:break"]?.rect else { return MapPoint2(x: 0, y: 0) }
        return MapPoint2(x: room.mid.x, y: room.y + room.h - 14)
    }

    /// Parcel spots on the mail room's counter: nine to a line, three lines, repeating.
    public func mailCounter(_ index: Int) -> MapPoint2 {
        guard let room = rooms["room:mail"]?.rect else { return MapPoint2(x: 0, y: 0) }
        let i = max(0, index)
        return MapPoint2(x: room.x + 20 + Double(i % 9) * 15, y: room.mid.y + Double((i / 9) % 3 - 1) * 14)
    }

    // MARK: - Furniture

    /// How far inside a room's door wall its lane runs: a route inside a room walks to the lane, along it to the door's x,
    /// and out through the door (`OfficeLayout.route`).
    static let roomLane = 14.0
    /// How far a route inside a room keeps clear of furniture it walks around.
    static let furnitureMargin = 20.0

    /// The furniture a room's routes go around (layout coordinates), as the scene draws it: the board table, the review
    /// table, the mail counter, the break room's counter and sofa. Empty for an office.
    public func furniture(_ roomId: String) -> [MapRect] {
        guard let room = rooms[roomId] else { return [] }
        let r = room.rect, mid = r.mid
        switch room.kind {
        case .board:
            return [MapRect(x: mid.x - 60, y: mid.y + 4 - 18, w: 120, h: 36)]
        case .review:
            let t = OfficeLayout.reviewTable
            return [MapRect(x: mid.x - t.w / 2, y: mid.y - t.h / 2, w: t.w, h: t.h)]
        case .mail:
            return [MapRect(x: r.x + 8, y: mid.y + 3 - 26, w: r.w - 16, h: 52)]
        case .breakRoom:
            return [MapRect(x: r.x + 12, y: r.y + 32 - 9, w: 64, h: 18), Self.sofa(r)]
        case .ceo, .executive, .director:
            return []
        }
    }

    /// The break room's sofa (40 × 16), right of its middle.
    static func sofa(_ r: MapRect) -> MapRect { MapRect(x: r.x + r.w - 36 - 20, y: r.y + r.h / 2 - 6 - 8, w: 40, h: 16) }

    /// Where the `k`th idle stroller rests in the break room: three seats on the sofa, then standing spots across the
    /// room's middle.
    public func sofaSeat(_ k: Int) -> MapPoint2 {
        guard let r = rooms["room:break"]?.rect else { return MapPoint2(x: 0, y: 0) }
        let sofa = Self.sofa(r)
        let i = max(0, k)
        if i < 3 { return MapPoint2(x: sofa.mid.x + Double(i - 1) * 12, y: sofa.mid.y - 2) }
        let j = i - 3
        let perLine = max(1, Int((r.w - 48) / OfficeLayout.spotSpacing))
        return MapPoint2(x: r.x + 24 + Double(j % perLine) * OfficeLayout.spotSpacing, y: r.mid.y + 16)
    }

    // MARK: - Routes

    /// A corridor's centreline: horizontal (y fixed, x in lo…hi) or vertical (x fixed, y in lo…hi).
    struct Line {
        var horizontal: Bool
        var at: Double
        var lo: Double
        var hi: Double

        init(_ c: MapRect) {
            horizontal = c.w >= c.h
            at = horizontal ? c.y + c.h / 2 : c.x + c.w / 2
            lo = horizontal ? c.x : c.y
            hi = horizontal ? c.x + c.w : c.y + c.h
        }

        func point(_ t: Double) -> MapPoint2 { horizontal ? MapPoint2(x: t, y: at) : MapPoint2(x: at, y: t) }
        func param(_ p: MapPoint2) -> Double { horizontal ? p.x : p.y }
        /// The point of the line nearest to `p` (it moves along one axis only).
        func snap(_ p: MapPoint2) -> MapPoint2 { point(min(hi, max(lo, param(p)))) }
    }

    static func inside(_ r: MapRect, _ p: MapPoint2) -> Bool {
        p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h
    }

    /// Where `p` joins the corridors: `p` itself when it is in one, else the nearest point reached by a perpendicular
    /// (straight-line, axis-aligned) step, else the nearest corner. Ties go to the earlier corridor.
    func entry(_ p: MapPoint2) -> (corridor: Int, point: MapPoint2) {
        if let i = corridors.firstIndex(where: { Self.inside($0, p) }) { return (i, p) }
        var best: (corridor: Int, point: MapPoint2, d: Double, square: Bool)?
        for (i, c) in corridors.enumerated() {
            let clamped = MapPoint2(x: min(c.x + c.w, max(c.x, p.x)), y: min(c.y + c.h, max(c.y, p.y)))
            let square = clamped.x == p.x || clamped.y == p.y
            let d = abs(clamped.x - p.x) + abs(clamped.y - p.y)
            if let b = best, (b.square && !square) || (b.square == square && b.d <= d) { continue }
            best = (i, clamped, d, square)
        }
        return (best!.corridor, best!.point)
    }

    /// The corridor network a route walks: each corridor's centreline and the junctions where a vertical corridor meets a
    /// horizontal one, with each junction's place along both lines. It depends on the corridors only, so a caller that
    /// routes many times over one layout builds it once (`routeGraph()`) and passes it to `route(from:to:graph:)`.
    public struct RouteGraph: Sendable {
        let lines: [Line]
        let junctions: [MapPoint2]
        let onLine: [[(t: Double, node: Int)]]
    }

    public func routeGraph() -> RouteGraph {
        let lines = corridors.map(Line.init)
        var junctions: [MapPoint2] = []
        var onLine: [[(t: Double, node: Int)]] = Array(repeating: [], count: lines.count)
        for (h, hl) in lines.enumerated() where hl.horizontal {
            let hc = corridors[h]
            for (v, vl) in lines.enumerated() where !vl.horizontal {
                let vc = corridors[v]
                guard vc.x >= hc.x, vc.x + vc.w <= hc.x + hc.w, vc.y <= hc.y + hc.h, vc.y + vc.h >= hc.y else { continue }
                junctions.append(MapPoint2(x: vl.at, y: hl.at))
                onLine[h].append((vl.at, junctions.count - 1))
                onLine[v].append((hl.at, junctions.count - 1))
            }
        }
        return RouteGraph(lines: lines, junctions: junctions, onLine: onLine)
    }

    /// Manhattan: start → out of its room (through the door) or pod (sideways) → the nearest corridor point → along
    /// corridor centrelines (shortest) → the nearest corridor point to the end → into its pod or room → end. Every segment
    /// lies in the corridors or in the two ends' pods or rooms, and none crosses a wall (outside a door), a desk, a pod's
    /// title band or a room's furniture (but the piece an end stands on).
    public func route(from a: MapPoint2, to b: MapPoint2) -> [MapPoint2] {
        route(from: a, to: b, graph: corridors.isEmpty ? nil : routeGraph())
    }

    /// `route(from:to:)` over a graph built by `routeGraph()` from this layout's corridors.
    ///
    /// An end inside a room leaves only through its door: it walks to the room's lane (going around the room's furniture,
    /// spec R28), along the lane to the door's x and out through the door; two ends in one room meet on its lane. An end
    /// in a pod leaves sideways along its chair row to the pod's nearer side, where an aisle corridor runs, so no route
    /// crosses a desk or a pod's title band.
    public func route(from a: MapPoint2, to b: MapPoint2, graph: RouteGraph?) -> [MapPoint2] {
        guard a != b else { return [a] }
        let ra = room(containing: a), rb = room(containing: b)
        var points: [MapPoint2]
        if let ra, let rb, ra.id == rb.id {
            points = roomLeg(a, ra) + roomLeg(b, rb).reversed()
        } else {
            let xa = exit(a, ra), xb = exit(b, rb)
            points = Array(xa.dropLast()) + corridorRoute(from: xa.last!, to: xb.last!, graph: graph)
                + Array(xb.reversed().dropFirst())
        }
        var result: [MapPoint2] = []
        for p in points where result.last != p { result.append(p) }
        // Merge straight runs (a lane point on the door's column, say).
        var merged: [MapPoint2] = []
        for p in result {
            if merged.count >= 2 {
                let u = merged[merged.count - 2], v = merged[merged.count - 1]
                let sameLine = (u.x == v.x && v.x == p.x) || (u.y == v.y && v.y == p.y)
                let onward = sameLine && ((v.x - u.x) * (p.x - v.x) + (v.y - u.y) * (p.y - v.y)) > 0
                if onward { merged[merged.count - 1] = p; continue }
            }
            merged.append(p)
        }
        return merged
    }

    /// The room `p` is in (its door included), nil outside every room.
    func room(containing p: MapPoint2) -> OfficeRoom? {
        rooms.values.sorted { $0.id < $1.id }.first { Self.inside($0.rect, p) }
    }

    /// From `p` to a point where it can join the corridors: out of its room through the door (to the door point itself,
    /// on the wall), or out of its pod sideways; else `p`.
    func exit(_ p: MapPoint2, _ room: OfficeRoom?) -> [MapPoint2] {
        if let room {
            if p == room.door { return [p] }
            return roomLeg(p, room) + [room.door]
        }
        if let pod = pods.values.sorted(by: { $0.id < $1.id }).first(where: { Self.inside($0.rect, p) }) {
            let side = p.x <= pod.rect.mid.x ? pod.rect.x : pod.rect.x + pod.rect.w
            return [p, MapPoint2(x: side, y: p.y)]
        }
        return [p]
    }

    /// Inside `room`: from `p` to its lane at the door's x. When the straight step to the lane would cross a piece of
    /// furniture (not the one `p` is on), it first steps sideways past that piece's nearer end.
    func roomLeg(_ p: MapPoint2, _ room: OfficeRoom) -> [MapPoint2] {
        let r = room.rect
        let doorOnTop = room.door.y <= r.y
        let lane = doorOnTop ? r.y + Self.roomLane : r.y + r.h - Self.roomLane
        var obstacles = furniture(room.id)
        obstacles += desks.values.filter { $0.roomId == room.id }.map(\.rect)
        obstacles.removeAll { Self.inside($0, p) }
        // Already on the door's column between the lane and the door: straight out.
        if p.x == room.door.x, doorOnTop ? p.y <= lane : p.y >= lane { return [p] }
        var leg = [p]
        var x = p.x
        let lo = min(p.y, lane), hi = max(p.y, lane)
        if let block = obstacles.filter({ $0.x < x && x < $0.x + $0.w && $0.y < hi && lo < $0.y + $0.h })
            .min(by: { abs($0.mid.y - p.y) < abs($1.mid.y - p.y) }) {
            let left = block.x - Self.furnitureMargin, right = block.x + block.w + Self.furnitureMargin
            x = abs(left - x) <= abs(right - x) ? left : right
            x = min(r.x + r.w - 6, max(r.x + 6, x))
            leg.append(MapPoint2(x: x, y: p.y))
        }
        leg.append(MapPoint2(x: x, y: lane))
        leg.append(MapPoint2(x: room.door.x, y: lane))
        return leg
    }

    /// The corridor part of a route: start → the nearest corridor point → along corridor centrelines (shortest) → the
    /// nearest corridor point to the end → end.
    func corridorRoute(from a: MapPoint2, to b: MapPoint2, graph: RouteGraph?) -> [MapPoint2] {
        guard a != b else { return [a] }
        guard !corridors.isEmpty, let graph, graph.lines.count == corridors.count else {
            return a.x == b.x || a.y == b.y ? [a, b] : [a, MapPoint2(x: b.x, y: a.y), b]
        }
        let lines = graph.lines
        let ea = entry(a), eb = entry(b)

        // Nodes: the junctions, then the two snapped ends.
        var nodes = graph.junctions
        var onLine = graph.onLine
        let sa = lines[ea.corridor].snap(ea.point), sb = lines[eb.corridor].snap(eb.point)
        nodes.append(sa)
        let start = nodes.count - 1
        onLine[ea.corridor].append((lines[ea.corridor].param(sa), start))
        nodes.append(sb)
        let goal = nodes.count - 1
        onLine[eb.corridor].append((lines[eb.corridor].param(sb), goal))

        var edges: [[(to: Int, d: Double)]] = Array(repeating: [], count: nodes.count)
        for list in onLine {
            let sorted = list.sorted { ($0.t, $0.node) < ($1.t, $1.node) }
            for (p, q) in zip(sorted, sorted.dropFirst()) {
                edges[p.node].append((q.node, q.t - p.t))
                edges[q.node].append((p.node, q.t - p.t))
            }
        }

        // Dijkstra; ties go to the lower node index.
        var dist = Array(repeating: Double.infinity, count: nodes.count)
        var prev = Array(repeating: -1, count: nodes.count)
        var done = Array(repeating: false, count: nodes.count)
        dist[start] = 0
        while true {
            var u = -1
            for i in nodes.indices where !done[i] && dist[i] < .infinity && (u < 0 || dist[i] < dist[u]) { u = i }
            if u < 0 || u == goal { break }
            done[u] = true
            for e in edges[u] where dist[u] + e.d < dist[e.to] {
                dist[e.to] = dist[u] + e.d
                prev[e.to] = u
            }
        }
        var middle: [MapPoint2] = []
        if dist[goal] < .infinity {
            var cursor = goal
            while cursor >= 0 { middle.append(nodes[cursor]); cursor = prev[cursor] }
            middle.reverse()
        } else {
            middle = [sa, sb]
        }

        var points: [MapPoint2] = [a, ea.point] + middle + [eb.point, b]
        // An end outside every corridor and off both its axes joins at a corner: step along x first.
        if a.x != ea.point.x && a.y != ea.point.y { points.insert(MapPoint2(x: ea.point.x, y: a.y), at: 1) }
        if b.x != eb.point.x && b.y != eb.point.y { points.insert(MapPoint2(x: eb.point.x, y: b.y), at: points.count - 1) }
        var result: [MapPoint2] = []
        for p in points where result.last != p { result.append(p) }
        return result
    }
}
