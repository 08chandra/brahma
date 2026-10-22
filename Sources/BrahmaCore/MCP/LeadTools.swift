import Foundation
import GRDB

/// The Inbox tools: `propose_decision`, `request_from_owner`, `escalate_decision`, `decide` and `request_mode`, and the sprint
/// tools `plan_sprint` and `close_sprint` (managers and executives). Registered from `CompanyTools`.
/// None of them can take an owner decision: that exists only in `Store.ownerDecide` and its siblings.
extension CompanyTools {
    static func inboxToolSpecs() -> [ToolSpec] {
        func prop(_ type: String, _ description: String) -> JSONValue {
            .object(["type": .string(type), "description": .string(description)])
        }
        func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map { .string($0) })])
        }
        let option: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["label": prop("string", "Short name"), "pros": prop("string", "Why choose it"),
                                   "cons": prop("string", "What it costs"), "effort": prop("string", "S, M or L"),
                                   "risk": prop("string", "What could go wrong")]),
            "required": .array([.string("label")])])
        let options: JSONValue = .object(["type": .string("array"), "items": option, "description": .string("Up to four alternatives")])
        let keys: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                       "description": .string("Work item keys committed to the sprint, e.g. ACME-12")])
        return [
            ToolSpec(name: "plan_sprint", description: """
                Plan the next sprint of your team (or the company): a goal and the items committed to it. It files a sprint-plan \
                ask; once approved, backlog items become Ready. It is done when every item is done (or, with cadence milestone, \
                the milestone item) or after 5 active days or 200 team turns. One open sprint per team.
                """, inputSchema: schema([
                    "goal": prop("string", "What the sprint delivers, in one line"), "items": keys,
                    "team": prop("string", "Team name; omit for a company-wide sprint"),
                    "cadence": prop("string", "sprint (default: all items done) or milestone"),
                    "milestone_key": prop("string", "With cadence milestone: the item whose completion ends the sprint"),
                ], required: ["goal", "items"])),
            ToolSpec(name: "close_sprint", description: """
                Close a sprint that is complete or reached its timebox: the review summary (what shipped, what slipped and why) \
                and the retro lessons, which go into the team's notes file. Unfinished items carry over to the backlog.
                """, inputSchema: schema([
                    "sprint": prop("string", "Sprint, e.g. Sprint 3"), "summary": prop("string", "Review summary"),
                    "lessons": prop("string", "Retro lessons, one per line"),
                ], required: ["sprint", "summary", "lessons"])),
            ToolSpec(name: "propose_decision", description: """
                File a decision for approval: a PRD, an architecture, a release, or any other choice (sprint plans use plan_sprint). \
                Write it as a brief: stakes in plain language, your recommendation, up to four options, whether it is \
                reversible, and the exact proposal. Mechanical matters are recorded without an approval.
                """, inputSchema: schema([
                    "kind": prop("string", "prd, architecture, release or other"),
                    "title": prop("string", "One line"), "summary": prop("string", "What and why"),
                    "category": prop("string", "Required for other: e.g. general, tooling, pricing, legal"),
                    "risk": prop("string", "low, medium or high"),
                    "document_path": prop("string", "A file in your workspace the approver should read"),
                    "item": prop("string", "Work item key this is about"), "supersedes": prop("string", "Ask ref it replaces, e.g. A-3"),
                    "options": options, "recommendation": prop("string", "What you recommend and why"),
                    "stakes": prop("string", "What is at stake, in plain language"),
                    "reversible": prop("string", "oneWay or twoWay"), "proposal": prop("string", "The exact action being approved"),
                    "request_id": prop("string", "Your own id; repeating it returns the same ask"),
                    "decision_class": prop("string", "mechanical, taste (default) or goalChanging"),
                ], required: ["kind", "title", "summary"])),
            ToolSpec(name: "request_from_owner", description: "Ask the owner a question only they can answer. Prefer propose_decision for choices.",
                     inputSchema: schema(["title": prop("string", "One line"), "question": prop("string", "The question"),
                                          "details": prop("string", "Background the owner needs"),
                                          "expires_in_hours": prop("number", "Stop waiting after this many active hours"),
                                          "request_id": prop("string", "Your own id; repeating it returns the same ask")],
                                         required: ["title", "question"])),
            ToolSpec(name: "escalate_decision", description: """
                Send an ask to the CEO (or the owner when no one else can take it), once per ask. The internal approver can escalate \
                a decision it cannot make; the requester can escalate after an internal rejection.
                """, inputSchema: schema(["ask": prop("string", "Ask ref, e.g. A-3"), "reason": prop("string", "Why it needs a higher decision")],
                                         required: ["ask", "reason"])),
            ToolSpec(name: "decide", description: "Decide an ask routed to you. You may raise its risk or move it to a reserved category, never lower them.",
                     inputSchema: schema(["ask": prop("string", "Ask ref, e.g. A-3"), "approve": prop("boolean", "true to approve, false to reject"),
                                          "note": prop("string", "Why"), "risk": prop("string", "low, medium or high (raise only)"),
                                          "category": prop("string", "A reserved category (raise only)")],
                                         required: ["ask", "approve", "note"])),
            ToolSpec(name: "request_mode", description: """
                Ask for more thinking on an item you are assigned to. Deep raises it to R2 from your next turn, never this one. \
                One request per item per three turns.
                """, inputSchema: schema(["key": prop("string", "Work item key"), "mode": prop("string", "deep or ultra"),
                                          "reason": prop("string", "Why the current mode is not enough"),
                                          "request_id": prop("string", "Your own id; repeating it changes nothing")],
                                         required: ["key", "mode", "reason", "request_id"])),
        ]
    }

    /// Runs an Inbox tool, or returns nil when `name` is not one.
    func dispatchInbox(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        do {
            switch name {
            case "propose_decision": return try proposeDecision(args)
            case "request_from_owner": return try requestFromOwner(args)
            case "decide": return try decide(args)
            case "escalate_decision": return try escalateDecision(args)
            case "request_mode": return try requestMode(args)
            case "plan_sprint": return try planSprint(args)
            case "close_sprint": return try closeSprint(args)
            default: return nil
            }
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        } catch StoreError.notFound {
            throw ToolError(message: "not found")
        }
    }

    // MARK: Tools

    private func proposeDecision(_ args: [String: JSONValue]) throws -> String {
        let kindName = try text(args, "kind")
        if kindName.lowercased() == AskKind.sprintPlan.rawValue.lowercased() {
            throw ToolError(message: "sprint plans are filed with plan_sprint")
        }
        let allowed: [AskKind] = [.prd, .architecture, .release, .other]
        guard let kind = allowed.first(where: { $0.rawValue.lowercased() == kindName.lowercased() }) else {
            throw ToolError(message: "kind must be one of: \(allowed.map(\.rawValue).joined(separator: ", "))")
        }
        let title = try text(args, "title"), summary = try text(args, "summary")
        let risk = try optionalText(args, "risk").map { r -> AskRisk in
            guard let v = AskRisk(rawValue: r.lowercased()) else { throw ToolError(message: "risk must be low, medium or high") }
            return v
        }
        let cls = try optionalText(args, "decision_class").map { c -> DecisionClass in
            guard let v = DecisionClass.allCases.first(where: { $0.rawValue.lowercased() == c.lowercased() }) else {
                throw ToolError(message: "decision_class must be mechanical, taste or goalChanging")
            }
            return v
        } ?? .taste
        var itemId: String?
        if let key = try optionalText(args, "item") {
            guard let item = try store.workItem(companyId: companyId, key: key) else { throw ToolError(message: "no work item \(key.uppercased())") }
            itemId = item.id
        }
        if cls == .mechanical {
            try store.recordMechanicalDecision(companyId: companyId, by: .agent(agentId), kind: kind, category: try optionalText(args, "category"), title: title,
                                                summary: summary, itemId: itemId)
            return "Recorded as a mechanical decision; no approval needed."
        }
        var supersedes: String?
        if let ref = try optionalText(args, "supersedes") {
            guard let old = try store.ask(companyId: companyId, ref: ref) else { throw ToolError(message: "no ask \(ref)") }
            supersedes = old.id
        }
        var reversible: Reversibility?
        if let r = try optionalText(args, "reversible") {
            guard let v = [Reversibility.oneWay, .twoWay].first(where: { $0.rawValue.lowercased() == r.lowercased() }) else {
                throw ToolError(message: "reversible must be oneWay or twoWay")
            }
            reversible = v
        }
        let payload = AskPayload(documentPath: try optionalText(args, "document_path"), options: try options(args),
                                 recommendation: try optionalText(args, "recommendation"), stakes: try optionalText(args, "stakes"),
                                 reversible: reversible, proposal: try optionalText(args, "proposal"))
        let deduped = try isRepeat(requestId: try optionalText(args, "request_id"))
        let ask = try store.propose(companyId: companyId, by: .agent(agentId), kind: kind, risk: risk,
                                    category: try optionalText(args, "category"), title: title, summary: summary, payload: payload,
                                    itemId: itemId, supersedes: supersedes, requestId: try optionalText(args, "request_id"),
                                    decisionClass: cls)
        return try describe(ask, expecting: kind, deduped: deduped)
    }

    private func requestFromOwner(_ args: [String: JSONValue]) throws -> String {
        var hours: Double?
        if let v = args["expires_in_hours"], v != .null {
            guard let n = v.numberValue, n.isFinite else { throw ToolError(message: "argument expires_in_hours must be a number") }
            hours = n
        }
        let deduped = try isRepeat(requestId: try optionalText(args, "request_id"))
        let ask = try store.requestFromOwner(companyId: companyId, by: .agent(agentId), title: try text(args, "title"),
                                             question: try text(args, "question"), details: try optionalText(args, "details"),
                                             expiresInHours: hours, requestId: try optionalText(args, "request_id"))
        if deduped || ask.kind != .info || ask.status != .pendingOwner { return try describe(ask, expecting: .info, deduped: deduped) }
        return "Asked the owner (\(ask.ref)). You will get the answer as a DM from the owner."
    }

    private func decide(_ args: [String: JSONValue]) throws -> String {
        let ref = try text(args, "ask")
        guard let ask = try store.ask(companyId: companyId, ref: ref) else { throw ToolError(message: "no ask \(ref)") }
        guard case .bool(let approve)? = args["approve"] else { throw ToolError(message: "argument approve must be true or false") }
        let risk = try optionalText(args, "risk").map { r -> AskRisk in
            guard let v = AskRisk(rawValue: r.lowercased()) else { throw ToolError(message: "risk must be low, medium or high") }
            return v
        }
        let done = try store.internalDecide(askId: ask.id, by: .agent(agentId), approve: approve, note: try optionalText(args, "note") ?? "",
                                            category: try optionalText(args, "category"), risk: risk)
        switch done.status {
        case .pendingOwner: return "\(done.ref) approved by you; it now waits for the owner's decision."
        case .approved: return "\(done.ref) approved under the company's autonomy setting; the owner is only informed."
        case .rejected: return "\(done.ref) rejected; the requester has been told."
        default: return "\(done.ref) is now \(done.status.rawValue)."
        }
    }

    private func escalateDecision(_ args: [String: JSONValue]) throws -> String {
        let ref = try text(args, "ask")
        guard let ask = try store.ask(companyId: companyId, ref: ref) else { throw ToolError(message: "no ask \(ref)") }
        let done = try store.escalate(askId: ask.id, by: .agent(agentId), reason: try text(args, "reason"))
        if done.status == .pendingInternal, let id = done.internalApproverId, let target = try store.agent(id: id) {
            return "Escalated \(done.ref) to @\(target.name)."
        }
        return "Escalated \(done.ref); no one else can decide it, so it waits for the owner."
    }

    private func planSprint(_ args: [String: JSONValue]) throws -> String {
        let cadence = try optionalText(args, "cadence").map { c -> CadenceKind in
            guard let v = CadenceKind(rawValue: c.lowercased()) else { throw ToolError(message: "cadence must be sprint or milestone") }
            return v
        }
        let (sprint, ask) = try store.planSprint(companyId: companyId, by: .agent(agentId), goal: try text(args, "goal"),
                                                 itemKeys: try stringArray(args, "items"), team: try optionalText(args, "team"),
                                                 cadence: cadence, milestoneKey: try optionalText(args, "milestone_key"))
        var waitingOn = "owner"
        if ask.status == .pendingInternal, let id = ask.internalApproverId, let approver = try store.agent(id: id) { waitingOn = approver.name }
        return "Planned \(sprint.name) (\(ask.ref)); waiting on @\(waitingOn)."
    }

    private func closeSprint(_ args: [String: JSONValue]) throws -> String {
        let ref = try text(args, "sprint")
        guard let sprint = try store.sprint(companyId: companyId, ref: ref) else { throw ToolError(message: "no sprint \(Store.flat(ref, max: 40))") }
        let closed = try store.closeSprint(sprintId: sprint.id, by: .agent(agentId), summary: try text(args, "summary"),
                                           lessons: try optionalText(args, "lessons") ?? "")
        let head = closed.summary?.components(separatedBy: "\n").first ?? closed.name
        return head + " Posted to #general; lessons added to the team's notes."
    }

    private func requestMode(_ args: [String: JSONValue]) throws -> String {
        try store.requestMode(companyId: companyId, by: agentId, itemKey: try text(args, "key"), mode: try text(args, "mode"),
                              reason: try text(args, "reason"), requestId: try optionalText(args, "request_id")).message
    }

    // MARK: Helpers

    /// Says what the ask is now. A repeated `request_id` returns the existing ask, which may be of another kind or already
    /// decided, so the text follows its actual kind and status.
    private func describe(_ ask: Ask, expecting kind: AskKind, deduped: Bool) throws -> String {
        let title = try store.displayTitle(ask)
        if ask.kind != kind {
            return "That request_id already belongs to \(ask.ref) (\(title), \(ask.status.rawValue)); nothing new was filed."
        }
        if !ask.status.isPending {
            return "\(ask.ref) (\(title)) was already filed with that request_id and is \(ask.status.rawValue); nothing new was filed."
        }
        if deduped {
            return "\(ask.ref) (\(title)) already filed (\(ask.status.rawValue)); nothing new was filed."
        }
        if ask.status == .pendingInternal, let id = ask.internalApproverId, let approver = try store.agent(id: id) {
            return "Filed \(ask.ref) (\(title)) for @\(approver.name) to decide; if it matters to the owner it goes on to them."
        }
        return "Filed \(ask.ref) (\(title)); it waits for the owner. You will get a DM with the outcome."
    }

    /// True when this requester already filed an ask under `requestId`, so the store will return it instead of filing a new one.
    private func isRepeat(requestId: String?) throws -> Bool {
        guard let rid = Store.cleanRequestId(requestId) else { return false }
        return try store.writer.read { db in
            try Ask.filter(Column("companyId") == companyId && Column("requesterId") == agentId && Column("requestId") == rid).fetchCount(db) > 0
        }
    }

    private func options(_ args: [String: JSONValue]) throws -> [AskOption] {
        guard let v = args["options"], v != .null else { return [] }
        guard let list = v.arrayValue else { throw ToolError(message: "argument options must be an array of objects") }
        return try list.map { item in
            guard let o = item.objectValue, let label = o["label"]?.stringValue else {
                throw ToolError(message: "each option needs a label")
            }
            return AskOption(label: label, pros: o["pros"]?.stringValue ?? "", cons: o["cons"]?.stringValue ?? "",
                             effort: o["effort"]?.stringValue ?? "", risk: o["risk"]?.stringValue ?? "")
        }
    }

    private func text(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let v = args[key], v != .null else { throw ToolError(message: "missing required argument: \(key)") }
        guard let s = v.stringValue else { throw ToolError(message: "argument \(key) must be a string") }
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError(message: "argument \(key) must not be empty") }
        return s
    }

    private func optionalText(_ args: [String: JSONValue], _ key: String) throws -> String? {
        guard let v = args[key], v != .null else { return nil }
        guard let s = v.stringValue else { throw ToolError(message: "argument \(key) must be a string") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}
