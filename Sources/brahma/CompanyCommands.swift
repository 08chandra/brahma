import ArgumentParser
import Foundation
import BrahmaCore

struct CompanyGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "company", abstract: "Create and manage companies.",
        subcommands: [Create.self, List.self, Pause.self, Resume.self, Mode.self, Weight.self, Reserve.self, Autonomy.self, Auto.self,
                      SetSetting.self, CompanyProfile.self])

    struct Create: ParsableCommand {
        @Argument(help: "Company name.") var name: String
        @Option(help: "What the company is for (optional with --demo live).") var goal: String?
        @Option(help: "Agents in the full org shape (0 for an empty company, otherwise 5 to 500; default 6).") var agents: Int?
        @Option(help: "Industry pack id (default software).") var pack: String?
        @Flag(help: "Print the org that would be created and change nothing.") var dryRun = false
        @Option(help: "A demo company. live: a four-agent org, hosting on the default provider, the hosting-account task and the owner's kickoff for a one-page waitlist site.")
        var demo: Demo?

        enum Demo: String, ExpressibleByArgument { case live }

        func run() throws {
            try requireOwnerShell()
            if let demo {
                // The demo builds its own org; a dry run of it would still create a company and post the kickoff.
                guard !dryRun, agents == nil, pack == nil else {
                    throw fail("--demo \(demo.rawValue) can't be combined with --dry-run, --agents or --pack")
                }
                switch demo {
                case .live:
                    let (store, paths) = try openStore()
                    let (c, task) = try DemoSeed.live(store: store, paths: paths, name: name, goal: goal) {
                        FileHandle.standardError.write(Data("brahma: \(safe($0))\n".utf8))
                    }
                    print(safe("Created \(c.name) with \(DemoSeed.liveHires.count) agents. Do Inbox task \(task.ref) (hosting account) now; "
                               + "approve the brief and the deploy when they arrive."))
                }
                return
            }
            guard let goal else { throw fail("--goal is required (or use --demo live)") }
            let agents = agents ?? 6
            let pack = pack ?? "software"
            guard agents == 0 || OrgGenerator.range.contains(agents) else {
                throw fail("--agents must be 0 or between \(OrgGenerator.range.lowerBound) and \(OrgGenerator.range.upperBound)")
            }
            let paths = BrahmaPaths.fromEnvironment()
            let catalog = PackCatalog.loadOrBuiltin(directory: paths.packsDir) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            guard let industry = catalog.pack(pack) else { throw fail("unknown pack '\(pack)'") }
            var staffed: (seated: OrgPlan, vacancies: [PlannedAgent])?
            var full: OrgPlan?
            if agents > 0 {
                if agents > 50 { print("Note: org sizes over 50 are experimental.") }
                let plan = try OrgGenerator.generate(goal: goal, count: agents, pack: industry)
                full = plan
                // The seat budget follows the plan tier; a dry run on a fresh home uses the default tier.
                let seats = FileManager.default.fileExists(atPath: paths.database.path)
                    ? try openStore().0.seatBudget() : PlanTier.max5x.seatBudget
                staffed = OrgGenerator.staff(plan: plan, pack: industry, readyWidth: 0, seatBudget: seats)
            }
            if dryRun {
                guard let full, let staffed else { print("(empty company)"); return }
                for line in full.treeLines(vacant: Set(staffed.vacancies.map(\.handle))) { print(safe(line)) }
                return
            }
            let (store, paths2) = try openStore()
            let c = try store.createCompany(name: name, goal: goal, workspacesRoot: paths2.workspaces, packId: pack)
            // The engine-owned pre-commit hook (Task 5a); a refusal is reported, the company stands.
            do {
                let layout = SandboxLayout(paths: paths2, company: c, agentHandle: "engine")
                try CompanyHooks.install(layout: layout, git: GitWorkspace(root: layout.workspace, exportHome: paths2.home))
            } catch { FileHandle.standardError.write(Data("brahma: could not install the pre-commit hook: \(safe("\(error)"))\n".utf8)) }
            // Brahma's built-in extensions (Task 10b); the engine also writes them at start.
            do { try BuiltinExtensions.materialize(workspace: URL(fileURLWithPath: c.workspacePath, isDirectory: true)) } catch {
                FileHandle.standardError.write(Data("brahma: could not write the built-in extensions: \(safe("\(error)"))\n".utf8))
            }
            print("\(c.id)  \(c.workspacePath)")
            if let staffed {
                let hired = try store.applyOrg(companyId: c.id, plan: staffed.seated, pack: industry, vacancies: staffed.vacancies)
                print("hired \(hired.count) of \(agents); \(staffed.vacancies.count) seats vacant")
            }
        }
    }

    struct List: ParsableCommand {
        func run() throws {
            let (store, _) = try openStore()
            print("name  status  mode  weight  agents(running/ready/blocked/sleeping)")
            for c in try store.companies() {
                let agents = try store.agents(companyId: c.id)
                func n(_ s: AgentState) -> Int { agents.filter { $0.state == s }.count }
                print(safe("\(c.name)  \(c.status.rawValue)  \(c.usageMode.rawValue)  \(c.priorityWeight)  "
                      + "\(n(.running))/\(n(.ready))/\(n(.blocked))/\(n(.sleeping))"))
            }
        }
    }

    struct Pause: ParsableCommand {
        @Argument var company: String
        func run() throws { try requireOwnerShell(); try set(company, .paused) }
    }

    struct Resume: ParsableCommand {
        @Argument var company: String
        func run() throws { try requireOwnerShell(); try set(company, .running) }
    }

    struct Mode: ParsableCommand {
        @Argument var company: String
        @Argument(help: "low, balanced or max.") var mode: UsageMode
        func run() throws { try requireOwnerShell(); try update(company) { $0.usageMode = mode } }
    }

    struct Weight: ParsableCommand {
        @Argument var company: String
        @Argument(help: "Scheduling weight (1 or more).") var weight: Int
        func run() throws {
            try requireOwnerShell()
            guard weight >= 1 else { throw fail("weight must be at least 1") }
            try update(company) { $0.priorityWeight = weight }
        }
    }

    struct Reserve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Override the share of the weekly allowance kept for you, for one company (advanced; see 'brahma settings share').")
        @Argument var company: String
        @Argument(help: "0.0 to 0.9, or 'default' to follow the owner-wide share.") var reserve: String

        func run() throws {
            try requireOwnerShell()
            let value: Double?
            if reserve.lowercased() == "default" {
                value = nil
            } else if let v = Double(reserve), (0.0...0.9).contains(v) {
                value = v
            } else {
                throw fail("reserve must be between 0.0 and 0.9, or 'default'")
            }
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            try store.setOwnerReserve(companyId: c.id, value)
            print(safe("\(c.name): reserve \(value.map { String(format: "%.2f", $0) } ?? "default (\(Int(((1 - store.weeklyShare()) * 100).rounded()))%)")"))
        }
    }

    struct Autonomy: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "How much you are asked: everything, important (default) or auto. Reserved matters always come to you.")
        @Argument var company: String
        @Argument(help: "everything, important or auto.") var preset: AutonomyPreset
        func run() throws { try requireOwnerShell(); try CompanyGroup.setAutonomy(company, preset) }
    }

    struct Auto: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shorthand: 'auto on' is autonomy auto, 'auto off' is important.")
        @Argument var company: String
        @Argument(help: "on or off.") var state: OnOff
        func run() throws { try requireOwnerShell(); try CompanyGroup.setAutonomy(company, state == .on ? .auto : .important) }
    }

    enum OnOff: String, ExpressibleByArgument { case on, off }

    struct SetSetting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change a company setting. auto-merge-small: small, lead-configured tier S changes whose allowlisted check "
                + "passes land without a review turn and are audited after (off until you switch it on; 'brahma settings "
                + "auto-merge' must be on too).")
        enum Setting: String, ExpressibleByArgument { case autoMergeSmall = "auto-merge-small" }
        @Argument var company: String
        @Argument(help: "auto-merge-small.") var setting: Setting
        @Argument(help: "on or off.") var value: OnOff

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            switch setting {
            case .autoMergeSmall:
                try store.setAutoMergeSmall(companyId: c.id, value == .on)
                print(safe("\(c.name): auto-merge-small \(value.rawValue) (owner-wide auto-merge: \(store.autoMergeEnabled() ? "on" : "off"))"))
            }
        }
    }

    private static func setAutonomy(_ query: String, _ preset: AutonomyPreset) throws {
        let (store, _) = try openStore()
        let c = try resolveCompany(store, query)
        try store.setAutonomy(companyId: c.id, preset)
        print(safe("\(c.name) autonomy: \(preset.rawValue)"))
    }

    private static func set(_ query: String, _ status: CompanyStatus) throws {
        try update(query) { $0.status = status }
    }

    private static func update(_ query: String, _ change: (inout Company) -> Void) throws {
        let (store, _) = try openStore()
        var c = try resolveCompany(store, query)
        change(&c)
        try store.updateCompany(c)
        print(safe("\(c.name): \(c.status.rawValue), \(c.usageMode.rawValue) mode, weight \(c.priorityWeight)"))
    }
}

extension UsageMode: ExpressibleByArgument {}
