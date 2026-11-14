import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What one mirror refresh did.
public struct MirrorResult: Equatable, Sendable {
    /// Files written because the handbook changed.
    public var written = 0
    /// Stale or planted files and directories taken out.
    public var removed = 0
    /// Mirror files (relative to `.brahma/kb`) that were changed, removed or planted while the handbook was not, and were put
    /// back.
    public var repaired: [String] = []
    /// Links or odd files found where the mirror writes; each raised the engine-file alert.
    public var unsafe: [UnsafeEngineFile] = []

    public init(written: Int = 0, removed: Int = 0, repaired: [String] = [], unsafe: [UnsafeEngineFile] = []) {
        self.written = written; self.removed = removed; self.repaired = repaired; self.unsafe = unsafe
    }
}

/// The handbook as Markdown files: the owner's export (every page in full) and the agent-readable mirror under
/// `<workspace>/.brahma/kb` (what every agent may read, untainted pages only). Page `A/B` is `A/B.md`; a page with children
/// keeps its own `A.md` beside the `A/` directory. Bodies pass through the redactor (fail closed: `Store.redact`).
public enum HandbookExporter {
    /// The mirror's `README.md`, exactly.
    public static let mirrorReadme = "Read-only mirror of the company handbook for Bash and Read. Edit pages with kb_write."
    static let mirrorRoot = ".brahma/kb"
    /// The `memoryCursor.source` holding the mirror's fingerprint.
    static let mirrorCursor = "mirror"
    /// The first line of every `INDEX.md` the engine writes: `export --force` only empties a folder whose `INDEX.md` has it.
    static let indexHeader = "# Handbook index"

    // MARK: Export

