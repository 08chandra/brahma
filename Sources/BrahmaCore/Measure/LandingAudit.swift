import Foundation
import GRDB

/// What `brahma measure <co> --verify-landings` found on `main` (Plan X6a Task 6): every first-parent commit from `main`'s tip
/// back to the company's first commit, each classified once. Lists are commit ids, newest first.
public struct LandingAuditResult: Codable, Equatable, Sendable {
    /// First-parent commits audited.
    public var commits: Int
    /// Commits the merge queue landed (`LandingAudit` says which count).
    public var verified: Int
    /// Commits the owner accepted into `main` (`brahma main accept`, `brahma merge adopt-main`, a quarantine accept).
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
    /// One request of a landed batch, in `landedIds` order: its candidate commit, and whether this batch merged it (ruling R24).
    public struct Link: Equatable, Sendable {
        public var commit: String
        public var merged: Bool
        public init(commit: String, merged: Bool) { self.commit = commit; self.merged = merged }
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

    /// An owner's acceptance of a `main` head, named by its first seven hex digits (all the activity record keeps).
    public struct Accept: Equatable, Sendable {
        public var prefix: String
        /// `brahma main accept` / `brahma merge adopt-main`: the owner accepted `main` as it stood, so the run of otherwise
        /// unclassified commits below the head is accepted with it. A quarantine accept covers only its head.
        public var adopt: Bool
        public init(prefix: String, adopt: Bool) { self.prefix = prefix; self.adopt = adopt }
    }

    public var batches: [Batch] = []
    public var accepts: [Accept] = []
    /// `company.importedCommit`.
    public var importedCommit: String?
    /// With `since`: the land commit of the newest landing that finished before it. The walk stops below it (exclusive).
    public var stopBefore: String?
    /// `company.mainCommit`: the head the engine recorded.
    public var recordedMain: String?
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
///   previous candidate, or the batch's base) on first-parent history: an item whose branch held several commits lands as a
///   rebased chain of them. A request the batch did not merge (requeued from an abandoned batch) verifies nothing.
/// - **owner-accepted**: named by an owner accept record (activity written by the engine itself, no agent or turn):
///   `main adopted at <sha7> by the owner` (`brahma main accept` with no ref, `brahma merge adopt-main`) covers that head and
///   the unbroken run of otherwise unclassified commits below it (what changed outside Brahma and was accepted);
///   `the owner accepted <quarantine ref> (<sha12>) into main at <sha7>` covers that head.
/// - **imported**: the company's first `main` commit (ruling R16): `company.importedCommit`, else the root of first-parent
///   history. Nothing below it is audited.
/// - **unverified**: everything else.
///
/// Read-only: one store snapshot, then git (`GitWorkspace.firstParentHistory`, `subjects(of:)`); nothing is written.
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
        guard let tip = try git.head(of: GitWorkspace.mainRef) else { throw MeasureError.noMainBranch(companyId) }
        // One more than the bound: a full listing says the walk did not reach the root.
        let walk = try git.firstParentHistory(from: tip, limit: maxCommits + 1)
        var result = classify(walk: walk, records: recs, maxCommits: maxCommits)
        let listed = Array(result.unverified.prefix(maxListed))
        result.subjects = try git.subjects(of: listed)
        return result
    }

