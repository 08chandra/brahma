import Foundation
import GRDB

/// Plan C Task C5b: the inline review limits (global constraints, "Inline review").
public enum DiffReviewLimits {
    /// Hunk lines quoted into the holder's DM.
    public static let quoteLines = 20
    /// Characters kept of each quoted line.
    public static let quoteLineChars = 200
    /// The owner's comment text.
    public static let maxText = 2000
    /// A comment relocates to the line whose text hashes to its `lineHash` within this many lines of where it was.
    public static let reanchorWindow = 50
    static let maxPath = 512
    static let maxHunkHeader = 200
}

/// A row of migration `vC-changes` (+ `vC-changes-quote`): one inline owner comment (or revert request) on an item's diff.
public struct DiffComment: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "diffComment"
    public static let comment = "comment"
    public static let revertRequest = "revertRequest"

    public var id: String
    public var companyId: String
    public var itemId: String
    /// `comment` or `revertRequest`.
    public var kind: String
    /// The file as the snapshot shows it (its display form).
    public var path: String
    /// `old` or `new`.
    public var side: String
    public var line: Int
    /// `StableHash.fnv1a64` of the anchored line's text (re-anchoring).
    public var lineHash: String
    /// `@@ -a,b +c,d @@` (numbers only: never a line of the file).
    public var hunkHeader: String
    /// The compare's canonical ref (`ENG-1:diff@worktree`, `…?vs=head`, `ENG-1:diff@r1..worktree`).
    public var compare: String
    public var baseSha: String?
    /// The owner's text (a revert request's note, possibly empty).
    public var text: String
    /// The `commented` item event that carries the owner's text (no diff text).
    public var eventId: String?
    public var createdAt: Date
    public var resolvedAt: Date?
    /// Fix round 1: the quoted hunk (redacted, sanitized), read only under the live worktree rule.
    public var quote: String? = nil
    /// The quoted live text was tainted when the comment was made.
    public var tainted: Bool = false
    /// The owner's DM to the holder that carries the quote.
    public var messageId: String? = nil

    public init(id: String = UUID().uuidString, companyId: String, itemId: String, kind: String, path: String, side: String, line: Int,
                lineHash: String, hunkHeader: String, compare: String, baseSha: String?, text: String, eventId: String?, createdAt: Date,
                resolvedAt: Date? = nil, quote: String? = nil, tainted: Bool = false, messageId: String? = nil) {
        self.id = id; self.companyId = companyId; self.itemId = itemId; self.kind = kind; self.path = path; self.side = side; self.line = line
        self.lineHash = lineHash; self.hunkHeader = hunkHeader; self.compare = compare; self.baseSha = baseSha; self.text = text
        self.eventId = eventId; self.createdAt = createdAt; self.resolvedAt = resolvedAt; self.quote = quote; self.tainted = tainted
        self.messageId = messageId
    }
}

/// Where a comment sits in a diff, as the app's diff model names it.
public struct DiffAnchor: Hashable, Sendable, Codable {
    /// The file's path as the snapshot shows it.
    public var path: String
    /// `old` or `new`.
    public var side: String
    public var line: Int
    public var hunkHeader: String
    /// The anchored line's text as shown (without its `+`/`-`/space marker).
    public var lineText: String

    public init(path: String, side: String, line: Int, hunkHeader: String, lineText: String) {
        self.path = path; self.side = side; self.line = line; self.hunkHeader = hunkHeader; self.lineText = lineText
    }
}

