import Foundation
import GRDB
import BrahmaCore
import BrahmaAppModel

/// Plan C Task C6's app-side world: company "Eng" (key prefix ENG) with a git repository holding a few committed files,
/// three agents, one item, one channel message, a resource row in the vault and a preview surface. Built over a file-backed
/// store beside its data home (`makeHome`), so `AppModel` and the vault read the same paths.
@MainActor
struct RefWorld {
    let store: Store
    let paths: BrahmaPaths
    let company: Company
    let cto: Agent, eng1: Agent, eng3: Agent
    let item: WorkItem
    let general: Channel
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var workspace: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }

    init(files: [String: String] = RefWorld.defaultFiles) throws {
        let (s, p) = try makeHome()
        store = s
        paths = p
        var c = try s.createCompany(name: "Eng", goal: "Build", workspacesRoot: p.workspaces)
        try s.updateSandbox(companyId: c.id, SandboxPatch(profile: .workspace), userHome: try tempDir())
        c = try s.company(id: c.id) ?? c
        company = c
        cto = try s.hire(companyId: c.id, name: "cto", role: "cto", model: "sonnet")
        eng1 = try s.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: cto.id)
        eng3 = try s.hire(companyId: c.id, name: "eng-3", role: "engineer", model: "sonnet", managerId: cto.id)
        let root = URL(fileURLWithPath: c.workspacePath, isDirectory: true)
        for (path, text) in files { try Self.write(path, text, in: root) }
        try Self.git(["add", "-A"], in: root)
        try Self.git(["commit", "-q", "-m", "files"], in: root)
        let main = try Self.git(["rev-parse", "main"], in: root)
        try s.writer.write { db in try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [main, c.id]) }
        item = try s.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Checkout totals"))
        guard let g = try s.channel(companyId: c.id, name: "general") else { throw TestFailure("no #general") }
        general = g
    }

    static let defaultFiles: [String: String] = [
        "src/checkout.tsx": (1...49).map { "const line\($0) = \($0)" }.joined(separator: "\n") + "\n",
        "src/a.ts": "one\ntwo\n",
        "Sources/App.swift": "let a = 1\nlet b = 2\nlet c = 3\n",
        "README.md": "# Eng\n\nHello.\n",
    ]

    var context: RefContext { RefContext(companyId: company.id, keyPrefixes: ["ENG"], allowInternal: true) }

    func ref(_ s: String) throws -> WorkRef {
        guard let r = WorkRef.parse(s, context: context) else { throw TestFailure("\(s) does not parse") }
        return r
    }

    func resolve(_ s: String, as reader: Reader = .owner) throws -> ResolvedRef {
        try store.resolveRef(try ref(s), for: reader, companyId: company.id)
    }

    func head() throws -> String { try Self.git(["rev-parse", "main"], in: workspace) }

    /// The app model over this world, with the company selected and its snapshot loaded.
    func app() async -> AppModel {
        let model = AppModel(store: store, paths: paths, clock: { Date() })
        await model.load()
        await model.selectCompany(company.id)
        return model
    }

    func renderContext() -> RefRenderContext {
        RefRenderContext(companyId: company.id, knownValues: [], paths: paths, archives: UnavailableArchiveReader(), timeZone: TimeZone(identifier: "UTC")!,
                         tempRoot: (try? tempDir()) ?? FileManager.default.temporaryDirectory, handles: [cto.id: "cto", eng1.id: "eng-1", eng3.id: "eng-3"],
                         now: now)
    }

    func count(_ table: String) throws -> Int {
        try store.writer.read { db in
            guard try db.tableExists(table) else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    /// A vault resource `F-<n>` of `bytes` named `name`, with the given provenance (`owner`, `agent:<id>`, …).
    @discardableResult
    func seedResource(number: Int, name: String, bytes: Data, provenance: String, tainted: Bool = false) throws -> Resource {
        let ext = ArtifactKind.ext(of: name)
        let vault = Vault(paths: paths, companyId: company.id, content: ContentVault(paths: paths))
        let written = try vault.write(bytes, area: .resources, name: "F-\(number).\(ext)")
        let (cId, now) = (company.id, self.now)
        let row = Resource(companyId: cId, number: number, kind: .file, displayName: name, ext: ext, fileKind: ArtifactKind.from(ext: ext)?.rawValue,
                           bytes: Int64(bytes.count), sha256: written.sha256, vaultPath: written.path, scopeKind: "company", scopeId: nil,
                           readerSet: nil, provenance: provenance, tainted: tainted, taintReason: tainted ? "outside content" : nil,
                           addedVia: "library", createdAt: now, updatedAt: now)
        try store.writer.write { db in try row.insert(db) }
        return row
    }

    /// The `web` preview surface with a `/checkout` smoke path, set by @eng-1.
    func seedPreviewSurface() throws {
        let (cId, now, setBy) = (company.id, self.now, eng1.id)
        try store.writer.write { db in
            try PreviewSurface(id: UUID().uuidString, companyId: cId, name: "web", position: 0, build: nil, run: "npm start",
                               url: "http://127.0.0.1:{port}/", smoke: [SmokeRequest(method: "GET", path: "/checkout")],
                               setById: setBy, createdAt: now, updatedAt: now).insert(db)
        }
    }

    // MARK: Plain git

    @discardableResult
    static func write(_ path: String, _ text: String, in root: URL) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir.path, "-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + args
        var e = ProcessInfo.processInfo.environment
        e["GIT_CONFIG_GLOBAL"] = "/dev/null"
        p.environment = e
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw TestFailure("git \(args.joined(separator: " ")) failed: \(String(decoding: r, as: UTF8.self))")
        }
        return String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// A minimal valid PNG (signature, IHDR, IEND; CRCs right), as the gate's strict chunk walk requires.
enum TinyPNG {
    static func make() -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: [UInt8]) {
            var len = UInt32(body.count).bigEndian
            d.append(Data(bytes: &len, count: 4))
            let typed = Array(type.utf8) + body
            d.append(contentsOf: typed)
            var crc = crc32(typed).bigEndian
            d.append(Data(bytes: &crc, count: 4))
        }
        chunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0])
        chunk("IEND", [])
        return d
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
