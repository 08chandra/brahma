import Foundation
import GRDB

// Plan 4a Task 7: the sprint-review demo. When a sprint reaches `review`, the engine shows what the company has: every preview
// surface's `demo` (a CLI demo re-run, a backend's smoke requests, a web GET, a Simulator screenshot, a macOS app's liveness)
// plus the artifact demo (Task 6's `ArtifactAdapter`: the latest `AR-<n>`). Each result is one `previewDemo` row (its `line`
// redacted), and the channel post is engine-written status only (fix 12): counts and engine-validated surface names, never a
// page title, a demo's output or any agent text. The raw lines live only in the rows and the engine's output files, for the app.

/// What one preview showed at a sprint's review demo (table `previewDemo`, migration `"v4a-demos"`). `surfaceId` is nil for the
/// artifact demo (`surfaceName` `"artifacts"`) and for the one row that records an empty demo (`"none"`).
public struct PreviewDemo: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "previewDemo"

    public var id: String
    public var companyId: String
    public var sprintId: String
    public var surfaceId: String?
    public var surfaceName: String
    public var commit: String?
    public var ok: Bool
    /// Engine-composed, redacted.
    public var line: String
    public var outputPath: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, companyId: String, sprintId: String, surfaceId: String?, surfaceName: String, commit: String?,
                ok: Bool, line: String, outputPath: String?, createdAt: Date) {
        self.id = id; self.companyId = companyId; self.sprintId = sprintId; self.surfaceId = surfaceId; self.surfaceName = surfaceName
        self.commit = commit; self.ok = ok; self.line = line; self.outputPath = outputPath; self.createdAt = createdAt
    }
}

extension Store {
    /// A sprint's demo rows, oldest first.
    public func previewDemos(sprintId: String) throws -> [PreviewDemo] {
        try writer.read { db in
            try PreviewDemo.filter(Column("sprintId") == sprintId).order(Column("createdAt"), Column.rowID).fetchAll(db)
        }
    }
}

/// What the demo step reads and says.
public enum DemoRunner {
    /// The `surfaceName` of the artifact demo's row.
    public static let artifactsName = "artifacts"
    /// The `surfaceName` of the one row an empty demo leaves (so the sprint is demoed once).
    public static let noneName = "none"
    /// The `surfaceName` of the one row left when the demo's results could not be recorded `PreviewRunner.maxDemoAttempts`
    /// times (fix round 1, M6).
    public static let failedName = "failed"
    /// The sha when the company has no `main` yet (only artifacts to show).
    static let noMain = "none"

    /// Sprints in `review` with no demo rows yet, of running companies (a paused company's surfaces are stopped; fix round 1,
    /// M7), oldest first across companies: what the "demos" tick works through.
    public static func pending(store: Store) throws -> [Sprint] {
        try store.writer.read { db in
            try Sprint.fetchAll(db, sql: """
                SELECT s.* FROM sprint s JOIN company c ON c.id = s.companyId
                WHERE s.status = ? AND c.status != ? AND NOT EXISTS (SELECT 1 FROM previewDemo d WHERE d.sprintId = s.id)
                ORDER BY s.createdAt, s.rowid
                """, arguments: [SprintStatus.review.rawValue, CompanyStatus.paused.rawValue])
        }
    }

    /// `"<sprint name> review demo: no previews or artifacts yet."`
    static func hint(_ sprint: Sprint) -> String { "\(sprint.name) review demo: no previews or artifacts yet." }

    /// `"<sprint name> review demo at <sha7>: <k> of <n> previews ok (<name> ok|failed, …)"`. Names are engine-validated
    /// surface names (or `artifacts`).
    static func status(_ sprint: Sprint, sha7: String, results: [(name: String, ok: Bool)]) -> String {
        let k = results.filter(\.ok).count
        let parts = results.map { "\($0.name) \($0.ok ? "ok" : "failed")" }.joined(separator: ", ")
        return "\(sprint.name) review demo at \(sha7): \(k) of \(results.count) previews ok (\(parts))"
    }

    /// `"<sprint name> review demo failed: its results could not be recorded."`
    static func failed(_ sprint: Sprint) -> String { "\(sprint.name) review demo failed: its results could not be recorded." }

