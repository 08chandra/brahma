import Foundation

/// The events a runtime's parser produces for the engine (spec §8.1.1's normalized stream). Ruling 25: `StreamEvent`
/// (`Runtime/Claude/StreamParser.swift` since Task 3's move) keeps its name, every case and associated value unchanged; this is its seam name.
///
/// The spec's normalized names, as cases of `StreamEvent`:
/// - `.session`    = `.initialized(sessionId:model:)` (with `.initInfo` right after it: the init line's tools, agents, skills)
/// - `.text`       = `.assistantText`
/// - `.toolUse`    = `.toolUse(name:inputDigest:)` (with `.toolCall(name:input:)` right after it, carrying the input)
/// - `.toolResult` = `.toolResult(digest:)`
/// - `.rateLimit`  = `.rateLimit(RateLimitInfo)`
/// - `.usage`      = `TurnResult.usage` inside `.result(TurnResult)`
/// - `.result`     = `.result(TurnResult)`
/// - `.raw`        = `.raw(String)` (only when `TurnRequest.emitRawLines` asks for it)
/// - `.other(type:)` is any line the parser recognizes as an event of no interest.
///
/// Claude-only cases, which no other runtime ever emits: `taskStarted`, `taskProgress` (with its `WorkflowAgentInfo` agents),
/// `taskNotification`, `backgroundTasks` (the fan-out and Workflow stream), `effortCapped` (a stderr note of the effort cap),
/// `sandboxNote` (a grant path dropped at spawn) and `spawned(pid:)` (the runner's own note of the process it started).
public typealias TurnEvent = StreamEvent

/// A runtime's line parser: one line of the launched process's stdout in, the events on it out. Stateful (a `mutating` parse),
/// so a parser may pair lines or carry a session across them.
public protocol RuntimeStreamParser {
    mutating func parse(line: String, now: Date) -> [TurnEvent]
}
