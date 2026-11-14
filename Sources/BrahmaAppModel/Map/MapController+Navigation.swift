import Foundation
import BrahmaCore

/// Camera, search and the former-agents toggle (Plan 4b Task 7b). Following or highlighting an agent expands every
/// ancestor of it (`collapsed` passes it as the focus).
extension MapController {
    /// Keeps `agentId` in view; nil, or an agent not on the map, goes back to the whole chart.
    public func follow(_ agentId: String?) {
        cameraRequest += 1
        guard let agentId, model.agents[agentId] != nil else {
            self.follow = nil
            camera = .fit
            return
        }
        self.follow = agentId
        camera = .agent(agentId)
    }

    /// The whole chart in view; stops following.
    public func zoomToFit() {
        cameraRequest += 1
        self.follow = nil
        camera = .fit
    }

    /// Agent ids whose handle, role or team contains `q` (case-insensitive, one leading `@` ignored), by handle. Former
    /// agents match only while they are shown. Matches the cleaned strings the map draws.
    public func search(_ q: String) {
        var needle = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.hasPrefix("@") { needle.removeFirst() }
        guard !needle.isEmpty else {
            searchHits = []
            return
        }
        let showFormer = model.showFormer
        searchHits = model.agents.values
            .filter { a in
                guard a.state != .killed || showFormer else { return false }
                let handle = a.handle.hasPrefix("@") ? String(a.handle.dropFirst()) : a.handle
                return handle.lowercased().contains(needle) || a.role.lowercased().contains(needle)
                    || (a.team?.lowercased().contains(needle) ?? false)
            }
            .sorted { ($0.handle, $0.id) < ($1.handle, $1.id) }
            .map(\.id)
    }

    /// Highlights `agentId` for `highlightDuration` of frames (restarting the timer) and moves the camera to it. An agent
    /// not on the map is ignored.
    public func jump(to agentId: String) {
        guard model.agents[agentId] != nil else { return }
        cameraRequest += 1
        highlightId = agentId
        highlightStartedAt = nil
        camera = .agent(agentId)
    }

    public func setShowFormer(_ on: Bool) {
        model.setShowFormer(on)
    }
}
