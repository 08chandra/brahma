import Foundation
@testable import BrahmaCore

/// A throwaway workspace directory with an engine-initialized repo, plus plain `git` for building fixtures and
/// checking results (the engine's own calls always go through `GitWorkspace`).
struct GitFixture {
    let root: URL
    var ws: GitWorkspace { GitWorkspace(root: root) }

    init(files: [String: String] = [:], ensure: Bool = true) throws {
        root = try tempDir().appending(path: "ws", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files { try write(path, text) }
        if ensure { try ws.ensureRepo() }
    }

    @discardableResult
    func write(_ path: String, _ text: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? root).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Plain git, with the owner's normal discovery. Returns trimmed stdout; throws on a non-zero exit.
    @discardableResult
    func git(_ args: [String], in dir: URL? = nil, env: [String: String] = [:], allowFailure: Bool = false) throws -> String {
        try GitFixture.plainGit(args, in: dir ?? root, env: env, allowFailure: allowFailure)
    }

    @discardableResult
    static func plainGit(_ args: [String], in dir: URL, env: [String: String] = [:], allowFailure: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir.path, "-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args
        var e = ProcessInfo.processInfo.environment
        e["GIT_CONFIG_GLOBAL"] = "/dev/null"
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0, !allowFailure {
            throw FakeError(description: "git \(args.joined(separator: " ")) failed: \(String(decoding: r, as: UTF8.self))")
        }
        return String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
