import Foundation
import GRDB

/// Plan C Task C5b: the live changes engine's pinned numbers (global constraints, "Live changes").
public enum ChangesLimits {
    /// Recompute cadence while a stream is observed and the holder is running.
    public static let refreshInterval: Duration = .seconds(2)
    /// Recompute cadence while the holder isn't running.
    public static let idleInterval: Duration = .seconds(10)
    /// The app's FSEvents nudge debounce.
    public static let nudgeDebounce: Duration = .milliseconds(300)
    public static let maxPatchLines = 5000
    /// A changed file larger than this is summarized, its hunks not shown.
    public static let maxFileBytes = 2_097_152
    /// Hunk lines kept per file; the rest is "N more lines not shown".
    public static let maxFileHunkLines = 1500
    public static let maxFiles = 2000
}

/// What a changes view compares (design: Codex-style live diffs). `main` is the live worktree against the merge base with
/// `main`; `head` against the item branch's last commit; `lastCheck` against the commit of the item's last check run;
/// `revisions` between two item revisions (`base`, `r<n>`, `head`, `worktree`).
public enum CompareMode: Hashable, Sendable, Codable {
    case main
    case head
    case lastCheck
    case revisions(from: String, to: String)

    /// The ref of this compare of item `key` (`ENG-1:diff@worktree`, `…?vs=head`, `…?vs=check`, `ENG-1:diff@r1..r2`).
    public func ref(key: String) -> WorkRef {
        switch self {
        case .main: return WorkRef(kind: .diff, id: key, branch: "worktree:\(key)")
        case .head: return WorkRef(kind: .diff, id: key, branch: "worktree:\(key)", params: ["vs": "head"])
        case .lastCheck: return WorkRef(kind: .diff, id: key, branch: "worktree:\(key)", params: ["vs": "check"])
        case .revisions(let from, let to):
            return WorkRef(kind: .diff, id: key, branch: to == "worktree" ? "worktree:\(key)" : nil, params: ["from": from, "to": to])
        }
    }

    /// The compare an item diff ref names; nil for a pinned snapshot or a ref that is no item diff. A committed `ENG-1:diff`
    /// is `base..head`.
    public init?(ref: WorkRef) {
        guard ref.kind == .diff, !ref.id.isEmpty, ref.params["snapshot"] == nil, ref.params["wt"] == nil else { return nil }
        if let from = ref.params["from"], let to = ref.params["to"] {
            self = .revisions(from: from, to: to)
        } else if ref.isWorktree {
            switch ref.params["vs"] {
            case nil: self = .main
            case "head"?: self = .head
            case "check"?: self = .lastCheck
            default: return nil
            }
        } else if ref.rev == nil {
            self = .revisions(from: "base", to: "head")
        } else {
            return nil
        }
    }

    /// Whether the target is the live worktree.
    public var isLive: Bool {
        switch self {
        case .main, .head, .lastCheck: return true
        case .revisions(_, let to): return to == "worktree"
        }
    }

    /// `base`, `r<n>`, `head` or `worktree` (a revision label the grammar accepts in that position).
    static func isFromLabel(_ s: String) -> Bool { s == "base" || isRunLabel(s) }
    static func isToLabel(_ s: String) -> Bool { s == "head" || s == "worktree" || isRunLabel(s) }
    static func isRunLabel(_ s: String) -> Bool { s.hasPrefix("r") && RefGrammar.number(String(s.dropFirst())) != nil }
}

public struct ChangedFile: Equatable, Sendable, Codable {
    public var path: String
    public var oldPath: String?
    /// `A`, `M`, `D` or `R`.
    public var status: String
    public var added: Int
    public var removed: Int
    /// `"binary · 1.2 MB → 1.3 MB"`, `"large file · 4.1 MB, diff not shown"` or `"1,500 more lines not shown"`.
    public var summary: String?

    public init(path: String, oldPath: String? = nil, status: String, added: Int, removed: Int, summary: String? = nil) {
        self.path = path; self.oldPath = oldPath; self.status = status; self.added = added; self.removed = removed; self.summary = summary
    }
}

