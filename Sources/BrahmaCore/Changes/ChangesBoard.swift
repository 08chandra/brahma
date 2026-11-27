import Foundation
import GRDB

/// One row of the changes board (design: every agent's live work at a glance).
public struct BoardRow: Equatable, Sendable {
    public var key: String
    /// `SafeTitle`, gated as the final string (the key alone when the title holds a stored value).
    public var title: String
    /// The holder's handle.
    public var agent: String
    public var agentState: String
    public var files: Int
    public var added: Int
    public var removed: Int
    public var lastEdit: Date?
    /// The latest check run: `passed`, `failed`, `running` or `none`.
    public var checkStatus: String?
    public var reviewer: String?
    public var tainted: Bool
}

extension Store {
    /// Every active lease with a worktree in place, as a row of its live changes vs `main`, sorted by last edit (newest
    /// first). An agent sees only the rows where it is the holder or the reviewer; the owner and the concierge see all.
    public func changesBoard(companyId: String, reader: Reader, knownValues: [(name: String, value: String)], now: Date) throws -> [BoardRow] {
        guard let company = try company(id: companyId) else { return [] }
        if case .agent(let id) = reader {
            guard let agent = try agent(id: id), agent.companyId == companyId else { return [] }
        }
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let fs = try SafeFS(workspace: workspace, ownHandle: nil)
        var rows: [BoardRow] = []
        for lease in try leases(companyId: companyId) {
            guard let item = try workItem(id: lease.itemId), item.companyId == companyId,
                  let holder = try agent(id: lease.agentId), holder.companyId == companyId else { continue }
            // The live worktree rule (`RefAccess.liveDiffSubject`), as for every live view.
            guard (try? checkChangesAccess(companyId: companyId, key: item.key, compare: .main, reader: reader)) != nil else { continue }
            guard (try? fs.worktreeDirectory(key: item.key)) != nil else { continue }
            let raw: RawChanges
            do { raw = try changesRaw(companyId: companyId, key: item.key, compare: .main) } catch { continue }
            let snapshot = Self.finishChanges(raw, knownValues: knownValues, now: now)
            let reviewer = try item.reviewerId.flatMap { try agent(id: $0) }.map(\.name)
            let latest = try checkRuns(companyId: companyId, itemId: item.id).last
            let title = gate.final(SafeTitle.make(item.title).text, max: SafeTitle.max).flatMap { $0.isEmpty ? nil : $0 } ?? item.key
            rows.append(BoardRow(key: item.key, title: title, agent: holder.name, agentState: holder.state.rawValue, files: snapshot.files.count,
                                 added: snapshot.added, removed: snapshot.removed, lastEdit: snapshot.lastEdit,
                                 checkStatus: Self.boardCheckStatus(latest), reviewer: reviewer, tainted: snapshot.tainted))
        }
        return rows.sorted {
            switch ($0.lastEdit, $1.lastEdit) {
            case let (a?, b?) where a != b: return a > b
            case (nil, .some): return false
            case (.some, nil): return true
            default: return $0.key < $1.key
            }
        }
    }

    /// Plan C Task C6b: the keys of the company's active leases whose worktree is in place (the live worktree rule's subjects), in
    /// key order. The CHANGES tab shows whenever this is not empty. No diff is computed; a workspace that can't be walked reads
    /// as none (the tab is presence only, never content).
    public func worktreeKeys(companyId: String) throws -> [String] {
        guard let company = try company(id: companyId) else { return [] }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        guard let fs = try? SafeFS(workspace: workspace, ownHandle: nil) else { return [] }
        var keys: [String] = []
        for lease in try leases(companyId: companyId) {
            guard let item = try workItem(id: lease.itemId), item.companyId == companyId else { continue }
            guard (try? fs.worktreeDirectory(key: item.key)) != nil else { continue }
            keys.append(item.key)
        }
        return keys.sorted()
    }

    /// `passed`, `failed`, `running` or `none`.
    static func boardCheckStatus(_ run: VerificationRun?) -> String {
        guard let run else { return "none" }
        switch run.status {
        case .passed: return "passed"
        case .queued, .running: return "running"
        case .failed, .timedOut, .inconclusive, .error: return "failed"
        }
    }
}
