import Foundation
import GRDB

/// Refs resolved for one reader (design §1.3, §4.2): the access decision first (`RefAccess`), then the object's
/// engine-derived title, subtitle and size from its data source (git through `SafeGit`, `.brahma` places through `SafeFS`,
/// rows through the store). Anything but `.full` leaves with only its kind and a fresh opaque handle.
extension Store {
    public func resolveRef(_ ref: WorkRef, for reader: Reader, companyId: String) throws -> ResolvedRef {
        try resolveForReader(ref, reader: reader, companyId: companyId, messageRefId: nil).resolved
    }

    /// `ref` as it is stored with a share: `rev` set to the commit the branch head (or the verified sha) names for committed
    /// files, diffs and commits, and the status at share time in `params["was"]` for items, asks, agents and previews (plus
    /// `params["main"]`, the main commit, for previews). A reader that can't read the ref in full can't pin it
    /// (`WorkError.forbidden`): a share never widens access. C2a adds `@worktree`, lab, notes and diff snapshots.
    public func pinRef(_ ref: WorkRef, for reader: Reader, companyId: String, messageRefId: String) throws -> WorkRef {
        let r = try resolveForReader(ref, reader: reader, companyId: companyId, messageRefId: messageRefId)
        guard r.resolved.visibility == .full else { throw WorkError.forbidden("there is no such ref you can read") }
        return r.pinned
    }

    // MARK: Resolution

    private struct Resolution {
        var resolved: ResolvedRef
        var pinned: WorkRef
    }

    /// What a `.full` object shows.
    private struct Details {
        var title: String
        var subtitle: String
        var bytes: Int? = nil
        var provenance: Provenance = .engine
        var tainted = false
        var taintReason: String? = nil
        var newer: WorkRef? = nil
        var state: RefState = .ok
        var pinned: WorkRef
    }

    private enum Outcome: Error { case missing, refused }

    private func resolveForReader(_ ref: WorkRef, reader: Reader, companyId: String, messageRefId: String?) throws -> Resolution {
        let opaqueId = StableHash.fnv1a64("\(companyId)\u{0}\(messageRefId ?? UUID().uuidString)")
        func blank(_ visibility: Visibility) -> Resolution {
            let r = ResolvedRef(ref: WorkRef(kind: ref.kind, id: ""), reader: reader, visibility: visibility, title: "", subtitle: "",
                                bytes: nil, provenance: .engine, tainted: false, taintReason: nil, accessClass: .ownerOnly,
                                newer: nil, state: .ok, opaqueId: opaqueId)
            return Resolution(resolved: r, pinned: r.ref)
        }
        let found: (decision: RefDecision, subject: RefAccess.Subject, company: Company, handle: String?)? = try writer.read { db in
            guard let company = try Company.fetchOne(db, key: companyId),
                  let ctx = try RefAccess.readerContext(reader, companyId: companyId, db: db, catalog: catalog),
                  let subject = try RefAccess.subject(ref, companyId: companyId, db: db) else { return nil }
            let handle = try ctx.agentId.flatMap { try RefAccess.handle(db, companyId, $0) }
            return (RefAccess.decide(ctx, subject), subject, company, handle)
        }
        guard let found else { return blank(.missing) }
        switch found.decision {
        case .refused: return blank(.refused)
        case .locked(let role): return blank(.locked(approverRole: role))
        case .allowed: break
        }
        let details: Details
        do {
            details = try self.details(ref, found.subject, company: found.company, readerHandle: found.handle)
        } catch Outcome.refused {
            return blank(.refused)
        } catch is Outcome, is SafeGitError, is SafeFSError {
            return blank(.missing)
        }
        let resolved = ResolvedRef(ref: ref, reader: reader, visibility: .full, title: details.title, subtitle: details.subtitle,
                                   bytes: details.bytes, provenance: details.provenance, tainted: details.tainted,
                                   taintReason: details.taintReason, accessClass: found.subject.access, newer: details.newer,
                                   state: details.state, opaqueId: opaqueId)
        return Resolution(resolved: resolved, pinned: details.pinned)
    }

