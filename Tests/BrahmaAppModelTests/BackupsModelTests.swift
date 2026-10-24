import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// Tool lookups are injected: an empty directory plays "nothing installed", a directory with an executable `litestream` plays an
/// install. No real litestream or rclone is ever run.
private func toolbox(litestream: Bool) throws -> BackupTools {
    let dir = try tempDir()
    if litestream {
        let path = dir.appending(path: "litestream")
        try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    return BackupTools(searchPath: dir.path, environment: [:])
}

@MainActor @Suite struct BackupsModelTests {
    private func make(litestream: Bool = false) throws -> (BackupsModel, Store, BrahmaPaths) {
        let (store, paths) = try makeHome()
        return (BackupsModel(store: store, paths: paths, tools: try toolbox(litestream: litestream)), store, paths)
    }

    @Test func statusLines() async throws {
        let (model, store, paths) = try make()
        await model.refresh()
        #expect(model.statusLines.map(\.label) == ["Last database snapshot", "Last home snapshot", "Last off-machine sync"])
        #expect(model.statusLines.map(\.value) == ["never", "never", "never"])

        _ = try BackupService(paths: paths, writer: store.writer).snapshot(reason: .hourly)
        _ = try HomeSnapshot.take(paths: paths)
        let now = Date()
        try SystemTimers.ensure(store: store, now: now)
        let timer = try #require(try store.timers(companyId: nil).first { $0.name == "backup.targets" })
        #expect(try store.claimFire(timerId: timer.id, expectedNext: timer.nextFireAt, now: now, next: now.addingTimeInterval(86_400)))
        await model.refresh()
        #expect(model.statusLines.map(\.value).allSatisfy { $0 != "never" })
        #expect(model.lastHourly != nil && model.lastHome != nil && model.lastTargetSync != nil)

        // A manual snapshot is not an hourly one.
        let (other, otherStore, otherPaths) = try make()
        _ = try BackupService(paths: otherPaths, writer: otherStore.writer).snapshot(reason: .manual)
        await other.refresh()
        #expect(other.lastHourly == nil)
    }

    @Test func addFolderValidates() async throws {
        let (model, store, paths) = try make()
        let drive = try tempDir()
        await model.addFolder(drive.path)
        #expect(model.error == nil)
        #expect(model.targets.count == 1)
        #expect(try store.backupTargets() == model.targets)
        // The same folder twice is one target.
        await model.addFolder(drive.path)
        #expect(model.targets.count == 1)

        // Refused: missing, and inside the data home. Nothing is stored and the reason is shown.
        await model.addFolder(drive.appending(path: "nope").path)
        #expect(model.error != nil && model.targets.count == 1)
        let inside = paths.home.appending(path: "mirror", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        await model.addFolder(inside.path)
        let stored = try store.backupTargets()
        #expect(model.error != nil && model.targets.count == 1 && stored.count == 1)

        // rclone is not installed here, so a remote is refused too.
        await model.addRclone("vault")
        #expect(model.error != nil && model.targets.count == 1)

        await model.remove(number: 1)
        #expect(model.targets.isEmpty && model.error == nil)
        #expect(try store.backupTargets().isEmpty)
        await model.remove(number: 1)
        #expect(model.error != nil)
    }

    @Test func walToggleDisabledWithoutLitestream() async throws {
        let (model, store, _) = try make(litestream: false)
        #expect(model.walToggleDisabled)
        #expect(model.walNote == "Install litestream to enable")
        await model.setWAL(enabled: true, replica: try tempDir().path)
        #expect(!model.walEnabled && model.error != nil)
        #expect(try store.walShipping() == nil)

        let (ready, readyStore, _) = try make(litestream: true)
        #expect(!ready.walToggleDisabled && ready.walNote == nil)
        let replica = try tempDir()
        await ready.setWAL(enabled: true, replica: replica.path)
        #expect(ready.walEnabled && ready.error == nil)
        #expect(try readyStore.walShipping()?.replica != nil)
        await ready.setWAL(enabled: false, replica: "")
        #expect(!ready.walEnabled)
        #expect(try readyStore.walShipping() == nil)

        // An enabled setting can always be switched off, even after litestream went away.
        try readyStore.setWALShipping(WALShippingConfig(replica: replica.path))
        let gone = BackupsModel(store: readyStore, paths: BrahmaPaths(home: replica, workspaces: replica), tools: try toolbox(litestream: false))
        await gone.refresh()
        #expect(gone.walEnabled && !gone.walToggleDisabled)
    }

    @Test func backUpNowTakesSnapshots() async throws {
        let (model, _, paths) = try make()
        await model.backUpNow()
        #expect(model.error == nil && !model.isBackingUp)
        #expect(BackupService(paths: paths).list().contains { $0.reason == .manual })
        #expect(model.lastHome != nil)
        #expect(model.lastHourly == nil)
    }
}
