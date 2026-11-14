import Testing
import Foundation
import CryptoKit

// Shared by BrahmaCoreTests, BrahmaAppModelTests and BrahmaMapKitTests: the three copies are byte-identical (TempHygieneTests checks). Both targets
// run in one test process; each module keeps its own registry, so each works in its own subroot (`Scratch.moduleTag`).

/// Test scratch space, structural. One root per test process (`$TMPDIR/brahma-test-<pid>/<TestTarget>/`), one directory
/// per test case (`tempDir()`), removed when the test case ends — passed, failed or thrown — by the `.scratch` trait every
/// suite carries, so no test has to remember a `defer`. A crash leaks at most the one root, which the next test process
/// removes (its pid is dead). Fake executables (`FakeTools`) are written once per process under `<subroot>/tools/`, keyed
/// by content, so the suite does not mint a fresh executable per test (macOS assesses every new one).
///
/// The guards are order-independent: when a test case ends, `ScratchScope.finish()` records an issue against THAT test if
/// one of its directories survives removal (after retries) or holds an executable the test made outside the shared tool
/// dir; `tempDir()` outside a scope records an issue against the running test. `ScratchHygieneTests` re-checks the
/// process-level lists, and the exit hook prints them.
enum Scratch {
    static let pid = getpid()
    static let rootName = "brahma-test-\(pid)"
    fileprivate static let temporaryBase = FileManager.default.temporaryDirectory
    fileprivate static let homeBase = FileManager.default.homeDirectoryForCurrentUser
    /// The test target this copy is compiled into (`BrahmaCoreTests`, `BrahmaAppModelTests`, `BrahmaMapKitTests`).
    static let moduleTag = String(#fileID.prefix { $0 != "/" })

    /// `$TMPDIR/brahma-test-<pid>/<TestTarget>/`, created on first use; stale roots are swept first.
    static let root: URL = makeRoot(in: temporaryBase, prefix: "brahma-test-")

    /// `~/.brahma-test-<pid>/<TestTarget>/`, for the Seatbelt tests (a home denial has to be the real one); same sweep and
    /// exit removal. Reached only through `homeDir()`, so every directory under it is scoped.
    fileprivate static let homeRoot: URL = makeRoot(in: homeBase, prefix: ".brahma-test-")

    /// A fresh directory for the current test case under the owner's real home (Seatbelt tests), removed when the case ends.
    static func homeDir() throws -> URL { try dir(under: homeRoot) }

    /// A fresh directory for the current test case, under `root` (or `parent`), removed when the test case ends.
    static func dir(under parent: URL? = nil) throws -> URL {
        let scope = ScratchScope.current
        let base = parent ?? root
        let url = (scope == nil ? base.appending(path: "orphan", directoryHint: .isDirectory) : base)
            .appending(path: state.nextName(), directoryHint: .isDirectory)
        if let scope {
            scope.register(url)
        } else {
            state.lock.withLock { state.orphans.append(url.path) }
            if Test.current != nil {
                Issue.record("tempDir() outside a scratch scope: this test's type is not a @Suite(.scratch), or the call is in detached work: \(url.path)")
            }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: roots

    /// This process's start time: the sweep marker carries it, so a root left by a dead process that had our pid is told
    /// from our own (I5), and the two modules sweep each base once per process (I7).
    static let startTime: String = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return "0" }
        return "\(info.kp_proc.p_starttime.tv_sec)"
    }()

    private static func makeRoot(in base: URL, prefix: String) -> URL {
        let fm = FileManager.default
        let rootURL = base.appending(path: prefix + "\(pid)", directoryHint: .isDirectory)
        let marker = rootURL.appending(path: ".swept-\(startTime)")
        let subroot = rootURL.appending(path: moduleTag, directoryHint: .isDirectory)
        // The two modules' first uses may race: a lock on the base directory serialises them.
        let lock = open(base.path, O_RDONLY)
        if lock >= 0 { _ = flock(lock, LOCK_EX) }
        defer { if lock >= 0 { close(lock) } }
        if !fm.fileExists(atPath: marker.path) {
            // Not ours: a root of a dead process that had our pid (I5), or nothing yet.
            if fm.fileExists(atPath: rootURL.path) { removeOnce(rootURL) }
            sweep(in: base, prefix: prefix)
            try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            fm.createFile(atPath: marker.path, contents: nil)
        }
        try? fm.createDirectory(at: subroot, withIntermediateDirectories: true)
        _ = exitHook
        return subroot
    }

    /// Removes the roots of this process at exit (the per-test cleanup has emptied them; `tools/` is what is left), and
    /// prints what the guards recorded (the issues were already recorded against the owning tests).
    private static let exitHook: Void = {
        atexit {
            for url in [Scratch.temporaryBase.appending(path: Scratch.rootName), Scratch.homeBase.appending(path: "." + Scratch.rootName)]
            where FileManager.default.fileExists(atPath: url.path) {
                Scratch.removeOnce(url)
            }
            let s = Scratch.state
            let (leaks, orphans, executables) = s.lock.withLock { (s.leaks, s.orphans, s.executables) }
            for (what, list) in [("leaked scratch dirs", leaks), ("orphan scratch dirs", orphans), ("executables outside tools/", executables)]
            where !list.isEmpty {
                FileHandle.standardError.write(Data("brahma tests (\(Scratch.moduleTag)): \(what): \(list.joined(separator: " "))\n".utf8))
            }
        }
    }()

    /// The roots under `base` whose process is dead.
    static func deadRoots(in base: URL, prefix: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).compactMap { name in
            guard name.hasPrefix(prefix), let other = pidNumber(name.dropFirst(prefix.count)), other != pid, isDead(other) else { return nil }
            return base.appending(path: name, directoryHint: .isDirectory)
        }
    }

