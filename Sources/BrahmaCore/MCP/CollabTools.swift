import Foundation

/// Plan C Task C3b's agent tools: `share` (refs to a teammate or channel, pinned and gated) and `open_ref` (the one read path
/// for shared content), plus the `attachments` argument of `post_message` and `send_dm`. Every secret-gate read point here
/// gets the injected vault's stored values (`Store.knownSecretValues`) and the archive reader (`archives`: in `brahma mcp`,
/// `EngineGateArchives`, which has the engine run the sandboxed helpers outside the turn's sandbox (Ruling 48); none refuses
/// archives and PDFs). Owner-only paths (`purge`, `viewOriginal`) have no tool.
extension CompanyTools {
    static func refsProp(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }

    static func collabToolSpecs() -> [ToolSpec] {
        let s = Self.self
        return [
            ToolSpec(name: "share", description: "Share refs (files, diffs, items, F-/AR- refs, msg:<id> quotes) with @handle or #channel. Pinned as they are now; nothing is pasted.",
                     inputSchema: s.schema(["refs": s.refsProp("1-6 refs, e.g. ENG-12:src/a.ts:40-88"),
                                            "to": s.prop("string", "@handle, @owner or #channel"),
                                            "note": s.prop("string", "Short note (max 600 chars)"),
                                            "reply_to": s.prop("string", "Reply in this message's thread (msg:<id>)")],
                                           required: ["refs", "to"])),
            ToolSpec(name: "open_ref", description: "Read a ref you can access (bounded; lines a-b). copy: true copies it into your lab's in/ folder.",
                     inputSchema: s.schema(["ref": s.prop("string", "The ref, e.g. ENG-12:src/a.ts@a1b2c3d or F-3"),
                                            "lines": s.prop("string", "Line window, e.g. 40-120"),
                                            "copy": s.prop("boolean", "Copy the whole content into your lab")],
                                           required: ["ref"])),
            // Plan C Task C4a: the Show bar's search (no LLM), with your access.
            ToolSpec(name: "search", description: "Search the company (items, messages, files, commits, kb, people…) for what you can read. One line per hit; open_ref to read.",
                     inputSchema: s.schema(["query": s.prop("string", "Words, a ref or a phrase, e.g. checkout blocked this week"),
                                            "kind": s.prop("string", "Only this kind: item, message, file, commit, kb, agent, run…"),
                                            "since": s.prop("string", "yyyy-mm-dd"),
                                            "by": s.prop("string", "@handle or @owner"),
                                            "limit": s.prop("integer", "At most 20 (default 10)")],
                                           required: ["query"])),
        ]
    }

    func dispatchCollab(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        try collabGeneric { try dispatchCollabTool(name, args) }
    }

