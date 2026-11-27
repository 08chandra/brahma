import ArgumentParser
import Foundation
import BrahmaCore

extension CompanyGroup {
    /// `brahma company landing <co> [local|pr] [--engine-merge]` (Plan X8 Task 1).
    struct Landing: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "landing",
            abstract: "How a company's approved items reach main: local (the engine fast-forwards main) or pr (a pushed brahma/ branch "
                + "and a pull request on GitHub). Owner only; without a mode it shows the current one.",
            discussion: "pr needs a connected github channel with a grant for push-branch (brahma/), open-pr and comment, and the "
                + "engine-held push token (brahma secret set <company> GITHUB_PUSH_TOKEN). --engine-merge lets the engine merge a "
                + "mergeable PR itself and needs a merge-pr grant too; without it you merge on GitHub. Switching back to local "
                + "abandons nothing: open PRs keep being watched until they are merged or you close them.")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "local or pr; omit to show the current mode and the grant status.") var mode: LandingMode?
        @Flag(name: .customLong("engine-merge"), help: "With pr: the engine merges a mergeable PR itself (needs a merge-pr grant).")
        var engineMerge = false

        func validate() throws {
            if engineMerge, mode != .pr { throw ValidationError("--engine-merge goes with pr") }
        }

        func run() throws {
            guard let mode else { try show(); return }
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            do {
                try LandingSwitch.apply(mode, engineMerge: engineMerge, companyId: c.id, store: store, checker: NoChannelGrantChecker(store: store))
            } catch let e as WorkError { throw fail(e.message) }
            let flag = mode == .pr && engineMerge ? " (engine-merge on)" : ""
            print(safe("\(c.name): landing \(mode.rawValue)\(flag)"))
        }

        /// A read: the mode, the engine-merge flag and what the grant checker reports (never a secret's value).
        private func show() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let (mode, engineMerge) = try store.landing(companyId: c.id)
            let status = try NoChannelGrantChecker(store: store).status(companyId: c.id)
            let grants = status.grantedActions.isEmpty ? "none" : status.grantedActions.sorted().joined(separator: ", ")
            for line in ["landing: \(mode.rawValue)", "engine-merge: \(engineMerge ? "on" : "off")",
                         "github channel: \(status.channelConnected ? "connected" : "not connected")", "grants: \(grants)",
                         "token: \(status.tokenPresent ? "present" : "missing") (\(LandingSwitch.tokenSecretName))"] {
                print(safe(line))
            }
            if mode == .local, let why = LandingSwitch.refusal(mode: .pr, engineMerge: false, status: status) { print(safe("pr: \(why)")) }
        }
    }
}

extension LandingMode: ExpressibleByArgument {}
