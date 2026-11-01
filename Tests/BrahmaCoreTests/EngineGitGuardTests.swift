import Testing
import Foundation
@testable import BrahmaCore

/// Engine git runs only in `Blocking` bodies, never on the orchestrator's actor or the cooperative pool. Two guards:
/// the static one here (sources), and the run-time one (`EngineGitGuard`), which makes `waitUntilIdle` throw in every test.
@Suite(.scratch) struct EngineGitGuardTests {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The sanctioned places, listed explicitly:
    /// - `GitCommand` (the one way git is started) is used only in `Git/GitWorkspace.swift`; everything else goes through
    ///   `GitWorkspace`.
    /// - A git process (`"git"` as a program argument) is started only there too.
    /// - In the engine (`Orchestrator*.swift`) every call that runs git sits inside a `blocking.run` / `blocking.tryRun`
    ///   closure, or inside one of the blocking-only helpers below, which are themselves only called from such a closure.
    static let gitCommandFiles: Set<String> = ["Sources/BrahmaCore/Git/GitWorkspace.swift"]
    static let blockingOnlyHelpers = ["prepareReview", "prepareAudit", "escalate", "touchesScope", "finishPlanTurn"]
    /// What runs git when called (GitWorkspace methods, the store's git steps, Plan L's `EngineExport` and the helpers above).
    static let gitCalls = #"\bEngineExport\.(export|remove)\b|\.(ensureRepo|addWorktree|removeWorktree|itemWorktrees|deleteBranch|addRunWorktree|removeRunWorktrees?|addEngineExport|commitAll|headCommit|resetHard|planBarrier|enforcePlanBarrier|isDirty|head\(of|mergeBase|isAncestor|nameStatus|blobs|treeHasDirectory|diff\(base|changeStats|log\(base|commitsBehind|mergeConflicts|fileDiff|checkedOutRef|mainIsSymbolic|landVerified|quarantineRoot|mergeQuarantine|prepareRepo|checkMain|ensureCheckSnapshot|performMerge\(item|finishMerge|recoverMerges\(\)|assessAutoMerge|acceptMainCommit|installedGitVersion|installedGitMerges|hooksPath|setHooksPath)\b|\bCompanyHooks\.install\(|\bTurnContext\.load\(|\b(prepareReview|prepareAudit|finishPlanTurn|touchesScope)\(|\bescalate\(itemId:"#

