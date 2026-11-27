import Foundation
import GRDB

/// What `brahma measure <co> --verify-landings` found on `main` (Plan X6a Task 6): every first-parent commit from `main`'s tip
/// back to the company's first commit, each classified once. Lists are commit ids, newest first.
public struct LandingAuditResult: Codable, Equatable, Sendable {
    /// First-parent commits audited.
    public var commits: Int
    /// Commits the merge queue landed (`LandingAudit` says which count).
    public var verified: Int
    /// Commits the owner accepted into `main` (`brahma main accept`, `brahma merge adopt-main`, a quarantine accept; ruling R38).
    public var ownerAccepted: [String]
    /// The company's first commit: `company.importedCommit`, else the root of first-parent history.
    public var imported: [String]
    /// Every other commit.
    public var unverified: [String]
    /// Records that `main`'s history was put back or moved outside Brahma: restores, a head that is not the recorded one.
    public var historyChanged: [String]
    /// The walk stopped at `LandingAudit.maxCommits` commits before the first one; nil when it reached it.
    public var truncatedAt: Int?
    /// The subjects of the first `LandingAudit.maxListed` unverified commits, by commit id, as git stores them: agent-controlled
    /// text, sanitized by whoever prints it.
    public var subjects: [String: String] = [:]
    /// What the audit covered: the tip and where the walk ended.
    public var basis: String = ""

    public init(commits: Int, verified: Int, ownerAccepted: [String], imported: [String], unverified: [String], historyChanged: [String],
                truncatedAt: Int?) {
        self.commits = commits; self.verified = verified; self.ownerAccepted = ownerAccepted; self.imported = imported
        self.unverified = unverified; self.historyChanged = historyChanged; self.truncatedAt = truncatedAt
    }

    /// Every audited commit is verified, owner-accepted or imported, and the walk reached the first commit.
    public var allClassified: Bool { unverified.isEmpty && truncatedAt == nil }

    /// `landings verified: 100% (412/412); owner-accepted 2; imported 1`. The denominator is every audited commit neither
    /// owner-accepted nor imported: the commits only the merge queue may have put there. The percentage is rounded down, so
    /// 100% means every one.
    public var summary: String {
        let queue = verified + unverified.count
        let share = queue == 0 ? "none to verify" : "\(verified * 100 / queue)%"
        return "landings verified: \(share) (\(verified)/\(queue)); owner-accepted \(ownerAccepted.count); imported \(imported.count)"
    }

    /// The report, one line each: the summary, where the walk stopped (when bounded), each history change, each unverified commit
    /// (`unverified: <sha7> <subject>`, at most `LandingAudit.maxListed`, then how many more). Plain text: subjects are printed
    /// as git stores them, so a terminal caller sanitizes every line.
    public func lines() -> [String] {
        var out = [summary]
        if let truncatedAt { out.append("stopped at \(truncatedAt) commits: older history of main was not audited") }
        out += historyChanged.map { "history changed: \($0)" }
        for sha in unverified.prefix(LandingAudit.maxListed) {
            out.append("unverified: \(sha.prefix(7)) \(subjects[sha] ?? "(subject not read)")")
        }
        if unverified.count > LandingAudit.maxListed { out.append("unverified: … and \(unverified.count - LandingAudit.maxListed) more") }
        return out
    }
}

/// The store's records the landing audit classifies commits against, read in one snapshot (`LandingAudit.records`).
public struct LandingRecords: Equatable, Sendable {
    /// One request of a landed batch, in `landedIds` order: its candidate commit (nil when `candidates` has none for it: a gap
    /// that verifies nothing and bounds nothing), and whether this batch merged it (ruling R24).
    public struct Link: Equatable, Sendable {
        public var commit: String?
        public var merged: Bool
        public init(commit: String?, merged: Bool) { self.commit = commit; self.merged = merged }
    }

