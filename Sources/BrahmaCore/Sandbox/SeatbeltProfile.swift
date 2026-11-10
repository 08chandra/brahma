import Foundation

/// The Seatbelt (SBPL) profile of one sandboxed command. Rule order, as the brief pins it (two deliberate deltas below):
///
/// ```
/// (version 1)
/// (allow default)
/// (deny file-read-data (subpath "<userHome>") (subpath "/Volumes") (subpath "<each engine home>"))
/// (allow file-read-data (subpath "<each readable + writable>") <toolchain reads>)
/// (deny file-read* file-read-data (subpath "<each read workspace>/.brahma"))                                   ; final I1
/// (allow file-read-metadata (literal "<each read workspace>/.brahma"))                                         ; final I1
/// (allow file-read* file-read-data (subpath "<.brahma/each readableDotBrahma>") <policy entries in .brahma>)    ; final I1
/// (deny file-read* file-read-data (subpath "<each protected>") (subpath "<each other company workspace>"))
/// (deny file-write* (require-not (require-any (subpath "<each writable>") <toolchain writes>
///     (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper") (regex #"^/dev/fd/"))))
/// (deny file-link (require-not (require-any (subpath "<each writable>"))))                              ; fix round 5
/// (deny file-clone (require-not (require-any (subpath "<each writable>") <each readable + toolchain read>)))  ; fix round 6
/// (deny file-clone (require-all (vnode-type DIRECTORY) (require-not (require-any (subpath "<each writable>")))))  ; round 7
/// (deny file-clone (subpath "<each protected>") (subpath "<each other company workspace>"))                      ; round 7
/// (deny file-clone (require-all (require-any <each hidden .brahma>) (require-not (require-any <re-allowed>))))  ; final I1
/// (deny file-clone (require-all (subpath "<each engine home>") (require-not (require-any (subpath "<each writable + readable>")))))
/// (deny file-mount file-unmount file-mount-update)                                                               ; round 7
/// (deny signal (target others))
/// (deny mach-lookup … the brief's names … (global-name "com.apple.cfprefsd.agent") (global-name "com.apple.cfprefsd.daemon")
///     … (global-name "com.apple.DiskArbitration.diskarbitrationd"))                                               ; round 8
/// (deny process-exec …)
/// (allow mach-lookup (global-name "com.apple.windowserver.active") …)          ; toolchain only
/// (deny network*)
/// (allow network-outbound (remote ip "localhost:<proxyPort>"))                  ; .outbound / .loopbackListen
/// (allow network-bind network-inbound (local ip "localhost:<each port>"))       ; .loopbackListen only
/// (allow network-outbound (remote ip "localhost:<each port>"))                  ; .loopbackListen only
/// ```
///
/// Deltas from the brief, both stricter, both found by running Seatbelt:
/// - The protected rule names `file-read-data` explicitly. Seatbelt checks a rule for the specific operation before a
///   wildcard one, so `(deny file-read* …)` alone does not override the earlier `(allow file-read-data …)` of a readable
///   entry that contains the protected path: `cat` inside it still worked (`ls` did not).
/// - cfprefsd's two mach services are denied: a preference write is performed by cfprefsd outside the sandbox, so
///   `defaults write` reached the owner's `~/Library/Preferences` (other apps' settings, a persistence and code-execution
///   route). Seatbelt's `user-preference-write` operation did not stop it under `sandbox-exec`.
///
/// Every string is escaped (`quote`, `regexEscape`) and every path is resolved; paths holding characters no profile string
/// may carry are refused before rendering (`SandboxPolicyCheck`).
public enum SeatbeltProfile {
    /// Mach services no sandboxed command may look up: the Keychain, the pasteboard, screen capture, LaunchServices (`open`),
    /// Apple events (`osascript`), accessibility, TCC, and cfprefsd (preference writes land outside the sandbox).
    static let deniedServices: [(prefix: Bool, name: String)] = [
        (false, "com.apple.SecurityServer"), (false, "com.apple.securityd.xpc"), (false, "com.apple.pasteboard.1"),
        (true, "com.apple.screencapture"), (false, "com.apple.coreservices.launchservicesd"),
        (false, "com.apple.coreservices.appleevents"), (true, "com.apple.accessibility"), (false, "com.apple.tccd"),
        (false, "com.apple.cfprefsd.agent"), (false, "com.apple.cfprefsd.daemon"),
        // FSEvents could announce other processes' NSIRD_* staging names as they are created (fix round 3).
        (false, "com.apple.FSEvents"),
        // DiskArbitration mounts as root outside the sandbox for any client that can look it up: `hdiutil makehybrid` →
        // `attach -nomount` → `diskutil mount -mountPoint <dir>` laid an agent-built filesystem read-write over a data-home
        // directory the profile denies (fix round 8, probed), and a plain `hdiutil attach` auto-mounted at /Volumes. With the
        // lookup denied neither attaches or mounts anything; `file-mount` below stops a direct `mount_*`.
        (false, "com.apple.DiskArbitration.diskarbitrationd"),
    ]

