import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A file-backed store on a throwaway data home (`<root>/home`), the way the CLI and the app open it.
struct BackupEnv {
    let root: URL
    let paths: BrahmaPaths
    let store: Store

    init() throws {
        root = try tempDir()
        paths = ownerPaths(root)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
    }

    /// A service whose clock steps one second per call, so snapshots in a loop get distinct names.
    func service(start: Date = Date(timeIntervalSince1970: 1_781_107_200)) -> BackupService {
        var service = BackupService(paths: paths, writer: store.writer)
        let clock = StepClock(start)
        service.now = { clock.next() }
        return service
    }

    func company(_ name: String = "Acme") throws -> Company {
        try store.createCompany(name: name, goal: "Ship it", workspacesRoot: paths.workspaces)
    }

    @discardableResult
    func post(_ company: Company, _ text: String) throws -> Message {
        try MessageRouter(store: store).post(companyId: company.id, channel: "general", from: .owner, text: text)
    }

    func companyNames(in file: URL) throws -> [String] {
        let queue = try BackupService.openForReading(file)
        defer { try? queue.close() }
        return try queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM company ORDER BY name") }
    }

    /// Plain git in a company's workspace: commits a file on `main`.
    @discardableResult
    func commit(_ company: Company, file: String, text: String) throws -> String {
        let fixture = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        try fixture.write(file, text)
        try fixture.git(["add", "-A"])
        try fixture.git(["commit", "-m", "add \(file)"])
        return try fixture.git(["rev-parse", "HEAD"])
    }

    func mainHead(_ company: Company) throws -> String {
        try GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true)).git(["rev-parse", "refs/heads/main"])
    }
}

final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    func next() -> Date { lock.withLock { defer { value = value.addingTimeInterval(1) }; return value } }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    private var count = 0
    func mark() { lock.withLock { set = true; count += 1 } }
    var isSet: Bool { lock.withLock { set } }
    var calls: Int { lock.withLock { count } }
}