    /// A landing (`Store.landings`, rulings R13/R24) with every request of its `landedIds`.
    public struct Batch: Equatable, Sendable {
        public var number: Int
        /// `mergeBatch.base`: the first request's chain starts above it.
        public var base: String?
        public var chain: [Link]
        /// A `main` or `item` check of the batch passed at its land commit (ruling R23; `mainAtBase` never judges a candidate).
        public var passed: Bool
        public init(number: Int, base: String?, chain: [Link], passed: Bool) {
            self.number = number; self.base = base; self.chain = chain; self.passed = passed
        }
    }

    /// An owner acceptance as `mainAccept` records it (ruling R38): the full commit `main` was recorded at and the record it
    /// replaced.
    public struct Accept: Equatable, Sendable {
        public var commit: String
        public var previousHead: String?
        public var kind: MainAcceptKind
        public init(commit: String, previousHead: String?, kind: MainAcceptKind) {
            self.commit = commit; self.previousHead = previousHead; self.kind = kind
        }
    }

    /// An owner acceptance from before `mainAccept` existed, known only from the engine's activity text: the head's first seven
    /// hex digits and when it was accepted.
    public struct LegacyAccept: Equatable, Sendable {
        public var prefix: String
        public var at: Date
        public init(prefix: String, at: Date) { self.prefix = prefix; self.at = at }
    }

    public var batches: [Batch] = []
    public var accepts: [Accept] = []
    public var legacyAccepts: [LegacyAccept] = []
    /// Every commit the store records other than an accept's own (ruling R38a): each `mergeBatch` at or after `landed` (passed,
    /// merged or not) — its base, candidates and land commit —, `importedCommit`, and every restore's `mainCommit`. Such a
    /// commit is decided by its own record, is never owner-accepted, and ends an accept's run.
    public var recorded: Set<String> = []
    /// `company.importedCommit`.
    public var importedCommit: String?
    /// With `since`: the land commit of the newest landing that finished before it. The walk stops below it (exclusive).
    public var stopBefore: String?
    /// `company.mainCommit`: the head the engine recorded.
    public var recordedMain: String?
    /// `company.pendingMainCommit`: the head the engine is about to move `main` to.
    public var pendingMain: String?
    /// A merge batch is moving `main` (step `backedUp` or `landing`).
    public var batchLanding = false
    /// One line per restore of the company (`restoreMain` with its `restoreEvent`, `restoreEpoch`).
    public var restores: [String] = []

    public init() {}
}

/// The landing audit (Plan X6a Task 6): walks `main`'s first-parent history and classifies each commit.
///
/// - **verified**: the merge queue landed it. For each landing (`Store.landings`: `landCommit`, a step at or after `landed`, a
///   request it merged — rulings R13, R24) whose batch has a passed `main` or `item` check at its land commit, each request it
///   merged verifies its candidate (`candidates[requestId]`; the last is the land commit, which 4a fast-forwards `main` to,
///   through every candidate before it) and the commits between that candidate and the one below it in the chain (the
///   previous candidate, or the batch's base) on first-parent history (ruling R35): an item whose branch held several commits
///   lands as a rebased chain of them. A request the batch did not merge (requeued from an abandoned batch) verifies nothing.
/// - **owner-accepted** (rulings R38, R38a): a `mainAccept` record's commit, and the first-parent run below it down to its
///   `previousHead` (exclusive), stopping (exclusive) at the first commit the store records (`LandingRecords.recorded`) or
///   another accept's commit. A store-recorded commit is never owner-accepted. An acceptance from before `mainAccept`
///   (activity text, no agent or turn, the engine's exact wording) covers one commit only: the single walked commit with its
///   seven-digit prefix, committed before the acceptance; two walked commits sharing the prefix match neither.
/// - **imported**: the company's first `main` commit (ruling R16): `company.importedCommit`, else the root of first-parent
///   history, which must have no parent in its object (a planted `shallow` or `info/grafts` file is refused before the walk).
/// - **unverified**: everything else.
///
/// Read-only: one store snapshot, then git (`GitWorkspace.firstParentHistory`, `commitParents`, `commitTimes(of:)`,
/// `subjects(of:)`); nothing is written. It cannot audit (throws `MeasureError`) without a `main`, over planted history files,
/// over a cut history, or while a merge batch is moving `main`.
public struct LandingAudit {
    /// The most first-parent commits one audit walks.
    public static let maxCommits = 10_000
    /// The most unverified commits listed by subject.
    public static let maxListed = 200

