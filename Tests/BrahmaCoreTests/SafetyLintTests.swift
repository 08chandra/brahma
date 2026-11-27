import Testing
import Foundation
@testable import BrahmaCore

/// Plan S's safety lint (spec §6.8.2): a static scan of `Sources/BrahmaCore`, `Sources/brahma` and the kernel
/// `Sources/BrahmaSafety` (Ruling S3-2: a zero scope there needs it scanned) for the raw APIs the plan retires (spawns, policy literals, descriptors, file APIs, directory walks, loopback HTTP, fail-open shapes, unscoped alerts,
/// turn scopes). The counts are frozen in a checked-in baseline (`Fixtures/safety-lint-baseline.json`, rule → file → count)
/// that may only shrink: a count above its baseline fails, a file not in the baseline with a hit fails, a `zero` scope with a
/// hit fails, and a count below its baseline fails too, printing the baseline to paste, so a drop is recorded the moment it
/// happens. Same scan style as `EngineGitGuardTests` (comments blanked with its `code`).
enum SafetyLint {
    enum Rule: String, CaseIterable {
        case spawn, sandboxPolicy, descriptor, fileAPI, dirWalk, loopbackHTTP, failOpen, alertScope, turnScope, publicBool

        /// The code-only pattern (spec §6.8.2). `alertScope` is matched by `alertScopeHits` instead, which reads the argument
        /// list up to the matching `)`. `failOpen` also holds spec §6.7's two other bans (S4): a `catch` with an empty body
        /// (a comment-only body is empty once comments are blanked; `{ () }` is empty too) and a `catch` body that ends in
        /// `return true` (also `return (true);`, after nested blocks); the part before a `catch`'s `{` may span lines, and
        /// `?? (true)` counts as `?? true` (a tuple default such as `?? (false, nil)` does not). `publicBool` is spec §6.7's
        /// ban on new `public func … -> Bool` in the policy and principal code (Ruling S4-B), a decision there being a
        /// `Decision`.
        var pattern: String {
            switch self {
            case .spawn: return #"\bProcess\(\)|\bposix_spawn\(|"/usr/bin/env"|\[\s*"git""#
            case .sandboxPolicy: return #"\bSandboxPolicy\("#
            case .descriptor: return #"\b(open|openat|fstatat|lstat|readlink|realpath)\(|\bO_NOFOLLOW\b"#
            case .fileAPI: return #"FileManager\.default|Data\(contentsOf:|String\(contentsOf|\.write\(to:|FileHandle\(for"#
            case .dirWalk: return #"enumerator\(at:|contentsOfDirectory\(|\bopendir\(|\bfdopendir\(|\breaddir\("#
            case .loopbackHTTP: return #"URLSessionHTTPProbe|URLSession|HTTPProbing"#
            case .failOpen:
                return #"\?\?\s*(?:true|false)\b|\?\?\s*\(\s*(?:true|false)\s*\)|\btry\?|\bcatch\b[^{}]*\{\s*(?:\(\s*\)\s*)?\}|"#
                    + #"\bcatch\b[^{}]*\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\breturn\s+\(?\s*true\s*\)?\s*;?\s*\}"#
            case .alertScope: return #"\bEngineAlerts\.raise\("#
            case .turnScope: return #"\bSandboxScope\.forTurn\("#
            case .publicBool:
                return #"\bpublic\s+(?:(?:static|class|final|nonisolated|override|mutating|@\w+)\s+)*func\b[^{]*?->\s*Bool\b"#
            }
        }

        /// The only directories a rule scans, when it is scoped (nil: every scanned root). A scoped rule is a zero rule there
        /// and has no baseline entries.
        var only: [String]? {
            switch self {
            case .publicBool: return Self.policyAndPrincipal
            case .spawn, .sandboxPolicy, .descriptor, .fileAPI, .dirWalk, .loopbackHTTP, .failOpen, .alertScope, .turnScope:
                return nil
            }
        }

        /// Spec §6.7's policy and principal code: the brief's `Policy/` and `BrahmaCore/Principal/`, and the spec's
        /// `BrahmaSafety/Principal/` (not created yet; S6 may put the principal model there).
        static let policyAndPrincipal = ["Sources/BrahmaSafety/Policy/", "Sources/BrahmaSafety/Principal/", "Sources/BrahmaCore/Principal/"]

