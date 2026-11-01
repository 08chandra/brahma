import Foundation
import GRDB

public struct ToolSpec: Encodable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// Listed with `annotations.readOnlyHint`: the CLI's plan mode lets such tools run and refuses the others (probe V-4).
    public var readOnly: Bool

    public init(name: String, description: String, inputSchema: JSONValue, readOnly: Bool = false) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
        self.readOnly = readOnly || CompanyTools.readOnlyTools.contains(name)
    }

    private enum CodingKeys: String, CodingKey { case name, description, inputSchema, annotations }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(inputSchema, forKey: .inputSchema)
        if readOnly { try c.encode(JSONValue.object(["readOnlyHint": .bool(true)]), forKey: .annotations) }
    }
}

/// Per-turn MCP quota counts. A real turn's server counts in the database by turn id (`Store.reserveTurnQuota`), so every server
/// process and every sub-agent of the turn shares one count; this in-memory counter serves tools built without a turn.
final class TurnQuotaCounter: @unchecked Sendable {
    enum Kind: String { case posts, items, comments, highRisk }
    private let lock = NSLock()
    private var used: [Kind: Int] = [:]

    func used(_ k: Kind) -> Int { lock.withLock { used[k] ?? 0 } }
    func reserve(_ k: Kind, limit: Int) -> Bool {
        lock.withLock {
            guard used[k, default: 0] < limit else { return false }
            used[k, default: 0] += 1
            return true
        }
    }
    func release(_ k: Kind) { lock.withLock { used[k] = max(0, (used[k] ?? 0) - 1) } }
}

/// A failure the agent should see as an `isError` tool result.
struct ToolError: Error { let message: String }

/// The tools one agent can call. Every call is attributed to `agentId` and writes straight to the shared store.
public struct CompanyTools: Sendable {
    let store: Store
    let companyId: String
    let agentId: String
    /// Receives diagnostics (stderr by default); stdout is reserved for JSON-RPC.
    let diagnostics: @Sendable (String) -> Void
    /// Set for the MCP server of a review turn: only the review tools, limited to this one item.
    let reviewItemId: String?
    /// Set for the MCP server of an audit turn (9c): only the `audit` tool, limited to the samples bound to this turn.
    let auditTurnId: String?

    /// The turn's mode quotas, from its credential row; nil: none (review turns, tools built without a turn).
    let quotas: ModeQuotas?
    /// The turn this server belongs to: its database counters hold the quotas, and every call needs its credential row live
    /// (`Store.turnCredentialIsLive`). nil: tools built without a turn (the in-memory counter, no credential check).
    let quotaTurnId: String?
    /// A plan turn's server: the mutating work and decision tools are not offered.
    let planTurn: Bool
    let counter = TurnQuotaCounter()

    public init(store: Store, companyId: String, agentId: String, reviewItemId: String? = nil, auditTurnId: String? = nil,
                quotas: ModeQuotas? = nil, quotaTurnId: String? = nil, planTurn: Bool = false) {
        self.init(store: store, companyId: companyId, agentId: agentId, reviewItemId: reviewItemId, auditTurnId: auditTurnId,
                  quotas: quotas, quotaTurnId: quotaTurnId, planTurn: planTurn, diagnostics: { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        })
    }

    init(store: Store, companyId: String, agentId: String, reviewItemId: String? = nil, auditTurnId: String? = nil,
         quotas: ModeQuotas? = nil, quotaTurnId: String? = nil, planTurn: Bool = false,
         diagnostics: @escaping @Sendable (String) -> Void) {
        self.store = store; self.companyId = companyId; self.agentId = agentId; self.diagnostics = diagnostics
        self.reviewItemId = reviewItemId
        self.auditTurnId = reviewItemId == nil ? auditTurnId : nil
        self.quotas = quotas; self.quotaTurnId = quotaTurnId; self.planTurn = planTurn
    }

    static let turnEndedMessage = "this turn has ended; its tools no longer work"