/// One computed view of an item's changes: redacted, capped and gated as the final display text (Rulings 53–56).
public struct ChangesSnapshot: Equatable, Sendable {
    public var key: String
    public var compare: CompareMode
    /// The base commit.
    public var base: String
    /// The target commit, or `"worktree"`.
    public var target: String
    public var files: [ChangedFile]
    public var added: Int
    public var removed: Int
    /// Redacted and capped.
    public var patch: String
    public var truncated: Bool
    public var tainted: Bool
    public var taintReason: String?
    /// The newest modification time among the changed files (live targets only; `SafeFS` fstat).
    public var lastEdit: Date?
    /// Changes when the shown patch or the file list changes.
    public var patchHash: String
    public var computedAt: Date
}

/// A revision of an item: `base` (the merge base with `main`), `r<n>` (the commit of its n-th check run, oldest first),
/// `head` and `worktree`.
public struct ItemRevision: Equatable, Sendable {
    public var label: String
    public var sha: String?
    public var at: Date?
    public var checkStatus: String?
}

/// The patch before redaction, with the engine-derived facts the snapshot carries. Internal: `Store.changesRaw` makes it,
/// `Store.finishChanges` turns it into a `ChangesSnapshot` for one reader's known values.
struct RawChanges: Sendable {
    var key: String
    var compare: CompareMode
    var base: String
    var target: String
    var files: [ChangedFile]
    var patch: String
    var truncated: Bool
    var tainted: Bool
    var taintReason: String?
    var lastEdit: Date?
}

extension Store {
    /// The changes of item `key` for `reader`: the access check first (the live worktree rule, `RefAccess`; the generic text
    /// on refusal), bases only from engine records, then the patch redacted (`RedactedCopy`: secret patterns and every form
    /// of every stored value) and gated as the final text. Nothing is stored.
    public func changesSnapshot(companyId: String, key: String, compare: CompareMode, reader: Reader,
                                knownValues: [(name: String, value: String)], now: Date) throws -> ChangesSnapshot {
        try checkChangesAccess(companyId: companyId, key: key, compare: compare, reader: reader)
        let raw = try changesRaw(companyId: companyId, key: key, compare: compare)
        return Self.finishChanges(raw, knownValues: knownValues, now: now)
    }

    /// `WorkError.notFound(refUnavailable)` unless `reader` may read the compare's ref in full.
    func checkChangesAccess(companyId: String, key: String, compare: CompareMode, reader: Reader) throws {
        let ref = compare.ref(key: key)
        let decision = try writer.read { db in try RefAccess.canRead(reader, ref, companyId: companyId, db: db, catalog: catalog) }
        guard case .allowed = decision else { throw WorkError.notFound(Self.refUnavailable) }
    }

    /// The item's revisions: `base`, `r1`…`r<n>`, `head`, `worktree`.
    public func itemRevisions(companyId: String, key: String) throws -> [ItemRevision] {
        guard let company = try company(id: companyId),
              let item = try writer.read({ db in try RefAccess.item(db, companyId, key) }) else { throw WorkError.notFound(Self.refUnavailable) }
        let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        let runs = try checkRuns(companyId: companyId, itemId: item.id)
        let head = try git.head("item/\(item.key)")
        let base = try git.mergeBase("main", head)
        var out = [ItemRevision(label: "base", sha: base, at: nil, checkStatus: nil)]
        for (i, run) in runs.enumerated() {
            out.append(ItemRevision(label: "r\(i + 1)", sha: run.commit, at: run.createdAt, checkStatus: run.status.rawValue))
        }
        out.append(ItemRevision(label: "head", sha: head, at: nil, checkStatus: nil))
        out.append(ItemRevision(label: "worktree", sha: nil, at: nil, checkStatus: nil))
        return out
    }

    /// The item's check runs, oldest first (engine records: `verificationRun`).
    func checkRuns(companyId: String, itemId: String) throws -> [VerificationRun] {
        try writer.read { db in
            try VerificationRun.fetchAll(db, sql: """
                SELECT * FROM verificationRun WHERE companyId = ? AND itemId = ? ORDER BY createdAt ASC, rowid ASC
                """, arguments: [companyId, itemId])
        }
    }