extension Store {
    /// The owner's inline comment on `anchor` of the item's diff (the app's path, never a tool). Writes a `diffComment` row, an
    /// owner item comment through 3a's event path, a waking `reviewComment` item event for the lease holder (else the
    /// assignee), and an owner DM to that agent with the quoted hunk:
    ///
    ///     Owner review comment on "<path>":<line> (<compare canonical> @<base sha7>):
    ///         | @@ -a,b +c,d @@
    ///         | <up to 20 hunk lines around the line, redacted, invisible characters as ⟦U+XXXX⟧, each cut to 200 chars>
    ///     <owner text>
    ///
    /// Fix round 1 (C5b-1): the item event every item reader sees carries the owner's text and the compare only — no path,
    /// hunk or line of the live diff; those go to the live reader set alone (the DM, and `diffComments` under the live rule).
    /// (I-1) The path must be one of the diff's files and prints as a JSON literal; the hunk header is regenerated from its
    /// numbers. (I-2) The quote's taint (`snapshot.tainted`) is carried onto the row, the DM and the events. Every text is
    /// redacted, then gated as the final string (a stored value in the owner's own text or in the quote refuses the comment).
    ///
    /// Ruling C6-3 (C6b): an owner-only API — it takes the minted `OwnerPrincipal`, so no tool handler or turn can call it.
    @discardableResult
    public func addDiffComment(companyId: String, key: String, compare: CompareMode, anchor: DiffAnchor, text: String,
                               knownValues: [(name: String, value: String)], now: Date, owner: OwnerPrincipal) throws -> DiffComment {
        _ = try requireOwner(owner)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw WorkError.invalid("the comment is empty") }
        return try writeDiffComment(companyId: companyId, key: key, compare: compare, anchor: anchor, kind: DiffComment.comment, text: body,
                                    knownValues: knownValues, now: now)
    }

    /// The same path with `kind = revertRequest`; the DM's first line is `Owner asks you to revert this hunk in "<path>"
    /// (<hunk header>):`. The engine never writes to the worktree, its index or the item branch for it: no `checkout`,
    /// `apply`, `restore`, `reset` or file write is ever issued (the holder does the revert in its turn).
    @discardableResult
    public func requestHunkRevert(companyId: String, key: String, compare: CompareMode, anchor: DiffAnchor, note: String?,
                                  knownValues: [(name: String, value: String)], now: Date, owner: OwnerPrincipal) throws -> DiffComment {
        _ = try requireOwner(owner)
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try writeDiffComment(companyId: companyId, key: key, compare: compare, anchor: anchor, kind: DiffComment.revertRequest, text: text,
                                    knownValues: knownValues, now: now)
    }

    private func writeDiffComment(companyId: String, key: String, compare: CompareMode, anchor: DiffAnchor, kind: String, text: String,
                                  knownValues: [(name: String, value: String)], now: Date) throws -> DiffComment {
        guard text.count <= DiffReviewLimits.maxText else { throw WorkError.invalid("the comment is longer than \(DiffReviewLimits.maxText) characters") }
        guard !anchor.path.isEmpty, anchor.path.count <= DiffReviewLimits.maxPath, anchor.side == "old" || anchor.side == "new", anchor.line >= 1,
              anchor.hunkHeader.count <= DiffReviewLimits.maxHunkHeader, let header = DiffAnchoring.headerRange(anchor.hunkHeader)
        else { throw WorkError.invalid("the anchor is not a diff position") }
        guard let item = try writer.read({ db in try RefAccess.item(db, companyId, key) }) else { throw WorkError.notFound(Self.refUnavailable) }
        // The snapshot as the owner sees it (redacted): the quote is cut from it. The anchor names the shown path; the hunk is
        // found under the path as the patch spells it.
        try checkChangesAccess(companyId: companyId, key: key, compare: compare, reader: .owner)
        let raw = try changesRaw(companyId: companyId, key: key, compare: compare)
        let snapshot = Self.finishChanges(raw, knownValues: knownValues, now: now)
        guard let index = snapshot.files.firstIndex(where: { $0.path == anchor.path }), index < raw.files.count else {
            throw WorkError.invalid("the anchor's file is not in the diff")
        }
        let rawPath = raw.files[index].path
        guard let hunk = DiffAnchoring.hunk(in: snapshot.patch, path: rawPath, header: header) else {
            throw WorkError.invalid("the anchor's hunk is not in the diff")
        }
        guard let literal = PasteableRef.literal(anchor.path) else { throw WorkError.invalid("the anchor is not a diff position") }
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        guard !gate.holdsSecret(text) else { throw WorkError.invalid("the comment holds a stored secret's value; remove it before posting") }
        let compareRef = compare.ref(key: key)
        let compareCanonical = compareRef.canonical
        let at = "\(compareCanonical) @\(snapshot.base.prefix(7))"
        let quote = DiffQuote.lines(hunk, anchor: anchor)
        // The holder's DM (the live reader set): the brief's form.
        var dm = [kind == DiffComment.comment ? "Owner review comment on \(literal):\(anchor.line) (\(at)):"
                  : "Owner asks you to revert this hunk in \(literal) (\(header)):", "    | " + header]
        dm += quote.map { "    | " + $0 }
        if !text.isEmpty { dm.append(text) }
        // The item event (every item reader): the owner's text and the compare, nothing of the diff.
        var event = [kind == DiffComment.comment ? "Owner review comment on \(item.key) changes (\(at)):" : "Owner asks you to revert a hunk in \(item.key) changes (\(at)):"]
        if !text.isEmpty { event.append(text) }
        // Redacted, then gated as the final strings (Ruling 55): nothing changes them after this check.
        let dmBody = try redact(dm.joined(separator: "\n")), eventBody = try redact(event.joined(separator: "\n"))
        let quoteText = try redact(quote.joined(separator: "\n"))
        guard !gate.holdsSecret(dmBody), !gate.holdsSecret(eventBody), !gate.holdsSecret(quoteText) else {
            throw WorkError.invalid("the comment would quote a stored secret's value; it was not posted")
        }
        let summary = kind == DiffComment.comment ? "owner review comment on the live changes" : "owner asks to revert a hunk in the live changes"
        let taint: Bool? = snapshot.tainted ? true : nil
        let router = MessageRouter(store: self)
        return try writer.write { db in
            let commented = try recordItemEvent(db: db, item: item, actor: "owner", kind: .commented, text: eventBody, taintedOverride: taint, now: now)
            // Whoever holds the work is woken: the lease holder, else the assignee. The quote goes to that agent alone.
            let target = try Self.leaseHolderId(db: db, itemId: item.id) ?? item.ownerId
            try recordItemEvent(db: db, item: item, actor: "owner", kind: .reviewComment, text: summary,
                                alsoNotify: target.map { [$0] } ?? [], alsoNotifyRole: .holder, onlyAlsoNotify: true, taintedOverride: taint, now: now)
            var messageId: String?
            if let target, let handle = try RefAccess.handle(db, companyId, target) {
                // R1-1: the quoted lines and the path are file text; they name no recipient and broadcast nothing.
                let message = try router.sendDM(db: db, companyId: companyId, from: .owner, to: handle, text: dmBody, now: now, parseMentions: false)
                messageId = message.id
                if snapshot.tainted {
                    try db.execute(sql: "UPDATE message SET taintedOrigin = 1, fromTaintedSession = 1, taintSource = ? WHERE id = ? AND companyId = ?",
                                   arguments: ["ref:\(compareCanonical)", message.id, companyId])
                }
            }
            let row = DiffComment(companyId: companyId, itemId: item.id, kind: kind, path: anchor.path, side: anchor.side, line: anchor.line,
                                  lineHash: StableHash.fnv1a64(anchor.lineText), hunkHeader: header, compare: compareCanonical,
                                  baseSha: snapshot.base, text: text, eventId: commented.id.map(String.init), createdAt: now,
                                  quote: quoteText, tainted: snapshot.tainted, messageId: messageId)
            try row.insert(db)
            return row
        }
    }

    /// The item's diff comments for `reader`: those whose compare the reader may read in full (the live worktree rule, through
    /// `RefAccess`; the owner reads all), each agent-visible field gated as the final string. A reader who can't read the item
    /// is refused.
    public func diffComments(companyId: String, key: String, reader: Reader, knownValues: [(name: String, value: String)]) throws -> [DiffComment] {
        guard let company = try company(id: companyId) else { throw WorkError.notFound(Self.refUnavailable) }
        let context = RefContext(companyId: companyId, keyPrefixes: [Self.keyPrefix(slug: company.slug)])
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        let rows: [DiffComment] = try writer.read { db in
            guard case .allowed = try RefAccess.canRead(reader, WorkRef(kind: .item, id: key), companyId: companyId, db: db, catalog: catalog) else {
                throw WorkError.notFound(Self.refUnavailable)
            }
            let all = try DiffComment.fetchAll(db, sql: """
                SELECT diffComment.* FROM diffComment JOIN workItem ON workItem.id = diffComment.itemId
                WHERE diffComment.companyId = ? AND workItem.companyId = ? AND workItem.key = ? ORDER BY diffComment.createdAt, diffComment.rowid
                """, arguments: [companyId, companyId, key])
            return try all.filter { row in
                guard let ref = WorkRef.parse(row.compare, context: context) else { return false }
                guard case .allowed = try RefAccess.canRead(reader, ref, companyId: companyId, db: db, catalog: catalog) else { return false }
                return true
            }
        }
        return rows.map { row in
            var r = row
            r.path = gate.final(row.path, max: DiffReviewLimits.maxPath) ?? Self.withheldPath
            r.hunkHeader = DiffAnchoring.headerRange(row.hunkHeader) ?? "@@"
            r.text = gate.final(row.text, max: DiffReviewLimits.maxText) ?? ShowLimits.withheldNote
            if let q = row.quote { r.quote = gate.holdsSecret(q) ? nil : q }
            return r
        }
    }

    /// Marks the comment resolved (owner; Ruling C6-3: takes the minted principal).
    public func resolveDiffComment(companyId: String, id: String, now: Date, owner: OwnerPrincipal) throws {
        _ = try requireOwner(owner)
        try writer.write { db in
            try db.execute(sql: "UPDATE diffComment SET resolvedAt = ? WHERE companyId = ? AND id = ? AND resolvedAt IS NULL",
                           arguments: [now, companyId, id])
            guard db.changesCount > 0 else { throw WorkError.notFound("no such comment") }
        }
    }
}

