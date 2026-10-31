import Foundation

// The extension package format (Task 5a, skill-only): a valid Claude Code plugin folder whose `.claude-plugin/plugin.json`
// holds exactly `name`, `version`, `description` and `author`, plus the optional `brahma.json` sidecar (5-lite subset) and
// the generated `ext.lock.json`. Everything here is pure data and hashing; the allowlist lives in `ExtensionValidator`.

/// The staging limits (global constraints table: `ExtensionLimits`).
public enum ExtensionLimits {
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxFiles = 2000
    public static let maxDescription = 1024
    /// The largest text file the lint scans whole (bigger ones are hashed only).
    public static let maxScannedBytes = 2 * 1024 * 1024

    /// Unicode scalars that hide or reorder text: zero-width, bidi controls, soft hyphen, word joiner and the like.
    public static func isHiddenOrBidi(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF, 0x00AD, 0x061C, 0x180E, 0xFFF9...0xFFFB:
            return true
        default:
            return false
        }
    }

    /// A path component a package may use: no control, hidden or bidi character, no separator, not `.` or `..`.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return false }
        return !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || isHiddenOrBidi($0) }
    }
}

/// The id rule: `^[a-z][a-z0-9-]{0,39}$`, never containing `anthropic` or `claude`.
public enum ExtensionId {
    public static let pattern = "^[a-z][a-z0-9-]{0,39}$"

    public static func problem(_ id: String) -> String? {
        guard id.range(of: pattern, options: .regularExpression) != nil else {
            return "id '\(Store.flat(id, max: 60))' must match \(pattern)"
        }
        for word in ["anthropic", "claude"] where id.contains(word) { return "id '\(id)' may not contain '\(word)'" }
        return nil
    }

    public static func isValid(_ id: String) -> Bool { problem(id) == nil }
}

/// A pack's (or a grant's) reference to an extension: bound only when the installed record's verified publisher matches.
public struct ExtensionRef: Codable, Equatable, Hashable, Sendable {
    public var publisher: String
    public var id: String
    public var version: String? = nil

    public init(publisher: String, id: String, version: String? = nil) {
        self.publisher = publisher; self.id = id; self.version = version
    }

    /// `<publisher>/<id>`, the grant value form.
    public var key: String { "\(publisher)/\(id)" }

    /// Parses `<publisher>/<id>` (the publisher may itself hold `/` and `:`; the id is the last component).
    public static func parse(_ text: String) -> ExtensionRef? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        let publisher = String(text[..<slash]), id = String(text[text.index(after: slash)...])
        guard !publisher.isEmpty, ExtensionId.isValid(id), ExtensionPublisher.isValid(publisher) else { return nil }
        return ExtensionRef(publisher: publisher, id: id)
    }
}

/// Publisher values the installer writes (never read from a package).
public enum ExtensionPublisher {
    public static let brahma = "brahma"
    public static let local = "local"
    public static func company(_ slug: String) -> String { "company:\(slug)" }
    public static func claudeCode(marketplace: String) -> String { "third-party:claude-code/\(marketplace)" }

    /// `brahma` and `company:<slug>` parts mount on every profile; `third-party:*` and `local` only on Sandboxed (§4.4).
    public static func isFirstParty(_ publisher: String) -> Bool {
        publisher == brahma || publisher.hasPrefix("company:")
    }

    public static func isValid(_ publisher: String) -> Bool {
        publisher == brahma || publisher == local || publisher.hasPrefix("company:") || publisher.hasPrefix("third-party:")
    }
}

/// `.claude-plugin/plugin.json`: exactly the four keys.
public struct ExtensionManifest: Equatable, Sendable {
    public static let path = ".claude-plugin/plugin.json"
    public static let keys = ["name", "version", "description", "author"]

    public var name: String
    public var version: String
    public var description: String
    public var author: JSONValue

    public init(name: String, version: String, description: String, author: JSONValue) {
        self.name = name; self.version = version; self.description = description; self.author = author
    }

    /// The parsed manifest, the keys beyond the four, and the four that are missing or not of the right type.
    public struct Parsed: Sendable {
        public var manifest: ExtensionManifest?
        public var extraKeys: [String]
        public var problems: [String]
        public var object: [String: JSONValue]
    }

