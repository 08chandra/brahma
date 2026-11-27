import Testing
import Foundation
@testable import BrahmaSafety

/// Plan S Task S5 (spec §6.5, B9): the engine's tools are resolved once, by absolute path, from the `PATH` entries that are
/// absolute, exist, belong to root or the engine's user, are writable by nobody else and lie outside every company workspace
/// and data home. A tool planted in a workspace, a relative entry or a shared writable directory is never chosen.
@Suite(.scratch) struct ToolPathsTests {
    /// A directory holding executable scripts with these names (mode 0755, the directory 0755). Where each one lives is what
    /// is under test (a planted, shared or safe directory), so they are fixtures in place, not shared fake tools.
    static func bin(_ parent: URL, _ names: [String], body: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        chmod(parent.path, 0o755)  // exec-bit fixture: the directory mode is under test
        for name in names {
            let url = parent.appending(path: name)
            try Data(body.utf8).write(to: url)
            try FakeTools.fixtureMode(0o755, at: url)
        }
        return parent
    }

    static let fixedVersion: @Sendable (String) -> String? = { _ in "2.50.1" }

    static func resolved(_ path: String, forbidden: [URL] = [], xcrun: @escaping (String) -> String? = { _ in nil },
                         version: @escaping (String) -> String? = ToolPathsTests.fixedVersion) throws -> ToolPaths {
        switch ToolPaths.resolve(path: path, forbiddenRoots: forbidden, xcrunFind: xcrun, gitVersion: version) {
        case .success(let tools): return tools
        case .failure(let error): throw error
        }
    }

