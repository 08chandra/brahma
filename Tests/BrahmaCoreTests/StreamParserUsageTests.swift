import Foundation
import Testing
@testable import BrahmaCore

private func fixtureLines(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}

private struct ParseFailure: Error {}

private func lastResult(_ fixture: String) throws -> TurnResult {
    let line = try #require(try fixtureLines(fixture).last)
    guard case .result(let r)? = StreamParser.parse(line: line) else { throw ParseFailure() }
    return r
}

private func fold(_ fixture: String) throws -> TurnStreamState {
    var state = TurnStreamState()
    for line in try fixtureLines(fixture) {
        let events = try #require(StreamParser.parseAll(line: line))
        for e in events { state.apply(e) }
    }
    return state
}

/// Usage, tool blocks and fan-out events (Task 14a). `stream-tools`, `stream-max-turns`, `stream-max-budget` and
/// `stream-resume` are real recordings of the installed CLI (2.1.308, haiku); `stream-workflow` is a real recording of a
/// two-agent workflow (p9, 2.1.306) and `stream-workflow-cut17` is its first 17 lines.
@Suite(.scratch) struct StreamParserUsageTests {
    @Test func resultCarriesUsage() throws {
        let r = try lastResult("stream-tools")
        // Usage is summed over the process's API calls; cache reads are not counted.
        let usage = try #require(r.usage)
        #expect(usage == TurnUsage(inputTokens: 4, outputTokens: 86, cacheReadTokens: 37851, cacheCreationTokens: 4260))
        #expect(usage.counted == 4 + 86 + 4260)
        #expect(r.costUSD == 0.00127391)
        #expect(r.terminalReason == "completed"); #expect(r.fastModeState == "off"); #expect(r.speed == "standard")
        #expect(r.modelsUsed == ["claude-haiku-5-5"]); #expect(r.subagentsSpawned == 0)
        #expect(r.stopReason == nil)
    }

