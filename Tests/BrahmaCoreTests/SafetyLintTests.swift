import Testing
import Foundation
@testable import BrahmaCore

/// Plan S's safety lint (spec §6.8.2): a static scan of `Sources/BrahmaCore` and `Sources/brahma` for the raw APIs the plan
/// retires (spawns, policy literals, descriptors, file APIs, directory walks, loopback HTTP, fail-open shapes, unscoped alerts,
/// turn scopes). The counts are frozen in a checked-in baseline (`Fixtures/safety-lint-baseline.json`, rule → file → count)
/// that may only shrink: a count above its baseline fails, a file not in the baseline with a hit fails, a `zero` scope with a
/// hit fails, and a count below its baseline fails too, printing the baseline to paste, so a drop is recorded the moment it
/// happens. Same scan style as `EngineGitGuardTests` (comments blanked with its `code`).
enum SafetyLint {
    enum Rule: String, CaseIterable {
        case spawn, sandboxPolicy, descriptor, fileAPI, dirWalk, loopbackHTTP, failOpen, alertScope, turnScope

        /// The code-only pattern (spec §6.8.2). `alertScope` is matched by `alertScopeHits` instead, which reads the argument
        /// list up to the matching `)`.
        var pattern: String {
            switch self {
            case .spawn: return #"\bProcess\(\)|\bposix_spawn\(|"/usr/bin/env"|\[\s*"git""#
            case .sandboxPolicy: return #"\bSandboxPolicy\("#
            case .descriptor: return #"\b(open|openat|fstatat|lstat|readlink|realpath)\(|\bO_NOFOLLOW\b"#
            case .fileAPI: return #"FileManager\.default|Data\(contentsOf:|String\(contentsOf|\.write\(to:|FileHandle\(for"#
            case .dirWalk: return #"enumerator\(at:|contentsOfDirectory\(|\bopendir\(|\bfdopendir\(|\breaddir\("#
            case .loopbackHTTP: return #"URLSessionHTTPProbe|URLSession|HTTPProbing"#
            case .failOpen: return #"\?\?\s*true\b|\?\?\s*false\b|\btry\?"#
            case .alertScope: return #"\bEngineAlerts\.raise\("#
            case .turnScope: return #"\bSandboxScope\.forTurn\("#
            }
        }

        /// Repo-relative directory prefixes where the rule must have no hit at all. Empty in S1; S7, S9–S12 and S15 fill them.
        var zero: [String] {
            switch self {
            case .spawn, .sandboxPolicy, .descriptor, .fileAPI, .dirWalk, .loopbackHTTP, .failOpen, .alertScope, .turnScope:
                return []
            }
        }
    }

    struct Hit: CustomStringConvertible {
        let path: String
        let line: Int
        let text: String
        var description: String { "\(path):\(line): \(text)" }
    }

    static let scanned = ["Sources/BrahmaCore", "Sources/brahma"]
    static let baselinePath = "Tests/BrahmaCoreTests/Fixtures/safety-lint-baseline.json"

    /// Every hit of every rule, by rule, over `scanned` under `root` (the package root). Comments are blanked first.
    static func hits(root: URL) throws -> [Rule: [Hit]] {
        var out: [Rule: [Hit]] = [:]
        for rule in Rule.allCases { out[rule] = [] }
        for dir in scanned {
            for (path, text) in try sources(under: dir, root: root) {
                let code = EngineGitGuardTests.code(text)
                for rule in Rule.allCases {
                    let found = rule == .alertScope ? alertScopeHits(in: code) : regexHits(in: code, pattern: rule.pattern)
                    out[rule, default: []] += found.map { Hit(path: path, line: $0.line, text: $0.text) }
                }
            }
        }
        return out
    }

    /// Rule → repo-relative file → number of hits (only files with a hit).
    static func scan(root: URL) throws -> [Rule: [String: Int]] {
        try hits(root: root).mapValues { hits in
            hits.reduce(into: [String: Int]()) { $0[$1.path, default: 0] += 1 }
        }
    }

    /// The baseline JSON for `counts`: `{ "<rule>": { "<path>": <count> } }`, keys sorted, every rule present.
    static func json(_ counts: [Rule: [String: Int]]) throws -> String {
        var byName: [String: [String: Int]] = [:]
        for rule in Rule.allCases { byName[rule.rawValue] = counts[rule] ?? [:] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(byName), as: UTF8.self) + "\n"
    }

