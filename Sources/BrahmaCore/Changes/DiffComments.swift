import Foundation
import GRDB

/// Plan C Task C5b: the inline review limits (global constraints, "Inline review").
public enum DiffReviewLimits {
    /// Hunk lines quoted into the item comment.
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

/// A row of migration `vC-changes`: one inline owner comment (or revert request) on an item's diff.
public struct DiffComment: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "diffComment"
    public static let comment = "comment"
    public static let revertRequest = "revertRequest"

    public var id: String
    public var companyId: String
    public var itemId: String
    /// `comment` or `revertRequest`.
    public var kind: String
    public var path: String
    /// `old` or `new`.
    public var side: String
    public var line: Int
    /// `StableHash.fnv1a64` of the anchored line's text (re-anchoring).
    public var lineHash: String
    public var hunkHeader: String
    /// The compare's canonical ref (`ENG-1:diff@worktree`, `…?vs=head`, `ENG-1:diff@r1..worktree`).
    public var compare: String
    public var baseSha: String?
    /// The owner's text (a revert request's note, possibly empty).
    public var text: String
    /// The `commented` item event that carries the body.
    public var eventId: String?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(id: String = UUID().uuidString, companyId: String, itemId: String, kind: String, path: String, side: String, line: Int,
                lineHash: String, hunkHeader: String, compare: String, baseSha: String?, text: String, eventId: String?, createdAt: Date,
                resolvedAt: Date? = nil) {
        self.id = id; self.companyId = companyId; self.itemId = itemId; self.kind = kind; self.path = path; self.side = side; self.line = line
        self.lineHash = lineHash; self.hunkHeader = hunkHeader; self.compare = compare; self.baseSha = baseSha; self.text = text
        self.eventId = eventId; self.createdAt = createdAt; self.resolvedAt = resolvedAt
    }
}