    /// Digits only (I8): `kill` of 0 or a negative number means a process group, never "this root's process".
    static func pidNumber(_ suffix: Substring) -> Int32? {
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int32(suffix)
    }

    static func isDead(_ other: Int32) -> Bool { other > 0 && kill(other, 0) == -1 && errno == ESRCH }

    /// The old per-test layout (`brahma-test-<UUID>` in `$TMPDIR`, `.brahma-test-<UUID>` in the home — nothing else, I3),
    /// swept when older than a day: at most `oldFormatExamined` looked at and `oldFormatRemoved` removed per process start.
    static let oldFormatExamined = 5000, oldFormatRemoved = 1000

    static func isOldFormat(_ suffix: Substring) -> Bool { suffix.count == 36 && UUID(uuidString: String(suffix)) != nil }

    private static func sweep(in base: URL, prefix: String) {
        guard var names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        names.sort()                                                            // deterministic progress through the old dirs (I7)
        var examined = 0, removed = 0, roots = 0
        let dayAgo = Date().addingTimeInterval(-86_400)
        for name in names where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            if let other = pidNumber(suffix) {
                if other != pid, isDead(other) {
                    removeOnce(base.appending(path: name, directoryHint: .isDirectory))
                    roots += 1
                }
            } else if examined < oldFormatExamined, removed < oldFormatRemoved, isOldFormat(suffix) {
                examined += 1
                let url = base.appending(path: name)
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified < dayAgo else { continue }
                removeOnce(url)
                removed += 1
            }
        }
        state.lock.withLock { state.sweptRoots += roots; state.sweptOldFormat += removed }
    }

    // MARK: removal

    /// One attempt, no chmod pass, no sleep: the sweep (under the base lock), the stale own-pid root and the exit hook. What
    /// it cannot remove is left for the next process's sweep.
    static func removeOnce(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes a test's directory (`ScratchScope.finish` only): a tree the test left unwritable is made writable, and a
    /// removal a still-running child races is retried (3 × 50 ms, I4). What still remains is a leak: recorded, and
    /// `finish` fails the owning test.
    @discardableResult
    static func remove(_ url: URL, recordLeak: Bool = true) -> Bool {
        let fm = FileManager.default
        func gone() -> Bool { (try? fm.removeItem(at: url)) != nil || !fm.fileExists(atPath: url.path) }
        if gone() { return true }
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            for case let item as URL in e where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
            }
        }
        for _ in 0..<3 {
            usleep(50_000)
            if gone() { return true }
        }
        if recordLeak { state.lock.withLock { state.leaks.append(url.path) } }
        return false
    }

    // MARK: executables

    /// Executable regular files under `dir` that a test made itself: not a hard link of a shared fake (`FakeTools`), not a
    /// name the test declared with `FakeTools.fixtureMode`, and not inside `.git/` (git's own sample hooks and checkouts)
    /// or `.brahma/bin/` and `.brahma/hooks/` (the engine's shell prefix and pre-commit hook, the subject's own output).
    static func strayExecutables(in dir: URL, allowedNames: Set<String>) -> [String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isExecutableKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys), options: []) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            let name = url.lastPathComponent
            if v.isDirectory == true {
                if name == ".git" || ((name == "bin" || name == "hooks") && url.deletingLastPathComponent().lastPathComponent == ".brahma") { e.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, v.isExecutable == true, !allowedNames.contains(name) else { continue }
            var st = stat()
            if stat(url.path, &st) == 0, state.isToolInode(UInt64(st.st_ino)) { continue }
            out.append(url.path)
        }
        return out
    }

    // MARK: state

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var counter = 0
        var live: Set<String> = []
        var leaks: [String] = [], orphans: [String] = [], executables: [String] = []
        var sweptRoots = 0, sweptOldFormat = 0
        var written: Set<String> = []
        var toolInodes: Set<UInt64> = []

        /// A counter only: a test's name in the path would show up in what tests assert on (`ultracodeNeverEmitted`...).
        func nextName() -> String {
            let n = lock.withLock { counter += 1; return counter }
            return "t\(n)"
        }
        func isLive(_ path: String) -> Bool { lock.withLock { live.contains(path) } }
        func isToolInode(_ inode: UInt64) -> Bool { lock.withLock { toolInodes.contains(inode) } }
        var leakedPaths: [String] { lock.withLock { leaks } }
        var orphanPaths: [String] { lock.withLock { orphans } }
        var strayExecutablePaths: [String] { lock.withLock { executables } }
    }
    static let state = State()
}

