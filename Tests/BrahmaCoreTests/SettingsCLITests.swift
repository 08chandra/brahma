import Foundation
import Testing
@testable import BrahmaCore

private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = ["BRAHMA_HOME": home.appending(path: "home").path, "BRAHMA_WORKSPACES": home.appending(path: "ws").path,
             "PATH": "/usr/bin:/bin"]
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

@Suite struct SettingsCLITests {
    @Test func timezoneShowsSetsAndValidates() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["settings", "timezone"], home: home).stdout.contains("time zone: "))
        let set = try brahma(["settings", "timezone", "Asia/Kolkata"], home: home)
        #expect(set.status == 0, "\(set.stderr)"); #expect(set.stdout.contains("Asia/Kolkata"))
        #expect(try brahma(["settings", "timezone"], home: home).stdout == "time zone: Asia/Kolkata\n")
        let bad = try brahma(["settings", "timezone", "Mars/Olympus"], home: home)
        #expect(bad.status == 1); #expect(bad.stderr.contains("unknown time zone"))
        #expect(try brahma(["settings", "timezone"], home: home).stdout == "time zone: Asia/Kolkata\n")
    }

    @Test func planAndShare() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["settings", "plan"], home: home).stdout.contains("plan: max5x (low 1 / balanced 3 / max 8"))
        let set = try brahma(["settings", "plan", "max20x"], home: home)
        #expect(set.status == 0, "\(set.stderr)"); #expect(set.stdout.contains("plan: max20x (low 2 / balanced 6 / max 16"))
        #expect(try brahma(["settings", "plan", "max99x"], home: home).status != 0)
        #expect(try brahma(["settings", "share"], home: home).stdout == "weekly share: 70%\n")
        #expect(try brahma(["settings", "share", "55"], home: home).stdout == "weekly share: 55%\n")
        for bad in ["9", "101", "abc"] { #expect(try brahma(["settings", "share", bad], home: home).status != 0, "\(bad)") }
        #expect(try brahma(["settings", "share"], home: home).stdout == "weekly share: 55%\n")
    }

    @Test func writesNeedTheOwnerShell() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        for args in [["settings", "timezone", "UTC"], ["settings", "plan", "max20x"], ["settings", "share", "50"],
                     ["company", "reserve", "Acme", "0.2"]] {
            let inAgent = try brahma(args, home: home, env: ["BRAHMA_AGENT_ID": "a1"])
            #expect(inAgent.status == 1, "\(args)")
            #expect(inAgent.stderr.contains("owner commands can't run inside an agent turn"), "\(args): \(inAgent.stderr)")
        }
        let nokey = try OwnerTestHome(initOwner: false)
        for args in [["settings", "timezone", "UTC"], ["settings", "plan", "max20x"], ["settings", "share", "50"]] {
            let r = try brahma(args, home: nokey.url)
            #expect(r.status == 1, "\(args)"); #expect(r.stderr.contains("owner key missing or invalid"), "\(args)")
        }
        // Reading needs no key.
        #expect(try brahma(["settings", "plan"], home: nokey.url).status == 0)
    }

    @Test func companyReserveOverride() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let set = try brahma(["company", "reserve", "Acme", "0.5"], home: home)
        #expect(set.status == 0, "\(set.stderr)"); #expect(set.stdout.contains("reserve 0.50"))
        for bad in ["0.95", "-0.1", "lots"] { #expect(try brahma(["company", "reserve", "Acme", bad], home: home).status != 0, "\(bad)") }
        let reset = try brahma(["company", "reserve", "Acme", "default"], home: home)
        #expect(reset.stdout.contains("default (30%)"), "\(reset.stdout)")
        #expect(try brahma(["company", "reserve", "Nope", "0.2"], home: home).status != 0)
    }

    @Test func statusShowsPaceAndHold() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let store = try Store(path: ownerPaths(home).database.path)
        let now = Date()
        try store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                              fiveHourUtilization: 0.1, sevenDayUtilization: 0.9, observedAt: now,
                                              sevenDayResetsAt: now.addingTimeInterval(3 * 86_400)))
        var s = try brahma(["status"], home: home)
        #expect(s.stdout.contains(" · 7D ahead by "), "\(s.stdout)")
        #expect(!s.stdout.contains("engine paused"))
        try store.setHold(reason: .disk, detail: "4.0 GB free", now: now)
        s = try brahma(["status"], home: home)
        #expect(s.stdout.contains("engine paused: disk — 4.0 GB free"), "\(s.stdout)")
    }

    @Test func clockUsesOwnerTimeZoneInStatusLastTurn() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let store = try Store(path: ownerPaths(home).database.path)
        let c = try #require(try store.companies().first)
        let ceo = try store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        let noon = Date(timeIntervalSince1970: TimeInterval(Int(1_800_000_000) - Int(1_800_000_000) % 86_400 + 12 * 3600))
        let t = try store.startTurn(agentId: ceo.id, now: noon)
        _ = try store.finishTurn(id: t.id, outcome: .succeeded, summary: nil, costUSD: nil, now: noon)
        try store.setOwnerTimeZone("UTC")
        #expect(try brahma(["status"], home: home).stdout.contains("last turn: succeeded 12:00"))
        try store.setOwnerTimeZone("Asia/Kolkata")
        #expect(try brahma(["status"], home: home).stdout.contains("last turn: succeeded 17:30"))
    }
}
