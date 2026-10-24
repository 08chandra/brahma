import Foundation
import Testing
@testable import BrahmaCore
@testable import BrahmaKeychain

/// The secret store choice (`PlatformSecretVault`), the dev/demo `FileVault`, and the trusted-application list the
/// Keychain vault's access control is built from. Nothing here touches the Keychain (`NoKeychainTests` checks).
@Suite struct SecretStoreTests {
    private func paths() throws -> BrahmaPaths {
        let d = try tempDir()
        return BrahmaPaths(home: d.appending(path: "home"), workspaces: d.appending(path: "ws"))
    }

    // MARK: selection

    @Test func selectionHonoursFileAndMemoryOnlyForANonDefaultHome() throws {
        let p = try paths()
        let elsewhere = try tempDir().appending(path: "default-home")
        let file = try PlatformSecretVault.resolve(environment: ["BRAHMA_SECRET_STORE": "file"], paths: p, defaultHome: elsewhere)
        #expect(file.kind == .file); #expect(file.vault is FileVault)
        #expect(file.warning == "using a file-backed secret store (dev/demo home only)")
        let memory = try PlatformSecretVault.resolve(environment: ["BRAHMA_SECRET_STORE": "memory"], paths: p, defaultHome: elsewhere)
        #expect(memory.kind == .memory); #expect(memory.vault is MemoryVault); #expect(memory.warning?.contains("in-memory") == true)
        // Unset: the platform store (constructing it touches nothing; NoKeychainTests counts the calls).
        let platform = try PlatformSecretVault.resolve(environment: [:], paths: p, defaultHome: elsewhere)
        #expect(platform.warning == nil)
        #if canImport(Security)
        #expect(platform.kind == .keychain)
        #else
        #expect(platform.kind == .unavailable)
        #endif
    }

