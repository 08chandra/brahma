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

    public func detail(agentId: String, timeZone: TimeZone = .current) -> AgentDetail? {
        guard let a = snapshot.agents.first(where: { $0.id == agentId }) else { return nil }
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
            canKill: alive)
    }
}
