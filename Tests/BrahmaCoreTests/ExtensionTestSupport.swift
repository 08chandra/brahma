import Testing
import Foundation
import GRDB
@testable import BrahmaCore

// Shared fixtures for the extension suites (Task 5a): a plugin folder on disk, and a World with a company and an engineer.

/// A Claude Code plugin folder under the test's scratch dir.
struct PluginFixture {
    let root: URL

    /// A minimal valid skill-only extension: the 4-key manifest and one skill. `manifest` replaces the manifest text
    /// (nil: the 4-key one); `files` are written relative to the plugin root.
    init(id: String = "demo", manifest: String? = nil, files: [String: String] = [:], withSkill: Bool = true, under: URL? = nil) throws {
        root = try (under ?? tempDir()).appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(".claude-plugin/plugin.json", manifest ?? PluginFixture.manifestJSON(id: id))
        if withSkill { try write("skills/\(id)/SKILL.md", PluginFixture.skillMD(name: id)) }
        for (path, text) in files { try write(path, text) }
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func writeBytes(_ path: String, _ bytes: [UInt8]) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    /// A text helper in `bin/`, executable (its mode is the fixture: the validator checks it).
    @discardableResult
    func bin(_ name: String, _ body: String = "echo hi") throws -> URL {
        let url = try write("bin/\(name)", "#!/bin/sh\n\(body)\n")
        try FakeTools.fixtureMode(0o755, at: url)
        return url
    }

    func read(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path) }

    static func manifestJSON(id: String, extra: String = "") -> String {
        """
        {"name": "\(id)", "version": "1.0.0", "description": "A demo skill for tests.", "author": {"name": "Tests"}\(extra)}
        """
    }

    static func skillMD(name: String, frontmatter extra: String = "", body: String = "1. Do the thing.\n") -> String {
        """
        ---
        name: \(name)
        description: Demo skill: use it for demos.
        when_to_use: When a demo is needed.
        \(extra.isEmpty ? "" : extra + "\n")---
        # \(name)

        \(body)
        """
    }

    static func agentMD(name: String, frontmatter extra: String = "") -> String {
        """
        ---
        name: \(name)
        description: A helper agent.
        \(extra.isEmpty ? "" : extra + "\n")---
        You help.
        """
    }
}

/// A sandboxed company with an engineer, for the install pipeline and mount tests.
struct ExtWorld {
    let world: World
    let company: Company
    let eng: Agent

    init(profile: PermissionProfile = .sandboxed) throws {
        world = try World()
        company = try world.company("Acme", profile: profile)
        eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
    }

    var store: Store { world.store }
    var paths: BrahmaPaths { world.paths }
    var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: false) }

    func stage(_ fixture: PluginFixture) async throws -> StagedExtension {
        try await ExtensionImporter.stage(source: .folder(fixture.root), paths: paths, sandbox: RecordingRunner())
    }

    func propose(_ fixture: PluginFixture, roles: [String] = ["engineer"], claude: ClaudeCheck? = nil) async throws -> Ask {
        try await ExtensionLibrary.propose(staged: try await stage(fixture), store: store, paths: paths, companyId: company.id,
                                           requester: .system, roles: roles, claude: claude, now: world.clock.now)
    }

    /// Proposes and approves (the app's path); returns the installed record.
    @discardableResult
    func install(_ fixture: PluginFixture, roles: [String] = ["engineer"]) async throws -> CompanyExtension {
        let ask = try await propose(fixture, roles: roles)
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: store, paths: paths, now: world.clock.now)
        return try #require(try store.installedExtensions(companyId: company.id).first { $0.id == fixture.root.lastPathComponent })
    }

    func installed(_ id: String) throws -> CompanyExtension? {
        try store.installedExtensions(companyId: company.id).first { $0.id == id }
    }

    func mounts(_ agent: Agent? = nil, kind: TurnKind = .work, profile: PermissionProfile? = nil,
                grants: GrantInputs = GrantInputs()) throws -> [ExtensionMount] {
        let a = agent ?? eng
        let c = try #require(try store.company(id: company.id))
        return try ExtensionLibrary.mounts(company: c, role: a.role, agent: a, grants: grants,
                                           profile: profile ?? c.profile(forRole: a.role), kind: kind, store: store, paths: paths,
                                           now: world.clock.now)
    }

    func events(_ kind: String? = nil) throws -> [ExtensionEvent] {
        try store.extensionEvents(companyId: company.id).filter { kind == nil || $0.kind == kind }
    }

    /// The next turn's request for the agent (the fake runner records it).
    func nextRequest(_ agent: Agent? = nil) async throws -> TurnRequest {
        let a = agent ?? eng
        try world.dm(company, a)
        try await world.cycle()
        return try #require(world.fake.requests.last { $0.agent.id == a.id })
    }
}

/// Runs the command unsandboxed (tests only) and records what the validator asked for.
final class RecordingRunner: SandboxedRunner, @unchecked Sendable {
    struct Call { var command: String; var cwd: URL; var environment: [String: String]; var policy: SandboxPolicy }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: SandboxPolicy) async -> CheckOutcome {
        lock.withLock { _calls.append(Call(command: command, cwd: cwd, environment: environment, policy: policy)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = cwd
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return CheckOutcome(exitCode: nil, timedOut: false, tail: "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? data.write(to: outputURL)
        return CheckOutcome(exitCode: p.terminationStatus, timedOut: false, tail: String(decoding: data, as: UTF8.self))
    }

    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        throw SandboxError.unavailable
    }
}

/// Writes a zip of STORED entries with arbitrary names and attributes (what `zip` refuses to produce: `..`, absolute names,
/// symlink entries, thousands of entries), so the importer's pre-extraction checks can be tested.
struct ZipBuilder {
    struct Entry { var name: String; var data: Data; var symlink = false; var declaredSize: Int? = nil }
    var entries: [Entry] = []

    /// `declaredSize` is what the central directory claims the entry inflates to (a lie, when set).
    mutating func add(_ name: String, _ text: String, symlink: Bool = false, declaredSize: Int? = nil) {
        entries.append(Entry(name: name, data: Data(text.utf8), symlink: symlink, declaredSize: declaredSize))
    }

    func write(to url: URL) throws {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        for e in entries {
            let name = Array(e.name.utf8), crc = ZipBuilder.crc32(e.data), size = UInt32(e.data.count), offset = UInt32(out.count)
            let fixed: [UInt8] = le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0)
            out += Data([0x50, 0x4b, 0x03, 0x04] + fixed + name) + e.data
            let mode: UInt32 = e.symlink ? 0o120777 : 0o100644
            let declared: [UInt8] = le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(size) + le32(UInt32(e.declaredSize ?? e.data.count))
                + le16(name.count) + le16(0)
            central += Data([0x50, 0x4b, 0x01, 0x02] + le16(0x031e) + declared + le16(0) + le16(0) + le16(0) + le32(mode << 16) + le32(offset) + name)
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += Data([0x50, 0x4b, 0x05, 0x06] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        try out.write(to: url)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
