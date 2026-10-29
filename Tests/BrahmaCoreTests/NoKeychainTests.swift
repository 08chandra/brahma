import Foundation
import Testing
@testable import BrahmaCore
import BrahmaKeychain

/// The login Keychain prompts for a password on every access from a freshly built, ad-hoc-signed binary, so a test
/// run must never touch it. Three layers, none relying on test order:
///  1. `tempDir()` arms `KeychainAccessLog.forbid()`: any Keychain call later in the process crashes the run.
///  2. A process-wide counter of every Security call, asserted to be 0 here (catches calls made before arming).
///  3. A source scan: only `LiveKeychainTests.swift` (disabled unless `BRAHMA_LIVE_KEYCHAIN=1`) may use the Keychain
///     stores (the owner-key store and the secrets vault) or the live secret-store selection; every CLI subprocess helper
///     (checked helper by helper, not file by file) must use the file stores for both.
///  4. BrahmaCore holds no Keychain code at all: every Security call lives in BrahmaKeychain, behind `KeychainAccessLog`.
///     The secrets vault the engine, `brahma mcp` and tests get is injected; library defaults are `UnavailableVault`.
@Suite(.scratch) struct NoKeychainTests {
    /// True for the deliberate `BRAHMA_LIVE_KEYCHAIN=1` run, which is allowed to touch the Keychain.
    private static let live = ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1"

    @Test(.enabled(if: !NoKeychainTests.live, "live Keychain run"))
    func thisTestRunMadeNoSecurityCalls() throws {
        _ = try tempDir()
        #expect(keychainTrapArmed)
        #expect(KeychainAccessLog.callCount == 0)
    }

    @Test func onlyTheLiveSuiteUsesTheKeychainStore() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let needles = ["KeychainOwnerKeyStore", "PlatformOwnerKeyStore.make", "import Security", "SecItem",
                       "KeychainVault", "PlatformSecretVault.resolve(paths", "SecAccess", "SecTrustedApplication", "SecKeychain"]
        let allowed: Set<String> = ["LiveKeychainTests.swift", "NoKeychainTests.swift", "OwnerKeyTests.swift"]
        var offenders: [String] = []
        for case let file as URL in try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)) {
            guard file.pathExtension == "swift", !allowed.contains(file.lastPathComponent) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if needles.contains(where: text.contains) { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "tests must use InMemoryOwnerKeyStore/HomeFileOwnerKeyStore and MemoryVault/FileVault: \(offenders)")
        // OwnerKeyTests may only name the type to assert the default selection, never construct it or call Security.
        let ownerTests = try String(contentsOf: tests.appending(path: "BrahmaCoreTests/OwnerKeyTests.swift"), encoding: .utf8)
        #expect(!ownerTests.contains("KeychainOwnerKeyStore()"))
        #expect(!ownerTests.contains("SecItem"))
    }

    @Test func everyCLISubprocessHelperUsesTheFileStore() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var checked = 0
        for case let file as URL in try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)) {
            guard file.pathExtension == "swift", file.lastPathComponent != "NoKeychainTests.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for helper in Self.topLevelDeclarations(text) where helper.contains("brahmaExecutableURL()") {
                // The definition of `brahmaExecutableURL` itself is not a launcher.
                if helper.contains("func brahmaExecutableURL()") { continue }
                checked += 1
                // Helpers build the environment with `cliEnvironment` (file store); TestSupport defines it.
                #expect(helper.contains("cliEnvironment(home:"),
                        "a helper in \(file.lastPathComponent) launches brahma without BRAHMA_OWNER_KEY_STORE=file:\n\(helper.prefix(120))")
            }
        }
        #expect(checked >= 4)
        let support = try String(contentsOf: tests.appending(path: "TestSupport.swift"), encoding: .utf8)
        #expect(support.contains("\"BRAHMA_OWNER_KEY_STORE\": \"file\""))
        #expect(support.contains("\"BRAHMA_SECRET_STORE\": \"file\""))
        // The environment the helpers use can never select the Keychain vault.
        let home = try tempDir()
        let env = cliEnvironment(home: home)
        let selection = try PlatformSecretVault.resolve(environment: env, paths: BrahmaPaths.from(environment: env))
        #expect(selection.kind == .file); #expect(selection.vault is FileVault)
    }

    @Test func brahmaCoreHasNoKeychainCode() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/BrahmaCore")
        var offenders: [String] = []
        var scanned = 0
        for case let file as URL in try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)) {
            guard file.pathExtension == "swift" else { continue }
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in ["import Security", "SecItem", "SecKeychain", "SecAccessCreate", "SecTrustedApplication", "KeychainVault"]
            where text.contains(needle) { offenders.append("\(file.lastPathComponent): \(needle)") }
        }
        #expect(scanned > 50)
        #expect(offenders.isEmpty, "Keychain code belongs in BrahmaKeychain, behind KeychainAccessLog: \(offenders)")
    }

    @Test func libraryDefaultsNeverSelectTheKeychainVault() throws {
        // The Orchestrator's default vault (no argument) and World's are in-memory, never the Keychain.
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let plain = Orchestrator(store: try Store.inMemory(), runner: FakeTurnRunner(), paths: paths, mcpExecutable: "/x/brahma")
        #expect(plain.vault is UnavailableVault)
        #expect(try World().orchestrator.vault is MemoryVault)
    }

    @Test func theScanSeesAHelperThatForgetsTheFileStore() {
        // A file with one good and one bad helper must be caught: a per-file `contains` would pass it.
        let source = """
        func good() { let url = brahmaExecutableURL(); p.environment = cliEnvironment(home: home) }
        func bad() { let url = brahmaExecutableURL(); p.environment = [:] }
        """
        let bad = Self.topLevelDeclarations(source).filter { $0.contains("brahmaExecutableURL()") && !$0.contains("cliEnvironment(home:") }
        #expect(bad.count == 1)
    }

    /// Splits Swift source at lines that start in column 0 with something other than a comment, brace or blank.
    static func topLevelDeclarations(_ text: String) -> [String] {
        var chunks: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, !first.isWhitespace, first != "}", first != "/", !current.isEmpty {
                chunks.append(current.joined(separator: "\n")); current = []
            }
            current.append(line)
        }
        chunks.append(current.joined(separator: "\n"))
        return chunks
    }
}