    /// Tools that only read; they carry `readOnlyHint` and are never counted.
    static let readOnlyTools: Set<String> = ["read_channel", "list_channels", "list_agents", "list_work", "show_work_item"]
    /// High-authority company tools (design §2.2): one call per turn when sub-agents are on, none on a plan turn, denied under
    /// taint (5-lite). `update_work_item` counts when it changes the spec or the assignee.
    public static let highRiskTools: Set<String> = ["decide", "propose_decision", "escalate_decision", "request_from_owner",
                                                    "request_mode", "plan_sprint", "close_sprint", "confirm_spec",
                                                    "request_access", "request_secret", "readopt_branch"]
    /// What a plan turn's server leaves out: everything that changes work, leases, decisions, channels or a turn's environment.
    static let planTurnExcluded: Set<String> = Set(["claim_lease", "release_lease", "submit_for_review", "update_work_item",
                                                    "create_work_item", "link_dependency", "write_handoff", "create_channel",
                                                    "set_blocked", "use_secret", "readopt_branch"])
        .union(highRiskTools)
    static let updateLowRiskFields: Set<String> = ["key", "status", "blockedReason", "blockedOnAsk", "notes", "linkedBranch"]

    func quotaKind(_ name: String, _ args: [String: JSONValue]) -> TurnQuotaCounter.Kind? {
        switch name {
        case "post_message", "send_dm": return .posts
        case "create_work_item": return .items
        case "comment_work_item": return .comments
        case "update_work_item": return Set(args.keys).isSubset(of: Self.updateLowRiskFields) ? nil : .highRisk
        default: return Self.highRiskTools.contains(name) ? .highRisk : nil
        }
    }

    /// Takes one unit of the turn's quota for this call. Returns whether a unit was taken (to give back if the call fails), or
    /// throws the refusal when the quota is used up. A counter the database cannot update refuses (fail closed).
    func reserveQuota(_ kind: TurnQuotaCounter.Kind) throws -> Bool {
        guard let q = quotas else { return false }
        let limit: Int?, what: String
        switch kind {
        case .posts: limit = q.posts; what = "\(q.posts) posts and DMs per turn"
        case .items: limit = q.itemsCreated; what = "\(q.itemsCreated) new items per turn"
        case .comments: limit = q.comments; what = "\(q.comments) comments per turn"
        case .highRisk: limit = q.highRisk; what = "\(q.highRisk ?? 0) high-risk company calls per turn"
        }
        guard let limit else { return false }
        let taken: Bool
        if let turnId = quotaTurnId {
            // Fail closed, and say why: a turn that ended takes nothing; a counter the database cannot update refuses too.
            do { taken = try store.reserveTurnQuota(turnId: turnId, kind: kind.rawValue, limit: limit) } catch is TurnNotLive {
                throw ToolError(message: Self.turnEndedMessage)
            } catch {
                diagnostics("brahma mcp: could not count a \(kind.rawValue) quota unit for turn \(turnId): \(error)")
                throw ToolError(message: "this turn's quota could not be counted, so nothing was done; say what you need in your final reply")
            }
        } else {
            taken = counter.reserve(kind, limit: limit)
        }
        guard taken else {
            throw ToolError(message: "this turn's limit is reached (\(what)); carry on next turn or say what you need in your final reply")
        }
        return true
    }

    func releaseQuota(_ kind: TurnQuotaCounter.Kind) {
        if let turnId = quotaTurnId {
            do { try store.releaseTurnQuota(turnId: turnId, kind: kind.rawValue) } catch {
                diagnostics("brahma mcp: failed to give back a \(kind.rawValue) quota unit: \(error)")
            }
        } else {
            counter.release(kind)
        }
    }

