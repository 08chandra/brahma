import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// The Seatbelt backend, run for real: only where `/usr/bin/sandbox-exec` exists. Every test works in `~/.brahma-test-<uuid>`
/// (removed afterwards), under the owner's real home, so the home denial is the real one.
@Suite(.serialized, .enabled(if: Toolchain.seatbeltAvailable, "no /usr/bin/sandbox-exec"))
struct SeatbeltRunnerTests {
    static let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]

    /// The owner's real home, resolved.
    static var realHome: URL { FileManager.default.homeDirectoryForCurrentUser.resolvedForSandbox }

    /// `~/.brahma-test-<uuid>` (resolved, so policies hold resolved paths).
    static func homeDir() throws -> URL {
        let url = realHome.appending(path: ".brahma-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvedForSandbox
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func mkdir(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The real baseline for this user, with `protected` extended (and the engine homes given).
    static func baseline(protected extra: [URL] = [], engineHomes: [URL] = []) -> SandboxBaseline {
        var b = SandboxBaseline.current(paths: BrahmaPaths(home: realHome.appending(path: "Library/Application Support/Brahma"),
                                                           workspaces: realHome.appending(path: "Brahma")),
                                        otherWorkspaces: [], backupTargets: [])
        b.protected += extra
        b.engineHomes += engineHomes
        return b
    }

    static func runner(_ baseline: SandboxBaseline = baseline(), pool: EgressProxyPool = EgressProxyPool()) -> SeatbeltRunner {
        SeatbeltRunner(baseline: { baseline }, proxies: pool)
    }

    /// Runs `command` in `cwd` (the first writable entry by default) and returns the outcome and the whole output.
    static func run(_ command: String, _ policy: SandboxPolicy, cwd: URL? = nil, runner: SeatbeltRunner? = nil,
                    timeout: Duration = .seconds(60), env: [String: String] = SeatbeltRunnerTests.env) async throws -> (CheckOutcome, String) {
        let out = try tempDir().appending(path: "out.log")
        let outcome = await (runner ?? Self.runner()).run(command: command, cwd: cwd ?? policy.writable[0], environment: env,
                                                          timeout: timeout, outputURL: out, policy: policy)
        return (outcome, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
    }

    static func policy(writable: [URL], readable: [URL] = [], network: SandboxNetwork = .none, toolchain: Bool = false) -> SandboxPolicy {
        SandboxPolicy(writable: writable, readable: readable, network: network, toolchain: toolchain)
    }

    // MARK: Files

    @Test func writesOnlyInsideWritable() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let p = Self.policy(writable: [w], readable: [h])
        let escape = "brahma-escape-\(UUID().uuidString)"

        let (ok, _) = try await Self.run("touch ok && mkdir -p sub/deeper && echo hi > sub/deeper/f", p)
        #expect(ok.exitCode == 0, "\(ok.tail)")
        #expect(FileManager.default.fileExists(atPath: w.appending(path: "sub/deeper/f").path))
        for target in [h.appending(path: escape).path, "/private/tmp/\(escape)", Self.realHome.appending(path: escape).path,
                       FileManager.default.temporaryDirectory.resolvedForSandbox.appending(path: escape).path] {
            let (bad, _) = try await Self.run("touch '\(target)'", p)
            #expect(bad.exitCode != 0, "\(target) was writable")
            #expect(!FileManager.default.fileExists(atPath: target)); try? FileManager.default.removeItem(atPath: target)
        }
        // TMPDIR is inside the first writable entry while the command runs, and gone afterwards.
        let (tmp, text) = try await Self.run("echo t > \"$TMPDIR/t\" && echo \"[$TMPDIR]\"", p)
        #expect(tmp.exitCode == 0, "\(tmp.tail)")
        #expect(text.contains("[\(w.path)/.brahma-tmp]"))
        #expect(!FileManager.default.fileExists(atPath: w.appending(path: ".brahma-tmp").path), "TMPDIR is removed after the run")
        // The protected-path deny wins even for a path the command could otherwise write: a policy that would make one
        // writable is refused outright.
        let (refused, _) = try await Self.run("true", Self.policy(writable: [Self.realHome.appending(path: ".ssh/brahma")]))
        #expect(refused.exitCode == nil); #expect(refused.tail.contains("protected"), "\(refused.tail)")
        // So is a writable entry that is the home or contains it, and one that is not resolved (a link on the way).
        let (wide, _) = try await Self.run("true", Self.policy(writable: [Self.realHome]), cwd: w)
        #expect(wide.exitCode == nil)
        var withWorkspace = Self.baseline()
        withWorkspace.companyWorkspaces = [w.appending(path: "sub")]
        let (containing, _) = try await Self.run("true", p, runner: Self.runner(withWorkspace))
        #expect(containing.exitCode == nil, "a writable entry holding a company workspace was accepted")
        try FileManager.default.createSymbolicLink(at: h.appending(path: "lw"), withDestinationURL: w)
        let (linked, _) = try await Self.run("true", Self.policy(writable: [h.appending(path: "lw")]), cwd: w)
        #expect(linked.exitCode == nil); #expect(linked.tail.contains("link"), "\(linked.tail)")
    }

    @Test func readsOfProtectedDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        try Self.file(h.appending(path: "secret/x"), "top-secret")
        try Self.file(h.appending(path: "other/y"), "fine")
        // The owner's real credentials are protected (and the home is unreadable anyway).
        let (ssh, _) = try await Self.run("ls '\(Self.realHome.path)/.ssh'", Self.policy(writable: [w], readable: [h]))
        #expect(ssh.exitCode != 0)
        // A policy entry overlapping a protected path (inside it, or containing it) is refused before anything runs.
        let r = Self.runner(Self.baseline(protected: [h.appending(path: "secret")]))
        for readable in [h.appending(path: "secret/inner"), h] {
            let (overlap, _) = try await Self.run("true", Self.policy(writable: [w], readable: [readable]), runner: r)
            #expect(overlap.exitCode == nil); #expect(overlap.tail.contains("protected"), "\(overlap.tail)")
        }
        // Another company's workspace inside a readable entry: denied there although its parent is readable. (Seatbelt
        // checks a `file-read-data` rule before a `file-read*` one: the deny must name `file-read-data` to win.)
        var b = Self.baseline()
        b.companyWorkspaces = [h.appending(path: "secret"), h]
        let nested = Self.runner(b)
        let p = Self.policy(writable: [w], readable: [h])
        let (denied, text) = try await Self.run("cat ../secret/x", p, runner: nested)
        #expect(denied.exitCode != 0); #expect(!text.contains("top-secret"))
        let (listed, _) = try await Self.run("ls ../secret", p, runner: nested)
        #expect(listed.exitCode != 0)
        let (fine, fineText) = try await Self.run("cat ../other/y", p, runner: nested)
        #expect(fine.exitCode == 0, "\(fineText)"); #expect(fineText.contains("fine"))
        // The same rule written the brief's way (`file-read*` only) would have let `cat` through: shown on a raw profile.
        let raw = """
        (version 1)(allow default)(deny file-read-data (subpath "\(Self.realHome.path)"))
        (allow file-read-data (subpath "\(h.path)"))(deny file-read* (subpath "\(h.path)/secret"))
        """
        let leak = try Self.outside(SeatbeltRunner.sandboxExec, ["-p", raw, "/bin/cat", h.appending(path: "secret/x").path])
        #expect(leak.output.contains("top-secret"), "Seatbelt's precedence changed; the explicit file-read-data deny is still right")
    }

    @Test func homeIsUnreadableExceptReadable() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        try Self.file(h.appending(path: "r/f"), "readable-text")
        try Self.file(h.appending(path: "nr/f"), "hidden-text")
        let p = Self.policy(writable: [w], readable: [h.appending(path: "r")])
        let (ok, okText) = try await Self.run("cat ../r/f", p)
        #expect(ok.exitCode == 0); #expect(okText.contains("readable-text"))
        let (no, noText) = try await Self.run("cat ../nr/f", p)
        #expect(no.exitCode != 0); #expect(!noText.contains("hidden-text"))
        let (home, _) = try await Self.run("ls '\(Self.realHome.path)'", p)
        #expect(home.exitCode != 0, "the home directory itself cannot be listed")
        // What the command writes it can read back.
        let (back, backText) = try await Self.run("echo mine > m && cat m", p)
        #expect(back.exitCode == 0); #expect(backText.contains("mine"))
    }

    @Test func volumesDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let (outcome, _) = try await Self.run("ls /Volumes", Self.policy(writable: [w]))
        #expect(outcome.exitCode != 0)
    }

    @Test func symlinkToProtectedIsDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        try Self.file(h.appending(path: "secret/x"), "top-secret")
        try Self.file(h.appending(path: "nr/f"), "hidden-text")
        _ = try Self.mkdir(h.appending(path: "outside"))
        let fm = FileManager.default
        try fm.createSymbolicLink(at: w.appending(path: "to-secret"), withDestinationURL: h.appending(path: "secret/x"))
        try fm.createSymbolicLink(at: w.appending(path: "to-home"), withDestinationURL: h.appending(path: "nr/f"))
        try fm.createSymbolicLink(at: w.appending(path: "to-outside"), withDestinationURL: h.appending(path: "outside/new"))
        let r = Self.runner(Self.baseline(protected: [h.appending(path: "secret")]))
        let p = Self.policy(writable: [w], readable: [h])
        let (a, aText) = try await Self.run("cat to-secret", p, runner: r)
        #expect(a.exitCode != 0); #expect(!aText.contains("top-secret"))
        let (b, bText) = try await Self.run("cat to-home", Self.policy(writable: [w]), runner: r)
        #expect(b.exitCode != 0); #expect(!bText.contains("hidden-text"))
        // Writing through a link lands on its target, which is outside the writable entry.
        let (c, _) = try await Self.run("echo x > to-outside", p, runner: r)
        #expect(c.exitCode != 0); #expect(!fm.fileExists(atPath: h.appending(path: "outside/new").path))
        // A link the command plants itself is no better.
        let (d, dText) = try await Self.run("ln -s ../secret/x planted && cat planted", p, runner: r)
        #expect(d.exitCode != 0); #expect(!dText.contains("top-secret"))
    }

    // MARK: Escapes

    @Test func launchctlSubmitDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        defer { _ = try? Self.outside("/bin/launchctl", ["remove", "dev.brahma.test"]) }
        let (outcome, text) = try await Self.run("launchctl submit -l dev.brahma.test -- /usr/bin/true", Self.policy(writable: [w]))
        #expect(outcome.exitCode != 0); #expect(text.contains("not permitted"), "\(text)")
        let listed = try Self.outside("/bin/launchctl", ["list", "dev.brahma.test"])
        #expect(listed.status != 0, "the job exists: \(listed.output)")
    }

    @Test func openDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let (outcome, text) = try await Self.run("open -g -a TextEdit", Self.policy(writable: [w]))
        #expect(outcome.exitCode != 0); #expect(text.contains("not permitted"), "\(text)")
    }

    @Test func securityCLIDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let (outcome, text) = try await Self.run("security find-generic-password -s dev.brahma.secrets", Self.policy(writable: [w]))
        #expect(outcome.exitCode != 0); #expect(text.contains("not permitted"), "\(text)")
        // A copy of a denied tool under another name still cannot reach the Security server or the Keychain.
        let (copy, copyText) = try await Self.run("cp /usr/bin/security ./sec && ./sec list-keychains", Self.policy(writable: [w]))
        #expect(copy.exitCode != 0 || !copyText.contains(".keychain"), "\(copyText)")
    }

    /// Uses the "find" pasteboard (not the general one) and puts its previous text back, so the owner's clipboard is never
    /// clobbered.
    @Test func pbpasteDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let saved = try Self.outside("/usr/bin/pbpaste", ["-pboard", "find"]).output
        defer { _ = try? Self.outside("/usr/bin/pbcopy", ["-pboard", "find"], input: saved) }
        let marker = "brahma-pb-\(UUID().uuidString)"
        _ = try Self.outside("/usr/bin/pbcopy", ["-pboard", "find"], input: marker)
        let check = try Self.outside("/usr/bin/pbpaste", ["-pboard", "find"]).output
        try #require(check == marker, "the pasteboard is not usable from this session")
        let (_, text) = try await Self.run("pbpaste -pboard find; pbpaste", Self.policy(writable: [w]))
        #expect(!text.contains(marker))
    }

    @Test func killParentDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let (parent, _) = try await Self.run("kill -0 \(getpid())", Self.policy(writable: [w]))
        #expect(parent.exitCode != 0)
        // An unrelated process outside the sandbox survives a TERM from inside.
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep"); victim.arguments = ["30"]
        try victim.run()
        defer { victim.terminate(); victim.waitUntilExit() }
        let (term, _) = try await Self.run("kill -TERM \(victim.processIdentifier)", Self.policy(writable: [w]))
        #expect(term.exitCode != 0); #expect(victim.isRunning)
        // Its own children it may signal.
        let (own, _) = try await Self.run("sleep 30 & kill $!; wait $!; test $? -ne 0", Self.policy(writable: [w]))
        #expect(own.exitCode == 0)
    }

    /// A preference write goes through cfprefsd, outside the sandbox: it must not reach the owner's preferences.
    @Test func preferencesWriteDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let domain = "dev.brahma.test-\(UUID().uuidString.prefix(8))"
        defer { _ = try? Self.outside("/usr/bin/defaults", ["delete", domain]) }
        let (outcome, _) = try await Self.run("defaults write \(domain) k v", Self.policy(writable: [w], toolchain: true))
        #expect(outcome.exitCode != 0)
        #expect(try Self.outside("/usr/bin/defaults", ["read", domain]).status != 0, "the preference was written")
    }

    // MARK: Network

    @Test func networkNoneBlocksEverything() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let (listener, port) = try Self.listenSocket()
        defer { close(listener) }
        let (local, _) = try await Self.run("nc -z -w 2 127.0.0.1 \(port)", Self.policy(writable: [w]))
        #expect(local.exitCode != 0)
        let (remote, _) = try await Self.run("curl -sS --max-time 5 -o /dev/null https://example.com", Self.policy(writable: [w]))
        #expect(remote.exitCode != 0)
        let (env, text) = try await Self.run("echo \"[${HTTPS_PROXY-}${ALL_PROXY-}]\"", Self.policy(writable: [w]))
        #expect(env.exitCode == 0); #expect(text.contains("[]"))
    }

    @Test func outboundOnlyAllowList() async throws {
        guard Self.online() else { return }   // offline: nothing to show
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let pool = EgressProxyPool()
        defer { Task { await pool.stopAll() } }
        let r = Self.runner(pool: pool)
        let p = Self.policy(writable: [w], network: .outbound(allow: ["example.com"]))
        let (ok, okText) = try await Self.run("curl -sS --max-time 30 -o /dev/null -w 'code=%{http_code}' https://example.com/", p, runner: r)
        #expect(ok.exitCode == 0, "\(okText)"); #expect(okText.contains("code=200"))
        let (other, _) = try await Self.run("curl -sS --max-time 20 -o /dev/null https://www.wikipedia.org/", p, runner: r)
        #expect(other.exitCode != 0)
        let (direct, _) = try await Self.run("curl -sS --noproxy '*' --max-time 10 -o /dev/null https://example.com/", p, runner: r)
        #expect(direct.exitCode != 0, "a direct connection bypassed the proxy")
        let (env, envText) = try await Self.run("echo \"[$HTTPS_PROXY][$http_proxy][$ALL_PROXY][$NO_PROXY]\"", p, runner: r)
        #expect(env.exitCode == 0)
        let proxy = try await pool.proxy(for: ["example.com"])
        let url = "http://127.0.0.1:\(proxy.port)"
        #expect(envText.contains("[\(url)][\(url)][\(url)][localhost,127.0.0.1]"), "\(envText)")
        #expect(proxy.deniedHosts.contains("www.wikipedia.org"))
    }

    @Test func loopbackListenOnlyOwnPorts() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let port = try Self.freePortPair()
        let p = Self.policy(writable: [w], network: .loopbackListen(allow: [], ports: [port]))
        let command = """
        nc -l 127.0.0.1 \(port) > got.txt & S=$!; sleep 1; echo hello | nc -w 3 127.0.0.1 \(port); wait $S; cat got.txt
        nc -l 127.0.0.1 \(port + 1) & N=$!; sleep 1; if kill -0 $N 2>/dev/null; then kill $N; echo BOUND-OTHER; fi
        """
        let (outcome, text) = try await Self.run(command, p, timeout: .seconds(30))
        #expect(outcome.exitCode == 0, "\(text)")
        #expect(text.contains("hello"), "own port not usable: \(text)")
        #expect(!text.contains("BOUND-OTHER"), "bound a port it was not given")
    }

    // MARK: Toolchain

    @Test(.timeLimit(.minutes(6)), .enabled(if: Toolchain.xcodeAvailable))
    func swiftBuildAndXcodebuildUnderToolchain() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let pkg = try Self.mkdir(h.appending(path: "pkg"))
        let cache = try Self.mkdir(h.appending(path: ".brahma/cache/shared"))
        try Self.file(pkg.appending(path: "Package.swift"), """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Hello", platforms: [.macOS(.v13)], targets: [.executableTarget(name: "Hello")])
        """)
        try Self.file(pkg.appending(path: "Sources/Hello/main.swift"), "print(\"hello from the sandbox\")\n")
        let swiftpmCache = Self.realHome.appending(path: "Library/Caches/org.swift.swiftpm")
        let before = try? FileManager.default.attributesOfItem(atPath: swiftpmCache.path)[.modificationDate] as? Date
        var env = Self.env
        env["DEVELOPER_DIR"] = Toolchain.developerDir
        let p = Self.policy(writable: [pkg, cache], readable: [h], toolchain: true)
        // SwiftPM sandboxes its manifest with sandbox-exec, which cannot nest inside Seatbelt: inside Brahma's sandbox SwiftPM
        // runs with its own turned off (`--disable-sandbox`; xcodebuild: `-IDEPackageSupportDisableManifestSandbox YES`).
        let (build, buildText) = try await Self.run("swift build --disable-sandbox --cache-path .build/cache > build.log 2>&1; s=$?; tail -40 build.log; exit $s",
                                                     p, timeout: .seconds(150), env: env)
        #expect(build.exitCode == 0, "swift build failed under the toolchain policy:\n\(buildText.suffix(3000))")
        let (xcode, xcodeText) = try await Self.run(
            "xcodebuild -scheme Hello -destination 'platform=macOS' -derivedDataPath .build/dd -IDEPackageSupportDisableManifestSandbox YES build > xc.log 2>&1; s=$?; tail -40 xc.log; exit $s",
            p, timeout: .seconds(150), env: env)
        #expect(xcode.exitCode == 0 && xcodeText.contains("BUILD SUCCEEDED"), "xcodebuild failed under the toolchain policy:\n\(xcodeText.suffix(3000))")
        let after = try? FileManager.default.attributesOfItem(atPath: swiftpmCache.path)[.modificationDate] as? Date
        #expect(before == after, "the owner's SwiftPM cache was written")
        // Without the toolchain allowances the build cannot run.
        try? FileManager.default.removeItem(at: pkg.appending(path: ".build"))
        let (bare, _) = try await Self.run("swift build --disable-sandbox --cache-path .build/cache", Self.policy(writable: [pkg, cache], readable: [h]),
                                           timeout: .seconds(120), env: env)
        #expect(bare.exitCode != 0)
    }

    /// A tiny AppKit app (built here, outside the sandbox) runs under the toolchain policy: it reaches the window server,
    /// finishes launching and quits. Nothing is left running: the group is killed when the run ends.
    @Test(.timeLimit(.minutes(4)), .enabled(if: Toolchain.xcodeAvailable))
    func guiAppLaunchesUnderToolchain() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let cache = try Self.mkdir(h.appending(path: ".brahma/cache/shared"))
        let source = w.appending(path: "app.swift")
        try Self.file(source, """
        import AppKit
        final class Delegate: NSObject, NSApplicationDelegate {
            var window: NSWindow?
            func applicationDidFinishLaunching(_ note: Notification) {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless], backing: .buffered, defer: false)
                w.orderFrontRegardless()
                window = w
                print("launched windows=\\(NSApp.windows.count)")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate()
        app.delegate = delegate
        app.run()
        """)
        let binary = w.appending(path: "BrahmaGUITest")
        let built = try Self.outside("/usr/bin/xcrun", ["swiftc", "-O", source.path, "-o", binary.path],
                                     environment: ["DEVELOPER_DIR": Toolchain.developerDir, "PATH": "/usr/bin:/bin"])
        try #require(built.status == 0, "could not build the test app: \(built.output)")
        var env = Self.env
        env["DEVELOPER_DIR"] = Toolchain.developerDir
        let p = Self.policy(writable: [w, cache], readable: [h], toolchain: true)
        let (outcome, text) = try await Self.run("./BrahmaGUITest", p, timeout: .seconds(60), env: env)
        #expect(outcome.exitCode == 0, "\(text.suffix(3000))")
        #expect(text.contains("launched windows="), "\(text.suffix(3000))")
        #expect(try Self.outside("/usr/bin/pgrep", ["-f", binary.path]).status != 0, "the app is still running")
    }

    // MARK: Processes

    @Test func timeoutKillsGroup() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let r = SeatbeltRunner(baseline: { Self.baseline() }, proxies: EgressProxyPool(), termGrace: 1)
        let started = AwakeTime.now
        let (outcome, _) = try await Self.run("trap '' TERM; (trap '' TERM; sleep 60) & echo $! > pid; sleep 60 & echo $! >> pid; wait",
                                              Self.policy(writable: [w]), runner: r, timeout: .seconds(2))
        #expect(outcome.timedOut); #expect(outcome.exitCode == nil)
        #expect(AwakeTime.now - started < .seconds(30))
        let pids = try String(contentsOf: w.appending(path: "pid"), encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.count == 2)
        for pid in pids { #expect(await Self.gone(pid), "\(pid) survived the timeout") }
        // Leftover background processes are killed when the command ends by itself, too.
        let (done, _) = try await Self.run("sleep 300 & echo $! > pid2; echo done", Self.policy(writable: [w]))
        #expect(done.exitCode == 0)
        let pid2 = try #require(Int32(try String(contentsOf: w.appending(path: "pid2"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await Self.gone(pid2))
    }

    @Test func outputIsCappedAndExitCodesKept() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let (big, text) = try await Self.run("head -c 3000000 /dev/zero | tr '\\0' 'a'; echo; echo THE-LAST-LINE", Self.policy(writable: [w]))
        #expect(big.exitCode == 0)
        #expect(text.utf8.count <= ProcessCheckRunner.outputCap + 64); #expect(text.contains(ProcessCheckRunner.truncationMarker))
        #expect(big.tail.contains("THE-LAST-LINE"))
        let (three, _) = try await Self.run("exit 3", Self.policy(writable: [w]))
        #expect(three.exitCode == 3)
        let (stdin, _) = try await Self.run("cat; echo after", Self.policy(writable: [w]))
        #expect(stdin.exitCode == 0); #expect(stdin.tail.contains("after"))
    }

    /// Many short runs at once: every output file holds its own run's text only (no descriptor is read or written after it
    /// was closed and its number reused).
    @Test func concurrentRunsKeepTheirOutput() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let results = await withTaskGroup(of: (Int, String).self) { group in
            for n in 0..<12 {
                group.addTask {
                    let text = (try? await Self.run("echo token-\(n); sleep 0.\(n % 3)", Self.policy(writable: [w])).1) ?? ""
                    return (n, text)
                }
            }
            var all: [(Int, String)] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 12)
        for (n, text) in results {
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "token-\(n)", "run \(n) got \(text)")
        }
    }

    /// Carry-over: a signal goes only to a process group the runner still owns and has not reaped.
    @Test func noSignalToReapedGroup() async throws {
        let log = SignalLog()
        let child = try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "exit 3"],
                                                environment: Self.env, workingDirectory: URL(fileURLWithPath: "/"),
                                                output: -1, observer: log.record)
        while !child.hasExited() { try await Task.sleep(for: .milliseconds(5)) }
        let status = child.finish()
        #expect((status >> 8) & 0xff == 3)
        // The one signal: the group sweep while the exited leader still held its pid (unreaped), then the reap.
        #expect(log.events == ["killpg \(child.pid) 9", "reaped \(child.pid)"])
        // After the reap nothing is ever sent, whatever asks.
        #expect(child.signalGroup(SIGTERM) == false)
        #expect(child.signalGroup(SIGKILL) == false)
        #expect(child.finish() == status)
        #expect(log.events.count == 2)

        // The same for a spawned sandboxed process that ended by itself.
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let r = Self.runner()
        let process = try r.spawn(command: "exit 0", cwd: w, environment: Self.env, logURL: try tempDir().appending(path: "log"),
                                  policy: Self.policy(writable: [w]))
        for _ in 0..<500 where process.isAlive() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!process.isAlive()); #expect(process.exitStatus() == 0)
        let seat = try #require(process as? SeatbeltProcess)
        let sent = seat.child.signalCount
        await process.terminate(grace: .seconds(1))
        #expect(seat.child.signalCount == sent, "terminate signalled a reaped group")
    }

    @Test func spawnedProcessTerminatesWithItsGroup() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let log = try tempDir().appending(path: "spawn.log")
        let process = try Self.runner().spawn(command: "sleep 60 & echo $! > child; echo started; wait", cwd: w, environment: Self.env,
                                              logURL: log, policy: Self.policy(writable: [w]))
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: w.appending(path: "child").path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(process.isAlive()); #expect(process.exitStatus() == nil); #expect(process.pid > 0)
        #expect(getpgid(process.pid) == process.pid, "the spawned process leads its own group")
        let childPid = try #require(Int32(try String(contentsOf: w.appending(path: "child"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        await process.terminate(grace: .seconds(2))
        #expect(!process.isAlive()); #expect(process.exitStatus() != nil)
        #expect(await Self.gone(childPid))
        #expect(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("started"))
    }

    // MARK: Profile text

    @Test func profileRuleOrderAndEscaping() throws {
        let b = SandboxBaseline(userHome: URL(fileURLWithPath: "/Users/o"), protected: [URL(fileURLWithPath: "/Users/o/.ssh")],
                                darwinUserTemp: URL(fileURLWithPath: "/private/var/folders/x+y/T"),
                                darwinUserCache: URL(fileURLWithPath: "/private/var/folders/x+y/C"),
                                engineHomes: [URL(fileURLWithPath: "/srv/brahma home")])
        let p = SandboxPolicy(writable: [URL(fileURLWithPath: "/srv/brahma home/run/checkouts/r1"), URL(fileURLWithPath: "/w/.brahma/cache/shared")],
                              readable: [URL(fileURLWithPath: "/w")], network: .loopbackListen(allow: [], ports: [4000, 4001]), toolchain: true)
        let text = SeatbeltProfile.render(policy: p, baseline: b, proxyPort: 5555)
        let order = ["(version 1)", "(allow default)", "(deny file-read-data (subpath \"/Users/o\") (subpath \"/Volumes\")",
                     "(allow file-read-data (subpath \"/w\")", "(deny file-read* file-read-data (subpath \"/Users/o/.ssh\")",
                     "(deny file-write* (require-not (require-any (subpath \"/srv/brahma home/run/checkouts/r1\")",
                     "(deny signal (target others))", "(deny mach-lookup (global-name \"com.apple.SecurityServer\")",
                     "(deny process-exec (literal \"/usr/bin/osascript\")", "(allow mach-lookup (global-name \"com.apple.windowserver.active\")",
                     "(deny network*)", "(allow network-outbound (remote ip \"localhost:5555\"))",
                     "(allow network-bind network-inbound (local ip \"localhost:4000\") (local ip \"localhost:4001\"))",
                     "(allow network-outbound (remote ip \"localhost:4000\") (remote ip \"localhost:4001\"))"]
        var at = text.startIndex
        for piece in order {
            let found = try #require(text.range(of: piece, range: at..<text.endIndex), "missing or out of order: \(piece)\n\(text)")
            at = found.upperBound
        }
        #expect(text.contains("(subpath \"/srv/brahma home\")"), "the engine home is denied for reading")
        #expect(text.contains("(regex #\"^/private/var/folders/x\\+y/T/xcrun_db\")"))
        #expect(text.contains("(regex #\"^/private/var/folders/x\\+y/C/org\\.llvm\\.clang\")"))
        #expect(text.contains("(subpath \"/private/var/folders/x+y/C/clang\")"))
        for literal in ["/dev/null", "/dev/tty", "/dev/dtracehelper"] { #expect(text.contains("(literal \"\(literal)\")")) }
        #expect(text.contains("(regex #\"^/dev/fd/\")"))
        #expect(!text.contains("Library/Caches/org.swift.swiftpm\") (literal"), "nothing under ~/Library is writable")
        // .none has no network allowance at all; .outbound only the proxy.
        let none = SeatbeltProfile.render(policy: SandboxPolicy(writable: p.writable, readable: [], network: .none, toolchain: false),
                                          baseline: b, proxyPort: nil)
        #expect(none.contains("(deny network*)")); #expect(!none.contains("network-outbound")); #expect(!none.contains("windowserver"))
        let out = SeatbeltProfile.render(policy: SandboxPolicy(writable: p.writable, readable: [], network: .outbound(allow: ["a.com"]),
                                                               toolchain: false), baseline: b, proxyPort: 7)
        #expect(out.contains("(allow network-outbound (remote ip \"localhost:7\"))")); #expect(!out.contains("network-bind"))
        // Escaping: a string can never close early.
        #expect(SeatbeltProfile.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
        #expect(SeatbeltProfile.regexEscape("/a.b+c(d)[e]^$|?*{}") == "/a\\.b\\+c\\(d\\)\\[e\\]\\^\\$\\|\\?\\*\\{\\}")
    }

    @Test func unsafePolicyPathsAreRefused() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        for bad in ["\(w.path)/a\"b", "\(w.path)/a\\b", "\(w.path)/a\nb", "\(w.path)/a'b", "\(w.path)/a\tb", "\(w.path)/../w"] {
            let (outcome, _) = try await Self.run("true", Self.policy(writable: [w], readable: [URL(fileURLWithPath: bad)]), cwd: w)
            #expect(outcome.exitCode == nil, "\(bad.debugDescription) was accepted")
        }
        let (relative, _) = try await Self.run("true", Self.policy(writable: [w], readable: [try #require(URL(string: "relative/path"))]), cwd: w)
        #expect(relative.exitCode == nil)
        let (domain, _) = try await Self.run("true", Self.policy(writable: [w], network: .outbound(allow: ["*.com"])))
        #expect(domain.exitCode == nil)
        let (anthropic, _) = try await Self.run("true", Self.policy(writable: [w], network: .outbound(allow: ["api.anthropic.com"])))
        #expect(anthropic.exitCode == nil)
        let (nothing, _) = try await Self.run("true", Self.policy(writable: []), cwd: w)
        #expect(nothing.exitCode == nil)
    }

    // MARK: Carry-over: the data home

    /// A check's checkout under the data home is writable; the rest of the data home is neither readable nor writable.
    @Test func checkoutWritableRestOfDataHomeDenied() async throws {
        let ws = try Self.homeDir(); defer { Self.remove(ws) }
        let home = try tempDir().resolvedForSandbox.appending(path: "home")   // outside the user's home, like a custom BRAHMA_HOME
        let checkout = try Self.mkdir(home.appending(path: "run/checkouts/r1"))
        try Self.file(home.appending(path: "brahma.sqlite"), "the-database")
        try Self.file(home.appending(path: "run/checkouts/r2/f"), "other-run")
        try Self.file(home.appending(path: "companies/c1/check-output/r0.log"), "old-log")
        let cache = try Self.mkdir(ws.appending(path: ".brahma/cache/shared"))
        let r = Self.runner(Self.baseline(engineHomes: [home]))
        let p = Self.policy(writable: [checkout, cache], readable: [ws])
        let (ok, okText) = try await Self.run("touch ok && echo c > '\(cache.path)/c' && cat ok c 2>/dev/null; cat '\(cache.path)/c'", p, runner: r)
        #expect(ok.exitCode == 0, "\(okText)")
        #expect(FileManager.default.fileExists(atPath: checkout.appending(path: "ok").path))
        for read in ["brahma.sqlite", "run/checkouts/r2/f", "companies/c1/check-output/r0.log"] {
            let (outcome, text) = try await Self.run("cat '\(home.appending(path: read).path)'", p, runner: r)
            #expect(outcome.exitCode != 0, "\(read) was readable"); #expect(!text.contains("the-database") && !text.contains("other-run"))
        }
        for write in ["new", "run/checkouts/r2/x", "run/checkouts/r3", "brahma.sqlite"] {
            let (outcome, _) = try await Self.run("echo x >> '\(home.appending(path: write).path)'", p, runner: r)
            #expect(outcome.exitCode != 0, "\(write) was writable")
        }
        #expect(try String(contentsOf: home.appending(path: "brahma.sqlite"), encoding: .utf8) == "the-database")
        let (list, _) = try await Self.run("ls '\(home.appending(path: "run/checkouts").path)'", p, runner: r)
        #expect(list.exitCode != 0, "other runs' checkouts can be listed")
    }

    // MARK: Helpers

    final class SignalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.withLock { _events } }
        var record: ProcessGroupChild.Observer {
            { [self] event in lock.withLock { _events.append(event.description) } }
        }
    }

    /// Runs a tool outside the sandbox (the test process's own rights).
    @discardableResult
    static func outside(_ tool: String, _ arguments: [String], input: String? = nil,
                        environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        try p.run()
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func gone(_ pid: Int32) async -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// A listening loopback socket and its port.
    static func listenSocket() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    /// A port `p` with `p` and `p + 1` both free just now.
    static func freePortPair() throws -> UInt16 {
        for _ in 0..<50 {
            let (fd, p) = try listenSocket()
            close(fd)
            guard p < 65000 else { continue }
            let probe = socket(AF_INET, Int32(SOCK_STREAM), 0)
            defer { close(probe) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET); addr.sin_port = (p + 1).bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok == 0 { return p }
        }
        throw POSIXError(.EADDRINUSE)
    }

    /// True when example.com:443 answers within a few seconds.
    static func online() -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = Int32(SOCK_STREAM)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("example.com", "443", &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(res) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0
    }
}
