import ArgumentParser
import Foundation
import BrahmaCore

/// Parses a status as typed: `inProgress`, `in-progress` and `in_progress` all work.
private func parseStatus(_ text: String) throws -> WorkItemStatus {
    let norm = text.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    guard let s = WorkItemStatus.allCases.first(where: { $0.rawValue.lowercased() == norm }) else {
        throw fail("unknown status '\(text)' (backlog, ready, inProgress, inReview, done, blocked)")
    }
    return s
}

private func parseTier(_ text: String) throws -> EffortTier {
    guard let t = EffortTier(rawValue: text.lowercased()) else { throw fail("unknown tier '\(text)' (s, m or l)") }
    return t
}

private func parseIntensity(_ text: String) throws -> WorkIntensity {
    guard let i = WorkIntensity(rawValue: text.lowercased()) else { throw fail("unknown intensity '\(text)' (auto, thorough or ultra)") }
    return i
}

private func isNone(_ text: String) -> Bool { text.lowercased() == "none" }

private func resolveItem(_ store: Store, _ company: Company, _ key: String) throws -> WorkItem {
    guard let item = try store.workItem(companyId: company.id, key: key) else {
        throw fail("no work item \(key.uppercased()) in \(company.name)")
    }
    return item
}

/// Runs a store call, turning a refused work operation into a plain CLI error.
private func refusing<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as WorkError { throw fail(e.message) }
}

private func agentId(_ store: Store, _ company: Company, _ handle: String) throws -> String {
    try resolveAgent(store, company: company, handle: handle).id
}

private func handleMap(_ store: Store, _ company: Company) throws -> [String: String] {
    var map = ["owner": "owner", "system": "system"]
    for a in try store.agents(companyId: company.id) { map[a.id] = a.name }
    return map
}