    /// Fix round 1 (I-3): what reaches the agent from a collab tool is its own refusal or the generic text; an engine failure's
    /// detail goes to diagnostics only.
    func collabGeneric<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as ToolError { throw e } catch let e as WorkError { throw e } catch let e as RouterError {
            throw e
        } catch let e as ThreadError { throw e } catch {
            diagnostics("brahma mcp: a collab tool failed: \(error)")
            throw ToolError(message: Store.refUnavailable)
        }
    }

    private func dispatchCollabTool(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        switch name {
        case "share":
            let refs = try stringArray(args, "refs")
            let env = try collabEnvironment()
            return try store.share(companyId: companyId, by: agentId, refs: refs, to: try string(args, "to"), note: try optionalString(args, "note"),
                                   replyTo: try optionalString(args, "reply_to"), context: try refContext(), knownValues: env.known,
                                   paths: env.paths, now: Store.now(), archives: env.archives)
        case "open_ref":
            let ref = try string(args, "ref")
            var copy = false
            if let v = args["copy"], v != .null {
                guard case .bool(let b) = v else { throw ToolError(message: "argument copy must be true or false") }
                copy = b
            }
            let env = try collabEnvironment()
            return try store.openRef(companyId: companyId, reader: .agent(agentId), ref: ref, lines: try optionalString(args, "lines"),
                                     copy: copy, turnId: try runningTurnId(), context: try refContext(), knownValues: env.known,
                                     paths: env.paths, now: Store.now(), archives: env.archives).text
        case "search":
            return try searchTool(args)
        default:
            return nil
        }
    }

    // MARK: search (Plan C Task C4a)

    /// The engine's search caches for this process (`brahma mcp` serves one agent's turn).
    static let searchFiles = FileIndexCache()
    static let searchCommits = CommitIndexCache()
    static let searchDefaultLimit = 10

    /// `search {query, kind?, since?, by?, limit?}`: `ShowResolver` for this agent (never the owner's view), one line per hit
    /// `[<kind> <canonical> · <title> · <HH:mm or yyyy-mm-dd>]` with its snippet quoted on the next line (`    | `); nothing
    /// found: `"Nothing found in what you can read."`. No count of what the agent can't read is ever printed.
    func searchTool(_ args: [String: JSONValue]) throws -> String {
        let query = try string(args, "query")
        var forced = SearchFilters()
        let tz = store.ownerTimeZone()
        let now = Store.now()
        if let k = try optionalString(args, "kind") {
            guard let kind = SearchKind.parse(k.trimmingCharacters(in: .whitespaces)) else {
                throw ToolError(message: "kind must be one of: " + SearchKind.allCases.map(\.rawValue).joined(separator: ", "))
            }
            forced.kinds = [kind]
        }
        if let since = try optionalString(args, "since") {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            guard let start = SearchFilters.day(since.trimmingCharacters(in: .whitespaces), cal: cal) else {
                throw ToolError(message: "since must be a date like 2026-10-01")
            }
            forced.window = TimeWindow(start: start, end: now, label: "SINCE \(since.trimmingCharacters(in: .whitespaces))")
        }
        if let by = try optionalString(args, "by") {
            let h = by.trimmingCharacters(in: .whitespaces).lowercased()
            let handle = h.hasPrefix("@") ? String(h.dropFirst()) : h
            guard RefGrammar.isHandle(handle) else { throw ToolError(message: "by must be @handle or @owner") }
            forced.actor = handle
        }
        var limit = Self.searchDefaultLimit
        if let v = args["limit"], v != .null {
            guard let n = v.numberValue, n.isFinite else { throw ToolError(message: "argument limit must be a number") }
            limit = Int(min(max(n, 1), Double(GlobalSearch.toolLimit)))
        }
        let resolver = ShowResolver(store: store, files: Self.searchFiles, commits: Self.searchCommits)
        let result = try resolver.resolveNow(query, companyId: companyId, reader: .agent(agentId), forced: forced, now: now)
        return Self.searchLines(result, limit: limit, now: now, tz: tz)
    }

    /// The `search` tool's text for a result (also the concierge's, C4c).
    static func searchLines(_ result: ShowResult, limit: Int, now: Date, tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func stamp(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = tz
            f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "yyyy-MM-dd"
            return f.string(from: d)
        }
        var lines: [String] = []
        for hit in result.hits.filter({ !$0.inlineOnly }).prefix(limit) {
            let kind = hit.kind?.rawValue ?? hit.ref.kind.rawValue
            var line = "[\(kind) \(GlobalSearch.flatten(hit.ref.canonical, max: RefGrammar.maxLength)) · \(GlobalSearch.flatten(hit.title, max: SafeTitle.max))"
            if let at = hit.at { line += " · " + stamp(at) }
            lines.append(line + "]")
            if let snippet = hit.snippet.map({ GlobalSearch.flatten($0, max: GlobalSearch.snippetMax) }), !snippet.isEmpty {
                lines.append("    | " + snippet)
            }
        }
        return lines.isEmpty ? "Nothing found in what you can read." : lines.joined(separator: "\n")
    }

    /// `post_message` / `send_dm` with `attachments` (`Store.postWithAttachments`); `to` is `#channel` or `@handle`.
    func postAttachments(to: String, text: String, attachments: [String], replyTo: String?) throws -> PostResult {
        try collabGeneric {
            let env = try collabEnvironment()
            return try store.postWithAttachmentsDetailed(companyId: companyId, by: agentId, to: to, text: text, attachments: attachments,
                                                         replyTo: replyTo, context: try refContext(), knownValues: env.known, paths: env.paths,
                                                         now: Store.now(), archives: env.archives)
        }
    }

    /// The `attachments` argument: nil when absent, null or empty; at most `ShareLimits.maxRefs`.
    func attachmentList(_ args: [String: JSONValue]) throws -> [String]? {
        guard let v = args["attachments"], v != .null else { return nil }
        let list = try stringArray(args, "attachments")
        guard !list.isEmpty else { return nil }
        guard list.count <= ShareLimits.maxRefs else { throw ToolError(message: "attachments takes at most \(ShareLimits.maxRefs) refs") }
        return list
    }

    static func attachedSuffix(_ n: Int?) -> String {
        guard let n else { return "" }
        return " with \(n) attachment" + (n == 1 ? "" : "s")
    }

    /// The data home's places, the stored secrets' values (from the injected vault; one that can't be read refuses: fail
    /// closed) and the archive reader.
    func collabEnvironment() throws -> (paths: BrahmaPaths, known: [(name: String, value: String)], archives: any ArchiveReader) {
        guard let paths = paths ?? store.dataHome.map({ BrahmaPaths(home: $0, workspaces: BrahmaPaths.fromEnvironment().workspaces) }) else {
            throw ToolError(message: "shared content can't be read here")
        }
        let known: [(name: String, value: String)]
        do { known = try store.knownSecretValues(companyId: companyId, vault: vault ?? UnavailableVault()) } catch {
            diagnostics("brahma mcp: could not read the stored secrets to check shared content: \(error)")
            throw ToolError(message: "the content could not be checked for secrets right now, so nothing was shared or shown; try again next turn")
        }
        return (paths, known, archives ?? UnavailableArchiveReader())
    }

    /// What an agent's refs resolve against: the company's item key prefix, the agent as the actor.
    func refContext() throws -> RefContext {
        guard let company = try store.company(id: companyId) else { throw ToolError(message: "this agent is not active in the company") }
        return RefContext(companyId: companyId, keyPrefixes: [Store.keyPrefix(slug: company.slug)], actingAgentId: agentId)
    }
}
