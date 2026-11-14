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
        files.append(("INDEX.md", index(pages: pages.map { ($0.id, $0.path, $0.title) }, layout: layout, redact: store.redact)))

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
    /// Every refresh re-reads each mirror file and compares its SHA-256 with what it should hold: when the handbook did not
    /// change (the fingerprint of every page's id, revision, taint, vouch, status and restriction, and the redactor's version,
    /// matches the stored one), a difference — a changed, missing or planted file — is put back, listed in `repaired` and
    /// noted in the activity feed. A link or odd file in the way stops the mirror for this refresh, raises the engine-file
    /// alert and removes the planted entry (the link itself, never what it points at), so the next refresh rebuilds it;
    /// nothing outside the workspace is touched.
    @discardableResult
    public static func mirror(store: Store, companyId: String, workspace: URL, now: Date = Store.now()) throws -> MirrorResult {
        let content = try mirrorContent(store: store, companyId: companyId)
        let stored = try store.writer.read { db in
            try Store.memoryCursorPosition(db: db, companyId: companyId, source: mirrorCursor)
        }
        let changed = stored != content.fingerprint
        var result = MirrorResult()
        var notes: [String] = []
        func note(_ relative: String) {
            result.repaired.append(relative)
            notes.append("repaired a changed handbook mirror file \(mirrorRoot)/\(relative)")
        }
        func base(_ relative: String) -> String { relative.isEmpty ? mirrorRoot : "\(mirrorRoot)/\(relative)" }

        do {
            try EngineFiles.directory(workspace: workspace, mirrorRoot)
            for dir in content.dirs { try EngineFiles.directory(workspace: workspace, base(dir)) }
            for (relative, data) in content.files.sorted(by: { $0.key < $1.key }) {
                let parent = relative.contains("/") ? String(relative[..<relative.lastIndex(of: "/")!]) : ""
                let name = String(relative.split(separator: "/").last ?? "")
                var current: Data?
                switch try EngineFiles.entry(workspace: workspace, dir: base(parent), name: name) {
                case .missing: current = nil
                case .regular: current = try EngineFiles.read(workspace: workspace, dir: base(parent), name: name, limit: data.count + 1)
                case .unsafe(let problem):
                    result.unsafe.append(problem)
                    store.alertEngineFile(problem, companyId: companyId, now: now)
                    current = nil
                }
                if let current, SHA256.hex(current) == SHA256.hex(data) { continue }
                if let problem = try EngineFiles.replace(data, workspace: workspace, dir: base(parent), name: name),
                   !result.unsafe.contains(problem) {
                    result.unsafe.append(problem)
                    store.alertEngineFile(problem, companyId: companyId, now: now)
                }
                if changed { result.written += 1 } else { note(relative) }
            }
            // Stale entries: anything that is not an expected directory or file (compared as the file system may: folded).
            let dirKeys = Set(content.dirs.map(Layout.fold)), fileKeys = Set(content.files.keys.map(Layout.fold))
            func sweep(_ relative: String, depth: Int) throws {
                let dir = try EngineFiles.openWalked(workspace: workspace, base(relative))
                for name in try dir.names().sorted() {
                    let child = relative.isEmpty ? name : "\(relative)/\(name)"
                    let key = Layout.fold(child)
                    switch dir.kind(of: name) {
                    case .directory where dirKeys.contains(key) && depth < HandbookPath.maxSegments: try sweep(child, depth: depth + 1)
                    case .other where fileKeys.contains(key): continue
                    default:
                        try EngineFiles.remove(workspace: workspace, dir: base(relative), name: name)
                        result.removed += 1
                        if !changed { note(child) }
                    }
                }
            }
            try sweep("", depth: 0)
        } catch let problem as UnsafeEngineFile {
            result.unsafe.append(problem)
            store.alertEngineFile(problem, companyId: companyId, now: now)
            // The planted entry goes (by descriptor: a link is unlinked, never followed) and the mirror is rebuilt next time.
            do {
                try EngineFiles.remove(workspace: workspace, dir: ".brahma", name: "kb")
            } catch {
                FileHandle.standardError.write(Data("brahma: could not remove the handbook mirror: \(error)\n".utf8))
            }
            try store.writer.write { db in
                try Store.setMemoryCursorPosition(db: db, companyId: companyId, source: mirrorCursor, "")
            }
            return result
        }
        try store.writer.write { db in
            for text in notes {
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .work, text: text, createdAt: now).insert(db)
            }
            try Store.setMemoryCursorPosition(db: db, companyId: companyId, source: mirrorCursor, content.fingerprint)
        }
        return result
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
        files["INDEX.md"] = index(pages: shown.map { ($0.id, $0.path, $0.title) }, layout: layout, redact: store.redact)
        return (files, layout.dirs, fingerprint)
    }

    // MARK: Layout and rendering

    /// Where each page's file goes. Directories are spelled as the first page that needs them spells them (paths compare
    /// case-insensitively, and so may the file system); a file name already taken, by a file or a directory, gets ` (2)`, ` (3)` ….
    struct Layout {
        /// Page id → relative file path.
        var files: [String: String] = [:]
        /// Every directory, parents first.
        var dirs: [String] = []

        static func fold(_ path: String) -> String { HandbookPath.foldKey(path) }

        init(_ pages: [(id: String, path: String)]) {
            var spelled: [String: String] = [:]
            func dirPath(_ parts: ArraySlice<String>) -> String {
                var path = ""
                for part in parts {
                    let candidate = path.isEmpty ? part : "\(path)/\(part)"
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
            var taken = Set(dirs.map(Self.fold)).union(["index.md", "readme.md"])
            for page in sorted {
                let parts = page.path.split(separator: "/").map(String.init)
                let dir = dirPath(parts.dropLast())
                let stem = parts.last ?? page.path
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
    static func index(pages: [(id: String, path: String, title: String)], layout: Layout, redact: (String) throws -> String) -> Data {
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
        var lines = ["# Handbook index", ""]
        func walk(_ node: Node, depth: Int) {
            for child in node.children.values.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                let indent = String(repeating: "  ", count: depth)
                if let page = child.page, let file = layout.files[page.id] {
                    let title = (try? redact(page.title)) ?? child.name
                    lines.append("\(indent)- [\(MarkdownEscape.inline(title))](\(linkTarget(file)))")
                } else {
                    lines.append("\(indent)- \(MarkdownEscape.inline(child.name))")
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
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
