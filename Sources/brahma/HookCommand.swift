import ArgumentParser
import Foundation
import BrahmaCore

/// Hooks the engine compiles into an agent turn's settings. Not for interactive use.
struct HookGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook", abstract: "Engine hooks run by Claude Code inside agent turns.", shouldDisplay: false,
        subcommands: [PreTool.self, PostTool.self])

    /// PreToolUse on `Agent|Task|Workflow`: reads the hook input on stdin and prints a deny object, or nothing to allow.
    struct PreTool: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "pre-tool", abstract: "Brahma's PreToolUse hook (design §4.2).")

        @Option(help: "The turn's work mode.") var mode: String = "standard"
        @Flag(help: "The turn's sub-agents are on (never in Plan 3a).") var subagents = false
        @Option(name: .customLong("taint-file"), help: "A flag file that marks the session tainted (Plan 5-lite).") var taintFile: String?
        @Option(help: "The database whose agent row says whether the session is tainted (Task 10).") var db: String?
        @Option(help: "The turn's agent id (with --db).") var agent: String?

        func run() throws {
            // Ruling C6-3: a turn's hook is an agent process before anything opens a Store.
            OwnerPrincipal.enterAgentProcess()
            signal(SIGPIPE, SIG_IGN)
            let input = FileHandle.standardInput.readDataToEndOfFile()
            // A foreign agent is never this turn's: its session counts as tainted (fail closed).
            let foreign = agent != nil && ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"].map { $0 != agent } == true
            // An unknown mode is never Ultra: workflows stay denied.
            let context = PreToolHook.Context(mode: WorkMode(rawValue: mode) ?? .standard, subagents: subagents,
                                              tainted: foreign || PreToolHook.Context.tainted(flagFile: taintFile, database: db, agentId: agent))
            if let out = PreToolHook.run(stdin: input, context: context) { print(out) }
        }
    }

    /// PostToolUse (Task 10): records the taint a tool call carries. Any error fails closed (the flag file, the database mark)
    /// and exits 0; when neither could be written it says so on stderr and exits 1 (S4 fix round 1).
    struct PostTool: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "post-tool", abstract: "Brahma's PostToolUse taint hook (Task 10).")

        @Option(help: "Path to the SQLite database.") var db: String
        @Option(help: "The turn's agent id.") var agent: String

        func run() throws {
            // Ruling C6-3: a turn's hook is an agent process before anything opens a Store.
            OwnerPrincipal.enterAgentProcess()
            signal(SIGPIPE, SIG_IGN)
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let outcome = PostToolHook.handle(stdin: input, database: db, agentId: agent, environment: ProcessInfo.processInfo.environment)
            switch outcome {
            case .clean, .tainted: break
            case .refused(let why): FileHandle.standardError.write(Data("brahma hook post-tool: \(why)\n".utf8))
            case .failedClosed(let why): FileHandle.standardError.write(Data("brahma hook post-tool: \(why); the session is marked tainted\n".utf8))
            case .unrecorded(let why):
                FileHandle.standardError.write(Data("brahma hook post-tool: \(why); the taint was NOT recorded\n".utf8))
                throw ExitCode(1)
            }
        }
    }
}
