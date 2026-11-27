import Foundation
import BrahmaCore

extension AppModel {
    /// The selected company's preview tabs, with the OPENED tab when a ref is open (Plan C).
    public var previewTabs: [PreviewTab] { PreviewTabs.make(snapshot.preview, opened: previewNav.opened) }

    /// The body of the selected tab (an unknown or reserved selection is the default one).
    public var previewBody: PreviewBody { previewBody(forTab: selectedPreviewTab) }

    /// The body of any tab id, for surfaces other than the pane (chat's inspector split, Collab). The ARTIFACTS tab shows the
    /// selected (possibly pinned) artifact, with the list and picker always present (`artifactNotice` is shown beside them, never
    /// in their place); a backend body carries the parsed OpenAPI copy (`previewForBodies`).
    public func previewBody(forTab tabId: String?) -> PreviewBody {
        // Plan C C6b: the CHANGES tab's content is `changes` (the view reads the model).
        if tabId == PreviewTabID.changes { return .changes }
        // Plan C: the OPENED tab shows the opened ref's body (or a placeholder while it renders).
        if tabId == PreviewTabID.ref, let opened = previewNav.opened {
            return .ref(openedBody ?? RefBody(header: RefHeader(title: opened.title, subtitle: "", chips: [], actions: []), content: .unavailable("LOADING")))
        }
        let p = previewForBodies
        let tails = p.logTails
        return PreviewBodies.body(for: tabId, snapshot: p, logTail: { tails[$0.path] ?? [] }, selectedArtifactId: selectedArtifactId)
    }

    /// The owner picks a tab (the pane's chips, `preview:<name>` targets). The one way a pick happens: it supersedes any artifact
    /// lookup still running (`openArtifact`), so a late result cannot pull the pane back to ARTIFACTS, and clears the deleted-artifact notice.
    public func selectPreviewTab(_ id: String?) {
        selectedPreviewTab = id
        artifactNotice = nil
        artifactSelectionGeneration += 1
        updateChangesVisibility()
    }

    /// Asks the engine to restart a surface (owner).
    public func restartPreview(surfaceId: String) async {
        await ownerWrite("restart the preview") { store in try store.requestPreviewRestart(surfaceId: surfaceId, by: .owner) }
    }

    // MARK: Turn stream (L-3)

    /// The observed agent's running turn, else its latest finished one. Empty for any other agent.
    public func turnStream(agentId: String) -> (turnId: String?, running: Bool, lines: [TurnStreamLine]) {
        guard let cache = turnStreamCache, cache.agentId == agentId, turnStreamAgentId == agentId else { return (nil, false, []) }
        return (cache.turnId, cache.running, cache.lines)
    }

    /// A view showing an agent's turn stream calls this; the stream then loads off-main on every tick.
    public func observeTurnStream(agentId: String) {
        guard turnStreamAgentId != agentId else { return }
        turnStreamAgentId = agentId
        turnStreamCache = nil
        Task { await refreshTurnStream() }
    }

    public func stopObservingTurnStream() {
        turnStreamAgentId = nil
        turnStreamCache = nil
    }

    public func refreshTurnStream() async {
        guard let agentId = turnStreamAgentId else { return }
        let store = self.store, tz = ownerTimeZone
        do {
            let loaded = try await Task.detached { () -> TurnStreamCache in
                guard let turn = try store.lastTurn(agentId: agentId) else {
                    return TurnStreamCache(agentId: agentId, turnId: nil, running: false, lines: [])
                }
                let events = try store.turnEvents(agentId: agentId, turnId: turn.id, kinds: TurnStream.kinds, limit: TurnStream.maxLines)
                return TurnStreamCache(agentId: agentId, turnId: turn.id, running: turn.outcome == .inProgress && turn.endedAt == nil,
                                       lines: TurnStream.lines(events: events, agentId: agentId, turnId: turn.id, timeZone: tz))
            }.value
            guard turnStreamAgentId == agentId else { return }
            if turnStreamCache != loaded { turnStreamCache = loaded }
        } catch {
            report(error)
        }
    }
}

struct TurnStreamCache: Equatable, Sendable {
    var agentId: String
    var turnId: String?
    var running: Bool
    var lines: [TurnStreamLine]
}
