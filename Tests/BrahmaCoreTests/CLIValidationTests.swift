import Foundation
import Testing

/// Runs the built `brahma` binary (it sits next to the test bundle) against a throwaway data home.
private func brahma(_ args: [String]) throws -> (status: Int32, stderr: String) {
    let url = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma")
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let home = try tempDir()
    let p = Process()
    p.executableURL = url
    p.arguments = args
    p.environment = ["BRAHMA_HOME": home.appending(path: "home").path,
                     "BRAHMA_WORKSPACES": home.appending(path: "ws").path, "PATH": "/usr/bin:/bin"]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Suite struct CLIValidationTests {
    @Test(arguments: ["0", "-1"])
    func hardCapMustBePositive(value: String) throws {
        let r = try brahma(["run", "--hard-cap=\(value)"])
        #expect(r.status == 64, "\(r.stderr)")
        #expect(r.stderr.contains("--hard-cap must be at least 1"))
    }

    @Test(arguments: ["0", "1001", "-5"])
    func logLimitIsBounded(value: String) throws {
        let r = try brahma(["log", "Acme", "#general", "--limit=\(value)"])
        #expect(r.status == 64, "\(r.stderr)")
        #expect(r.stderr.contains("--limit must be between 1 and 1000"))
    }

    @Test func validLimitReachesTheCommand() throws {
        let r = try brahma(["log", "Acme", "#general", "--limit", "1000"])
        #expect(r.status == 1)
        #expect(r.stderr.contains("no company named 'Acme'"))
    }
}
