import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct ActivityTextTests {
    func event(_ kind: ActivityKind, _ text: String, agent: String? = nil) -> ActivityEvent {
        ActivityEvent(companyId: "c", agentId: agent, turnId: nil, kind: kind, text: text, createdAt: .now)
    }

    @Test func stateChangeLineNamesAgent() {
        let e = event(.stateChanged, "sleeping -> ready", agent: "a1")
        #expect(ActivityText.line(e, handles: ["a1": "ceo"]) == "@ceo sleeping → ready")
    }

    @Test func otherKindsVerbatim() {
        let e = event(.message, "#general @ceo: [x](y)", agent: "a1")
        #expect(ActivityText.line(e, handles: ["a1": "ceo"]) == "#general @ceo: [x](y)")
    }

    @Test(arguments: [(ActivityFilter.messages, ActivityKind.message, true), (.messages, .turnStarted, false), (.turns, .toolUse, true),
                      (.states, .stateChanged, true), (.problems, .usage, true), (.problems, .message, false), (.all, .error, true),
                      (.work, .preview, true), (.work, .release, true), (.work, .resource, true), (.problems, .resource, false), (.problems, .preview, false), (.messages, .release, false)])
    func filterKinds(f: ActivityFilter, k: ActivityKind, ok: Bool) { #expect(f.includes(k) == ok) }

    @Test func agentBadgeLabels() throws {
        let (store, paths) = try makeHome()
        let (_, ceo, cto, eng) = try seedAcme(store, paths)
        var a = cto; a.paused = true
        #expect(AgentBadge.label(a) == "paused")
        var r = ceo; r.state = .running; r.paused = true
        #expect(AgentBadge.label(r) == "running (pausing)")
        #expect(AgentBadge.label(eng) == "blocked")
        var k = eng; k.state = .killed; k.paused = true
        #expect(AgentBadge.label(k) == "killed")
    }

    @Test func filteredActivityAppliesFilter() async throws {
        let (store, paths) = try makeHome()
        let (acme, ceo, _, _) = try seedAcme(store, paths)
        try store.appendEvent(ActivityEvent(companyId: acme.id, agentId: ceo.id, turnId: nil, kind: .message, text: "hi", createdAt: .now))
        try store.appendEvent(ActivityEvent(companyId: acme.id, agentId: ceo.id, turnId: nil, kind: .stateChanged, text: "a -> b", createdAt: .now))
        let model = AppModel(store: store, paths: paths)
        await model.load()
        #expect(model.handles[ceo.id] == "ceo")
        #expect(model.handles["owner"] == "owner")
        model.activityFilter = .states
        #expect(!model.filteredActivity.isEmpty)
        #expect(model.filteredActivity.allSatisfy { $0.kind == .stateChanged })
        model.activityFilter = .all
        #expect(model.filteredActivity.count == model.activity.count)
    }
}