    private func details(_ ref: WorkRef, _ subject: RefAccess.Subject, company: Company, readerHandle: String?) throws -> Details {
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        switch subject.record {
        case .file(let place):
            return try fileDetails(ref, workspace: workspace, companyId: company.id, ownHandle: place ?? readerHandle)
        case .diff(let item):
            return try diffDetails(ref, item: item, workspace: workspace)
        case .commit:
            let git = try refGit(workspace)
            let sha = try git.verifyRev(ref.id, reachableFrom: try reachabilityRefs(companyId: company.id))
            let shown = try git.show(commit: sha)
            var pinned = ref
            pinned.rev = sha
            return Details(title: "commit \(sha.prefix(7))", subtitle: Self.diffStat(shown.diff), pinned: pinned)
        case .item(let item, let owner):
            var pinned = ref
            pinned.params["was"] = item.status.rawValue
            return Details(title: Self.safe("\(item.key) \(item.title)"),
                           subtitle: item.status.rawValue + (owner.map { " · @\($0)" } ?? ""),
                           tainted: item.taintedOrigin, taintReason: item.taintedOrigin ? "outside content" : nil, pinned: pinned)
        case .ask(let ask):
            var pinned = ref
            pinned.params["was"] = ask.status.rawValue
            return Details(title: Self.safe("\(ask.ref) \(ask.title)"), subtitle: ask.status.rawValue,
                           provenance: ask.requesterId == "system" ? .engine : .agent(ask.requesterId), pinned: pinned)
        case .kb(let page, let section):
            let title = page.tainted ? "kb:\(page.path) (untrusted)" : page.title + (section.map { " · \($0)" } ?? "")
            let provenance: Provenance = page.ownerId == "owner" ? .owner : page.ownerId == "system" ? .engine : .agent(page.ownerId)
            return Details(title: Self.safe(title), subtitle: "kb · revision \(page.revision)", bytes: page.body.utf8.count,
                           provenance: provenance, tainted: page.tainted, taintReason: page.taintReason, pinned: ref)
        case .memory(let entry, let author):
            return Details(title: Self.safe("Memory \(entry.ref) · \(entry.type.rawValue) · @\(author)"), subtitle: entry.kind.rawValue,
                           bytes: entry.fact.utf8.count, provenance: Provenance(raw: entry.provenance) ?? .external(entry.provenance),
                           tainted: entry.tainted, taintReason: entry.taintReason, pinned: ref)
        case .resource(let r):
            let state: RefState = r.purgedAt != nil ? .purged : r.secretScan == .redacted ? .redacted : .ok
            return Details(title: r.tainted ? "\(r.ref) (untrusted)" : Self.safe(r.displayName),
                           subtitle: "\(r.ref) · \(r.fileKind ?? r.kind.rawValue)", bytes: Int(r.bytes),
                           provenance: Provenance(raw: r.provenance) ?? .external(r.provenance), tainted: r.tainted,
                           taintReason: r.taintReason, state: state, pinned: ref)
        case .preview(let surface, let status):
            var pinned = ref
            pinned.params["was"] = (status ?? .idle).rawValue
            if let main = try? refGit(workspace).head("main") { pinned.params["main"] = main }
            let viewport = ref.params["viewport"].map { " · \($0)" } ?? ""
            return Details(title: Self.safe("preview \(surface.name)\(ref.params["path"] ?? "")"),
                           subtitle: (status ?? .idle).rawValue + viewport, pinned: pinned)
        case .run(let run, let key):
            let exit = run.exitCode.map { " · exit \($0)" } ?? ""
            return Details(title: "run · \(key)", subtitle: run.status.rawValue + exit, pinned: ref)
        case .release(let version, let status):
            return Details(title: Self.safe("Release \(version)"), subtitle: Self.safe(status), pinned: ref)
        case .message(let m, let channel):
            let place = channel.kind == .dm ? "DM" : "#\(channel.name)"
            let provenance: Provenance = m.senderId == "owner" ? .owner : m.senderId == "system" ? .engine : .agent(m.senderId)
            return Details(title: (ref.kind == .thread ? "Thread in " : "Message in ") + place, subtitle: Self.safe(m.text),
                           bytes: m.text.utf8.count, provenance: provenance, tainted: m.taintedOrigin,
                           taintReason: m.taintedOrigin ? "from a session that read outside content" : nil, pinned: ref)
        case .agent(let agent):
            var pinned = ref
            pinned.params["was"] = agent.state.rawValue
            return Details(title: "@\(agent.name)", subtitle: "\(agent.role) · \(agent.state.rawValue)", pinned: pinned)
        case .channel(let channel, let members):
            return Details(title: "#\(channel.name)", subtitle: members == 1 ? "1 member" : "\(members) members", pinned: ref)
        case .sprint(let sprint):
            return Details(title: "Sprint \(sprint.number)", subtitle: sprint.status.rawValue, pinned: ref)
        case .fact:
            return Details(title: Self.safe(ref.id), subtitle: "fact", pinned: ref)
        }
    }