/// Where a comment sits in a diff, as the app's diff model names it.
public struct DiffAnchor: Hashable, Sendable, Codable {
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
    /// The owner's inline comment on `anchor` of the item's diff (the app's path, never a tool). Writes a `diffComment` row,
    /// then an owner item comment through 3a's event path with the body
    ///
    ///     Owner review comment on <path>:<line> (<compare canonical> @<base sha7>):
    ///         | <the hunk header>
    ///         | <up to 20 hunk lines around the line, redacted, invisible characters as ⟦U+XXXX⟧, each cut to 200 chars>
    ///     <owner text>
    ///
    /// and a waking `reviewComment` item event for the lease holder (else the assignee). The quote comes from the redacted
    /// snapshot (`changesSnapshot`); the whole body is gated as the final text before it is written: a stored value in it
    /// (the owner's own text included: the body reaches agents) refuses the comment.
    @discardableResult
    public func addDiffComment(companyId: String, key: String, compare: CompareMode, anchor: DiffAnchor, text: String,
                               knownValues: [(name: String, value: String)], now: Date) throws -> DiffComment {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw WorkError.invalid("the comment is empty") }
        return try writeDiffComment(companyId: companyId, key: key, compare: compare, anchor: anchor, kind: DiffComment.comment, text: body,
                                    knownValues: knownValues, now: now) { snapshot, _ in
            "Owner review comment on \(anchor.path):\(anchor.line) (\(compare.ref(key: key).canonical) @\(snapshot.base.prefix(7))):"
        }
    }

    /// The same path with `kind = revertRequest` and the first line `Owner asks you to revert this hunk in <path> (<hunk
    /// header>):`. The engine never writes to the worktree, its index or the item branch for it: no `checkout`, `apply`,
    /// `restore`, `reset` or file write is ever issued (the holder does the revert in its turn).
    @discardableResult
    public func requestHunkRevert(companyId: String, key: String, compare: CompareMode, anchor: DiffAnchor, note: String?,
                                  knownValues: [(name: String, value: String)], now: Date) throws -> DiffComment {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try writeDiffComment(companyId: companyId, key: key, compare: compare, anchor: anchor, kind: DiffComment.revertRequest, text: text,
                                    knownValues: knownValues, now: now) { _, _ in
            "Owner asks you to revert this hunk in \(anchor.path) (\(anchor.hunkHeader)):"
        }
    }

    private func writeDiffComment(companyId: String, key: String, compare: CompareMode, anchor: DiffAnchor, kind: String, text: String,
                                  knownValues: [(name: String, value: String)], now: Date,
                                  header: (ChangesSnapshot, DiffAnchor) -> String) throws -> DiffComment {
        guard text.count <= DiffReviewLimits.maxText else { throw WorkError.invalid("the comment is longer than \(DiffReviewLimits.maxText) characters") }
        guard !anchor.path.isEmpty, anchor.path.count <= DiffReviewLimits.maxPath, !anchor.path.contains("\n"),
              anchor.side == "old" || anchor.side == "new", anchor.line >= 1,
              anchor.hunkHeader.hasPrefix("@@"), anchor.hunkHeader.count <= DiffReviewLimits.maxHunkHeader, !anchor.hunkHeader.contains("\n")
        else { throw WorkError.invalid("the anchor is not a diff position") }
        guard let item = try writer.read({ db in try RefAccess.item(db, companyId, key) }) else { throw WorkError.notFound(Self.refUnavailable) }
        // The snapshot as the owner sees it (redacted): the quote is cut from it.
        let snapshot = try changesSnapshot(companyId: companyId, key: key, compare: compare, reader: .owner, knownValues: knownValues, now: now)
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        guard !gate.holdsSecret(text) else { throw WorkError.invalid("the comment holds a stored secret's value; remove it before posting") }
        let quote = DiffQuote.lines(snapshot.patch, anchor: anchor)
        var lines = [header(snapshot, anchor), "    | " + DiffQuote.sanitize(anchor.hunkHeader)]
        lines += quote.map { "    | " + $0 }
        if !text.isEmpty { lines.append(text) }
        let body = lines.joined(separator: "\n")
        // Gated as the final text (Rulings 53–56): nothing changes it after this check.
        guard !gate.holdsSecret(body) else { throw WorkError.invalid("the comment would quote a stored secret's value; it was not posted") }
        let compareCanonical = compare.ref(key: key).canonical
        let summary = kind == DiffComment.comment ? "owner review comment on \(anchor.path):\(anchor.line)"
            : "owner asks to revert a hunk in \(anchor.path)"
        return try writer.write { db in
            let event = try recordItemEvent(db: db, item: item, actor: "owner", kind: .commented, text: body, now: now)
            // Whoever holds the work is woken: the lease holder, else the assignee.
            let target = try Self.leaseHolderId(db: db, itemId: item.id) ?? item.ownerId
            try recordItemEvent(db: db, item: item, actor: "owner", kind: .reviewComment, text: summary,
                                alsoNotify: target.map { [$0] } ?? [], alsoNotifyRole: .holder, onlyAlsoNotify: true, now: now)
            let row = DiffComment(companyId: companyId, itemId: item.id, kind: kind, path: anchor.path, side: anchor.side, line: anchor.line,
                                  lineHash: StableHash.fnv1a64(anchor.lineText), hunkHeader: anchor.hunkHeader, compare: compareCanonical,
                                  baseSha: snapshot.base, text: text, eventId: event.id.map(String.init), createdAt: now)
            try row.insert(db)
            return row
        }
    }

    /// The item's diff comments, for readers who can read the item; each agent-visible field gated as the final string.
    public func diffComments(companyId: String, key: String, reader: Reader, knownValues: [(name: String, value: String)]) throws -> [DiffComment] {
        let decision = try writer.read { db in
            try RefAccess.canRead(reader, WorkRef(kind: .item, id: key), companyId: companyId, db: db, catalog: catalog)
        }
        guard case .allowed = decision else { throw WorkError.notFound(Self.refUnavailable) }
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        let rows = try writer.read { db in
            try DiffComment.fetchAll(db, sql: """
                SELECT diffComment.* FROM diffComment JOIN workItem ON workItem.id = diffComment.itemId
                WHERE diffComment.companyId = ? AND workItem.companyId = ? AND workItem.key = ? ORDER BY diffComment.createdAt, diffComment.rowid
                """, arguments: [companyId, companyId, key])
        }
        return rows.map { row in
            var r = row
            r.path = gate.final(row.path, max: DiffReviewLimits.maxPath) ?? Self.withheldPath
            r.hunkHeader = gate.final(row.hunkHeader, max: DiffReviewLimits.maxHunkHeader) ?? "@@"
            r.text = gate.final(row.text, max: DiffReviewLimits.maxText) ?? ShowLimits.withheldNote
            return r
        }
    }

    /// Marks the comment resolved (owner).
    public func resolveDiffComment(companyId: String, id: String, now: Date) throws {
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
    /// Up to `quoteLines` lines of the anchor's hunk around the anchored line (the hunk's first lines when the line isn't
    /// found); nothing when the file or hunk isn't in the patch.
    static func lines(_ patch: String, anchor: DiffAnchor) -> [String] {
        guard let hunk = DiffAnchoring.hunk(in: patch, path: anchor.path, header: anchor.hunkHeader) else { return [] }
        let body = hunk.lines
        guard !body.isEmpty else { return [] }
        let at = hunk.numbered.firstIndex { $0.side(anchor.side) == anchor.line } ?? 0
        let half = DiffReviewLimits.quoteLines / 2
        var start = max(0, at - half)
        let end = min(body.count, start + DiffReviewLimits.quoteLines)
        start = max(0, end - DiffReviewLimits.quoteLines)
        return body[start..<end].map(sanitize)
    }

    /// Invisible characters as `⟦U+XXXX⟧`; the line cut to `quoteLineChars` with `…`.
    static func sanitize(_ line: String) -> String {
        var out = ""
        for scalar in line.unicodeScalars {
            let v = scalar.value
            if v == 0x09 { out.unicodeScalars.append(scalar); continue }
            if RefText.isHidden(v) || scalar.properties.generalCategory == .format || v == 0x00AD || v == 0x180E {
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
            let text = String(line.dropFirst())
            if line.hasPrefix("+") { h.numbered.append(Numbered(old: nil, new: new, text: text)); new += 1 }
            else if line.hasPrefix("-") { h.numbered.append(Numbered(old: old, new: nil, text: text)); old += 1 }
            else if line.hasPrefix("\\") { h.numbered.append(Numbered(old: nil, new: nil, text: text)) }
            else { h.numbered.append(Numbered(old: old, new: new, text: text)); old += 1; new += 1 }
            current = h
        }
        if let h = current { out.append(h) }
        return out
    }

    /// The hunk with `header` (else the one that spans the anchor's line, else nil).
    static func hunk(in patch: String, path: String, header: String) -> Hunk? {
        let all = hunks(in: patch, path: path)
        return all.first { $0.header == header } ?? all.first { !$0.lines.isEmpty }
    }

    /// `@@ -a,b +c,d @@` → (a, c); 0 when unreadable.
    static func starts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ s: Substring) -> Int { Int(s.dropFirst().split(separator: ",").first ?? "") ?? 0 }
        guard parts.count >= 3 else { return (0, 0) }
        return (start(parts[1]), start(parts[2]))
    }

    /// The line the comment shows at in `patch` now, or nil when it is outdated.
    public static func relocate(_ comment: DiffComment, in patch: String) -> Int? {
        var best: Int?
        for hunk in hunks(in: patch, path: comment.path) {
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