    /// The base commit and the target (`nil`: the live worktree) of a compare, from engine records only: the merge base with
    /// `main`, `head(item/<KEY>)`, the runs' commits. `Outcome`-free: throws `WorkError.notFound` for a revision that isn't.
    func changesBases(companyId: String, item: WorkItem, compare: CompareMode, git: SafeGit) throws -> (base: String, target: String?) {
        let head = try git.head("item/\(item.key)")
        func run(_ label: String) throws -> String {
            let runs = try checkRuns(companyId: companyId, itemId: item.id)
            guard label.hasPrefix("r"), let n = Int(label.dropFirst()), n >= 1, n <= runs.count else {
                throw WorkError.notFound("\(item.key) has no revision \(Store.flat(label, max: 20))")
            }
            try SafeGit.checkRevShape(runs[n - 1].commit)
            return runs[n - 1].commit
        }
        func revision(_ label: String) throws -> String? {
            switch label {
            case "base": return try git.mergeBase("main", head)
            case "head": return head
            case "worktree": return nil
            default: return try run(label)
            }
        }
        switch compare {
        case .main: return (try git.mergeBase("main", head), nil)
        case .head: return (head, nil)
        case .lastCheck:
            guard let last = try checkRuns(companyId: companyId, itemId: item.id).last else { throw WorkError.notFound("\(item.key) has no check run yet") }
            try SafeGit.checkRevShape(last.commit)
            return (last.commit, nil)
        case .revisions(let from, let to):
            guard CompareMode.isFromLabel(from), CompareMode.isToLabel(to) else { throw WorkError.notFound(Self.refUnavailable) }
            guard let base = try revision(from) else { throw WorkError.notFound(Self.refUnavailable) }
            return (base, try revision(to))
        }
    }

