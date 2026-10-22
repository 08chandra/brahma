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
    /// Relative paths the command names, resolved against every directory it changes into.
    public var tokens: Set<String>
    /// The directories of the scripts it runs.
    public var directories: Set<String>
    /// False when the engine cannot follow the command: every changed file is then sensitive.
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

    /// Options whose value is a directory the command runs in (`-C X`, `--directory=X` …), besides `cd X` and `pushd X`.
    private static let directoryOptions: Set<String> = ["-C", "--directory", "--dir", "--chdir", "--cwd", "--prefix", "--package-path",
                                                        "--rootdir", "--working-directory"]
    /// Words that run the next word as a script (`sh x`, `python3 x`, `source x` …).
    private static let interpreters = try! NSRegularExpression(
        pattern: "^(sh|bash|zsh|dash|ksh|ash|python[0-9.]*|pypy[0-9.]*|node|nodejs|deno|bun|ruby|perl|php|source|\\.)$")
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "ash"]
    /// Words that run the rest of the command (`env x`, `timeout 60 x` …), skipped to find the program.
    private static let wrappers: Set<String> = ["env", "exec", "command", "builtin", "nohup", "time", "sudo", "nice", "xargs", "timeout",
                                                "stdbuf", "caffeinate"]
    private static let moduleName = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_.]*$")

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// The relative paths of every token a check command could name, for risk-tiered review (9c); `checkReach(command:).tokens`.
    public static func checkTokens(command: String) -> Set<String> { checkReach(command: command).tokens }

    /// What a check command could reach, for risk-tiered review (9c), over-inclusive on purpose (`ReviewPolicy.isSensitive`):
    ///
    /// - `tokens`: the command split on whitespace and `; & | ( ) < >` with quotes stripped (so the inside of `sh -c "…"` counts
    ///   too), each cleaned like `candidatePaths`; the value of each `--option=value` / `VAR=value`; a Python module run with
    ///   `-m a.b` or `-ma.b` as `a/b.py`, `a/b/__main__.py` and `a/b`; a Go pattern `x/...` as `x`; and each of those again
    ///   relative to every directory the command changes into (`cd X`, `pushd X`, `-C X`, `--directory X`, `=X` …).
    /// - `directories`: the directory of every referenced script (a token with a file extension, the program of a command, or
    ///   the word after an interpreter such as `sh`, `python3` or `source`): the files beside a check script are its helpers.
    /// - `parseable`: false when the command uses shell syntax the engine does not follow (`$` expansions or `$(…)`, backticks,
    ///   `eval`, unbalanced quotes, a trailing `\`, globs other than `*`, brace expansion, here-documents, process substitution,
    ///   comments), changes into a directory it cannot resolve (none, `-`, absolute, `~` or `..`), or runs inline code
    ///   (`python -c`, `node -e`, `perl -e`, `ruby -e`, `php -r`, `deno eval`). Such a check makes every changed file sensitive.
    ///   The inside of `sh -c '…'` / `bash -lc "…"` is checked the same way.
    public static func checkReach(command: String) -> CheckReach {
        var raw: [(text: String, program: Bool)] = []
        var token = "", atStart = true
        func flush() {
            if !token.isEmpty { raw.append((token, atStart)); atStart = false }
            token = ""
        }
        for ch in command {
            if separators.contains(ch) || ch.isNewline {
                flush(); atStart = true
            } else if ch.isWhitespace {
                flush()
            } else if ch != "'" && ch != "\"" {
                token.append(ch)
            }
        }
        flush()

        func clean(_ t: String) -> String? {
            guard !t.isEmpty, !t.hasPrefix("/") else { return nil }
            var parts = t.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
            if parts.count > 1, parts.last == "..." { parts.removeLast() }    // go test ./x/...
            guard !parts.isEmpty, !parts.contains("..") else { return nil }
            return parts.joined(separator: "/")
        }
        var tokens = Set<String>(), scripts = Set<String>(), dirs = Set<String>()
        for (n, entry) in raw.enumerated() {
            let t = entry.text
            let previous = n > 0 ? raw[n - 1].text : ""
            let base = previous.split(separator: "/").last.map(String.init) ?? previous
            var values = [t]
            if let eq = t.firstIndex(of: "="), t.hasPrefix("-") || eq != t.startIndex {
                let key = String(t[..<eq]), value = String(t[t.index(after: eq)...])
                values.append(value)
                if directoryOptions.contains(key), let d = clean(value) { dirs.insert(d) }
            }
            let changesDirectory = previous == "cd" || previous == "pushd" || directoryOptions.contains(previous)
            if changesDirectory, let d = clean(t) { dirs.insert(d) }
            var module: String?
            if previous == "-m", !t.hasPrefix("-") { module = t }
            if t.hasPrefix("-m"), t.count > 2 { module = String(t.dropFirst(2)) }
            if let module, matches(moduleName, module) {
                let path = module.split(separator: ".", omittingEmptySubsequences: true).joined(separator: "/")
                values += [path + ".py", path + "/__main__.py", path]
            }
            let cleaned = values.compactMap(clean)
            tokens.formUnion(cleaned)
            for c in cleaned where !changesDirectory {
                let last = c.split(separator: "/").last.map(String.init) ?? c
                if entry.program || matches(interpreters, base) || last.dropFirst().contains(".") { scripts.insert(c) }
            }
        }
        for d in dirs {
            for t in Array(tokens) { tokens.insert(d + "/" + t) }
            for s in Array(scripts) { scripts.insert(d + "/" + s) }
        }
        let directories = Set(scripts.compactMap { s -> String? in
            guard let slash = s.lastIndex(of: "/") else { return nil }
            return String(s[..<slash])
        })
        return CheckReach(tokens: tokens, directories: directories, parseable: parseable(command))
    }

    /// One shell word: its text with quotes removed, and the characters that were not quoted.
    private struct Word { var text = "", unquoted = "", quoted = false }

    /// The command split into simple commands of words (`; & | ( )` and newlines separate them), or nil for syntax the engine
    /// does not follow (see `checkReach`).
    private static func lex(_ command: String) -> [[Word]]? {
        enum Quote { case none, single, double }
        var commands: [[Word]] = [[]], word = Word(), inWord = false, quote = Quote.none
        var chars = Array(command)[...]
        func end() {
            if inWord { commands[commands.count - 1].append(word) }
            word = Word(); inWord = false
        }
        while let ch = chars.popFirst() {
            switch quote {
            case .single:
                if ch == "'" { quote = .none } else { word.text.append(ch) }
            case .double:
                if ch == "\"" { quote = .none }
                else if ch == "$" || ch == "`" { return nil }
                else if ch == "\\" {
                    guard let next = chars.popFirst() else { return nil }
                    if !"$`\"\\\n".contains(next) { word.text.append(ch) }
                    word.text.append(next)
                } else { word.text.append(ch) }
            case .none:
                if ch == "$" || ch == "`" { return nil }
                if ch == "#", !inWord { return nil }
                if ch == "'" || ch == "\"" { quote = ch == "'" ? .single : .double; inWord = true; word.quoted = true; continue }
                if ch == "\\" {
                    guard let next = chars.popFirst() else { return nil }
                    word.text.append(next); inWord = true; continue
                }
                if ch == "<" || ch == ">" {
                    if let next = chars.first, next == "(" || (ch == "<" && next == "<") { return nil }
                    end(); continue
                }
                if ch.isNewline || ";&|()".contains(ch) { end(); commands.append([]); continue }
                if ch.isWhitespace { end(); continue }
                word.text.append(ch); word.unquoted.append(ch); inWord = true
            }
        }
        guard quote == .none else { return nil }
        end()
        for w in commands.joined() {
            let u = w.unquoted
            if u.contains("?") { return nil }
            if u.contains("["), !["[", "[["].contains(w.text) { return nil }
            if u.contains("{"), u.contains("}"), u.contains(",") || u.contains("..") { return nil }
        }
        return commands.filter { !$0.isEmpty }
    }

    /// Whether the engine follows every part of `command` (see `checkReach`).
    static func parseable(_ command: String, depth: Int = 0) -> Bool {
        guard depth < 4, let commands = lex(command) else { return false }
        func isAssignment(_ w: Word) -> Bool {
            guard let eq = w.text.firstIndex(of: "="), eq != w.text.startIndex else { return false }
            return w.text[..<eq].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
        }
        func unresolvable(_ dir: String) -> Bool {
            dir.isEmpty || dir == "-" || dir.hasPrefix("/") || dir.hasPrefix("~") || dir.split(separator: "/").contains("..")
        }
        for words in commands {
            var i = 0
            while i < words.count, isAssignment(words[i]) { i += 1 }
            while i < words.count, wrappers.contains(words[i].text) {
                let wrapper = words[i].text
                i += 1
                while i < words.count, words[i].text.hasPrefix("-") || isAssignment(words[i]) { i += 1 }
                if wrapper == "timeout" || wrapper == "nice" { i += 1 }
            }
            guard i < words.count else { continue }
            let program = words[i].text.split(separator: "/").last.map(String.init) ?? words[i].text
            let args = words[(i + 1)...].map(\.text)
            // Options before the first operand (the script, a module, a subcommand).
            let options = Array(args.prefix { $0.hasPrefix("-") && $0 != "-" && $0 != "--" })
            switch program {
            case "eval":
                return false
            case "cd", "pushd":
                guard let dir = args.first(where: { !["-P", "-L", "-e", "-@"].contains($0) }), !unresolvable(dir) else { return false }
            case _ where shells.contains(program):
                // `sh -c '…'`, `bash -lc "…"`: the script is the word after the option, followed the same way.
                if let k = options.firstIndex(where: { !$0.hasPrefix("--") && $0.dropFirst().contains("c") }) {
                    guard k + 1 < args.count, parseable(args[k + 1], depth: depth + 1) else { return false }
                }
            case _ where program.hasPrefix("python") || program.hasPrefix("pypy"):
                for option in options {
                    if option.hasPrefix("-m") { break }
                    if !option.hasPrefix("--"), option.dropFirst().contains("c") { return false }
                }
            case "node", "nodejs", "bun", "perl", "ruby":
                for option in options {
                    if ["--eval", "--print"].contains(where: { option.hasPrefix($0) }) { return false }
                    if !option.hasPrefix("--"), option.dropFirst().contains(where: { $0 == "e" || $0 == "E" || $0 == "p" }) { return false }
                }
            case "php":
                if options.contains(where: { !$0.hasPrefix("--") && $0.dropFirst().contains("r") }) { return false }
            case "deno":
                if args.contains("eval") { return false }
            default:
                break
            }
            // A directory option (`-C X`, `--directory=X` …) the engine cannot resolve.
            for (n, a) in args.enumerated() {
                if let eq = a.firstIndex(of: "="), directoryOptions.contains(String(a[..<eq])),
                   unresolvable(String(a[a.index(after: eq)...])) { return false }
                if directoryOptions.contains(a), n + 1 < args.count, unresolvable(args[n + 1]) { return false }
            }
        }
        return true
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