    public static func run(store: Store, git: GitWorkspace, companyId: String, since: Date?) throws -> LandingAuditResult {
        try run(store: store, git: git, companyId: companyId, since: since, maxCommits: maxCommits)
    }

    /// `run` with its bound given (tests).
    public static func run(store: Store, git: GitWorkspace, companyId: String, since: Date?, maxCommits: Int) throws -> LandingAuditResult {
        let recs = try records(store: store, companyId: companyId, since: since)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.gitDir.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let tip = try git.head(of: GitWorkspace.mainRef) else { throw MeasureError.noMainBranch(companyId) }
        // A `shallow` or `info/grafts` file makes git end the history wherever it says: never walked.
        guard !git.hasPlantedHistoryFiles else { throw MeasureError.plantedHistory(companyId) }
        guard !recs.batchLanding, recs.pendingMain == nil || recs.pendingMain != tip else { throw MeasureError.mergeBatchOpen }
        // One more than the bound: a full listing says the walk did not reach the root.
        let walk = try git.firstParentHistory(from: tip, limit: maxCommits + 1)
        // The root's parents as its object records them, read only when the walk reached a root.
        let rootParents = walk.count <= maxCommits ? try walk.last.map { try git.commitParents($0) } ?? [] : []
        try checkRoot(walk: walk, parents: rootParents, maxCommits: maxCommits)
        let candidates = legacyCandidates(walk: walk, records: recs)
        var result = classify(walk: walk, records: recs, maxCommits: maxCommits,
                              commitTimes: try git.commitTimes(of: Array(candidates.prefix(GitWorkspace.maxSubjectLookup))))
        if try git.mainIsSymbolic() { result.historyChanged.append("main is a symbolic ref (not Brahma's)") }
        let listed = Array(result.unverified.prefix(maxListed))
        result.subjects = try git.subjects(of: listed)
        return result
    }

    /// A walk no longer than `maxCommits` reached the root of first-parent history; that root must have no parent in its own
    /// object (`parents`, `GitWorkspace.commitParents`), else the history was cut and is not audited. A longer walk stopped at
    /// the bound and judges nothing. Pure (Task 6 review #13).
    static func checkRoot(walk: [String], parents: [String], maxCommits: Int) throws {
        if walk.count <= maxCommits, let root = walk.last, !parents.isEmpty { throw MeasureError.historyCut(String(root.prefix(7))) }
    }

