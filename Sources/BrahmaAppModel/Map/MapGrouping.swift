import Foundation
import BrahmaCore

/// A band of the chart: the C-suite, a team, or the teamless agents of one department.
public struct MapGroup: Identifiable, Equatable, Sendable {
    /// "csuite" | "team:<t>" | "dept:<department>".
    public var id: String
    public var title: String
    public var department: Department
    /// In `createdAt`, then handle, order.
    public var memberIds: [String]
    /// Members that are not killed.
    public var activeCount: Int
    public var leadId: String?

    public init(id: String, title: String, department: Department, memberIds: [String], activeCount: Int, leadId: String?) {
        self.id = id; self.title = title; self.department = department; self.memberIds = memberIds
        self.activeCount = activeCount; self.leadId = leadId
    }
}

public enum MapGrouping {
    /// Executives form the C-suite; other agents with a team form `team:<t>`; the rest group by `Department.of`. Killed
    /// agents stay members (they are drawn as former) but do not count as active. Order: C-suite, teams by numeric-aware
    /// name, departments in enum order.
    public static func make(agents: [Agent], roleKinds: [String: RoleKind]) -> [MapGroup] {
        let ordered = agents.sorted { ($0.createdAt, $0.name, $0.id) < ($1.createdAt, $1.name, $1.id) }
        var reports: [String: Int] = [:]
        for a in agents { if let m = a.managerId { reports[m, default: 0] += 1 } }
        func kind(_ a: Agent) -> RoleKind? { roleKinds[a.role] }

        var csuite: [Agent] = []
        var teams: [String: [Agent]] = [:]
        var departments: [Department: [Agent]] = [:]
        for a in ordered {
            if kind(a) == .executive {
                csuite.append(a)
            } else if let t = a.team, !t.isEmpty {
                teams[t, default: []].append(a)
            } else {
                departments[Department.of(role: a.role, kind: kind(a)), default: []].append(a)
            }
        }

        func group(_ id: String, _ title: String, _ department: Department, _ members: [Agent]) -> MapGroup {
            let managers = members.filter { kind($0) == .manager }
            // The manager with the most reports; ties go to the earlier member.
            var lead: Agent?
            for m in managers where lead == nil || reports[m.id, default: 0] > reports[lead!.id, default: 0] { lead = m }
            return MapGroup(id: id, title: title, department: department, memberIds: members.map(\.id),
                            activeCount: members.filter { $0.state != .killed }.count, leadId: lead?.id)
        }

        var result: [MapGroup] = []
        if !csuite.isEmpty { result.append(group("csuite", Department.csuite.title, .csuite, csuite)) }
        let teamNames = teams.keys.sorted { l, r in
            switch l.compare(r, options: .numeric) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: l < r
            }
        }
        for t in teamNames {
            let members = teams[t]!
            result.append(group("team:\(t)", teamTitle(t), teamDepartment(members, roleKinds),
                                members))
        }
        for d in Department.allCases {
            if let members = departments[d] { result.append(group("dept:\(d.rawValue)", d.title, d, members)) }
        }
        return result
    }

    /// Uppercased before cleaning, so a case mapping that grows the text ("ß" → "SS") cannot exceed the 32-cluster cap.
    static func teamTitle(_ team: String) -> String {
        MapText.clean(String(String.UnicodeScalarView(team.unicodeScalars.prefix(MapText.inputLimit))).uppercased(), max: 32)
    }

    /// The most common department among the team's non-manager members; ties go to enum order; managers only → engineering.
    static func teamDepartment(_ members: [Agent], _ roleKinds: [String: RoleKind]) -> Department {
        var counts: [Department: Int] = [:]
        for a in members where roleKinds[a.role] != .manager {
            counts[Department.of(role: a.role, kind: roleKinds[a.role]), default: 0] += 1
        }
        var best: Department?
        for d in Department.allCases {
            guard let c = counts[d] else { continue }
            if best == nil || c > counts[best!]! { best = d }
        }
        return best ?? .engineering
    }
}
