import Foundation

public enum OrgError: Error, Equatable {
    case countOutOfRange
    case invalidPlan([OrgIssue])
    case cycle
    case tooManyReports(manager: String, count: Int)
    case unknownPack
    case managerKilled
}

public struct OrgIssue: Equatable, Sendable {
    public var handle: String?
    public var message: String
    public init(handle: String?, message: String) { self.handle = handle; self.message = message }
}

public struct PlannedAgent: Equatable, Sendable {
    public var handle: String
    public var role: String
    public var managerHandle: String?
    public var team: String?
    /// Role title, for display; defaults to the role id.
    public var title: String

    public init(handle: String, role: String, managerHandle: String?, team: String?, title: String? = nil) {
        self.handle = handle; self.role = role; self.managerHandle = managerHandle; self.team = team
        self.title = title ?? role
    }
}

/// A proposed org: agents in creation order, each pointing at its manager by handle.
public struct OrgPlan: Equatable, Sendable {
    public var goal: String
    public var agents: [PlannedAgent]

    public init(goal: String, agents: [PlannedAgent]) { self.goal = goal; self.agents = agents }

    public func reports(of handle: String) -> [PlannedAgent] { agents.filter { $0.managerHandle == handle } }

    public func roleCounts() -> [String: Int] {
        agents.reduce(into: [:]) { $0[$1.role, default: 0] += 1 }
    }

    public mutating func add(role: String, handle: String, manager: String?, team: String?, title: String? = nil) {
        agents.append(PlannedAgent(handle: handle, role: role, managerHandle: manager, team: team, title: title))
    }

    /// Removes an agent; its reports move up to its manager.
    public mutating func remove(handle: String) {
        guard let i = agents.firstIndex(where: { $0.handle == handle }) else { return }
        let manager = agents[i].managerHandle
        agents.remove(at: i)
        for j in agents.indices where agents[j].managerHandle == handle { agents[j].managerHandle = manager }
    }

    public mutating func rename(_ handle: String, to new: String) {
        for j in agents.indices {
            if agents[j].handle == handle { agents[j].handle = new }
            if agents[j].managerHandle == handle { agents[j].managerHandle = new }
        }
    }

    public mutating func setManager(handle: String, manager: String?) throws {
        guard agents.contains(where: { $0.handle == handle }) else {
            throw OrgError.invalidPlan([OrgIssue(handle: handle, message: "unknown agent")])
        }
        if let manager {
            guard agents.contains(where: { $0.handle == manager }) else {
                throw OrgError.invalidPlan([OrgIssue(handle: manager, message: "unknown manager")])
            }
            var cursor: String? = manager
            var steps = 0
            while let c = cursor, steps <= agents.count {
                if c == handle { throw OrgError.cycle }
                cursor = agents.first { $0.handle == c }?.managerHandle
                steps += 1
            }
            let existing = reports(of: manager).filter { $0.handle != handle }.count + 1
            if existing > OrgGenerator.maxReports { throw OrgError.tooManyReports(manager: manager, count: existing) }
        }
        if let i = agents.firstIndex(where: { $0.handle == handle }) { agents[i].managerHandle = manager }
    }

    /// Everything wrong with the plan; empty means it can be applied.
    /// `external` are handles that already exist outside the plan and may be named as managers.
    public func validate(pack: IndustryPack, external: Set<String> = []) -> [OrgIssue] {
        var issues: [OrgIssue] = []
        var seen = Set<String>()
        let handles = Set(agents.map(\.handle))
        for a in agents {
            let valid = a.handle.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
            if !valid || a.handle == "owner" || a.handle == "system" { issues.append(OrgIssue(handle: a.handle, message: "invalid handle")) }
            // 10b, S29: `try-` names the owner's extension trials.
            if ExtensionTry.isReservedHandle(a.handle) {
                issues.append(OrgIssue(handle: a.handle, message: "reserved handle (try- is for extension trials)"))
            }
            if !seen.insert(a.handle).inserted { issues.append(OrgIssue(handle: a.handle, message: "duplicate handle")) }
            if pack.role(a.role) == nil { issues.append(OrgIssue(handle: a.handle, message: "unknown role \(a.role)")) }
            if let m = a.managerHandle {
                if m == a.handle { issues.append(OrgIssue(handle: a.handle, message: "reports to itself")) }
                else if !handles.contains(m), !external.contains(m) { issues.append(OrgIssue(handle: a.handle, message: "unknown manager \(m)")) }
            }
        }
        let byHandle = Dictionary(agents.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
        for a in agents {
            var cursor = a.managerHandle
            var steps = 0
            while let c = cursor, steps <= agents.count {
                if c == a.handle { issues.append(OrgIssue(handle: a.handle, message: "reporting cycle")); break }
                cursor = byHandle[c]?.managerHandle
                steps += 1
            }
        }
        var counts: [String: Int] = [:]
        for a in agents { if let m = a.managerHandle { counts[m, default: 0] += 1 } }
        for (m, n) in counts.sorted(by: { $0.key < $1.key }) where n > OrgGenerator.maxReports {
            issues.append(OrgIssue(handle: m, message: "\(n) direct reports (max \(OrgGenerator.maxReports))"))
        }
        if !agents.isEmpty, !agents.contains(where: { $0.managerHandle == nil || external.contains($0.managerHandle!) }) {
            issues.append(OrgIssue(handle: nil, message: "no root agent"))
        }
        return issues
    }

    /// Indented tree, children in creation order. `vacant` handles are marked.
    public func treeLines(vacant: Set<String> = []) -> [String] {
        let handles = Set(agents.map(\.handle))
        var children: [String: [PlannedAgent]] = [:]
        var roots: [PlannedAgent] = []
        for a in agents {
            if let m = a.managerHandle, handles.contains(m), m != a.handle { children[m, default: []].append(a) } else { roots.append(a) }
        }
        var lines: [String] = []
        var visited = Set<String>()
        func walk(_ a: PlannedAgent, _ depth: Int) {
            guard visited.insert(a.handle).inserted else { return }
            lines.append(String(repeating: "  ", count: depth) + "\(a.handle) (\(a.title))" + (vacant.contains(a.handle) ? " (vacant)" : ""))
            for c in children[a.handle] ?? [] { walk(c, depth + 1) }
        }
        for r in roots { walk(r, 0) }
        return lines
    }
}
