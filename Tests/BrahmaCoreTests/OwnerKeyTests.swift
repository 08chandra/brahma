import Foundation
import Testing
@testable import BrahmaCore
import BrahmaKeychain

private func paths() throws -> BrahmaPaths {
    let d = try tempDir()
    return BrahmaPaths(home: d.appending(path: "home"), workspaces: d.appending(path: "ws"))
}

@Suite struct OwnerKeyTests {
    @Test func validKeyAccepted() throws {
        let p = try paths(); let store = InMemoryOwnerKeyStore()
        #expect(!OwnerKey.verify(paths: p, store: store))
        try OwnerKey.create(paths: p, store: store)
        #expect(OwnerKey.verify(paths: p, store: store))
        let attrs = try FileManager.default.attributesOfItem(atPath: OwnerKey.url(paths: p).path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect(store.hash(for: p)?.count == 64)
    }

    @Test func wrongKeyContentRefused() throws {
        let p = try paths(); let store = InMemoryOwnerKeyStore()
        try OwnerKey.create(paths: p, store: store)
        try Data("not the key\n".utf8).write(to: OwnerKey.url(paths: p))
        #expect(!OwnerKey.verify(paths: p, store: store))
        try Data("\n".utf8).write(to: OwnerKey.url(paths: p))
        #expect(!OwnerKey.verify(paths: p, store: store))
    }

    @Test func missingStoredHashRefused() throws {
        let p = try paths(); let store = InMemoryOwnerKeyStore()
        try OwnerKey.create(paths: p, store: store)
        store.removeHash(for: p)
        #expect(!OwnerKey.verify(paths: p, store: store))
        // A key file with no hash anywhere (someone created only the file) is refused as well.
        let q = try paths()
        try FileManager.default.createDirectory(at: q.home, withIntermediateDirectories: true)
        try Data("abc\n".utf8).write(to: OwnerKey.url(paths: q))
        #expect(!OwnerKey.verify(paths: q, store: InMemoryOwnerKeyStore()))
    }

    @Test func createRefusesExistingUnlessRotated() throws {
        let p = try paths(); let store = InMemoryOwnerKeyStore()
        try OwnerKey.create(paths: p, store: store)
        let first = try String(contentsOf: OwnerKey.url(paths: p), encoding: .utf8)
        #expect(throws: OwnerKeyError.alreadyExists) { try OwnerKey.create(paths: p, store: store) }
        try OwnerKey.create(paths: p, store: store, rotate: true)
        #expect(try String(contentsOf: OwnerKey.url(paths: p), encoding: .utf8) != first)
        #expect(OwnerKey.verify(paths: p, store: store))
    }

    @Test func ensureKeepsValidAndRepairsInvalid() throws {
        let p = try paths(); let store = InMemoryOwnerKeyStore()
        try OwnerKey.ensure(paths: p, store: store)
        let first = try String(contentsOf: OwnerKey.url(paths: p), encoding: .utf8)
        try OwnerKey.ensure(paths: p, store: store)
        #expect(try String(contentsOf: OwnerKey.url(paths: p), encoding: .utf8) == first)
        store.removeHash(for: p)
        try OwnerKey.ensure(paths: p, store: store)
        #expect(OwnerKey.verify(paths: p, store: store))
    }

    @Test func constantTimeCompare() {
        #expect(OwnerKey.constantTimeEqual("abc", "abc")); #expect(!OwnerKey.constantTimeEqual("abc", "abd"))
        #expect(!OwnerKey.constantTimeEqual("abc", "abcd")); #expect(!OwnerKey.constantTimeEqual("", "a"))
        #expect(OwnerKey.constantTimeEqual("", ""))
    }

    @Test func fileStoreRoundTripIs0600() throws {
        let p = try paths(); let dir = try tempDir().appending(path: "cfg")
        let store = FileOwnerKeyStore(directory: dir)
        #expect(store.hash(for: p) == nil)
        try store.setHash("deadbeef", for: p)
        #expect(store.hash(for: p) == "deadbeef")
        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        store.removeHash(for: p)
        #expect(store.hash(for: p) == nil)
    }

    @Test func keychainStoreRoundTrip() throws {
        let p = try paths(); let store = KeychainOwnerKeyStore()
        defer { store.removeHash(for: p) }
        #expect(store.hash(for: p) == nil)
        try store.setHash("h1", for: p)
        try store.setHash("h2", for: p)
        #expect(store.hash(for: p) == "h2")
        store.removeHash(for: p)
        #expect(store.hash(for: p) == nil)
    }
}