/// The quoted hunk lines of an inline comment: redacted text from the snapshot, invisible characters shown as `⟦U+XXXX⟧`,
/// each line cut to `DiffReviewLimits.quoteLineChars`.
enum DiffQuote {
    /// Up to `quoteLines` lines of the hunk around the anchored line (the hunk's first lines when the line isn't in it).
    static func lines(_ hunk: DiffAnchoring.Hunk, anchor: DiffAnchor) -> [String] {
        let body = hunk.lines
        guard !body.isEmpty else { return [] }
        let at = hunk.numbered.firstIndex { $0.side(anchor.side) == anchor.line } ?? 0
        let half = DiffReviewLimits.quoteLines / 2
        var start = max(0, at - half)
        let end = min(body.count, start + DiffReviewLimits.quoteLines)
        start = max(0, end - DiffReviewLimits.quoteLines)
        return body[start..<end].map(sanitize)
    }

    /// Invisible characters (controls, DEL, bidi, zero-width, format, soft hyphen, line and paragraph separators) as `⟦U+XXXX⟧`;
    /// the line cut to `quoteLineChars` with `…`. A tab stays.
    static func sanitize(_ line: String) -> String {
        var out = ""
        for scalar in line.unicodeScalars {
            let v = scalar.value
            if v == 0x09 { out.unicodeScalars.append(scalar); continue }
            let category = scalar.properties.generalCategory
            if RefText.isHidden(v) || category == .format || category == .lineSeparator || category == .paragraphSeparator || v == 0x00AD || v == 0x180E {
                out += "⟦U+" + String(v, radix: 16, uppercase: true).leftPadded(to: 4) + "⟧"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        if out.count > DiffReviewLimits.quoteLineChars { out = String(out.prefix(DiffReviewLimits.quoteLineChars - 1)) + "…" }
        return out
    }
}

/// Re-anchoring is plain code over the patch text: a comment shows at the line whose text hashes to its `lineHash` within
/// ±`reanchorWindow` lines of `line` in the same file and side, else as "outdated" (nil) in that file's header.
public enum DiffAnchoring {
    struct Numbered {
        var old: Int?
        var new: Int?
        var text: String
        func side(_ s: String) -> Int? { s == "old" ? old : new }
    }

    struct Hunk {
        var header: String
        /// The raw hunk body lines (with their `+`/`-`/space markers).
        var lines: [String]
        var numbered: [Numbered]
    }

    /// The hunks of `path` in the patch, with old/new line numbers per body line.
    static func hunks(in patch: String, path: String) -> [Hunk] {
        guard let section = ChangesPatch.parse(patch).first(where: { $0.path == path }) else { return [] }
        return hunks(of: section)
    }

    /// The hunks of the `index`-th section of the patch (`ChangedFile.patchIndex`: the engine's file identity, C6b I-1).
    static func hunks(in patch: String, sectionIndex index: Int) -> [Hunk] {
        let sections = ChangesPatch.parse(patch)
        guard sections.indices.contains(index) else { return [] }
        return hunks(of: sections[index])
    }

    static func hunks(of section: ChangesPatch.Section) -> [Hunk] {
        var out: [Hunk] = []
        var current: Hunk?
        var old = 0, new = 0
        for line in section.hunks {
            if line.hasPrefix("@@") {
                if let h = current { out.append(h) }
                let (o, n) = starts(line)
                old = o; new = n
                current = Hunk(header: line, lines: [], numbered: [])
                continue
            }
            guard var h = current else { continue }
            h.lines.append(line)
            // The line as the app shows it (C6b-2): its marker dropped, one trailing CR read as the line ending — the hash both sides agree on.
            var text = String(line.unicodeScalars.dropFirst())
            if text.unicodeScalars.last == "\r" { text.unicodeScalars.removeLast() }
            if line.hasPrefix("+") { h.numbered.append(Numbered(old: nil, new: new, text: text)); new += 1 }
            else if line.hasPrefix("-") { h.numbered.append(Numbered(old: old, new: nil, text: text)); old += 1 }
            else if line.hasPrefix("\\") { h.numbered.append(Numbered(old: nil, new: nil, text: text)) }
            else { h.numbered.append(Numbered(old: old, new: new, text: text)); old += 1; new += 1 }
            current = h
        }
        if let h = current { out.append(h) }
        return out
    }

    /// The hunk whose range (`@@ -a,b +c,d @@`) is `header`'s, or nil: a stale anchor quotes nothing (never another hunk).
    static func hunk(in patch: String, path: String, header: String) -> Hunk? {
        guard let wanted = headerRange(header) else { return nil }
        return hunks(in: patch, path: path).first { headerRange($0.header) == wanted }
    }

    /// `@@ -a,b +c,d @@` → (a, c); 0 when unreadable.
    static func starts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ s: Substring) -> Int { Int(s.dropFirst().split(separator: ",").first ?? "") ?? 0 }
        guard parts.count >= 3 else { return (0, 0) }
        return (start(parts[1]), start(parts[2]))
    }

