import Foundation
import GRDB

/// Plan ML's handbook tools: `search_kb`, `kb_read` and `kb_write`. Reads are filtered per section by `KBAccess` before they
/// are rendered; page text is quoted as a `    | ` block (an `UntrustedBlock` for a tainted revision, after this session is
/// marked as having read it); every reply goes through the redactor.
extension CompanyTools {
    static func handbookToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "search_kb", description: "Search the company handbook. Returns cited sections you can read.",
                     inputSchema: schema([
                        "query": prop("string", "Words to look for"),
                        "limit": prop("integer", "At most 10 (default 5)"),
                     ], required: ["query"])),
            ToolSpec(name: "kb_read", description: "Read a handbook page, e.g. kb:Engineering/Deploy.",
                     inputSchema: schema([
                        "path": prop("string", "Page path"),
                        "section": prop("string", "One section only"),
                        "revision": prop("integer", "An older revision"),
                     ], required: ["path"])),
            ToolSpec(name: "kb_write", description: """
                Create or edit a handbook page for a work item you own or lease. Editing needs base_revision from kb_read; \
                pass section to replace one section.
                """, inputSchema: schema([
                    "path": prop("string", "Page path, e.g. Research/Pricing"),
                    "body": prop("string", "Markdown: the page, or the section's text"),
                    "item": prop("string", "Work item key"),
                    "base_revision": prop("integer", "Revision you read"),
                    "section": prop("string", "Section to replace or add"),
                    "title": prop("string", "Page title"),
                    "summary": prop("string", "What changed"),
                    "sources": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                        "description": .string("URLs and refs you used")]),
                    "status": prop("string", "draft or active"),
                    "release": prop("boolean", "Drop your edit lease"),
                ], required: ["path", "body", "item"])),
        ]
    }

    /// Runs a handbook tool, or returns nil when `name` is not one.
    func dispatchHandbook(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        switch name {
        case "search_kb": return store.redactor.apply(try searchKB(args))
        case "kb_read": return store.redactor.apply(try kbRead(args))
        case "kb_write": return store.redactor.apply(try kbWrite(args))
        default: return nil
        }
    }

    // MARK: search_kb

    private func searchKB(_ args: [String: JSONValue]) throws -> String {
        let query = try rawString(args, "query") ?? ""
        var limit = MemoryPolicy.defaultHits
        if let v = args["limit"], v != .null {
            guard let n = v.numberValue, n.isFinite else { throw ToolError(message: "argument limit must be a number") }
            limit = Int(min(max(n, 1), Double(MemoryPolicy.maxHits)))
        }
        // C4a fix round 4 (R4-2): matched, ranked and counted on the vault-blanked shadow; every field shown as its gated final
        // display string; a snippet only from a section holding no stored value; the query never echoed (`renderSearch`).
        guard MemoryQuery.expression(query) != nil else { return "Search needs at least one word." }
        let gate = try memorySearchGate()
        let now = Store.now()
        let hits = try MemoryIndex(store: store).search(companyId: companyId, scope: .agent(agentId), query: query, sources: [.kb],
                                                        limit: limit, now: now, text: .visible(gate))
        var shown: [(lines: [String], read: Int64?)] = []
        for hit in hits {
            guard let ref = gate.final(hit.ref, max: 200) else { continue }
            let n = shown.count + 1
            if hit.tainted {
                let line = "\(n). \(ref) (untrusted) — read it with kb_read; that marks this session as having read outside content"
                if !gate.holdsSecret(line) { shown.append(([line], nil)) }
                continue
            }
            let line = "\(n). \(ref) — \(gate.final(hit.title, max: MemoryPolicy.maxTitleChars) ?? ref)"
            guard !gate.holdsSecret(line) else { continue }
            var lines = [line]
            if hit.level == .full, let body = try memoryDocBody(hit.docId),
               let snippet = gate.snippet(body, around: query, max: MemoryPolicy.snippetChars), !gate.holdsSecret("    | " + snippet) {
                lines.append("    | " + snippet)
            }
            shown.append((lines, lines.count > 1 ? hit.docId : nil))
        }
        guard !shown.isEmpty else { return "No results you can read in the handbook." }
        var lines = ["\(shown.count) result(s) in the handbook (only what you can read):"]
        lines += shown.flatMap(\.lines)
        lines.append("Open one with kb_read.")
        try store.recordRead(companyId: companyId, docIds: shown.compactMap(\.read), agentId: agentId, turnId: try runningTurnId(),
                             via: .search, now: now)
        return lines.joined(separator: "\n")
    }

    // MARK: kb_read

    private func kbRead(_ args: [String: JSONValue]) throws -> String {
        let rawPath = try string(args, "path")
        let section = try optionalString(args, "section")
        let revision = try positiveInteger(args, "revision")
        guard let view = try store.kbRead(companyId: companyId, reader: .agent(agentId), path: rawPath, section: section,
                                          revision: revision) else {
            let shown = (try? HandbookPath.normalize(rawPath)) ?? Store.flat(rawPath, max: 80)
            return "No handbook page kb:\(shown) you can read. Try search_kb."
        }
        let page = view.page
        let labels = try MemoryLabels(store: store, companyId: companyId)
        let source = "kb:\(page.path)@\(view.revision)"
        var header = "kb:\(page.path) · rev \(view.revision) · \(page.status.rawValue) · owner \(labels.author(page.ownerId)) · updated \(labels.date(view.revisionDate))"
        if view.tainted { header += " · untrusted" }
        // The bound applies to what the agent receives: at most `readLines` quoted lines, and the whole reply (header,
        // quoted block and trailer) at most `readBytes` bytes.
        let truncationNote = "… (truncated; read one section with section)"
        let trailer = ["Backlinks: " + (view.backlinks.isEmpty ? "none" : view.backlinks.map { "kb:\($0)" }.joined(separator: ", ")),
                       "To edit: kb_write with base_revision: \(page.revision)."]
        let textLines = view.text.split(separator: "\n", omittingEmptySubsequences: false)
        var truncated = textLines.count > MemoryPolicy.readLines
        let shown = textLines.prefix(MemoryPolicy.readLines).joined(separator: "\n")
        var block: String
        if view.tainted {
            // Taint first: the text is shown only once this session is marked as having read it (a failed mark refuses).
            try relayTaint(source)
            block = UntrustedBlock.render(source: "\(source) (\(view.taintReason ?? "outside content"))", text: shown,
                                          maxLines: MemoryPolicy.readLines)
        } else {
            block = shown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                "    | " + String(String.UnicodeScalarView(line.unicodeScalars.map {
                    CharacterSet.controlCharacters.contains($0) && $0 != "\t" ? " " : $0
                }))
            }.joined(separator: "\n")
        }
        // Room for the header, the trailer and the truncation note, each on its own line.
        let budget = MemoryPolicy.readBytes - ([header, truncationNote] + trailer).joined(separator: "\n").utf8.count - 1
        let cut = Self.cutToBytes(block, max(budget, 0))
        block = cut.text
        truncated = truncated || cut.truncated
        var lines = [header, block]
        if truncated { lines.append(truncationNote) }
        lines += trailer

        let sourceIds = view.slugs.map { "\(page.id)#\($0)" }
        if !sourceIds.isEmpty {
            let docIds = try store.writer.read { [companyId] db in
                try Int64.fetchAll(db, sql: """
                    SELECT id FROM memoryDoc WHERE companyId = ? AND source = ? AND removedAt IS NULL
                      AND sourceId IN (\(sourceIds.map { _ in "?" }.joined(separator: ", ")))
                    """, arguments: StatementArguments([companyId, MemorySource.kb.rawValue]) + StatementArguments(sourceIds))
            }
            try store.recordRead(companyId: companyId, docIds: docIds, agentId: agentId, turnId: try runningTurnId(),
                                 via: .kbRead, now: Store.now())
        }
        return lines.joined(separator: "\n")
    }

    /// `text` cut to at most `bytes` UTF-8 bytes, on a character boundary.
    static func cutToBytes(_ text: String, _ bytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var used = 0
        var cut = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard used + size <= bytes else { break }
            used += size
            cut = text.index(after: index)
        }
        return (String(text[..<cut]), true)
    }

    // MARK: kb_write

    private func kbWrite(_ args: [String: JSONValue]) throws -> String {
        let path = try string(args, "path")
        guard let body = try rawString(args, "body") else { throw ToolError(message: "missing required argument: body") }
        // An unknown key stays unresolvable, so the store answers in its own order (a page the agent cannot read first).
        var itemId: String?
        if let key = try optionalString(args, "item") {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            itemId = try store.workItem(companyId: companyId, key: normalized)?.id ?? "unknown:\(normalized)"
        }
        let base = try positiveInteger(args, "base_revision")
        var status: KBStatus?
        if let raw = try optionalString(args, "status") {
            guard let s = KBStatus(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw ToolError(message: "status is draft or active")
            }
            status = s
        }
        var sources: [String]?
        if let v = args["sources"], v != .null { sources = try stringArray(args, "sources") }
        var release = false
        if let v = args["release"], v != .null {
            guard case .bool(let b) = v else { throw ToolError(message: "argument release must be true or false") }
            release = b
        }
        let known: [(name: String, value: String)]
        do { known = try store.knownSecretValues(companyId: companyId, vault: vault ?? UnavailableVault()) } catch {
            diagnostics("brahma mcp: could not read the stored secrets to check a handbook edit: \(error)")
            throw ToolError(message: "the page could not be checked for secrets right now, so it was not saved; try again next turn")
        }
        let result = try store.kbWrite(companyId: companyId, by: .agent(agentId), path: path, body: body,
                                       section: try optionalString(args, "section"), title: try optionalString(args, "title"),
                                       itemId: itemId, baseRevision: base, summary: try optionalString(args, "summary"),
                                       sources: sources, status: status, release: release, knownValues: known, paths: paths)
        let saved = "Saved kb:\(result.page.path) rev \(result.revision)."
        guard !release, let lease = try store.kbLeaseDescription(companyId: companyId, pageId: result.page.id) else {
            return saved + " Lease released."
        }
        return saved + " You hold its edit lease for \(lease.itemKey) until \(lease.until); pass release: true when done."
    }

    /// An optional whole number of at least 1 (absent or null: nil).
    private func positiveInteger(_ args: [String: JSONValue], _ key: String) throws -> Int? {
        guard let v = args[key], v != .null else { return nil }
        guard let n = v.numberValue, n.isFinite, n.rounded() == n, n >= 1, let i = Int(exactly: n) else {
            throw ToolError(message: "argument \(key) must be a whole number of at least 1")
        }
        return i
    }
}