    static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) })])
    }
    static func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    /// The same list for every role (a stable prompt prefix); `call` enforces what the caller's role may use.
    public func specs() -> [ToolSpec] {
        let all = Self.baseSpecs() + Self.workSpecs() + Self.inboxToolSpecs() + Self.safetyToolSpecs()
        // An audit turn sees the audit tool only (`audit` is listed only here).
        if auditTurnId != nil { return [Self.auditSpec()] }
        if planTurn, reviewItemId == nil { return all.filter { !Self.planTurnExcluded.contains($0.name) } }
        guard reviewItemId != nil else { return all }
        // A review turn sees the review tools only (`review` itself is listed only here).
        return all.filter { CompanyToolNames.review.contains($0.name) } + [Self.reviewSpec()]
    }

    private static let implemented: Set<String> = Set((baseSpecs() + workSpecs() + inboxToolSpecs() + safetyToolSpecs()).map(\.name))

    private static func baseSpecs() -> [ToolSpec] {
        let s = Self.self
        let handles: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                          "description": .string("Teammate handles")])
        let base: [ToolSpec] = [
            ToolSpec(name: "post_message", description: "Post a message to a channel you are a member of. Use @handle to mention teammates.",
                     inputSchema: s.schema(["channel": s.prop("string", "Channel name, e.g. general"),
                                            "text": s.prop("string", "Message text")], required: ["channel", "text"])),
            ToolSpec(name: "send_dm", description: "Send a direct message to a teammate or to the owner.",
                     inputSchema: s.schema(["to": s.prop("string", "Recipient handle, e.g. @cto, or owner"),
                                            "text": s.prop("string", "Message text")], required: ["to", "text"])),
            ToolSpec(name: "read_channel", description: "Read the latest messages of a channel or DM you are in, oldest first.",
                     inputSchema: s.schema(["channel": s.prop("string", "Channel name"),
                                            "limit": s.prop("integer", "How many messages (default 20, max 100)")], required: ["channel"])),
            ToolSpec(name: "list_channels", description: "List the channels you are a member of.",
                     inputSchema: s.schema([:], required: [])),
            ToolSpec(name: "list_agents", description: "List everyone in the company with role and state.",
                     inputSchema: s.schema([:], required: [])),
            ToolSpec(name: "create_channel", description: "Create a channel with the given teammates (you are always included).",
                     inputSchema: s.schema(["name": s.prop("string", "Channel name"), "members": handles],
                                           required: ["name", "members"])),
            ToolSpec(name: "set_blocked", description: "Declare you cannot continue until someone answers or a work item is done. Takes effect when your turn ends.",
                     inputSchema: s.schema(["on": s.prop("string", "Who or what you are waiting on: @handle, owner, or a work item key such as ACME-12"),
                                            "reason": s.prop("string", "What you need"),
                                            "ask": s.prop("string", "With on owner: the open ask you wait for, e.g. A-3")],
                     required: ["on", "reason"])),
        ]
        return base
    }

    /// Runs a tool and returns its text result. Appends one `toolUse` event whether it succeeds or fails.
    public func call(name: String, arguments: [String: JSONValue]) throws -> String {
        defer { logUse(name) }
        // Validate the caller on every call: it may have been killed or removed since the server started.
        guard let me = try? store.agent(id: agentId), me.companyId == companyId, me.state != .killed else {
            throw ToolError(message: "this agent is not active in the company")
        }
        // A turn's server works only while its turn does: the turn must still be in progress and hold its credential row.
        if let turnId = quotaTurnId {
            let live: Bool
            do { live = try store.turnCredentialIsLive(turnId: turnId, companyId: companyId, agentId: agentId) } catch {
                diagnostics("brahma mcp: could not check the credential of turn \(turnId): \(error)")
                live = false
            }
            guard live else { throw ToolError(message: Self.turnEndedMessage) }
        }
        if auditTurnId != nil { return try callInAuditTurn(name: name, arguments: arguments) }
        if reviewItemId != nil { return try callInReviewTurn(name: name, arguments: arguments) }
        if name == "review" { throw ToolError(message: Store.reviewTurnOnlyMessage) }
        if CompanyToolNames.audit.contains(name) { throw ToolError(message: Store.auditTurnOnlyMessage) }
        if planTurn, Self.planTurnExcluded.contains(name) {
            throw ToolError(message: "\(name) is not available in a plan turn: write the plan; the next turn carries it out")
        }
        if Self.implemented.contains(name) {
            let packId = (try? store.company(id: companyId))??.packId ?? "software"
            guard store.catalog.template(role: me.role, pack: packId).companyTools.contains(name) else {
                throw ToolError(message: "\(name) is not available to your role")
            }
        }
        // Quotas count calls that succeed; a refused or failed call costs nothing. The unit is taken before the call (so two
        // concurrent calls cannot both take the last one) and given back if it fails.
        try refuseItemsBeingMerged(name, arguments)
        let kind = quotaKind(name, arguments)
        let reserved = try kind.map(reserveQuota) ?? false
        do {
            return try dispatch(name, arguments)
        } catch {
            if reserved, let kind { releaseQuota(kind) }
            throw error
        }
    }

    /// Tools that only read an item stay available while it merges.
    static let readOnlyItemTools: Set<String> = ["show_work_item", "list_work"]

    /// While the engine merges an item, no tool may act on it (`"<KEY> is being merged"`).
    private func refuseItemsBeingMerged(_ name: String, _ arguments: [String: JSONValue]) throws {
        guard !Self.readOnlyItemTools.contains(name) else { return }
        for field in ["key", "dependsOn"] {
            guard let raw = arguments[field]?.stringValue else { continue }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let item = try? store.workItem(companyId: companyId, key: key) else { continue }
            if try store.isMerging(itemId: item.id) { throw ToolError(message: "\(item.key) is being merged") }
        }
    }

    private func logUse(_ tool: String) {
        let handle = (try? store.agent(id: agentId))??.name ?? agentId
        do {
            try store.appendEvent(ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .toolUse,
                                                text: "@\(handle) \(tool)", createdAt: Store.now()))
        } catch {
            diagnostics("brahma mcp: failed to record toolUse event for @\(handle) \(tool): \(error)")
        }
    }

    func dispatch(_ name: String, _ args: [String: JSONValue]) throws -> String {
        do {
            let router = MessageRouter(store: store)
            switch name {
            case "post_message":
                let channel = try string(args, "channel"), text = try string(args, "text")
                let result = try router.postDetailed(companyId: companyId, channel: channel, from: .agent(agentId), text: text)
                var reply = "Posted to #\(Store.normalizeChannelName(channel))."
                if let refusal = result.broadcastRefusal { reply += " " + refusal }
                return reply
            case "send_dm":
                let to = try string(args, "to"), text = try string(args, "text")
                _ = try router.sendDM(companyId: companyId, from: .agent(agentId), to: to, text: text)
                return "Sent DM to @\(Self.handle(to))."
            case "read_channel":
                return try readChannel(try string(args, "channel"), limit: try limit(args))
            case "list_channels":
                let channels = try store.channels(companyId: companyId, memberId: agentId)
                return channels.isEmpty ? "No channels." : channels.map { "#\($0.name)" }.joined(separator: "\n")
            case "list_agents":
                let agents = try store.agents(companyId: companyId)
                let handles = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { f, _ in f })
                return agents.isEmpty ? "No agents." : agents.map { a in
                    var line = "@\(a.name) — \(a.role) — \(a.state.rawValue)"
                    if let m = a.managerId, let h = handles[m] { line += " — reports to @\(h)" }
                    return line
                }.joined(separator: "\n")
            case "create_channel":
                return try createChannel(name: try string(args, "name"), members: try stringArray(args, "members"))
            case "set_blocked":
                return try setBlocked(on: try string(args, "on"), reason: try string(args, "reason"), ask: try optionalString(args, "ask"))
            case "review":
                return try reviewTool(args)
            case "audit":
                return try auditTool(args)
            default:
                if let result = try callWork(name, args) { return result }
                if let result = try dispatchInbox(name, args) { return result }
                if let result = try dispatchSafety(name, args) { return result }
                throw ToolError(message: "unknown tool: \(name)")
            }
        } catch let e as ToolError {
            throw e
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        } catch let e as GitError {
            throw ToolError(message: "\(e)")
        } catch let e as RouterError {
            throw ToolError(message: Self.describe(e))
        } catch StoreError.invalidName {
            throw ToolError(message: "invalid name: use letters, digits, '-' or '_' (max 64 chars)")
        } catch StoreError.duplicateName {
            throw ToolError(message: "a channel with that name already exists")
        } catch {
            throw ToolError(message: "\(error)")
        }
    }

    // MARK: Tools

    private func readChannel(_ name: String, limit: Int) throws -> String {
        guard let channel = try store.channel(companyId: companyId, name: name) else {
            throw ToolError(message: "unknown channel: \(Store.normalizeChannelName(name))")
        }
        guard try store.members(channelId: channel.id).contains(agentId) else {
            throw ToolError(message: "you are not a member of #\(channel.name)")
        }
        let handles = Dictionary(try store.agents(companyId: companyId).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // JSON-encoded so a message body cannot forge another entry or sender.
        let entries: [JSONValue] = try store.messages(channelId: channel.id, limit: limit).map { m in
            .object(["sender": .string("@" + (m.senderId == "owner" ? "owner" : handles[m.senderId] ?? m.senderId)),
                     "text": .string(m.text), "at": .string(iso.string(from: m.createdAt))])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(JSONValue.array(entries)), as: UTF8.self)
    }

    private func createChannel(name: String, members handles: [String]) throws -> String {
        var ids = [agentId]
        for h in handles {
            let handle = Self.handle(h)
            guard let a = try store.agent(companyId: companyId, name: handle) else {
                throw ToolError(message: Self.describe(.unknownAgent(handle)))
            }
            if !ids.contains(a.id) { ids.append(a.id) }
        }
        let channel = try store.createChannel(companyId: companyId, name: name, members: ids)
        return "Created #\(channel.name) with \(ids.count) members."
    }

    private func setBlocked(on: String, reason: String, ask askRef: String?) throws -> String {
        let target = Self.handle(on)
        let reason = try store.redact(reason)
        let raw = on.trimmingCharacters(in: .whitespaces)
        if askRef != nil, target != "owner" { throw ToolError(message: "ask applies only when you are blocked on the owner") }
        if askRef == nil, !raw.hasPrefix("@"), raw.range(of: "^[A-Z0-9]{1,8}-[0-9]+$", options: .regularExpression) != nil {
            if let result = try setBlockedOnItem(key: raw) { return result }
        }
        // Target check and write share one transaction, so a teammate killed in between cannot be waited on.
        // Touch only this column so a concurrent orchestrator save is not clobbered.
        let linked: String? = try store.writer.write { [companyId, agentId] db in
            var linkedRef: String?
            let blocker: Blocker
            if target == "owner" {
                // The ask link is the engine's: resolved by ref inside this company and checked open, never read from the reason.
                var askId: String?
                if let askRef {
                    guard let ask = try Store.ask(db: db, companyId: companyId, ref: askRef) else {
                        throw ToolError(message: "no ask \(Store.flat(askRef, max: 20))")
                    }
                    guard ask.status.isPending else { throw ToolError(message: "\(ask.ref) is no longer open") }
                    askId = ask.id
                    linkedRef = ask.ref
                }
                blocker = .owner(reason: reason, askId: askId)
            } else {
                guard let other = try Agent.filter(Column("companyId") == companyId && Column("name") == target).fetchOne(db) else {
                    throw ToolError(message: Self.describe(.unknownAgent(target)))
                }
                guard other.id != agentId else { throw ToolError(message: "you cannot be blocked on yourself") }
                guard other.state != .killed else { throw ToolError(message: "@\(target) has been killed; you cannot wait on them") }
                blocker = .agent(other.id)
            }
            guard var me = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            me.requestedBlocker = blocker
            try me.update(db, columns: ["requestedBlocker"])
            return linkedRef
        }
        return "Marked blocked on @\(target)" + (linked.map { " waiting for \($0)" } ?? "") + "; this takes effect when your turn ends."
    }

    // MARK: Argument helpers

    func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let v = args[key], v != .null else { throw ToolError(message: "missing required argument: \(key)") }
        guard let s = v.stringValue else { throw ToolError(message: "argument \(key) must be a string") }
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError(message: "argument \(key) must not be empty")
        }
        return s
    }

    /// An optional string argument; absent, null or blank is nil.
    func optionalString(_ args: [String: JSONValue], _ key: String) throws -> String? {
        guard let v = args[key], v != .null else { return nil }
        guard let s = v.stringValue else { throw ToolError(message: "argument \(key) must be a string") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    func stringArray(_ args: [String: JSONValue], _ key: String) throws -> [String] {
        guard let v = args[key], v != .null else { throw ToolError(message: "missing required argument: \(key)") }
        guard let a = v.arrayValue else { throw ToolError(message: "argument \(key) must be an array of strings") }
        return try a.map {
            guard let s = $0.stringValue else { throw ToolError(message: "argument \(key) must be an array of strings") }
            return s
        }
    }

    private func limit(_ args: [String: JSONValue]) throws -> Int {
        guard let v = args["limit"], v != .null else { return 20 }
        guard let n = v.numberValue, n.isFinite else { throw ToolError(message: "argument limit must be a number") }
        return Int(min(max(n, 1), 100))
    }

    static func handle(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("@") { h.removeFirst() }
        return h.lowercased()
    }

    static func describe(_ e: RouterError) -> String {
        switch e {
        case .unknownChannel(let c): "unknown channel: \(c)"
        case .unknownAgent(let a): "unknown agent: @\(a)"
        case .notAMember: "you are not a member of that channel"
        case .invalidChannel(let c): "channel \(c) is not a direct message between the two parties"
        case .invalidSender: "invalid sender (you cannot message yourself, and killed agents cannot send)"
        }
    }
}