    /// Writes every page (the owner's view) into `dir` with JSON-quoted YAML front matter, plus `INDEX.md`. Returns the number
    /// of files written. `dir` is created when missing; a non-empty one is refused unless `force`, which empties it first
    /// (links in it are removed, never followed). A folder inside a company workspace is refused: agents can read those.
    /// Every file and directory is created with `O_CREAT | O_EXCL | O_NOFOLLOW` (`mkdirat`) relative to its parent's
    /// descriptor.
    @discardableResult
    public static func export(store: Store, companyId: String, to dir: URL, force: Bool) throws -> Int {
        let (pages, handles, workspaces) = try store.writer.read { db -> ([KBPage], [String: String], [String]) in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            let pages = try KBPage.fetchAll(db, sql: "SELECT * FROM kbPage WHERE companyId = ? ORDER BY path COLLATE NOCASE",
                                            arguments: [companyId])
            let handles = Dictionary(try Row.fetchAll(db, sql: "SELECT id, name FROM agent WHERE companyId = ?", arguments: [companyId])
                .map { ($0["id"] as String, $0["name"] as String) }, uniquingKeysWith: { a, _ in a })
            return (pages, handles, try String.fetchAll(db, sql: "SELECT workspacePath FROM company"))
        }
        // Render (and redact) everything before the folder is touched.
        let layout = Layout(pages.map { ($0.id, $0.path) })
        var files: [(relative: String, data: Data)] = []
        for page in pages {
            guard let relative = layout.files[page.id] else { continue }
            let owner = page.ownerId == "owner" || page.ownerId == "system" ? page.ownerId : "@" + (handles[page.ownerId] ?? page.ownerId)
            var fields: [(String, String)] = [
                ("title", quote(try store.redact(page.title))), ("path", quote("kb:\(page.path)")), ("status", quote(page.status.rawValue)),
                ("revision", quote(String(page.revision))), ("updated", quote(iso(page.updatedAt))), ("owner", quote(owner)),
            ]
            if let auto = page.autoKind { fields.append(("auto", quote(auto))) }
            if page.tainted { fields.append(("tainted", quote("true"))) }
            if !page.sources.isEmpty {
                fields.append(("sources", "[" + (try page.sources.map { quote(Store.flat(try store.redact($0), max: Int.max)) })
                    .joined(separator: ",") + "]"))
            }
            files.append((relative, document(fields, body: try store.redact(page.body))))
        }
        files.append(("INDEX.md", try index(pages: pages.map { ($0.id, $0.path, $0.title) }, layout: layout, redact: store.redact)))

        let target = dir.standardizedFileURL
        let real = resolvedPath(target)
        for ws in workspaces {
            guard let w = realpathString(ws) else { continue }
            if real.lowercased() == w.lowercased() || real.lowercased().hasPrefix(w.lowercased() + "/") {
                throw WorkError.invalid("export the handbook to a folder outside the company workspaces: agents can read those")
            }
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
        let rootFD = open(target.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw WorkError.invalid("\(target.path) is not a folder that can be opened") }
        defer { close(rootFD) }
        let existing = try fm.contentsOfDirectory(atPath: target.path)
        if !existing.isEmpty {
            guard force else { throw WorkError.conflict("export folder must be empty (use --force to replace it)") }
            // `--force` replaces an earlier handbook export, never any folder: its `INDEX.md` (a regular file, not a link)
            // must start with the engine's header.
            guard isEarlierExport(rootFD) else {
                throw WorkError.conflict("--force only replaces an earlier handbook export (a folder with its INDEX.md); choose an empty folder")
            }
            for name in existing {
                try EngineFiles.removeEntry(dfd: rootFD, name: name, shown: target.appending(path: name).path)
            }
        }

        var opened: [String: Int32] = ["": rootFD]
        defer { for (k, fd) in opened where !k.isEmpty { close(fd) } }
        func directory(_ relative: String) throws -> Int32 {
            if let fd = opened[relative] { return fd }
            let parts = relative.split(separator: "/").map(String.init)
            let parent = try directory(parts.dropLast().joined(separator: "/"))
            let name = parts.last ?? ""
            guard mkdirat(parent, name, 0o700) == 0 else {
                throw WorkError.invalid("could not create \(relative) in the export folder (\(String(cString: strerror(errno))))")
            }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw WorkError.invalid("could not open \(relative) in the export folder") }
            opened[relative] = fd
            return fd
        }
        for (relative, data) in files {
            let parts = relative.split(separator: "/").map(String.init)
            let dfd = try directory(parts.dropLast().joined(separator: "/"))
            let fd = openat(dfd, parts.last ?? "", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw WorkError.invalid("could not create \(relative) in the export folder (\(String(cString: strerror(errno))))")
            }
            defer { close(fd) }
            try writeAll(fd, data, shown: relative)
        }
        return files.count
    }

    // MARK: Mirror

    /// Brings `<workspace>/.brahma/kb` up to date: company-class pages every agent can read at page level, untainted, with
    /// every section a role-less reader cannot read removed (`KBAccess.companyWide`), redacted, plus `README.md` and
    /// `INDEX.md`. Everything goes through `EngineFiles` (directories walked without following links, files replaced through a
    /// temporary file renamed in the same directory, stale entries removed by descriptor).
    ///
    /// Every refresh first sweeps the mirror (stale, planted or wrong-kind entries go), then re-reads each mirror file and
    /// compares its SHA-256 with what it should hold: when the handbook did not change (the fingerprint of every page's id,
    /// revision, taint, vouch, status and restriction, and the redactor's version, matches the stored one), a difference — a
    /// changed, missing or planted file — is put back, listed in `repaired` and noted in the activity feed.
    ///
    /// It fails closed: old content (perhaps a section restricted since) never stays readable.
    /// - Any `UnsafeEngineFile` while sweeping (a link, an entry that cannot be inspected, listed or removed, one nested too
    ///   deeply or that kept changing) is treated as planted, as is one in the way of a write: the engine-file alert, the whole
    ///   mirror removed (by descriptor: a link is unlinked, never followed), the cursor reset, so the next refresh rebuilds it.
    /// - Any other failure (the content cannot be built, the engine's own write fails: a full disk) also removes the mirror,
    ///   alerts when there was one to remove, and is rethrown for the caller to trace.
    @discardableResult
    public static func mirror(store: Store, companyId: String, workspace: URL, now: Date = Store.now()) throws -> MirrorResult {
        try mirror(store: store, companyId: companyId, workspace: workspace, now: now, fault: nil)
    }

