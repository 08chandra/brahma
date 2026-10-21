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

    @Test func ensureCreatesOnlyWhenMissing() throws {
        let p = try paths(); let store = InMemoryOwnerKeyStore()
        #expect(try OwnerKey.ensure(paths: p, store: store) != nil)
        let first = try String(contentsOf: OwnerKey.url(paths: p), encoding: .utf8)
        #expect(try OwnerKey.ensure(paths: p, store: store) != nil)
        #expect(try String(contentsOf: OwnerKey.url(paths: p), encoding: .utf8) == first)
        // An existing key that fails to verify is never silently replaced.
        store.removeHash(for: p)
        #expect(try OwnerKey.ensure(paths: p, store: store) == nil)
        #expect(try String(contentsOf: OwnerKey.url(paths: p), encoding: .utf8) == first)
        #expect(!OwnerKey.verify(paths: p, store: store))
    }

    @Test func symlinkedHomeResolvesToSameItem() throws {
        let d = try tempDir()
        let real = d.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = d.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let viaReal = BrahmaPaths(home: real, workspaces: d.appending(path: "ws"))
        let viaLink = BrahmaPaths(home: link, workspaces: d.appending(path: "ws"))
        #expect(viaReal.canonicalHomePath == viaLink.canonicalHomePath)
        #expect(BrahmaPaths.canonicalPath(link.appending(path: "not/yet").path) == viaReal.canonicalHomePath + "/not/yet")
        for store in [InMemoryOwnerKeyStore() as any OwnerKeyStore, FileOwnerKeyStore(directory: d.appending(path: "cfg")),
                      KeychainOwnerKeyStore()] {
            defer { store.removeHash(for: viaReal) }
            try OwnerKey.create(paths: viaReal, store: store)
            #expect(OwnerKey.verify(paths: viaLink, store: store), "\(type(of: store))")
            #expect(store.hash(for: viaLink) == store.hash(for: viaReal))
            store.removeHash(for: viaLink)
            #expect(store.hash(for: viaReal) == nil)
            try? FileManager.default.removeItem(at: OwnerKey.url(paths: viaReal))
        }
    }

    @Test func symlinkedDBRefused() throws {
        let p = try paths()
        try FileManager.default.createDirectory(at: p.home, withIntermediateDirectories: true)
        #expect(OwnerKey.databaseIsInsideHome(paths: p), "a database that doesn't exist yet is fine")
        try Data("x".utf8).write(to: p.database)
        #expect(OwnerKey.databaseIsInsideHome(paths: p))
        let elsewhere = try tempDir().appending(path: "other.sqlite")
        try Data("y".utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: p.database)
        try FileManager.default.createSymbolicLink(at: p.database, withDestinationURL: elsewhere)
        #expect(!OwnerKey.databaseIsInsideHome(paths: p))
        // A symlink that stays inside the home is still a symlink.
        let inside = p.home.appending(path: "real.sqlite")
        try Data("z".utf8).write(to: inside)
        try FileManager.default.removeItem(at: p.database)
        try FileManager.default.createSymbolicLink(at: p.database, withDestinationURL: inside)
        #expect(!OwnerKey.databaseIsInsideHome(paths: p))
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