struct ItemsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "items", abstract: "List, show and change work items.",
        subcommands: [List.self, Show.self, Add.self, Edit.self, Depend.self, Confirm.self, Readopt.self], defaultSubcommand: List.self)

    /// An item branch the engine found moved outside its holder's turns: the owner takes it as it is, so submits work again.
    struct Readopt: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "readopt", abstract: "Re-adopt an item's branch after it was found moved outside its holder's turns (owner only).")
        @Argument var company: String
        @Argument(help: "Item key, e.g. ACME-12.") var key: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let i = try resolveItem(store, c, key)
            let git = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true))
            do {
                let adopted = try store.readoptBranch(itemId: i.id, by: .owner, head: try git.head(of: git.branchRef(key: i.key)))
                print("re-adopted item/\(adopted.key) at \(adopted.leaseHeadCommit?.prefix(7) ?? "?")")
            } catch let e as WorkError { throw fail(e.message) }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List work items.")
        @Argument var company: String
        @Option(help: "Only this status (backlog, ready, inProgress, inReview, done, blocked).") var status: String?
        @Option(help: "Only items assigned to this handle.") var owner: String?
        @Option(help: "Only this team.") var team: String?
        @Option(help: "Only this item type.") var type: String?
        @Option(help: "Number of items (1-5000).") var limit: Int = 200

        func validate() throws {
            guard (1...5000).contains(limit) else { throw ValidationError("--limit must be between 1 and 5000") }
        }

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            var filter = WorkItemFilter(limit: limit)
            if let status { filter.statuses = [try parseStatus(status)] }
            if let owner { filter.ownerId = try agentId(store, c, owner) }
            if let team { filter.team = team }
            if let type { filter.type = WorkItemType(type.lowercased()) }
            let names = try handleMap(store, c)
            let items = try store.workItems(companyId: c.id, filter: filter)
            if items.isEmpty { print("(no work items)") }
            for i in items {
                let owner = i.ownerId.map { "@" + (names[$0] ?? "?") } ?? "unassigned"
                print(safe("\(i.key)  \(i.status.title)  \(i.type.rawValue)  p\(i.priority)  \(i.tier.label)  \(owner)  \(i.title)"))
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one work item with its dependencies and recent events.")
        @Argument var company: String
        @Argument(help: "Item key, e.g. ACME-12.") var key: String
        @Option(help: "How many recent events to show (1-200).") var events: Int = 20

        func validate() throws {
            guard (1...200).contains(events) else { throw ValidationError("--events must be between 1 and 200") }
        }

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let i = try resolveItem(store, c, key)
            let names = try handleMap(store, c)
            func who(_ id: String?) -> String { id.map { "@" + (names[$0] ?? "?") } ?? "none" }
            print(safe("\(i.key)  \(i.title)"))
            print(safe("type: \(i.type.rawValue)  status: \(i.status.title)  priority: \(i.priority)  tier: \(i.tier.label)  points: \(i.points.map(String.init) ?? "none")"))
            print(safe("assignee: \(who(i.ownerId))  reviewer: \(who(i.reviewerId))  author: \(who(i.authorId))  team: \(i.team ?? "none")"))
            if let p = i.parentId, let parent = try store.workItem(id: p) { print(safe("parent: \(parent.key)")) }
            print(safe("intensity: \(i.intensity.rawValue)  spec: \(i.specConfirmedBy.map { "confirmed by \(who(String($0.split(separator: ":").first ?? "")))" } ?? "unconfirmed")"))
            if i.status == .blocked { print(safe("blocked: \(i.blockedReason ?? "(no reason)")")) }
            if let stopped = i.stopReason { print(safe("Stopped: \(stopped)")) }
            if let check = i.checkSpec {
                var line = "check (revision \(i.checkRevision)): \(check.command)  timeout: \(check.timeoutSeconds)s"
                if !check.paths.isEmpty { line += "  paths: \(check.paths.joined(separator: ", "))" }
                print(safe(line))
            } else {
                print("check: none")
            }
            if !i.reviewFlags.isEmpty { print(safe("review flags: \(i.reviewFlags.joined(separator: ", "))")) }
            for d in try store.dependencies(itemId: i.id) { print(safe("waits for: \(d.key) (\(d.status.title)) \(d.title)")) }
            for d in try store.dependents(itemId: i.id) { print(safe("blocks: \(d.key) (\(d.status.title)) \(d.title)")) }
            if !i.description.isEmpty {
                print("description:")
                for line in i.description.components(separatedBy: .newlines) { print(safe("    | " + line)) }
            }
            if !i.acceptanceCriteria.isEmpty {
                print("acceptance criteria:")
                for line in i.acceptanceCriteria.components(separatedBy: .newlines) { print(safe("    | " + line)) }
            }
            let recent = try store.itemEvents(itemId: i.id, limit: events)
            if !recent.isEmpty {
                print("events:")
                for e in recent {
                    print(safe("  \(clock(e.createdAt, seconds: true)) \(e.kind.rawValue) by @\(names[e.actorId] ?? "?"): \(e.text)"))
                }
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a work item (owner only).")
        @Argument var company: String
        @Option(help: "Item type from the company's pack (software: epic, story, task, bug, spike).") var type: String = "task"
        @Option(help: "Title.") var title: String
        @Option(help: "Description.") var description: String = ""
        @Option(help: "Acceptance criteria.") var criteria: String = ""
        @Option(help: "Check command, run by the engine in a clean checkout.") var check: String?
        @Option(name: .customLong("path"), help: "A repo-relative path the check covers (repeatable).") var paths: [String] = []
        @Option(help: "Check timeout in seconds (1-3600).") var timeout: Int?
        @Option(name: .customLong("touch"), help: "A repo-relative path or glob the item changes besides its check's paths (repeatable).") var touch: [String] = []
        @Option(help: "Effort tier: s, m or l.") var tier: String = "m"
        @Option(help: "Priority 0 (most urgent) to 4.") var priority: Int = 2
        @Option(help: "Parent epic or story key.") var parent: String?
        @Option(help: "Assignee handle.") var owner: String?
        @Option(help: "Reviewer handle.") var reviewer: String?
        @Option(help: "Team name.") var team: String?
        @Option(help: "Intensity: auto, thorough or ultra.") var intensity: String = "auto"
        @Flag(help: "Create it ready instead of in the backlog.") var ready = false

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            var spec: CheckSpec?
            if let check { spec = CheckSpec(command: check, timeoutSeconds: timeout ?? 600, paths: paths) }
            else if timeout != nil || !paths.isEmpty { throw fail("--timeout and --path need --check") }
            var draft = WorkItemDraft(type: WorkItemType(type.lowercased()), title: title, description: description,
                                      acceptanceCriteria: criteria, checkSpec: spec, priority: priority,
                                      tier: try parseTier(tier), team: team, status: ready ? .ready : .backlog,
                                      intensity: try parseIntensity(intensity), touchPaths: touch)
            if let parent { draft.parentId = try resolveItem(store, c, parent).id }
            if let owner { draft.ownerId = try agentId(store, c, owner) }
            if let reviewer { draft.reviewerId = try agentId(store, c, reviewer) }
            let item = try refusing { try store.createWorkItem(companyId: c.id, by: .owner, draft: draft) }
            print(safe("created \(item.key) (\(item.type.rawValue)): \(item.title)"))
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit", abstract: "Change a work item (owner only). 'none' clears --owner, --reviewer, --team, --parent and --check.")
        @Argument var company: String
        @Argument(help: "Item key.") var key: String
        @Option var type: String?
        @Option var title: String?
        @Option var description: String?
        @Option var criteria: String?
        @Option(help: "New check command, or 'none'.") var check: String?
        @Option(name: .customLong("path"), help: "Replace the check's paths (repeatable).") var paths: [String] = []
        @Option var timeout: Int?
        @Option(name: .customLong("touch"), help: "Replace the item's touch paths (repeatable); 'none' clears them.") var touch: [String] = []
        @Option var tier: String?
        @Option var priority: Int?
        @Option(help: "Parent key, or 'none'.") var parent: String?
        @Option(help: "Assignee handle, or 'none'.") var owner: String?
        @Option(help: "Reviewer handle, or 'none'.") var reviewer: String?
        @Option(help: "Team name, or 'none'.") var team: String?
        @Option(help: "Intensity: auto, thorough or ultra.") var intensity: String?
        @Option(help: "backlog, ready or blocked (the engine sets the rest).") var status: String?
        @Option(help: "Why it is blocked (with --status blocked).") var reason: String?

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let item = try resolveItem(store, c, key)
            var patch = WorkItemPatch()
            if let type { patch.type = WorkItemType(type.lowercased()) }
            patch.title = title
            patch.description = description
            patch.acceptanceCriteria = criteria
            if let check, isNone(check) {
                patch.checkSpec = .some(nil)
            } else if check != nil || timeout != nil || !paths.isEmpty {
                guard let command = check ?? item.checkSpec?.command else { throw fail("this item has no check; give --check") }
                var spec = item.checkSpec ?? CheckSpec(command: command)
                spec.command = command
                if let timeout { spec.timeoutSeconds = timeout }
                if !paths.isEmpty { spec.paths = paths }
                patch.checkSpec = .some(spec)
            }
            if !touch.isEmpty { patch.touchPaths = touch.count == 1 && isNone(touch[0]) ? [] : touch }
            if let tier { patch.tier = try parseTier(tier) }
            patch.priority = priority
            if let parent { patch.parentId = .some(isNone(parent) ? nil : try resolveItem(store, c, parent).id) }
            if let owner { patch.ownerId = .some(isNone(owner) ? nil : try agentId(store, c, owner)) }
            if let reviewer { patch.reviewerId = .some(isNone(reviewer) ? nil : try agentId(store, c, reviewer)) }
            if let team { patch.team = .some(isNone(team) ? nil : team) }
            if let intensity { patch.intensity = try parseIntensity(intensity) }
            if let status { patch.status = try parseStatus(status) }
            patch.blockedReason = reason
            let updated = try refusing { try store.updateWorkItem(id: item.id, by: .owner, patch: patch) }
            print(safe("updated \(updated.key)"))
        }
    }

    struct Depend: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "depend", abstract: "Make one item wait for another (owner only).")
        @Argument var company: String
        @Argument(help: "The waiting item's key.") var key: String
        @Option(help: "The key it waits for.") var on: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let item = try resolveItem(store, c, key)
            let other = try resolveItem(store, c, on)
            try refusing { try store.addDependency(itemId: item.id, dependsOn: other.id, by: .owner) }
            print(safe("\(item.key) now waits for \(other.key)"))
        }
    }

    struct Confirm: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "confirm", abstract: "Confirm an item's spec so its tier, priority and type count for model selection (owner only).")
        @Argument var company: String
        @Argument(help: "Item key.") var key: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let item = try resolveItem(store, c, key)
            try refusing { _ = try store.confirmSpec(id: item.id, by: .owner) }
            print(safe("confirmed the spec of \(item.key)"))
        }
    }
}
