import Foundation
import Testing
@testable import BrahmaCore

/// The revert detector's pure half (Plan X6a Task 4): pairing landed ranges by patch-id, and stopping at its bounds. No git runs:
/// patch-ids are given as values or by a source that never spawns a process. The git half is `RevertDetectorTests`.
@Suite(.scratch) struct PatchIdPairingTests {
    let t0 = MeasureFixtures.t0
    let day: TimeInterval = 86_400

    func range(_ id: String, _ at: TimeInterval) -> LandedRange {
        LandedRange(itemId: id, merged: String(repeating: id.lowercased(), count: 40).prefix(40).description, landedAt: t0.addingTimeInterval(at))
    }

    /// L is reverted by the earliest LATER landing whose forward patch-id is L's inverse patch-id, within the lookback. An earlier
    /// landing with the same patch-id reverts nothing; one past the lookback is not a revert of L; an empty diff (no patch-id)
    /// never pairs.
    @Test func pairsByInverseWithinWindow() {
        let a = range("A", 0), b = range("B", 2 * day), c = range("C", -day), d = range("D", 31 * day), e = range("E", 3 * day)
        let forward = ["A": "fa", "B": "ia", "C": "ia", "D": "ia"]
        let inverse = ["A": "ia", "B": "fa", "C": "ic", "D": "id"]
        let pairs = RevertDetector.pair([d, e, c, b, a], forward: forward, inverse: inverse, lookback: 30 * day)
        // A ← B; and B (A's revert) is itself undone by nothing later (D's forward is "ia", not "fa").
        #expect(pairs == [RevertDetector.Pair(reverted: "A", by: "B")])

        // Only D is a later inverse of A, and it is past 30 days: nothing.
        let late = RevertDetector.pair([a, c, d], forward: forward, inverse: inverse, lookback: 30 * day)
        #expect(late.isEmpty)
        // Within a 40-day lookback it is A's revert.
        #expect(RevertDetector.pair([a, c, d], forward: forward, inverse: inverse, lookback: 40 * day) == [RevertDetector.Pair(reverted: "A", by: "D")])
        // A revert of a revert: B undoes A, F re-applies A (its forward is A's forward, B's inverse).
        let f = range("F", 4 * day)
        let again = RevertDetector.pair([a, b, f], forward: forward.merging(["F": "fa"]) { $1 }, inverse: inverse, lookback: 30 * day)
        #expect(again == [RevertDetector.Pair(reverted: "A", by: "B"), RevertDetector.Pair(reverted: "B", by: "F")])
    }

    /// More landed items than `maxItems`: the oldest `maxItems` are scanned and the basis says where the scan stopped. A git call
    /// over its time limit stops the scan there. Under the bounds there is no basis.
    @Test func boundsStopWithBasis() throws {
        let ranges = ["A", "B", "C", "D", "E"].enumerated().map { range($1, Double($0) * day) }
        var counted = 0
        let limits = RevertDetector.Limits(maxItems: 3, gitCallSeconds: 10, lookback: 30 * day)
        let capped = RevertDetector(limits: limits, source: { _, _ in counted += 1; return nil })
        let scan = try capped.inversePairs(ranges.reversed())
        #expect(scan.stoppedAt == "3 landed items")
        #expect(scan.basis == "revert scan stopped at 3 landed items")
        #expect(scan.scanned == ["A", "B", "C"])
        #expect(scan.notScanned == ["D", "E"])
        #expect(counted == 6, "two patch-ids per scanned range")
        // Cached for the run: asking again runs nothing.
        _ = try capped.inversePairs(ranges)
        #expect(counted == 6)

        let cMerged = ranges[2].merged
        let slow = RevertDetector(limits: RevertDetector.Limits(maxItems: 2000, gitCallSeconds: 10, lookback: 30 * day), source: { from, to in
            if from.hasPrefix(cMerged) || to.hasPrefix(cMerged) { throw RevertDetector.SourceError.timedOut }
            return nil
        })
        let stopped = try slow.inversePairs(ranges)
        #expect(stopped.stoppedAt == "a git call over 10 s")
        #expect(stopped.basis == "revert scan stopped at a git call over 10 s")
        #expect(stopped.scanned == ["A", "B"])
        #expect(stopped.notScanned == ["C", "D", "E"])

        let fine = try RevertDetector(limits: RevertDetector.Limits(maxItems: 5, gitCallSeconds: 10, lookback: 30 * day),
                                      source: { _, _ in nil }).inversePairs(ranges)
        #expect(fine.stoppedAt == nil && fine.basis == nil && fine.notScanned.isEmpty && fine.scanned.count == 5)
        #expect(RevertDetector.Limits.standard == RevertDetector.Limits(maxItems: 2000, gitCallSeconds: 10, lookback: 30 * day))
    }

    /// A revision is a commit id, optionally with `^1`, and nothing after it: a trailing newline is not a revision.
    @Test func revisionsAreStrict() {
        #expect(RevertDetector.isRevision("abc1234"))
        #expect(RevertDetector.isRevision("abc1234^1"))
        #expect(!RevertDetector.isRevision("abc1234\n"))
        #expect(!RevertDetector.isRevision("abc1234^1\n"))
        #expect(!RevertDetector.isRevision("-abc1234"))
        #expect(!RevertDetector.isRevision("HEAD"))
    }
}