    /// The checked-in baseline, or nil when there is none yet.
    static func baseline(root: URL) throws -> [Rule: [String: Int]]? {
        let url = root.appending(path: baselinePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let byName = try JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        var out: [Rule: [String: Int]] = [:]
        for (name, files) in byName {
            guard let rule = Rule(rawValue: name) else { throw LintError.unknownRule(name) }
            out[rule] = files
        }
        return out
    }

    enum LintError: Error { case unknownRule(String) }

    /// The Swift sources under `dir` (repo-relative path, text), sorted by path. Same shape as `EngineGitGuardTests.sources`.
    static func sources(under dir: String, root: URL) throws -> [(path: String, text: String)] {
        let base = root.appending(path: dir)
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: Matching

    static func regexHits(in code: String, pattern: String) -> [(line: Int, text: String)] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { m in
            (line(of: m.range.location, in: ns), lineText(at: m.range.location, in: ns))
        }
    }

    /// `EngineAlerts.raise(` calls whose argument list, up to the matching `)`, carries no `scope:` label (in code: a `scope:`
    /// inside a string literal does not count).
    static func alertScopeHits(in code: String) -> [(line: Int, text: String)] {
        let regex = try! NSRegularExpression(pattern: Rule.alertScope.pattern)
        let ns = code as NSString
        let chars = Array(code.utf16)
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let open = m.range.location + m.range.length - 1
            let arguments = argumentList(from: open, chars: chars)
            if arguments.range(of: #"(^|[\s(,])scope\s*:"#, options: .regularExpression) != nil { return nil }
            return (line(of: m.range.location, in: ns), lineText(at: m.range.location, in: ns))
        }
    }

    /// The code of the argument list opened by the `(` at `open`, up to its matching `)` (or the end of the text when it
    /// never closes), with the contents of string literals (`"…"`, `"""…"""`) blanked. Parentheses inside a literal do not
    /// count; the code of its `\(…)` interpolations does, balanced on its own.
    static func argumentList(from open: Int, chars: [UInt16]) -> String {
        enum Mode { case code(depth: Int), string(triple: Bool) }
        let quote: UInt16 = 34, backslash: UInt16 = 92, lparen: UInt16 = 40, rparen: UInt16 = 41, space: UInt16 = 32
        guard chars.indices.contains(open), chars[open] == lparen else { return "" }
        var stack: [Mode] = [.code(depth: 1)]
        var out: [UInt16] = []
        var i = open + 1
        func isTriple(_ at: Int) -> Bool { at + 2 < chars.count && chars[at] == quote && chars[at + 1] == quote && chars[at + 2] == quote }
        scan: while i < chars.count, let top = stack.last {
            let c = chars[i]
            switch top {
            case .code(let depth):
                if c == quote {
                    let triple = isTriple(i)
                    stack.append(.string(triple: triple)); out.append(space); i += triple ? 3 : 1; continue
                }
                if c == lparen { stack[stack.count - 1] = .code(depth: depth + 1) }
                if c == rparen {
                    if depth == 1 {
                        stack.removeLast()
                        if stack.isEmpty { break scan }       // the outermost list closed
                    } else {
                        stack[stack.count - 1] = .code(depth: depth - 1)
                    }
                }
                out.append(c)
            case .string(let triple):
                if c == backslash, i + 1 < chars.count {
                    if chars[i + 1] == lparen { stack.append(.code(depth: 1)); out.append(space); i += 2; continue }
                    out.append(space); i += 2; continue                          // an escape such as \" or \\
                }
                if triple ? isTriple(i) : c == quote { stack.removeLast(); out.append(space); i += triple ? 3 : 1; continue }
                out.append(c == 10 ? c : space)
            }
            i += 1
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    static func line(of offset: Int, in ns: NSString) -> Int {
        var n = 1
        for i in 0..<offset where ns.character(at: i) == 10 { n += 1 }
        return n
    }

    static func lineText(at offset: Int, in ns: NSString) -> String {
        ns.substring(with: ns.lineRange(for: NSRange(location: offset, length: 0))).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite struct SafetyLintTests {
    static let root = EngineGitGuardTests.packageRoot

    /// A (rule, file) count above its baseline, or a hit in a file the baseline does not list, fails and names the hits.
    @Test func noRuleExceedsBaseline() throws {
        let baseline = try #require(try SafetyLint.baseline(root: Self.root), "no baseline at \(SafetyLint.baselinePath)")
        let hits = try SafetyLint.hits(root: Self.root)
        var offenders: [String] = []
        for rule in SafetyLint.Rule.allCases {
            let byFile = Dictionary(grouping: hits[rule] ?? [], by: \.path)
            for (path, found) in byFile.sorted(by: { $0.key < $1.key }) {
                let allowed = baseline[rule]?[path] ?? 0
                if found.count > allowed {
                    offenders.append("\(rule.rawValue) in \(path): \(found.count) > baseline \(allowed)\n    "
                        + found.map(\.description).joined(separator: "\n    "))
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "raw API use above the safety-lint baseline (spec §6.8.2):\n" + offenders.joined(separator: "\n")))
    }

    /// Every baseline entry equals the count found, so a drop must be recorded: on a shrink the baseline to paste is printed.
    @Test func baselineHasNoSlack() throws {
        let baseline = try SafetyLint.baseline(root: Self.root)
        let counts = try SafetyLint.scan(root: Self.root)
        var slack: [String] = []
        for rule in SafetyLint.Rule.allCases {
            for (path, allowed) in (baseline?[rule] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let found = counts[rule]?[path] ?? 0
                if found < allowed { slack.append("\(rule.rawValue) in \(path): baseline \(allowed), found \(found)") }
            }
        }
        if baseline == nil || !slack.isEmpty {
            print("--- \(SafetyLint.baselinePath) (paste this) ---")
            print(try SafetyLint.json(counts), terminator: "")
            print("--- end of baseline ---")
        }
        #expect(baseline != nil, "no baseline at \(SafetyLint.baselinePath); the one to check in was printed")
        #expect(slack.isEmpty, Comment(rawValue: "the safety-lint baseline has slack; lower it to the printed one:\n" + slack.joined(separator: "\n")))
        // Entries the two tests above do not cover (a file in the baseline that no longer has a hit is slack; a rule key
        // missing from the file is a damaged baseline).
        if let baseline {
            #expect(Set(baseline.keys) == Set(SafetyLint.Rule.allCases), "the baseline must list every rule")
            for rule in SafetyLint.Rule.allCases {
                #expect(baseline[rule] ?? [:] == counts[rule] ?? [:], "\(rule.rawValue): baseline and scan differ")
            }
        }
    }

    /// A rule's `zero` directories have no hit. The lists are empty in S1; later tasks fill them as families reach zero.
    @Test func zeroScopesAreZero() throws {
        let hits = try SafetyLint.hits(root: Self.root)
        var offenders: [String] = []
        for rule in SafetyLint.Rule.allCases {
            for prefix in rule.zero {
                for hit in hits[rule] ?? [] where hit.path.hasPrefix(prefix) {
                    offenders.append("\(rule.rawValue): \(hit)")
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "hits in a zero scope:\n" + offenders.joined(separator: "\n")))
    }

    /// The scan is live: known sites are found, and the `alertScope` argument-list matcher reads to the matching `)`.
    @Test func scanFindsKnownSites() throws {
        let counts = try SafetyLint.scan(root: Self.root)
        #expect((counts[.spawn]?["Sources/BrahmaCore/Git/GitWorkspace.swift"] ?? 0) > 0, "spawn: GitWorkspace starts git")
        #expect((counts[.sandboxPolicy]?["Sources/BrahmaCore/Sandbox/SandboxedCheckRunner.swift"] ?? 0) > 0,
                "sandboxPolicy: the check runner builds a policy")
        #expect((counts[.alertScope]?.count ?? 0) >= 17, "alertScope: \(counts[.alertScope]?.count ?? 0) files, expected the 17+ of spec §7.7")

        // The matcher: no `scope:` → a hit; `scope:` anywhere in the argument list, across lines and nested calls → none;
        // parentheses in string literals and interpolations do not end the list early.
        func unscoped(_ code: String) -> Int { SafetyLint.alertScopeHits(in: code).count }
        #expect(unscoped(#"try EngineAlerts.raise(store: store, text: "x", now: now)"#) == 1)
        #expect(unscoped(#"try EngineAlerts.raise(store: store, text: "x", now: now, scope: .company(id))"#) == 0)
        #expect(unscoped("try EngineAlerts.raise(store: store, text: text(for: a),\n    now: now,\n    scope: .allCompanies(.doctor))") == 0)
        #expect(unscoped(#"try EngineAlerts.raise(store: s, text: "(scope: none) \(flat(x))", now: n)"#) == 1)
        #expect(unscoped(#"try EngineAlerts.raise(store: s, text: "a ) b", now: n, scope: .company(c))"#) == 0)
        #expect(unscoped(#"let scope = 1; try EngineAlerts.raise(store: s, text: "x", now: n); use(scope: scope)"#) == 1)
        #expect(unscoped(#"EngineAlerts.raise(store: s, text: "x", now: n)\nEngineAlerts.raise(store: s, text: "y", now: n, scope: .company(c))"#) == 1)
    }
}
