import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
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

/// `brahma items link <co> <KEY> regression-of|revert-of <TARGET>` (Plan X6a Task 2): owner only, refused inside an agent turn,
/// refuses an unlanded target with the store's words.
@Suite(.scratch) struct ItemLinkCommandTests {
    @Test func linksAndRefusesInsideAgentTurn() throws {
        let owner = try OwnerTestHome()
        let made = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: owner.url)
        #expect(made.status == 0, "\(made.stderr)")
        let store = try Store(path: ownerPaths(owner.url).database.path)
        let company = try #require(try store.companies().first)
        let now = MeasureFixtures.t0
        let items = try MeasureFixtures.items(store, company: company, count: 3, now: now.addingTimeInterval(-3600))
        try MeasureFixtures.land(store, company: company, items: [items[0]], number: 1, enqueuedAt: now.addingTimeInterval(-1800), landedAt: now)
        let window = MeasureWindow(since: now.addingTimeInterval(-86_400), until: Date().addingTimeInterval(86_400))
        func links(_ kind: ItemLinkKind) throws -> [ItemLink] { try store.itemLinks(companyId: company.id, kind: kind, in: window) }

        // The owner's shell: linked, attributed to the owner, both spellings of the relation accepted.
        let ok = try brahma(["items", "link", "Acme", "acme-2", "regression-of", "ACME-1"], home: owner.url)
        #expect(ok.status == 0, "\(ok.stderr)")
        #expect(ok.stdout == "ACME-2 is a regression of ACME-1\n", Comment(rawValue: ok.stdout))
        let linked = try links(.regressionOf)
        #expect(linked.map(\.itemId) == [items[1].id] && linked.map(\.targetId) == [items[0].id] && linked.map(\.createdBy) == ["owner"])
        let revert = try brahma(["items", "link", "Acme", "ACME-3", "revert-of", "ACME-1"], home: owner.url)
        #expect(revert.status == 0, "\(revert.stderr)")
        #expect(revert.stdout == "ACME-3 reverts ACME-1\n", Comment(rawValue: revert.stdout))
        #expect(try links(.revertOf).map(\.itemId) == [items[2].id])

        // Inside an agent turn: refused before anything is read, nothing written.
        let agent = try brahma(["items", "link", "Acme", "ACME-3", "regression-of", "ACME-1"], home: owner.url, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(agent.status == 1)
        #expect(agent.stderr.contains("owner commands can't run inside an agent turn"), Comment(rawValue: agent.stderr))
        #expect(agent.stdout.isEmpty)
        #expect(try links(.regressionOf).count == 1)

        // Refusals carry the store's words; a bad relation names the two that exist.
        let unlanded = try brahma(["items", "link", "Acme", "ACME-3", "regression-of", "ACME-2"], home: owner.url)
        #expect(unlanded.status == 1)
        #expect(unlanded.stderr.contains("ACME-2 has not landed; only landed items can regress or be reverted"), Comment(rawValue: unlanded.stderr))
        let missing = try brahma(["items", "link", "Acme", "ACME-3", "regression-of", "ACME-9"], home: owner.url)
        #expect(missing.status == 1 && missing.stderr.contains("ACME-9"), Comment(rawValue: missing.stderr))
        let selfLink = try brahma(["items", "link", "Acme", "ACME-1", "revert-of", "ACME-1"], home: owner.url)
        #expect(selfLink.status == 1 && selfLink.stderr.contains("ACME-1 cannot be a revert of itself"), Comment(rawValue: selfLink.stderr))
        let relation = try brahma(["items", "link", "Acme", "ACME-3", "caused-by", "ACME-1"], home: owner.url)
        #expect(relation.status == 1 && relation.stderr.contains("regression-of") && relation.stderr.contains("revert-of"), Comment(rawValue: relation.stderr))
        #expect(try links(.regressionOf).count == 1 && links(.revertOf).count == 1)
        // The help lists it.
        let help = try brahma(["items", "--help"], home: owner.url)
        #expect(help.status == 0 && help.stdout.contains("link"), Comment(rawValue: help.stdout))
    }
}
