import ArgumentParser
import Foundation
import BrahmaCore

/// Hooks the engine compiles into an agent turn's settings. Not for interactive use.
struct HookGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook", abstract: "Engine hooks run by Claude Code inside agent turns.", shouldDisplay: false,
        subcommands: [PreTool.self])

    /// PreToolUse on `Agent|Task|Workflow`: reads the hook input on stdin and prints a deny object, or nothing to allow.
    struct PreTool: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "pre-tool", abstract: "Brahma's PreToolUse hook (design §4.2).")

        @Option(help: "The turn's work mode.") var mode: String = "standard"
        @Flag(help: "The turn's sub-agents are on (never in Plan 3a).") var subagents = false
        @Option(name: .customLong("taint-file"), help: "A flag file that marks the session tainted (Plan 5-lite).") var taintFile: String?

        func run() throws {
            signal(SIGPIPE, SIG_IGN)
            let input = FileHandle.standardInput.readDataToEndOfFile()
            // An unknown mode is never Ultra: workflows stay denied.
            let context = PreToolHook.Context(mode: WorkMode(rawValue: mode) ?? .standard, subagents: subagents,
                                              tainted: PreToolHook.Context.tainted(flagFile: taintFile))
            if let out = PreToolHook.run(stdin: input, context: context) { print(out) }
        }
    }
}