    @Test func toolResultDigest() throws {
        let lines = try fixtureLines("stream-tools")
        let events = try #require(StreamParser.parseAll(line: lines[3]))
        #expect(events.count == 1)
        guard case .toolResult(let digest) = events[0] else { Issue.record("expected .toolResult, got \(events)"); return }
        #expect(digest.count == 16)
        let same = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"other","type":"tool_result","content":"hello-probe","is_error":false}]}}"#
        let error = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"x","type":"tool_result","content":"hello-probe","is_error":true}]}}"#
        let other = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"x","type":"tool_result","content":"different","is_error":false}]}}"#
        #expect(StreamParser.parse(line: same) == .toolResult(digest: digest), "the tool_use_id is not part of the digest")
        #expect(StreamParser.parse(line: error) != .toolResult(digest: digest))
        #expect(StreamParser.parse(line: other) != .toolResult(digest: digest))
    }

    @Test func inputDigestIgnoresKeyOrder() {
        let a = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls","description":"d","nested":{"a":1,"b":2}}}]}}"#
        let b = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"nested":{"b":2,"a":1},"description":"d","command":"ls"}}]}}"#
        let c = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"pwd","description":"d","nested":{"a":1,"b":2}}}]}}"#
        #expect(StreamParser.parse(line: a) == StreamParser.parse(line: b))
        #expect(StreamParser.parse(line: a) != StreamParser.parse(line: c))
    }

    @Test func multipleToolUseBlocksAllYielded() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","name":"Read","input":{"p":1}},{"type":"tool_use","name":"Grep","input":{"p":2}}]}}"#
        let all = try #require(StreamParser.parseAll(line: line))
        #expect(all.count == 2)
        guard case .toolUse(let n1, _) = all[0], case .toolUse(let n2, _) = all[1] else { Issue.record("expected two tool uses"); return }
        #expect([n1, n2] == ["Read", "Grep"])
        #expect(StreamParser.parse(line: line) == all.first, "parse is the first event")
        let user = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"1"},{"type":"tool_result","tool_use_id":"b","content":[{"type":"text","text":"2"}]}]}}"#
        let results = try #require(StreamParser.parseAll(line: user))
        #expect(results.count == 2)
    }

    @Test func initLineYieldsToolsAndAgents() throws {
        let first = try #require(try fixtureLines("stream-tools").first)
        let events = try #require(StreamParser.parseAll(line: first))
        #expect(events.count == 2)
        guard case .initInfo(let info) = events[1] else { Issue.record("expected .initInfo"); return }
        #expect(info.model == "claude-haiku-5-5")
        #expect(info.tools.contains("Bash")); #expect(info.agents.contains("Explore"))
    }

    @Test func maxTurnsIsControlledStop() throws {
        let r = try lastResult("stream-max-turns")
        #expect(r.isError); #expect(r.subtype == "error_max_turns"); #expect(r.terminalReason == "max_turns")
        #expect(r.stopReason == "turnCap"); #expect(r.text == "Reached maximum number of turns (1)")
        #expect(r.usage != nil)
        // The classifier never sees it as infrastructure, whatever the text says.
        #expect(EngineHealth.classify(InfraInput(text: "fetch failed", status: nil, subtype: r.subtype)) == .none)
    }

    @Test func maxBudgetIsControlledStop() throws {
        let r = try lastResult("stream-max-budget")
        #expect(r.subtype == "error_max_budget_usd"); #expect(r.terminalReason == "budget_exhausted")
        #expect(r.stopReason == "budgetCap"); #expect((r.costUSD ?? 0) > 0)
    }

    @Test func workflowProgressParsed() throws {
        var state = TurnStreamState()
        var peakPending = 0
        for line in try fixtureLines("stream-workflow") {
            let events = try #require(StreamParser.parseAll(line: line))
            for e in events { state.apply(e); peakPending = max(peakPending, state.pendingTasks.count) }
        }
        #expect(peakPending == 1)
        #expect(state.pendingTasks.isEmpty, "the notification and the empty background list end the workflow")
        #expect(state.workflowAgentIds.count == 2, "two workflow agents, counted once each")
        #expect(state.resultCount == 2)
        #expect(state.subagentIds.isEmpty, "a workflow is not a sub-agent")
    }

    @Test func lastResultWins() throws {
        let state = try fold("stream-workflow")
        let r = try #require(state.result)
        #expect(r.text?.hasPrefix("The workflow is still running") == false, "the first result said still running")
        #expect(r.costUSD == 0.0076812550000000005, "the total is cumulative: the last one stands")
        // The usage of both results adds up.
        let u = try #require(r.usage)
        #expect(u.inputTokens == 6); #expect(u.cacheCreationTokens == 19368); #expect(u.outputTokens == 1174)
    }

    @Test func secondInitAccepted() throws {
        let state = try fold("stream-workflow")
        #expect(state.inits.count == 2)
        #expect(Set(state.inits.map(\.sessionId)).count == 1)
    }

    @Test func cutWorkflowStreamHasPendingWork() throws {
        let state = try fold("stream-workflow-cut17")
        #expect(state.hasPendingWork); #expect(!state.sawResult)
    }

    @Test func resumeTotalIsCumulative() throws {
        // Probe L-4 (Claude Code 2.1.308): the second process resumed the first's session; its `total_cost_usd` includes
        // the first's cost while its own `usage` covers the second process only.
        let first = try lastResult("stream-tools"), second = try lastResult("stream-resume")
        #expect(first.sessionId == second.sessionId)
        let (firstCost, secondCost) = (try #require(first.costUSD), try #require(second.costUSD))
        #expect(secondCost > firstCost)
        let usage = try #require(second.usage)
        #expect(usage.cacheCreationTokens == 61, "per process")
    }

    @Test func effortCapWarningParsedFromStderr() {
        #expect(TurnAudit.effortCap(in: "warn\nEffort 'max' exceeds the cap (high)\n") == "max")
        #expect(TurnAudit.effortCap(in: "nothing") == nil)
    }
}
