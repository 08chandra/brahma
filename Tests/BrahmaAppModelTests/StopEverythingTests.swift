import Foundation
import Testing
@testable import BrahmaCore
@testable import BrahmaAppModel

/// STOP EVERYTHING goes through the one stop every path shares (Task 9c fix round 1, controller ruling 1):
/// `EmergencyStop.signalEngineGroups`, whose set includes the turn leaders the runner recorded under `<runDir>/turns`.
@MainActor @Suite(.scratch) struct StopEverythingTests {
    /// A turn the engine already recorded `interrupted` whose `claude` still lingers is named only by its turn record; STOP
    /// EVERYTHING kills it. A process of the owner's with no record survives.
    @Test func stopEverythingKillsALingeringInterruptedTurn() async throws {
        let (store, paths) = try makeHome()
        let (_, ceo, _, _) = try seedAcme(store, paths)
        let devnull = open("/dev/null", O_WRONLY)
        defer { close(devnull) }
        func sleeper() throws -> ProcessGroupChild {
            try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "sleep 600"], environment: [:],
                                        workingDirectory: paths.home, output: devnull)
        }
        let lingering = try sleeper(), unrelated = try sleeper()
        defer { unrelated.signalGroup(SIGKILL); _ = unrelated.finish() }
        let turns = paths.runDir.appending(path: "turns", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        let start = try #require(ProcessTable.entry(lingering.pid)?.start)
        try TurnRecords.add(TurnRecord(leader: lingering.pid, leaderStart: start, since: start, machMarker: nil), agentId: ceo.id, in: turns)
        #expect(try store.runningTurnPids().isEmpty, "no database row names the lingering claude")

        let model = AppModel(store: store, paths: paths)
        await model.load()
        await model.stopEverything()
        #expect(try store.engineStopped()?.by == "app")
        let deadline = AwakeTime.deadline(after: .seconds(10))
        while !lingering.hasExited(), AwakeTime.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(lingering.hasExited(), "the lingering turn leader was signalled")
        #expect(!unrelated.hasExited(), "a process with no engine record is never signalled")
        _ = lingering.finish()
    }

    /// S4 fix round 1 (I1, M8): what the stop could not read (here: the child-group records) is shown in its result; the stop
    /// itself is recorded.
    @Test func stopEverythingShowsWhatItCouldNotRead() async throws {
        let (store, paths) = try makeHome()
        _ = try seedAcme(store, paths)
        let children = ChildGroups.directory(runDir: paths.runDir)
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: children.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: children.path) }   // exec-bit fixture: a directory mode
        let model = AppModel(store: store, paths: paths)
        await model.load()
        await model.stopEverything()
        #expect(try store.engineStopped()?.by == "app")
        let message = try #require(model.errorMessage)
        #expect(message.contains(children.path), Comment(rawValue: message))
    }
}
