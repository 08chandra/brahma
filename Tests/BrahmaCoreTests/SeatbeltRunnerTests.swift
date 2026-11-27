import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore
@testable import BrahmaSafety

/// The Seatbelt backend, run for real: only where `/usr/bin/sandbox-exec` exists. Every test works in `~/.brahma-test-<pid>/<n>`
/// (removed when the test ends), under the owner's real home, so the home denial is the real one.
@Suite(.scratch, .serialized, .enabled(if: Toolchain.seatbeltAvailable, "no /usr/bin/sandbox-exec"))
struct SeatbeltRunnerTests {
    static let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]

    /// The owner's real home, resolved.
    static var realHome: URL { FileManager.default.homeDirectoryForCurrentUser.resolvedForSandbox }  // raw-temp-api: read-only, the home the policy denies

    /// `~/.brahma-test-<pid>/<n>` (resolved, so policies hold resolved paths), removed with the test case.
    static func homeDir() throws -> URL {
        try Scratch.homeDir().resolvedForSandbox
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
                       FileManager.default.temporaryDirectory.resolvedForSandbox.appending(path: escape).path] {  // raw-temp-api: an escape the sandbox must refuse
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

    /// Fix round 5 probe (Task 3 canary obligation b): a hard link would give an unreadable file a readable name inside the
    /// writable entry, and a clone (`cp -c`, `clonefile`) a single-link copy that passes the engine's `copyProblem`. A hard
    /// link is denied for every source outside the writable entries (a readable one too: copying is for `cp`); a clone is
    /// denied for every source the command may not read (a protected path, the unreadable home) and allowed from a readable
    /// entry, where it is no worse than `cp` (fix round 6, NB5). Inside a writable entry both work.
    @Test func hardLinksAndClonesFromOutsideTheWritableAreDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let fm = FileManager.default
        let w = try Self.mkdir(h.appending(path: "w"))
        try Self.file(h.appending(path: "secret/x"), "top-secret")
        try Self.file(h.appending(path: "nr/f"), "hidden-text")
        try Self.file(h.appending(path: "pub/y"), "public-text")
        let r = Self.runner(Self.baseline(protected: [h.appending(path: "secret")]))
        let p = Self.policy(writable: [w], readable: [h.appending(path: "pub")])
        for (source, label) in [("../secret/x", "protected"), ("../nr/f", "home"), ("../pub/y", "readable")] {
            let (a, aText) = try await Self.run("ln \(source) l-\(label) && cat l-\(label)", p, runner: r)
            #expect(a.exitCode != 0, "ln from \(label): \(aText)")
            #expect(!aText.contains("-text") && !aText.contains("top-secret"), "ln from \(label): \(aText)")
            #expect(!fm.fileExists(atPath: w.appending(path: "l-\(label)").path), "a hard link from \(label) was made")
            let (b, bText) = try await Self.run("cp -c \(source) c-\(label) && cat c-\(label)", p, runner: r)
            if label == "readable" {
                #expect(b.exitCode == 0, "clone from \(label): \(bText)"); #expect(bText.contains("public-text"), "\(bText)")
            } else {
                #expect(b.exitCode != 0, "clone from \(label): \(bText)")
                #expect(!bText.contains("-text") && !bText.contains("top-secret"), "clone from \(label): \(bText)")
                #expect(!fm.fileExists(atPath: w.appending(path: "c-\(label)").path), "a clone from \(label) was made")
            }
        }
        let (ok, okText) = try await Self.run("echo in > a && ln a b && cp -c a c && cp ../pub/y d && cat b c d", p, runner: r)
        #expect(ok.exitCode == 0, "\(okText)")
        #expect(okText.contains("in\nin\npublic-text"), "\(okText)")
    }

    /// `clonefile(2)` from inside the sandbox, through Perl's `syscall` (`SYS_clonefileat`, 462; `AT_FDCWD` is -2): one line
    /// per `source=destination` argument, `ok` or `errno <n>`. `cp -c -R` and `ditto --clone` walk file by file; only the
    /// system call clones a whole directory in one step.
    static let clonePerl = #"for (@ARGV) { my ($s, $d) = split /=/, $_; $! = 0; my $r = syscall(462, -2, $s, -2, $d, 0); print "$s: ", ($r == 0 ? "ok" : "errno " . ($! + 0)), "\n" }"#

    /// Fix round 7 (S13 + NB5-regression), with the real `sandbox-exec`: another company's workspace nested inside a readable
    /// entry cannot be cloned out file by file, nor by cloning the readable directory around it (Seatbelt checks only a
    /// directory clone's top, so a directory clone is allowed only inside a writable entry); a readable file still clones and a
    /// directory inside the writable entry still clones.
    @Test func clonefileOfNestedDeniedSubtreesIsRefused() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let fm = FileManager.default
        let w = try Self.mkdir(h.appending(path: "w"))
        let r = h.appending(path: "r")
        try Self.file(r.appending(path: "other/o"), "OTHER-COMPANY-TEXT")
        try Self.file(r.appending(path: "pub/p"), "public-text")
        try Self.file(w.appending(path: "in/x/f"), "inner-text")
        try Self.file(w.appending(path: "clone.pl"), Self.clonePerl)
        var b = Self.baseline()
        b.companyWorkspaces = [r.appending(path: "other")]
        let p = Self.policy(writable: [w], readable: [r])
        let pairs = ["\(r.path)/other/o=c-other", "\(r.path)/other=c-otherdir", "\(r.path)=c-rdir", "\(r.path)/pub=c-pubdir",
                     "\(r.path)/pub/p=c-pub", "\(w.path)/in=c-in"]
        let (outcome, text) = try await Self.run("/usr/bin/perl clone.pl " + pairs.map { "'\($0)'" }.joined(separator: " "), p, runner: Self.runner(b))
        #expect(outcome.exitCode == 0, "\(text)")
        for refused in ["\(r.path)/other/o", "\(r.path)/other", "\(r.path)", "\(r.path)/pub"] {
            #expect(text.contains("\(refused): errno 1\n"), "clonefile(\(refused)) was not refused: \(text)")
        }
        for name in ["c-other", "c-otherdir", "c-rdir", "c-pubdir"] {
            #expect(!fm.fileExists(atPath: w.appending(path: name).path), "\(name) was cloned")
        }
        #expect(text.contains("\(r.path)/pub/p: ok\n"), "\(text)"); #expect(text.contains("\(w.path)/in: ok\n"), "\(text)")
        #expect((try? String(contentsOf: w.appending(path: "c-pub"), encoding: .utf8)) == "public-text")
        #expect((try? String(contentsOf: w.appending(path: "c-in/x/f"), encoding: .utf8)) == "inner-text")
    }

    /// Fix round 7 (S13): a protected path nested inside a readable root. `validate` refuses such a policy, so the rendered
    /// profile is run with `sandbox-exec` directly: the clone of the protected file is refused, and stays refused with the
    /// protected read deny taken out (the explicit `file-clone` deny alone holds), while a normal readable file still clones.
    @Test func clonefileOfAProtectedFileUnderAReadableRootIsRefused() throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let r = h.appending(path: "r")
        try Self.file(r.appending(path: "prot/s"), "TOP-SECRET")
        try Self.file(r.appending(path: "pub/p"), "public-text")
        let script = w.appending(path: "clone.pl")
        try Self.file(script, Self.clonePerl)
        let profile = SeatbeltProfile.render(policy: Self.policy(writable: [w], readable: [r]),
                                             baseline: Self.baseline(protected: [r.appending(path: "prot")]), proxyPort: nil)
        let cloneDeny = profile.split(separator: "\n").first { $0.hasPrefix("(deny file-clone (subpath ") }
        #expect(cloneDeny?.contains("(subpath \(SeatbeltProfile.quote(r.appending(path: "prot").path)))") == true, "\(profile)")
        let withoutReadDeny = profile.split(separator: "\n").filter { !$0.hasPrefix("(deny file-read* file-read-data") }.joined(separator: "\n")
        for (label, text) in [("full", profile), ("clone deny alone", withoutReadDeny)] {
            for name in ["c-prot", "c-pub"] { try? FileManager.default.removeItem(at: w.appending(path: name)) }
            let (status, out) = try Self.outside("/usr/bin/sandbox-exec", ["-p", text, "/usr/bin/perl", script.path,
                                                                            "\(r.path)/prot/s=\(w.path)/c-prot", "\(r.path)/pub/p=\(w.path)/c-pub"],
                                                 environment: Self.env)
            #expect(status == 0, "\(label): \(out)")
            #expect(out.contains("\(r.path)/prot/s: errno 1\n"), "\(label): the protected file was cloned: \(out)")
            #expect(!FileManager.default.fileExists(atPath: w.appending(path: "c-prot").path), "\(label)")
            #expect(out.contains("\(r.path)/pub/p: ok\n"), "\(label): \(out)")
        }
    }

    /// Fix round 8 nit: the data-home carve-out at run time. A check's own checkout inside the data home clones files and
    /// directories inside itself, and a readable workspace inside the data home (BRAHMA_WORKSPACES under BRAHMA_HOME) still
    /// clones its files (the round-8 minor); a sibling run's checkout, the database and any directory outside the checkout
    /// do not clone.
    @Test func dataHomeCarveOutClonesOnlyTheRunsOwnEntries() async throws {
        let home = try tempDir().resolvedForSandbox.appending(path: "home")   // a custom BRAHMA_HOME outside the user's home
        let fm = FileManager.default
        let ck = try Self.mkdir(home.appending(path: "run/checkouts/r1"))
        try Self.file(ck.appending(path: "a"), "own-text")
        try Self.file(ck.appending(path: "in/x/f"), "own-inner")
        try Self.file(ck.appending(path: "clone.pl"), Self.clonePerl)
        try Self.file(home.appending(path: "run/checkouts/r2/f"), "other-run")
        try Self.file(home.appending(path: "brahma.sqlite"), "the-database")
        let ws = home.appending(path: "workspaces/acme")
        try Self.file(ws.appending(path: "f"), "workspace-text")
        let r = Self.runner(Self.baseline(engineHomes: [home]))
        let p = Self.policy(writable: [ck], readable: [ws])
        let pairs = ["\(ck.path)/a=b", "\(ck.path)/in=in2", "\(ws.path)/f=c-ws", "\(home.path)/run/checkouts/r2/f=c-sib",
                     "\(home.path)/run/checkouts/r2=c-sibdir", "\(home.path)/brahma.sqlite=c-db", "\(ws.path)=c-wsdir"]
        let (outcome, text) = try await Self.run("/usr/bin/perl clone.pl " + pairs.map { "'\($0)'" }.joined(separator: " "), p, runner: r)
        #expect(outcome.exitCode == 0, "\(text)")
        for allowed in ["\(ck.path)/a", "\(ck.path)/in", "\(ws.path)/f"] { #expect(text.contains("\(allowed): ok\n"), "\(allowed): \(text)") }
        for refused in ["\(home.path)/run/checkouts/r2/f", "\(home.path)/run/checkouts/r2", "\(home.path)/brahma.sqlite", ws.path] {
            #expect(text.contains("\(refused): errno 1\n"), "\(refused) was cloned: \(text)")
        }
        #expect((try? String(contentsOf: ck.appending(path: "in2/x/f"), encoding: .utf8)) == "own-inner")
        #expect((try? String(contentsOf: ck.appending(path: "c-ws"), encoding: .utf8)) == "workspace-text")
        for name in ["c-sib", "c-sibdir", "c-db", "c-wsdir"] { #expect(!fm.fileExists(atPath: ck.appending(path: name).path), "\(name)") }
    }

    /// Detaches (forced) every disk image whose file lies under `dir`, from outside the sandbox.
    static func detachImages(under dir: URL) {
        guard let info = try? Self.outside("/usr/bin/hdiutil", ["info"]).output else { return }
        for block in info.components(separatedBy: "================================================") where block.contains(dir.path) {
            if let range = block.range(of: #"/dev/disk[0-9]+"#, options: .regularExpression) {
                _ = try? Self.outside("/usr/bin/hdiutil", ["detach", "-force", String(block[range])])
            }
        }
    }

    /// Whether a disk image under `dir` is attached, or anything is mounted on one of `points` (from outside the sandbox).
    static func imageState(under dir: URL, points: [URL]) throws -> (attached: Bool, mounted: [String]) {
        let info = try Self.outside("/usr/bin/hdiutil", ["info"]).output
        let mounts = try Self.outside("/sbin/mount", []).output.split(separator: "\n").map(String.init)
        return (info.contains(dir.path), mounts.filter { line in points.contains { line.contains(" on \($0.path) (") } })
    }

    /// `mount(2)` (SYS_mount = 167) from inside the sandbox via Perl's `syscall`: one line per `type=dir` argument, `ok` or
    /// `errno <n>`. The string arguments must be lvalue scalars for `syscall` to pass their pointers. `devfs` and `fdesc` are
    /// synthetic filesystems a non-root user can mount over a directory they own with no device and no server (the positive
    /// control below does exactly that), so they reach the real `mount(2)` the profile's `file-mount` deny must stop — the
    /// same syscall every mount helper (mount_smbfs/nfs/webdav/afp, mount_apfs, mount_tmpfs, an FSKit mount) calls in the
    /// mounting process.
    static let mountPerl = #"for (@ARGV) { my ($t, $d) = split /=/, $_; my $tt = "$t"; my $dd = "$d"; $! = 0; my $r = syscall(167, $tt, $dd, 0, 0); print "$d: ", ($r == 0 ? "ok" : "errno " . ($! + 0)), "\n" }"#

    /// The mount points at or under `dir` right now (from outside the sandbox), by parsing `/sbin/mount` ("<dev> on <point> (…").
    static func mountsUnder(_ dir: URL) -> [String] {
        guard let out = try? Self.outside("/sbin/mount", []).output else { return [] }
        var points: [String] = []
        for line in out.split(separator: "\n") {
            guard let on = line.range(of: " on "), let paren = line[on.upperBound...].range(of: " (") else { continue }
            let point = String(line[on.upperBound..<paren.lowerBound])
            if point == dir.path || point.hasPrefix(dir.path + "/") { points.append(point) }
        }
        return points
    }

    /// Force-unmounts anything mounted at or under `dir` (deepest first), from outside the sandbox — test hygiene, so a run
    /// that unexpectedly mounted leaves nothing behind.
    static func unmountAllUnder(_ dir: URL) {
        for point in mountsUnder(dir).sorted(by: { $0.count > $1.count }) { _ = try? Self.outside("/sbin/umount", ["-f", point]) }
    }

    /// Fix round 8 (Critical): DiskArbitration mounts as root outside the sandbox, so `file-mount` alone did not stop
    /// `hdiutil makehybrid` → `attach -nomount` → `diskutil mount -mountPoint <dir>` from laying an agent-built filesystem over
    /// a data-home directory the profile denies. With its lookup denied: the sandboxed chain attaches nothing; a device the
    /// test attaches from outside cannot be mounted from inside over the denied directory or a readable one; a plain
    /// `hdiutil attach` (auto-mount at /Volumes) attaches nothing. The directories are unchanged.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil"), "no hdiutil"))
    func diskArbitrationMountsAreRefused() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        defer { Self.detachImages(under: h) }
        let fm = FileManager.default
        let w = try Self.mkdir(h.appending(path: "w"))
        try Self.file(w.appending(path: "src/planted.txt"), "AGENT-PLANTED")
        let home = h.appending(path: "datahome")
        let db = home.appending(path: "db")
        try Self.file(db.appending(path: "orig"), "engine-private")
        let pub = h.appending(path: "r/pub")
        try Self.file(pub.appending(path: "p"), "public-text")
        let r = Self.runner(Self.baseline(engineHomes: [home]))
        let p = Self.policy(writable: [w], readable: [h.appending(path: "r")])
        let image = w.appending(path: "x.iso.dmg")
        func unchanged() throws {
            #expect(Set(try fm.contentsOfDirectory(atPath: db.path)) == ["orig"])
            #expect(Set(try fm.contentsOfDirectory(atPath: pub.path)) == ["p"])
        }

        // The reviewer's chain, all inside the sandbox.
        let chain = """
        /usr/bin/hdiutil makehybrid -quiet -hfs -o x.iso src || exit 10
        dev=$(/usr/bin/hdiutil attach -nomount x.iso.dmg | /usr/bin/awk '/Apple_HFS/ { print $1 }')
        if [ -z "$dev" ]; then echo NO-DEVICE; exit 3; fi
        /usr/sbin/diskutil mount -mountPoint '\(db.path)' "$dev"
        """
        let (a, aText) = try await Self.run(chain, p, runner: r, timeout: .seconds(120))
        #expect(fm.fileExists(atPath: image.path), "makehybrid did not run: \(aText)")
        #expect(a.exitCode != 0, "\(aText)"); #expect(aText.contains("NO-DEVICE"), "the sandboxed attach made a device: \(aText)")
        var state = try Self.imageState(under: h, points: [db, pub])
        #expect(!state.attached, "the sandboxed attach attached the image: \(aText)"); #expect(state.mounted.isEmpty, "\(state.mounted)")
        try unchanged()

        // A real device (attached from outside): the sandboxed mount step alone, over the denied and the readable directory.
        let attached = try Self.outside("/usr/bin/hdiutil", ["attach", "-nomount", image.path])
        let device = try #require(attached.output.split(separator: "\n").first { $0.contains("Apple_HFS") }?
            .split(separator: " ", omittingEmptySubsequences: true).first.map(String.init), "\(attached.output)")
        for point in [db, pub] {
            let (m, mText) = try await Self.run("/usr/sbin/diskutil mount -mountPoint '\(point.path)' \(device)", p, runner: r, timeout: .seconds(60))
            #expect(m.exitCode != 0, "mounted over \(point.path): \(mText)")
        }
        state = try Self.imageState(under: h, points: [db, pub])
        #expect(state.mounted.isEmpty, "\(state.mounted)")
        try unchanged()
        Self.detachImages(under: h)

        // A plain attach, which would auto-mount at /Volumes.
        let (c, cText) = try await Self.run("/usr/bin/hdiutil attach x.iso.dmg", p, runner: r, timeout: .seconds(60))
        state = try Self.imageState(under: h, points: [URL(fileURLWithPath: "/Volumes/src")])
        // `hdiutil` lists each device it attached (and where it mounted); with DiskArbitration denied it lists none.
        #expect(!cText.contains("/dev/disk") && !state.attached && state.mounted.isEmpty,
                "a plain attach attached the image (exit \(String(describing: c.exitCode))): \(cText) \(state.mounted)")
    }

    /// Fix round 8: the everyday copies and git still work with DiskArbitration denied: from a readable entry `cp -c`,
    /// `cp -cR`, `ditto` and `ditto --clone`; and git (init, commit, clone of a readable repository, worktree) in the
    /// writable entry.
    @Test(.enabled(if: Toolchain.xcodeAvailable))
    func copiesAndGitStillWorkWithDiskArbitrationDenied() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let r = h.appending(path: "r")
        try Self.file(r.appending(path: "pub/p"), "public-text")
        try Self.file(r.appending(path: "pub/sub/q"), "nested-text")
        let repo = r.appending(path: "repo")
        try Self.file(repo.appending(path: "a.txt"), "repo-text")
        let git = Toolchain.developerDir + "/usr/bin/git"
        for args in [["init", "-q", "--initial-branch=main"], ["add", "a.txt"],
                     ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "one"]] {
            let out = try Self.outside(git, ["-C", repo.path] + args)
            #expect(out.status == 0, "\(out.output)")
        }
        var env = Self.env
        env["DEVELOPER_DIR"] = Toolchain.developerDir
        let command = """
        set -e
        cp -c '\(r.path)/pub/p' a; cp -cR '\(r.path)/pub' b; ditto '\(r.path)/pub' c; ditto --clone '\(r.path)/pub' d
        cat a b/sub/q c/p d/sub/q
        G='\(git)'
        "$G" clone -q '\(repo.path)' cl
        cd cl; echo more > b.txt; "$G" add b.txt; "$G" -c user.name=t -c user.email=t@t commit -q -m two
        "$G" worktree add -q ../wt2 -b side; "$G" log --oneline | wc -l
        """
        let (outcome, text) = try await Self.run(command, Self.policy(writable: [w], readable: [r], toolchain: true), env: env)
        #expect(outcome.exitCode == 0, "\(text)")
        #expect(text.contains("public-textnested-textpublic-textnested-text"), "\(text)")
        #expect(FileManager.default.fileExists(atPath: w.appending(path: "wt2/a.txt").path), "\(text)")
    }

    // MARK: Mount escapes (follow-up to the DiskArbitration fix, round 8)

    /// The core of the mount-escape audit. `mount(2)` is the one syscall every mount helper calls in the mounting process,
    /// and on macOS none of them is setuid, so a sandboxed command's only routes to a mount are (a) that client-side
    /// `mount(2)` — which `(deny file-mount …)` must stop — or (b) a root daemon that mounts on its behalf, of which the only
    /// one that does so for an arbitrary target is DiskArbitration, already denied (round 8). `devfs` proves (a) with no
    /// device, no server and no root: the positive control really mounts it over a dir this user owns, then unmounts, so the
    /// in-sandbox refusals below are the sandbox and nothing else. Inside the sandbox `devfs`/`fdesc` are refused over a
    /// denied data-home directory, a readable directory and the writable one; nothing is mounted and the directories are
    /// unchanged. The non-setuid `mount_devfs` helper (same `mount(2)`) is refused too. This is the syscall-level proof for
    /// every client-side route the brief lists: mount_smbfs/nfs/webdav/afp, mount_apfs -s, mount_tmpfs and an FSKit mount.
    @Test func clientSideMountsOverDeniedPathsAreRefused() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        defer { Self.unmountAllUnder(h) }
        let fm = FileManager.default
        let w = try Self.mkdir(h.appending(path: "w"))
        let home = h.appending(path: "datahome")
        let db = home.appending(path: "db")
        try Self.file(db.appending(path: "orig"), "engine-private")
        let pub = h.appending(path: "r/pub")
        try Self.file(pub.appending(path: "p"), "public-text")
        try Self.file(w.appending(path: "mount.pl"), Self.mountPerl)
        let r = Self.runner(Self.baseline(engineHomes: [home]))
        let p = Self.policy(writable: [w], readable: [h.appending(path: "r")])

        // Positive control, outside the sandbox: devfs really does mount over a directory this user owns (so the refusals
        // below are the sandbox, not a missing privilege or a missing server). Unmounted immediately.
        let ctl = try Self.mkdir(h.appending(path: "ctl"))
        let control = try Self.outside("/usr/bin/perl", ["-e", Self.mountPerl, "devfs=\(ctl.path)"])
        #expect(control.output.contains("\(ctl.path): ok"), "devfs is not user-mountable here; the test would prove nothing: \(control.output)")
        #expect(!Self.mountsUnder(ctl).isEmpty, "the control devfs mount did not appear: \(control.output)")
        Self.unmountAllUnder(ctl)

        // Inside the sandbox: devfs and fdesc over the denied, the readable and the writable directories.
        let targets = [db, pub, w]
        let args = targets.flatMap { ["devfs=\($0.path)", "fdesc=\($0.path)"] }
        let (outcome, text) = try await Self.run("/usr/bin/perl mount.pl " + args.map { "'\($0)'" }.joined(separator: " "), p, runner: r)
        #expect(outcome.exitCode == 0, "\(text)")
        for t in targets {
            #expect(text.contains("\(t.path): errno"), "a mount over \(t.path) was not refused: \(text)")
            #expect(!text.contains("\(t.path): ok"), "a mount over \(t.path) succeeded: \(text)")
            #expect(Self.mountsUnder(t).isEmpty, "something is mounted under \(t.path): \(Self.mountsUnder(t))")
        }
        #expect(Set(try fm.contentsOfDirectory(atPath: db.path)) == ["orig"], "the denied data-home dir changed")
        #expect(Set(try fm.contentsOfDirectory(atPath: pub.path)) == ["p"], "the readable dir changed")

        // The mount_devfs helper itself (not setuid; same mount(2)).
        let (helper, helperText) = try await Self.run("/sbin/mount_devfs devfs '\(db.path)'", p, runner: r)
        #expect(helper.exitCode != 0, "mount_devfs succeeded: \(helperText)")
        #expect(Self.mountsUnder(db).isEmpty, "mount_devfs mounted something: \(Self.mountsUnder(db))")
    }

    /// Brief routes 1–2: the network-share mount helpers. None is setuid, so each calls the client-side `mount(2)` shown
    /// refused above (NetFS authentication via NetAuthSysAgent returns to the client; the mount is this syscall). Run for real
    /// at a loopback address with no server: whether they fail to connect or are stopped at the mount, nothing is ever
    /// mounted over the denied data-home directory, which stays unchanged.
    @Test func networkShareMountHelpersPlantNothing() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        defer { Self.unmountAllUnder(h) }
        let fm = FileManager.default
        let w = try Self.mkdir(h.appending(path: "w"))
        let home = h.appending(path: "datahome")
        let db = home.appending(path: "db")
        try Self.file(db.appending(path: "orig"), "engine-private")
        let r = Self.runner(Self.baseline(engineHomes: [home]))
        let p = Self.policy(writable: [w], readable: [h.appending(path: "r")])
        let point = db.path
        let attempts = [
            "/sbin/mount_nfs -o timeo=1,retrycnt=0,soft 127.0.0.1:/nonexistent '\(point)'",
            "/sbin/mount_webdav -i http://127.0.0.1:1/dav '\(point)'",
            "/sbin/mount_smbfs //guest:@127.0.0.1/nonexistent '\(point)'",
            "/sbin/mount_afp afp://guest:@127.0.0.1/nonexistent '\(point)'",
        ]
        for attempt in attempts {
            let (_, text) = try await Self.run(attempt + " 2>&1; echo EXIT=$?", p, runner: r, timeout: .seconds(30))
            #expect(!text.contains("EXIT=0"), "\(attempt) reported success: \(text)")
            #expect(Self.mountsUnder(db).isEmpty, "\(attempt) mounted something: \(Self.mountsUnder(db))")
        }
        #expect(Set(try fm.contentsOfDirectory(atPath: db.path)) == ["orig"], "the denied data-home dir changed")
    }

    /// Brief route 4: APFS snapshots / Time Machine. The mount-escape audit found that `tmutil localsnapshot` was NOT stopped
    /// — it created a system APFS local snapshot of every volume from inside the sandbox (it carries the VFS-snapshot
    /// entitlement and needs no root), an effect outside the command's writable area. The round-9 fix denies `/usr/bin/tmutil`
    /// (`deniedExecutables`), so the exec is refused and no snapshot is created; this test asserts that refusal. (This is a
    /// side-effect / persistence concern, not a path read: mounting a snapshot to read a denied path is a client-side
    /// `mount(2)`, separately blocked — `mount_apfs -s` plants nothing over the denied data-home directory, which is
    /// unchanged.) The whole test is gated so it never runs — and so never creates a snapshot — unless the tmutil deny is in
    /// the rendered profile.
    @Test func apfsSnapshotAndTimeMachineMountsAreRefused() async throws {
        // Guard: only run once the fix is present, so a pre-fix checkout does not create a stray snapshot. The rendered
        // profile must deny tmutil.
        try #require(SeatbeltProfile.deniedExecutables.contains("/usr/bin/tmutil"),
                     "tmutil is not denied; skipping to avoid creating a system snapshot (apply the round-9 fix first)")
        let h = try Self.homeDir(); defer { Self.remove(h) }
        defer { Self.unmountAllUnder(h) }
        let fm = FileManager.default
        let w = try Self.mkdir(h.appending(path: "w"))
        let home = h.appending(path: "datahome")
        let db = home.appending(path: "db")
        try Self.file(db.appending(path: "orig"), "engine-private")
        let r = Self.runner(Self.baseline(engineHomes: [home]))
        let p = Self.policy(writable: [w], readable: [h.appending(path: "r")])
        // tmutil is refused at exec (process-exec deny), so it creates no snapshot.
        let (snap, snapText) = try await Self.run("/usr/bin/tmutil localsnapshot 2>&1", p, runner: r, timeout: .seconds(30))
        #expect(snap.exitCode != 0, "tmutil localsnapshot ran: \(snapText)")
        #expect(snapText.contains("not permitted"), "tmutil was not denied at exec: \(snapText)")
        #expect(!snapText.contains("Created local snapshot"), "a snapshot was created: \(snapText)")
        // mount_apfs -s is a client-side mount(2): it plants nothing over the denied directory.
        let dev = Self.outside_device(for: db) ?? "/dev/disk3s1"
        let (m, mText) = try await Self.run("/sbin/mount_apfs -s nonexistent.brahma.test \(dev) '\(db.path)' 2>&1; echo EXIT=$?",
                                            p, runner: r, timeout: .seconds(30))
        #expect(!mText.contains("EXIT=0"), "mount_apfs reported success: \(mText)")
        #expect(Self.mountsUnder(db).isEmpty, "mount_apfs mounted something: \(Self.mountsUnder(db))")
        _ = m
        #expect(Set(try fm.contentsOfDirectory(atPath: db.path)) == ["orig"], "the denied data-home dir changed")
    }

    /// The device backing `url` (from outside the sandbox): the first field of `df`'s data line.
    static func outside_device(for url: URL) -> String? {
        guard let out = try? Self.outside("/bin/df", [url.path]).output else { return nil }
        return out.split(separator: "\n").dropFirst().first?.split(separator: " ").first.map(String.init)
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

    /// A harmless, read-only invocation of each denied executable (never one that changes system state).
    static let harmlessArguments: [String: String] = [
        "/usr/bin/osascript": "-e 'return 1'", "/usr/bin/open": "-h", "/bin/launchctl": "version", "/usr/bin/security": "help",
        "/usr/bin/sudo": "-n true", "/usr/sbin/screencapture": "-h", "/usr/bin/crontab": "-l", "/usr/bin/at": "-l",
        "/usr/bin/tmutil": "version",
    ]

    /// Copy-and-rename bypass of the path-literal exec deny (security review of b334c09). A sandboxed command copies a
    /// denied Apple tool into its writable dir and runs the copy. Seatbelt cannot stop this: it has no filter on the exec
    /// TARGET's code signature (`signing-identifier` on `process-exec` matches the calling process, probed). What stops it is
    /// AMFI: every platform binary carries a launch constraint that it run from the sealed system volume, so the copy is
    /// SIGKILLed at exec ("Launch Constraint Violation"), `/bin/echo` as much as `tmutil`. This test pins that premise: if a
    /// macOS release drops the constraint, it fails, and the deny list needs another lever. It checks that the death is the
    /// SIGKILL (exit 137), not an argument error, and that the original path is still refused by Seatbelt.
    @Test func copiesOfDeniedExecutablesAreKilledAtExec() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        var script = ""
        for path in SeatbeltProfile.deniedExecutables {
            let args = try #require(Self.harmlessArguments[path], "no harmless invocation for \(path)")
            let name = (path as NSString).lastPathComponent
            script += "\(path) \(args) >/dev/null 2>&1; echo \"orig \(name) rc=$?\"\n"
            // sudo is mode 4111 (unreadable): it cannot be copied at all.
            if path == "/usr/bin/sudo" { script += "cp \(path) ./c-\(name) 2>/dev/null; echo \"cp \(name) rc=$?\"\n"; continue }
            script += "cp \(path) ./c-\(name) && ./c-\(name) \(args); echo \"copy \(name) rc=$?\"\n"
        }
        // The marker is computed by the shell, so the "Killed: 9" line (which repeats the command) never contains it.
        script += "cp /bin/echo ./c-echo && ./c-echo ECHO-$((40+2))-RAN; echo \"copy echo rc=$?\"\n"
        let (_, text) = try await Self.run(script + " 2>&1", Self.policy(writable: [w]))
        for path in SeatbeltProfile.deniedExecutables {
            let name = (path as NSString).lastPathComponent
            #expect(text.contains("orig \(name) rc=126"), "\(path) was not refused at exec by Seatbelt: \(text)")
            if path == "/usr/bin/sudo" { #expect(!text.contains("cp \(name) rc=0"), "sudo could be copied: \(text)"); continue }
            #expect(text.contains("copy \(name) rc=137"), "the copy of \(path) was not SIGKILLed at exec: \(text)")
        }
        #expect(text.contains("Killed: 9"), "\(text)")
        // Not our deny: an undenied platform binary's copy dies the same way (the launch constraint).
        #expect(text.contains("copy echo rc=137") && !text.contains("ECHO-42-RAN"), "\(text)")
    }

    static var rosettaAvailable: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/lipo")
    }

    /// The x86_64 slice of `tool`, ad-hoc re-signed, at `out`: a copy that AMFI's launch constraints do not kill.
    static func reSignedCopy(of tool: String, to out: URL, keepEntitlements: Bool = false) throws {
        let env = ["DEVELOPER_DIR": Toolchain.developerDir, "PATH": "/usr/bin:/bin"]
        let l = try Self.outside("/usr/bin/lipo", ["-thin", "x86_64", tool, "-output", out.path], environment: env)
        try #require(l.status == 0, "lipo \(tool): \(l.output)")
        let c = try Self.outside("/usr/bin/codesign", ["-f", "-s", "-"]
            + (keepEntitlements ? ["--preserve-metadata=entitlements"] : []) + [out.path], environment: env)
        try #require(c.status == 0, "codesign \(tool): \(c.output)")
    }

    /// launchd job creation (copy audit). The path deny cannot stop a re-signed `launchctl`, so the boundary is launchd's own
    /// sandbox check, which the profile denies explicitly (`(deny job-creation)`). Control first: the same copy run OUTSIDE
    /// the sandbox does create a job, so the in-sandbox refusal is the profile, not a broken copy. Both canary jobs (they
    /// only run /usr/bin/true) are removed from outside the sandbox even when an expectation fails.
    @Test(.enabled(if: rosettaAvailable, "no Rosetta"))
    func launchdJobCreationIsRefusedEvenForAReSignedLaunchctl() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let label = "dev.brahma.canary.\(UUID().uuidString)", control = "dev.brahma.canary.\(UUID().uuidString)"
        defer {
            _ = try? Self.outside("/bin/launchctl", ["remove", label])
            _ = try? Self.outside("/bin/launchctl", ["remove", control])
        }
        try #require(SeatbeltProfile.render(policy: Self.policy(writable: [w]), baseline: Self.baseline(), proxyPort: nil)
            .contains("(deny job-creation)"))
        let copy = w.appending(path: "r-launchctl")
        try Self.reSignedCopy(of: "/bin/launchctl", to: copy)
        let made = try Self.outside(copy.path, ["submit", "-l", control, "--", "/usr/bin/true"])
        try #require(made.status == 0, "the re-signed launchctl cannot submit even unsandboxed: \(made.output)")
        try #require(try Self.outside("/bin/launchctl", ["list", control]).status == 0, "control job missing")
        _ = try Self.outside("/bin/launchctl", ["remove", control])

        let (_, text) = try await Self.run("./r-launchctl submit -l \(label) -- /usr/bin/true; echo \"submit rc=$?\"",
                                           Self.policy(writable: [w]))
        #expect(text.contains("submit rc=") && !text.contains("submit rc=0"), "\(text)")
        let listed = try Self.outside("/bin/launchctl", ["list", label])
        #expect(listed.status != 0, "the sandboxed copy created a launchd job: \(listed.output)")
    }

    /// The copy route that DOES run: thin a denied tool to its x86_64 slice (Rosetta) and ad-hoc re-sign it. Seatbelt
    /// cannot stop it (positive control: such a copy of `/bin/echo` runs in the writable dir), and a command could build
    /// the same code itself. What the copy loses is what the deny protects. Restricted entitlements cannot ride on an ad-hoc
    /// signature (AMFI kills a re-signed `tmutil` that keeps them), and setuid does not survive `cp` (`crontab`, `at`). The
    /// Keychain stays out of reach (`security`, mach-lookup deny).
    /// `launchctl` is covered by `launchdJobCreationIsRefusedEvenForAReSignedLaunchctl`. Apple events from a re-signed
    /// `osascript` are not asserted: `name of application "Finder"` is answered locally by LaunchServices (no event is sent),
    /// and a real event needs the owner's Automation (TCC) consent, which a test must not prompt for.
    @Test(.enabled(if: rosettaAvailable, "no Rosetta"))
    func reSignedCopiesOfDeniedExecutablesLoseTheirPrivilege() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        func thin(_ tool: String, as name: String, keepEntitlements: Bool = false) throws {
            try Self.reSignedCopy(of: tool, to: w.appending(path: name), keepEntitlements: keepEntitlements)
        }
        try thin("/bin/echo", as: "r-echo")
        try thin("/usr/bin/tmutil", as: "r-tmutil-ent", keepEntitlements: true)
        try thin("/usr/bin/security", as: "r-security")
        try thin("/usr/bin/crontab", as: "r-crontab")
        try thin("/usr/bin/at", as: "r-at")
        let ent = try Self.outside("/usr/bin/codesign", ["-d", "--entitlements", "-", w.appending(path: "r-tmutil-ent").path])
        try #require(ent.output.contains("com.apple.private"), "the re-signed tmutil did not keep its entitlements: \(ent.output)")
        let script = """
        ./r-echo RESIGNED-$((40+2))-RAN; echo "echo rc=$?"
        ./r-tmutil-ent version; echo "tmutil-ent rc=$?"
        ./r-security list-keychains; echo "security rc=$?"
        ./r-crontab -l; echo "crontab rc=$?"
        ./r-at -l; echo "at rc=$?"
        """
        let (_, text) = try await Self.run(script + " 2>&1", Self.policy(writable: [w]))
        #expect(text.contains("RESIGNED-42-RAN") && text.contains("echo rc=0"), "writable-dir exec was blocked: \(text)")
        #expect(text.contains("tmutil-ent rc=137") && !text.contains("tmutil version 4"), "an ad-hoc tmutil kept its entitlements: \(text)")
        #expect(!text.contains(".keychain"), "the Keychain was reachable: \(text)")
        #expect(text.contains("crontab: seteuid: Operation not permitted") && !text.contains("crontab rc=0"), "\(text)")
        #expect(text.contains("at: setregid failed: Operation not permitted") && !text.contains("at rc=0"), "\(text)")
    }

    /// B-I3: each run gets its own HOME, CARGO_HOME and XDG_CACHE_HOME under its TMPDIR (thrown away with it), so config a
    /// check plants there cannot run in a later check; only the npm cache is shared, and only when the policy gives a shared
    /// cache. A merge check (one writable entry) gets no shared cache: its npm cache is per-run too.
    /// Round 2: every toolchain cache is per-run under TMPDIR — HOME, CARGO_HOME, XDG_CACHE_HOME, the npm cache and the clang
    /// module cache. A check gets no writable shared cache at all, so nothing it plants can run in a later check.
    @Test func toolchainCachesAreAllPerRun() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let show = "for v in HOME CARGO_HOME XDG_CACHE_HOME npm_config_cache CLANG_MODULE_CACHE_PATH; do eval \"echo $v=\\$$v\"; done"
        let (submit, s) = try await Self.run(show, Self.policy(writable: [w], readable: [h], toolchain: true))
        #expect(submit.exitCode == 0, "\(s)")
        let tmp = w.appending(path: ".brahma-tmp")
        #expect(s.contains("HOME=\(tmp.path)/home")); #expect(s.contains("CARGO_HOME=\(tmp.path)/cargo"))
        #expect(s.contains("XDG_CACHE_HOME=\(tmp.path)/xdg")); #expect(s.contains("npm_config_cache=\(tmp.path)/npm"))
        #expect(s.contains("CLANG_MODULE_CACHE_PATH=\(tmp.path)/clang-modules"))
        // Even with a second writable entry, nothing goes to it: the npm cache stays per-run under TMPDIR.
        let other = try Self.mkdir(h.appending(path: "other"))
        let (two, t) = try await Self.run(show, Self.policy(writable: [w, other], readable: [h], toolchain: true))
        #expect(two.exitCode == 0)
        #expect(t.contains("npm_config_cache=\(tmp.path)/npm"), "npm must stay per-run, never a shared entry: \(t)")
    }

    /// B-I2: the engine never follows a link a check planted at its own writable root. `removeTemp`, anchored at the root's
    /// parent and opened O_NOFOLLOW, removes the link itself and never touches the link's target.
    @Test func removeTempNeverFollowsALinkAtTheRoot() throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let parent = try Self.mkdir(h.appending(path: "checkouts"))
        let root = parent.appending(path: "r1")
        let outside = try Self.mkdir(h.appending(path: "outside"))
        try Self.file(outside.appending(path: ".brahma-tmp/keep"), "do-not-delete")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)   // root is a link to `outside`
        SeatbeltRunner.removeTemp(Self.policy(writable: [root]))
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: ".brahma-tmp/keep").path), "followed the link")
        #expect(SandboxPath.kind(root.path) == .link, "the link itself should be untouched by removeTemp")
    }

    /// B-I4: a check that puts a process in a new session (`POSIX::setsid`, via a double fork) cannot outlive the run; the
    /// marker-based sweep kills it (even though it left the process group) and reports the kill, and the outcome stands (N2:
    /// only a straggler that cannot be killed or classified makes the run inconclusive). The marker still identifies it after
    /// it deletes its own checkout.
    @Test func setsidEscapeeIsSweptAndReported() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        // macOS has no `setsid` binary; use perl. The escapee forks, the parent exits, the child starts a new session, writes
        // its pid, deletes the checkout out from under itself, then sleeps.
        let perl = "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); open(F, \">\", \"escapee.pid\"); print F $$; close(F); "
            + "unlink grep { $_ ne \"escapee.pid\" } glob(\"*\"); sleep 300'"
        let command = "\(perl) & sleep 0.5; echo started"
        final class Reports: @unchecked Sendable { let lock = NSLock(); var all: [StragglerReport] = [] }
        let reports = Reports()
        let r = SeatbeltRunner(baseline: { Self.baseline() }, proxies: EgressProxyPool(), termGrace: 5,
                               onStraggler: { report in reports.lock.withLock { reports.all.append(report) } })
        let (outcome, _) = try await Self.run(command, Self.policy(writable: [w], readable: [h]), runner: r, timeout: .seconds(20))
        // N2: the escapee was found (by the run's marker, though it left the group and deleted the checkout) and killed, so
        // the outcome stands (exit 0 stays a pass) and the kill is reported, not hidden.
        #expect(outcome.exitCode == 0, "\(outcome)")
        let pidText = (try? String(contentsOf: w.appending(path: "escapee.pid"), encoding: .utf8)) ?? ""
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), "the escapee never recorded its pid")
        #expect(await Self.gone(pid), "an escaped sandboxed process survived the run")
        let report = try #require(reports.lock.withLock { reports.all.first })
        #expect(report.killed.contains(pid)); #expect(!report.inconclusive); #expect(report.checkout == w)
    }

    /// B-I4: one run's sweep never touches another run's processes. Under `(allow default)` every name is allowed unless
    /// denied, so each profile denies the whole marker prefix and allows only its own; a long run keeps running while a
    /// short one ends and sweeps.
    @Test func concurrentRunsDoNotSweepEachOther() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let a = try Self.mkdir(h.appending(path: "a")), b = try Self.mkdir(h.appending(path: "b"))
        async let long = Self.run("sleep 3; echo long-done", Self.policy(writable: [a]), timeout: .seconds(30))
        try await Task.sleep(for: .milliseconds(500))
        let (short, _) = try await Self.run("echo short-done", Self.policy(writable: [b]))
        #expect(short.exitCode == 0)
        let (longOutcome, longText) = try await long
        #expect(longOutcome.exitCode == 0, "the long run was swept by the short one: \(longOutcome)")
        #expect(longText.contains("long-done"))
    }

    /// A-I1 ruling test: a 0600 file in the per-user temp dir (outside the home) cannot be read inside the sandbox.
    @Test func userTempFileUnreadable() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let base = SandboxBaseline.current(paths: BrahmaPaths(home: Self.realHome.appending(path: "Library/Application Support/Brahma"),
                                                              workspaces: Self.realHome.appending(path: "Brahma")),
                                           otherWorkspaces: [], backupTargets: [])
        let temp = try #require(base.darwinUserTemp)
        let secret = temp.appending(path: "brahma-tread-\(UUID().uuidString)")
        try "top-secret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        defer { try? FileManager.default.removeItem(at: secret) }
        let (outcome, text) = try await Self.run("cat '\(secret.path)'", Self.policy(writable: [w]))
        #expect(outcome.exitCode != 0); #expect(!text.contains("top-secret"))
        // Even under the toolchain profile (which re-allows only xcrun_db and the NSIRD staging), the file is unreadable.
        let (tc, tcText) = try await Self.run("cat '\(secret.path)'", Self.policy(writable: [w], readable: [h], toolchain: true))
        #expect(tc.exitCode != 0); #expect(!tcText.contains("top-secret"))
    }

    /// NSIRD ruling test: a sandboxed check cannot enumerate another process's open files (`lsof -p <owner pid>`), so it
    /// cannot discover the per-user temp staging names. It still sees its own process.
    @Test func cannotInspectOtherProcessesOpenFiles() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return }
        // A process outside the sandbox with an open file whose name a check must not learn. It lives until the test ends it
        // (however slow the suite runs) and is waited on by pid with a bound (`OutsideChild`), never by Foundation's
        // `waitUntilExit`, which hung here under a concurrent `swift test`. lsof gets -n -P: no DNS or service lookups.
        let marker = "NSIRD-\(UUID().uuidString)"
        let open = w.appending(path: marker)
        let victim = try OutsideChild("exec 9>'\(open.path)'; exec /bin/sleep 600")
        defer { victim.end() }
        try await Self.waitUntil { FileManager.default.fileExists(atPath: open.path) }   // the file is open: a file event, no fixed sleep
        try #require(victim.isRunning)
        // Control: outside the sandbox, lsof does list it, so the negative result below is the sandbox, not timing.
        let seen = ExternalTool.run(executable: "/usr/sbin/lsof", arguments: ["-n", "-P", "-p", "\(victim.pid)"], environment: Self.env, timeout: 120)
        try #require(seen.output.contains(marker), "lsof outside the sandbox did not list the victim's open file: \(seen.output.suffix(400))")
        let (outcome, text) = try await Self.run("/usr/sbin/lsof -n -P -p \(victim.pid) 2>&1 || true; echo DONE", Self.policy(writable: [w]))
        #expect(outcome.exitCode == 0)
        #expect(victim.isRunning, "the victim was gone during the sandboxed lsof, so the result proves nothing")
        #expect(!text.contains(marker), "lsof revealed another process's open file: \(text.suffix(400))")
        // Positive control (N7): inside the same sandbox, lsof still works on the shell's own process, which holds its own
        // marker file open — so the negative result above is the sandbox, not lsof failing.
        let own = "OWN-\(UUID().uuidString)"
        let (control, controlText) = try await Self.run("exec 9>'\(own)'; /usr/sbin/lsof -n -P -p $$ 2>&1; echo DONE", Self.policy(writable: [w]))
        #expect(control.exitCode == 0)
        #expect(controlText.contains(own), "lsof could not list the sandboxed shell's own open file: \(controlText.suffix(400))")
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
    /// clobbered. The pasteboard is one per login session, shared by every test process: two `swift test` runs at once
    /// clobbered each other's marker (and restore), so the whole test holds a cross-process lock first (`PasteboardLock`).
    @Test func pbpasteDenied() async throws {
        let lock = try await PasteboardLock.acquire()
        defer { lock.release() }
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
        // An unrelated process outside the sandbox survives a TERM from inside (it lives until the test ends it).
        let victim = try OutsideChild("exec /bin/sleep 600")
        defer { victim.end() }
        let (term, _) = try await Self.run("kill -TERM \(victim.pid)", Self.policy(writable: [w]))
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

    /// The run may listen on its own port and on no other. Load-tolerant without weakening: ports come from the kernel (bound
    /// to port 0) but anything on the machine can take one between that probe and nc's bind, so an attempt where nc reports
    /// the address taken or unavailable (not a sandbox denial) is retried with a fresh pair, a bounded number of times. No
    /// fixed sleeps: the client retries until the listener is up (bounded), and the other-port listener is waited on until it
    /// exits (bounded; one still listening at the bound did bind).
    @Test func loopbackListenOnlyOwnPorts() async throws {
        let h = try Self.homeDir(); defer { Self.remove(h) }
        let w = try Self.mkdir(h.appending(path: "w"))
        let raced = ["Address already in use", "Can't assign requested address"]
        var last = ""
        for _ in 0..<20 {
            let port = try Self.freePortPair()
            let p = Self.policy(writable: [w], network: .loopbackListen(allow: [], ports: [port]))
            let command = """
            rm -f got.txt own.err other.err
            nc -l 127.0.0.1 \(port) > got.txt 2> own.err & S=$!
            i=0; until echo hello | nc -w 3 127.0.0.1 \(port) 2>/dev/null; do
              i=$((i+1)); if [ $i -ge 600 ] || ! kill -0 $S 2>/dev/null; then echo OWN-NOT-REACHED; break; fi; sleep 0.1
            done
            wait $S; echo "own-exit=$?"; cat got.txt; cat own.err
            nc -l 127.0.0.1 \(port + 1) 2> other.err & N=$!
            i=0; while kill -0 $N 2>/dev/null && [ $i -lt 600 ]; do i=$((i+1)); sleep 0.1; done
            if kill -0 $N 2>/dev/null; then kill $N; echo BOUND-OTHER; else wait $N; echo "other-exit=$?"; fi
            cat other.err
            """
            let (outcome, text) = try await Self.run(command, p, timeout: .seconds(300))
            last = text
            if raced.contains(where: { text.contains($0) }) { continue }       // a port taken from outside: a fresh pair
            #expect(outcome.exitCode == 0, "\(text)")
            #expect(text.contains("hello") && text.contains("own-exit=0"), "own port not usable: \(text)")
            #expect(!text.contains("BOUND-OTHER"), "bound a port it was not given: \(text)")
            #expect(text.contains("other-exit=") && !text.contains("other-exit=0") && text.contains("Operation not permitted"),
                    "the other port's bind was not refused by the sandbox: \(text)")
            return
        }
        Issue.record("every port pair was taken from outside the sandbox: \(last)")
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
        // runs with its own turned off (`--disable-sandbox`). Its atomic writes stage in the per-user temp dir
        // (`TemporaryItems/NSIRD_swift-build_…`), which the toolchain policy allows; nothing under the owner's ~/Library.
        let (build, buildText) = try await Self.run("swift build --disable-sandbox --cache-path .build/cache > build.log 2>&1; s=$?; tail -40 build.log; exit $s",
                                                     p, timeout: .seconds(150), env: env)
        #expect(build.exitCode == 0, "swift build failed under the toolchain policy:\n\(buildText.suffix(3000))")
        // xcodebuild builds an Xcode PROJECT (resolving a SwiftPM package needs to write the owner's ~/Library SwiftPM cache,
        // which stays denied — the check-author guidance says to build projects with `-project`, not Swift packages). Its
        // build service stages atomic writes in `TemporaryItems/NSIRD_(xcodebuild|SWBBuildService)_…`, which the policy allows.
        let proj = try Self.xcodeProject(in: try Self.mkdir(h.appending(path: "proj")))
        let xp = Self.policy(writable: [proj, cache], readable: [h], toolchain: true)
        let (xcode, xcodeText) = try await Self.run(
            "xcodebuild -project Hello.xcodeproj -scheme Hello -destination 'platform=macOS' -derivedDataPath .build/dd build > xc.log 2>&1; s=$?; tail -40 xc.log; exit $s",
            xp, cwd: proj, timeout: .seconds(150), env: env)
        #expect(xcode.exitCode == 0 && xcodeText.contains("BUILD SUCCEEDED"), "xcodebuild failed under the toolchain policy:\n\(xcodeText.suffix(3000))")
        let after = try? FileManager.default.attributesOfItem(atPath: swiftpmCache.path)[.modificationDate] as? Date
        #expect(before == after, "the owner's SwiftPM cache was written")
        // Without the toolchain allowances the build cannot run.
        try? FileManager.default.removeItem(at: pkg.appending(path: ".build"))
        let (bare, _) = try await Self.run("swift build --disable-sandbox --cache-path .build/cache", Self.policy(writable: [pkg, cache], readable: [h]),
                                           timeout: .seconds(120), env: env)
        #expect(bare.exitCode != 0)
    }

    /// A minimal Xcode project (one command-line tool target, manual signing) under `dir`, whose cwd is `dir`.
    static func xcodeProject(in dir: URL) throws -> URL {
        try file(dir.appending(path: "main.swift"), "print(\"hello from xcodebuild\")\n")
        try file(dir.appending(path: "Hello.xcodeproj/project.pbxproj"), """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1; classes = {}; objectVersion = 56;
        \tobjects = {
        \t\tA1 = {isa = PBXBuildFile; fileRef = A2; };
        \t\tA2 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
        \t\tA3 = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = Hello; sourceTree = BUILT_PRODUCTS_DIR; };
        \t\tA4 = {isa = PBXGroup; children = (A2, A5); sourceTree = "<group>"; };
        \t\tA5 = {isa = PBXGroup; children = (A3); name = Products; sourceTree = "<group>"; };
        \t\tA6 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1); runOnlyForDeploymentPostprocessing = 0; };
        \t\tA7 = {isa = PBXNativeTarget; buildConfigurationList = A8; buildPhases = (A6); buildRules = (); dependencies = (); name = Hello; productName = Hello; productReference = A3; productType = "com.apple.product-type.tool"; };
        \t\tA8 = {isa = XCConfigurationList; buildConfigurations = (A9); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        \t\tA9 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; }; name = Debug; };
        \t\tAA = {isa = XCConfigurationList; buildConfigurations = (AB); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        \t\tAB = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; }; name = Debug; };
        \t\tAC = {isa = PBXProject; buildConfigurationList = AA; compatibilityVersion = "Xcode 14.0"; mainGroup = A4; productRefGroup = A5; projectDirPath = ""; projectRoot = ""; targets = (A7); };
        \t};
        \trootObject = AC;
        }
        """)
        return dir
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
                                darwinUserDir: URL(fileURLWithPath: "/private/var/folders/x+y"),
                                engineHomes: [URL(fileURLWithPath: "/srv/brahma home")],
                                companyWorkspaces: [URL(fileURLWithPath: "/w"), URL(fileURLWithPath: "/other-co")])
        let p = SandboxPolicy(writable: [URL(fileURLWithPath: "/srv/brahma home/run/checkouts/r1")],
                              readable: [URL(fileURLWithPath: "/w")], network: .loopbackListen(allow: [], ports: [4000, 4001]), toolchain: true)
        let text = SeatbeltProfile.render(policy: p, baseline: b, proxyPort: 5555, marker: "dev.brahma.run.abc")
        let order = ["(version 1)", "(allow default)",
                     "(deny file-read-data (subpath \"/Users/o\") (subpath \"/Volumes\")",
                     "(allow file-read-data (subpath \"/w\")", "(deny file-read* file-read-data (subpath \"/Users/o/.ssh\")",
                     "(deny file-write* (require-not (require-any (subpath \"/srv/brahma home/run/checkouts/r1\")",
                     "(deny file-link (require-not (require-any (subpath \"/srv/brahma home/run/checkouts/r1\"))))",
                     "(deny file-clone (require-not (require-any (subpath \"/srv/brahma home/run/checkouts/r1\") (subpath \"/w\")",
                     "(deny file-clone (require-all (vnode-type DIRECTORY) (require-not (require-any (subpath \"/srv/brahma home/run/checkouts/r1\")))))",
                     "(deny file-clone (subpath \"/Users/o/.ssh\") (subpath \"/other-co\"))",
                     "(deny file-clone (require-all (require-any (subpath \"/srv/brahma home\")) (require-not (require-any (subpath \"/srv/brahma home/run/checkouts/r1\") (subpath \"/w\")))))",
                     "(deny file-mount file-unmount file-mount-update)",
                     "(deny signal (target others))", "(deny process-info* (target others))",
                     "(deny mach-lookup (global-name \"com.apple.SecurityServer\")",
                     "(deny process-exec (literal \"/usr/bin/osascript\")", "(deny job-creation)", "(allow mach-lookup (global-name \"com.apple.windowserver.active\")",
                     "(deny mach-lookup (global-name-prefix \"dev.brahma.run.\"))",
                     "(allow mach-lookup (global-name \"dev.brahma.run.abc\"))",
                     "(deny network*)", "(allow network-outbound (remote ip \"localhost:5555\"))",
                     "(allow network-bind network-inbound (local ip \"localhost:4000\") (local ip \"localhost:4001\"))",
                     "(allow network-outbound (remote ip \"localhost:4000\") (remote ip \"localhost:4001\"))"]
        var at = text.startIndex
        for piece in order {
            let found = try #require(text.range(of: piece, range: at..<text.endIndex), "missing or out of order: \(piece)\n\(text)")
            at = found.upperBound
        }
        #expect(text.contains("(subpath \"/srv/brahma home\")"), "the engine home is denied for reading")
        // The per-user Darwin folder (T/C/0) is denied for reading (A-I1).
        #expect(text.contains("(subpath \"/private/var/folders/x+y\")"))
        // The other company's workspace is denied; this run's readable workspace is not in that deny.
        #expect(text.contains("(subpath \"/other-co\")"))
        // Toolchain reads: the xcrun_db and NSIRD temp regexes and the one narrowed C read subpath (no broad `(subpath C)`).
        #expect(text.contains("(regex #\"^/private/var/folders/x\\+y/T/xcrun_db\")"))
        #expect(text.contains("TemporaryItems/NSIRD_(swift-(build|package|test|run)|xcodebuild|SWBBuildService)_"))
        #expect(text.contains("(subpath \"/private/var/folders/x+y/C/com.apple.DeveloperTools\")"))
        #expect(!text.contains("C/clang"), "the default module cache is not readable (fix round 3)")
        #expect(!text.contains("Library/Caches/org.swift.swiftpm"), "the owner's SwiftPM cache is not readable (fix round 3)")
        #expect(text.contains("(global-name \"com.apple.FSEvents\")"))
        #expect(text.contains("(global-name \"com.apple.DiskArbitration.diskarbitrationd\")"), "DiskArbitration mounts outside the sandbox (round 8)")
        #expect(!text.contains("(subpath \"/private/var/folders/x+y/C\")"), "C is read narrowly, not wholesale")
        // C is never written (compiler caches are per-run): no C write subpaths or org.llvm.clang write regex.
        #expect(!text.contains("C/org.llvm.clang")); #expect(!text.contains("C/org.swift.swiftpm"))
        for literal in ["/dev/null", "/dev/tty", "/dev/dtracehelper"] { #expect(text.contains("(literal \"\(literal)\")")) }
        #expect(text.contains("(regex #\"^/dev/fd/\")"))
        #expect(!text.contains("Library/Caches/org.swift.swiftpm\") (literal"), "nothing under ~/Library is writable")
        // No marker rendered when none is given.
        #expect(!SeatbeltProfile.render(policy: p, baseline: b, proxyPort: 5555).contains("dev.brahma.run"))
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

    // MARK: Final review I1: a check reads no more than a sandboxed turn

    /// A secret file in a fresh directory under `root` (`/private/tmp/...`), created when missing; the returned closure removes
    /// what this test made (the directory, and `root` itself only when the test created it).
    static func tmpSecret(root: String, _ text: String) throws -> (file: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let createdRoot = !fm.fileExists(atPath: root)
        if createdRoot { try fm.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }   // exec-bit fixture: a directory mode
        let dir = URL(fileURLWithPath: root).appending(path: "brahma-test-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])   // exec-bit fixture: a directory mode
        let file = dir.appending(path: "s")
        try text.write(to: file, atomically: false, encoding: .utf8)
        return (file, { try? fm.removeItem(at: dir); if createdRoot { try? fm.removeItem(atPath: root) } })
    }

    /// The check shape for real: the company workspace readable, the run's checkout under the data home writable, the toolchain
    /// on, the workspace listed in the baseline (as `checkBaseline` lists every company's). The check cannot read another
    /// agent's temp folder (`/private/tmp/b-<uid>/*`), the owner's Claude Code sessions (`/private/tmp/claude-<uid>`), or the
    /// private parts of `.brahma` (other agents' homes, labs and notes, review pages, trial copies), by `cat`, `ls` or a clone;
    /// the workspace's sources and the turn-readable `.brahma` places stay readable, and a git check in the checkout works.
    @Test func checkCannotReadAgentTempsOwnerSessionsOrPrivateDotBrahma() async throws {
        let ws = try Self.homeDir(); defer { Self.remove(ws) }
        let home = try tempDir().resolvedForSandbox.appending(path: "home")
        let checkout = home.appending(path: "run/checkouts/r1")
        try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.file(ws.appending(path: "src/f"), "src-ok")
        _ = try GitFixture.plainGit(["init", "-q", "-b", "main"], in: ws)
        _ = try GitFixture.plainGit(["add", "src"], in: ws)
        _ = try GitFixture.plainGit(["commit", "-q", "-m", "base commit"], in: ws)
        _ = try GitFixture.plainGit(["worktree", "add", "--quiet", "--detach", checkout.path, "HEAD"], in: ws)
        try Self.file(ws.appending(path: ".brahma/wt/K/f"), "wt-ok")
        let privates = ["home/other/s": "home-secret", "labs/other/s": "lab-secret", "notes/agents/other.md": "notes-secret",
                        "ext-review/A-1.md": "review-secret", "ext-try/t1/f": "try-secret", "trash/x": "trash-secret",
                        "plans/K/p.md": "plan-secret", "resources/private/r": "resource-secret"]
        for (path, text) in privates { try Self.file(ws.appending(path: ".brahma/\(path)"), text) }
        let agentTemp = try Self.tmpSecret(root: "/private/tmp/b-\(getuid())", "agent-temp-secret")
        defer { agentTemp.cleanup() }
        let ownerSession = try Self.tmpSecret(root: "/private/tmp/claude-\(getuid())", "owner-session-secret")
        defer { ownerSession.cleanup() }

        var b = Self.baseline(engineHomes: [home])
        b.companyWorkspaces = [ws]
        let r = Self.runner(b)
        var env = Self.env
        env["DEVELOPER_DIR"] = Toolchain.developerDir
        let p = Self.policy(writable: [checkout], readable: [ws], toolchain: true)

        var secrets = privates.map { (ws.appending(path: ".brahma/\($0.key)").path, $0.value) }
        secrets += [(agentTemp.file.path, "agent-temp-secret"), (ownerSession.file.path, "owner-session-secret"),
                    ("/tmp/" + agentTemp.file.path.dropFirst("/private/tmp/".count), "agent-temp-secret")]
        for (path, text) in secrets {
            let (read, readText) = try await Self.run("cat '\(path)'", p, runner: r, env: env)
            #expect(read.exitCode != 0, "\(path) was readable"); #expect(!readText.contains(text), "\(path) leaked")
            let (clone, _) = try await Self.run("cp -c '\(path)' cloned && cat cloned", p, runner: r, env: env)
            #expect(clone.exitCode != 0, "\(path) could be cloned")
        }
        for dir in [ws.appending(path: ".brahma").path, ws.appending(path: ".brahma/labs").path, "/private/tmp/b-\(getuid())",
                    "/private/tmp/claude-\(getuid())", agentTemp.file.deletingLastPathComponent().path] {
            let (list, listText) = try await Self.run("ls '\(dir)'", p, runner: r, env: env)
            #expect(list.exitCode != 0, "\(dir) could be listed: \(listText)")
        }
        // What a turn reads stays readable, and a git check in the checkout works (it reads the workspace's `.git`).
        let (ok, okText) = try await Self.run("cat '\(ws.path)/src/f' '\(ws.path)/.brahma/wt/K/f' && cat src/f && "
                                              + "git log -1 --format=%s && git status --porcelain --untracked-files=no && echo git-ok",
                                              p, runner: r, env: env)
        #expect(ok.exitCode == 0, "\(okText)")
        #expect(okText.contains("src-ok") && okText.contains("wt-ok") && okText.contains("base commit") && okText.contains("git-ok"), "\(okText)")
        // The profile names what it hides and re-allows.
        let profile = SeatbeltProfile.render(policy: p, baseline: b, proxyPort: nil)
        #expect(profile.contains("(deny file-read* file-read-data (subpath \"\(ws.path)/.brahma\"))"), "\(profile)")
        #expect(profile.contains("(subpath \"/private/tmp/b-\(getuid())\")"))
        #expect(profile.contains("(subpath \"/private/tmp/claude-\(getuid())\")"))
        // Fix-wave F4: Claude Code's daemon-control and pty socket folders too.
        #expect(profile.contains("(subpath \"/private/tmp/cc-daemon-\(getuid())\")")); #expect(profile.contains("(subpath \"/private/tmp/cc-socks\")"))
    }

    /// I1: a normal Swift package builds in a check's checkout under the new read scope (the workspace listed, `.brahma`
    /// hidden, the Claude temp places denied).
    @Test(.timeLimit(.minutes(6)), .enabled(if: Toolchain.xcodeAvailable))
    func swiftBuildChecksStillWorkUnderTheCheckReadScope() async throws {
        let ws = try Self.homeDir(); defer { Self.remove(ws) }
        let home = try tempDir().resolvedForSandbox.appending(path: "home")
        let checkout = home.appending(path: "run/checkouts/r1")
        try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.file(ws.appending(path: "Package.swift"), """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Hello", platforms: [.macOS(.v13)], targets: [.executableTarget(name: "Hello")])
        """)
        try Self.file(ws.appending(path: "Sources/Hello/main.swift"), "print(\"hello from the check\")\n")
        try Self.file(ws.appending(path: ".brahma/labs/other/s"), "lab-secret")
        _ = try GitFixture.plainGit(["init", "-q", "-b", "main"], in: ws)
        _ = try GitFixture.plainGit(["add", "Package.swift", "Sources"], in: ws)
        _ = try GitFixture.plainGit(["commit", "-q", "-m", "package"], in: ws)
        _ = try GitFixture.plainGit(["worktree", "add", "--quiet", "--detach", checkout.path, "HEAD"], in: ws)
        var b = Self.baseline(engineHomes: [home])
        b.companyWorkspaces = [ws]
        var env = Self.env
        env["DEVELOPER_DIR"] = Toolchain.developerDir
        let p = Self.policy(writable: [checkout], readable: [ws], toolchain: true)
        ScratchScope.current?.allowExecutable(named: "Hello")   // the product of the build under test
        let (build, text) = try await Self.run("swift build --disable-sandbox --cache-path .build/cache > build.log 2>&1; s=$?; tail -40 build.log; "
                                               + "[ $s -eq 0 ] && .build/debug/Hello; exit $s", p, runner: Self.runner(b), timeout: .seconds(240), env: env)
        #expect(build.exitCode == 0, "swift build failed under the check read scope:\n\(text.suffix(3000))")
        #expect(text.contains("hello from the check"))
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

    /// Waits on `condition`, bounded by a generous awake-time deadline.
    static func waitUntil(_ seconds: Int = 120, _ condition: () -> Bool) async throws {
        let deadline = AwakeTime.deadline(after: .seconds(seconds))
        while !condition(), AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(20)) }
    }

    static func gone(_ pid: Int32) async -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// A listening loopback socket on a port the kernel picks. Under load the ephemeral range can run short for a moment
    /// (EADDRNOTAVAIL) or a pick can race (EADDRINUSE): retried, bounded.
    static func listenSocket() throws -> (Int32, UInt16) {
        var failure: (any Error)?
        for _ in 0..<500 {
            do { return try listenSocketOnce() } catch let e as POSIXError where e.code == .EADDRNOTAVAIL || e.code == .EADDRINUSE {
                failure = e
                usleep(10_000)
            }
        }
        throw failure ?? POSIXError(.EADDRNOTAVAIL)
    }

    private static func listenSocketOnce() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard bound == 0 else { let e = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EADDRINUSE) }
        guard listen(fd, 4) == 0 else { let e = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    /// A port `p` with `p` and `p + 1` both free just now (bounded tries; under load `p + 1` is often taken).
    static func freePortPair() throws -> UInt16 {
        for _ in 0..<2000 {
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
        throw POSIXError(.EADDRNOTAVAIL)
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

/// An exclusive advisory lock (`flock`) on `/usr/bin/pbcopy`, opened read-only: every Brahma test process that uses the
/// session's "find" pasteboard takes it first, so concurrent test runs take turns. Nothing is written; the lock goes with the
/// descriptor. Acquiring is bounded (awake time), never a fixed sleep.
final class PasteboardLock {
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }

    static func acquire(bound: Duration = .seconds(300)) async throws -> PasteboardLock {
        let fd = open("/usr/bin/pbcopy", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let deadline = AwakeTime.deadline(after: bound)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, AwakeTime.now < deadline else {
                let e = errno; close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: e) ?? .ETIMEDOUT)
            }
            try await AwakeTime.sleep(for: .milliseconds(20))
        }
        return PasteboardLock(fd: fd)
    }

    func release() { close(fd) }
}