    /// `"<sprint name> demo ready (<k>/<n> ok)"`, the activity line.
    static func ready(_ sprint: Sprint, results: [(name: String, ok: Bool)]) -> String {
        "\(sprint.name) demo ready (\(results.filter(\.ok).count)/\(results.count) ok)"
    }

    /// One write: the rows, the status post (from system, to the sprint's channel) and, with `ready`, the activity line. Nothing
    /// is written when the owner's stop holds at that moment (`CancellationError`).
    static func record(store: Store, sprint: Sprint, rows: [PreviewDemo], post: String, ready: String?, now: Date) throws {
        try store.writer.write { db in
            guard try Store.engineStopped(db) == nil else { throw CancellationError() }
            for row in rows { try row.insert(db) }
            _ = try MessageRouter(store: store).post(db: db, companyId: sprint.companyId, channel: try channel(db, sprint: sprint),
                                                     from: .system, text: post, now: now)
            if let ready {
                try ActivityEvent(companyId: sprint.companyId, agentId: nil, turnId: nil, kind: .preview, text: ready, createdAt: now).insert(db)
            }
        }
    }

    /// The sprint's team channel when it exists, else `general` (as sprint standups).
    static func channel(_ db: Database, sprint: Sprint) throws -> String {
        if let team = sprint.team,
           try Channel.filter(Column("companyId") == sprint.companyId && Column("name") == "team-\(team)").fetchCount(db) > 0 {
            return "team-\(team)"
        }
        return "general"
    }
}

extension PreviewRunner {
    /// What `demo(sprint:)` wrote: the post's text and the rows.
    public struct DemoOutcome: Equatable, Sendable {
        public var post: String
        public var rows: [PreviewDemo]
    }

    /// The sprint-review demo of one sprint, in order:
    /// 1. one reconcile pass per surface, with the sprint's company past its merge debounce (every other company keeps it),
    ///    each awaited (the surfaces run on the current `main`);
    /// 2. every surface's adapter `demo` (a surface with no run of its own: `"<name>: not running"`), then the artifact demo
    ///    (`ArtifactAdapter.latestDemo`; absent when the company has published nothing);
    /// 3. the rows (`line` redacted), the status post from system to `#team-<team>` or `#general`, and the activity line
    ///    `"<name> demo ready (<k>/<n> ok)"`, in one write; a sprint with nothing to show posts the hint and gets one `none` row.
    ///
    /// The owner's stop (obligation e, fix round 1 I1): nothing runs or is written while `engineStopped()` holds — read before
    /// every pass, before and after every surface's demo, and inside the write — and `stopAll` cancels the demo in flight
    /// (`demoTask`: a running demo command is killed with its group, no later surface demos, nothing recorded). Nil then, as
    /// when a stop is running, the company is gone or already demoed, the lines cannot be redacted (fail closed: the sprint
    /// stays pending), or the results could not be recorded. A record failure other than the stop is counted
    /// (`demoAttempts`); at `maxDemoAttempts` the engine gives the sprint up with one `failed` row and the post
    /// `"<name> review demo failed: its results could not be recorded."` (fix round 1, M6), so nothing re-runs forever.
    /// One demo runs at a time.
    public func demo(sprint: Sprint) async -> DemoOutcome? {
        guard demoTask == nil else { return nil }
        let task = Task { await self.runDemo(sprint) }
        demoTask = task
        let outcome = await task.value
        demoTask = nil
        return outcome
    }

