import Foundation

/// Where the engine keeps the files of a check in the workspace. Only the engine writes `.brahma/checks` (the saved
/// scripts); the temporary detached checkouts a submission's check runs in live under `.brahma/wt-check`. A merge check
/// runs on a `.git`-free export that is not in the workspace at all: `<home>/run/exports/<runId>` under the data home
/// (`BrahmaPaths.exportDir(runId:)`, `GitWorkspace.exportPath(runId:)`). (`BrahmaPaths.checksDir` is not used for checks.)
public struct CheckPaths: Sendable, Equatable {
    public let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    var checksRoot: URL { workspace.appending(path: ".brahma/checks", directoryHint: .isDirectory) }
    var runWorktreesRoot: URL { workspace.appending(path: ".brahma/wt-check", directoryHint: .isDirectory) }

    /// `<ws>/.brahma/checks/<KEY>/rev<n>/`: the saved copies of the check's scripts.
    public func snapshotDir(key: String, revision: Int) -> URL {
        workspace.appending(path: Self.snapshotRelative(key: key, revision: revision), directoryHint: .isDirectory)
    }

    /// The same, relative to the workspace (for `EngineFiles`).
    static func snapshotRelative(key: String, revision: Int) -> String { ".brahma/checks/\(key)/rev\(revision)" }

    public func manifest(key: String, revision: Int) -> URL {
        snapshotDir(key: key, revision: revision).appending(path: "manifest.json")
    }

    /// `<ws>/.brahma/wt-check/<runId>`: the clean detached checkout a submission's check run executes in. (A merge check's
    /// export is `GitWorkspace.exportPath(runId:)`, under the data home.)
    public func runWorktree(runId: String) -> URL {
        runWorktreesRoot.appending(path: runId, directoryHint: .isDirectory)
    }
}

/// What a check command could reach (`CheckScripts.checkReach`), for risk-tiered review's sensitive paths.
public struct CheckReach: Sendable, Equatable {
    /// Relative paths the command names, resolved against every directory it runs in.
    public var tokens: Set<String>
    /// The directories of the scripts it runs.
    public var directories: Set<String>
    /// False unless the command is in the allowlisted grammar (`CheckScripts.checkReach`): every changed file is then sensitive.
    public var parseable: Bool

    public init(tokens: Set<String> = [], directories: Set<String> = [], parseable: Bool = true) {
        self.tokens = tokens; self.directories = directories; self.parseable = parseable
    }
}

/// The scripts a check command names, and their saved baseline.
public enum CheckScripts {
    public static let maxFiles = 20

    private static let separators: Set<Character> = [";", "&", "|", "(", ")", "<", ">"]

    /// The relative paths a command mentions, cleaned: tokens split on whitespace and `; & | ( ) < >`, quotes stripped,
    /// absolute paths and anything with `..` dropped, in order of first mention.
    public static func candidatePaths(command: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        var token = ""
        func flush() {
            defer { token = "" }
            let t = token.filter { $0 != "'" && $0 != "\"" }
            guard !t.isEmpty, !t.hasPrefix("/") else { return }
            let parts = t.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { return }
            let rel = parts.joined(separator: "/")
            if seen.insert(rel).inserted { out.append(rel) }
        }
        for ch in command {
            if ch.isWhitespace || separators.contains(ch) { flush() } else { token.append(ch) }
        }
        flush()
        return out
    }

    /// Options whose value is a directory the check runs in (`-C X`, `--prefix=X` …): what the check reaches is resolved
    /// against it as well.
    private static let directoryOptions: Set<String> = ["-C", "--directory", "--dir", "--chdir", "--cwd", "--prefix", "--package-path",
                                                        "--rootdir", "--working-directory"]

    /// The only check commands risk-tiered review (9c) follows: a program and subcommand from this list, then plain arguments.
    /// Anything else (a wrapper, an environment assignment, another program) is not followed, and the item keeps its review.
    public static let autoMergePrograms: [[String]] = [
        ["swift", "test"], ["swift", "build"], ["npm", "test"], ["npm", "run", "test"], ["pnpm", "test"], ["yarn", "test"], ["pytest"],
        ["python", "-m", "pytest"], ["python3", "-m", "pytest"], ["go", "test"], ["cargo", "test"], ["make", "test"],
    ]