    public static func parse(_ data: Data) -> Parsed {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let object = value.objectValue else {
            return Parsed(manifest: nil, extraKeys: [], problems: ["plugin.json is not a JSON object"], object: [:])
        }
        let extra = object.keys.filter { !keys.contains($0) }.sorted()
        var problems: [String] = []
        func text(_ key: String) -> String? {
            guard let v = object[key] else { problems.append("plugin.json lacks \(key)"); return nil }
            guard let s = v.stringValue else { problems.append("plugin.json \(key) must be a string"); return nil }
            return s
        }
        let name = text("name"), version = text("version"), description = text("description")
        guard let author = object["author"] else {
            problems.append("plugin.json lacks author")
            return Parsed(manifest: nil, extraKeys: extra, problems: problems, object: object)
        }
        if author.stringValue == nil, author.objectValue == nil { problems.append("plugin.json author must be a string or an object") }
        guard let name, let version, let description, problems.isEmpty else {
            return Parsed(manifest: nil, extraKeys: extra, problems: problems, object: object)
        }
        return Parsed(manifest: ExtensionManifest(name: name, version: version, description: description, author: author),
                      extraKeys: extra, problems: [], object: object)
    }

    /// The manifest of a package root; throws when it is missing or not the four keys.
    public static func read(_ root: URL) throws -> ExtensionManifest {
        guard let data = FileManager.default.contents(atPath: root.appending(path: path).path) else {
            throw ExtensionError.message("no \(path)")
        }
        let p = parse(data)
        guard let m = p.manifest else { throw ExtensionError.message(p.problems.joined(separator: "; ")) }
        return m
    }

    /// The four keys, sorted, pretty-printed.
    public func json() -> Data {
        let object: JSONValue = .object(["name": .string(name), "version": .string(version), "description": .string(description), "author": author])
        return ExtensionJSON.encode(object)
    }
}

/// Stable JSON encoding (sorted keys, pretty) for files the engine writes.
enum ExtensionJSON {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? e.encode(value)) ?? Data()
    }
}

/// `brahma.json`, the 5-lite subset: `brahma: 1`, `agentNetwork`, `requires.hostTools`, `suits.roles[].role` and `suits.tags`.
/// `connector` and `metering` are refused ("connector parts need a later Brahma (X-connectors)").
public struct BrahmaSidecar: Codable, Equatable, Sendable {
    public static let path = "brahma.json"
    public static let connectorRefusal = "connector parts need a later Brahma (X-connectors)"

    public var agentNetwork: [String] = []
    public var hostTools: [String] = []
    public var suitsRoles: [String] = []
    public var suitsTags: [String] = []

    public init(agentNetwork: [String] = [], hostTools: [String] = [], suitsRoles: [String] = [], suitsTags: [String] = []) {
        self.agentNetwork = agentNetwork; self.hostTools = hostTools; self.suitsRoles = suitsRoles; self.suitsTags = suitsTags
    }