    private func runDemo(_ sprint: Sprint) async -> DemoOutcome? {
        let epoch = stopEpoch
        func halted() -> Bool { Task.isCancelled || stopping != 0 || epoch != stopEpoch || ownerStopHolds }
        guard !halted(), let company = try? store.company(id: sprint.companyId),
              (try? store.previewDemos(sprintId: sprint.id))?.isEmpty == true else { return nil }
        // Given up already (M6): only the cheap failure record is tried again, never the demo.
        if (demoAttempts[sprint.id] ?? 0) >= Self.maxDemoAttempts {
            giveUp(sprint, company: company)
            return nil
        }
        let surfaces = ((try? store.previewSurfaces(companyId: company.id)) ?? []).filter { $0.previewKind != nil && $0.previewKind != .artifact }
        // 1. Reconcile until every surface had its chance to start (one start per pass), awaiting each.
        for _ in 0...surfaces.count {
            guard !halted() else { return nil }
            await reconcile(now: clock(), settledCompany: company.id)
            await waitForStarts()
        }
        // 2. The demos, the stop read before and after each.
        let states = (try? store.previewStates(companyId: company.id)) ?? [:]
        var results: [(name: String, ok: Bool)] = []
        var captures: [(surface: PreviewSurface?, commit: String?, capture: DemoCapture)] = []
        for surface in surfaces {
            guard !halted() else { return nil }
            let state = states[surface.id] ?? PreviewState(surfaceId: surface.id, companyId: company.id, updatedAt: clock())
            let capture: DemoCapture
            if let kind = surface.previewKind, let run = runs[surface.id], var context = run.context, let adapter = adapters[kind] {
                context.demoSprint = sprint.number
                capture = await adapter.demo(context, state: state)
            } else {
                capture = DemoCapture(ok: false, line: "\(surface.name): not running")
            }
            guard !halted() else { return nil }
            results.append((surface.name, capture.ok))
            captures.append((surface, state.commit, capture))
        }
        if let artifact = ArtifactAdapter.latestDemo(store: store, companyId: company.id) {
            results.append((DemoRunner.artifactsName, artifact.ok))
            captures.append((nil, company.mainCommit, artifact))
        }
        // 3. The rows and the post, in one write; the stop read once more first.
        guard !halted() else { return nil }
        let now = clock()
        let post = results.isEmpty ? DemoRunner.hint(sprint)
            : DemoRunner.status(sprint, sha7: company.mainCommit.map { String($0.prefix(7)) } ?? DemoRunner.noMain, results: results)
        var rows: [PreviewDemo] = []
        do {
            for (surface, commit, capture) in captures {
                rows.append(PreviewDemo(companyId: company.id, sprintId: sprint.id, surfaceId: surface?.id,
                                        surfaceName: surface?.name ?? DemoRunner.artifactsName, commit: commit, ok: capture.ok,
                                        line: try store.redact(capture.line), outputPath: capture.outputPath, createdAt: now))
            }
            if captures.isEmpty {
                rows.append(PreviewDemo(companyId: company.id, sprintId: sprint.id, surfaceId: nil, surfaceName: DemoRunner.noneName,
                                        commit: company.mainCommit, ok: false, line: "no previews or artifacts yet", outputPath: nil, createdAt: now))
            }
            if let failure = demoRecordFailure { throw failure }
            try DemoRunner.record(store: store, sprint: sprint, rows: rows, post: post,
                                  ready: results.isEmpty ? nil : DemoRunner.ready(sprint, results: results), now: now)
        } catch is SecretError {
            return nil                                   // secrets not loaded: the orchestrator holds the tick meanwhile
        } catch {
            if error is CancellationError || halted() { return nil }
            let attempts = (demoAttempts[sprint.id] ?? 0) + 1
            demoAttempts[sprint.id] = attempts
            FileHandle.standardError.write(Data("brahma preview: could not record the \(sprint.name) demo of \(company.slug) (attempt \(attempts)): \(error)\n".utf8))
            if attempts >= Self.maxDemoAttempts { giveUp(sprint, company: company) }
            return nil
        }
        demoAttempts[sprint.id] = nil
        return DemoOutcome(post: post, rows: rows)
    }

    /// One `failed` row and the failure post; the sprint is then demoed (M6). If this write fails too, the next call tries
    /// only it again.
    private func giveUp(_ sprint: Sprint, company: Company) {
        let now = clock()
        let row = PreviewDemo(companyId: company.id, sprintId: sprint.id, surfaceId: nil, surfaceName: DemoRunner.failedName,
                              commit: company.mainCommit, ok: false, line: "the demo's results could not be recorded", outputPath: nil, createdAt: now)
        do {
            try DemoRunner.record(store: store, sprint: sprint, rows: [row], post: DemoRunner.failed(sprint), ready: nil, now: now)
            demoAttempts[sprint.id] = nil
        } catch {
            FileHandle.standardError.write(Data("brahma preview: could not record the failed \(sprint.name) demo of \(company.slug): \(error)\n".utf8))
        }
    }
}
