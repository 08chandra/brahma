import Testing
import Foundation
import CryptoKit

// Shared by BrahmaCoreTests and BrahmaAppModelTests: the two copies are byte-identical (TempHygieneTests checks). Both targets
// run in one test process; each module keeps its own registry, so each works in its own subroot (`Scratch.moduleTag`).

/// Test scratch space, structural. One root per test process (`$TMPDIR/brahma-test-<pid>/<TestTarget>/`), one directory
/// per test case (`tempDir()`), removed when the test case ends — passed, failed or thrown — by the `.scratch` trait every
/// suite carries, so no test has to remember a `defer`. A crash leaks at most the one root, which the next test process
/// removes (its pid is dead). Fake executables (`FakeTools`) are written once per process under `<subroot>/tools/`, keyed
/// by content, so the suite does not mint a fresh executable per test (macOS assesses every new one).
enum Scratch {
    static let pid = getpid()
    static let rootName = "brahma-test-\(pid)"
    static let temporaryBase = FileManager.default.temporaryDirectory
    static let homeBase = FileManager.default.homeDirectoryForCurrentUser
    /// The test target this copy is compiled into (`BrahmaCoreTests`, `BrahmaAppModelTests`).
    static let moduleTag = String(#fileID.prefix { $0 != "/" })

    /// `$TMPDIR/brahma-test-<pid>/<TestTarget>/`, created on first use; stale roots are swept first.
    static let root: URL = makeRoot(in: temporaryBase, prefix: "brahma-test-")

    /// `~/.brahma-test-<pid>/<TestTarget>/`, for the Seatbelt tests (a home denial has to be the real one); same sweep and
    /// exit removal.
    static let homeRoot: URL = makeRoot(in: homeBase, prefix: ".brahma-test-")

    /// A fresh directory for the current test case, under `root` (or `parent`), removed when the test case ends.
    static func dir(under parent: URL? = nil) throws -> URL {
        let scope = ScratchScope.current
        let base = parent ?? root
        let url = (scope == nil ? base.appending(path: "orphan", directoryHint: .isDirectory) : base)
            .appending(path: state.nextName(), directoryHint: .isDirectory)
        scope?.register(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: roots

    private static func makeRoot(in base: URL, prefix: String) -> URL {
        sweep(in: base, prefix: prefix)
        let url = base.appending(path: prefix + "\(pid)", directoryHint: .isDirectory).appending(path: moduleTag, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = exitHook
        return url
    }

    /// Removes the roots of this process at exit (the per-test cleanup has emptied them; `tools/` is what is left).
    private static let exitHook: Void = {
        atexit {
            for url in [Scratch.temporaryBase.appending(path: Scratch.rootName), Scratch.homeBase.appending(path: "." + Scratch.rootName)]
            where FileManager.default.fileExists(atPath: url.path) {
                Scratch.remove(url, recordLeak: false)
            }
        }
    }()

    /// The roots under `base` whose process is dead.
    static func deadRoots(in base: URL, prefix: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).compactMap { name in
            guard name.hasPrefix(prefix), let other = Int32(name.dropFirst(prefix.count)), other != pid, isDead(other) else { return nil }
            return base.appending(path: name, directoryHint: .isDirectory)
        }
    }

    static func isDead(_ other: Int32) -> Bool { kill(other, 0) == -1 && errno == ESRCH }

    /// Old-format per-test names (before the per-process root), swept when older than a day: at most `oldFormatExamined`
    /// looked at and `oldFormatRemoved` removed per process start, so the sweep stays fast whatever is lying around.
    static let oldFormatPrefixes = ["brahma-test-", "brahma-appmodel-", "brahma-pack-", "brahma-shell-", ".brahma-test-"]
    static let oldFormatExamined = 5000, oldFormatRemoved = 1000

    private static func sweep(in base: URL, prefix: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        var examined = 0, removed = 0
        let dayAgo = Date().addingTimeInterval(-86_400)
        for name in names {
            if name.hasPrefix(prefix), let other = Int32(name.dropFirst(prefix.count)) {
                if other != pid, isDead(other) {
                    remove(base.appending(path: name, directoryHint: .isDirectory), recordLeak: false)
                    state.lock.withLock { state.sweptRoots += 1 }
                }
                continue
            }
            guard examined < oldFormatExamined, removed < oldFormatRemoved,
                  oldFormatPrefixes.contains(where: { name.hasPrefix($0) && Int32(name.dropFirst($0.count)) == nil }) else { continue }
            examined += 1
            let url = base.appending(path: name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified < dayAgo else { continue }
            remove(url, recordLeak: false)
            removed += 1
        }
        state.lock.withLock { state.sweptOldFormat += removed }
    }

    // MARK: removal

    /// Removes `url`; a tree a test left unwritable is made writable first. A failure is a leak (`ScratchHygieneTests`).
    static func remove(_ url: URL, recordLeak: Bool = true) {
        let fm = FileManager.default
        if (try? fm.removeItem(at: url)) != nil || !fm.fileExists(atPath: url.path) { return }
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            for case let item as URL in e where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
            }
        }
        if (try? fm.removeItem(at: url)) != nil || !fm.fileExists(atPath: url.path) { return }
        if recordLeak { state.lock.withLock { state.leaks.append(url.path) } }
    }

    // MARK: state

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var counter = 0
        var live: Set<String> = []
        var leaks: [String] = []
        var sweptRoots = 0, sweptOldFormat = 0
        var written: Set<String> = []

        /// A counter only: a test's name in the path would show up in what tests assert on (`ultracodeNeverEmitted`...).
        func nextName() -> String {
            let n = lock.withLock { counter += 1; return counter }
            return "t\(n)"
        }
        func isLive(_ path: String) -> Bool { lock.withLock { live.contains(path) } }
        var leakedPaths: [String] { lock.withLock { leaks } }
    }
    static let state = State()
}

/// The directories one test case made; removed when the case ends.
final class ScratchScope: @unchecked Sendable {
    @TaskLocal static var current: ScratchScope?
    private let lock = NSLock()
    private var dirs: [URL] = []