        /// Repo-relative directory prefixes where the rule must have no hit at all; each lies under a `scanned` root. S3 emptied
        /// `Verify/` and `Sandbox/` of spawns (the process primitives and the Seatbelt runtime moved to `BrahmaSafety`); S4
        /// emptied the kernel and `Principal/` of fail-open shapes and every scanned file of unscoped alerts; S7, S9–S12 and S15
        /// fill the rest.
        var zero: [String] {
            switch self {
            case .spawn: return ["Sources/BrahmaCore/Verify/", "Sources/BrahmaCore/Sandbox/"]
            case .failOpen: return ["Sources/BrahmaSafety/", "Sources/BrahmaCore/Principal/"]
            case .alertScope: return SafetyLint.scanned.map { $0 + "/" }
            case .publicBool: return Self.policyAndPrincipal
            case .sandboxPolicy, .descriptor, .fileAPI, .dirWalk, .loopbackHTTP, .turnScope:
                return []
            }
        }

        /// Files inside a `zero` directory whose hits are not what the rule hunts, each with its reason (spec §6.8.2: "ClaudeSettings'
        /// script-text line allowlisted with a reason"). Exempt from the zero check only; the baseline still bounds their count.
        var zeroExempt: [String: String] {
            switch self {
            case .spawn:
                return ["Sources/BrahmaCore/Sandbox/ClaudeSettings.swift":
                            "`ShellPrefix.tools`: the absolute tool paths the agent's shell prefix script runs, as script text; the engine spawns nothing here"]
            case .sandboxPolicy, .descriptor, .fileAPI, .dirWalk, .loopbackHTTP, .failOpen, .alertScope, .turnScope, .publicBool:
                return [:]
            }
        }
    }

    struct Hit: CustomStringConvertible {
        let path: String
        let line: Int
        let text: String
        var description: String { "\(path):\(line): \(text)" }
    }

    static let scanned = ["Sources/BrahmaCore", "Sources/brahma", "Sources/BrahmaSafety"]
    static let baselinePath = "Tests/BrahmaCoreTests/Fixtures/safety-lint-baseline.json"

