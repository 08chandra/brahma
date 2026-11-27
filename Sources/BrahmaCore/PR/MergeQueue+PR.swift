import Foundation

/// The merge queue's PR mode (Plan X8, spec §8.5.1). When `company.landing == .pr` a batch takes one request
/// (`MergeSettings.prBatchSize`), fetches the remote `main` (`RemoteMainFetching`) and rebases and checks onto it, and after
/// `checked` hands the verified commit to the PR landing machine (`PRLandingBeginning.begin`) instead of fast-forwarding local
/// `main`. The journal goes `checked` → `handedToPR` → `done`, so recovery never treats a PR batch as a local landing.
extension MergeQueue {
    /// Wires PR mode's machinery (Tasks 3 and 6 supply the conformers; tests supply fakes). Nil leaves a PR-mode company held.
    public func wirePR(landing: (any PRLandingBeginning)?, remoteMain: (any RemoteMainFetching)?) {
        prLandingMachine = landing
        self.remoteMain = remoteMain
    }

    /// Why a PR-mode company's queue cannot run now (it is then held with this text), or nil (local mode, or everything wired).
    func prUnavailable(_ company: Company) -> String? {
        guard company.landing == .pr else { return nil }
        if prLandingMachine == nil { return Store.prNoLandingMachineHold }
        if remoteMain == nil { return Store.prNoRemoteMainHold }
        return nil
    }

    /// The remote `main`'s tip, fetched into the company's repository by the wired fetcher (which bounds its own size and time).
    /// Any failure is the engine's, never the item's: the request goes back uncounted.
    func fetchRemoteMain(_ company: Company) async throws -> String {
        guard let remoteMain else {
            throw MergeInfrastructureError(underlying: WorkError.conflict(Store.prNoRemoteMainHold))
        }
        let fetched: FetchResult
        do { fetched = try await remoteMain.fetch(companyId: company.id) } catch {
            throw MergeInfrastructureError(underlying: error)
        }
        guard fetched.newTip.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil else {
            throw MergeInfrastructureError(underlying: GitError.failed(command: "fetch remote main", status: -1, stderr: "not a commit"))
        }
        return fetched.newTip
    }

    /// The hand-off: the requests become `handedToPR` (the queue never takes them again), then each item's checked commit goes
    /// to the landing machine. Nothing here touches `main`, `company.mainCommit` or the item's worktree.
    func handOffToPR(landed: [(requestId: String, itemId: String, candidate: String)], base: String, company: Company) async throws {
        guard let machine = prLandingMachine else {
            throw MergeInfrastructureError(underlying: WorkError.conflict(Store.prNoLandingMachineHold))
        }
        try store.markHandedToPR(requestIds: landed.map(\.requestId), candidates: Dictionary(uniqueKeysWithValues: landed.map { ($0.requestId, $0.candidate) }),
                                 base: base, now: clock())
        for entry in landed {
            guard let item = try store.workItem(id: entry.itemId) else { continue }
            await machine.begin(item: item, verifiedSHA: entry.candidate)
        }
    }

    /// Recovery of a batch journaled `handedToPR`: the hand-off is made again for the requests the batch still owns (a request
    /// the owner withdrew meanwhile is left alone), the rest go back uncounted, and the batch is `done`. Without a landing
    /// machine it stays open (retried later); `main` is never moved either way.
    func recoverHandOff(_ b: MergeBatch, company: Company) async -> MergeRecoveryResult {
        guard prLandingMachine != nil else { return .pending }
        let landed = b.landedIds.compactMap { id in b.candidates[id].map { (requestId: id, candidate: $0) } }
        guard let base = b.base, !landed.isEmpty, landed.count == b.landedIds.count else {
            do {
                try store.requeueMerge(requestIds: b.requestIds, countsAsRequeue: false, now: clock())
                try store.advanceBatch(id: b.id, to: .done, error: "interrupted", now: clock())
            } catch { return .faulted("batch \(b.number): \(error)") }
            return .dealt
        }
        do {
            // Still the batch's: `running` (the crash came before the requests were marked) or already `handedToPR`.
            var entries: [(requestId: String, itemId: String, candidate: String)] = []
            for (requestId, candidate) in landed {
                let request = try store.mergeRequest(id: requestId)
                guard let request, request.batchId == b.id, request.status == .running || request.status == .handedToPR else { continue }
                entries.append((requestId, request.itemId, candidate))
            }
            if !entries.isEmpty { try await handOffToPR(landed: entries, base: base, company: company) }
            let rest = b.requestIds.filter { id in !entries.contains { $0.requestId == id } }
            try store.requeueMerge(requestIds: rest, countsAsRequeue: false, now: clock())
            try store.advanceBatch(id: b.id, to: .done, error: entries.isEmpty ? "interrupted" : nil, now: clock())
        } catch {
            return .faulted("batch \(b.number): \(error)")
        }
        return .dealt
    }
}

/// How one unfinished batch fared in a recovery (`MergeQueue.recoverBatch`'s result, shared with the PR hand-off's).
enum MergeRecoveryResult: Sendable {
    /// Finished or abandoned.
    case dealt
    /// Still open for a reason the batch itself records: retried later.
    case pending
    /// The recovery itself threw: backed off and escalated.
    case faulted(String)
}

extension Store {
    /// The hold a PR-mode company's queue takes while the landing machine (Task 3) is not wired.
    static let prNoLandingMachineHold = "PR landing unavailable: no landing machine"
    /// The hold while the remote-main fetch (Task 6) is not wired.
    static let prNoRemoteMainHold = "PR landing unavailable: no remote main fetch"

    /// One of PR mode's own holds, which lift themselves once the machinery is wired.
    static func isPRUnavailableHold(_ hold: String?) -> Bool {
        hold == prNoLandingMachineHold || hold == prNoRemoteMainHold
    }
}