/// The directories one test case made; checked and removed when the case ends, with any problem recorded against that test.
final class ScratchScope: @unchecked Sendable {
    @TaskLocal static var current: ScratchScope?
    private let lock = NSLock()
    private var dirs: [URL] = []
    private var allowedNames: Set<String> = []

    func register(_ url: URL) {
        lock.withLock { dirs.append(url) }
        Scratch.state.lock.withLock { _ = Scratch.state.live.insert(url.path) }
    }

    func allowExecutable(named name: String) { lock.withLock { _ = allowedNames.insert(name) } }

    func finish() {
        let (mine, allowed) = lock.withLock { let d = dirs; dirs = []; return (d, allowedNames) }
        var strays: [String] = [], leaked: [String] = []
        for url in mine {
            strays += Scratch.strayExecutables(in: url, allowedNames: allowed)
            if !Scratch.remove(url) { leaked.append(url.path) }
            Scratch.state.lock.withLock { _ = Scratch.state.live.remove(url.path) }
        }
        if !strays.isEmpty {
            Scratch.state.lock.withLock { Scratch.state.executables += strays }
            Issue.record("this test wrote executables outside the shared fake-tool dir (use FakeTools.script/bin/install, or FakeTools.fixtureMode for a mode that is itself under test): \(strays)")
        }
        if !leaked.isEmpty {
            Issue.record("this test's scratch directories could not be removed (a child still writing there?): \(leaked)")
        }
    }
}

/// `@Suite(.scratch)` / `@Test(.scratch)`: every `tempDir()` of the test case is removed when the case ends, however it ends.
struct ScratchTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> ScratchTrait? { testCase == nil ? nil : self }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let scope = ScratchScope()
        defer { scope.finish() }
        try await ScratchScope.$current.withValue(scope) { try await function() }
    }
}

extension Trait where Self == ScratchTrait {
    static var scratch: ScratchTrait { ScratchTrait() }
}

/// Fake executables (`#!/bin/sh` scripts standing in for claude, litestream, rclone, git helpers...), written once per process
/// under `<subroot>/tools/<content hash>/` and shared by every test that asks for the same content. Behaviour variants are
/// driven by the script's arguments, its working directory or an environment variable the subject passes through, not by
/// another script file.
enum FakeTools {
    static var toolsDir: URL { Scratch.root.appending(path: "tools", directoryHint: .isDirectory) }

    /// The one executable for this (name, body): `<subroot>/tools/<hash>/<name>`.
    static func script(_ name: String, _ body: String) throws -> URL {
        try bin([name: body]).appending(path: name)
    }

