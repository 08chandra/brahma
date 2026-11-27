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
                         version: @escaping (String) -> String? = ToolPathsTests.fixedVersion,
                         group: gid_t? = ToolPaths.trustedWriterGroup,
                         prefixes: [String] = ToolPaths.trustedGroupPrefixes) throws -> ToolPaths {
        switch ToolPaths.resolve(path: path, forbiddenRoots: forbidden, xcrunFind: xcrun, gitVersion: version, trustedGroup: group,
                                 trustedPrefixes: prefixes) {
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

    #if os(macOS)
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
    #endif

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

    static func gid(_ url: URL) throws -> gid_t {
        var st = stat()
        try #require(stat(url.path, &st) == 0)
        return st.st_gid
    }

    /// Ruling S5-1: a group-writable directory is a candidate only when its group is the trusted writer group (macOS `admin`,
    /// Homebrew's prefix); never a world-writable one, never one inside a forbidden root. Tests pass the fixture's own group
    /// and the scratch directory as the trusted prefix (Ruling S5-1b's seam).
    @Test func trustedWriterGroupDirectoryAccepted() throws {
        let scratch = try tempDir()
        let prefixes = [scratch.path]
        let brew = try Self.bin(scratch.appending(path: "brew", directoryHint: .isDirectory), ["git", "claude"])
        chmod(brew.path, 0o775)  // exec-bit fixture: the directory mode is under test
        let group = try Self.gid(brew)
        let tools = try Self.resolved(brew.path, group: group, prefixes: prefixes)
        #expect(tools.git == brew.appending(path: "git").path)
        #expect(tools.claude == brew.appending(path: "claude").path)
        #expect(ToolPaths.candidateDirectories(path: brew.path, forbiddenRoots: [], trustedGroup: group, trustedPrefixes: prefixes)
                == [brew.path])
        // No trusted group, or another group: the group-writable directory is refused.
        #expect(ToolPaths.resolve(path: brew.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion,
                                  trustedGroup: nil, trustedPrefixes: prefixes) == .failure(.gitMissing))
        #expect(ToolPaths.resolve(path: brew.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion,
                                  trustedGroup: group + 1, trustedPrefixes: prefixes) == .failure(.gitMissing))
        // World-writable stays refused, whatever its group.
        chmod(brew.path, 0o777)  // exec-bit fixture: the directory mode is under test
        #expect(ToolPaths.resolve(path: brew.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion,
                                  trustedGroup: group, trustedPrefixes: prefixes) == .failure(.gitMissing))
        chmod(brew.path, 0o775)  // exec-bit fixture: the directory mode is under test
        // Inside a forbidden root: refused, the trusted group notwithstanding.
        #expect(ToolPaths.resolve(path: brew.path, forbiddenRoots: [scratch], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion,
                                  trustedGroup: group, trustedPrefixes: prefixes) == .failure(.gitMissing))
        // The same holds for the executable itself: group-writable only with the trusted group.
        let file = try Self.bin(scratch.appending(path: "file", directoryHint: .isDirectory), ["git"])
        try FakeTools.fixtureMode(0o775, at: file.appending(path: "git"))
        #expect(try Self.resolved(file.path, group: try Self.gid(file), prefixes: prefixes).git == file.appending(path: "git").path)
        #expect(ToolPaths.resolve(path: file.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion,
                                  trustedGroup: nil, trustedPrefixes: prefixes) == .failure(.gitMissing))
    }

    /// Ruling S5-1b: the trusted group's exception holds only inside the Homebrew prefix (`trustedGroupPrefixes`), judged on
    /// resolved paths with component boundaries. The same 0775 directory with the matching group outside it, under a
    /// sibling `<prefix>X`, or reached through a link from inside it, is refused; so is a group-writable executable outside.
    @Test func trustedGroupOnlyInsideTheHomebrewPrefix() throws {
        let scratch = try tempDir()
        let prefix = scratch.appending(path: "brew", directoryHint: .isDirectory)
        let inside = try Self.bin(prefix.appending(path: "bin", directoryHint: .isDirectory), ["git"])
        let outside = try Self.bin(scratch.appending(path: "other/bin", directoryHint: .isDirectory), ["git"])
        let sibling = try Self.bin(scratch.appending(path: "brewX/bin", directoryHint: .isDirectory), ["git"])
        for dir in [inside, outside, sibling] { chmod(dir.path, 0o775) }  // exec-bit fixture: the directory mode is under test
        let group = try Self.gid(inside)
        func resolve(_ dir: URL) -> Result<ToolPaths, ToolPathsError> {
            ToolPaths.resolve(path: dir.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion,
                              trustedGroup: group, trustedPrefixes: [prefix.path])
        }
        #expect(try resolve(inside).get().git == inside.appending(path: "git").path)
        #expect(resolve(outside) == .failure(.gitMissing), "outside the prefix")
        #expect(resolve(sibling) == .failure(.gitMissing), "<prefix>X is not inside <prefix>")
        // A link inside the prefix to the group-writable directory outside it: judged where it resolves.
        let link = prefix.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(resolve(link) == .failure(.gitMissing), "resolved outside the prefix")
        // The executable itself: group-writable inside the prefix with the group, refused outside.
        let fileIn = try Self.bin(prefix.appending(path: "files", directoryHint: .isDirectory), ["git"])
        let fileOut = try Self.bin(scratch.appending(path: "files", directoryHint: .isDirectory), ["git"])
        for dir in [fileIn, fileOut] { try FakeTools.fixtureMode(0o775, at: dir.appending(path: "git")) }
        #expect(try resolve(fileIn).get().git == fileIn.appending(path: "git").path)
        #expect(resolve(fileOut) == .failure(.gitMissing))
        // The engine's git handed to `brahma mcp` meets the same rule.
        #expect(ToolPaths.validateEngineGit(fileOut.appending(path: "git").path, forbiddenRoots: [], gitVersion: Self.fixedVersion,
                                            trustedGroup: group, trustedPrefixes: [prefix.path]) == .failure(.gitMissing))
        #expect(ToolPaths.trustedGroupPrefixes == ["/opt/homebrew", "/usr/local"])
        #expect(ToolPaths.safeDirectoryRule.contains("Homebrew prefix only"))
    }

    /// The default trusted group is macOS `admin` (gid 80), constant, and none elsewhere (Ruling S5-1).
    @Test func trustedWriterGroupIsAdminOnMacOS() {
        #if os(macOS)
        #expect(ToolPaths.trustedWriterGroup == 80)
        #else
        #expect(ToolPaths.trustedWriterGroup == nil)
        #endif
        #expect(ToolPaths.safeDirectoryRule.contains("admin"))
    }

    /// The owner's Homebrew (`/opt/homebrew/bin`, group `admin`, group-writable): its git is the one chosen (spec §6.5's
    /// `tools: git /opt/homebrew/bin/git …`). Live: only where that layout exists.
    @Test(.enabled(if: ToolPathsTests.homebrewLayout)) func homebrewGitChosenWithTheDefaultGroup() throws {
        let tools = try Self.resolved("/opt/homebrew/bin", version: ToolPaths.probeGitVersion)
        #expect(tools.git == "/opt/homebrew/bin/git")
    }

    static var homebrewLayout: Bool {
        #if os(macOS)
        var st = stat()
        guard stat("/opt/homebrew/bin", &st) == 0, st.st_gid == 80, st.st_mode & S_IWOTH == 0,
              st.st_uid == 0 || st.st_uid == getuid() else { return false }
        return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git")
        #else
        return false
        #endif
    }

    /// I2: the executable itself is judged, not only its directory: its resolved file must be owned by root or this user and
    /// not writable by others, and the directory it resolves into must be a safe directory too.
    @Test func executableItselfIsChecked() throws {
        let scratch = try tempDir()
        let safe = try Self.bin(scratch.appending(path: "safe", directoryHint: .isDirectory), ["git"])
        // A world-writable executable in a 0755 directory.
        let loose = try Self.bin(scratch.appending(path: "loose", directoryHint: .isDirectory), ["git", "claude"])
        try FakeTools.fixtureMode(0o777, at: loose.appending(path: "git"))
        try FakeTools.fixtureMode(0o757, at: loose.appending(path: "claude"))
        var tools = try Self.resolved("\(loose.path):\(safe.path)")
        #expect(tools.git == safe.appending(path: "git").path)
        #expect(tools.claude == nil, "a world-writable claude is never found")
        // A link in a safe directory to an executable in a world-writable directory.
        let open = try Self.bin(scratch.appending(path: "open", directoryHint: .isDirectory), ["git"])
        chmod(open.path, 0o777)  // exec-bit fixture: the directory mode is under test
        let relay = scratch.appending(path: "relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)
        chmod(relay.path, 0o755)  // exec-bit fixture: the directory mode is under test
        try FileManager.default.createSymbolicLink(at: relay.appending(path: "git"), withDestinationURL: open.appending(path: "git"))
        tools = try Self.resolved("\(relay.path):\(safe.path)")
        #expect(tools.git == safe.appending(path: "git").path)
        #expect(ToolPaths.resolve(path: relay.path, forbiddenRoots: [], xcrunFind: { _ in nil }, gitVersion: Self.fixedVersion)
                == .failure(.gitMissing))
        // A `..` entry is judged where it leads: into the world-writable directory it is refused, into a safe one accepted.
        #expect(ToolPaths.resolve(path: "\(safe.path)/../open", forbiddenRoots: [], xcrunFind: { _ in nil },
                                  gitVersion: Self.fixedVersion) == .failure(.gitMissing))
        #expect(ToolPaths.candidateDirectories(path: "\(open.path)/../safe", forbiddenRoots: []) == ["\(open.path)/../safe"])
        // A directory whose name no sandbox profile may carry is no candidate.
        let quoted = try Self.bin(scratch.appending(path: "sa'fe", directoryHint: .isDirectory), ["git"])
        #expect(ToolPaths.candidateDirectories(path: quoted.path, forbiddenRoots: []).isEmpty)
    }

    #if os(macOS)
    /// I2: the shim is recognised by where a candidate resolves, so `/usr/bin/`, `//usr/bin` or `/usr/../usr/bin` on PATH
    /// still go through xcrun rather than starting the shim.
    @Test func shimSpellingsGoThroughXcrun() throws {
        let real = try Self.bin(try tempDir().appending(path: "real", directoryHint: .isDirectory), ["git"])
        let realGit = real.appending(path: "git").path
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "/usr/bin/git is the macOS shim")
        for entry in ["/usr/bin/", "//usr/bin", "/usr/../usr/bin"] {
            final class Asked: @unchecked Sendable { var names: [String] = [] }
            let asked = Asked()
            let tools = try Self.resolved(entry, xcrun: { asked.names.append($0); return realGit })
            #expect(tools.git == realGit, "\(entry)")
            #expect(asked.names == ["git"], "\(entry)")
        }
    }
    #endif

    /// Ruling S-c1: before this process installed its tools with the real forbidden roots, nothing is resolved and nothing is
    /// looked up on PATH: `engine()` and `engineTool` refuse (`notInstalled`). An install replaces the last one (the app's
    /// post-login-shell PATH wins), and its forbidden roots hold for every later lookup.
    @Test func resolvingBeforeInstallThrows() throws {
        let scratch = try tempDir()
        let none = try Self.bin(scratch.appending(path: "none", directoryHint: .isDirectory), [])
        let withClaude = try Self.bin(scratch.appending(path: "b", directoryHint: .isDirectory), ["claude", "npm"])
        try ToolPaths.withIsolatedSlot { () throws in
            #expect(!ToolPaths.isInstalled)
            #expect(ToolPaths.engine() == .failure(.notInstalled))
            #expect(throws: ToolPathsError.notInstalled) { try ToolPaths.engineTool(named: "claude") }
            #expect(throws: ToolPathsError.notInstalled) { try ToolPaths.engineTool(named: "npm") }
            #expect(ToolPaths.gitCandidates.isEmpty)
            #expect("\(ToolPathsError.notInstalled)".contains("nothing is looked up on PATH"))
            // PATH A (no claude), then PATH B (one): the second install is what counts.
            ToolPaths.install(forbiddenRoots: [], path: none.path)
            #expect(ToolPaths.isInstalled)
            #expect(ToolPaths.engine() == .failure(.gitMissing))
            #expect(try ToolPaths.engineTool(named: "claude") == nil)
            ToolPaths.install(forbiddenRoots: [], path: "\(none.path):\(withClaude.path)")
            #expect(try ToolPaths.engineTool(named: "claude") == withClaude.appending(path: "claude").path)
            #expect(try ToolPaths.engineTool(named: "npm") == withClaude.appending(path: "npm").path)
            // The same directory inside a forbidden root of the last install: never looked in.
            ToolPaths.install(forbiddenRoots: [scratch], path: withClaude.path)
            #expect(try ToolPaths.engineTool(named: "claude") == nil)
            #expect(try ToolPaths.engineTool(named: "npm") == nil)
        }
    }

    /// S5 fix 3 (R2): the test processes' seed install (`toolPathsInstalled`) lands in the process slot even when it is first
    /// armed inside `withIsolatedSlot`; the isolated slot stays empty, and an install already in the process slot is kept.
    @Test func testSeedInstallsTheProcessSlotFromInsideAnIsolatedSlot() {
        ToolPaths.withIsolatedSlot {
            ToolPaths.installProcessWide(forbiddenRoots: [])
            #expect(!ToolPaths.isInstalled)                     // the isolated slot: untouched
            #expect(ToolPaths.engine() == .failure(.notInstalled))
            #expect(ToolPaths.isInstalledProcessWide)
            #expect(!ToolPaths.installProcessWide(forbiddenRoots: []))   // already seeded: kept, not replaced
        }
        #expect(ToolPaths.isInstalled)                          // the process slot, outside any isolated one
    }

    /// Ruling S5-4: a process the engine started (`brahma mcp`) takes the engine's git and checks it again under the same
    /// rules (owner and mode, Ruling S5-1, its resolved directory, the forbidden roots, the shim, 2.43); anything else is
    /// `gitMissing` (or `gitTooOld`), never a PATH walk.
    @Test func engineGitIsRevalidated() throws {
        let scratch = try tempDir()
        let safe = try Self.bin(scratch.appending(path: "safe", directoryHint: .isDirectory), ["git"])
        let ws = scratch.appending(path: "ws", directoryHint: .isDirectory)
        let planted = try Self.bin(ws.appending(path: "bin", directoryHint: .isDirectory), ["git"])
        let open = try Self.bin(scratch.appending(path: "open", directoryHint: .isDirectory), ["git"])
        chmod(open.path, 0o777)  // exec-bit fixture: the directory mode is under test
        let link = scratch.appending(path: "relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        chmod(link.path, 0o755)  // exec-bit fixture: the directory mode is under test
        try FileManager.default.createSymbolicLink(at: link.appending(path: "git"), withDestinationURL: planted.appending(path: "git"))
        func check(_ git: String?, version: (String) -> String? = Self.fixedVersion) -> Result<ToolPaths, ToolPathsError> {
            ToolPaths.validateEngineGit(git, forbiddenRoots: [ws], gitVersion: version)
        }
        let good = try check(safe.appending(path: "git").path).get()
        #expect(good.git == safe.appending(path: "git").path); #expect(good.gitVersion == "2.50.1"); #expect(good.claude == nil)
        for refused in [planted.appending(path: "git").path, open.appending(path: "git").path, link.appending(path: "git").path,
                        "git", "bin/git", "", scratch.appending(path: "missing/git").path] {
            #expect(check(refused) == .failure(.gitMissing), "\(refused)")
        }
        #expect(check(nil) == .failure(.gitMissing))
        #expect(check(safe.appending(path: "git").path, version: { _ in "2.39.5" }) == .failure(.gitTooOld("2.39.5")))
        #expect(check(safe.appending(path: "git").path, version: { _ in nil }) == .failure(.gitTooOld("unknown")))
        #if os(macOS)
        #expect(check(ToolPaths.gitShim) == .failure(.gitMissing), "the shim would need xcrun")
        #endif
        // Installed, it is the process's tools (and nothing else is looked up: there is no PATH).
        try ToolPaths.withIsolatedSlot { () throws in
            ToolPaths.installFromEngine(git: safe.appending(path: "git").path, forbiddenRoots: [ws], gitVersion: Self.fixedVersion)
            #expect(try ToolPaths.engine().get().git == safe.appending(path: "git").path)
            #expect(ToolPaths.gitCandidates == [safe.appending(path: "git").path])
            #expect(try ToolPaths.engineTool(named: "git") == nil)
            ToolPaths.installFromEngine(git: planted.appending(path: "git").path, forbiddenRoots: [ws], gitVersion: Self.fixedVersion)
            #expect(ToolPaths.engine() == .failure(.gitMissing))
            ToolPaths.installFromEngine(git: nil, forbiddenRoots: [ws], gitVersion: Self.fixedVersion)
            #expect(ToolPaths.engine() == .failure(.gitMissing))
        }
    }
}
