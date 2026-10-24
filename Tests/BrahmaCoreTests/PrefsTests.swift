import Testing
import Foundation
import GRDB
@testable import BrahmaCore

private func brahma(_ args: [String], home: URL) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    p.environment = cliEnvironment(home: home)
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

@Suite struct PrefsTests {
    // 2026-06-10 12:00 EDT
    let now = Date(timeIntervalSince1970: 1_781_107_200)

    @Test func defaultsAreSeededAndRoundTrip() throws {
        let store = try Store.inMemory()
        let seeded = try store.ownerPrefs()
        #expect(seeded == .defaults)
        #expect(OwnerPrefs.defaults.quietEnabled && OwnerPrefs.defaults.quietStart == "22:00" && OwnerPrefs.defaults.quietEnd == "08:00")
        #expect(OwnerPrefs.defaults.digestTime == "08:00")
        #expect(OwnerPrefs.defaults.notificationsEnabled && OwnerPrefs.defaults.preventSleep)
        #expect(OwnerPrefs.defaults.quietHours == QuietHours(startHour: 22, startMinute: 0, endHour: 8, endMinute: 0))

        var changed = seeded
        changed.quietEnabled = false
        changed.quietStart = "23:30"
        changed.quietEnd = "06:15"
        changed.digestTime = "07:45"
        changed.notificationsEnabled = false
        changed.preventSleep = false
        try store.updateOwnerPrefs(changed, now: now)
        #expect(try store.ownerPrefs() == changed)
        #expect(changed.quietHours == nil)                       // off, though the window is remembered
        #expect(changed.digestHourMinute == (7, 45))
        // Still exactly one row.
        #expect(try store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ownerPrefs") } == 1)
    }

    @Test func invalidTimesAreRefused() throws {
        let store = try Store.inMemory()
        for bad in ["8:00", "24:00", "08:60", "0800", "08:00:00", "", "ab:cd", "08:0"] {
            var p = OwnerPrefs.defaults
            p.digestTime = bad
            #expect(throws: SettingsError.self, "\(bad)") { try store.updateOwnerPrefs(p, now: now) }
        }
        var p = OwnerPrefs.defaults
        p.quietEnd = "25:00"
        #expect(throws: SettingsError.self) { try store.updateOwnerPrefs(p, now: now) }
        #expect(try store.ownerPrefs() == .defaults)
    }

    @Test func digestTimeMovesExistingDigestTimers() throws {
        let store = try Store.inMemory()
        try store.setOwnerTimeZone("America/New_York")
        let a = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let b = try store.createCompany(name: "Beta", goal: "g", workspacesRoot: try tempDir())
        // The default comes from the preferences.
        try SystemTimers.ensure(store: store, now: now)
        let before = try store.timers(companyId: nil)
        #expect(before.filter { $0.name == "digest.daily" }.allSatisfy { $0.schedule == .daily(hour: 8, minute: 0) })

        var prefs = try store.ownerPrefs()
        prefs.digestTime = "13:30"
        try store.updateOwnerPrefs(prefs, now: now)
        let after = try store.timers(companyId: nil)
        let digests = after.filter { $0.name == "digest.daily" }
        #expect(Set(digests.compactMap(\.companyId)) == [a.id, b.id])
        #expect(digests.allSatisfy { $0.schedule == .daily(hour: 13, minute: 30) })
        // 13:30 EDT the same day, recomputed from now.
        #expect(digests.allSatisfy { $0.nextFireAt == now.addingTimeInterval(90 * 60) })
        // Nothing else moved.
        #expect(after.filter { $0.name != "digest.daily" } == before.filter { $0.name != "digest.daily" })

        // Saving the same prefs again is a no-op, and a later ensure keeps the owner's time.
        try store.updateOwnerPrefs(prefs, now: now.addingTimeInterval(3600))
        try SystemTimers.ensure(store: store, now: now.addingTimeInterval(3600))
        #expect(try store.timers(companyId: nil) == after)
    }

