import Foundation

/// Where the engine keeps the files of a check. Only the engine writes `.brahma/checks`; the temporary detached checkouts
/// the checks run in live under `.brahma/wt-check`. (`BrahmaPaths.checksDir` is not used for checks.)
public struct CheckPaths: Sendable, Equatable {
    public let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    var checksRoot: URL { workspace.appending(path: ".brahma/checks", directoryHint: .isDirectory) }
    var runWorktreesRoot: URL { workspace.appending(path: ".brahma/wt-check", directoryHint: .isDirectory) }

    /// `<ws>/.brahma/checks/<KEY>/rev<n>/`: the saved copies of the check's scripts.
    public func snapshotDir(key: String, revision: Int) -> URL {
        checksRoot.appending(path: "\(key)/rev\(revision)", directoryHint: .isDirectory)
    }

    public func manifest(key: String, revision: Int) -> URL {
        snapshotDir(key: key, revision: revision).appending(path: "manifest.json")
    }

    /// `<ws>/.brahma/wt-check/<runId>`: the clean detached checkout one run executes in.
    public func runWorktree(runId: String) -> URL {
        runWorktreesRoot.appending(path: runId, directoryHint: .isDirectory)
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

    /// Options whose value is a directory the command runs in (`-C X`, `--directory=X` …), besides `cd X`.
    private static let directoryOptions: Set<String> = ["-C", "--directory", "--dir", "--chdir", "--cwd", "--prefix", "--package-path",
                                                        "--rootdir", "--working-directory"]

    /// Every relative path a check command could name, for risk-tiered review (9c): each token as `candidatePaths` cleans it;
    /// the value of each `--option=value`; a Python module run with `-m a.b` as `a/b.py`, `a/b/__main__.py` and `a/b`; and each
    /// of those again relative to every directory the command changes into (`cd X &&`, `cd X;`, `(cd X && …)`, `-C X`,
    /// `--directory X` and the like), so `cd src && python3 check.py` names `src/check.py`. Over-inclusive on purpose: a changed
    /// file whose name or path suffix matches any of these keeps its review (`ReviewPolicy.isSensitive`).
    public static func checkTokens(command: String) -> Set<String> {
        var raw: [String] = []
        var token = ""
        for ch in command {
            if ch.isWhitespace || separators.contains(ch) {
                if !token.isEmpty { raw.append(token); token = "" }
            } else if ch != "'" && ch != "\"" {
                token.append(ch)
            }
        }
        if !token.isEmpty { raw.append(token) }

        func clean(_ t: String) -> String? {
            guard !t.isEmpty, !t.hasPrefix("/") else { return nil }
            let parts = t.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { return nil }
            return parts.joined(separator: "/")
        }
        var tokens = Set<String>(), dirs = Set<String>()
        for (n, t) in raw.enumerated() {
            let previous = n > 0 ? raw[n - 1] : ""
            var values = [t]
            if let eq = t.firstIndex(of: "="), t.hasPrefix("-") || eq != t.startIndex {
                let key = String(t[..<eq]), value = String(t[t.index(after: eq)...])
                values.append(value)
                if directoryOptions.contains(key), let d = clean(value) { dirs.insert(d) }
            }
            if previous == "cd" || directoryOptions.contains(previous), let d = clean(t) { dirs.insert(d) }
            if previous == "-m", !t.contains("/"), !t.hasPrefix("-") {
                let module = t.replacingOccurrences(of: ".", with: "/")
                values += [module + ".py", module + "/__main__.py", module]
            }
            tokens.formUnion(values.compactMap(clean))
        }
        for d in dirs { for t in Array(tokens) { tokens.insert(d + "/" + t) } }
        return tokens
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

    /// Writes `contents` (relative path → bytes) under `to`, replacing it, and returns the content hash of each.
    @discardableResult
    public static func write(contents: [String: Data], to: URL) throws -> [String: String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for (file, data) in contents {
            let target = to.appending(path: file)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            manifest[file] = StableHash.fnv1a64(data)
        }
        return manifest
    }

    /// Copies each file (relative to `from`) to the same relative path under `to`, and returns the content hash of each.
    @discardableResult
    public static func snapshot(files: [String], from: URL, to: URL) throws -> [String: String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for file in files {
            let data = try Data(contentsOf: from.appending(path: file))
            let target = to.appending(path: file)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            manifest[file] = StableHash.fnv1a64(data)
        }
        return manifest
    }

    /// The content hash of each file under `dir`; nil where it is missing or not a regular file.
    public static func hashes(files: [String], in dir: URL) -> [String: String?] {
        var out: [String: String?] = [:]
        for file in files {
            let url = dir.appending(path: file)
            if (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular,
               let data = try? Data(contentsOf: url) {
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