    /// The company's records, in one read. `since` (nil: the whole history) picks `stopBefore`. Every query is the company's own.
    public static func records(store: Store, companyId: String, since: Date?) throws -> LandingRecords {
        try store.writer.read { db in
            guard let company = try Row.fetchOne(db, sql: "SELECT importedCommit, mainCommit, pendingMainCommit FROM company WHERE id = ?",
                                                 arguments: [companyId]) else { throw MeasureError.unknownCompany(companyId) }
            var recs = LandingRecords()
            recs.importedCommit = company["importedCommit"]
            recs.recordedMain = company["mainCommit"]
            recs.pendingMain = company["pendingMainCommit"]
            if let imported = recs.importedCommit { recs.recorded.insert(imported) }

            let landings = try Store.landings(db, companyId: companyId, in: nil)
            // The step names are bound, never spliced into the text (Task 6 review #16).
            let steps = Store.landedSteps.map(\.rawValue)
            let marks = steps.map { _ in "?" }.joined(separator: ", ")
            var raw: [String: MergeBatch] = [:]
            for b in try MergeBatch.fetchAll(db, sql: "SELECT * FROM mergeBatch WHERE companyId = ? AND step IN (\(marks))",
                                             arguments: StatementArguments([companyId]) + StatementArguments(steps)) {
                raw[b.id] = b
                // Ruling R38a: every landed-step batch's commits are the store's, passed and merged or not.
                if let base = b.base { recs.recorded.insert(base) }
                if let land = b.landCommit { recs.recorded.insert(land) }
                recs.recorded.formUnion(b.candidates.values.filter { !$0.isEmpty })
            }
            let landingNow = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mergeBatch WHERE companyId = ? AND step IN (?, ?)",
                                              arguments: [companyId, MergeStep.backedUp.rawValue, MergeStep.landing.rawValue])
            recs.batchLanding = (landingNow ?? 0) > 0
            var passed = Set<String>()
            for row in try Row.fetchAll(db, sql: """
                SELECT DISTINCT batchId, candidateCommit FROM mergeRun
                WHERE companyId = ? AND batchId IS NOT NULL AND candidateCommit IS NOT NULL AND kind IN ('main', 'item') AND status = 'passed'
                """, arguments: [companyId]) {
                let batchId: String = row["batchId"], candidate: String = row["candidateCommit"]
                passed.insert("\(batchId) \(candidate)")
            }
            recs.batches = landings.compactMap { landing -> LandingRecords.Batch? in
                guard let b = raw[landing.batchId] else { return nil }
                let merged = Set(landing.items.map(\.requestId))
                // A landed id with no candidate stays in the chain as a gap (review #5): it bounds the next link's range.
                let chain = b.landedIds.map { id in LandingRecords.Link(commit: b.candidates[id], merged: merged.contains(id)) }
                return LandingRecords.Batch(number: landing.number, base: b.base, chain: chain,
                                            passed: passed.contains("\(landing.batchId) \(landing.landCommit)"))
            }
            if let since {
                recs.stopBefore = landings.filter { $0.finishedAt < since }.max { $0.finishedAt < $1.finishedAt }?.landCommit
            }

            for row in try Row.fetchAll(db, sql: """
                SELECT "commit", previousHead, kind FROM mainAccept WHERE companyId = ? ORDER BY createdAt, id
                """, arguments: [companyId]) {
                let kind: String = row["kind"]
                guard let k = MainAcceptKind(rawValue: kind) else { continue }
                recs.accepts.append(LandingRecords.Accept(commit: row["commit"], previousHead: row["previousHead"], kind: k))
            }
            // Acceptances from before `mainAccept`: activity text only (ruling R38). No epoch row: every row is that old.
            let epoch: Date? = try Row.fetchOne(db, sql: "SELECT at FROM measureEpoch WHERE name = 'mainAccept'")?["at"]
            var legacySQL = """
                SELECT kind, text, createdAt FROM activityEvent
                WHERE companyId = ? AND agentId IS NULL AND turnId IS NULL AND kind IN ('merge', 'work')
                  AND (text LIKE 'main adopted at %' OR text LIKE 'the owner accepted %')
                """
            var legacyArguments: StatementArguments = [companyId]
            if let epoch { legacySQL += " AND createdAt < ?"; legacyArguments += [epoch] }
            for row in try Row.fetchAll(db, sql: legacySQL + " ORDER BY createdAt, id", arguments: legacyArguments) {
                let kind: String = row["kind"], text: String = row["text"], at: Date = row["createdAt"]
                if let prefix = acceptedPrefix(kind: kind, text: text) { recs.legacyAccepts.append(LandingRecords.LegacyAccept(prefix: prefix, at: at)) }
            }

            var restoreSQL = """
                SELECT e.restoredAt AS at, m.mainCommit AS mainCommit, 0 AS unreadable FROM restoreMain m
                JOIN restoreEvent e ON e.nonce = m.nonce WHERE m.companyId = ?
                """
            var epochSQL = "SELECT createdAt AS at, mainCommit, 1 AS unreadable FROM restoreEpoch WHERE companyId = ?"
            var arguments: StatementArguments = [companyId]
            var epochArguments: StatementArguments = [companyId]
            if let since {
                restoreSQL += " AND e.restoredAt >= ?"; arguments += [since]
                epochSQL += " AND createdAt >= ?"; epochArguments += [since]
            }
            var restores: [(at: Date, line: String)] = []
            for (sql, args) in [(restoreSQL, arguments), (epochSQL, epochArguments)] {
                for row in try Row.fetchAll(db, sql: sql, arguments: args) {
                    let at: Date = row["at"], main: String? = row["mainCommit"], unreadable: Bool = row["unreadable"]
                    if let main { recs.recorded.insert(main) }
                    let to = main.map { "main restored to \($0.prefix(7))" } ?? "no main recorded"
                    restores.append((at, "restore at \(MeasureReport.iso(at))\(unreadable ? " (database unreadable)" : ""): \(to)"))
                }
            }
            if since != nil {
                // A restore before the window still records its commit (R38a), though it is not reported.
                for main in try String.fetchAll(db, sql: """
                    SELECT m.mainCommit FROM restoreMain m WHERE m.companyId = ? AND m.mainCommit IS NOT NULL
                    UNION SELECT mainCommit FROM restoreEpoch WHERE companyId = ? AND mainCommit IS NOT NULL
                    """, arguments: [companyId, companyId]) { recs.recorded.insert(main) }
            }
            recs.restores = restores.sorted { $0.at < $1.at }.map(\.line)
            return recs
        }
    }

    /// The accepted head's seven-digit prefix in a pre-`mainAccept` owner accept row, or nil: the engine's own wording, exactly
    /// (the engine's re-affirmation and anything else is none).
    static func acceptedPrefix(kind: String, text: String) -> String? {
        func whole(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if kind == ActivityKind.merge.rawValue, whole(#"^main adopted at [0-9a-f]{7} by the owner\z"#) {
            return String(text.dropFirst("main adopted at ".count).prefix(7))
        }
        // The ref holds no space, so the first " into main at " is the engine's.
        if kind == ActivityKind.work.rawValue,
           whole(#"^the owner accepted refs/brahma/quarantine/[0-9A-Za-z-]+ \([0-9a-f]{12}\) into main at [0-9a-f]{7}(?: \([^)]*\))?\z"#),
           let at = text.range(of: " into main at ") {
            return String(text[at.upperBound...].prefix(7))
        }
        return nil
    }

    /// The walked commits a legacy accept could name: the one commit with its prefix (two or more sharing it: none), not
    /// recorded by the store. Their commit times decide (`classify`).
    static func legacyCandidates(walk: [String], records: LandingRecords) -> [String] {
        records.legacyAccepts.compactMap { legacy -> String? in
            let matches = walk.filter { $0.hasPrefix(legacy.prefix) }
            guard matches.count == 1, let only = matches.first, !records.recorded.contains(only) else { return nil }
            return only
        }
    }

    enum Class { case verified, ownerAccepted, imported, unverified }

    /// Classifies `walk` (`main`'s first-parent history, newest first, as `firstParentHistory` lists it, up to `maxCommits` + 1
    /// commits: a list no longer than `maxCommits` reached the root) against `records`. `commitTimes`: the committer times of
    /// `legacyCandidates` (a legacy accept matches only a commit made before it). Pure.
    public static func classify(walk: [String], records: LandingRecords, maxCommits: Int = LandingAudit.maxCommits,
                                commitTimes: [String: Date] = [:]) -> LandingAuditResult {
        var position: [String: Int] = [:]
        for (i, sha) in walk.enumerated() where position[sha] == nil { position[sha] = i }
        // Where the walk ends: below the `since` landing, at the first commit, or at the root.
        var audited = walk.count
        var importedAt: Int?
        var ending = "the root of first-parent history"
        var notes: [String] = []
        let stop = records.stopBefore.flatMap { position[$0] }
        let imp = records.importedCommit.flatMap { position[$0] }
        if let stop, stop <= (imp ?? Int.max) {
            audited = stop
            ending = "the last landing before the window (\(walk[stop].prefix(7)), not audited)"
        } else if let imp {
            audited = imp + 1
            importedAt = imp
            ending = "the import commit \(walk[imp].prefix(7))"
        } else if walk.count <= maxCommits, !walk.isEmpty {
            if let imported = records.importedCommit {
                notes.append("the import commit \(imported.prefix(7)) is not on main's first-parent history")
            } else {
                importedAt = walk.count - 1
            }
        }
        var truncatedAt: Int?
        if audited > maxCommits {
            audited = maxCommits
            truncatedAt = maxCommits
            importedAt = nil
            ending = "the bound of \(maxCommits) commits"
        }

        var classes = [Class?](repeating: nil, count: audited)
        if let importedAt { classes[importedAt] = .imported }
        // Verified: each merged request's chain, from its candidate down to (not including) the commit below it.
        for batch in records.batches where batch.passed {
            for (k, link) in batch.chain.enumerated() where link.merged {
                guard let commit = link.commit, let top = position[commit], top < audited else { continue }
                let below = k == 0 ? batch.base : batch.chain[k - 1].commit
                var end = top + 1
                if let below, let j = position[below], j > top { end = min(j, audited) }
                for i in top..<end where classes[i] == nil { classes[i] = .verified }
            }
        }
        // Owner-accepted (R38, R38a): an accept's commit and the run below it to its previous head, ending at any commit the
        // store records (another accept's commit included) or that is already classified.
        let acceptCommits = Set(records.accepts.map(\.commit))
        for accept in records.accepts {
            guard let top = position[accept.commit], top < audited, classes[top] == nil, !records.recorded.contains(accept.commit) else { continue }
            classes[top] = .ownerAccepted
            var i = top + 1
            while i < audited, classes[i] == nil, walk[i] != accept.previousHead, !records.recorded.contains(walk[i]),
                  !acceptCommits.contains(walk[i]) {
                classes[i] = .ownerAccepted
                i += 1
            }
        }
        // Legacy accepts: one commit each, unique on the walk, committed before the acceptance.
        for legacy in records.legacyAccepts {
            let matches = walk.indices.filter { walk[$0].hasPrefix(legacy.prefix) }
            guard matches.count == 1, let i = matches.first, i < audited, classes[i] == nil, !records.recorded.contains(walk[i]),
                  let made = commitTimes[walk[i]], made < legacy.at else { continue }
            classes[i] = .ownerAccepted
        }

        let commits = Array(walk.prefix(audited))
        func with(_ c: Class) -> [String] { zip(commits, classes).filter { ($0.1 ?? .unverified) == c }.map(\.0) }
        var history = records.restores
        if let tip = walk.first, let recorded = records.recordedMain, recorded != tip {
            history.append("main is at \(tip.prefix(7)) but the record says \(recorded.prefix(7)) (main changed outside Brahma)")
        }
        history += notes
        var result = LandingAuditResult(commits: audited, verified: with(.verified).count, ownerAccepted: with(.ownerAccepted),
                                        imported: with(.imported), unverified: with(.unverified), historyChanged: history,
                                        truncatedAt: truncatedAt)
        result.basis = walk.first.map { "first-parent history of main from \($0.prefix(7)) back to \(ending): \(audited) commits" }
            ?? "main has no commits"
        return result
    }
}