    func register(_ url: URL) {
        lock.withLock { dirs.append(url) }
        Scratch.state.lock.withLock { _ = Scratch.state.live.insert(url.path) }
    }

    func finish() {
        let mine = lock.withLock { let d = dirs; dirs = []; return d }
        for url in mine {
            Scratch.remove(url)
            Scratch.state.lock.withLock { _ = Scratch.state.live.remove(url.path) }
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
            Scratch.state.written.insert(key)
        }
        return dir
    }

    /// The shared script hard-linked at `destination`, for an executable that has to sit at its own path (a hook inside a
    /// repository, a program a git config names, a bundle layout). `$0` in the body is that path. No new executable
    /// content is written; a copy is the fallback across volumes.
    static func install(at destination: URL, _ body: String) throws {
        let shared = try script(destination.lastPathComponent, body)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        do { try fm.linkItem(at: shared, to: destination) } catch { try fm.copyItem(at: shared, to: destination) }
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

/// This target leaves nothing behind (the source scans are in BrahmaCoreTests/TempHygieneTests.swift).
@Suite(.scratch) struct ScratchHygieneTests {
    /// After the startup sweep no root of a dead test process remains, in `$TMPDIR` or in the home (Seatbelt tests).
    @Test func noStaleRootsAfterTheStartupSweep() {
        _ = Scratch.root; _ = Scratch.homeRoot
        #expect(Scratch.deadRoots(in: Scratch.temporaryBase, prefix: "brahma-test-").isEmpty)
        #expect(Scratch.deadRoots(in: Scratch.homeBase, prefix: ".brahma-test-").isEmpty)
        #expect(FileManager.default.fileExists(atPath: Scratch.root.path))
    }

    /// This target's subroots hold only `tools/` and the directories of tests still running: a finished test's directory is
    /// gone, none could not be removed, and none was made outside a test scope (`orphan/`).
    @Test func finishedTestsLeaveNothingInTheRoot() throws {
        #expect(Scratch.state.leakedPaths == [], "scratch directories that could not be removed")
        for root in [Scratch.root, Scratch.homeRoot] {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name != "tools" && name != "orphan" {
                let path = root.appending(path: name).path
                if Scratch.state.isLive(path) { continue }                   // a test still running
                #expect(!FileManager.default.fileExists(atPath: path), "\(path) outlived its test")
            }
            let orphans = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "orphan").path)) ?? []
            #expect(orphans == [], "tempDir() called outside a test scope (a type with tests but no @Suite(.scratch), or a detached task): \(orphans)")
        }
    }

    /// The shared tool directory hands the same file back for the same content and a different one for different content,
    /// and `install` hard-links it rather than writing another executable.
    @Test func fakeToolsAreWrittenOncePerContent() throws {
        let a = try FakeTools.script("probe", "exit 0"), b = try FakeTools.script("probe", "exit 0"), c = try FakeTools.script("probe", "exit 1")
        #expect(a == b && a != c)
        #expect(a.path.hasPrefix(FakeTools.toolsDir.path))
        #expect(FileManager.default.isExecutableFile(atPath: a.path))
        #expect(try String(contentsOf: a, encoding: .utf8) == "#!/bin/sh\nexit 0\n")
        let dest = try tempDir().appending(path: "hook")
        try FakeTools.install(at: dest, "exit 0")
        let inode = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? UInt64 }
        #expect(inode(dest) == inode(try FakeTools.script("hook", "exit 0")), "a hard link, not a new executable")
    }
}