    static let deniedExecutables = ["/usr/bin/osascript", "/usr/bin/open", "/bin/launchctl", "/usr/bin/security", "/usr/bin/sudo",
                                    "/usr/sbin/screencapture", "/usr/bin/crontab", "/usr/bin/at"]

    /// What a GUI app built by a check (or previewed) needs to draw.
    static let toolchainServices = ["com.apple.windowserver.active", "com.apple.CARenderServer", "com.apple.dock.server",
                                    "com.apple.fonts"]

    /// Read-only places of the toolchain under the owner's home (the home itself is otherwise unreadable).
    /// `~/Library/Caches/org.swift.swiftpm` (git mirrors of the owner's package dependencies, private ones included) is not
    /// read (fix round 3). A check that has to resolve packages through it fails; the role text tells check authors so
    /// ("resolving a package needs a cache the sandbox denies").
    static let toolchainHomeReads = ["Library/Developer", "Library/org.swift.swiftpm", ".npm"]

    /// Entries of the per-user temp dir the toolchain reads and writes (regexes after `^<T>/`, already escaped): xcrun's cache
    /// (the brief), and the item-replacement directories Foundation stages atomic writes in for the SwiftPM front ends,
    /// xcodebuild and its build service (`TemporaryItems/NSIRD_<process>_<random>`, whatever TMPDIR says). Found from the
    /// sandbox's violation log: without them `swift build` fails reading back `output-file-map.json` and xcodebuild cannot
    /// save its PIF cache. Residual: the owner's own builds by the same tools stage there too.
    static let toolchainTempEntries = ["xcrun_db", "TemporaryItems/NSIRD_(swift-(build|package|test|run)|xcodebuild|SWBBuildService)_"]

    /// Subpaths of the per-user Darwin cache (`C`) the toolchain reads: only Xcode's cached build-system specifications and
    /// plug-in cache (xcodebuild). Read-only. `C/clang` (clang's and swiftc's default implicit module cache, whose `.pcm` files
    /// embed the text of every header built there, the owner's own included) is not readable: compiler caches are
    /// redirected per run (`CLANG_MODULE_CACHE_PATH`), and `C` is never written.
    static let toolchainCacheReads = ["com.apple.DeveloperTools"]

