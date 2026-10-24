import Foundation

/// The Seatbelt (SBPL) profile of one sandboxed command. Rule order, as the brief pins it (two deliberate deltas below):
///
/// ```
/// (version 1)
/// (allow default)
/// (deny file-read-data (subpath "<userHome>") (subpath "/Volumes") (subpath "<each engine home>"))
/// (allow file-read-data (subpath "<each readable + writable>") <toolchain reads>)
/// (deny file-read* file-read-data (subpath "<each protected>") (subpath "<each other company workspace>"))
/// (deny file-write* (require-not (require-any (subpath "<each writable>") <toolchain writes>
///     (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper") (regex #"^/dev/fd/"))))
/// (deny signal (target others))
/// (deny mach-lookup … the brief's names … (global-name "com.apple.cfprefsd.agent") (global-name "com.apple.cfprefsd.daemon"))
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
    ]

    static let deniedExecutables = ["/usr/bin/osascript", "/usr/bin/open", "/bin/launchctl", "/usr/bin/security", "/usr/bin/sudo",
                                    "/usr/sbin/screencapture", "/usr/bin/crontab", "/usr/bin/at"]

    /// What a GUI app built by a check (or previewed) needs to draw.
    static let toolchainServices = ["com.apple.windowserver.active", "com.apple.CARenderServer", "com.apple.dock.server",
                                    "com.apple.fonts"]

    /// Read-only places of the toolchain under the owner's home (the home itself is otherwise unreadable).
    static let toolchainHomeReads = ["Library/Developer", "Library/Caches/org.swift.swiftpm", "Library/org.swift.swiftpm", ".npm"]

    /// Entries of the per-user temp dir the toolchain reads and writes (regexes after `^<T>/`, already escaped): xcrun's cache
    /// (the brief), and the item-replacement directories Foundation stages atomic writes in for the SwiftPM front ends,
    /// xcodebuild and its build service (`TemporaryItems/NSIRD_<process>_<random>`, whatever TMPDIR says). Found from the
    /// sandbox's violation log: without them `swift build` fails reading back `output-file-map.json` and xcodebuild cannot
    /// save its PIF cache. Residual: the owner's own builds by the same tools stage there too.
    static let toolchainTempEntries = ["xcrun_db", "TemporaryItems/NSIRD_(swift-(build|package|test|run)|xcodebuild|SWBBuildService)_"]

    /// `proxyPort` is the egress proxy's port (`.outbound` and `.loopbackListen`; ignored for `.none`).
    public static func render(policy: SandboxPolicy, baseline: SandboxBaseline, proxyPort: UInt16?) -> String {
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
                reads.append(subpath(cache))
                writes += [subpath(cache + "/clang"), subpath(cache + "/com.apple.DeveloperTools"),
                           "(regex #\"^\(regexEscape(cache))/org\\.llvm\\.clang\")", subpath(cache + "/org.swift.swiftpm")]
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
        let protected = unique(baseline.protected.map(\.path) + baseline.protected.map(r) + others)
        if !protected.isEmpty { lines.append("(deny file-read* file-read-data " + protected.map(subpath).joined(separator: " ") + ")") }

        let allowedWrites = writable.map(subpath) + writes + ["(literal \"/dev/null\")", "(literal \"/dev/tty\")",
                                                             "(literal \"/dev/dtracehelper\")", "(regex #\"^/dev/fd/\")"]
        lines.append("(deny file-write* (require-not (require-any " + allowedWrites.joined(separator: " ") + ")))")
        lines.append("(deny signal (target others))")
        lines.append("(deny mach-lookup " + deniedServices.map { "(\($0.prefix ? "global-name-prefix" : "global-name") \(quote($0.name)))" }
            .joined(separator: " ") + ")")
        lines.append("(deny process-exec " + deniedExecutables.map { "(literal \(quote($0)))" }.joined(separator: " ") + ")")
        if policy.toolchain {
            lines.append("(allow mach-lookup " + toolchainServices.map { "(global-name \(quote($0)))" }.joined(separator: " ") + ")")
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