    /// The unredacted changes of `key` (no access check: callers check first). Live targets go through
    /// `SafeGit.worktreeDiff` on a temp index (the agent's own `.git`/index is never read or written); committed pairs
    /// through `SafeGit.diff`. Binary and over-cap files get a summary and no hunks; a file's hunks are cut at
    /// `ChangesLimits.maxFileHunkLines`.
    func changesRaw(companyId: String, key: String, compare: CompareMode) throws -> RawChanges {
        guard let company = try company(id: companyId),
              let item = try writer.read({ db in try RefAccess.item(db, companyId, key) }) else { throw WorkError.notFound(Self.refUnavailable) }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = try refGit(workspace)
        let (base, target) = try changesBases(companyId: companyId, item: item, compare: compare, git: git)
        let ref = compare.ref(key: item.key)
        let taint = try refTaint(ref, companyId: companyId)
        var files: [ChangedFile] = []
        var patch = "", truncated = false
        var lastEdit: Date?
        var sizes: [String: Int] = [:]
        do {
            if let target {
                let diff = try git.diff(base: base, head: target, path: nil, patchSkipOver: ChangesLimits.maxFileBytes)
                let parsed = ChangesPatch.parse(diff.patch)
                truncated = diff.truncated
                var stat = diff.stat
                if stat.count > ChangesLimits.maxFiles { stat = Array(stat.prefix(ChangesLimits.maxFiles)); truncated = true }
                let statuses = Dictionary(parsed.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                let skipped = Set(diff.skipped)
                for s in stat {
                    let section = statuses[s.path]
                    let large = skipped.contains(s.path)
                    let binary = !large && (s.added == nil || section?.binary == true)
                    files.append(ChangedFile(path: s.path, oldPath: nil, status: section?.status ?? (large && s.removed == 0 ? "A" : "M"),
                                             added: s.added ?? 0, removed: s.removed ?? 0, summary: large ? "large" : binary ? "binary" : nil))
                    if large || binary {
                        sizes[s.path] = (try? git.blobSize(rev: target, path: s.path)) ?? 0
                    }
                }
                (patch, files, truncated) = Self.assemble(parsed, files: files, truncated: truncated, bytes: sizes,
                                                           oldSize: { path in try? git.blobSize(rev: base, path: path) })
            } else {
                let fs = try SafeFS(workspace: workspace, ownHandle: nil)
                let temp = try refTempDirectory()
                defer { try? FileManager.default.removeItem(at: temp) }
                let worktree = workspace.appending(path: ".brahma/wt/\(item.key)", directoryHint: .isDirectory)
                let diff = try git.worktreeDiff(key: item.key, worktree: worktree, against: base, tempDir: temp, fs: fs,
                                                patchSkipOver: ChangesLimits.maxFileBytes)
                let parsed = ChangesPatch.parse(diff.patch)
                let binaryByParse = Set(parsed.filter(\.binary).map(\.path))
                let skipped = Set(diff.skipped)
                for f in diff.files {
                    let large = skipped.contains(f.path)
                    let binary = !large && ((f.added == nil && f.status != "D") || binaryByParse.contains(f.path))
                    files.append(ChangedFile(path: f.path, oldPath: nil, status: f.status == "T" ? "M" : f.status, added: f.added ?? 0,
                                             removed: f.removed ?? 0, summary: large ? "large" : binary ? "binary" : nil))
                    sizes[f.path] = f.bytes
                }
                (patch, files, truncated) = Self.assemble(parsed, files: files, truncated: diff.truncated, bytes: sizes,
                                                           oldSize: { path in try? git.blobSize(rev: base, path: path) })
                // The newest edit among the changed files that are present, by the descriptor SafeFS checked.
                for f in files where f.status != "D" && !f.path.hasSuffix("/") {
                    guard let file = try? fs.open(f.path, inWorktree: item.key, maxBytes: SafeGit.maxBinaryBytes) else { continue }
                    if lastEdit.map({ file.modifiedAt > $0 }) ?? true { lastEdit = file.modifiedAt }
                }
            }
        } catch let e as WorkError {
            throw e
        } catch {
            // A missing worktree, a refused walk, a git failure: the ref isn't available (no agent-controlled text).
            throw WorkError.notFound(Self.refUnavailable)
        }
        return RawChanges(key: item.key, compare: compare, base: base, target: target ?? "worktree", files: files, patch: patch,
                          truncated: truncated, tainted: taint.tainted, taintReason: taint.reason, lastEdit: lastEdit)
    }

    /// The patch of the kept sections, each file's hunks cut at the per-file cap, binary and over-cap files dropped with a
    /// summary. `truncated` is cleared when git's cut fell inside a section that is not shown anyway.
    static func assemble(_ sections: [ChangesPatch.Section], files: [ChangedFile], truncated: Bool, bytes: [String: Int],
                         oldSize: (String) -> Int?) -> (patch: String, files: [ChangedFile], truncated: Bool) {
        var byPath = Dictionary(sections.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        var files = files
        var truncated = truncated
        let lastSection = sections.last?.path
        for i in files.indices {
            let path = files[i].path
            let section = byPath.removeValue(forKey: path)
            let size = bytes[path] ?? 0
            if files[i].summary == "binary" {
                let old = oldSize(path) ?? 0
                files[i].summary = "binary · \(ChangesFormat.bytes(old)) → \(ChangesFormat.bytes(size))"
                files[i].added = 0; files[i].removed = 0
                if lastSection == path { truncated = false }
                continue
            }
            if files[i].summary == "large" || size > ChangesLimits.maxFileBytes {
                let shown = size > 0 ? size : (oldSize(path) ?? 0)
                files[i].summary = "large file · \(ChangesFormat.bytes(shown)), diff not shown"
                if lastSection == path { truncated = false }
                continue
            }
            guard let section else { continue }
            out.append(contentsOf: section.header)
            // Hunk lines (not `@@` headers) count towards the per-file cap; the rest is summarized.
            var content = 0, dropped = 0
            for line in section.hunks {
                if content >= ChangesLimits.maxFileHunkLines { if !line.hasPrefix("@@") { dropped += 1 }; continue }
                out.append(line)
                if !line.hasPrefix("@@") { content += 1 }
            }
            if dropped > 0 { files[i].summary = "\(ChangesFormat.count(dropped)) more lines not shown" }
        }
        var patch = out.joined(separator: "\n")
        if !patch.isEmpty { patch += "\n" }
        return (patch, files, truncated)
    }

    /// The snapshot for one reader's known values: the patch redacted (`RedactedCopy.make`: every secret pattern and every
    /// form of every stored value), then gated as the final text (`TextGate.holdsSecret`: a patch the redaction did not
    /// clear is withheld whole, never cut around a value); each path and summary gated the same way. Nothing changes a
    /// field after its gate. `patchHash` covers the shown patch and the file list.
    static func finishChanges(_ raw: RawChanges, knownValues: [(name: String, value: String)], now: Date) -> ChangesSnapshot {
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        var patch = String(decoding: RedactedCopy.make(Data(raw.patch.utf8), findings: [], knownValues: knownValues), as: UTF8.self)
        if gate.holdsSecret(patch) { patch = Self.withheldPatch }
        var files: [ChangedFile] = []
        for var f in raw.files {
            f.path = gate.final(f.path, max: 512) ?? Self.withheldPath
            if let old = f.oldPath { f.oldPath = gate.final(old, max: 512) ?? Self.withheldPath }
            if let s = f.summary { f.summary = gate.final(s, max: 200) ?? "withheld" }
            files.append(f)
        }
        let listing = files.map { "\($0.status) \($0.path) \($0.oldPath ?? "") +\($0.added) -\($0.removed) \($0.summary ?? "")" }.joined(separator: "\n")
        let hash = SHA256.hex(Data((patch + "\u{0}" + listing + "\u{0}" + raw.base + "\u{0}" + raw.target).utf8))
        return ChangesSnapshot(key: raw.key, compare: raw.compare, base: raw.base, target: raw.target, files: files,
                               added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed }, patch: patch,
                               truncated: raw.truncated, tainted: raw.tainted, taintReason: raw.taintReason, lastEdit: raw.lastEdit,
                               patchHash: hash, computedAt: now)
    }

    static let withheldPatch = "[patch withheld: it still looks like it holds a stored secret after redaction]\n"
    static let withheldPath = "[path withheld]"
}

/// Plain parsing of a unified patch into per-file sections (no regex over agent text).
enum ChangesPatch {
    struct Section {
        var path: String
        /// `A`, `M`, `D` or `R`.
        var status: String
        var binary: Bool
        /// The lines before the first hunk (`diff --git …`, modes, `index`, `---`, `+++`).
        var header: [String]
        /// The lines from the first `@@` on.
        var hunks: [String]
    }

