import Foundation
import GRDB

/// How a search combines its words. `andThenOr` is ML's (every word, then any word when fewer than
/// `MemoryPolicy.orFallbackBelow` hits came back); Plan C Task C4a's global search runs `all` and `any` itself, so it decides
/// the fallback on the hits it keeps.
public enum MemoryMatch: Sendable {
    case andThenOr, all, any
}

/// Which text a search matches, ranks and counts on. `raw` is ML's index over the stored text (the owner's and the engine's
/// own callers). `visible` (Plan C Task C4a fix round 4, Ruling 57) is the vault-blanked shadow (`memoryShadowFts`): every
/// stored value the gate knows is blanked before anything is matched, so a value's tokens answer like random text. The
/// shadow is brought up to date with the gate's values before the search reads it.
public enum MemoryText: Sendable {
    case raw
    case visible(GlobalSearch.TextGate)
}

/// The company-memory index: one scoped full-text index over every source, read through the access engine. Every query is
/// bound to one company (`companyId = ?`); a ref of another company answers exactly like a missing one.
public struct MemoryIndex: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }

    // MARK: Search

    /// Up to `min(limit, MemoryPolicy.maxHits)` hits the reader may see, best first.
    ///
    /// 1. Load the reader's context and build the query expression (nothing searchable: no hits).
    /// 2. Full pass: `memoryFts MATCH <and>` over the company's live, unexpired docs; for an agent, prefiltered in SQL to the
    ///    classes its context could read (an optimization only: step 4 decides). Best `MemoryPolicy.candidateRows` by bm25.
    /// 3. Summary pass (an agent with reports): the same, matching titles only, over its reports' private docs.
    /// 4. Every row goes through `MemoryAccess.level`: `none` is dropped, `summary` loses its snippet, a tainted row loses its
    ///    snippet and its title.
    /// 5. Score `-bm25 × recency × weight`. Fewer than `MemoryPolicy.orFallbackBelow` hits: steps 2–4 again with OR, merged.
    /// 6. Score descending, then newest first.
    ///
    /// With `text: .visible(gate)` (C4a fix round 4, Ruling 57) every step reads the vault-blanked shadow instead
    /// (`MemoryShadow`, synced with the gate's values first): matching, bm25's statistics and the AND→OR decision see only
    /// what a reader sees. Only a doc the reader may read in full is matched on its body (one it may read in summary only is
    /// matched on its title, in step 3), no snippet is cut (callers cut theirs from the gated text), and every hit's shadow
    /// is checked against its doc as the gate blanks it now: a stale one blanks the company again and searches once more,
    /// then drops what is still stale (fail closed).
    public func search(companyId: String, scope: Reader, query: String, sources: Set<MemorySource>? = nil,
                       limit: Int = MemoryPolicy.defaultHits, now: Date, match: MemoryMatch = .andThenOr,
                       text: MemoryText = .raw) throws -> [MemoryHit] {
        guard case .visible(let gate) = text else {
            return try searchOnce(companyId: companyId, scope: scope, query: query, sources: sources, limit: limit, now: now,
                                  match: match, gate: nil, dropStale: false)
        }
        // The reader first (another company's agent is refused before anything is written), then the shadow brought current.
        _ = try ReaderContext.load(store: store, companyId: companyId, reader: scope)
        try MemoryShadow.sync(store: store, companyId: companyId, gate: gate)
        do {
            return try searchOnce(companyId: companyId, scope: scope, query: query, sources: sources, limit: limit, now: now,
                                  match: match, gate: gate, dropStale: false)
        } catch is MemoryShadow.Stale {
            try MemoryShadow.sync(store: store, companyId: companyId, gate: gate, force: true)
            return try searchOnce(companyId: companyId, scope: scope, query: query, sources: sources, limit: limit, now: now,
                                  match: match, gate: gate, dropStale: true)
        }
    }

    private func searchOnce(companyId: String, scope: Reader, query: String, sources: Set<MemorySource>?, limit: Int, now: Date,
                            match: MemoryMatch, gate: GlobalSearch.TextGate?, dropStale: Bool) throws -> [MemoryHit] {
        try store.writer.read { db in
            let ctx = try ReaderContext.load(db: db, catalog: store.catalog, companyId: companyId, reader: scope)
            guard let expr = MemoryQuery.expression(query) else { return [] }
            let activeNow = try Store.activeNow(db: db, companyId: companyId)
            let visible = gate != nil

            var hits: [Int64: MemoryHit] = [:]
            func merge(_ found: [MemoryHit]) {
                for hit in found where (hits[hit.docId]?.score ?? -.infinity) < hit.score { hits[hit.docId] = hit }
            }
            func passes(_ match: String) throws -> [MemoryHit] {
                var found = try rows(db: db, ctx: ctx, match: match, summaryPass: false, sources: sources, activeNow: activeNow, now: now,
                                     visible: visible)
                if case .agent = ctx.reader, !ctx.reportIds.isEmpty {
                    found += try rows(db: db, ctx: ctx, match: "{title} : (" + match + ")", summaryPass: true, sources: sources,
                                      activeNow: activeNow, now: now, visible: visible)
                }
                return found
            }
            switch match {
            case .andThenOr:
                merge(try passes(expr.and))
                if hits.count < MemoryPolicy.orFallbackBelow, expr.or != expr.and { merge(try passes(expr.or)) }
            case .all:
                merge(try passes(expr.and))
            case .any:
                merge(try passes(expr.or))
            }

            let sorted = hits.values.sorted { a, b in
                a.score != b.score ? a.score > b.score : a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.docId > b.docId
            }
            var out = Array(sorted.prefix(max(0, min(limit, MemoryPolicy.maxHits))))
            if let gate {
                // Every hit's shadow is its doc as the gate blanks it now; one that isn't was blanked for other values.
                var fresh: [MemoryHit] = []
                for hit in out {
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT d.title, d.body, s.title AS shadowTitle, s.body AS shadowBody FROM memoryDoc d
                        JOIN memoryShadow s ON s.docId = d.id WHERE d.companyId = ? AND d.id = ?
                        """, arguments: [companyId, hit.docId]) else { continue }
                    let current = MemoryShadow.blanked(row["title"], gate: gate) == row["shadowTitle"] as String
                        && MemoryShadow.blanked(row["body"], gate: gate) == row["shadowBody"] as String
                    if current { fresh.append(hit) } else if !dropStale { throw MemoryShadow.Stale() }
                }
                out = fresh
            }
            return out
        }
    }

    /// One pass over the index (`memoryFts`, or with `visible` the shadow's `memoryShadowFts`), filtered by the access engine.
    private func rows(db: Database, ctx: ReaderContext, match: String, summaryPass: Bool, sources: Set<MemorySource>?,
                      activeNow: Double, now: Date, visible: Bool) throws -> [MemoryHit] {
        let w = MemoryPolicy.bm25Weights
        var sql = visible ? """
            SELECT d.*, bm25(memoryShadowFts, \(w.title), \(w.body)) AS rank, NULL AS snip
            FROM memoryShadowFts JOIN memoryShadow s ON s.docId = memoryShadowFts.rowid
            JOIN memoryDoc d ON d.id = s.docId AND d.companyId = s.companyId
            WHERE memoryShadowFts MATCH ? AND d.companyId = ? AND d.removedAt IS NULL
              AND (d.expiresActive IS NULL OR d.expiresActive > ?)
            """ : """
            SELECT d.*, bm25(memoryFts, \(w.title), \(w.body)) AS rank,
                   snippet(memoryFts, 1, '', '', '…', \(MemoryPolicy.snippetTokens)) AS snip
            FROM memoryFts JOIN memoryDoc d ON d.id = memoryFts.rowid
            WHERE memoryFts MATCH ? AND d.companyId = ? AND d.removedAt IS NULL
              AND (d.expiresActive IS NULL OR d.expiresActive > ?)
            """
        var arguments: StatementArguments = [match, ctx.companyId, activeNow]
        if let sources {
            guard !sources.isEmpty else { return [] }
            sql += " AND d.source IN (\(placeholders(sources.count)))"
            arguments += StatementArguments(sources.map(\.rawValue).sorted())
        }
        if summaryPass {
            guard !ctx.reportIds.isEmpty else { return [] }
            sql += " AND d.accessKind = 'agent' AND d.accessId IN (\(placeholders(ctx.reportIds.count))) AND d.readerSet IS NULL"
            arguments += StatementArguments(ctx.reportIds.sorted())
        } else if case .agent = ctx.reader {
            let (clause, args) = prefilter(ctx)
            sql += " AND (\(clause))"
            arguments += args
        }
        sql += " ORDER BY rank LIMIT \(MemoryPolicy.candidateRows)"

        var hits: [MemoryHit] = []
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            guard let doc = StoredDoc(row: row) else { continue }
            let level = doc.level(for: ctx)
            guard level != .none else { continue }
            // Visible text: a body is matched only for a reader who may read it; a summary reader matches titles (step 3).
            if visible, !summaryPass, level != .full { continue }
            let rank: Double = row["rank"]
            let recency = MemoryPolicy.recency(now.timeIntervalSince(doc.lastTouched))
            var hit = doc.hit(level: level, score: -rank * recency * doc.weight)
            if level == .full, !doc.tainted, let snip: String = row["snip"] {
                hit.snippet = String(snip.prefix(MemoryPolicy.snippetChars))
            }
            hits.append(hit)
        }
        return hits
    }

    /// The SQL prefilter for an agent: the access classes its context could read at all, plus every row with a reader set
    /// (decided per row by the access engine). hr-perf and secret docs are never an agent's.
    private func prefilter(_ ctx: ReaderContext) -> (String, StatementArguments) {
        var clauses = ["d.accessKind = 'company'", "d.readerSet IS NOT NULL"]
        var arguments = StatementArguments()
        func list(_ kinds: [String], _ ids: Set<String>) {
            guard !ids.isEmpty else { return }
            let kindSQL = kinds.map { "'\($0)'" }.joined(separator: ", ")
            // A context too large to bind (a manager over thousands of items) widens to the whole class: still filtered below.
            if ids.count > 2000 {
                clauses.append("d.accessKind IN (\(kindSQL))")
            } else {
                clauses.append("(d.accessKind IN (\(kindSQL)) AND d.accessId IN (\(placeholders(ids.count))))")
                arguments += StatementArguments(ids.sorted())
            }
        }
        var teams = ctx.teamsBelow
        if let team = ctx.team { teams.insert(team) }
        list(["team"], teams)
        list(["role"], ctx.roles)
        list(["item"], ctx.itemIds)
        list(["channel", "dm"], ctx.channelIds)
        if let agentId = ctx.agentId { list(["agent"], [agentId]) }
        let clause = "(" + clauses.joined(separator: " OR ") + ") AND d.sensitivity NOT IN ('hr-perf', 'secret')"
        return (clause, arguments)
    }

    private func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ", ") }

    // MARK: Documents

    /// The doc `ref` names, as the reader may see it: only docs of the source the ref's form implies, with its canonical ref.
    /// The newest one the reader can read at `full` wins (a kb page ref without `#section` joins the page's readable
    /// sections, in order); otherwise the newest at `summary`, title only; otherwise nil, the same for unreadable and missing.
    ///
    /// A `kb:` ref is matched like a page is everywhere else (`kbRead`): its path is normalized (`HandbookPath`) and resolved
    /// to the stored page case-insensitively, and its `#section` to that section's slug.
    public func document(companyId: String, scope: Reader, ref: String, now: Date) throws -> MemoryDocument? {
        let (source, implied) = MemoryRefs.implied(ref)
        guard let source else {
            // An unknown form still checks the reader (another company's agent is refused) before answering "missing".
            _ = try ReaderContext.load(store: store, companyId: companyId, reader: scope)
            return nil
        }
        return try store.writer.read { db in
            let ctx = try ReaderContext.load(db: db, catalog: store.catalog, companyId: companyId, reader: scope)
            let activeNow = try Store.activeNow(db: db, companyId: companyId)
            var canonical = implied
            // A name that is not a page path, or no such page, is left as given (and answers like a missing ref).
            if source == .kb, let parsed = try? HandbookPath.normalizeRef(implied),
               let page = try Store.kbPage(db: db, companyId: companyId, path: parsed.path) {
                canonical = "kb:\(page.path)" + (parsed.section.map { "#" + KBMarkdown.slug($0) } ?? "")
            }
            let wholePage = source == .kb && !canonical.contains("#")
            var sql = """
                SELECT * FROM memoryDoc WHERE companyId = ? AND source = ? AND removedAt IS NULL
                  AND (expiresActive IS NULL OR expiresActive > ?)
                """
            var arguments: StatementArguments = [companyId, source.rawValue, activeNow]
            if wholePage {
                sql += " AND (ref = ? OR substr(ref, 1, length(?)) = ?)"
                arguments += [canonical, canonical + "#", canonical + "#"]
            } else {
                sql += " AND ref = ?"
                arguments += [canonical]
            }
            sql += " ORDER BY updatedAt DESC, id DESC"
            let docs = try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(StoredDoc.init(row:))
            let readable = docs.map { (doc: $0, level: $0.level(for: ctx)) }

            let full = readable.filter { $0.level == .full }.map(\.doc)
            if let newest = full.first {
                if wholePage {
                    // The page's readable sections in page order (then indexing order), under the page's title.
                    var order: [String: Int] = [:]
                    var pageTitle: String?
                    if let path = try? HandbookPath.normalize(canonical),
                       let page = try Store.kbPage(db: db, companyId: companyId, path: path) {
                        for (i, s) in KBMarkdown.sections(page.body, page: nil).enumerated() { order[s.slug] = i }
                        pageTitle = page.title
                    }
                    func position(_ doc: StoredDoc) -> Int { order[String(doc.ref.dropFirst(canonical.count + 1))] ?? Int.max }
                    let sections = full.sorted { (position($0), $0.id) < (position($1), $1.id) }
                    let text = sections.map(\.body).joined(separator: "\n\n")
                    var hit = newest.hit(level: .full, score: 0)
                    hit.ref = canonical
                    if let pageTitle { hit.title = pageTitle }
                    hit.tainted = sections.contains(where: \.tainted)
                    hit.taintReason = sections.first(where: \.tainted)?.taintReason
                    if hit.tainted { hit.title = "\(canonical) (untrusted)" }
                    return Self.bounded(hit: hit, text: text)
                }
                return Self.bounded(hit: newest.hit(level: .full, score: 0), text: newest.body)
            }
            if let summary = readable.first(where: { $0.level == .summary })?.doc {
                let hit = summary.hit(level: .summary, score: 0)
                return MemoryDocument(hit: hit, text: hit.title, truncated: false)
            }
            return nil
        }
    }

    /// At most `MemoryPolicy.readLines` lines and `MemoryPolicy.readBytes` bytes (cut on a character boundary).
    static func bounded(hit: MemoryHit, text: String) -> MemoryDocument {
        var out = text
        var truncated = false
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > MemoryPolicy.readLines {
            out = lines.prefix(MemoryPolicy.readLines).joined(separator: "\n")
            truncated = true
        }
        if out.utf8.count > MemoryPolicy.readBytes {
            var bytes = 0
            var cut = out.startIndex
            for index in out.indices {
                let size = out[index].utf8.count
                guard bytes + size <= MemoryPolicy.readBytes else { break }
                bytes += size
                cut = out.index(after: index)
            }
            out = String(out[..<cut])
            truncated = true
        }
        return MemoryDocument(hit: hit, text: out, truncated: truncated)
    }
}

/// A `memoryDoc` row as the access engine and the hit builder read it.
private struct StoredDoc {
    var id: Int64
    var ref: String
    var source: MemorySource
    var title: String
    var body: String
    var access: AccessClass
    var readerSet: Set<String>?
    var futureHolders: Bool
    var sensitivity: Sensitivity
    var restrictions: [Restriction]
    var tainted: Bool
    var taintReason: String?
    var weight: Double
    var authorId: String?
    var itemId: String?
    var updatedAt: Date
    var lastRecalledAt: Date?

    /// Nil for a row whose access fields do not parse: such a row is never shown (fail closed).
    init?(row: Row) {
        guard let access = AccessClass(kind: row["accessKind"], id: row["accessId"]),
              let sensitivity = Sensitivity(rawValue: row["sensitivity"])
        else { return nil }
        let decoder = JSONDecoder()
        if let raw: String = row["readerSet"] {
            guard let ids = try? decoder.decode([String].self, from: Data(raw.utf8)) else { return nil }
            readerSet = Set(ids)
        } else {
            readerSet = nil
        }
        guard let restrictions = try? decoder.decode([[String]].self, from: Data((row["restrictions"] as String).utf8)) else { return nil }
        self.restrictions = restrictions.map(Set.init)
        self.access = access
        self.sensitivity = sensitivity
        id = row["id"]; ref = row["ref"]; source = MemorySource(rawValue: row["source"]); title = row["title"]; body = row["body"]
        futureHolders = row["futureHolders"]; tainted = row["tainted"]; taintReason = row["taintReason"]; weight = row["weight"]
        authorId = row["authorId"]; itemId = row["itemId"]; updatedAt = row["updatedAt"]; lastRecalledAt = row["lastRecalledAt"]
    }

    var lastTouched: Date { max(updatedAt, lastRecalledAt ?? updatedAt) }

    func level(for ctx: ReaderContext) -> AccessLevel {
        MemoryAccess.level(ctx, access: access, sensitivity: sensitivity, readerSet: readerSet, restrictions: restrictions,
                           futureHolders: futureHolders)
    }

    /// No snippet; a tainted doc's own title is never shown.
    func hit(level: AccessLevel, score: Double) -> MemoryHit {
        MemoryHit(docId: id, ref: ref, source: source, title: tainted ? "\(ref) (untrusted)" : title, snippet: nil, level: level,
                  tainted: tainted, taintReason: taintReason, authorId: authorId, itemId: itemId, updatedAt: updatedAt, score: score)
    }
}
