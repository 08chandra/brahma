import Foundation
import GRDB

/// Plan C Task C4b (controller ruling, carried from C4a): who made a commit comes only from the engine's own record of what
/// each turn did, never from a commit's author email (which an agent sets) nor from who holds the branch's lease now. At the
/// end of every turn the engine lists, for every item branch the turn touched, the commits the turn added (`turnCommit`);
/// the engine's own rebase carries each row to the commit it replays it as. Anything else has no verified author
/// (`CommitIndex.unverified`) and matches no `by @…` filter.
extension Store {
    /// Records the commits one turn made: for each item it held as it started (`heldAtStart`: item id → its branch head
    /// then, read by the engine) and each item it claimed during the turn (the claim log's trusted claim head), the commits of
    /// `<start>..head(item/<KEY>)` that neither `main` nor any other item branch holds. An item whose start head is unknown is
    /// skipped (its commits stay unverified: attribution fails closed, unlike taint). The first record of a sha wins. Never
    /// throws (git, off the cooperative pool).
    public func recordTurnCommits(companyId: String, agentId: String, turnId: String, heldAtStart: [String: String], now: Date) {
        var starts = heldAtStart
        do {
            let claims = try writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT itemId, claimHead FROM leaseClaim WHERE companyId = ? AND agentId = ? AND turnId = ? ORDER BY id
                    """, arguments: [companyId, agentId, turnId])
            }
            for claim in claims {
                let itemId: String = claim["itemId"]
                if starts[itemId] == nil, let head: String = claim["claimHead"] { starts[itemId] = head }    // the turn's first claim
            }
            guard !starts.isEmpty, let company = try company(id: companyId) else { return }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let main = try git.head("main")
            let branches = try git.branchHeads(prefix: "item/")
            for (itemId, start) in starts.sorted(by: { $0.key < $1.key }) {
                guard let item = try workItem(id: itemId), item.companyId == companyId, let head = branches["item/\(item.key)"],
                      head != start else { continue }
                let others = [main] + branches.filter { $0.key != "item/\(item.key)" }.map(\.value)
                let shas = try git.revList(start, head, excluding: others)
                try recordCommitAuthors(companyId: companyId, itemId: itemId, agentId: agentId, turnId: turnId, shas: shas, now: now)
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not record the commits of turn \(turnId): \(error)\n".utf8))
        }
    }

    /// Inserts one row per sha (an existing row is kept: the first record wins).
    func recordCommitAuthors(companyId: String, itemId: String?, agentId: String, turnId: String?, shas: [String], now: Date) throws {
        guard !shas.isEmpty else { return }
        try writer.write { db in
            for sha in shas {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO turnCommit (companyId, sha, itemId, agentId, turnId, createdAt) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [companyId, sha, itemId, agentId, turnId, now])
            }
        }
    }

    /// After the engine rebased an item: each replayed commit gets its original's recorded author. The rebase replays exactly
    /// `<base>..<before>` in order, so old and new map by position; when that mapping can't be established nothing is carried
    /// (the new commits stay unverified). Never throws.
    func carryAuthorsThroughRebase(item: WorkItem, rebased: String, now: Date) {
        guard let before = item.verifiedCommit ?? item.leaseHeadCommit, before != rebased,
              let company = try? company(id: item.companyId),
              let git = try? refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true)),
              let newBase = try? git.mergeBase("main", rebased), let fresh = try? git.revList(newBase, rebased),
              let oldBase = try? git.mergeBase(before, rebased), let old = try? git.revList(oldBase, before), old.count == fresh.count,
              let authors = try? recordedCommitRows(companyId: item.companyId, shas: old), !authors.isEmpty else { return }
        do {
            try writer.write { db in
                for (o, n) in zip(old, fresh) {
                    guard let a = authors[o] else { continue }
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO turnCommit (companyId, sha, itemId, agentId, turnId, createdAt) VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [item.companyId, n, item.id, a.agentId, a.turnId, now])
                }
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not carry the commit authors of \(item.key) through its rebase: \(error)\n".utf8))
        }
    }

    private func recordedCommitRows(companyId: String, shas: [String]) throws -> [String: (agentId: String, turnId: String?)] {
        try writer.read { db in
            var out: [String: (agentId: String, turnId: String?)] = [:]
            for chunk in stride(from: 0, to: shas.count, by: 500).map({ Array(shas[$0..<min($0 + 500, shas.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT sha, agentId, turnId FROM turnCommit WHERE companyId = ? AND sha IN (\(marks))",
                                            arguments: StatementArguments([companyId] + chunk)) {
                    out[row["sha"]] = (row["agentId"], row["turnId"])
                }
            }
            return out
        }
    }

    /// Sha → the handle of the agent whose turn the engine recorded making it, for those of `shas` it recorded (this company's
    /// agents only).
    public func recordedCommitAuthors(companyId: String, shas: [String]) throws -> [String: String] {
        guard !shas.isEmpty else { return [:] }
        return try writer.read { db in
            var out: [String: String] = [:]
            for chunk in stride(from: 0, to: shas.count, by: 500).map({ Array(shas[$0..<min($0 + 500, shas.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: """
                    SELECT t.sha, a.name FROM turnCommit t JOIN agent a ON a.id = t.agentId AND a.companyId = t.companyId
                    WHERE t.companyId = ? AND t.sha IN (\(marks))
                    """, arguments: StatementArguments([companyId] + chunk)) {
                    out[row["sha"]] = row["name"]
                }
            }
            return out
        }
    }

    /// Changes whenever a commit of the company is recorded (search caches attribution per value of it).
    func commitAuthorsVersion(companyId: String) -> Int64 {
        (try? writer.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM turnCommit WHERE companyId = ?", arguments: [companyId]) } ?? 0) ?? 0
    }
}