    static func parse(_ patch: String) -> [Section] {
        var sections: [Section] = []
        var current: Section?
        var inHunks = false
        func close() { if let s = current { sections.append(s) }; current = nil; inHunks = false }
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                close()
                current = Section(path: Self.pathFromGitLine(line), status: "M", binary: false, header: [line], hunks: [])
                continue
            }
            guard var s = current else { continue }
            if !inHunks {
                if line.hasPrefix("@@") {
                    inHunks = true
                    s.hunks.append(line)
                } else {
                    if line.hasPrefix("new file mode") { s.status = "A" }
                    else if line.hasPrefix("deleted file mode") { s.status = "D" }
                    else if line.hasPrefix("rename from") || line.hasPrefix("rename to") { s.status = "R" }
                    else if line.hasPrefix("Binary files ") || line == "GIT binary patch" { s.binary = true }
                    else if line.hasPrefix("+++ b/") { s.path = String(line.dropFirst(6)) }
                    else if line.hasPrefix("--- a/"), s.status == "D" { s.path = String(line.dropFirst(6)) }
                    s.header.append(line)
                }
            } else {
                s.hunks.append(line)
            }
            current = s
        }
        close()
        // The split leaves one empty trailing line after the final newline.
        for i in sections.indices where sections[i].hunks.last == "" { sections[i].hunks.removeLast() }
        for i in sections.indices where sections[i].hunks.isEmpty && sections[i].header.last == "" { sections[i].header.removeLast() }
        return sections
    }

    /// `diff --git a/<p> b/<p>` → `<p>` (the two halves agree without renames; a path holding ` b/` is settled by `+++`).
    static func pathFromGitLine(_ line: String) -> String {
        let rest = line.dropFirst("diff --git ".count)
        guard rest.hasPrefix("a/") else { return String(rest) }
        let body = rest.dropFirst(2)
        // The path appears twice: `<p> b/<p>`; take the longest prefix that repeats.
        let text = String(body)
        if let range = text.range(of: " b/") {
            let first = String(text[..<range.lowerBound]), second = String(text[range.upperBound...])
            if first == second { return first }
        }
        return text
    }
}

/// Display formatting for the changes views.
enum ChangesFormat {
    /// `512 B`, `1.2 KB`, `4.1 MB` (decimal units, one decimal).
    static func bytes(_ n: Int) -> String {
        if n < 1000 { return "\(n) B" }
        if n < 1_000_000 { return String(format: "%.1f KB", Double(n) / 1000) }
        return String(format: "%.1f MB", Double(n) / 1_000_000)
    }

    /// `1,500`.
    static func count(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return out
    }
}
