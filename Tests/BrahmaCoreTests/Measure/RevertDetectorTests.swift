import Foundation
import Testing
@testable import BrahmaCore

/// The revert detector over a real repository (Plan X6a Task 4; ruling R3: an ordinary test over a `GitFixture`). Patch-ids come
/// from `git diff <a> <b> | git patch-id --stable` through `GitCommand`; ranges are `<merged>^1..<merged>` (ruling R17).
@Suite(.scratch) struct RevertDetectorTests {
    let t0 = MeasureFixtures.t0
    let day: TimeInterval = 86_400

    /// Writes `files` and commits them on the fixture's current branch; returns the commit.
    func commit(_ repo: GitFixture, _ files: [String: String], _ message: String) throws -> String {
        for (path, text) in files { try repo.write(path, text) }
        try repo.git(["add", "-A"])
        try repo.git(["commit", "-q", "--no-verify", "-m", message])
        return try repo.git(["rev-parse", "HEAD"])
    }

    /// `git revert` of a landed change is its exact inverse: found. A range whose commit is not in the repository is reported
    /// unreadable, never paired.
    @Test func exactInverseFound() throws {
        let repo = try GitFixture(files: ["README.md": "acme\n", "app.txt": "one\n"])
        let a = try commit(repo, ["app.txt": "one\ntwo\n", "lib.txt": "new\n"], "A")
        let other = try commit(repo, ["README.md": "acme\nmore\n"], "other")
        try repo.git(["revert", "--no-edit", a])
        let b = try repo.git(["rev-parse", "HEAD"])
        let missing = String(repeating: "d", count: 40)
        let ranges = [
            LandedRange(itemId: "A", merged: a, landedAt: t0),
            LandedRange(itemId: "O", merged: other, landedAt: t0.addingTimeInterval(day)),
            LandedRange(itemId: "B", merged: b, landedAt: t0.addingTimeInterval(3 * day)),
            LandedRange(itemId: "Z", merged: missing, landedAt: t0.addingTimeInterval(4 * day)),
        ]
        #expect(ranges[0].base == "\(a)^1")
        let scan = try RevertDetector(git: repo.ws).inversePairs(ranges)
        #expect(scan.pairs == [RevertDetector.Pair(reverted: "A", by: "B")], "\(scan)")
        #expect(scan.unreadable == ["Z"])
        #expect(scan.scanned == ["A", "O", "B"])
        #expect(scan.stoppedAt == nil)
    }

    /// A change that undoes only part of a landing is not an exact inverse: only a link can claim it.
    @Test func partialRevertNotClaimed() throws {
        let repo = try GitFixture(files: ["x.txt": "x\n", "y.txt": "y\n"])
        let a = try commit(repo, ["x.txt": "x\nx2\n", "y.txt": "y\ny2\n"], "A")
        let b = try commit(repo, ["x.txt": "x\n"], "undo x only")
        let scan = try RevertDetector(git: repo.ws).inversePairs([
            LandedRange(itemId: "A", merged: a, landedAt: t0),
            LandedRange(itemId: "B", merged: b, landedAt: t0.addingTimeInterval(day)),
        ])
        #expect(scan.pairs.isEmpty, "\(scan)")
        #expect(scan.scanned == ["A", "B"] && scan.unreadable.isEmpty)
    }

    /// The detector looks 30 days past a landing: an exact inverse 31 days later is not a revert of it; 29 days later it is.
    @Test func outsideThirtyDaysIgnored() throws {
        let repo = try GitFixture(files: ["app.txt": "one\n"])
        let a = try commit(repo, ["app.txt": "one\ntwo\n"], "A")
        try repo.git(["revert", "--no-edit", a])
        let b = try repo.git(["rev-parse", "HEAD"])
        let detector = RevertDetector(git: repo.ws)
        let late = try detector.inversePairs([
            LandedRange(itemId: "A", merged: a, landedAt: t0),
            LandedRange(itemId: "B", merged: b, landedAt: t0.addingTimeInterval(31 * day)),
        ])
        #expect(late.pairs.isEmpty, "\(late)")
        let inTime = try detector.inversePairs([
            LandedRange(itemId: "A", merged: a, landedAt: t0),
            LandedRange(itemId: "B", merged: b, landedAt: t0.addingTimeInterval(29 * day)),
        ])
        #expect(inTime.pairs == [RevertDetector.Pair(reverted: "A", by: "B")])
    }
}
