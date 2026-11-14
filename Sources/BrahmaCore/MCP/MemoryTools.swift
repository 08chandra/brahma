import Foundation
import GRDB

/// Plan ML's memory tools: `search_memory`, `recall` and `remember`. Every result is filtered by the access engine
/// (`MemoryIndex`) before it is rendered; every agent-written string is flattened to one line or quoted as a `    | ` block,
/// and the whole reply goes through the redactor. A tainted doc is never shown by search; `recall(ref:)` of one marks this
/// session as having read outside content before it renders the text as an `UntrustedBlock`.
extension CompanyTools {
    /// The source names `search_memory` accepts; others are ignored.
    static let memorySources: [String: MemorySource] = Dictionary(uniqueKeysWithValues: [
        MemorySource.message, .item, .ask, .decision, .handoff, .retro, .kb, .resource, .memory,
    ].map { ($0.rawValue, $0) })

    static func memoryToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "search_memory", description: """
                Search company memory you can read — messages, items, asks, hand-offs, handbook, retros, resources and \
                remembered facts. Returns cited snippets.
                """, inputSchema: schema([
                    "query": prop("string", "Words to look for"),
                    "sources": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                        "description": .string("Only these: message, item, ask, decision, handoff, retro, kb, resource, memory")]),
                    "limit": prop("integer", "At most 10 (default 5)"),
                ], required: ["query"])),
            ToolSpec(name: "recall", description: """
                Your memory. Pass query to search remembered facts and your past work, or ref (mem:12, F-3, ENG-7, kb:Path, \
                A-4) to read one entry in full.
                """, inputSchema: schema([
                    "query": prop("string", "Words to look for"),
                    "ref": prop("string", "One ref to read"),
                ], required: [])),
            ToolSpec(name: "remember", description: """
                Save a durable fact for later turns. The same key updates it; a different fact under the same key is kept as \
                a contradiction.
                """, inputSchema: schema([
                    "fact": prop("string", "Up to 600 characters"),
                    "key": prop("string", "Optional, e.g. staging.port"),
                    "type": prop("string", "fact (default), preference, howto, person or decision"),
                    "scope": prop("string", "mine (default), item, team or company"),
                    "confidence": prop("number", "0 to 1 (default 0.7)"),
                    "ttl_days": prop("integer", "Forget after 1-90 active days"),
                ], required: ["fact"])),
        ]
    }

    /// Runs a memory tool, or returns nil when `name` is not one.
    func dispatchMemory(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        switch name {
        case "search_memory": return store.redactor.apply(try searchMemory(args))
        case "recall": return store.redactor.apply(try recall(args))
        case "remember": return store.redactor.apply(try remember(args))
        default: return nil
        }
    }

    // MARK: search_memory

    private func searchMemory(_ args: [String: JSONValue]) throws -> String {
        let query = try rawString(args, "query") ?? ""
        var limit = MemoryPolicy.defaultHits
        if let v = args["limit"], v != .null {
            guard let n = v.numberValue, n.isFinite else { throw ToolError(message: "argument limit must be a number") }
            limit = Int(min(max(n, 1), Double(MemoryPolicy.maxHits)))
        }
        var sources: Set<MemorySource>?
        if let v = args["sources"], v != .null {
            let known = Set(try stringArray(args, "sources").compactMap {
                Self.memorySources[$0.trimmingCharacters(in: .whitespaces).lowercased()]
            })
            sources = known.isEmpty ? nil : known
        }
        return try renderSearch(query: query, sources: sources, limit: limit, memoryLines: false)
    }

    /// Search and its rendering, shared by `search_memory` and `recall(query:)` (`memoryLines`: `mem:` lines with the fact).
    private func renderSearch(query: String, sources: Set<MemorySource>?, limit: Int, memoryLines: Bool) throws -> String {
        let shownQuery = Store.flat(query, max: 60)
        guard MemoryQuery.expression(query) != nil else { return "Search needs at least one word." }
        let now = Store.now()
        let hits = try MemoryIndex(store: store).search(companyId: companyId, scope: .agent(agentId), query: query,
                                                        sources: sources, limit: limit, now: now)
        guard !hits.isEmpty else { return "No results you can read for \"\(shownQuery)\"." }
        let labels = try MemoryLabels(store: store, companyId: companyId)
        let entries = memoryLines ? try memoryEntriesByRef(hits) : [:]
        var lines = ["\(hits.count) result(s) for \"\(shownQuery)\" (only what you can read):"]
        var read: [Int64] = []
        for (i, hit) in hits.enumerated() {
            let ref = Store.flat(hit.ref, max: 200)
            if hit.tainted {
                lines.append("\(i + 1). \(ref) · \(hit.source) (untrusted) — read it with recall(ref: \"\(ref)\"); that marks this session as having read outside content")
                continue
            }
            if memoryLines, let entry = entries[hit.ref] {
                var line = "\(i + 1). \(ref) · \(entry.type.rawValue) · confidence \(Self.confidenceText(entry.confidence)) · \(labels.date(hit.updatedAt))"
                if let old = entry.contradictsId, let number = entries.oldNumbers[old] { line += " · contradicts mem:\(number)" }
                lines.append(line)
                if hit.snippet != nil {
                    lines.append("    | " + Store.flat(entry.fact, max: MemoryPolicy.maxFactChars))
                    read.append(hit.docId)
                }
                continue
            }
            lines.append("\(i + 1). \(ref) · \(hit.source) · \(labels.author(hit.authorId)) · \(labels.date(hit.updatedAt)) — \(Store.flat(hit.title, max: MemoryPolicy.maxTitleChars))")
            if let snippet = hit.snippet {
                lines.append("    | " + Store.flat(snippet, max: MemoryPolicy.snippetChars))
                read.append(hit.docId)
            }
        }
        lines.append("Open one with recall(ref: \"<ref>\"), kb_read or show_work_item.")
        try store.recordRead(companyId: companyId, docIds: read, agentId: agentId, turnId: try runningTurnId(), via: .search, now: now)
        return lines.joined(separator: "\n")
    }

    /// The memory entries the hits cite (`mem:<n>`), and the numbers of the entries they contradict.
    private func memoryEntriesByRef(_ hits: [MemoryHit]) throws -> MemoryEntriesByRef {
        let numbers = hits.compactMap { hit -> Int? in
            guard hit.source == .memory, hit.ref.hasPrefix("mem:") else { return nil }
            return Int(hit.ref.dropFirst(4))
        }
        guard !numbers.isEmpty else { return [:] }
        return try store.writer.read { [companyId] db in
            let found = try MemoryEntry.fetchAll(db, sql: """
                SELECT * FROM memoryEntry WHERE companyId = ? AND number IN (\(numbers.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments([companyId]) + StatementArguments(numbers))
            var out = MemoryEntriesByRef(byRef: Dictionary(found.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a }))
            let olds = found.compactMap(\.contradictsId)
            if !olds.isEmpty {
                for row in try Row.fetchAll(db, sql: """
                    SELECT id, number FROM memoryEntry WHERE companyId = ? AND id IN (\(olds.map { _ in "?" }.joined(separator: ", ")))
                    """, arguments: StatementArguments([companyId]) + StatementArguments(olds)) {
                    out.oldNumbers[row["id"]] = row["number"]
                }
            }
            return out
        }
    }

    // MARK: recall

    private func recall(_ args: [String: JSONValue]) throws -> String {
        let query = try optionalString(args, "query"), ref = try optionalString(args, "ref")
        guard (query == nil) != (ref == nil) else { throw ToolError(message: "pass query or ref") }
        if let query {
            return try renderSearch(query: query, sources: [.memory], limit: MemoryPolicy.defaultHits, memoryLines: true)
        }
        let raw = ref ?? ""
        let now = Store.now()
        let notFound = "No memory \(Store.flat(MemoryRefs.implied(raw).canonical, max: 80)) you can read."
        guard let doc = try MemoryIndex(store: store).document(companyId: companyId, scope: .agent(agentId), ref: raw, now: now) else {
            return notFound
        }
        let shownRef = Store.flat(doc.hit.ref, max: 200)
        let out: String
        if doc.hit.tainted {
            // Taint first: the text is shown only once this session is marked as having read it (a failed mark refuses).
            try relayTaint("memory:\(doc.hit.ref)")
            let reason = doc.hit.taintReason ?? "outside content"
            var block = UntrustedBlock.render(source: "\(shownRef) (\(reason))", text: doc.text, maxLines: MemoryPolicy.readLines)
            if doc.truncated { block += "\n… (truncated)" }
            out = block
        } else {
            let labels = try MemoryLabels(store: store, companyId: companyId)
            var lines = ["\(shownRef) · \(doc.hit.source) · \(labels.author(doc.hit.authorId)) · \(labels.date(doc.hit.updatedAt))"]
            for line in doc.text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    | " + String(String.UnicodeScalarView(line.unicodeScalars.map {
                    CharacterSet.controlCharacters.contains($0) && $0 != "\t" ? " " : $0
                })))
            }
            if doc.truncated { lines.append("… (truncated)") }
            out = lines.joined(separator: "\n")
        }
        try store.markRecalled(companyId: companyId, docId: doc.hit.docId, now: now)
        try store.recordRead(companyId: companyId, docIds: [doc.hit.docId], agentId: agentId, turnId: try runningTurnId(),
                             via: .recall, now: now)
        return out
    }

    // MARK: remember

    private func remember(_ args: [String: JSONValue]) throws -> String {
        let fact = try rawString(args, "fact") ?? ""
        let key = try optionalString(args, "key")
        var type = MemoryEntryType.fact
        if let raw = try optionalString(args, "type") {
            guard let t = MemoryEntryType(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()), t != .episode else {
                throw ToolError(message: "type is one of fact, preference, howto, person or decision")
            }
            type = t
        }
        var scope = RememberScope.mine
        if let raw = try optionalString(args, "scope") {
            guard let s = RememberScope(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw ToolError(message: "scope is one of mine, item, team or company")
            }
            scope = s
        }
        var confidence = MemoryPolicy.defaultConfidence
        if let v = args["confidence"], v != .null {
            guard let n = v.numberValue else { throw ToolError(message: "confidence is between 0 and 1") }
            confidence = n
        }
        var ttlDays: Int?
        if let v = args["ttl_days"], v != .null {
            guard let n = v.numberValue, n.isFinite, n.rounded() == n, let days = Int(exactly: n) else {
                throw ToolError(message: "ttl_days is 1–90")
            }
            ttlDays = days
        }
        let known: [(name: String, value: String)]
        do { known = try store.knownSecretValues(companyId: companyId, vault: vault ?? UnavailableVault()) } catch {
            diagnostics("brahma mcp: could not read the stored secrets to check a remembered fact: \(error)")
            throw ToolError(message: "the fact could not be checked for secrets right now, so it was not saved; try again next turn")
        }
        let result = try store.remember(companyId: companyId, by: agentId, fact: fact, key: key, type: type, scope: scope,
                                        confidence: confidence, ttlDays: ttlDays, knownValues: known, paths: paths)
        switch result {
        case .created(let e): return "Remembered \(e.ref) (\(scope.rawValue))."
        case .confirmed(let e): return "Already remembered as \(e.ref); confirmed."
        case .contradicts(let new, let old):
            // A trusted session is not shown what a tainted one wrote: the old fact stays one recall (that taints) away.
            let quoted = old.tainted && !new.tainted
                ? "untrusted: read it with recall(ref: \"\(old.ref)\")" : "\"\(Store.flat(old.fact, max: 80))\""
            return "Remembered \(new.ref). It contradicts \(old.ref) (\(quoted)); both are kept and the newer ranks first."
        }
    }

    // MARK: Helpers

    /// A string argument as given (absent or null: nil); blank is allowed so the store's own refusal answers.
    func rawString(_ args: [String: JSONValue], _ key: String) throws -> String? {
        guard let v = args[key], v != .null else { return nil }
        guard let s = v.stringValue else { throw ToolError(message: "argument \(key) must be a string") }
        return s
    }

    /// The turn a read belongs to: this server's turn, else the agent's running one.
    func runningTurnId() throws -> String? {
        if let quotaTurnId { return quotaTurnId }
        return try store.writer.read { [agentId] db in try Store.runningTurnId(db: db, agentId: agentId) }
    }

    /// `0.7`, `1`, `0.85`: at most two decimals, no trailing zeros.
    static func confidenceText(_ c: Double) -> String {
        var s = String(format: "%.2f", c)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// The memory entries a list of hits cites, by ref, and the numbers of the entries they contradict (by id).
struct MemoryEntriesByRef: ExpressibleByDictionaryLiteral {
    var byRef: [String: MemoryEntry]
    var oldNumbers: [String: Int] = [:]

    init(byRef: [String: MemoryEntry]) { self.byRef = byRef }
    init(dictionaryLiteral elements: (String, MemoryEntry)...) { byRef = Dictionary(elements, uniquingKeysWith: { a, _ in a }) }

    subscript(ref: String) -> MemoryEntry? { byRef[ref] }
}

/// How a hit names its author and date: `@handle`, `owner` or `engine`; `yyyy-MM-dd` in the owner's time zone.
struct MemoryLabels {
    let handles: [String: String]
    let formatter: DateFormatter

    init(store: Store, companyId: String) throws {
        handles = Dictionary(try store.agents(companyId: companyId).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = store.ownerTimeZone()
        formatter.dateFormat = "yyyy-MM-dd"
    }

    func author(_ id: String?) -> String {
        switch id {
        case nil, "system"?: return "engine"
        case "owner"?: return "owner"
        case let id?: return "@" + Store.flat(handles[id] ?? "unknown", max: 64)
        }
    }

    func date(_ d: Date) -> String { formatter.string(from: d) }
}