    /// The sidecar and what is wrong with it (every problem refuses the package).
    public static func parse(_ data: Data) -> (sidecar: BrahmaSidecar?, problems: [String]) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let object = value.objectValue else {
            return (nil, ["brahma.json is not a JSON object"])
        }
        var problems: [String] = []
        if object["connector"] != nil || object["metering"] != nil { problems.append(connectorRefusal) }
        let allowed: Set<String> = ["brahma", "agentNetwork", "requires", "suits"]
        for key in object.keys.sorted() where !allowed.contains(key) && key != "connector" && key != "metering" {
            problems.append("brahma.json key '\(Store.flat(key, max: 40))' is not part of format 1")
        }
        if object["brahma"]?.numberValue != 1 { problems.append("brahma.json must declare \"brahma\": 1") }
        var s = BrahmaSidecar()
        if let net = object["agentNetwork"] {
            guard let list = net.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                problems.append("brahma.json agentNetwork must be a list of domains"); return (nil, problems)
            }
            for d in list.compactMap(\.stringValue) {
                do { try SandboxDomains.check(d); s.agentNetwork.append(SandboxDomains.normalize(d)) } catch {
                    problems.append("brahma.json agentNetwork: \(error)")
                }
            }
            s.agentNetwork = Array(Set(s.agentNetwork)).sorted()
        }
        if let requires = object["requires"] {
            guard let r = requires.objectValue, r.keys.allSatisfy({ $0 == "hostTools" }) else {
                problems.append("brahma.json requires may hold only hostTools"); return (nil, problems)
            }
            if let tools = r["hostTools"] {
                guard let list = tools.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                    problems.append("brahma.json requires.hostTools must be a list of names"); return (nil, problems)
                }
                for t in list.compactMap(\.stringValue) {
                    guard t.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}(>=[0-9][0-9.]*)?$", options: .regularExpression) != nil else {
                        problems.append("brahma.json hostTools: '\(Store.flat(t, max: 40))' is not a tool name"); continue
                    }
                    s.hostTools.append(t)
                }
            }
        }
        if let suits = object["suits"] {
            guard let o = suits.objectValue, o.keys.allSatisfy({ $0 == "roles" || $0 == "tags" }) else {
                problems.append("brahma.json suits may hold only roles and tags"); return (nil, problems)
            }
            for role in o["roles"]?.arrayValue ?? [] {
                guard let r = role.objectValue, r.keys.allSatisfy({ $0 == "role" }), let name = r["role"]?.stringValue else {
                    problems.append("brahma.json suits.roles entries hold only role"); continue
                }
                s.suitsRoles.append(name)
            }
            s.suitsTags = (o["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        return (problems.isEmpty ? s : nil, problems)
    }

    public static func read(_ root: URL) -> (sidecar: BrahmaSidecar?, problems: [String])? {
        guard let data = FileManager.default.contents(atPath: root.appending(path: path).path) else { return nil }
        return parse(data)
    }
}

/// What the lint worked out about a package (never authored): stored on the package row and in the lock.
public struct LintFacts: Codable, Equatable, Sendable {
    public struct Executes: Codable, Equatable, Sendable {
        public var bin = false
        public var scripts = false
        public var bangInjection = false
        public init(bin: Bool = false, scripts: Bool = false, bangInjection: Bool = false) {
            self.bin = bin; self.scripts = scripts; self.bangInjection = bangInjection
        }
    }
    public var executes = Executes()
    public var hosts: [String] = []
    public var alwaysOnTokens: Int = 0
    public var parts: [String] = []
    public var skills: [String] = []
    public var commands: [String] = []
    public var agents: [String] = []
    /// `<path>: <key>` for each frontmatter key stripped (or that `--fix` would strip).
    public var stripped: [String] = []
    public var hiddenUnicode: [String] = []

    public init() {}

    /// The part of the facts the lock carries.
    public struct LockSummary: Codable, Equatable, Sendable {
        public var executes: Executes
        public var hosts: [String]
        public var alwaysOnTokens: Int
    }
    public var lockSummary: LockSummary { LockSummary(executes: executes, hosts: hosts, alwaysOnTokens: alwaysOnTokens) }
}

/// `ext.lock.json` (format 1): generated, never hand-edited. `tools` is the connector `tools/list` slot, empty in 5-lite.
public struct ExtensionLock: Codable, Equatable, Sendable {
    public static let path = "ext.lock.json"

    public struct FileEntry: Codable, Equatable, Sendable {
        public var path: String
        /// `%04o` of the permission bits.
        public var mode: String
        public var sha256: String
    }

    public var format: Int = 1
    public var id: String
    public var version: String
    public var treeSha256: String
    public var files: [FileEntry]
    public var lint: LintFacts.LockSummary
    public var tools: [JSONValue] = []

    /// The regular files of a package root, sorted by path, with their modes and content hashes (the lock itself left out).
    /// A mode is recorded as `0755` when any execute bit is set, else `0644`: the read-only materialized copies (0555/0444)
    /// hash the same as the staged tree. Links and odd files are listed with `sha256` "-" so a tree holding one never
    /// hashes like a clean one.
    public static func entries(root: URL) throws -> [FileEntry] {
        var out: [FileEntry] = []
        for file in try PackageWalk.files(root: root) {
            if file.relative == path { continue }
            switch file.kind {
            case .regular:
                guard let data = FileManager.default.contents(atPath: file.url.path) else {
                    throw ExtensionError.message("cannot read \(file.relative)")
                }
                out.append(FileEntry(path: file.relative, mode: (file.mode & 0o111) != 0 ? "0755" : "0644", sha256: SHA256.hex(data)))
            default:
                out.append(FileEntry(path: file.relative, mode: (file.mode & 0o111) != 0 ? "0755" : "0644", sha256: "-"))
            }
        }
        return out
    }

    /// The SHA-256 over the sorted `<relativePath> <mode> <sha256(content)>` lines, `ext.lock.json` excluded.
    public static func treeHash(root: URL) throws -> String {
        treeHash(entries: try entries(root: root))
    }

    public static func treeHash(entries: [FileEntry]) -> String {
        SHA256.hex(entries.map { "\($0.path) \($0.mode) \($0.sha256)\n" }.joined())
    }

    public static func generate(root: URL, id: String, version: String, lint: LintFacts) throws -> ExtensionLock {
        let entries = try entries(root: root)
        return ExtensionLock(id: id, version: version, treeSha256: treeHash(entries: entries), files: entries, lint: lint.lockSummary)
    }

    public static func read(root: URL) -> ExtensionLock? {
        guard let data = FileManager.default.contents(atPath: root.appending(path: path).path) else { return nil }
        return try? JSONDecoder().decode(ExtensionLock.self, from: data)
    }

    public func write(to root: URL) throws {
        try ExtensionJSON.encode(self).write(to: root.appending(path: Self.path))
    }

    /// Equal apart from `lint.alwaysOnTokens`, which only Claude's own `details` run knows.
    public func matches(_ other: ExtensionLock) -> Bool {
        var a = self, b = other
        a.lint.alwaysOnTokens = 0; b.lint.alwaysOnTokens = 0
        return a == b
    }
}

/// One file of a package, as `PackageWalk` lists it.
struct PackageFile: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case regular, directory, link, other }
    var relative: String
    var url: URL
    var kind: Kind
    var mode: mode_t
    var size: Int64
    var nlink: Int
}

