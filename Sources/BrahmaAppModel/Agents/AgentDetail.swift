import Foundation
import BrahmaCore

public struct AgentDetail: Equatable, Sendable {
    public var agent: Agent
    public var stateLabel: String
    public var blockerText: String
    public var lastTurnLine: String
    public var lastTurnSummary: String?
    public var canPause: Bool
    public var canWake: Bool
    public var canKill: Bool
    /// The handle of the agent's manager, nil for the root or when the manager left.
    public var managerHandle: String? = nil
    public var team: String? = nil
    /// Live agents that report to this one.
    public var reportCount = 0
    /// "ceo" while the agent stands in for a CEO who left.
    public var actingRole: String? = nil
    /// What the running turn uses, e.g. "Deep R2 · high"; nil unless the agent is running a turn that recorded a mode.
    public var modeChip: String? = nil
}

public enum ModeChipText {
    /// "Deep R2 · high", from the turn's recorded mode, rung and effort.
    public static func line(_ turn: Turn?) -> String? {
        guard let turn, turn.outcome == .inProgress, let raw = turn.mode, let mode = WorkMode(rawValue: raw) else { return nil }
        var parts = mode.title
        if let rung = turn.rung { parts += " R\(rung)" }
        if let effort = turn.effort { parts += " · \(effort)" }
        return parts
    }
}

extension AppModel {
    public func hire(_ form: HireForm) async throws -> Agent {
        let existing = Set(snapshot.agents.map { $0.name.lowercased() })
        if let message = form.validate(existingHandles: existing) { throw FormError.invalid(message) }
        guard let companyId = selectedCompanyId else { throw FormError.invalid("Select a company first") }
        let handle = form.normalizedHandle, role = form.trimmedRole, model = form.model.rawValue
        let store = self.store
        let agent: Agent
        do {
            agent = try await Task.detached { try store.hire(companyId: companyId, name: handle, role: role, model: model) }.value
        } catch StoreError.duplicateName {
            throw FormError.invalid("@\(handle) already exists")
        } catch StoreError.invalidName {
            throw FormError.invalid(HireForm.formatMessage)
        }
        await tick(forceSnapshot: true)
        selectedAgentId = agent.id
        return agent
    }

    public func setAgentPaused(_ agentId: String, _ paused: Bool) async {
        let store = self.store
        do {
            _ = try await Task.detached { try store.setPaused(agentId: agentId, paused) }.value
            await tick(forceSnapshot: true)
        } catch {
            errorMessage = "Couldn't \(paused ? "pause" : "wake") the agent: \(error)"
        }
    }

    public func kill(agentId: String) async {
        let store = self.store
        let handle = snapshot.agents.first { $0.id == agentId }?.name ?? agentId
        do {
            _ = try await Task.detached { try store.transition(agentId: agentId, to: .killed) }.value
            await tick(forceSnapshot: true)
        } catch is LifecycleError {
            errorMessage = "@\(handle) is already killed"
            await tick(forceSnapshot: true)
        } catch {
            errorMessage = "Couldn't kill @\(handle): \(error)"
        }
    }

    public func openDM(handle: String) { select(.dm(handle: handle)) }

    public func detail(agentId: String, timeZone: TimeZone? = nil) -> AgentDetail? {
        guard let a = snapshot.agents.first(where: { $0.id == agentId }) else { return nil }
        let timeZone = timeZone ?? ownerTimeZone
        let turn = snapshot.lastTurns[agentId]
        let line: String
        if let turn {
            if turn.outcome == .inProgress {
                line = "in progress since \(TimeText.hm(turn.startedAt, timeZone: timeZone))"
            } else {
                line = "\(turn.outcome.rawValue) at \(TimeText.hm(turn.endedAt ?? turn.startedAt, timeZone: timeZone))"
            }
        } else {
            line = "No turns yet"
        }
        let alive = a.state != .killed
        return AgentDetail(
            agent: a, stateLabel: AgentBadge.label(a),
            blockerText: BlockerText.describe(a.blocker, handles: handles, timeZone: timeZone),
            lastTurnLine: line, lastTurnSummary: turn?.summary,
            canPause: alive && !a.paused,
            canWake: alive && (a.paused || a.state == .sleeping || a.state == .blocked),
            canKill: alive,
            managerHandle: a.managerId.flatMap { id in snapshot.agents.first { $0.id == id }?.name },
            team: a.team, reportCount: snapshot.agents.filter { $0.managerId == a.id && $0.state != .killed }.count,
            actingRole: a.actingRole, modeChip: a.state == .running ? ModeChipText.line(turn) : nil)
    }
}
