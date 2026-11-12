import Foundation
import Testing
@testable import BrahmaCore

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

/// `brahma canary edit` and `brahma canary run` as the owner runs them (no model is called here).
@Suite(.scratch) struct CanaryCLITests {
    @Test func editCreatesTheTemplateWithNoProbeLines() throws {
        let owner = try OwnerTestHome()
        let paths = ownerPaths(owner.url)
        let r = try brahma(["canary", "edit"], home: owner.url, env: ["EDITOR": "/usr/bin/true"])
        #expect(r.status == 0, "\(r.stderr)")
        #expect(r.stdout.contains("created")); #expect(r.stdout.contains("no probe lines"))
        let url = CanaryProbes.url(paths: paths)
        #expect(try String(contentsOf: url, encoding: .utf8) == CanaryProbes.template)
        #expect(CanaryProbes.parse(try String(contentsOf: url, encoding: .utf8)).isEmpty)
        var st = stat()
        #expect(lstat(url.path, &st) == 0); #expect(st.st_mode & 0o7777 == 0o600)
    }

    @Test func editRevalidatesWhatTheEditorLeft() throws {
        let owner = try OwnerTestHome()
        // An editor that adds one benign probe line (a fake: it lives only in the test target).
        let adds = try FakeTools.script("canary-editor-add", "printf 'cat \"$CANARY_HOME_FILE\"\\n' >> \"$1\"")
        let ok = try brahma(["canary", "edit"], home: owner.url, env: ["EDITOR": adds.path])
        #expect(ok.status == 0, "\(ok.stderr)"); #expect(ok.stdout.contains("1 probe line(s)"), "\(ok.stdout)")
        // An editor that leaves the file group- and world-readable: refused.
        let loosens = try FakeTools.script("canary-editor-chmod", "chmod 644 \"$1\"")
        let bad = try brahma(["canary", "edit"], home: owner.url, env: ["EDITOR": loosens.path])
        #expect(bad.status == 1); #expect(bad.stderr.contains("mode 644"), "\(bad.stderr)")
        // A failing editor.
        let fails = try brahma(["canary", "edit"], home: owner.url, env: ["EDITOR": "/usr/bin/false"])
        #expect(fails.status == 1); #expect(fails.stderr.contains("the editor exited"))
    }

    @Test func bothNeedTheOwnerShell() throws {
        let owner = try OwnerTestHome()
        for args in [["canary", "edit"], ["canary", "run"]] {
            let inAgent = try brahma(args, home: owner.url, env: ["BRAHMA_AGENT_ID": "a1", "EDITOR": "/usr/bin/true"])
            #expect(inAgent.status == 1, "\(args)")
            #expect(inAgent.stderr.contains("owner commands can't run inside an agent turn"), "\(args): \(inAgent.stderr)")
        }
        #expect(!FileManager.default.fileExists(atPath: CanaryProbes.url(paths: ownerPaths(owner.url)).path))
        let nokey = try OwnerTestHome(initOwner: false)
        let r = try brahma(["canary", "edit"], home: nokey.url, env: ["EDITOR": "/usr/bin/true"])
        #expect(r.status == 1); #expect(r.stderr.contains("owner key missing or invalid"))
    }

    @Test func helpListsBoth() throws {
        let owner = try OwnerTestHome()
        let r = try brahma(["canary", "--help"], home: owner.url)
        #expect(r.stdout.contains("edit")); #expect(r.stdout.contains("run"))
        #expect(try brahma(["--help"], home: owner.url).stdout.contains("canary"))
    }
}