    /// One plain argument: no quote, backslash, `$`, backtick, glob, `;`, `&`, `|`, `<`, `>`, `(`, `)`, `~`, `#`, `{` or `,`.
    private static let plainWord = try! NSRegularExpression(pattern: "^[A-Za-z0-9_./:=@+-]+$")
    /// A shell variable assignment (`X=y`), which also sets a `make` variable.
    private static let assignment = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*=")
    /// File extensions a bare dotted operand may end in (`test_a.py`); any other dotted name (`pkg.mod`) reads as a module.
    private static let fileExtensions: Set<String> = ["py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "mts", "cts", "go", "rs", "swift"]

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The command's words, or nil unless it is only plain words (`plainWord`) separated by spaces or tabs. The one tokenizer
    /// for risk-tiered review: nothing it accepts means anything special to `/bin/sh`.
    private static func lex(_ command: String) -> [String]? {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty, words.allSatisfy({ matches(plainWord, $0) }) else { return nil }
        return words
    }

    /// A relative path inside the workspace, cleaned (`./` and empty components dropped, a Go `/...` suffix too), or nil when
    /// it is not a plain one: absolute, `..` anywhere, `...` other than a Go pattern's end, a dotted directory component
    /// (`example.com/x`), or, for Go, anything not written `.` or `./…` (Go reads every other operand as an import path).
    private static func plainPath(_ word: String, go: Bool, operand: Bool) -> String?? {
        guard !word.hasPrefix("/") else { return nil }
        if go, operand, word != ".", !word.hasPrefix("./") { return nil }
        var parts = word.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.map(String.init)
        if go, parts.last == "..." { parts.removeLast() }
        guard !parts.contains(where: { $0 == ".." || $0 == "..." }) else { return nil }
        if parts.dropLast().contains(where: { $0.contains(".") }) { return nil }
        // A bare dotted operand (`pkg.mod`) is a module name unless it ends in a source file extension.
        if operand, !word.contains("/"), let last = parts.last, let dot = last.lastIndex(of: "."),
           !fileExtensions.contains(String(last[last.index(after: dot)...]).lowercased()) { return nil }
        return .some(parts.isEmpty ? nil : parts.joined(separator: "/"))
    }

    /// What a check command could reach, for risk-tiered review (9c). Deny by default: `parseable` is true only for one of
    /// `autoMergePrograms` followed by plain arguments (`lex`), none of them an environment or `make` variable assignment
    /// (`X=y`), a plugin or module option (`-p…`, `-m…`, `--pyargs`) or a path that is not a plain relative one (`plainPath`).
    /// Every changed file is sensitive for any other command.
    ///
    /// For a followed command, over-inclusive on purpose (`ReviewPolicy.isSensitive`):
    /// - `tokens`: every argument and every `--option=value` value, cleaned, and each again relative to every directory the
    ///   command runs in (`-C X`, `--prefix=X` …); `python -m pytest` adds `pytest.py` and `pytest` (a workspace module of
    ///   that name would shadow the runner).
    /// - `directories`: the directory of every argument naming a file (one with an extension): the files beside it are its
    ///   helpers.
    public static func checkReach(command: String) -> CheckReach {
        let refused = CheckReach(parseable: false)
        guard let words = lex(command), let program = autoMergePrograms.first(where: { words.starts(with: $0) }) else { return refused }
        let go = program[0] == "go"
        var tokens = Set<String>(), files = Set<String>(), dirs = Set<String>()
        if program.count == 3 { tokens.formUnion(["pytest.py", "pytest"]) }
        var previous = ""
        for word in words.dropFirst(program.count) {
            defer { previous = word }
            var value: String?, key = word
            if word.hasPrefix("-") {
                if word == "--pyargs" { return refused }
                if !word.hasPrefix("--"), word.hasPrefix("-p") || word.hasPrefix("-m") { return refused }
                guard let eq = word.firstIndex(of: "=") else { continue }
                key = String(word[..<eq])
                guard let v = plainPath(String(word[word.index(after: eq)...]), go: go, operand: false) else { return refused }
                value = v
            } else {
                if matches(assignment, word) || word.contains("=") { return refused }
                guard let v = plainPath(word, go: go, operand: !directoryOptions.contains(previous)) else { return refused }
                value = v
                key = previous
            }
            guard let path = value else { continue }
            if directoryOptions.contains(key) { dirs.insert(path); continue }
            tokens.insert(path)
            if path.split(separator: "/").last?.dropFirst().contains(".") == true { files.insert(path) }
        }
        for d in dirs {
            tokens.insert(d)
            for t in Array(tokens) where t != d { tokens.insert(d + "/" + t) }
            for f in Array(files) { files.insert(d + "/" + f) }
        }
        let directories = Set(files.compactMap { f -> String? in f.lastIndex(of: "/").map { String(f[..<$0]) } })
        return CheckReach(tokens: tokens, directories: directories, parseable: true)
    }

    /// Relative regular files under `root` that the command mentions (see `candidatePaths`); directories, symlinks and
    /// anything resolving outside `root` are ignored. At most `maxFiles`.
    public static func referencedFiles(command: String, root: URL) -> [String] {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [String] = []
        for rel in candidatePaths(command: command) where out.count < maxFiles {
            let url = root.appending(path: rel)
            guard (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else { continue }
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath + "/") else { continue }
            out.append(rel)
        }
        return out
    }

    /// Writes `contents` (relative path → bytes) under `<workspace>/<relative>`, replacing whatever was there (a link
    /// included, never followed), through `EngineFiles`, and returns the content hash of each.
    @discardableResult
    public static func write(contents: [String: Data], workspace: URL, dir relative: String) throws -> [String: String] {
        let parts = relative.split(separator: "/").map(String.init)
        guard let last = parts.last else { throw UnsafeEngineFile(path: workspace.path, problem: "is not a check snapshot directory") }
        try EngineFiles.remove(workspace: workspace, dir: parts.dropLast().joined(separator: "/"), name: last)
        try EngineFiles.directory(workspace: workspace, relative)
        var manifest: [String: String] = [:]
        for (file, data) in contents {
            let comps = file.split(separator: "/").map(String.init)
            guard let name = comps.last else { continue }
            let sub = ([relative] + comps.dropLast()).joined(separator: "/")
            guard try EngineFiles.create(data, workspace: workspace, dir: sub, name: name) else {
                throw UnsafeEngineFile(path: workspace.appending(path: "\(relative)/\(file)").path, problem: "already exists")
            }
            manifest[file] = StableHash.fnv1a64(data)
        }
        return manifest
    }

    /// The largest saved script that is hashed; a bigger one hashes as missing (so it reads as modified).
    static let maxHashedBytes = 16 << 20

    /// The content hash of each file under `dir`; nil where it is missing or not a regular file. Every part of the path
    /// below `root` (by default `dir` itself; the workspace for a saved snapshot) is opened without following a link.
    public static func hashes(files: [String], in dir: URL, root: URL? = nil) -> [String: String?] {
        var out: [String: String?] = [:]
        for file in files {
            let url = dir.appending(path: file)
            // Never through a link, and capped: a file past the cap counts as changed.
            if let data = EngineFiles.readNoFollow(url, under: root ?? dir, limit: maxHashedBytes + 1), data.count <= maxHashedBytes {
                out[file] = StableHash.fnv1a64(data)
            } else {
                out[file] = .some(nil)
            }
        }
        return out
    }

    /// One hash over names and contents, independent of order.
    public static func scriptHash(_ hashes: [String: String]) -> String {
        StableHash.fnv1a64(hashes.keys.sorted().map { "\($0)\u{0}\(hashes[$0] ?? "")" }.joined(separator: "\n"))
    }

    public static func scriptHash(_ hashes: [String: String?]) -> String {
        scriptHash(hashes.compactMapValues { $0 })
    }
}

/// Which paths count as tests, for spotting a weakened verification.
public enum PathRules {
    private static let testDirs: Set<String> = ["test", "tests", "__tests__", "spec", "specs"]
    private static let testName = try! NSRegularExpression(
        pattern: "(?i)(^test_.*|.*[._-](test|spec)s?\\.[a-z0-9]+$|.*Tests?\\.swift$)")

    public static func isTestFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: { testDirs.contains($0.lowercased()) }) { return true }
        return testName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
