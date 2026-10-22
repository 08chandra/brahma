import Foundation

/// `brahma hook pre-tool` (design §4.2): the engine's PreToolUse hook on `Agent|Task|Workflow`, compiled into every mode turn's
/// settings (probe V-8 showed it fires under `--setting-sources ""`, and for sub-agents' own tool calls). It denies, with a
/// reason the model sees:
/// - `Agent`/`Task` with `isolation` set, `run_in_background: true`, or a `subagent_type` outside the expected set;
/// - `Agent`/`Task` on a turn whose sub-agents are off (every 3a turn: a belt to the deny list);
/// - `Workflow` with `name`, `scriptPath` or a `resumeFromRunId` not recorded for the item (inline scripts only);
/// - `Workflow` on any non-Ultra turn;
/// - any of them while the session is tainted.
public enum PreToolHook {
    public enum Decision: Equatable, Sendable {
        case allow
        case deny(String)
    }

    public struct Context: Equatable, Sendable {
        public var mode: WorkMode
        public var subagents: Bool
        public var tainted: Bool
        public var recordedRunIds: Set<String>
        public var subagentTypes: Set<String>

        public init(mode: WorkMode, subagents: Bool, tainted: Bool = false, recordedRunIds: Set<String> = [],
                    subagentTypes: Set<String> = PreToolHook.builtinSubagentTypes) {
            self.mode = mode; self.subagents = subagents; self.tainted = tainted
            self.recordedRunIds = recordedRunIds; self.subagentTypes = subagentTypes
        }

        /// A session is tainted once its flag file exists (5-lite writes it).
        public static func tainted(flagFile: String?) -> Bool {
            guard let flagFile, !flagFile.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: flagFile)
        }
    }

    /// The built-in agent types a sub-agent call may name (plus approved Brahma types, later).
    public static let builtinSubagentTypes: Set<String> = ["general-purpose", "Explore", "Plan"]

    public static func decide(_ input: [String: JSONValue], context: Context) -> Decision {
        let tool = input["tool_name"]?.stringValue ?? ""
        let args = input["tool_input"]?.objectValue ?? [:]
        guard ["Agent", "Task", "Workflow"].contains(tool) else { return .allow }
        if context.tainted { return .deny("Brahma: this session is tainted; sub-agents and workflows are off for it") }
        if tool == "Workflow" {
            guard context.mode == .ultra else {
                return .deny("Brahma: workflows run only on an approved Ultra turn; this is a \(context.mode.title) turn")
            }
            if args["name"].map({ $0 != .null }) == true || args["scriptPath"].map({ $0 != .null }) == true {
                return .deny("Brahma: only an inline workflow script is allowed (no named or file workflows)")
            }
            if let run = args["resumeFromRunId"]?.stringValue, !context.recordedRunIds.contains(run) {
                return .deny("Brahma: workflow run \(run) was not started for this item")
            }
            return .allow
        }
        guard context.subagents else { return .deny("Brahma: sub-agents are off in this mode") }
        if let isolation = args["isolation"], isolation != .null {
            return .deny("Brahma: sub-agents with isolation (\(isolation.stringValue ?? "set")) are not allowed")
        }
        if args["run_in_background"]?.boolValue == true { return .deny("Brahma: background sub-agents are not allowed") }
        let type = args["subagent_type"]?.stringValue ?? "general-purpose"
        if !context.subagentTypes.contains(type) { return .deny("Brahma: sub-agent type '\(type)' is not allowed") }
        return .allow
    }

    /// The hook protocol's deny object, or nil to allow (print nothing, exit 0).
    public static func output(_ d: Decision) -> String? {
        guard case .deny(let why) = d else { return nil }
        let value: JSONValue = .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PreToolUse"), "permissionDecision": .string("deny"),
            "permissionDecisionReason": .string(why)])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Reads the hook input; input it cannot read fails closed.
    public static func run(stdin: Data, context: Context) -> String? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: stdin), let input = value.objectValue else {
            return output(.deny("Brahma: the hook input could not be read"))
        }
        return output(decide(input, context: context))
    }
}