    /// The company's records, in one read. `since` (nil: the whole history) picks `stopBefore`. Every query is the company's own.
    public static func records(store: Store, companyId: String, since: Date?) throws -> LandingRecords {
        try store.writer.read { db in
            guard let company = try Row.fetchOne(db, sql: "SELECT importedCommit, mainCommit FROM company WHERE id = ?",
                                                 arguments: [companyId]) else { throw MeasureError.unknownCompany(companyId) }
            var recs = LandingRecords()
            recs.importedCommit = company["importedCommit"]
            recs.recordedMain = company["mainCommit"]

            let landings = try Store.landings(db, companyId: companyId, in: nil)
            var raw: [String: MergeBatch] = [:]
            for b in try MergeBatch.fetchAll(db, sql: "SELECT * FROM mergeBatch WHERE companyId = ? AND landCommit IS NOT NULL",
                                             arguments: [companyId]) {
                raw[b.id] = b
            }
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
                let chain = b.landedIds.compactMap { id -> LandingRecords.Link? in
                    b.candidates[id].map { LandingRecords.Link(commit: $0, merged: merged.contains(id)) }
                }
                return LandingRecords.Batch(number: landing.number, base: b.base, chain: chain,
                                            passed: passed.contains("\(landing.batchId) \(landing.landCommit)"))
            }
            if let since {
                recs.stopBefore = landings.filter { $0.finishedAt < since }.max { $0.finishedAt < $1.finishedAt }?.landCommit
            }

            for row in try Row.fetchAll(db, sql: """
                SELECT kind, text FROM activityEvent
                WHERE companyId = ? AND agentId IS NULL AND turnId IS NULL AND kind IN ('merge', 'work')
                  AND (text LIKE 'main adopted at %' OR text LIKE 'the owner accepted %')
                ORDER BY createdAt, id
                """, arguments: [companyId]) {
                let kind: String = row["kind"], text: String = row["text"]
                if let accept = accept(kind: kind, text: text) { recs.accepts.append(accept) }
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
                    let to = main.map { "main restored to \($0.prefix(7))" } ?? "no main recorded"
                    restores.append((at, "restore at \(MeasureReport.iso(at))\(unreadable ? " (database unreadable)" : ""): \(to)"))
                }
            }
            recs.restores = restores.sorted { $0.at < $1.at }.map(\.line)
            return recs
        }
    }

    /// An owner accept record, or nil: the engine's own wording, exactly (the engine's re-affirmation and anything else is none).
    static func accept(kind: String, text: String) -> LandingRecords.Accept? {
        func whole(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if kind == ActivityKind.merge.rawValue, whole(#"^main adopted at [0-9a-f]{7} by the owner\z"#) {
            return LandingRecords.Accept(prefix: String(text.dropFirst("main adopted at ".count).prefix(7)), adopt: true)
        }
        // The ref holds no space, so the first " into main at " is the engine's.
        if kind == ActivityKind.work.rawValue,
           whole(#"^the owner accepted refs/brahma/quarantine/[0-9A-Za-z-]+ \([0-9a-f]{12}\) into main at [0-9a-f]{7}(?: \([^)]*\))?\z"#),
           let at = text.range(of: " into main at ") {
            return LandingRecords.Accept(prefix: String(text[at.upperBound...].prefix(7)), adopt: false)
        }
        return nil
    }

    enum Class { case verified, ownerAccepted, imported, unverified }

    /// Classifies `walk` (`main`'s first-parent history, newest first, as `firstParentHistory` lists it, up to `maxCommits` + 1
    /// commits: a list no longer than `maxCommits` reached the root) against `records`. Pure.
    public static func classify(walk: [String], records: LandingRecords, maxCommits: Int = LandingAudit.maxCommits) -> LandingAuditResult {
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
                guard let top = position[link.commit], top < audited else { continue }
                let below = k == 0 ? batch.base : batch.chain[k - 1].commit
                var end = top + 1
                if let below, let j = position[below], j > top { end = min(j, audited) }
                for i in top..<end where classes[i] == nil { classes[i] = .verified }
            }
        }
        // Owner-accepted: a named head; below an adopted one, the run of commits nothing else classifies.
        var adoptRun = false
        for i in 0..<audited {
            if classes[i] != nil { adoptRun = false; continue }
            if let accept = records.accepts.first(where: { walk[i].hasPrefix($0.prefix) }) {
                classes[i] = .ownerAccepted
                // Two records can name one head; any adopt among them starts a run.
                adoptRun = accept.adopt || records.accepts.contains { $0.adopt && walk[i].hasPrefix($0.prefix) }
            } else if adoptRun {
                classes[i] = .ownerAccepted
            }
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
