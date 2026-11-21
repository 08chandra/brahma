import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan C Task C2a: the vault beside ML's `ContentVault` (snapshots, the diff cache, temp copies), its modes and its hash check.
@Suite(.scratch) struct VaultTests {
    static func paths() throws -> BrahmaPaths {
        let root = try tempDir()
        return BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
    }

    static func mode(_ url: URL) -> mode_t {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return st.st_mode & 0o7777
    }

    @Test func writeIsReadOnlyAndHashed() throws {
        let paths = try Self.paths()
        let vault = Vault(paths: paths, companyId: "c1", content: ContentVault(paths: paths))
        #expect(vault.root == paths.vaultDir(companyId: "c1"))
        let bytes = Data("diff --git a/x b/x\n+one\n".utf8)
        let written = try vault.write(bytes, area: .snapshots, name: "s1.patch")
        #expect(written.path == "snapshots/s1.patch")
        #expect(written.sha256 == SHA256.hex(bytes))
        let file = vault.root.appending(path: "snapshots/s1.patch")
        #expect(Self.mode(file) == 0o444)
        #expect(Self.mode(vault.root.appending(path: "snapshots", directoryHint: .isDirectory)) == 0o700)
        #expect(Self.mode(vault.root) == 0o700)
        #expect(try vault.read(written.path, sha256: written.sha256, maxBytes: 1 << 20) == bytes)
        // The same name is never written twice.
        #expect(throws: (any Error).self) { try vault.write(bytes, area: .snapshots, name: "s1.patch") }
        // Names are one engine-chosen component.
        for bad in ["../x", "a/b", "", ".", "..", "x\u{0}y"] {
            #expect(throws: (any Error).self) { try vault.write(bytes, area: .diffcache, name: bad) }
        }
        // A flipped byte on disk fails the read.
        #expect(chmod(file.path, 0o644) == 0)
        var tampered = bytes
        tampered[0] ^= 0x01
        try tampered.write(to: file)
        #expect(throws: VaultError.hashMismatch) { try vault.read(written.path, sha256: written.sha256, maxBytes: 1 << 20) }
        // A missing file is `.missing`; a file over the cap is a mismatch.
        #expect(throws: VaultError.missing) { try vault.read("diffcache/none.patch", sha256: written.sha256, maxBytes: 100) }
        let big = try vault.write(Data(repeating: 0x61, count: 64), area: .diffcache, name: "big.patch")
        #expect(throws: VaultError.hashMismatch) { try vault.read(big.path, sha256: big.sha256, maxBytes: 10) }
        // A linked file is never read through.
        let other = try tempDir().appending(path: "secret.txt")
        try Data("owner secret".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: vault.root.appending(path: "diffcache/link.patch"), withDestinationURL: other)
        #expect(throws: VaultError.hashMismatch) {
            try vault.read("diffcache/link.patch", sha256: SHA256.hex(Data("owner secret".utf8)), maxBytes: 100)
        }
    }

    @Test func resourcesLandWhereContentVaultReadsThem() throws {
        let paths = try Self.paths()
        let content = ContentVault(paths: paths)
        let vault = Vault(paths: paths, companyId: "c1", content: content)
        let bytes = Data("# Brief\n".utf8)
        let written = try vault.write(bytes, area: .resources, name: "F-7.md")
        #expect(written.path == "resources/F-7.md")
        #expect(try content.read(companyId: "c1", relativePath: written.path, expectedSHA256: written.sha256, maxBytes: 100) == bytes)
        #expect(try vault.read(written.path, sha256: written.sha256, maxBytes: 100) == bytes)
        #expect(Self.mode(vault.root.appending(path: "resources/F-7.md")) == 0o444)
        // The resources area takes only ML's names.
        #expect(throws: (any Error).self) { try vault.write(bytes, area: .resources, name: "notes.md") }
        #expect(throws: VaultError.hashMismatch) { try vault.read(written.path, sha256: SHA256.hex(Data("x".utf8)), maxBytes: 100) }
        try vault.remove(written.path)
        #expect(throws: VaultError.missing) { try vault.read(written.path, sha256: written.sha256, maxBytes: 100) }
    }

    @Test func tempDirsArePrivate() throws {
        let paths = try Self.paths()
        let vault = Vault(paths: paths, companyId: "c1", content: ContentVault(paths: paths))
        let a = try vault.makeTempDir(), b = try vault.makeTempDir()
        #expect(a != b)
        #expect(a.deletingLastPathComponent().standardizedFileURL.path == paths.tmpDir.standardizedFileURL.path)
        #expect(Self.mode(a) == 0o700)
    }

    /// Live: a sandboxed command can't read a vault file (the data home is denied), and the token never appears.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1" && Toolchain.seatbeltAvailable))
    func vaultNotReadableFromSandbox() async throws {
        let paths = try Self.paths()
        let vault = Vault(paths: paths, companyId: "c1", content: ContentVault(paths: paths))
        let token = "BRAHMA-VAULT-TOKEN-\(UUID().uuidString)"
        let written = try vault.write(Data(token.utf8), area: .snapshots, name: "canary.patch")
        let file = vault.root.appending(path: written.path).resolvedForSandbox
        let baseline = SandboxBaseline.current(paths: paths, otherWorkspaces: [], backupTargets: [])
        let runner = SeatbeltRunner(baseline: { baseline }, proxies: EgressProxyPool())
        let item = await SandboxCanary.backendItem(token: file, secret: token, sandbox: runner)
        #expect(item.status == .pass, "\(item.detail)")
        #expect(!item.detail.contains(token))
    }
}