    // MARK: Files and diffs

    private func fileDetails(_ ref: WorkRef, workspace: URL, companyId: String, ownHandle: String?) throws -> Details {
        let title = Self.safe(ref.id + (ref.range.map { $0.start == $0.end ? ":\($0.start)" : ":\($0.start)-\($0.end)" } ?? ""))
        let language = Self.language(of: ref.id)
        // `.brahma` places (labs, notes, the allowlisted children) and live worktree files: the bytes SafeFS checked.
        if ref.isWorktree || (ref.branch == nil && ref.rev == nil && ref.id.hasPrefix(".brahma/")) {
            let fs = try SafeFS(workspace: workspace, ownHandle: ref.isWorktree ? nil : ownHandle)
            let file: SafeFile
            do {
                if let key = ref.itemKey, ref.isWorktree {
                    file = try fs.open(ref.id, inWorktree: key, maxBytes: SafeGit.maxTextBytes)
                } else {
                    file = try fs.open(workspacePath: ref.id, maxBytes: SafeGit.maxTextBytes)
                }
            } catch SafeFSError.privateTo(_), SafeFSError.notAllowed {
                throw Outcome.refused
            }
            let subtitle = "\(Self.lines(Self.lineCount(try file.readAll()))) · \(language)" + (ref.isWorktree ? " · UNCOMMITTED" : "")
            return Details(title: title, subtitle: subtitle, bytes: file.size, pinned: ref)
        }
        let git = try refGit(workspace)
        let branch = ref.itemKey.map { "item/\($0)" } ?? "main"
        let sha: String
        if let rev = ref.rev {
            let refs = ref.itemKey != nil ? [branch] : try reachabilityRefs(companyId: companyId)
            sha = try git.verifyRev(rev, reachableFrom: refs)
        } else {
            sha = try git.head(branch)
        }
        let size = try git.blobSize(rev: sha, path: ref.id)
        var state = RefState.ok
        var subtitle = "\(language) · @\(sha.prefix(7))"
        if size <= SafeGit.maxTextBytes {
            subtitle = "\(Self.lines(Self.lineCount(try git.catFile(rev: sha, path: ref.id, binary: false)))) · " + subtitle
        } else {
            state = .tooLarge
        }
        var newer: WorkRef?
        if ref.rev != nil, let head = try? git.head(branch), head != sha,
           let changed = try? git.logShas(range: "\(sha)..\(head)", path: ref.id), !changed.isEmpty {
            newer = ref
            newer?.rev = head
        }
        var pinned = ref
        pinned.rev = sha
        return Details(title: title, subtitle: subtitle, bytes: size, newer: newer, state: state, pinned: pinned)
    }