    /// `proxyPort` is the egress proxy's port (`.outbound` and `.loopbackListen`; ignored for `.none`). `marker`, when set, is
    /// a per-run unique mach global name the profile allows (and no service answers), so the engine can recognize the run's
    /// processes afterwards by their sandbox alone (B-I4).
    public static func render(policy: SandboxPolicy, baseline: SandboxBaseline, proxyPort: UInt16?, marker: String? = nil) -> String {
        func r(_ url: URL) -> String { SandboxPath.resolve(url.path) }
        func subpath(_ p: String) -> String { "(subpath \(quote(p)))" }
        func unique(_ paths: [String]) -> [String] {
            var seen = Set<String>()
            return paths.filter { seen.insert($0).inserted }
        }
        let writable = unique(policy.writable.map(r))
        let readable = unique(policy.readable.map(r))
        let home = r(baseline.userHome)

        var lines = ["(version 1)", "(allow default)"]
        // The per-user Darwin folder (`/private/var/folders/<a>/<b>`: T, C and 0) holds the engine's and every app's
        // temporary files; it is unreadable like the home (A-I1), except the toolchain's own entries below.
        let darwinUser = baseline.darwinUserDir.map(r).map { [$0] } ?? []
        lines.append("(deny file-read-data " + (unique([home, "/Volumes"] + baseline.engineHomes.map(r) + darwinUser)).map(subpath).joined(separator: " ") + ")")

        var reads = (readable + writable).map(subpath)
        var writes: [String] = []
        if policy.toolchain {
            reads += toolchainHomeReads.map { subpath(home + "/" + $0) }
            reads.append(subpath(r(URL(fileURLWithPath: "/Applications/Xcode.app"))))
            if let cache = baseline.darwinUserCache.map(r) {
                // Read-only, narrowed to the two subpaths the toolchain needs; `C` is never written (compiler caches are
                // redirected per-run via the environment).
                reads += toolchainCacheReads.map { subpath(cache + "/" + $0) }
            }
            if let temp = baseline.darwinUserTemp.map(r) {
                // xcrun's cache, read and written; SwiftPM's atomic writes, which Foundation stages in the per-user temp
                // dir whatever TMPDIR says (`<T>/TemporaryItems/NSIRD_<process>_<random>`): only SwiftPM's own.
                let temps = toolchainTempEntries.map { "(regex #\"^\(regexEscape(temp))/\($0)\")" }
                writes.insert(contentsOf: temps, at: 0)
                reads += temps
            }
        }
        if !reads.isEmpty { lines.append("(allow file-read-data " + unique(reads).joined(separator: " ") + ")") }

        // Every company workspace the policy reads or writes nothing inside of is denied like a protected path.
        let mine = readable + writable
        let others = baseline.companyWorkspaces.map(r).filter { ws in !mine.contains { SandboxPath.isInside($0, ws) } }

        // Final review I1: in a company workspace the policy does read, its `.brahma` is read like a sandboxed turn reads it
        // (`SandboxScope.readableDotBrahma`): every other part (other agents' homes, labs and notes, extension review pages,
        // `ext-try` copies, trash, plans, the engine's own places) is unreadable, whatever exists there now or later. A policy
        // entry inside `.brahma` keeps its own reads. `.brahma` itself stays stat-able (path walks), never listable. The
        // protected denies below still win over these re-allowances.
        var hidden: [String] = [], reallowed: [String] = [], statOnly: [String] = []
        for ws in unique(baseline.companyWorkspaces.map(r)) where !others.contains(ws) {
            let dot = ws + "/.brahma"
            // Both spellings: should `.brahma` ever be a link, what it names is hidden whole (nothing is re-allowed there).
            hidden += [dot, SandboxPath.resolve(dot)]
            statOnly.append(dot)
            reallowed += SandboxScope.readableDotBrahma.map { dot + "/" + $0 }
            reallowed += mine.filter { SandboxPath.isInside($0, dot) }
        }
        if !hidden.isEmpty {
            lines.append("(deny file-read* file-read-data " + unique(hidden).map(subpath).joined(separator: " ") + ")")
            lines.append("(allow file-read-metadata " + unique(statOnly).map { "(literal \(quote($0)))" }.joined(separator: " ") + ")")
            lines.append("(allow file-read* file-read-data " + unique(reallowed).map(subpath).joined(separator: " ") + ")")
        }
        let protected = unique(baseline.protected.map(\.path) + baseline.protected.map(r) + others)
        if !protected.isEmpty { lines.append("(deny file-read* file-read-data " + protected.map(subpath).joined(separator: " ") + ")") }

        let allowedWrites = writable.map(subpath) + writes + ["(literal \"/dev/null\")", "(literal \"/dev/tty\")",
                                                             "(literal \"/dev/dtracehelper\")", "(regex #\"^/dev/fd/\")"]
        lines.append("(deny file-write* (require-not (require-any " + allowedWrites.joined(separator: " ") + ")))")
        // A hard link would give a file the command cannot read a readable name inside a writable entry, and a clone
        // (`clonefile`, `cp -c`) a single-link copy of it that passes the engine's `EngineFiles.copyProblem`. Seatbelt already
        // refuses both for a source the command may not read (probed, fix round 5); this says so explicitly. A hard link is
        // denied for every source outside the writable entries (`file-link` is checked on both of its paths; copying is for
        // `cp`). A clone is denied for every source outside what the command may read (writable, readable, the toolchain's
        // reads): cloning a readable file is no worse than copying it, and callers that clone first and fall back only on
        // specific errors (Rust's `fs::copy`) keep working (fix round 6, NB5). Links and clones inside a writable entry work.
        lines.append("(deny file-link (require-not (require-any " + writable.map(subpath).joined(separator: " ") + ")))")
        lines.append("(deny file-clone (require-not (require-any " + unique(writable.map(subpath) + reads).joined(separator: " ") + ")))")
        // Fix round 7 (S13, NB5-regression): the clone allowance is the readable entries MINUS the protected paths, the
        // other companies' workspaces and the data home, said by explicit denies after the allowance. And a directory clone
        // copies the whole hierarchy in the kernel while Seatbelt checks only its top (probed: `clonefile(R)` copied a
        // read-denied `R/prot/s`, which `cat` then printed), so a directory is clonable only from inside a writable entry,
        // which holds nothing the command may not read (`validate` keeps protected paths, other workspaces and the data
        // home's other parts out of every writable entry). A file clone from a readable entry still works (Rust's
        // `fs::copy`); `fclonefileat` on a directory descriptor is caught by the same rule (probed).
        let writableAny = "(require-any " + writable.map(subpath).joined(separator: " ") + ")"
        lines.append("(deny file-clone (require-all (vnode-type DIRECTORY) (require-not \(writableAny))))")
        // The data home's own entries in the policy keep their clone rights (fix round 8): a check's checkout inside it (it
        // clones inside itself), and a readable entry inside it (BRAHMA_WORKSPACES under BRAHMA_HOME), whose files the
        // command can read anyway. `validate` keeps every entry from containing the data home, so nothing else of it is
        // inside them; directory clones from a readable entry stay denied by the rule above, and protected paths and other
        // workspaces by the one below.
        let ownAny = "(require-any " + unique(writable + readable).map(subpath).joined(separator: " ") + ")"
        if !protected.isEmpty { lines.append("(deny file-clone " + protected.map(subpath).joined(separator: " ") + ")") }
        if !hidden.isEmpty {
            // The hidden parts of `.brahma` (I1) are not clonable either.
            lines.append("(deny file-clone (require-all (require-any " + unique(hidden).map(subpath).joined(separator: " ")
                + ") (require-not (require-any " + unique(reallowed).map(subpath).joined(separator: " ") + "))))")
        }
        let engineHomes = unique(baseline.engineHomes.map(r))
        if !engineHomes.isEmpty {
            // A check's own checkout under the data home stays clonable inside itself.
            lines.append("(deny file-clone (require-all (require-any " + engineHomes.map(subpath).joined(separator: " ") + ") (require-not \(ownAny))))")
        }
        // Mounts (fix round 7 audit, probed): `hdiutil attach -mountpoint <readable dir>` from inside the sandbox had
        // DiskArbitration (outside it) mount an agent-made image over a directory the command may only read, replacing what
        // the engine and the owner see there after the run. Seatbelt's `file-mount` check stops a `mount(2)` made inside the
        // sandbox only; DiskArbitration mounts from outside it, so its lookup is denied too (`deniedServices`, round 8).
        lines.append("(deny file-mount file-unmount file-mount-update)")
        lines.append("(deny signal (target others))")
        // A sandboxed check may not inspect other processes (open files, pid info): this stops `lsof -p <owner pid>` and the
        // like from discovering the NSIRD_* staging names and so reaching another process's in-flight atomic saves (A
        // re-review, NSIRD). It still sees its own and its children's.
        lines.append("(deny process-info* (target others))")
        lines.append("(deny mach-lookup " + deniedServices.map { "(\($0.prefix ? "global-name-prefix" : "global-name") \(quote($0.name)))" }
            .joined(separator: " ") + ")")
        lines.append("(deny process-exec " + deniedExecutables.map { "(literal \(quote($0)))" }.joined(separator: " ") + ")")
        if policy.toolchain {
            lines.append("(allow mach-lookup " + toolchainServices.map { "(global-name \(quote($0)))" }.joined(separator: " ") + ")")
        }
        // The per-run marker: a unique global name no service answers, so the engine can identify the run's processes by
        // their sandbox after the run, even one that deleted its own checkout (B-I4).
        // Under `(allow default)` any unlisted mach name is allowed, so every other run's marker is denied first: only this
        // run's own name is allowed. The probe also checks a sibling name (`marker + ".not"`) that must be denied, so a
        // foreign sandbox that allows every lookup never reads as this run's.
        if let marker {
            lines.append("(deny mach-lookup (global-name-prefix \(quote(SeatbeltRunner.markerPrefix))))")
            lines.append("(allow mach-lookup (global-name \(quote(marker))))")
        }
        lines.append("(deny network*)")
        if policy.allowedDomains != nil, let proxyPort {
            lines.append("(allow network-outbound (remote ip \(quote("localhost:\(proxyPort)"))))")
        }
        let ports = policy.loopbackPorts
        if !ports.isEmpty {
            lines.append("(allow network-bind network-inbound " + ports.map { "(local ip \(quote("localhost:\($0)")))" }.joined(separator: " ") + ")")
            lines.append("(allow network-outbound " + ports.map { "(remote ip \(quote("localhost:\($0)")))" }.joined(separator: " ") + ")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An SBPL string literal: `\` and `"` escaped, so the string can never end early.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `s` with every regex metacharacter escaped, for a `#"…"` regex literal (the path is refused if it holds `"`).
    static func regexEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\.^$|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
