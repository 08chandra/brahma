import Foundation

/// What one run of the main guard did.
public enum MainGuardResult: Equatable, Sendable {
    /// `main` is the recorded head.
    case ok
    /// `main` was not the recorded head: the other tip is saved under `foreignRef` and `main` is back at `to`.
    case restored(foreignRef: String, to: String)
    /// Nothing was moved: the owner's stop is up, a merge batch is open (its journal owns `main` until it is `done`), a restore
    /// the engine has not taken up names the company (the restore step decides first), the workspace has no `main` or no
    /// record of it (the owner is alerted once and adopts: B6), `main` is a symbolic ref, or `main` or the record moved again
    /// under the guard's hands (the next tick looks again).
    case skipped
}

/// Only the merge queue moves `main` (Plan 4a Task 3). Every tick, for every company, `refs/heads/main` is compared with the
/// engine's record (`company.mainCommit`, written only by the engine at the company's creation, the queue's journaled landing,
/// the owner's `adopt-main` and the restore step). A head that is not the record is foreign, whoever made it and whatever its
/// subject says: it is saved under a unique `refs/brahma/foreign/<yyyyMMdd-HHmmss UTC>-<n>` and `main` is put back; the owner is
/// told (activity, a notice, and an alert when the root checkout is off `main`) and can adopt the saved tip with
/// `brahma merge adopt-main`. A symbolic `main` is never the engine's (3a) and is refused, not repaired: 3a's alert, `.skipped`.
/// Uncommitted edits at the root are not a move (they stay); when `main` did move they go with the saved tip, never onto `main`.
/// No record at all (B6) adopts nothing: one owner alert, and the owner accepts with `adopt-main`.
///
/// `main == pendingMainCommit` is the engine's own crash record (the pending head is written only by the queue's journaled
/// landing and the owner's accept, right before `main` moves, and cleared on every path that does not move it): 3a's
/// `checkMain` records it, as it always did.
///
/// Runs under the company's `GitLock` (so it never interleaves with a landing of this or another engine) and skips while any
/// batch is open, a restore is pending, or the owner's stop is up. The restore itself re-reads the record and the pending head
/// under main's lock: `adopt-main` and 3a's quarantine accept write the record under that lock (and the accept writes its
/// pending head there before `main` moves), so a move of theirs is never mistaken for a foreign one. Blocking (git): call it
/// in a `Blocking` body.
public enum MainGuard {
    /// How long the guard waits for a company's git lock (a batch of another engine may hold it; the next tick tries again).
    static let lockWait = Duration.seconds(5)

    public static func check(company: Company, store: Store, git: GitWorkspace, paths: BrahmaPaths, now: Date) throws -> MainGuardResult {
        if try store.engineStopped() != nil { return .skipped }
        guard try store.openMergeBatches(companyId: company.id).isEmpty, try !store.restorePending(companyId: company.id, paths: paths) else { return .skipped }
        return try GitLock.withLock(paths: paths, companyId: company.id, wait: lockWait) {
            // Read again under the lock: a batch claimed meanwhile owns `main` from its journal row on.
            if try store.engineStopped() != nil { return .skipped }
            guard try store.openMergeBatches(companyId: company.id).isEmpty, try !store.restorePending(companyId: company.id, paths: paths),
                  let current = try store.company(id: company.id) else { return .skipped }
            store.mergeRefProbe.call("refs/brahma/guard-record")     // the test seam between the record read and the head read
            guard let recorded = current.mainCommit else {
                // Fail closed (B6): nothing is adopted by itself. The owner hears once and accepts with `adopt-main`.
                try store.raiseMainUnrecordedAlert(company: current, now: now)
                return .skipped
            }
            guard let head = try git.revParse("main") else { return .skipped }
            if try git.mainIsSymbolic() {
                // A symbolic `main` is never the engine's (3a) and is not a plain ref the guard can swap (B6: refused, not
                // repaired): 3a's one "main changed outside Brahma" alert, and nothing moves until the owner makes it a branch.
                do { try store.checkMain(company: current, git: git) }
                catch let error as WorkError where error.message == Store.mainChangedMessage {}
                return .skipped
            }
            if head == recorded { return .ok }
            if let pending = current.pendingMainCommit, pending == head {
                // 3a's crash record: the engine itself was moving `main` here (an owner accept, say) and did not get to record
                // it. `checkMain` records a pending head it finds; anything else it throws for.
                try store.checkMain(company: current, git: git)
                return .ok
            }
            store.mergeRefProbe.call("refs/brahma/foreign")      // the test seam between the record read and the restore
            let restore = try git.restoreMain(to: recorded, from: head, stamp: stamp(now)) {
                // The record as it stands under main's lock; a pending head equal to the tip names the engine's or the owner's
                // own move in flight, never a foreign one.
                let fresh = try store.company(id: company.id)
                return fresh?.mainCommit == recorded && fresh?.pendingMainCommit != head
            }
            guard let restore else { return .skipped }
            store.reportMainRestored(company: current, restore: restore, recorded: recorded, now: now)
            return .restored(foreignRef: restore.ref, to: recorded)
        }
    }

    /// `yyyyMMdd-HHmmss` in UTC, the stamp in a foreign ref's name.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