    /// A directory holding exactly these scripts (a PATH entry), written once per process.
    static func bin(_ scripts: [String: String]) throws -> URL {
        let key = hash(scripts)
        let dir = toolsDir.appending(path: key, directoryHint: .isDirectory)
        let fm = FileManager.default
        try Scratch.state.lock.withLock {
            guard !Scratch.state.written.contains(key) else { return }
            if !fm.fileExists(atPath: dir.path) {
                let staging = toolsDir.appending(path: ".\(key)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for (name, body) in scripts {
                    let url = staging.appending(path: name)
                    try Data(text(body).utf8).write(to: url)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
                try fm.moveItem(at: staging, to: dir)
            }
            for name in scripts.keys {                                          // the shared inodes: hard links of them are not strays
                var st = stat()
                if stat(dir.appending(path: name).path, &st) == 0 { Scratch.state.toolInodes.insert(UInt64(st.st_ino)) }
            }
            Scratch.state.written.insert(key)
        }
        return dir
    }

    /// The shared script hard-linked at `destination`, for an executable that has to sit at its own path (a hook inside a
    /// repository, a program a git config names, a bundle layout). `$0` in the body is that path. No new executable
    /// content is written; a copy is the fallback across volumes. The link shares the shared script's inode: a test must
    /// only run it, never chmod, append to or truncate it in place (an atomic rewrite makes a new inode and is fine).
    static func install(at destination: URL, _ body: String) throws {
        let shared = try script(destination.lastPathComponent, body)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        do { try fm.linkItem(at: shared, to: destination) } catch { try fm.copyItem(at: shared, to: destination) }
    }

    /// Sets `mode` on a fixture whose mode is itself the thing under test (a hook's mode for the plan barrier, a mode change
    /// under review). The file is never run; its name is allowed by this test's exec-bit walk, copies git makes included.
    static func fixtureMode(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        ScratchScope.current?.allowExecutable(named: url.lastPathComponent)
    }

    static func text(_ body: String) -> String { "#!/bin/sh\n" + body + (body.hasSuffix("\n") ? "" : "\n") }

    static func hash(_ scripts: [String: String]) -> String {
        var h = SHA256()
        for (name, body) in scripts.sorted(by: { $0.key < $1.key }) {
            for part in [name, "\u{0}", text(body), "\u{0}"] { h.update(data: Data(part.utf8)) }
        }
        return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// This target leaves nothing behind (the source scans are in BrahmaCoreTests/TempHygieneTests.swift). The order-independent
/// guard is `ScratchScope.finish()`, which fails the owning test; these re-check the process-level lists (whatever has
/// finished by the time they run) and the roots.
@Suite(.scratch) struct ScratchHygieneTests {
    /// After the startup sweep no root of a dead test process remains, in `$TMPDIR` or in the home (Seatbelt tests).
    @Test func noStaleRootsAfterTheStartupSweep() {
        _ = Scratch.root; _ = Scratch.homeRoot
        #expect(Scratch.deadRoots(in: Scratch.temporaryBase, prefix: "brahma-test-").isEmpty)
        #expect(Scratch.deadRoots(in: Scratch.homeBase, prefix: ".brahma-test-").isEmpty)
        #expect(FileManager.default.fileExists(atPath: Scratch.root.path))
        #expect(Scratch.pidNumber("12") == 12 && Scratch.pidNumber("-1") == nil && Scratch.pidNumber("+5") == nil && Scratch.pidNumber("") == nil)
        #expect(Scratch.isOldFormat("3B02DE0E-11AE-4E61-AF53-731D7180DB90") && !Scratch.isOldFormat("home-3B02DE0E") && !Scratch.isOldFormat("12"))
    }

    /// This target's subroots hold only `tools/` and the directories of tests still running: a finished test's directory is
    /// gone, none could not be removed, none was made outside a test scope, none held a stray executable.
    @Test func finishedTestsLeaveNothingInTheRoot() throws {
        #expect(Scratch.state.leakedPaths == [], "scratch directories that could not be removed")
        #expect(Scratch.state.orphanPaths == [], "tempDir() called outside a test scope")
        #expect(Scratch.state.strayExecutablePaths == [], "executables written outside the shared fake-tool dir")
        for root in [Scratch.root, Scratch.homeRoot] {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name != "tools" && name != "orphan" {
                let path = root.appending(path: name).path
                if Scratch.state.isLive(path) { continue }                   // a test still running
                #expect(!FileManager.default.fileExists(atPath: path), "\(path) outlived its test")
            }
        }
    }

    /// The shared tool directory hands the same file back for the same content and a different one for different content,
    /// `install` hard-links it rather than writing another executable, and the exec-bit walk tells a stray from both.
    @Test func fakeToolsAreWrittenOncePerContent() throws {
        let a = try FakeTools.script("probe", "exit 0"), b = try FakeTools.script("probe", "exit 0"), c = try FakeTools.script("probe", "exit 1")
        #expect(a == b && a != c)
        #expect(a.path.hasPrefix(FakeTools.toolsDir.path))
        #expect(FileManager.default.isExecutableFile(atPath: a.path))
        #expect(try String(contentsOf: a, encoding: .utf8) == "#!/bin/sh\nexit 0\n")
        let dir = try tempDir()
        let dest = dir.appending(path: "hook")
        try FakeTools.install(at: dest, "exit 0")
        let inode = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? UInt64 }
        #expect(inode(dest) == inode(try FakeTools.script("hook", "exit 0")), "a hard link, not a new executable")
        // The walk: a hard link and a declared fixture pass; a plain executable the test wrote does not (checked here, then
        // its bit is cleared so this test's own finish() does not report it).
        let fixture = dir.appending(path: "fixture"), stray = dir.appending(path: "stray")
        try Data("x".utf8).write(to: fixture); try Data("x".utf8).write(to: stray)
        try FakeTools.fixtureMode(0o755, at: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stray.path)  // exec-bit fixture: the walk's own probe
        #expect(Scratch.strayExecutables(in: dir, allowedNames: ["fixture"]).map { URL(fileURLWithPath: $0).lastPathComponent } == ["stray"])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stray.path)
    }
}
