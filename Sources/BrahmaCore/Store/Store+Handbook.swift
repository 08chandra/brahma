import Foundation
import GRDB

/// The company handbook: pages with append-only revisions, links, per-section restriction locked by structure, the page
/// lease, taint, and the owner's operations. Every `kbPage` query is bound to one company (`companyId = ?`): another
/// company's page answers exactly like a missing one.
extension Store {
    // MARK: Read

    /// The page `path` names (an optional `kb:` prefix; a `#section` suffix stands for `section` when that is nil) as `reader`
    /// may see it, at `revision` (nil: the current one). Nil for a missing page **and** for one the reader cannot read at page
    /// level. Sections are filtered with `KBAccess`. An old revision is shown only to a reader who can read every current
    /// section (else the missing-revision answer), and is also filtered by its own markers and by the current restrictions of
    /// every slug restricted now. `tainted` is the read revision's flag. Backlinks list only links whose source page and
    /// section the reader can read. The text passes through the redactor. A revision the page does not have, or a section
    /// that is missing or hidden, is `WorkError.notFound` (the same answer for both).
    public func kbRead(companyId: String, reader: Reader, path: String, section: String? = nil,
                       revision: Int? = nil) throws -> KBView? {
        let ref = try HandbookPath.normalizeRef(path)
        let wanted = section.map { Store.flat($0, max: 200) }.flatMap { $0.isEmpty ? nil : $0 } ?? ref.section
        let view: KBView? = try writer.read { db in
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: reader)
            guard let page = try Self.kbPage(db: db, companyId: companyId, path: ref.path), KBAccess.canReadPage(page, ctx: ctx)
            else { return nil }
            let restriction = page.pageRestriction
            let currentSections = KBMarkdown.sections(page.body, page: restriction)
            let row: KBRevision?
            let old = revision.map { $0 != page.revision } ?? false
            if let revision {
                // History is for readers of the whole current page: an old revision's sections cannot be matched to today's
                // restrictions reliably (a section may have been renamed or restricted since), so anyone who cannot read
                // every current section sees no old revision at all, with the missing-revision answer.
                let missing = WorkError.notFound("kb:\(page.path) has no revision \(revision)")
                if old, !currentSections.allSatisfy({ KBAccess.canRead($0, ctx: ctx) }) { throw missing }
                guard let r = try KBRevision.filter(Column("pageId") == page.id && Column("number") == revision).fetchOne(db),
                      r.companyId == companyId
                else { throw missing }
                row = r
            } else {
                row = try KBRevision.filter(Column("pageId") == page.id && Column("number") == page.revision).fetchOne(db)
            }
            let body = row?.body ?? page.body
            // Every slug restricted now must be readable now too, whatever an old revision said.
            var restrictedNow: [String: KBSection] = [:]
            for s in currentSections where !s.restrictions.isEmpty { restrictedNow[s.slug] = s }
            let lines = KBMarkdown.lines(body)
            let located = KBMarkdown.located(body, page: restriction)
            func visible(_ loc: KBMarkdown.Located) -> Bool {
                KBAccess.canRead(loc.section, ctx: ctx) && (restrictedNow[loc.section.slug].map { KBAccess.canRead($0, ctx: ctx) } ?? true)
            }

            var text: String
            var hidden = 0
            var slugs: [String] = []
            if let wanted {
                let slug = KBMarkdown.slug(wanted)
                guard let loc = located.first(where: { $0.section.slug == slug }), visible(loc) else {
                    // Final wave B1 item 9: the asked-for section is never echoed (it may be agent text, a guessed value).
                    throw WorkError.notFound("kb:\(page.path) has no section by that name you can read")
                }
                text = lines[loc.lineRange].joined(separator: "\n")
                slugs = [loc.section.slug]
            } else {
                var shown: [String] = []
                for loc in located {
                    guard visible(loc) else { hidden += 1; continue }
                    shown += lines[loc.lineRange]
                    slugs.append(loc.section.slug)
                }
                text = shown.joined(separator: "\n")
                if hidden > 0 { text += "\n\n_\(hidden) restricted section(s) not shown._" }
            }
            // An old revision's text is read by a whole-page reader: its reads are of every current section doc.
            if old { slugs = currentSections.map(\.slug) }

            let backlinks = try Self.kbBacklinks(db: db, page: page, ctx: ctx)
            return KBView(page: page, revision: row?.number ?? page.revision, text: text, hiddenSections: hidden,
                          backlinks: backlinks, tainted: row?.tainted ?? page.tainted,
                          taintReason: row.map(\.taintReason) ?? page.taintReason, slugs: slugs,
                          revisionDate: row?.createdAt ?? page.updatedAt)
        }
        guard var view else { return nil }
        view.text = redactor.apply(view.text)
        // No field of a view carries what the reader may not see: the page's body is the filtered text.
        view.page.body = view.text
        return view
    }

    /// The paths of other pages linking to `page` from a section the reader can read, on a page it can read; sorted.
    static func kbBacklinks(db: Database, page: KBPage, ctx: ReaderContext) throws -> [String] {
        let links = try KBLink.fetchAll(db, sql: """
            SELECT * FROM kbLink WHERE companyId = ? AND toPath = ? AND fromPageId <> ?
            """, arguments: [page.companyId, page.path, page.id])
        var sources: [String: KBPage] = [:]
        var out = Set<String>()
        for link in links {
            if sources[link.fromPageId] == nil {
                sources[link.fromPageId] = try KBPage.filter(Column("id") == link.fromPageId && Column("companyId") == page.companyId)
                    .fetchOne(db)
            }
            guard let from = sources[link.fromPageId], KBAccess.canReadPage(from, ctx: ctx),
                  KBAccess.canRead(restrictions: link.restrictions.map(Set.init), ctx: ctx) else { continue }
            out.insert(from.path)
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The pages `reader` can read at page level, by path.
    public func kbPages(companyId: String, reader: Reader) throws -> [KBPageSummary] {
        try writer.read { db in
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: reader)
            return try KBPage.fetchAll(db, sql: "SELECT * FROM kbPage WHERE companyId = ? ORDER BY path COLLATE NOCASE",
                                       arguments: [companyId])
                .filter { KBAccess.canReadPage($0, ctx: ctx) }.map(KBPageSummary.init)
        }
    }

    /// The most recently changed pages `reader` can read, newest first.
    public func kbRecent(companyId: String, reader: Reader, limit: Int = 20) throws -> [KBPageSummary] {
        try writer.read { db in
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: reader)
            return Array(try KBPage.fetchAll(db, sql: "SELECT * FROM kbPage WHERE companyId = ? ORDER BY updatedAt DESC, path",
                                             arguments: [companyId])
                .filter { KBAccess.canReadPage($0, ctx: ctx) }.prefix(max(0, limit)).map(KBPageSummary.init))
        }
    }

    /// Every revision of a page, oldest first (the owner's view).
    public func kbRevisions(companyId: String, path: String) throws -> [KBRevision] {
        let normalized = try HandbookPath.normalize(path)
        return try writer.read { db in
            guard let page = try Self.kbPage(db: db, companyId: companyId, path: normalized) else {
                throw WorkError.notFound("no handbook page kb:\(normalized)")
            }
            return try KBRevision.filter(Column("pageId") == page.id && Column("companyId") == companyId)
                .order(Column("number")).fetchAll(db)
        }
    }

    /// The edit lease on a page of this company, if any.
    public func kbLease(companyId: String, pageId: String) throws -> KBLease? {
        try writer.read { db in try KBLease.filter(Column("pageId") == pageId && Column("companyId") == companyId).fetchOne(db) }
    }

    /// The page lease as the writer is told about it: the item's key and `HH:mm` (owner's zone) when it runs out if the company
    /// stays active.
    func kbLeaseDescription(companyId: String, pageId: String, now: Date = Store.now()) throws -> (itemKey: String, until: String)? {
        try writer.read { db in
            guard let lease = try KBLease.filter(Column("pageId") == pageId && Column("companyId") == companyId).fetchOne(db) else {
                return nil
            }
            return try Self.describe(db: db, lease: lease, now: now)
        }
    }

    private static func describe(db: Database, lease: KBLease, now: Date) throws -> (itemKey: String, until: String) {
        let active = try activeNow(db: db, companyId: lease.companyId)
        let key = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE id = ? AND companyId = ?",
                                      arguments: [lease.itemId, lease.companyId]) ?? "?"
        return (key, clockTime(db, now.addingTimeInterval(max(lease.expiresActive - active, 0))))
    }

    static func kbPage(db: Database, companyId: String, path: String) throws -> KBPage? {
        try KBPage.fetchOne(db, sql: "SELECT * FROM kbPage WHERE companyId = ? AND path = ? COLLATE NOCASE",
                            arguments: [companyId, path])
    }

    // MARK: Write

    static let kbSectionsHidden = "has sections you can't see; write one section at a time with section"

    /// Writes a page (creating it when missing) and returns it, its new revision and whether it was created. Every check
    /// runs before anything is written, in one transaction; a refusal writes nothing. For an agent, in this order:
    /// 1. the path normalizes (`HandbookPath`);
    /// 2. an engine-generated page (or path) → forbidden;
    /// 2b. an existing page the agent cannot read at page level, or a new path that differs only by case or Unicode
    ///     normalization from one → `forbidden("you can't write kb:<requested path>")`, before any item, lease or revision
    ///     check: one text for both, echoing only the normalized path asked for (never a stored one);
    /// 4. an item is required, and the agent must own or lease it;
    /// 5. another agent's unexpired page lease → conflict;
    /// 6. an existing page needs `baseRevision`, equal to its revision;
    /// 7. sections: a whole-page write needs every section readable; a section write names a readable section (a missing
    ///    one is appended as `## <section>`), its text is one section, and every section the writer cannot read comes out
    ///    unchanged in slug, level, restrictions and text; a new restriction marker needs the roles it names;
    /// 8. the body is at most `Handbook.maxBodyBytes`; 9. no secret (`SecretScan.textFindings`); 10. sources within
    ///    `Handbook.maxSources`/`maxSourceChars`; 11. status: `deprecated` is the owner's, other statuses the page owner's.
    ///
    /// The owner and the engine are exempt from 4–5, and need `baseRevision` only when they pass one. Then: the new body and
    /// revision with its diff summary, links recomputed per section, the section docs indexed (and docs of removed sections
    /// removed), taint (a tainted session taints the page and the revision; an untainted agent never clears it; the owner's
    /// whole-page write does), an activity line, and the lease taken (or dropped with `release`).
    @discardableResult
    public func kbWrite(companyId: String, by author: KBAuthor, path rawPath: String, body rawBody: String,
                        section rawSection: String? = nil, title rawTitle: String? = nil, itemId: String? = nil,
                        baseRevision: Int? = nil, summary: String? = nil, sources rawSources: [String]? = nil,
                        status: KBStatus? = nil, release: Bool = false, knownValues: [(name: String, value: String)],
                        now: Date = Store.now(), paths: BrahmaPaths? = nil) throws -> (page: KBPage, revision: Int, created: Bool) {
        let path = try HandbookPath.normalize(rawPath)
        // A path becomes file names and link targets that cannot be redacted (the mirror, the export), and refusals echo it:
        // a path that looks like it holds a secret is refused first, whoever writes, with the body's wording.
        // Each part, and the whole path once (a known value holding `/` spans parts).
        for segment in path.split(separator: "/").map(String.init) + [path] {
            if let f = SecretScan.textFindings(segment, knownValues: knownValues).first {
                throw WorkError.invalid("that text contains what looks like a secret (\(f.label), line \(f.line)); remove it")
            }
        }
        let home = paths?.home ?? dataHome
        let rawText = rawBody.replacingOccurrences(of: "\r\n", with: "\n")
        return try writer.write { db in
            // Who is writing, and what it may read.
            var handle = author.id
            if case .agent(let id) = author {
                handle = try resolveActor(db, .agent(id), companyId: companyId).handle
            } else {
                guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            }
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: author.reader)
            let existing = try Self.kbPage(db: db, companyId: companyId, path: path)
            let shownPath = existing?.path ?? path

            // 2, 2b.
            if author != .system, existing?.autoKind != nil || Handbook.isAutoPath(path) {
                throw WorkError.forbidden("kb:\(shownPath) is generated by the engine from live data; it updates itself")
            }
            if case .agent = author {
                let cannotWrite = WorkError.forbidden("you can't write kb:\(path)")
                if let existing {
                    if !KBAccess.canReadPage(existing, ctx: ctx) { throw cannotWrite }
                } else {
                    // A look-alike of a page the agent cannot read (`é` vs `É`, compatibility forms) is refused the same way.
                    let key = HandbookPath.foldKey(path)
                    for other in try KBPage.fetchAll(db, sql: "SELECT * FROM kbPage WHERE companyId = ?", arguments: [companyId])
                    where HandbookPath.foldKey(other.path) == key && !KBAccess.canReadPage(other, ctx: ctx) {
                        throw cannotWrite
                    }
                }
            }

            // 4, 5.
            let activeNow = try Self.activeNow(db: db, companyId: companyId)
            var leaseItem: WorkItem?
            if case .agent(let agentId) = author {
                guard let itemId else { throw WorkError.invalid("kb_write needs item: the work item this edit belongs to") }
                let holder = try String.fetchOne(db, sql: "SELECT agentId FROM workLease WHERE itemId = ?", arguments: [itemId])
                guard let item = try WorkItem.fetchOne(db, key: itemId), item.companyId == companyId,
                      item.ownerId == agentId || holder == agentId
                else { throw WorkError.forbidden("you can only write the handbook for items you own or lease") }
                leaseItem = item
                if let existing, let held = try KBLease.fetchOne(db, key: existing.id), held.agentId != agentId,
                   try !Self.kbLeaseExpired(db: db, held, activeNow: activeNow) {
                    let who = try Agent.fetchOne(db, key: held.agentId)?.name ?? "?"
                    let (key, until) = try Self.describe(db: db, lease: held, now: now)
                    throw WorkError.conflict("kb:\(shownPath) is being edited by @\(who) for \(key) until \(until)")
                }
            }

            // 6.
            if let existing {
                if case .agent = author, baseRevision == nil {
                    throw WorkError.invalid("pass base_revision (the revision kb_read showed you)")
                }
                if let baseRevision, baseRevision != existing.revision {
                    throw WorkError.conflict("kb:\(shownPath) changed since revision \(baseRevision) (now \(existing.revision)); kb_read it again and merge your edit")
                }
            }

            // 7. Structure, checked on the text as it will be stored.
            let supplied = try redact(rawText)
            let restriction = existing?.pageRestriction
            let oldBody = existing?.body ?? ""
            let oldSections = KBMarkdown.sections(oldBody, page: restriction)
            let hiddenOld = oldSections.filter { !KBAccess.canRead($0, ctx: ctx) }
            let sectionName = rawSection.map { Store.flat($0, max: 200) }.flatMap { $0.isEmpty ? nil : $0 }
            let newBody: String
            if let sectionName {
                let slug = KBMarkdown.slug(sectionName)
                let notOneSection = WorkError.invalid("a section edit must be one section: close every code fence and don't add headings at this level or above")
                if let target = oldSections.first(where: { $0.slug == slug }) {
                    guard KBAccess.canRead(target, ctx: ctx) else { throw WorkError.forbidden("kb:\(shownPath) \(Self.kbSectionsHidden)") }
                    // The lead holds no heading at all: through it a writer could otherwise add whole new sections.
                    guard KBMarkdown.isSingleSectionText(supplied, belowLevel: target.heading == nil ? 6 : target.level) else {
                        throw notOneSection
                    }
                    newBody = KBMarkdown.replacing(section: slug, in: oldBody, with: supplied)
                } else {
                    guard KBMarkdown.isSingleSectionText(supplied, belowLevel: 2) else { throw notOneSection }
                    let heading = "## " + (try redact(sectionName))
                    newBody = oldBody.isEmpty ? heading + "\n" + supplied
                        : oldBody + (oldBody.hasSuffix("\n") ? "" : "\n") + heading + "\n" + supplied
                }
            } else {
                guard hiddenOld.isEmpty else { throw WorkError.forbidden("kb:\(shownPath) \(Self.kbSectionsHidden)") }
                newBody = supplied
            }
            let newSections = KBMarkdown.sections(newBody, page: restriction)
            for h in hiddenOld where !newSections.contains(where: {
                $0.slug == h.slug && $0.level == h.level && $0.heading == h.heading && $0.restrictions == h.restrictions && $0.text == h.text
            }) {
                throw WorkError.forbidden("that edit would change sections you can't see")
            }
            if case .agent = author {
                let hiddenSlugs = Set(hiddenOld.map(\.slug))
                let oldMarkers = Dictionary(oldSections.map { ($0.slug, $0.marker) }, uniquingKeysWith: { a, _ in a })
                for s in newSections {
                    guard let marker = s.marker, !hiddenSlugs.contains(s.slug) else { continue }
                    if let old = oldMarkers[s.slug], old == marker { continue }
                    let allowed = marker.allSatisfy { $0 == "@executive" ? ctx.isExecutive : ctx.roles.contains($0) }
                    guard allowed else { throw WorkError.forbidden("you can't create a section restricted to roles you don't have") }
                }
            }

            // 8–11.
            guard newBody.utf8.count <= Handbook.maxBodyBytes else {
                throw WorkError.invalid("handbook pages are limited to 200 KB; split it into pages")
            }
            var title: String?
            if let rawTitle {
                let t = Store.flat(rawTitle, max: Int.max)
                guard t.count <= Handbook.maxTitle else { throw WorkError.invalid("handbook titles are up to 120 characters") }
                title = t.isEmpty ? nil : t
            }
            let flatSources = rawSources.map { $0.map { Store.flat($0, max: Int.max) }.filter { !$0.isEmpty } }
            for text in [rawText, rawTitle ?? "", summary ?? "", sectionName ?? ""] + (flatSources ?? []) {
                if let f = SecretScan.textFindings(text, knownValues: knownValues).first {
                    throw WorkError.invalid("that text contains what looks like a secret (\(f.label), line \(f.line)); remove it")
                }
            }
            if let flatSources, flatSources.count > Handbook.maxSources || flatSources.contains(where: { $0.count > Handbook.maxSourceChars }) {
                throw WorkError.invalid("sources: at most 20, each up to 300 characters")
            }
            if case .agent(let agentId) = author, let status {
                guard status != .deprecated else { throw WorkError.forbidden("only the owner can deprecate a page") }
                if let existing, existing.ownerId != agentId {
                    throw WorkError.forbidden("only the page's owner can change its status")
                }
            }

            // Write.
            var taint: (tainted: Bool, reason: String?) = (existing?.tainted ?? false, existing?.taintReason)
            switch author {
            case .agent(let agentId):
                if let source = try Self.currentTaint(db: db, agentId: agentId, home: home) {
                    taint = (true, "edited by a session that read \(source)")
                }
            case .owner:
                if sectionName == nil { taint = (false, nil) }
            case .system:
                break
            }
            var page = existing ?? KBPage(
                id: UUID().uuidString, companyId: companyId, path: path, title: HandbookPath.defaultTitle(of: path),
                section: HandbookPath.section(of: path), body: "", ownerId: author.id, status: .active, autoKind: nil,
                revision: 0, lastReviewed: nil, sources: [], restriction: nil, tainted: false, taintReason: nil, vouchedAt: nil,
                createdAt: now, updatedAt: now)
            if let title { page.title = try redact(title) }
            if let status { page.status = status }
            if let flatSources { page.sources = try flatSources.map { try redact($0) } }
            page.tainted = taint.tainted
            page.taintReason = taint.reason
            var turnId: String?
            if case .agent(let id) = author { turnId = try Self.runningTurnId(db: db, agentId: id) }
            let number = try commitKBRevision(db: db, page: &page, body: newBody, author: author, itemId: leaseItem?.id,
                                               turnId: turnId, summary: summary, rollbackOf: nil, insert: existing == nil, now: now)

            if case .agent(let agentId) = author, let leaseItem {
                if release {
                    try KBLease.deleteOne(db, key: page.id)
                } else {
                    try KBLease(pageId: page.id, companyId: companyId, agentId: agentId, itemId: leaseItem.id,
                                expiresActive: activeNow + KBLease.ttl).save(db)
                }
            }
            if author != .system {
                let who = author == .owner ? "owner" : "@\(handle)"
                try ActivityEvent(companyId: companyId, agentId: author.agentId, turnId: turnId, kind: .work,
                                  text: "\(who) edited kb:\(page.path) (rev \(number), \(KBMarkdown.diffSummary(old: oldBody, new: newBody)))",
                                  createdAt: now).insert(db)
            }
            return (page, number, existing == nil)
        }
    }

    /// Stores `body` as `page`'s next revision (inserting the page when `insert`), recomputes its links and indexes its
    /// sections. The page's other fields are the caller's. Returns the revision number.
    @discardableResult
    func commitKBRevision(db: Database, page: inout KBPage, body: String, author: KBAuthor, itemId: String?, turnId: String?,
                          summary: String?, rollbackOf: Int?, insert: Bool, now: Date) throws -> Int {
        let oldBody = insert ? "" : page.body
        page.body = body
        page.revision += 1
        page.updatedAt = now
        if insert { try page.insert(db) } else { try page.update(db) }
        var revision = KBRevision(
            id: nil, companyId: page.companyId, pageId: page.id, number: page.revision, title: page.title, body: body,
            status: page.status, authorId: author.id, itemId: itemId, turnId: turnId,
            summary: try summary.map { try redact(Store.flat($0, max: 500)) }.flatMap { $0.isEmpty ? nil : $0 },
            diffSummary: KBMarkdown.diffSummary(old: oldBody, new: body), tainted: page.tainted, taintReason: page.taintReason,
            rollbackOf: rollbackOf, createdAt: now)
        try revision.insert(db)
        try Self.recomputeKBLinks(db: db, page: page)
        try indexKBPage(db: db, page: page, now: now)
        return page.revision
    }

    /// `kbLink` for `page`: one row per (section, linked path), carrying the section's restrictions.
    static func recomputeKBLinks(db: Database, page: KBPage) throws {
        try db.execute(sql: "DELETE FROM kbLink WHERE fromPageId = ? AND companyId = ?", arguments: [page.id, page.companyId])
        let bySlug = Dictionary(KBMarkdown.sections(page.body, page: page.pageRestriction).map { ($0.slug, $0.restrictions) },
                                uniquingKeysWith: { a, _ in a })
        for link in KBMarkdown.links(page.body) {
            let restrictions = (bySlug[link.sectionSlug] ?? []).map { $0.sorted() }
            try KBLink(companyId: page.companyId, fromPageId: page.id, sectionSlug: link.sectionSlug, toPath: link.path,
                       restrictions: restrictions).insert(db, onConflict: .ignore)
        }
    }

    /// Every section of `page` as a `kb` memory doc (`<pageId>#<slug>`, ref `kb:<path>#<slug>`, title `<page title> › <heading>`),
    /// company access with the section's restrictions and the page's taint; an empty lead is not indexed. Docs of sections
    /// the page no longer has are removed.
    func indexKBPage(db: Database, page: KBPage, now: Date) throws {
        let lines = KBMarkdown.lines(page.body)
        let provenance: Provenance
        if page.tainted {
            provenance = .external("tainted-session:\(page.taintReason ?? "outside content")")
        } else {
            provenance = switch page.ownerId { case "owner": .owner; case "system": .engine; default: .agent(page.ownerId) }
        }
        var live: [String] = []
        for loc in KBMarkdown.located(page.body, page: page.pageRestriction) {
            let text = lines[loc.lineRange].joined(separator: "\n")
            if loc.section.heading == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let sourceId = "\(page.id)#\(loc.section.slug)"
            live.append(sourceId)
            try ingest(db: db, MemoryIngestDoc(
                companyId: page.companyId, source: .kb, sourceId: sourceId, ref: "kb:\(page.path)#\(loc.section.slug)",
                title: loc.section.heading.map { "\(page.title) › \($0)" } ?? page.title, body: text, access: .company,
                sensitivity: .normal, restrictions: loc.section.restrictions, provenance: provenance, tainted: page.tainted,
                taintReason: page.taintReason, authorId: page.ownerId, createdAt: page.createdAt), now: now)
        }
        let prefix = page.id + "#"
        var sql = """
            UPDATE memoryDoc SET removedAt = ? WHERE companyId = ? AND source = ? AND substr(sourceId, 1, ?) = ? AND removedAt IS NULL
            """
        var arguments: StatementArguments = [now, page.companyId, MemorySource.kb.rawValue, prefix.count, prefix]
        if !live.isEmpty {
            sql += " AND sourceId NOT IN (\(live.map { _ in "?" }.joined(separator: ", ")))"
            arguments += StatementArguments(live)
        }
        try db.execute(sql: sql, arguments: arguments)
    }

    // MARK: Owner operations

    /// The owner restores revision `to`: a new revision whose title and body are that revision's (`rollbackOf`), carrying that
    /// revision's taint.
    @discardableResult
    public func kbRollback(companyId: String, path: String, to number: Int, now: Date = Store.now()) throws -> (page: KBPage, revision: Int) {
        let normalized = try HandbookPath.normalize(path)
        return try writer.write { db in
            guard var page = try Self.kbPage(db: db, companyId: companyId, path: normalized) else {
                throw WorkError.notFound("no handbook page kb:\(normalized)")
            }
            guard let old = try KBRevision.filter(Column("pageId") == page.id && Column("number") == number).fetchOne(db) else {
                throw WorkError.notFound("kb:\(page.path) has no revision \(number)")
            }
            let oldBody = page.body
            page.title = old.title
            page.tainted = old.tainted
            page.taintReason = old.taintReason
            let n = try commitKBRevision(db: db, page: &page, body: old.body, author: .owner, itemId: nil, turnId: nil,
                                         summary: "rollback to revision \(number)", rollbackOf: number, insert: false, now: now)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .work,
                              text: "owner rolled back kb:\(page.path) to rev \(number) (rev \(n), \(KBMarkdown.diffSummary(old: oldBody, new: old.body)))",
                              createdAt: now).insert(db)
            return (page, n)
        }
    }

    /// The owner sets a page's status (`deprecated` is only ever set here).
    public func kbSetStatus(companyId: String, path: String, status: KBStatus, now: Date = Store.now()) throws {
        let normalized = try HandbookPath.normalize(path)
        try writer.write { db in
            guard var page = try Self.kbPage(db: db, companyId: companyId, path: normalized) else {
                throw WorkError.notFound("no handbook page kb:\(normalized)")
            }
            guard page.status != status else { return }
            page.status = status
            page.updatedAt = now
            try page.update(db, columns: ["status", "updatedAt"])
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .work,
                              text: "owner marked kb:\(page.path) \(status.rawValue)", createdAt: now).insert(db)
        }
    }

    /// The owner vouches for a page: its taint is cleared on the page, its current revision and its section docs.
    public func kbVouch(companyId: String, path: String, now: Date = Store.now(), owner: OwnerPrincipal) throws {
        try ProcessRole.refuseInAgentProcess()  // final wave B1 (C7b m-7): the owner principal, never from an agent process
        let normalized = try HandbookPath.normalize(path)
        try writer.write { db in
            guard var page = try Self.kbPage(db: db, companyId: companyId, path: normalized) else {
                throw WorkError.notFound("no handbook page kb:\(normalized)")
            }
            page.tainted = false
            page.taintReason = nil
            page.vouchedAt = now
            try page.update(db, columns: ["tainted", "taintReason", "vouchedAt"])
            try db.execute(sql: """
                UPDATE kbRevision SET tainted = 0, taintReason = NULL WHERE pageId = ? AND companyId = ? AND number = ?
                """, arguments: [page.id, companyId, page.revision])
            try indexKBPage(db: db, page: page, now: now)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .work,
                              text: "owner vouched for kb:\(page.path)", createdAt: now).insert(db)
        }
    }

    // MARK: Leases

    /// Drops every page lease taken for `itemId` (its work lease went, or it is done).
    public func releaseKBLeases(itemId: String) throws {
        try writer.write { db in try Self.releaseKBLeases(db: db, itemId: itemId) }
    }

    static func releaseKBLeases(db: Database, itemId: String) throws {
        try db.execute(sql: "DELETE FROM kbLease WHERE itemId = ?", arguments: [itemId])
    }

    /// Once per tick: page leases past their company-active expiry, or held by a killed agent, are dropped. Returns how many.
    @discardableResult
    public func reapKBLeases(now: Date) throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM kbLease WHERE agentId IN (SELECT id FROM agent WHERE state = 'killed')
                   OR expiresActive < COALESCE((SELECT activeSeconds FROM companyActivity ca WHERE ca.companyId = kbLease.companyId), 0)
                """)
            return db.changesCount
        }
    }

    static func kbLeaseExpired(db: Database, _ lease: KBLease, activeNow: Double) throws -> Bool {
        if try Agent.fetchOne(db, key: lease.agentId)?.state == .killed { return true }
        return lease.expiresActive < activeNow
    }

    // MARK: Skeleton

    /// Creates each of the company's pack sections (`IndustryPack.handbook`) that has no page yet, except the engine's auto
    /// pages: body `# <title>\n\n<summary>\n\n_No content yet. Add pages under <title>/ with kb_write._`, by the engine,
    /// active, `["@executive"]` when the section is restricted. Placeholders are not indexed: the first real edit indexes the
    /// page. Idempotent.
    public func ensureHandbookSkeleton(companyId: String, now: Date) throws {
        try writer.write { db in try ensureHandbookSkeleton(db: db, companyId: companyId, now: now) }
    }

    func ensureHandbookSkeleton(db: Database, companyId: String, now: Date) throws {
        guard let company = try Company.fetchOne(db, key: companyId) else { return }
        let sections = catalog.pack(company.packId)?.handbook ?? HandbookSection.softwareDefault
        for s in sections {
            // `IndustryPack.validate` refuses a pack whose section paths do not normalize.
            guard let path = try? HandbookPath.normalize(s.path), !Handbook.isAutoPath(path),
                  try Self.kbPage(db: db, companyId: companyId, path: path) == nil else { continue }
            let title = String(Store.flat(s.title, max: Int.max).prefix(Handbook.maxTitle))
            let body = "# \(title)\n\n\(Store.flat(s.summary, max: Int.max))\n\n_No content yet. Add pages under \(title)/ with kb_write._"
            let page = KBPage(
                id: UUID().uuidString, companyId: companyId, path: path, title: title.isEmpty ? path : title,
                section: HandbookPath.section(of: path), body: body, ownerId: KBAuthor.system.id, status: .active, autoKind: nil,
                revision: 1, lastReviewed: nil, sources: [], restriction: s.restricted ? ["@executive"] : nil, tainted: false,
                taintReason: nil, vouchedAt: nil, createdAt: now, updatedAt: now)
            try page.insert(db)
            var revision = KBRevision(
                id: nil, companyId: companyId, pageId: page.id, number: 1, title: page.title, body: body, status: .active,
                authorId: KBAuthor.system.id, itemId: nil, turnId: nil, summary: nil,
                diffSummary: KBMarkdown.diffSummary(old: "", new: body), tainted: false, taintReason: nil, rollbackOf: nil,
                createdAt: now)
            try revision.insert(db)
        }
    }
}

extension KBAuthor {
    /// The agent id for an activity line; nil for the owner and the engine.
    var agentId: String? { if case .agent(let id) = self { return id } else { return nil } }
}