    /// The header's range alone, `@@ -a[,b] +c[,d] @@`, regenerated from its numbers (never the function context git appends,
    /// which is a line of the file); nil when the text is not a hunk header.
    public static func headerRange(_ header: String) -> String? {
        let parts = header.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@" else { return nil }
        func range(_ s: Substring, _ sign: Character) -> String? {
            guard s.first == sign else { return nil }
            let nums = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(nums.count), nums.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            return String(sign) + nums.joined(separator: ",")
        }
        guard let old = range(parts[1], "-"), let new = range(parts[2], "+") else { return nil }
        return "@@ \(old) \(new) @@"
    }

    /// The line the comment shows at in `patch` now, or nil when it is outdated. With `sectionIndex` (the snapshot file's
    /// `patchIndex`) the section is the engine's identity, so a display path that differs from the raw one still relocates.
    public static func relocate(_ comment: DiffComment, in patch: String, sectionIndex: Int? = nil) -> Int? {
        var best: Int?
        let found = sectionIndex.map { Self.hunks(in: patch, sectionIndex: $0) } ?? Self.hunks(in: patch, path: comment.path)
        for hunk in found {
            for n in hunk.numbered {
                guard let line = n.side(comment.side), abs(line - comment.line) <= DiffReviewLimits.reanchorWindow,
                      StableHash.fnv1a64(n.text) == comment.lineHash else { continue }
                if best.map({ abs(line - comment.line) < abs($0 - comment.line) }) ?? true { best = line }
            }
        }
        return best
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}
