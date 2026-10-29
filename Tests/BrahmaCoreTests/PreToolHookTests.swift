import Foundation
import Testing
@testable import BrahmaCore

/// `brahma hook pre-tool` (design §4.2): the engine's PreToolUse hook on `Agent|Task|Workflow`.
@Suite(.scratch) struct PreToolHookTests {
    private func input(_ tool: String, _ fields: [String: JSONValue]) -> [String: JSONValue] {
        ["hook_event_name": .string("PreToolUse"), "tool_name": .string(tool), "tool_input": .object(fields),
         "session_id": .string("s")]
    }

    /// A turn whose sub-agents are on (5-lite), so the specific rules are what refuses.
    private let open = PreToolHook.Context(mode: .standard, subagents: true)

    private func denied(_ d: PreToolHook.Decision) -> String? {
        if case .deny(let why) = d { return why }
        return nil
    }

    @Test func deniesRemoteIsolation() {
        let d = PreToolHook.decide(input("Agent", ["subagent_type": .string("general-purpose"), "isolation": .string("remote"),
                                                   "prompt": .string("x")]), context: open)
        #expect(denied(d)?.contains("isolation") == true)
        #expect(PreToolHook.decide(input("Task", ["isolation": .string("worktree")]), context: open) != .allow)
        #expect(PreToolHook.decide(input("Agent", ["subagent_type": .string("Explore"), "prompt": .string("x")]), context: open) == .allow)
        // The output is the hook protocol's deny object.
        let out = PreToolHook.output(d)
        #expect(out?.contains("\"permissionDecision\":\"deny\"") == true)
        #expect(out?.contains("\"hookEventName\":\"PreToolUse\"") == true)
        #expect(PreToolHook.output(.allow) == nil)
    }

    @Test func deniesBackgroundAgent() {
        let d = PreToolHook.decide(input("Agent", ["run_in_background": .bool(true), "prompt": .string("x")]), context: open)
        #expect(denied(d)?.contains("background") == true)
    }

    @Test func deniesUnknownSubagentType() {
        let d = PreToolHook.decide(input("Agent", ["subagent_type": .string("x-planted"), "prompt": .string("x")]), context: open)
        #expect(denied(d)?.contains("x-planted") == true)
        for builtin in ["general-purpose", "Explore", "Plan"] {
            #expect(PreToolHook.decide(input("Agent", ["subagent_type": .string(builtin)]), context: open) == .allow)
        }
        // With sub-agents off for the turn (every 3a turn) any Agent or Task call is refused: a belt to the deny list.
        let off = PreToolHook.Context(mode: .standard, subagents: false)
        #expect(PreToolHook.decide(input("Agent", ["subagent_type": .string("Explore")]), context: off) != .allow)
        #expect(PreToolHook.decide(input("Task", [:]), context: off) != .allow)
    }

    @Test func deniesNamedWorkflowAndScriptPath() {
        let ultra = PreToolHook.Context(mode: .ultra, subagents: true)
        #expect(denied(PreToolHook.decide(input("Workflow", ["name": .string("deep-research")]), context: ultra))?.contains("inline") == true)
        #expect(PreToolHook.decide(input("Workflow", ["scriptPath": .string("/tmp/w.js")]), context: ultra) != .allow)
        #expect(PreToolHook.decide(input("Workflow", ["script": .string("agent()")]), context: ultra) == .allow)
    }

    @Test func deniesForeignResumeRun() {
        let ultra = PreToolHook.Context(mode: .ultra, subagents: true, recordedRunIds: ["run-1"])
        #expect(PreToolHook.decide(input("Workflow", ["script": .string("x"), "resumeFromRunId": .string("run-9")]), context: ultra) != .allow)
        #expect(PreToolHook.decide(input("Workflow", ["script": .string("x"), "resumeFromRunId": .string("run-1")]), context: ultra) == .allow)
    }

    @Test func deniesFanOutWhenTainted() {
        let tainted = PreToolHook.Context(mode: .ultra, subagents: true, tainted: true)
        for tool in ["Agent", "Task", "Workflow"] {
            #expect(denied(PreToolHook.decide(input(tool, ["script": .string("x")]), context: tainted))?.contains("tainted") == true)
        }
        // A taint flag file marks the session (5-lite writes it; the hook reads it).
        let dir = (try? tempDir()) ?? URL(fileURLWithPath: "/tmp")
        let flag = dir.appending(path: "taint")
        #expect(!PreToolHook.Context.tainted(flagFile: flag.path))
        FileManager.default.createFile(atPath: flag.path, contents: Data())
        #expect(PreToolHook.Context.tainted(flagFile: flag.path))
    }

    @Test func deniesWorkflowOffUltra() {
        for mode in [WorkMode.quick, .standard, .deep, .plan] {
            let d = PreToolHook.decide(input("Workflow", ["script": .string("x")]), context: .init(mode: mode, subagents: true))
            #expect(denied(d)?.contains("Ultra") == true, "\(mode)")
        }
        // Unparseable input fails closed; other tools pass untouched.
        #expect(PreToolHook.run(stdin: Data("not json".utf8), context: open) != nil)
        #expect(PreToolHook.run(stdin: Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8), context: open) == nil)
    }
}