    /// Every hit of every rule, by rule, over `scanned` under `root` (the package root). Comments are blanked first.
    static func hits(root: URL) throws -> [Rule: [Hit]] {
        var out: [Rule: [Hit]] = [:]
        for rule in Rule.allCases { out[rule] = [] }
        for dir in scanned {
            for (path, text) in try sources(under: dir, root: root) {
                let code = EngineGitGuardTests.code(text)
                for rule in Rule.allCases {
                    if let only = rule.only, !only.contains(where: { path.hasPrefix($0) }) { continue }
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

    /// The baseline to paste after a shrink: every baseline entry lowered to what was found (`min`), entries that fell to 0
    /// dropped, and no file the baseline does not list. A rise never appears in it, so pasting cannot raise a count
    /// (spec §6.8.2: the printed baseline only shrinks); `noRuleExceedsBaseline` reports rises separately.
    static func shrunk(baseline: [Rule: [String: Int]], counts: [Rule: [String: Int]]) -> [Rule: [String: Int]] {
        var out: [Rule: [String: Int]] = [:]
        for rule in Rule.allCases {
            var files: [String: Int] = [:]
            for (path, allowed) in baseline[rule] ?? [:] {
                let kept = min(allowed, counts[rule]?[path] ?? 0)
                if kept > 0 { files[path] = kept }
            }
            out[rule] = files
        }
        return out
    }

    /// The hits inside a rule's `zero` directories, less those in an exempted file. A prefix names a directory:
    /// `Sources/BrahmaCore/Refs` (with or without the trailing `/`) covers `Sources/BrahmaCore/Refs/…` and not
    /// `Sources/BrahmaCore/RefsX/…`.
    static func zeroOffenders(_ hits: [Hit], zero: [String], exempt: [String: String] = [:]) -> [Hit] {
        let dirs = zero.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return hits.filter { hit in dirs.contains { hit.path.hasPrefix($0) } && exempt[hit.path] == nil }
    }

    /// The prefixes of `zero` that lie under none of `roots` (a zero scope outside the scan would pass vacuously). A prefix
    /// lies under a root when it is the root or starts with the root and `/`.
    static func unscanned(_ zero: [String], roots: [String] = scanned) -> [String] {
        zero.filter { prefix in
            let dir = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            return !roots.contains { dir == $0 || dir.hasPrefix($0 + "/") }
        }
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

@Suite(.scratch) struct SafetyLintTests {
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
            // With a baseline, only the shrink is printed (never a rise, which noRuleExceedsBaseline reports); without one,
            // the first baseline is the whole scan.
            let paste = baseline.map { SafetyLint.shrunk(baseline: $0, counts: counts) } ?? counts
            print("--- \(SafetyLint.baselinePath) (paste this) ---")
            print(try SafetyLint.json(paste), terminator: "")
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
            // The paste map never exceeds the baseline, on the live data...
            let paste = SafetyLint.shrunk(baseline: baseline, counts: counts)
            for rule in SafetyLint.Rule.allCases {
                for (path, kept) in paste[rule] ?? [:] { #expect(kept <= baseline[rule]?[path] ?? 0, "\(rule.rawValue) \(path)") }
            }
        }
        // ...and on a synthetic rise + fall: the fall is lowered, the rise stays at the baseline, a file that dropped to 0 is
        // gone, and a file the baseline does not list never enters it.
        let synthetic = SafetyLint.shrunk(
            baseline: [.spawn: ["a.swift": 3, "b.swift": 2, "c.swift": 1], .turnScope: ["t.swift": 1]],
            counts: [.spawn: ["a.swift": 1, "b.swift": 5, "d.swift": 4], .turnScope: ["t.swift": 1]])
        #expect(synthetic[.spawn] == ["a.swift": 1, "b.swift": 2])
        #expect(synthetic[.turnScope] == ["t.swift": 1])
        #expect(synthetic[.descriptor] == [:], "every rule is present, empty when it has no entry")
    }

    /// A rule's `zero` directories have no hit. S3 set the first (`spawn` in `Verify/` and `Sandbox/`); later tasks fill the rest.
    @Test func zeroScopesAreZero() throws {
        let hits = try SafetyLint.hits(root: Self.root)
        var offenders: [String] = []
        for rule in SafetyLint.Rule.allCases {
            offenders += SafetyLint.zeroOffenders(hits[rule] ?? [], zero: rule.zero, exempt: rule.zeroExempt).map { "\(rule.rawValue): \($0)" }
            // An exemption names a file inside one of the rule's zero directories, with a reason, and the baseline still bounds it.
            for (path, reason) in rule.zeroExempt {
                #expect(!reason.isEmpty, "\(rule.rawValue): \(path) needs a reason")
                #expect(SafetyLint.zeroOffenders([SafetyLint.Hit(path: path, line: 1, text: "")], zero: rule.zero).count == 1,
                        "\(rule.rawValue): \(path) is not inside a zero directory; drop the exemption")
                #expect((try SafetyLint.baseline(root: Self.root))?[rule]?[path] != nil, "\(rule.rawValue): \(path) must stay in the baseline")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "hits in a zero scope:\n" + offenders.joined(separator: "\n")))

        // The prefix logic: a hit inside a zero directory is an offender, one outside is not, and
        // a directory prefix matches whole path components only (Refs/ is not RefsX/), with or without its trailing slash.
        let synthetic = ["Sources/BrahmaCore/Refs/A.swift", "Sources/BrahmaCore/RefsX/B.swift", "Sources/BrahmaCore/Git/C.swift",
                         "Sources/BrahmaCore/Refs.swift"].map { SafetyLint.Hit(path: $0, line: 1, text: "") }
        for zero in [["Sources/BrahmaCore/Refs/"], ["Sources/BrahmaCore/Refs"]] {
            #expect(SafetyLint.zeroOffenders(synthetic, zero: zero).map(\.path) == ["Sources/BrahmaCore/Refs/A.swift"], "\(zero)")
        }
        #expect(SafetyLint.zeroOffenders(synthetic, zero: []).isEmpty)
        #expect(SafetyLint.zeroOffenders(synthetic, zero: ["Sources/BrahmaCore/Refs/"], exempt: ["Sources/BrahmaCore/Refs/A.swift": "why"]).isEmpty)
        #expect(SafetyLint.zeroOffenders(synthetic, zero: ["Sources/BrahmaCore/Git", "Sources/brahma"]).map(\.path) == ["Sources/BrahmaCore/Git/C.swift"])
    }

    /// Ruling S3-2: a zero scope (or an exemption) outside the scanned roots would pass whatever its directory holds.
    @Test func zeroScopesLieUnderScannedRoots() {
        for rule in SafetyLint.Rule.allCases {
            #expect(SafetyLint.unscanned(rule.zero).isEmpty, "\(rule.rawValue): \(SafetyLint.unscanned(rule.zero)) is not scanned")
            #expect(SafetyLint.unscanned(Array(rule.zeroExempt.keys)).isEmpty, "\(rule.rawValue): an exemption outside the scan")
            #expect(SafetyLint.unscanned(rule.only ?? []).isEmpty, "\(rule.rawValue): a scope outside the scan")
            // A scoped rule is a zero rule wherever it looks.
            if let only = rule.only { #expect(Set(only) == Set(rule.zero), "\(rule.rawValue): its scope is its zero scope") }
        }
        #expect(SafetyLint.Rule.failOpen.zero.contains("Sources/BrahmaSafety/"), "the kernel is a failOpen zero scope")
        // Whole path components only, with or without the trailing `/`.
        let roots = ["Sources/BrahmaCore", "Sources/BrahmaSafety"]
        #expect(SafetyLint.unscanned(["Sources/BrahmaCore/Refs/", "Sources/BrahmaSafety", "Sources/BrahmaSafety/", "Sources/BrahmaCore/A.swift"],
                                     roots: roots).isEmpty)
        #expect(SafetyLint.unscanned(["Sources/BrahmaSafetyX/", "Sources/brahma/", "Sources/", "Tests/BrahmaCoreTests/"], roots: roots)
                == ["Sources/BrahmaSafetyX/", "Sources/brahma/", "Sources/", "Tests/BrahmaCoreTests/"])
    }

    /// The scan is live: known sites are found (the kernel included), and the `alertScope` argument-list matcher reads to the
    /// matching `)`.
    @Test func scanFindsKnownSites() throws {
        let counts = try SafetyLint.scan(root: Self.root)
        #expect((counts[.spawn]?["Sources/BrahmaCore/Git/GitWorkspace.swift"] ?? 0) > 0, "spawn: GitWorkspace starts git")
        #expect((counts[.sandboxPolicy]?["Sources/BrahmaCore/Sandbox/SandboxedCheckRunner.swift"] ?? 0) > 0,
                "sandboxPolicy: the check runner builds a policy")
        #expect((counts[.descriptor]?["Sources/BrahmaSafety/Path/EngineFiles.swift"] ?? 0) > 0, "descriptor: the kernel is scanned")
        // S4: every `EngineAlerts.raise` names its scope (the compiler requires it too).
        #expect(counts[.alertScope]?.isEmpty ?? true, "alertScope: \(counts[.alertScope] ?? [:])")

        // `failOpen`: the three shapes of spec §6.8.2 plus spec §6.7's empty `catch` and `catch` ending in `return true`.
        func failOpen(_ code: String) -> Int { SafetyLint.regexHits(in: code, pattern: SafetyLint.Rule.failOpen.pattern).count }
        #expect(failOpen("let x = try? f()") == 1)
        #expect(failOpen("let ok = flag ?? true\nlet no = flag ??  false") == 2)
        #expect(failOpen("do { try f() } catch {}") == 1)
        #expect(failOpen("do { try f() } catch let e as Boom {\n    \n}") == 1)
        #expect(failOpen("do { try f() } catch {\n    log(error)\n    return true\n}") == 1)
        #expect(failOpen("do { try f() } catch { return false }") == 0)
        #expect(failOpen("do { try f() } catch { log(error) }") == 0)
        #expect(failOpen("do { try f() } catch { return trueish }") == 0)
        #expect(failOpen("let entry? = x; let y = a ?? trueValue") == 0)
        // S4 fix round 1 (M3): the shapes the first matcher missed, one each, and their near misses.
        #expect(failOpen("do { try f() } catch { return true; }") == 1, "a trailing semicolon")
        #expect(failOpen("do { try f() }\ncatch\n{\n    log(error)\n    return true\n}") == 1, "the `{` on the next line")
        #expect(failOpen("do { try f() } catch let e as Boom\n{\n}") == 1, "an empty body opened on the next line")
        #expect(failOpen("do { try f() } catch {\n    if bad { log(error) }\n    for x in y { if x { z() } }\n    return true\n}") == 1,
                "nested blocks before the `return true`")
        #expect(failOpen("do { try f() } catch { return (true) }") == 1, "a parenthesized `true`")
        #expect(failOpen("do { try f() } catch { () }") == 1, "an empty tuple is an empty body")
        #expect(failOpen("let ok = flag ?? (true)\nlet no = flag ?? ( false )") == 2, "a parenthesized default")
        #expect(failOpen("return row.map { (true, $0) } ?? (false, nil)") == 0, "a tuple default is not a `Bool` default")
        #expect(failOpen("do { try f() } catch {\n    if bad { return true }\n    log(error)\n}") == 0, "`return true` not last")
        #expect(failOpen("do { try f() } catch { return (trueish) }") == 0)
        #expect(failOpen("do { try f() } catch { (log(error)) }") == 0)

        // `publicBool` (Ruling S4-B): a public function returning `Bool`, on one line or several; never an internal one or one
        // returning a `Decision`.
        func publicBool(_ code: String) -> Int { SafetyLint.regexHits(in: code, pattern: SafetyLint.Rule.publicBool.pattern).count }
        #expect(publicBool("public static func isAllowed(_ x: Int) -> Bool { true }") == 1)
        #expect(publicBool("public func check(\n    _ x: Int\n) throws -> Bool {\n    true\n}") == 1)
        #expect(publicBool("public nonisolated func ok() -> Bool? { nil }") == 1)
        #expect(publicBool("func internalCheck() -> Bool { true }") == 0)
        #expect(publicBool("public func decide() -> Decision<Int> { .deny(\"no\") }\nfunc other() -> Bool { true }") == 0)
        #expect(publicBool("public var isOK: Bool { true }") == 0)

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