    private func diffDetails(_ ref: WorkRef, item: WorkItem, workspace: URL) throws -> Details {
        let file = ref.params["file"]
        let title = Self.safe("\(item.key) diff" + (file.map { " · \($0)" } ?? ""))
        if ref.isWorktree {
            let fs = try SafeFS(workspace: workspace, ownHandle: nil)
            let temp = try refTempDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let worktree = workspace.appending(path: ".brahma/wt/\(item.key)", directoryHint: .isDirectory)
            let diff = try refGit(workspace).worktreeDiff(key: item.key, worktree: worktree, tempDir: temp, fs: fs)
            let files = diff.files.filter { file == nil || $0.path == file }
            let summary = Self.diffStat(files.map { (path: $0.path, added: $0.added, removed: $0.removed) })
            return Details(title: Self.safe(title + " (uncommitted)"), subtitle: summary, state: diff.truncated ? .tooLarge : .ok, pinned: ref)
        }
        let git = try refGit(workspace)
        let branch = "item/\(item.key)"
        let current = try git.head(branch)
        let head = try ref.rev.map { try git.verifyRev($0, reachableFrom: [branch]) } ?? current
        let base = try git.mergeBase("main", head)
        let diff = try git.diff(base: base, head: head, path: file)
        var newer: WorkRef?
        if ref.rev != nil, current != head {
            newer = ref
            newer?.rev = current
        }
        var pinned = ref
        pinned.rev = head
        return Details(title: title, subtitle: Self.diffStat(diff), newer: newer, state: diff.truncated ? .tooLarge : .ok, pinned: pinned)
    }

    /// `main` and the branches of the company's open items: what an agent-named sha must be reachable from.
    private func reachabilityRefs(companyId: String) throws -> [String] {
        let keys = try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT key FROM workItem WHERE companyId = ? AND status IN ('inProgress', 'inReview', 'blocked')
                ORDER BY updatedAt DESC LIMIT 50
                """, arguments: [companyId])
        }
        return ["main"] + keys.map { "item/\($0)" }
    }

    /// Engine git over the company workspace; its captured output goes under the data home's `tmp` (never the process temp
    /// dir when the store has a data home).
    private func refGit(_ workspace: URL) throws -> SafeGit {
        SafeGit(workspace: workspace, runner: LiveGitRunner(tempRoot: try dataHomeTmp()))
    }

    private func dataHomeTmp() throws -> URL? {
        guard let dataHome else { return nil }
        let tmp = dataHome.appending(path: "tmp", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(tmp)
        return tmp
    }

    /// A fresh 0700 directory for one worktree diff, under the data home's `tmp`.
    private func refTempDirectory() throws -> URL {
        let root = try dataHomeTmp() ?? FileManager.default.temporaryDirectory
        let dir = root.appending(path: "ref-\(UUID().uuidString)", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(dir)
        return dir
    }

    // MARK: Text

    static func safe(_ s: String) -> String { SafeTitle.make(s).text }

    static func diffStat(_ diff: SafeGit.DiffText) -> String { diffStat(diff.stat) }

    /// `+A −R in N files` (binary files count as changed, with no lines).
    static func diffStat(_ files: [(path: String, added: Int?, removed: Int?)]) -> String {
        let added = files.reduce(0) { $0 + ($1.added ?? 0) }, removed = files.reduce(0) { $0 + ($1.removed ?? 0) }
        return "+\(added) \u{2212}\(removed) in \(files.count) \(files.count == 1 ? "file" : "files")"
    }

    static func lineCount(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    static func lines(_ n: Int) -> String { n == 1 ? "1 line" : "\(n) lines" }

    static let languages: [String: String] = [
        "swift": "Swift", "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript",
        "cjs": "JavaScript", "py": "Python", "rb": "Ruby", "go": "Go", "rs": "Rust", "java": "Java", "kt": "Kotlin", "c": "C",
        "h": "C", "cc": "C++", "cpp": "C++", "hpp": "C++", "m": "Objective-C", "mm": "Objective-C++", "cs": "C#", "php": "PHP",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "md": "Markdown", "json": "JSON", "yml": "YAML", "yaml": "YAML",
        "toml": "TOML", "html": "HTML", "css": "CSS", "scss": "SCSS", "sql": "SQL", "txt": "Text",
    ]

    /// The language a path's extension names, or "Text".
    static func language(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "Text" }
        return languages[name[name.index(after: dot)...].lowercased()] ?? "Text"
    }
}