    @Test func selectionRefusesTheDefaultHomeAndUnknownValues() throws {
        let p = try paths()
        for value in ["file", "memory"] {
            #expect(throws: PlatformSecretVault.Refusal.self) {
                _ = try PlatformSecretVault.resolve(environment: ["BRAHMA_SECRET_STORE": value], paths: p, defaultHome: p.home)
            }
        }
        do {
            _ = try PlatformSecretVault.resolve(environment: ["BRAHMA_SECRET_STORE": "file"], paths: p, defaultHome: p.home)
        } catch let r as PlatformSecretVault.Refusal {
            #expect(r.description.contains("refusing for the default data home"))
        }
        for value in ["", "keychain", "plaintext", "FILE"] {
            #expect(throws: PlatformSecretVault.Refusal.self) {
                _ = try PlatformSecretVault.resolve(environment: ["BRAHMA_SECRET_STORE": value], paths: p, defaultHome: try tempDir())
            }
        }
    }

    @Test func selectionCarriesTheInteractiveFlag() throws {
        let p = try paths()
        let elsewhere = try tempDir()
        #expect(try PlatformSecretVault.resolve(environment: [:], paths: p, defaultHome: elsewhere).interactive == false)
        #expect(try PlatformSecretVault.resolve(environment: [:], paths: p, defaultHome: elsewhere, interactive: true).interactive)
    }

    @Test func mcpConfigForwardsOnlyTheFileStore() throws {
        let p = try paths()
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let agent = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        func env(_ e: [String: String]) throws -> [String: String] {
            let path = try MCPConfig.write(paths: p, executable: "/x/brahma", agent: agent, turnToken: "tok", environment: e)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
            let server = ((json?["mcpServers"] as? [String: Any])?["company"] as? [String: Any])
            return server?["env"] as? [String: String] ?? [:]
        }
        #expect(try env(["BRAHMA_SECRET_STORE": "file"]) == ["BRAHMA_TURN_TOKEN": "tok", "BRAHMA_SECRET_STORE": "file"])
        #expect(try env(["BRAHMA_SECRET_STORE": "memory"]) == ["BRAHMA_TURN_TOKEN": "tok"])
        #expect(try env([:]) == ["BRAHMA_TURN_TOKEN": "tok"])
    }

    // MARK: FileVault

    @Test func fileVaultRoundTripsWithPrivatePermissions() throws {
        let home = try tempDir().appending(path: "home")
        let v = FileVault(home: home)
        #expect(try v.value(companyId: "c1", name: "A_KEY") == nil)   // no file yet
        try v.set(companyId: "c1", name: "A_KEY", value: "first-value \"q\" ü")
        try v.set(companyId: "c2", name: "A_KEY", value: "other")
        #expect(try v.value(companyId: "c1", name: "A_KEY") == "first-value \"q\" ü")
        try v.set(companyId: "c1", name: "A_KEY", value: "second")
        #expect(try FileVault(home: home).value(companyId: "c1", name: "A_KEY") == "second")   // another process sees it
        let dir = home.appending(path: "secrets"), file = dir.appending(path: "vault.json")
        #expect((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // No leftover temp files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["vault.json", "vault.lock"])
        try v.delete(companyId: "c1", name: "A_KEY")
        try v.delete(companyId: "c1", name: "A_KEY")
        #expect(try v.value(companyId: "c1", name: "A_KEY") == nil); #expect(try v.value(companyId: "c2", name: "A_KEY") == "other")
    }

    @Test func fileVaultRefusesSymlinks() throws {
        let root = try tempDir()
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let decoy = root.appending(path: "decoy.json")
        try Data("{}".utf8).write(to: decoy)
        try FileManager.default.createDirectory(at: home.appending(path: "secrets"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "secrets/vault.json"), withDestinationURL: decoy)
        let v = FileVault(home: home)
        #expect(throws: (any Error).self) { _ = try v.value(companyId: "c", name: "A_KEY") }
        #expect(throws: (any Error).self) { try v.set(companyId: "c", name: "A_KEY", value: "value-value") }
        #expect(try String(contentsOf: decoy, encoding: .utf8) == "{}")
        // A symlinked secrets directory is refused too.
        let home2 = root.appending(path: "home2")
        try FileManager.default.createDirectory(at: home2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home2.appending(path: "secrets"), withDestinationURL: root.appending(path: "elsewhere"))
        #expect(throws: (any Error).self) { try FileVault(home: home2).set(companyId: "c", name: "A_KEY", value: "value-value") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "elsewhere").path).isEmpty)
    }

    // MARK: trusted applications (F1)

    private let app = "/Applications/Brahma.app/Contents/MacOS/Brahma"
    private let helper = "/Applications/Brahma.app/Contents/Helpers/brahma"

    @Test func trustedListNamesOnlyTheRunningBinaryAndItsSibling() {
        let both: (String) -> Bool = { [app, helper].contains($0) }
        // The bundled CLI trusts itself and the app executable of its own bundle; the app trusts itself and its bundled CLI.
        #expect(KeychainTrust.trustedApplicationPaths(executable: helper, isExecutable: both) == [helper, app])
        #expect(KeychainTrust.trustedApplicationPaths(executable: app, isExecutable: both) == [app, helper])
        // A SwiftPM build: the CLI and the app executable side by side (ToolLocator's sibling rule).
        let cli = "/src/.build/debug/brahma", appExe = "/src/.build/debug/BrahmaApp"
        #expect(KeychainTrust.trustedApplicationPaths(executable: cli, isExecutable: { [cli, appExe].contains($0) }) == [cli, appExe])
        #expect(KeychainTrust.trustedApplicationPaths(executable: appExe, isExecutable: { [cli, appExe].contains($0) }) == [appExe, cli])
        // An app with no bundled helper falls back to a `brahma` beside its executable, as ToolLocator does.
        let bareApp = "/x/Brahma.app/Contents/MacOS/Brahma", besideApp = "/x/Brahma.app/Contents/MacOS/brahma"
        #expect(KeychainTrust.trustedApplicationPaths(executable: bareApp, isExecutable: { [bareApp, besideApp].contains($0) })
                == [bareApp, besideApp])
        // A missing sibling is not listed; the running binary always is. Nothing else is ever added (no installed app).
        #expect(KeychainTrust.trustedApplicationPaths(executable: cli, isExecutable: { _ in false }) == [cli])
        #expect(KeychainTrust.trustedApplicationPaths(executable: cli, isExecutable: { _ in true }) == [cli, appExe])
    }

    @Test func trustedListIsNeverEmptyAndNeverTheSecurityTool() {
        // `/usr/bin/security` is never trusted, whatever the running binary or its neighbours are.
        #expect(KeychainTrust.trustedApplicationPaths(executable: "/usr/bin/security", isExecutable: { _ in true }).isEmpty)
        let inUsrBin = KeychainTrust.trustedApplicationPaths(executable: "/usr/bin/brahma", isExecutable: { _ in true })
        #expect(inUsrBin == ["/usr/bin/brahma", "/usr/bin/BrahmaApp"]); #expect(!inUsrBin.contains("/usr/bin/security"))
        // An unknown program gets no sibling at all.
        #expect(KeychainTrust.trustedApplicationPaths(executable: "/opt/tool/xctest", isExecutable: { _ in true }) == ["/opt/tool/xctest"])
        #expect(KeychainTrust.trustedApplicationPaths(executable: "", isExecutable: { _ in true }).isEmpty)
        #expect(KeychainTrust.trustedApplicationPaths(executable: "relative/brahma", isExecutable: { _ in true }).isEmpty)
        // The live list for this (test) process: the real path of the running executable first, never security, no duplicates.
        let live = KeychainTrust.trustedApplicationPaths()
        let exe = KeychainTrust.currentExecutablePath()
        #expect(exe != nil)
        #expect(live.first == exe)
        #expect(exe == exe.flatMap { KeychainTrust.realPath($0) })
        #expect(!live.contains("/usr/bin/security")); #expect(Set(live).count == live.count)
        #expect(!live.isEmpty)
    }

    @Test func siblingPathsAreResolvedToRealPaths() throws {
        // A symlinked CLI (for example /usr/local/bin/brahma -> the app's helper) resolves to the helper inside the bundle.
        let root = try tempDir()
        let bundle = root.appending(path: "Brahma.app/Contents")
        try FileManager.default.createDirectory(at: bundle.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appending(path: "Helpers"), withIntermediateDirectories: true)
        for exe in [bundle.appending(path: "MacOS/Brahma"), bundle.appending(path: "Helpers/brahma")] {
            try Data("#!/bin/sh\n".utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        }
        let link = root.appending(path: "brahma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle.appending(path: "Helpers/brahma"))
        let real = { (p: String) in KeychainTrust.realPath(p) ?? "unresolved \(p)" }
        let list = KeychainTrust.trustedApplicationPaths(executable: KeychainTrust.realPath(link.path) ?? "")
        #expect(list == [real(bundle.appending(path: "Helpers/brahma").path), real(bundle.appending(path: "MacOS/Brahma").path)])
    }
}