    @Test func plantedToolInWorkspaceIsNeverChosen() throws {
        let scratch = try tempDir()
        let ws = scratch.appending(path: "ws", directoryHint: .isDirectory)
        let planted = try Self.bin(ws.appending(path: "bin", directoryHint: .isDirectory), ["git", "claude", "curl"])
        let safe = try Self.bin(scratch.appending(path: "safe", directoryHint: .isDirectory), ["git", "claude"])
        let tools = try Self.resolved("\(planted.path):\(safe.path):/usr/bin", forbidden: [ws])
        #expect(tools.git == safe.appending(path: "git").path, "\(tools.git)")
        #expect(tools.claude == safe.appending(path: "claude").path)
        #expect(!tools.curl.hasPrefix(ws.path))
        for path in [tools.git, tools.claude ?? "", tools.curl, tools.unzip, tools.tar, tools.sh, tools.sandboxExec] {
            #expect(path.hasPrefix("/") && !path.hasPrefix(ws.path), "\(path)")
        }
        // The forbidden root named through a link (`/tmp` style): judged on resolved paths.
        let alias = scratch.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ws)
        #expect(try Self.resolved("\(planted.path):\(safe.path)", forbidden: [alias]).git == safe.appending(path: "git").path)
        // A safe-looking directory that is a link into the workspace is inside it once resolved.
        let linked = scratch.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: planted)
        #expect(try Self.resolved("\(linked.path):\(safe.path)", forbidden: [ws]).git == safe.appending(path: "git").path)
        // An executable in a safe directory that is a link to a planted file is refused as well.
        let relay = scratch.appending(path: "relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)
        chmod(relay.path, 0o755)  // exec-bit fixture: the directory mode is under test
        try FileManager.default.createSymbolicLink(at: relay.appending(path: "git"), withDestinationURL: planted.appending(path: "git"))
        #expect(try Self.resolved("\(relay.path):\(safe.path)", forbidden: [ws]).git == safe.appending(path: "git").path)
        // Nothing but the workspace: no git at all.
        #expect(ToolPaths.resolve(path: planted.path, forbiddenRoots: [ws], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion)
                == .failure(.gitMissing))
    }

    @Test func relativeAndEmptyEntriesIgnored() throws {
        let safe = try Self.bin(try tempDir().appending(path: "safe", directoryHint: .isDirectory), ["git"])
        let tools = try Self.resolved(".::bin:\(safe.path):", xcrun: { _ in nil })
        #expect(tools.git == safe.appending(path: "git").path)
        #expect(ToolPaths.candidateDirectories(path: ".::bin:\(safe.path):./x", forbiddenRoots: []) == [safe.path])
        #expect(ToolPaths.resolve(path: ".::bin", forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion)
                == .failure(.gitMissing))
    }

    @Test func worldWritableDirIgnored() throws {
        let scratch = try tempDir()
        let open = try Self.bin(scratch.appending(path: "open", directoryHint: .isDirectory), ["git", "claude"])
        chmod(open.path, 0o777)  // exec-bit fixture: the directory mode is under test
        let shared = try Self.bin(scratch.appending(path: "shared", directoryHint: .isDirectory), ["git", "claude"])
        chmod(shared.path, 0o775)  // exec-bit fixture: the directory mode is under test
        let safe = try Self.bin(scratch.appending(path: "safe", directoryHint: .isDirectory), ["git"])
        let tools = try Self.resolved("\(open.path):\(shared.path):\(safe.path)")
        #expect(tools.git == safe.appending(path: "git").path)
        #expect(tools.claude == nil, "a claude only in a group- or world-writable directory is not found")
        #expect(ToolPaths.candidateDirectories(path: "\(open.path):\(shared.path):\(safe.path)", forbiddenRoots: []) == [safe.path])
        // A directory that is missing or a file is no candidate either.
        #expect(ToolPaths.candidateDirectories(path: "\(scratch.path)/missing:\(safe.path)/git", forbiddenRoots: []).isEmpty)
    }

    @Test func shimResolvedToRealGit() throws {
        let real = try Self.bin(try tempDir().appending(path: "x/real", directoryHint: .isDirectory), ["git"])
        let realGit = real.appending(path: "git").path
        final class Asked: @unchecked Sendable { var names: [String] = [] }
        let asked = Asked()
        let fakeShimDir = "/usr/bin"
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "/usr/bin/git is the macOS shim")
        let tools = try Self.resolved(fakeShimDir, xcrun: { asked.names.append($0); return realGit })
        #expect(tools.git == realGit)
        #expect(asked.names == ["git"])
        #expect(tools.gitVersion == "2.50.1")
        // The shim's target must pass the same rules: one in a world-writable directory is not used.
        chmod(real.path, 0o777)  // exec-bit fixture: the directory mode is under test
        #if os(macOS)
        #expect(ToolPaths.resolve(path: fakeShimDir, forbiddenRoots: [], xcrunFind: { _ in realGit }, gitVersion: Self.fixedVersion)
                == .failure(.gitMissing))
        #endif
        chmod(real.path, 0o755)  // exec-bit fixture: the directory mode is under test
        // git older than 2.43 (3a's attr-source floor) is refused, with its version.
        #expect(ToolPaths.resolve(path: real.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: { _ in "2.39.5" })
                == .failure(.gitTooOld("2.39.5")))
        #expect(ToolPaths.resolve(path: real.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: { _ in nil })
                == .failure(.gitTooOld("unknown")))
        #expect(ToolPaths.isSupportedGit("2.43.0") && ToolPaths.isSupportedGit("3.0") && !ToolPaths.isSupportedGit("2.42.9"))
        #expect(ToolPaths.versionNumber(in: "git version 2.50.1 (Apple Git-155)") == "2.50.1")
    }

    /// The fixed tools, `curl`'s preference, `claude` being optional (the CLI may run without it; the orchestrator's turns
    /// need it) and the helper's candidate set.
    @Test func fixedToolsAndOptionalClaude() throws {
        let safe = try Self.bin(try tempDir().appending(path: "safe", directoryHint: .isDirectory), ["git", "curl"])
        let tools = try Self.resolved(safe.path)
        #expect(tools.sh == "/bin/sh" && tools.sandboxExec == "/usr/bin/sandbox-exec")
        #expect(tools.unzip == "/usr/bin/unzip" && tools.tar == "/usr/bin/tar")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") { #expect(tools.curl == "/usr/bin/curl") }
        #expect(tools.claude == nil)
        #expect(throws: ToolPathsError.claudeMissing) { try tools.requireClaude() }
        #expect(ToolPaths.gitCandidates(of: .success(tools)) == [tools.git])
        #expect(ToolPaths.gitCandidates(of: .failure(.gitMissing)).isEmpty)
        #expect(ToolPathsError.gitTooOld("2.39.5").description.contains("2.43"))
    }
}
