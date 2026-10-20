import Foundation
import GRDB

public struct ToolSpec: Encodable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
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

    public init(store: Store, companyId: String, agentId: String) {
        self.init(store: store, companyId: companyId, agentId: agentId, diagnostics: { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        })
    }

    init(store: Store, companyId: String, agentId: String, diagnostics: @escaping @Sendable (String) -> Void) {
        self.store = store; self.companyId = companyId; self.agentId = agentId; self.diagnostics = diagnostics
    }

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map { .string($0) })])
    }
    private static func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    public func specs() -> [ToolSpec] {
        let s = Self.self
        let handles: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                          "description": .string("Teammate handles")])
        return [
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
            ToolSpec(name: "set_blocked", description: "Declare you cannot continue until someone answers. Takes effect when your turn ends.",
                     inputSchema: s.schema(["on": s.prop("string", "Who you are waiting on: @handle or owner"),
                                            "reason": s.prop("string", "What you need")], required: ["on", "reason"])),
        ]
    }

    /// Runs a tool and returns its text result. Appends one `toolUse` event whether it succeeds or fails.
    public func call(name: String, arguments: [String: JSONValue]) throws -> String {
        defer { logUse(name) }
        // Validate the caller on every call: it may have been killed or removed since the server started.
        guard let me = try? store.agent(id: agentId), me.companyId == companyId, me.state != .killed else {
            throw ToolError(message: "this agent is not active in the company")
        }
        return try dispatch(name, arguments)
    }

    private func logUse(_ tool: String) {
        let handle = (try? store.agent(id: agentId))??.name ?? agentId
        do {
            try store.appendEvent(ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .toolUse,
                                                text: "@\(handle) \(tool)", createdAt: Store.now()))
        } catch {
            diagnostics("agentco mcp: failed to record toolUse event for @\(handle) \(tool): \(error)")
        }
    }

    private func dispatch(_ name: String, _ args: [String: JSONValue]) throws -> String {
        do {
            let router = MessageRouter(store: store)
            switch name {
            case "post_message":
                let channel = try string(args, "channel"), text = try string(args, "text")
                _ = try router.post(companyId: companyId, channel: channel, from: .agent(agentId), text: text)
                return "Posted to #\(Store.normalizeChannelName(channel))."
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
                return agents.isEmpty ? "No agents." : agents.map { "@\($0.name) — \($0.role) — \($0.state.rawValue)" }.joined(separator: "\n")
            case "create_channel":
                return try createChannel(name: try string(args, "name"), members: try stringArray(args, "members"))
            case "set_blocked":
                return try setBlocked(on: try string(args, "on"), reason: try string(args, "reason"))
            default:
                throw ToolError(message: "unknown tool: \(name)")
            }
        } catch let e as ToolError {
            throw e
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

    private func setBlocked(on: String, reason: String) throws -> String {
        let target = Self.handle(on)
        // Target check and write share one transaction, so a teammate killed in between cannot be waited on.
        // Touch only this column so a concurrent orchestrator save is not clobbered.
        try store.writer.write { [companyId, agentId] db in
            let blocker: Blocker
            if target == "owner" {
                blocker = .owner(reason: reason)
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
        }
        return "Marked blocked on @\(target); this takes effect when your turn ends."
    }

    // MARK: Argument helpers

    private func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let v = args[key], v != .null else { throw ToolError(message: "missing required argument: \(key)") }
        guard let s = v.stringValue else { throw ToolError(message: "argument \(key) must be a string") }
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError(message: "argument \(key) must not be empty")
        }
        return s
    }

    private func stringArray(_ args: [String: JSONValue], _ key: String) throws -> [String] {
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

    private static func handle(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("@") { h.removeFirst() }
        return h.lowercased()
    }

    private static func describe(_ e: RouterError) -> String {
        switch e {
        case .unknownChannel(let c): "unknown channel: \(c)"
        case .unknownAgent(let a): "unknown agent: @\(a)"
        case .notAMember: "you are not a member of that channel"
        case .invalidChannel(let c): "channel \(c) is not a direct message between the two parties"
        case .invalidSender: "invalid sender (you cannot message yourself, and killed agents cannot send)"
        }
    }
}
