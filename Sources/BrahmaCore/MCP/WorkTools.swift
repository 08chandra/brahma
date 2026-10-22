import Foundation
import GRDB

/// The work tools of `CompanyTools`: items, dependencies, comments and single-writer leases. Output that lists or shows
/// items is JSON (sorted keys, one line), so agent-written titles and notes can never forge another entry.
extension CompanyTools {
    // MARK: Schemas

    static func workSpecs() -> [ToolSpec] {
        let s = Self.self
        let key = s.prop("string", "Item key, e.g. ACME-12")
        let strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                          "description": .string("Repo-relative paths or globs")])
        let check: JSONValue = .object([
            "type": .string("object"),
            "description": .string("How the work is judged: a shell command the engine runs in a clean checkout"),
            "properties": .object(["command": s.prop("string", "Shell command; exit 0 means pass"),
                                   "timeoutSeconds": s.prop("integer", "1 to 3600 (default 600)"),
                                   "paths": strings]),
            "required": .array([.string("command")]),
        ])
        let fields: [String: JSONValue] = [
            "type": s.prop("string", "Item type from the company's pack, e.g. task, bug, spike, story, epic"),
            "title": s.prop("string", "Short title"),
            "description": s.prop("string", "What and why"),
            "acceptanceCriteria": s.prop("string", "How anyone can tell it is done"),
            "check": check,
            "touchPaths": strings,
            "priority": s.prop("integer", "0 (most urgent) to 4; default 2"),
            "points": s.prop("integer", "Estimate"),
            "tier": s.prop("string", "Effort tier: s, m or l"),
            "owner": s.prop("string", "Assignee handle; \"none\" clears (managers only)"),
            "reviewer": s.prop("string", "Reviewer handle; \"none\" clears"),
            "team": s.prop("string", "Team name; \"none\" clears"),
            "parent": s.prop("string", "Parent epic or story key; \"none\" clears"),
        ]
        var create = fields
        create["status"] = s.prop("string", "backlog (default) or ready")
        var update = fields
        update["key"] = key
        update["status"] = s.prop("string", "backlog, ready or blocked (the engine sets inReview and done)")
        update["blockedReason"] = s.prop("string", "Why it is blocked (with status blocked)")
        update["notes"] = s.prop("string", "Your working notes on the item")
        update["linkedBranch"] = s.prop("string", "Branch that holds the work")
        return [
            ToolSpec(name: "list_work", description: "List work items as JSON. Scopes: mine (assigned to you or leased by you), team, ready (claimable order), review (you review them), all.",
                     inputSchema: s.schema(["scope": s.prop("string", "mine, team, ready, review or all"),
                                            "status": s.prop("string", "Only this status")], required: ["scope"])),
            ToolSpec(name: "show_work_item", description: "Show one work item as JSON: spec, check, lease, dependencies, the last 10 events and review flags.",
                     inputSchema: s.schema(["key": key], required: ["key"])),
            ToolSpec(name: "create_work_item", description: "Create a work item (it starts in the backlog unless you say ready).",
                     inputSchema: s.schema(create, required: ["type", "title"])),
            ToolSpec(name: "update_work_item", description: "Change a work item. Assignees change status, notes and linkedBranch only; spec fields belong to the author, reviewer and managers.",
                     inputSchema: s.schema(update, required: ["key"])),
            ToolSpec(name: "link_dependency", description: "Make an item wait for another: it cannot be claimed until the other is done.",
                     inputSchema: s.schema(["key": key, "dependsOn": s.prop("string", "Key of the item it waits for")], required: ["key", "dependsOn"])),
            ToolSpec(name: "comment_work_item", description: "Comment on a work item. Only an @mention makes a comment ask a teammate to act.",
                     inputSchema: s.schema(["key": key, "text": s.prop("string", "Comment text")], required: ["key", "text"])),
            ToolSpec(name: "claim_lease", description: "Take the single-writer lease on a ready item and get a git worktree for it. You may hold one lease at a time.",
                     inputSchema: s.schema(["key": key], required: ["key"])),
            ToolSpec(name: "release_lease", description: "Give the item back. Your work is committed to its branch and the item returns to ready.",
                     inputSchema: s.schema(["key": key, "note": s.prop("string", "Why, and where you stopped")], required: ["key"])),
            ToolSpec(name: "submit_for_review", description: "Hand your finished work over. The engine commits your worktree, runs the item's check on that commit and, once it passes, asks the reviewer. You are notified of the result; you cannot mark the item in review or done yourself.",
                     inputSchema: s.schema(["key": key, "summary": s.prop("string", "What you did, and anything the reviewer should look at")],
                                           required: ["key", "summary"])),
            ToolSpec(name: "confirm_spec", description: "Vouch for an item's spec (managers and executives): its tier, priority and type then count for model selection.",
                     inputSchema: s.schema(["key": key], required: ["key"])),
        ]
    }

    // MARK: Dispatch

    func callWork(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        switch name {
        case "list_work": return try listWork(scope: try string(args, "scope"), status: try optString(args, "status"))
        case "show_work_item": return try showWorkItem(try item(args))
        case "create_work_item": return try createWorkItem(args)
        case "update_work_item": return try updateWorkItem(args)
        case "link_dependency":
            let a = try item(args), b = try item(args, "dependsOn")
            try store.addDependency(itemId: a.id, dependsOn: b.id, by: .agent(agentId))
            return "\(a.key) now waits for \(b.key)."
        case "comment_work_item":
            let i = try item(args)
            try store.commentWorkItem(id: i.id, by: .agent(agentId), text: try string(args, "text"))
            return "Commented on \(i.key)."
        case "claim_lease": return try claimLease(try item(args))
        case "release_lease": return try releaseLease(try item(args), note: try optString(args, "note"))
        case "submit_for_review": return try submitForReview(try item(args), summary: try string(args, "summary"))
        case "confirm_spec":
            let i = try item(args)
            try store.confirmSpec(id: i.id, by: .agent(agentId))
            return "Confirmed the spec of \(i.key)."
        default: return nil
        }
    }

    // MARK: Argument helpers

    private func optString(_ args: [String: JSONValue], _ key: String) throws -> String? {
        guard let v = args[key], v != .null else { return nil }
        guard let s = v.stringValue else { throw ToolError(message: "argument \(key) must be a string") }
        return s
    }

    private func optInt(_ args: [String: JSONValue], _ key: String) throws -> Int? {
        guard let v = args[key], v != .null else { return nil }
        guard let n = v.numberValue, n.isFinite, n == n.rounded(), abs(n) < 1e9 else { throw ToolError(message: "argument \(key) must be an integer") }
        return Int(n)
    }

    private func optStrings(_ args: [String: JSONValue], _ key: String) throws -> [String]? {
        guard let v = args[key], v != .null else { return nil }
        guard let a = v.arrayValue else { throw ToolError(message: "argument \(key) must be an array of strings") }
        return try a.map {
            guard let s = $0.stringValue else { throw ToolError(message: "argument \(key) must be an array of strings") }
            return s
        }
    }

    private func isNone(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).lowercased() == "none" }

    private func item(_ args: [String: JSONValue], _ name: String = "key") throws -> WorkItem {
        try item(key: try string(args, name))
    }

    func item(key raw: String) throws -> WorkItem {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let found = try store.workItem(companyId: companyId, key: key) else {
            throw ToolError(message: "no such work item \(String(key.prefix(40)).components(separatedBy: .newlines).joined(separator: " "))")
        }
        return found
    }

    private func agentId(handle raw: String) throws -> String {
        let h = Self.handle(raw)
        guard let a = try store.agent(companyId: companyId, name: h) else { throw ToolError(message: Self.describe(.unknownAgent(h))) }
        return a.id
    }

    private func handles() throws -> [String: String] {
        Dictionary(try store.agents(companyId: companyId).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private func json(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(v)) ?? Data("{}".utf8), as: UTF8.self)
    }

    private func optional(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }

    private func gitWorkspace(_ root: URL) -> GitWorkspace { store.gitWorkspace(root: root, companyId: companyId) }

    private func workspace() throws -> URL {
        guard let c = try store.company(id: companyId) else { throw ToolError(message: "no such company") }
        return URL(fileURLWithPath: c.workspacePath, isDirectory: true)
    }

    // MARK: Read

    private func summary(_ i: WorkItem, handles: [String: String], lease: WorkLease?, waits: [String]) -> JSONValue {
        .object([
            "key": .string(i.key), "type": .string(i.type.rawValue), "title": .string(i.title), "status": .string(i.status.rawValue),
            "priority": .number(Double(i.priority)), "tier": .string(i.tier.rawValue),
            "owner": optional(i.ownerId.flatMap { handles[$0] }), "reviewer": optional(i.reviewerId.flatMap { handles[$0] }),
            "team": optional(i.team), "hasCheck": .bool(i.checkSpec != nil),
            "leasedBy": optional(lease.flatMap { handles[$0.agentId] }),
            "waitsOn": .array(waits.map { .string($0) }),
        ])
    }

    private func listWork(scope: String, status: String?) throws -> String {
        guard let me = try store.agent(id: agentId) else { throw ToolError(message: "this agent is not active in the company") }
        var filter = WorkItemFilter()
        if let status {
            guard let st = WorkItemStatus(rawValue: status) else {
                throw ToolError(message: "unknown status '\(status)' (\(WorkItemStatus.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            filter.statuses = [st]
        }
        var items: [WorkItem]
        switch scope {
        case "all": items = try store.workItems(companyId: companyId, filter: filter)
        case "mine":
            let leasedId = try store.lease(agentId: agentId)?.itemId
            items = try store.workItems(companyId: companyId, filter: filter).filter { $0.ownerId == agentId || $0.id == leasedId }
        case "team":
            guard let team = me.team else { items = []; break }
            filter.team = team
            items = try store.workItems(companyId: companyId, filter: filter)
        case "review":
            filter.reviewerId = agentId
            items = try store.workItems(companyId: companyId, filter: filter)
        case "ready":
            filter.statuses = [.ready]
            items = try store.workItems(companyId: companyId, filter: filter)
                .sorted { ($0.priority, $0.createdAt, $0.number) < ($1.priority, $1.createdAt, $1.number) }
        default:
            throw ToolError(message: "unknown scope '\(String(scope.prefix(40)))' (mine, team, ready, review or all)")
        }
        let total = items.count
        let shown = Array(items.prefix(100))
        let names = try handles()
        let leases = Dictionary(try store.leases(companyId: companyId).map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = try shown.map { i -> JSONValue in
            let waits = try store.dependencies(itemId: i.id).filter { $0.status != .done }.map(\.key)
            return summary(i, handles: names, lease: leases[i.id], waits: waits)
        }
        return json(.object(["items": .array(rows), "shown": .number(Double(shown.count)), "total": .number(Double(total)),
                             "scope": .string(scope)]))
    }

    private func showWorkItem(_ i: WorkItem) throws -> String {
        let names = try handles()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lease: JSONValue = .null
        if let l = try store.lease(itemId: i.id) {
            let ws = try workspace()
            let git = gitWorkspace(ws)
            let until = store.formatTime(l.expiresAt(activeNow: store.activeNow(companyId: companyId), now: Store.now()))
            lease = .object(["holder": optional(names[l.agentId]), "until": .string(until),
                             "worktree": .string(git.worktreePath(key: i.key).path), "branch": .string(git.branch(key: i.key)),
                             "progressFile": .string(ProgressFile.path(workspace: ws, key: i.key).path)])
        }
        var check: JSONValue = .null
        if let c = i.checkSpec {
            check = .object(["command": .string(c.command), "timeoutSeconds": .number(Double(c.timeoutSeconds)),
                             "paths": .array(c.paths.map { .string($0) }), "revision": .number(Double(i.checkRevision))])
        }
        func link(_ x: WorkItem) -> JSONValue { .object(["key": .string(x.key), "status": .string(x.status.rawValue), "title": .string(x.title)]) }
        let events: [JSONValue] = try store.itemEvents(itemId: i.id, limit: 10).map { e in
            .object(["at": .string(iso.string(from: e.createdAt)),
                     "actor": .string(e.actorId == "owner" || e.actorId == "system" ? e.actorId : names[e.actorId] ?? "unknown"),
                     "kind": .string(e.kind.rawValue), "text": .string(e.text)])
        }
        let parent = try i.parentId.flatMap { try store.workItem(id: $0)?.key }
        return json(.object([
            "key": .string(i.key), "type": .string(i.type.rawValue), "title": .string(i.title), "status": .string(i.status.rawValue),
            "blockedReason": optional(i.blockedReason), "description": .string(i.description),
            "acceptanceCriteria": .string(i.acceptanceCriteria), "check": check,
            "touchPaths": .array(i.touchPaths.map { .string($0) }), "priority": .number(Double(i.priority)),
            "points": i.points.map { .number(Double($0)) } ?? .null, "tier": .string(i.tier.rawValue),
            "author": .string(i.authorId == "owner" || i.authorId == "system" ? i.authorId : names[i.authorId] ?? "unknown"),
            "owner": optional(i.ownerId.flatMap { names[$0] }), "reviewer": optional(i.reviewerId.flatMap { names[$0] }),
            "team": optional(i.team), "parent": optional(parent), "linkedBranch": optional(i.linkedBranch), "notes": optional(i.notes),
            "reviewFlags": .array(i.reviewFlags.map { .string($0) }), "specConfirmed": .bool(i.specConfirmedBy != nil),
            "lease": lease, "dependencies": .array(try store.dependencies(itemId: i.id).map(link)),
            "dependents": .array(try store.dependents(itemId: i.id).map(link)), "events": .array(events),
        ]))
    }

    // MARK: Write

    private func checkSpec(_ v: JSONValue) throws -> CheckSpec {
        guard let o = v.objectValue, let command = o["command"]?.stringValue else {
            throw ToolError(message: "argument check must be an object with a command")
        }
        var spec = CheckSpec(command: command)
        if let t = o["timeoutSeconds"] {
            guard let n = t.numberValue, n.isFinite, n == n.rounded(), abs(n) < 1e9 else {
                throw ToolError(message: "check.timeoutSeconds must be an integer")
            }
            spec.timeoutSeconds = Int(n)
        }
        if let p = o["paths"] {
            guard let a = p.arrayValue, a.allSatisfy({ $0.stringValue != nil }) else { throw ToolError(message: "check.paths must be an array of strings") }
            spec.paths = a.compactMap(\.stringValue)
        }
        return spec
    }

    private func createWorkItem(_ args: [String: JSONValue]) throws -> String {
        var draft = WorkItemDraft(type: WorkItemType(try string(args, "type")), title: try string(args, "title"))
        draft.description = try optString(args, "description") ?? ""
        draft.acceptanceCriteria = try optString(args, "acceptanceCriteria") ?? ""
        if let c = args["check"], c != .null { draft.checkSpec = try checkSpec(c) }
        draft.touchPaths = try optStrings(args, "touchPaths") ?? []
        if let p = try optInt(args, "priority") { draft.priority = p }
        draft.points = try optInt(args, "points")
        if let t = try optString(args, "tier") {
            guard let tier = EffortTier(rawValue: t.lowercased()) else { throw ToolError(message: "tier must be s, m or l") }
            draft.tier = tier
        }
        if let o = try optString(args, "owner"), !isNone(o) { draft.ownerId = try agentId(handle: o) }
        if let r = try optString(args, "reviewer"), !isNone(r) { draft.reviewerId = try agentId(handle: r) }
        if let t = try optString(args, "team"), !isNone(t) { draft.team = t }
        if let p = try optString(args, "parent"), !isNone(p) { draft.parentId = try item(key: p).id }
        if let s = try optString(args, "status") {
            guard let st = WorkItemStatus(rawValue: s) else { throw ToolError(message: "unknown status '\(String(s.prefix(40)))'") }
            draft.status = st
        }
        let created = try store.createWorkItem(companyId: companyId, by: .agent(agentId), draft: draft)
        return "Created \(created.key): \(created.title) (\(created.status.rawValue))."
    }

    private func updateWorkItem(_ args: [String: JSONValue]) throws -> String {
        let target = try item(args)
        var patch = WorkItemPatch()
        if let t = try optString(args, "type") { patch.type = WorkItemType(t) }
        patch.title = try optString(args, "title")
        patch.description = try optString(args, "description")
        patch.acceptanceCriteria = try optString(args, "acceptanceCriteria")
        if let c = args["check"] {
            if c == .null || (c.stringValue.map(isNone) ?? false) { patch.checkSpec = .some(nil) } else { patch.checkSpec = .some(try checkSpec(c)) }
        }
        patch.touchPaths = try optStrings(args, "touchPaths")
        patch.priority = try optInt(args, "priority")
        if let p = try optInt(args, "points") { patch.points = .some(p) }
        if let t = try optString(args, "tier") {
            guard let tier = EffortTier(rawValue: t.lowercased()) else { throw ToolError(message: "tier must be s, m or l") }
            patch.tier = tier
        }
        if let o = try optString(args, "owner") { patch.ownerId = .some(isNone(o) ? nil : try agentId(handle: o)) }
        if let r = try optString(args, "reviewer") { patch.reviewerId = .some(isNone(r) ? nil : try agentId(handle: r)) }
        if let t = try optString(args, "team") { patch.team = .some(isNone(t) ? nil : t) }
        if let p = try optString(args, "parent") { patch.parentId = .some(isNone(p) ? nil : try item(key: p).id) }
        if let s = try optString(args, "status") {
            guard let st = WorkItemStatus(rawValue: s) else { throw ToolError(message: "unknown status '\(String(s.prefix(40)))'") }
            patch.status = st
        }
        patch.blockedReason = try optString(args, "blockedReason")
        if let n = try optString(args, "notes") { patch.notes = .some(n.isEmpty ? nil : n) }
        if let b = try optString(args, "linkedBranch") { patch.linkedBranch = .some(b.isEmpty ? nil : b) }
        let before = try store.lease(itemId: target.id)
        let updated = try store.updateWorkItem(id: target.id, by: .agent(agentId), patch: patch)
        var note = ""
        // A lease the update ended (back to ready, or given to someone else) takes its worktree with it; the work stays on the branch.
        if before != nil, try store.lease(itemId: target.id) == nil {
            do { try removeWorktreeUnlessLeased(key: target.key) } catch { note = " (its worktree could not be removed: \(error))" }
        }
        return "Updated \(updated.key)." + note
    }

    // MARK: Leases

    private func claimLease(_ target: WorkItem) throws -> String {
        let wasUnowned = target.ownerId == nil
        // No new work starts on a `main` that was rewritten outside Brahma.
        if let company = try store.company(id: companyId) {
            do { try store.prepareRepo(company: company) } catch let e as WorkError { throw e } catch {
                throw ToolError(message: "could not prepare the workspace: \(error)")
            }
        }
        let lease = try store.claimLease(itemId: target.id, agentId: agentId)
        let ws = try workspace()
        let git = gitWorkspace(ws)
        let path: URL
        do {
            try git.ensureRepo()
            path = try git.addWorktree(key: target.key)
            try ProgressFile.ensure(workspace: ws, item: target)
            // The baseline of the check's scripts, once per check revision; a reclaim keeps the first one.
            try store.ensureCheckSnapshot(item: target, workspace: ws)
        } catch {
            // The claim is undone; nothing this call did not create is removed.
            _ = try? store.releaseLease(itemId: target.id, agentId: agentId, note: "the worktree could not be created",
                                        undoOwner: wasUnowned)
            throw ToolError(message: "could not create your worktree, so the lease was released: \(error)")
        }
        let until = store.formatTime(lease.expiresAt(activeNow: store.activeNow(companyId: companyId), now: Store.now()))
        return "You hold \(target.key) until \(until). Work only in your worktree: \(path.path) (branch \(git.branch(key: target.key))). "
            + "Progress file: \(ProgressFile.path(workspace: ws, key: target.key).path)."
    }

    /// Removes the item's worktree unless a lease exists again by the time the item's lock is taken (a new claim won the
    /// race), or the lease cannot be read.
    private func removeWorktreeUnlessLeased(key: String) throws {
        let (store, companyId) = (self.store, self.companyId)
        try gitWorkspace(try workspace()).removeWorktree(key: key, keepIf: { try store.lease(companyId: companyId, key: key) != nil })
    }

    private func releaseLease(_ target: WorkItem, note: String?) throws -> String {
        try store.releaseLease(itemId: target.id, agentId: agentId, note: note)
        var tail = "Your work is saved on branch \(gitWorkspace(try workspace()).branch(key: target.key))."
        do { try removeWorktreeUnlessLeased(key: target.key) } catch {
            tail = "Its worktree could not be removed yet (\(error)); your work stays in it."
        }
        return "Released \(target.key). \(tail)"
    }

    // MARK: Submit

    /// Commits the worktree, notes anything that weakens the verification (deleted, modified or renamed test files, edited
    /// or deleted check scripts), and queues the engine's check on that commit. The agent never supplies the commit or flags.
    private func submitForReview(_ target: WorkItem, summary: String) throws -> String {
        // Refusals first, so nothing is committed on behalf of someone who does not hold the item.
        guard let lease = try store.lease(itemId: target.id), lease.agentId == agentId else {
            throw ToolError(message: "you do not hold \(target.key)")
        }
        guard target.status == .inProgress else {
            throw ToolError(message: "\(target.key) is \(target.status.title.lowercased()), not in progress")
        }
        // Nothing is committed for a submit that would be refused anyway.
        _ = try Store.validSummary(summary)
        try store.checkReviewerAvailable(itemId: target.id)
        let git = gitWorkspace(try workspace())
        guard git.hasCheckout(key: target.key) else {
            throw ToolError(message: "your worktree for \(target.key) is missing; release the item and claim it again")
        }
        let worktree = git.worktreePath(key: target.key)
        guard let commit = try git.commitAll(in: worktree, message: "\(target.key): submit round \(target.reviewRound + 1)")
                ?? git.head(of: git.branchRef(key: target.key)) else { throw ToolError(message: "\(target.key) has no commit to submit") }
        if commit == target.baseCommit { throw ToolError(message: "\(target.key) has no changes to submit") }

        // Weakening is measured against the base the engine recorded at claim, never the live `main` (an agent can move that ref).
        // History and check-script flags come first: the flag list is capped, and test-file flags (one per file) must not push them out.
        var flags: [String] = []
        var testFlags: [String] = []
        if let base = target.baseCommit {
            do {
                let changes = try git.nameStatus(base: base, head: commit)
                for c in changes.entries {
                    switch c.status.first {
                    case "D" where PathRules.isTestFile(c.path): testFlags.append("deleted test file \(c.path)")
                    case "M" where PathRules.isTestFile(c.path), "T" where PathRules.isTestFile(c.path):
                        testFlags.append("modified test file \(c.path)")
                    case "R" where c.oldPath.map(PathRules.isTestFile) == true:
                        testFlags.append("renamed test file \(c.oldPath ?? "?") → \(c.path)")
                    default: break
                    }
                }
                if changes.truncated { flags.append("change list too long to inspect (more than 2000 files)") }
            } catch {
                flags.append("change list could not be inspected")
            }
        } else {
            flags.append("branch has no common history with main")
        }
        // Script hashes come from the committed tree: what the check will run, not what the worktree holds now.
        var current: [String: String] = [:]
        if let snapshot = try store.latestCheckSnapshot(itemId: target.id, upTo: target.checkRevision) {
            let names = snapshot.manifest.keys.sorted()
            let committed = try git.blobs(at: commit, paths: names, limit: max(names.count, 1))
            for name in names {
                if let data = committed[name] {
                    let hash = StableHash.fnv1a64(data)
                    current[name] = hash
                    if hash != snapshot.manifest[name] { flags.append("check script modified: \(name)") }
                } else {
                    flags.append("check script deleted: \(name)")
                }
            }
        }
        flags += testFlags
        let result = try store.submitForReview(itemId: target.id, agentId: agentId, summary: summary, flags: flags, commit: commit,
                                               scriptHash: CheckScripts.scriptHash(current), workingDirectory: worktree.path)
        let short = String(commit.prefix(7))
        return result.run == nil
            ? "Submitted \(target.key) at \(short). It has no check, so it goes straight to review."
            : "Submitted \(target.key) at \(short). The engine is running its check; you will be notified."
    }

    /// `set_blocked` on a work item key. Nil when the text names no item but an agent has that handle.
    func setBlockedOnItem(key: String) throws -> String? {
        let found = try store.workItem(companyId: companyId, key: key)
        guard let found else {
            if try store.agent(companyId: companyId, name: key.lowercased()) != nil { return nil }
            throw ToolError(message: "no such work item or agent: \(key)")
        }
        guard found.status != .done else { throw ToolError(message: "\(found.key) is already done") }
        try store.writer.write { [agentId] db in
            guard let current = try WorkItem.fetchOne(db, key: found.id), current.status != .done else {
                throw ToolError(message: "\(found.key) is already done")
            }
            guard var me = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            me.requestedBlocker = .workItem(id: found.id, key: found.key)
            try me.update(db, columns: ["requestedBlocker"])
        }
        return "Marked blocked on \(found.key); this takes effect when your turn ends."
    }
}