    @Test func startAndTickEnsureUsePrefsDigestTime() async throws {
        let store = try Store.inMemory()
        try store.setOwnerTimeZone("America/New_York")
        var prefs = try store.ownerPrefs()
        prefs.digestTime = "06:45"
        try store.updateOwnerPrefs(prefs, now: now)
        let a = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let clock = TestClock()
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let orchestrator = Orchestrator(store: store, runner: FakeTurnRunner(), paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                        clock: clock.function)
        try await orchestrator.start()
        func digest(_ id: String) throws -> EngineTimer {
            try #require(try store.timers(companyId: id).first { $0.name == "digest.daily" && $0.companyId == id })
        }
        #expect(try digest(a.id).schedule == .daily(hour: 6, minute: 45))

        // A company added later gets its digest from the tick's re-ensure, at the preferred time.
        let b = try store.createCompany(name: "Beta", goal: "g", workspacesRoot: try tempDir())
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(5))
        #expect(try digest(b.id).schedule == .daily(hour: 6, minute: 45))
    }

    @Test func prefsAndNoticesCommands() throws {
        let owner = try OwnerTestHome(); let home = owner.url

        let show = try brahma(["prefs"], home: home)
        #expect(show.status == 0, "\(show.stderr)")
        #expect(show.stdout.contains("notifications: on"))
        #expect(show.stdout.contains("quiet hours: 22:00-08:00"))
        #expect(show.stdout.contains("digest: 08:00"))
        #expect(show.stdout.contains("prevent sleep: on"))

        let quiet = try brahma(["prefs", "set", "quiet", "23:15-07:30"], home: home)
        #expect(quiet.status == 0, "\(quiet.stderr)")
        #expect(quiet.stdout.contains("quiet hours: 23:15-07:30"))
        #expect(try brahma(["prefs", "set", "quiet", "off"], home: home).stdout.contains("quiet hours: off"))
        #expect(try brahma(["prefs", "set", "digest", "07:05"], home: home).stdout.contains("digest: 07:05"))
        #expect(try brahma(["prefs", "set", "prevent-sleep", "off"], home: home).stdout.contains("prevent sleep: off"))
        #expect(try brahma(["prefs", "set", "notifications", "off"], home: home).stdout.contains("notifications: off"))
        let finalShow = try brahma(["prefs"], home: home).stdout
        #expect(finalShow.contains("notifications: off") && finalShow.contains("quiet hours: off")
                && finalShow.contains("digest: 07:05") && finalShow.contains("prevent sleep: off"))
        // Turning quiet hours back on with a window.
        #expect(try brahma(["prefs", "set", "quiet", "21:00-06:00"], home: home).stdout.contains("quiet hours: 21:00-06:00"))

        for bad in [["quiet", "25:00-08:00"], ["quiet", "22:00"], ["digest", "8am"], ["prevent-sleep", "maybe"], ["notifications", "yes"]] {
            let r = try brahma(["prefs", "set"] + bad, home: home)
            #expect(r.status != 0, "\(bad)")
        }
        #expect(try brahma(["prefs"], home: home).stdout.contains("digest: 07:05"))

        // The digest change reached the timers.
        let store = try Store(path: ownerPaths(home).database.path)
        #expect(try store.ownerPrefs().digestTime == "07:05")

        // Notices: listing is read-only and escapes agent text.
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: ownerPaths(home).workspaces)
        try store.notifyOwner(companyId: company.id, title: "hello\u{1B}[2Jthere", body: "body text")
        let list = try brahma(["notices"], home: home)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(list.stdout.contains("hello [2Jthere") && !list.stdout.contains("\u{1B}"))
        #expect(list.stdout.contains("acme"))
        let id = try #require(try store.undeliveredNotices().first?.id)
        try store.markNoticesDelivered(ids: [id], now: Store.now())
        #expect(try brahma(["notices"], home: home).stdout.contains("no undelivered notices"))
        #expect(try brahma(["notices", "--all"], home: home).stdout.contains("body text"))
    }

    @Test func prefsSetRefusesWithoutOwnerKey() throws {
        let home = try OwnerTestHome(initOwner: false).url
        let r = try brahma(["prefs", "set", "digest", "09:00"], home: home)
        #expect(r.status == 1)
        #expect(r.stderr.contains("owner key"))
        #expect(try brahma(["prefs"], home: home).status == 0)       // showing is read-only
    }
}