    /// Where a test injects a failure: the sweep (listing, inspecting, removing) or the writes.
    enum MirrorPhase { case sweep, write }

    static func mirror(store: Store, companyId: String, workspace: URL, now: Date,
                       fault: ((MirrorPhase, String) throws -> Void)?) throws -> MirrorResult {
        var result = MirrorResult()
        func flag(_ problem: UnsafeEngineFile) {
            guard !result.unsafe.contains(problem) else { return }
            result.unsafe.append(problem)
            store.alertEngineFile(problem, companyId: companyId, now: now)
        }
        let content: (files: [String: Data], dirs: [String], fingerprint: String)
        let stored: String
        do {
            content = try mirrorContent(store: store, companyId: companyId)
            stored = try store.writer.read { db in try Store.memoryCursorPosition(db: db, companyId: companyId, source: mirrorCursor) }
        } catch {
            failClosed(store: store, companyId: companyId, workspace: workspace, now: now, because: error)
            throw error
        }
        let changed = stored != content.fingerprint
        var notes: [String] = []
        func note(_ relative: String) {
            result.repaired.append(relative)
            notes.append("repaired a changed handbook mirror file \(mirrorRoot)/\(relative)")
        }
        func base(_ relative: String) -> String { relative.isEmpty ? mirrorRoot : "\(mirrorRoot)/\(relative)" }

        do {
            // Sweep: anything that is not an expected directory or file, or not of the expected kind (compared as the file
            // system may: folded), goes: stale pages, planted files, a directory where a file belongs. Every problem here is
            // treated as planted.
            do {
                try EngineFiles.directory(workspace: workspace, mirrorRoot)
                let dirKeys = Set(content.dirs.map(Layout.fold)), fileKeys = Set(content.files.keys.map(Layout.fold))
                func sweep(_ relative: String, depth: Int) throws {
                    try fault?(.sweep, relative)
                    let dir = try EngineFiles.openWalked(workspace: workspace, base(relative))
                    for name in try dir.names().sorted() {
                        let child = relative.isEmpty ? name : "\(relative)/\(name)"
                        let key = Layout.fold(child)
                        let kind = dir.kind(of: name)
                        switch kind {
                        case .directory where dirKeys.contains(key) && depth < HandbookPath.maxSegments: try sweep(child, depth: depth + 1)
                        case .other where fileKeys.contains(key): continue
                        default:
                            if kind == .link, dirKeys.contains(key) || fileKeys.contains(key) {
                                flag(UnsafeEngineFile(path: workspace.appending(path: "\(base(relative))/\(name)").path,
                                                      problem: "is a symbolic link"))
                            }
                            try fault?(.sweep, child)
                            try EngineFiles.remove(workspace: workspace, dir: base(relative), name: name)
                            result.removed += 1
                            if !changed { note(child) }
                        }
                    }
                }
                try sweep("", depth: 0)
            } catch let problem as UnsafeEngineFile {
                throw Planted(problem: problem)
            }
            // Writes. A link or odd file in the way is planted; the engine's own failure is not.
            for dir in content.dirs { try EngineFiles.directory(workspace: workspace, base(dir)) }
            for (relative, data) in content.files.sorted(by: { $0.key < $1.key }) {
                let parent = relative.contains("/") ? String(relative[..<relative.lastIndex(of: "/")!]) : ""
                let name = String(relative.split(separator: "/").last ?? "")
                var current: Data?
                switch try EngineFiles.entry(workspace: workspace, dir: base(parent), name: name) {
                case .missing: current = nil
                case .regular: current = try EngineFiles.read(workspace: workspace, dir: base(parent), name: name, limit: data.count + 1)
                case .unsafe(let problem):
                    flag(problem)
                    current = nil
                }
                if let current, SHA256.hex(current) == SHA256.hex(data) { continue }
                try fault?(.write, relative)
                if let problem = try EngineFiles.replace(data, workspace: workspace, dir: base(parent), name: name) { flag(problem) }
                if changed { result.written += 1 } else if !result.repaired.contains(relative) { note(relative) }
            }
        } catch let planted as Planted {
            flag(planted.problem)
            removeMirror(store: store, companyId: companyId, workspace: workspace)
            return result
        } catch let problem as UnsafeEngineFile where isPlanted(problem) {
            flag(problem)
            removeMirror(store: store, companyId: companyId, workspace: workspace)
            return result
        } catch {
            failClosed(store: store, companyId: companyId, workspace: workspace, now: now, because: error)
            throw error
        }
        try store.writer.write { db in
            for text in notes {
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .work, text: text, createdAt: now).insert(db)
            }
            try Store.setMemoryCursorPosition(db: db, companyId: companyId, source: mirrorCursor, content.fingerprint)
        }
        return result
    }

    /// A sweep problem, carried out of the sweep to the planted path.
    private struct Planted: Error { var problem: UnsafeEngineFile }

    /// The reason that keys the alert about a mirror that could not be rebuilt and was removed.
    public static let mirrorAlertReason = "handbook-mirror"

    /// The mirror is removed (by descriptor; a link is unlinked, never followed) and its cursor reset, so the next refresh
    /// rebuilds it from scratch. Returns whether something was there. A removal that fails is reported on standard error (the
    /// caller has raised, or raises, an alert).
    @discardableResult
    static func removeMirror(store: Store, companyId: String, workspace: URL) -> Bool {
        var existed = true
        do {
            existed = try EngineFiles.entry(workspace: workspace, dir: ".brahma", name: "kb") != .missing
            if existed { try EngineFiles.remove(workspace: workspace, dir: ".brahma", name: "kb") }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not remove the handbook mirror of \(companyId): \(error)\n".utf8))
        }
        do {
            try store.writer.write { db in try Store.setMemoryCursorPosition(db: db, companyId: companyId, source: mirrorCursor, "") }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not reset the handbook mirror cursor of \(companyId): \(error)\n".utf8))
        }
        return existed
    }

    /// The mirror cannot be rebuilt: its old files go (nothing stale stays readable) and, when there were any, the owner is
    /// alerted. The caller rethrows `error` for its trace.
    static func failClosed(store: Store, companyId: String, workspace: URL, now: Date, because error: any Error) {
        guard removeMirror(store: store, companyId: companyId, workspace: workspace) else { return }
        let text = "The handbook mirror in .brahma/kb could not be rebuilt (\(Store.flat("\(error)", max: 300))); its old files were "
            + "removed so nothing stale stays readable. The next refresh tries again."
        do {
            try EngineAlerts.raise(store: store, text: text, now: now, reason: mirrorAlertReason, companyId: companyId)
        } catch {
            FileHandle.standardError.write(Data("brahma: \(text) (and the alert failed: \(error))\n".utf8))
        }
    }

    /// The mirror's files (relative to `.brahma/kb`), its directories (parents first) and its fingerprint.
    static func mirrorContent(store: Store, companyId: String) throws -> (files: [String: Data], dirs: [String], fingerprint: String) {
        let ctx = KBAccess.companyWide(companyId: companyId)
        let (pages, fingerprintInput) = try store.writer.read { db -> ([KBPage], String) in
            let all = try KBPage.fetchAll(db, sql: "SELECT * FROM kbPage WHERE companyId = ? ORDER BY path COLLATE NOCASE",
                                          arguments: [companyId])
            let rows = all.map { p in
                [p.id, String(p.revision), p.tainted ? "1" : "0", p.vouchedAt.map { String($0.timeIntervalSince1970) } ?? "-",
                 p.status.rawValue, (p.restriction ?? []).sorted().joined(separator: ",")].joined(separator: "\u{1F}")
            }.sorted()
            return (all, rows.joined(separator: "\u{1E}"))
        }
        let fingerprint = StableHash.fnv1a64(fingerprintInput + "\u{1D}" + store.redactor.version)
        let shown = pages.filter { !$0.tainted && KBAccess.canReadPage($0, ctx: ctx) }
        let layout = Layout(shown.map { ($0.id, $0.path) })
        var files: [String: Data] = [:]
        for page in shown {
            guard let relative = layout.files[page.id] else { continue }
            let lines = KBMarkdown.lines(page.body)
            var kept: [String] = []
            var hidden = 0
            for loc in KBMarkdown.located(page.body, page: page.pageRestriction) {
                if KBAccess.canRead(loc.section, ctx: ctx) { kept += lines[loc.lineRange] } else { hidden += 1 }
            }
            var text = kept.joined(separator: "\n")
            if hidden > 0 { text += "\n\n_\(hidden) restricted section(s) not shown._" }
            let fields: [(String, String)] = [
                ("title", quote(try store.redact(page.title))), ("path", quote("kb:\(page.path)")), ("status", quote(page.status.rawValue)),
                ("revision", quote(String(page.revision))), ("updated", quote(iso(page.updatedAt))),
            ]
            files[relative] = document(fields, body: try store.redact(text))
        }
        files["README.md"] = Data(mirrorReadme.utf8)
        files["INDEX.md"] = try index(pages: shown.map { ($0.id, $0.path, $0.title) }, layout: layout, redact: store.redact)
        return (files, layout.dirs, fingerprint)
    }

    /// For the writes (after the sweep, where every problem counts as planted): whether `problem` is something found in the
    /// way (a link, a hard link, another user's or odd file, a directory moved during the walk, a directory where the file
    /// goes) rather than a failure of the engine's own write (a refused name, a full disk). Either way the mirror is removed.
    static func isPlanted(_ problem: UnsafeEngineFile) -> Bool {
        ["symbolic link", "is not a directory", "another hard link", "owned by another user", "not a regular file", "moved",
         "is a directory, not a file"]
            .contains { problem.problem.contains($0) }
    }

    // MARK: Layout and rendering

    /// Where each page's file goes. Directories are spelled as the first page that needs them spells them (paths compare
    /// case-insensitively, and so may the file system); a file name already taken, by a file or a directory, gets ` (2)`, ` (3)` ….
    /// Every name is the engine's own and always writable: a directory never takes a name of the engine's files
    /// (`README.md`, `INDEX.md`: it becomes `<name> (dir)`), and a part longer than `maxNameBytes` UTF-8 bytes is cut and given
    /// a hash of the whole part, so a name with its suffix and `EngineFiles.replace`'s temporary name stays under the file
    /// system's 255 bytes (and six levels stay well under its path limit).
    struct Layout {
        /// Page id → relative file path.
        var files: [String: String] = [:]
        /// Every directory, parents first.
        var dirs: [String] = []

        static let maxNameBytes = 120
        /// Names the engine's own files take, folded.
        static let reserved: Set<String> = ["readme.md", "index.md"]

        static func fold(_ path: String) -> String { HandbookPath.foldKey(path) }

        /// `part`, or (when longer than `maxNameBytes` bytes) its longest prefix that leaves room for `~<16 hex>`, plus that
        /// hash of the whole part. Deterministic.
        static func capped(_ part: String) -> String {
            guard part.utf8.count > maxNameBytes else { return part }
            let hash = "~" + StableHash.fnv1a64(part)
            var out = ""
            for ch in part {
                guard out.utf8.count + String(ch).utf8.count + hash.utf8.count <= maxNameBytes else { break }
                out.append(ch)
            }
            return out + hash
        }

        static func directoryName(_ part: String) -> String {
            let name = capped(part)
            return reserved.contains(fold(name)) ? capped(name + " (dir)") : name
        }

        init(_ pages: [(id: String, path: String)]) {
            var spelled: [String: String] = [:]
            func dirPath(_ parts: ArraySlice<String>) -> String {
                var path = ""
                for part in parts {
                    let name = Self.directoryName(part)
                    let candidate = path.isEmpty ? name : "\(path)/\(name)"
                    let key = Self.fold(candidate)
                    if let known = spelled[key] { path = known } else {
                        spelled[key] = candidate
                        dirs.append(candidate)
                        path = candidate
                    }
                }
                return path
            }
            let sorted = pages.sorted { $0.path.lowercased() < $1.path.lowercased() }
            for page in sorted { _ = dirPath(page.path.split(separator: "/").map(String.init).dropLast()) }
            var taken = Set(dirs.map(Self.fold)).union(Self.reserved)
            for page in sorted {
                let parts = page.path.split(separator: "/").map(String.init)
                let dir = dirPath(parts.dropLast())
                let stem = Self.capped(parts.last ?? page.path)
                var n = 1
                while true {
                    let name = n == 1 ? "\(stem).md" : "\(stem) (\(n)).md"
                    let relative = dir.isEmpty ? name : "\(dir)/\(name)"
                    if taken.insert(Self.fold(relative)).inserted {
                        files[page.id] = relative
                        break
                    }
                    n += 1
                }
            }
        }
    }

    /// `---`, one `key: value` line per field, `---`, the body (ending in a newline).
    static func document(_ fields: [(String, String)], body: String) -> Data {
        var text = "---\n" + fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n---\n" + body
        if !text.hasSuffix("\n") { text += "\n" }
        return Data(text.utf8)
    }

    /// `INDEX.md`: the pages as a tree of links, two spaces per level; a level with no page of its own is plain text.
    static func index(pages: [(id: String, path: String, title: String)], layout: Layout, redact: (String) throws -> String) throws -> Data {
        final class Node {
            var name: String
            var page: (id: String, title: String)?
            var children: [String: Node] = [:]
            init(_ name: String) { self.name = name }
        }
        let root = Node("")
        for p in pages {
            var node = root
            for part in p.path.split(separator: "/").map(String.init) {
                let key = Layout.fold(part)
                if let next = node.children[key] { node = next } else {
                    let next = Node(part)
                    node.children[key] = next
                    node = next
                }
            }
            node.page = (p.id, p.title)
        }
        var lines = [indexHeader, ""]
        // Fail closed: text the redactor cannot check is never written.
        func walk(_ node: Node, depth: Int) throws {
            for child in node.children.values.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                let indent = String(repeating: "  ", count: depth)
                if let page = child.page, let file = layout.files[page.id] {
                    lines.append("\(indent)- [\(MarkdownEscape.inline(try redact(page.title)))](\(linkTarget(file)))")
                } else {
                    lines.append("\(indent)- \(MarkdownEscape.inline(try redact(child.name)))")
                }
                try walk(child, depth: depth + 1)
            }
        }
        try walk(root, depth: 0)
        if pages.isEmpty { lines.append("No pages yet.") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// A relative link, percent-encoded but for letters, digits, `-._~` and `/`.
    static func linkTarget(_ relative: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return relative.addingPercentEncoding(withAllowedCharacters: allowed) ?? relative
    }

    /// `text` as a JSON string literal: quotes, backslashes and every control, line- or paragraph-separator character escaped,
    /// so a value can never end its line or open a new key.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                let v = scalar.value
                if v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029 {
                    out += String(format: "\\u%04x", v)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: Files

    private static func writeAll(_ fd: Int32, _ data: Data, shown: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WorkError.invalid("could not write \(shown) in the export folder (\(String(cString: strerror(errno))))")
                }
                offset += n
            }
        }
    }

    /// Whether the folder open at `dfd` holds an `INDEX.md` the engine wrote: a regular file (opened without following a
    /// link) whose first line is `indexHeader`.
    static func isEarlierExport(_ dfd: Int32) -> Bool {
        let fd = openat(dfd, "INDEX.md", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return false }
        var buffer = [UInt8](repeating: 0, count: indexHeader.utf8.count + 1)
        let n = read(fd, &buffer, buffer.count)
        guard n == buffer.count else { return false }
        return Array(buffer) == Array((indexHeader + "\n").utf8)
    }

    private static func realpathString(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// `url` with its longest existing ancestor resolved (links followed: this is the owner's choice of folder).
    private static func resolvedPath(_ url: URL) -> String {
        var existing = url
        var rest: [String] = []
        while realpathString(existing.path) == nil, existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let base = realpathString(existing.path) ?? existing.path
        return ([base] + rest).joined(separator: "/")
    }
}