    static func sources(under dir: String) throws -> [(path: String, text: String)] {
        let base = packageRoot.appending(path: dir)
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(packageRoot.standardizedFileURL.path.count + 1))
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The code of a file with comments blanked out (lengths kept, so offsets still line up).
    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound]) + String(repeating: " ", count: line.distance(from: r.lowerBound, to: line.endIndex))
        }.joined(separator: "\n")
    }

    @Test func gitCommandIsUsedOnlyInGitWorkspace() throws {
        var offenders: [String] = []
        for (path, text) in try Self.sources(under: "Sources") where !Self.gitCommandFiles.contains(path) {
            let code = Self.code(text)
            if code.contains("GitCommand") { offenders.append("\(path): GitCommand") }
            if code.range(of: #"\[\s*"git"\s*[,\]]"#, options: .regularExpression) != nil { offenders.append("\(path): starts git") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// Every git call in the engine's own files is inside a blocking closure or a blocking-only helper.
    @Test func engineGitCallsAreInsideBlockingBodies() throws {
        let engine = try Self.sources(under: "Sources/BrahmaCore").filter { $0.path.hasPrefix("Sources/BrahmaCore/Orchestrator") }
        #expect(engine.count >= 8)
        var offenders: [String] = []
        var checked = 0
        for (path, text) in engine {
            let code = Self.code(text)
            let chars = Array(code.utf16)
            let blocking = Self.closureRanges(in: code, opener: #"blocking\.(try)?[rR]un\s*(\(\s*)?\{"#, chars: chars)
                + Self.functionBodies(in: code, names: Self.blockingOnlyHelpers, chars: chars)
            let regex = try NSRegularExpression(pattern: Self.gitCalls)
            for match in regex.matches(in: code, range: NSRange(location: 0, length: chars.count)) {
                let at = match.range.location
                // A declaration, not a call.
                let before = (code as NSString).substring(with: NSRange(location: max(0, at - 40), length: min(40, at)))
                if before.range(of: #"func\s+\w*$"#, options: .regularExpression) != nil { continue }
                checked += 1
                if !blocking.contains(where: { $0.contains(at) }) {
                    let line = code.utf16.prefix(at).filter { $0 == 10 }.count + 1
                    offenders.append("\(path):\(line): \((code as NSString).substring(with: match.range))")
                }
            }
        }
        #expect(checked >= 15, "the scan found too few git calls (\(checked)); is the pattern still right?")
        #expect(offenders.isEmpty, "engine git outside a blocking body: \(offenders)")
    }

    /// Plan L's export runs git (3a's `addEngineExport`): the scan counts `EngineExport.export`/`.remove` as git calls, and
    /// not the path lookup `EngineExport.directory`.
    @Test func engineExportCountsAsAGitCall() throws {
        let regex = try NSRegularExpression(pattern: Self.gitCalls)
        func hits(_ code: String) -> Bool { regex.firstMatch(in: code, range: NSRange(location: 0, length: code.utf16.count)) != nil }
        #expect(hits("let run = try EngineExport.export(store: store, company: c, runId: id, commit: main)"))
        #expect(hits("EngineExport.remove(store: store, company: c, runId: id)"))
        #expect(!hits("let dir = EngineExport.directory(store: store, company: c, runId: id)"))
        // Outside a blocking body in an engine file it would be reported.
        let code = Self.code("func step() {\n    _ = try? EngineExport.export(store: s, company: c, runId: r, commit: m)\n    blocking.run { EngineExport.remove(store: s, company: c, runId: r) }\n}")
        let chars = Array(code.utf16)
        let blocking = Self.closureRanges(in: code, opener: #"blocking\.(try)?[rR]un\s*(\(\s*)?\{"#, chars: chars)
        let calls = regex.matches(in: code, range: NSRange(location: 0, length: chars.count)).map(\.range.location)
        #expect(calls.count == 2)
        #expect(calls.filter { at in !blocking.contains { $0.contains(at) } }.count == 1, "the export outside blocking.run")
    }

    /// Plan L's Pages `functions/` decision reads the commit's tree with git (`GitWorkspace.treeHasDirectory`, PR-24): the scan
    /// counts it, so an engine call outside a blocking body is reported statically, not only at run time.
    @Test func treeHasDirectoryCountsAsAGitCall() throws {
        let regex = try NSRegularExpression(pattern: Self.gitCalls)
        func hits(_ code: String) -> Bool { regex.firstMatch(in: code, range: NSRange(location: 0, length: code.utf16.count)) != nil }
        #expect(hits("let functions = try git.treeHasDirectory(at: commit, path: \"functions\")"))
        #expect(!hits("let functions = input.functionsInCommit"))
        let code = Self.code("func render() {\n    _ = try? git.treeHasDirectory(at: c, path: \"functions\")\n    blocking.run { try? git.treeHasDirectory(at: c, path: \"functions\") }\n}")
        let chars = Array(code.utf16)
        let blocking = Self.closureRanges(in: code, opener: #"blocking\.(try)?[rR]un\s*(\(\s*)?\{"#, chars: chars)
        let calls = regex.matches(in: code, range: NSRange(location: 0, length: chars.count)).map(\.range.location)
        #expect(calls.count == 2)
        #expect(calls.filter { at in !blocking.contains { $0.contains(at) } }.count == 1, "the tree read outside blocking.run")
    }

    /// The extent of each closure opened by `opener` (brace matched from its `{`).
    static func closureRanges(in code: String, opener: String, chars: [UInt16]) -> [Range<Int>] {
        guard let regex = try? NSRegularExpression(pattern: opener) else { return [] }
        return regex.matches(in: code, range: NSRange(location: 0, length: chars.count)).compactMap { m in
            braceRange(from: m.range.location + m.range.length - 1, chars: chars)
        }
    }

    /// The bodies of the functions named `names`.
    static func functionBodies(in code: String, names: [String], chars: [UInt16]) -> [Range<Int>] {
        names.flatMap { name -> [Range<Int>] in
            guard let regex = try? NSRegularExpression(pattern: #"func\s+\#(name)\s*\("#) else { return [] }
            return regex.matches(in: code, range: NSRange(location: 0, length: chars.count)).compactMap { m in
                guard let open = chars[(m.range.location)...].firstIndex(of: 123) else { return nil }   // "{"
                return braceRange(from: open, chars: chars)
            }
        }
    }

    static func braceRange(from open: Int, chars: [UInt16]) -> Range<Int>? {
        guard chars.indices.contains(open), chars[open] == 123 else { return nil }
        var depth = 0
        for i in open..<chars.count {
            if chars[i] == 123 { depth += 1 } else if chars[i] == 125 { depth -= 1; if depth == 0 { return open..<(i + 1) } }
        }
        return nil
    }

    // MARK: The run-time guard

    @Test func gitStartedFromAnEngineTaskIsReportedAndFromABlockingBodyIsNot() async throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let ws = f.ws
        let id = "guard-\(UUID().uuidString)"
        // Off the pool, in a blocking body of an engine task: fine.
        let blocking = Blocking()
        _ = await EngineGitGuard.$engine.withValue(id) { await blocking.run { try? ws.head(of: GitWorkspace.mainRef) } }
        #expect(EngineGitGuard.takeViolations(engine: id).isEmpty)
        // On the engine task itself: reported, with the command.
        EngineGitGuard.$engine.withValue(id) { _ = try? ws.head(of: GitWorkspace.mainRef) }
        let found = EngineGitGuard.takeViolations(engine: id)
        #expect(found.count == 1); #expect(found.first?.hasPrefix("git rev-parse") == true, "\(found)")
        // Not an engine task (a test, the CLI, an MCP tool): not the engine's business.
        _ = try ws.head(of: GitWorkspace.mainRef)
        #expect(EngineGitGuard.takeViolations(engine: id).isEmpty)
    }

    @Test func waitUntilIdleReportsEngineGitOffBlocking() async throws {
        let w = try World()
        let f = try GitFixture(files: ["a.txt": "one"])
        let ws = f.ws
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(300))
        await EngineGitGuard.$engine.withValue(w.orchestrator.engineId) { _ = try? ws.head(of: GitWorkspace.mainRef) }
        await #expect(throws: OrchestratorError.self) { try await w.orchestrator.waitUntilIdle(timeout: .seconds(300)) }
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(300))
    }
}