/// Walks a package root without following links (lstat on every entry), sorted by relative path, directories included.
enum PackageWalk {
    static func files(root: URL, includeDirectories: Bool = false) throws -> [PackageFile] {
        var out: [PackageFile] = []
        try walk(root: root, relative: "", into: &out, includeDirectories: includeDirectories, depth: 0)
        return out.sorted { $0.relative < $1.relative }
    }

    private static func walk(root: URL, relative: String, into out: inout [PackageFile], includeDirectories: Bool, depth: Int) throws {
        guard depth < 32 else { throw ExtensionError.message("the package nests deeper than 32 directories") }
        let dir = relative.isEmpty ? root : root.appending(path: relative)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw ExtensionError.message("cannot list \(relative.isEmpty ? "the package" : relative)")
        }
        for name in names.sorted() {
            let rel = relative.isEmpty ? name : relative + "/" + name
            let url = root.appending(path: rel)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw ExtensionError.message("cannot stat \(rel)") }
            let kind: PackageFile.Kind
            switch st.st_mode & S_IFMT {
            case S_IFREG: kind = .regular
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .link
            default: kind = .other
            }
            let file = PackageFile(relative: rel, url: url, kind: kind, mode: st.st_mode, size: Int64(st.st_size), nlink: Int(st.st_nlink))
            if kind == .directory {
                if includeDirectories { out.append(file) }
                try walk(root: root, relative: rel, into: &out, includeDirectories: includeDirectories, depth: depth + 1)
            } else {
                out.append(file)
            }
        }
    }
}

/// What the extension pipeline refuses with: lint issues, or one message.
public struct ExtensionError: Error, CustomStringConvertible, Sendable {
    public var issues: [LintIssue]
    public var text: String

    public init(issues: [LintIssue]) {
        self.issues = issues
        text = issues.map { "\($0.code) \($0.path)\($0.line.map { ":\($0)" } ?? ""): \($0.message)" }.joined(separator: "\n")
    }

    public static func message(_ text: String) -> ExtensionError { ExtensionError(issues: [], text: text) }

    private init(issues: [LintIssue], text: String) { self.issues = issues; self.text = text }

    public var description: String { text }
    public var message: String { text }
}
