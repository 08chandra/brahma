import Foundation

// `brahma ext try` (Task 10b): the owner tries a working extension folder in one throwaway turn before proposing it. The
// folder must lint without errors; its plugin parts are copied read-only to `<ws>/.brahma/ext-try/<uuid>/plugin/`, which only
// that turn reads, and mounted as `<id>@dev` next to the role's normal mounts. The turn runs as a throwaway handle
// `try-<uuid8>` with the role's template, a fresh session, the company's real compiler output, haiku and Quick caps, on the
// Sandboxed profile only. No ask is created, no agent or turn row is written (it is never a team member): the run is recorded
// as an `extensionEvent` of kind `try`. Everything it made is removed afterwards.

/// What one `ext try` run did.
public struct ExtensionTryResult: Equatable, Sendable {
    public var extId: String
    public var handle: String
    public var role: String
    /// `succeeded`, `capped` (a Quick cap stopped it), `failed` or `stopped` (an init the engine refuses).
    public var outcome: String
    public var costUSD: Double?
    /// The init line's `skills` and the tools the turn used, in order of first use.
    public var skills: [String]
    public var tools: [String]
    public var text: String?
    /// The redacted transcript, relative to the data home (`TranscriptCapture.captureDevRun`); nil when none was captured.
    public var transcript: String?
    public var problem: String?
    /// The taint source the trial ran under (Plan L Task 14 fix round 2: an imported company the owner has not trusted), or nil.
    public var taint: String? = nil
}

public enum ExtensionTry {
    public static let profileRefusal = "ext try runs only on the Sandboxed profile; this company runs the role on another profile"
    public static let model = "haiku"
    public static let stoppedRefusal = "Brahma is stopped (emergency stop); resume it before trying an extension"
    static let dir = ".brahma/ext-try"

    /// The handle prefix of a trial (`try-<uuid8>`), reserved (S29): `Store.hire` and `OrgPlan` refuse any handle that starts
    /// with it (case-insensitive, after NFC).
    public static let handlePrefix = "try-"

    public static func isReservedHandle(_ handle: String) -> Bool {
        handle.precomposedStringWithCanonicalMapping.lowercased().hasPrefix(handlePrefix)
    }

    /// What a trial that was killed left (M2, S29): its own root `.brahma/ext-try/<id>` (its plugin copy, home, lab, notes and
    /// shell prefix all live there, never in the per-agent directories) and its `try-<uuid>` settings, MCP and taint files,
    /// each older than `olderThan` seconds (a trial running now keeps its own), removed by descriptor without following a link.
    /// A name that is an existing agent's id or handle is never removed (`existing`). Run at each `ext try` and at engine
    /// start. Blocking. Returns what it removed.
    @discardableResult
    public static func sweepStale(paths: BrahmaPaths, workspace: URL, existing: Set<String>, olderThan: TimeInterval = 3600,
                                  now: Date) -> [String] {
        let ws = workspace.resolvedForSandbox
        let agentId = "^try-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        let places: [(dir: URL, root: URL, pattern: String)] = [
            (ws.appending(path: dir), ws, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"),
            (paths.runDir, paths.runDir, agentId + "\\.(settings|mcp)\\.json$"),
            (paths.runDir.appending(path: "taint"), paths.runDir, agentId + "$"),
        ]
        var removed: [String] = []
        for place in places {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: place.dir.path)) ?? []
            where name.range(of: place.pattern, options: .regularExpression) != nil {
                let base = name.replacingOccurrences(of: "\\.(settings|mcp)\\.json$", with: "", options: .regularExpression)
                guard !existing.contains(base), !existing.contains(name) else { continue }
                let url = place.dir.appending(path: name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                #if canImport(Darwin)
                let modified = Double(st.st_mtimespec.tv_sec)
                #else
                let modified = Double(st.st_mtim.tv_sec)
                #endif
                guard now.timeIntervalSince1970 - modified > olderThan else { continue }
                if st.st_mode & S_IFMT == S_IFDIR { ExtensionLibrary.makeWritable(url) }
                if case .removed? = try? EngineFiles.removeNoFollow(url, under: place.root) { removed.append(url.path) }
            }
        }
        return removed
    }

    /// Every agent id and handle in the store (what `sweepStale` never removes).
    static func existingNames(_ store: Store) -> Set<String> {
        let agents = ((try? store.companies()) ?? []).flatMap { (try? store.agents(companyId: $0.id)) ?? [] }
        return Set(agents.flatMap { [$0.id, $0.name] })
    }

    /// Lints `path`, mounts its plugin parts for one throwaway Quick turn of `role` in the company, records the run and removes
    /// what it made. Refused (`ExtensionError`) on lint errors or when the role does not run Sandboxed.
    public static func run(path: URL, companyId: String, role: String, prompt: String, orchestrator: Orchestrator,
                           now: Date = Store.now()) async throws -> ExtensionTryResult {
        let store = orchestrator.store, paths = orchestrator.paths
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        guard store.catalog.pack(company.packId)?.role(role) != nil else {
            throw WorkError.invalid("no role '\(Store.flat(role, max: 40))' in this company's pack")
        }
        guard orchestrator.turnProfile(role: role, company: company) == .sandboxed else { throw ExtensionError.message(profileRefusal) }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkError.invalid("the prompt is empty") }
        // M2: the owner's emergency stop holds trials too; what an interrupted trial left is swept first.
        if try store.engineStopped() != nil { throw ExtensionError.message(stoppedRefusal) }
        sweepStale(paths: paths, workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: true), existing: existingNames(store),
                   now: now)

        // 1. Lint a staged copy (never the folder itself), under the data home's tmp: errors refuse, warnings do not.
        let scratch = try paths.ensureTmpDir().appending(path: "ext-try-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = scratch.appending(path: "staged", directoryHint: .isDirectory)
        try ExtensionImporter.copyTree(from: path, to: staged)
        let options = ValidationOptions(installedBins: try store.installedBins(companyId: company.id, paths: paths))
        let lint = ExtensionValidator.validate(staged: staged, options: options)
        guard lint.errors.isEmpty, let manifest = lint.manifest else { throw ExtensionError(issues: lint.errors) }
        if BuiltinExtensions.ids.contains(manifest.name) {
            throw ExtensionError.message("'\(manifest.name)' is Brahma's own extension id; choose another")
        }
        // What an install would mount: the canonical frontmatter (S9).
        _ = try ExtensionValidator.canonicalize(staged: staged)

        // 2. The dev copy, read-only through EngineFiles; only this turn's scope reads it.
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let resolved = workspace.resolvedForSandbox
        let uuid = UUID().uuidString.lowercased()
        let relative = "\(dir)/\(uuid)/plugin"
        defer {
            let tryDir = resolved.appending(path: "\(dir)/\(uuid)", directoryHint: .isDirectory)
            ExtensionLibrary.makeWritable(tryDir)
            _ = try? EngineFiles.removeNoFollow(tryDir, under: resolved)
        }
        try ExtensionLibrary.writePluginParts(from: staged, workspace: resolved, relative: relative)
        let devPlugin = resolved.appending(path: relative, directoryHint: .notDirectory)

        // 3. The turn, then 4. its record (never an ask).
        let result = try await orchestrator.devRunUnlessStopped(company: company, role: role, prompt: prompt, devPlugin: devPlugin,
                                                                devId: manifest.name, trialRoot: "\(dir)/\(uuid)", now: now)
        try store.recordExtensionEvent(companyId: company.id, extId: manifest.name, kind: "try", detail: eventDetail(result), now: now)
        return result
    }

    static func money(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "cost unknown" }

    static func eventDetail(_ r: ExtensionTryResult) -> String {
        "\(r.extId)@dev as \(r.handle) role \(r.role): \(r.outcome) \(money(r.costUSD)); skills \(r.skills.joined(separator: ", ")); "
            + "tools \(r.tools.joined(separator: ", ")); transcript \(r.transcript ?? "not captured")"
            + (r.problem.map { "; \($0)" } ?? "")
    }

    /// What the CLI prints (through `safe()`): agent text is flattened here.
    public static func summary(_ r: ExtensionTryResult) -> String {
        var lines = ["ext try \(r.extId)@dev as \(r.handle) (role \(r.role)): \(r.outcome), \(money(r.costUSD))",
                     "skills: \(r.skills.isEmpty ? "(none reported)" : r.skills.map { Store.flat($0, max: 120) }.joined(separator: ", "))",
                     "tools used: \(r.tools.isEmpty ? "(none)" : r.tools.map { Store.flat($0, max: 80) }.joined(separator: ", "))",
                     "transcript: \(r.transcript ?? "not captured")"]
        if let t = r.taint { lines.append("taint: \(Store.flat(t, max: 120)) (the company's imported repo is not trusted yet)") }
        if let p = r.problem { lines.append("note: \(Store.flat(p, max: 400))") }
        if let t = r.text { lines.append("reply: \(Store.flat(t, max: 2000))") }
        return lines.joined(separator: "\n")
    }
}

extension Orchestrator {
    /// The profile a turn of `role` runs under in the company (its choice, under the engine's ceiling).
    nonisolated func turnProfile(role: String, company: Company) -> PermissionProfile {
        let chosen = company.profile(forRole: role)
        return profileCeiling.map { PermissionProfile.narrower(chosen, $0) } ?? chosen
    }

    /// `devRun` raced against the owner's emergency stop (M2), as engine turns are: a stop cancels the trial (its process ends,
    /// its places are removed) and the trial is refused. Cancelling the caller (the CLI's Ctrl-C) cleans up the same way.
    nonisolated func devRunUnlessStopped(company: Company, role: String, prompt: String, devPlugin: URL, devId: String,
                                         trialRoot: String, now: Date) async throws -> ExtensionTryResult {
        let outcome: ExtensionTryResult?? = try await withThrowingTaskGroup(of: ExtensionTryResult?.self) { group in
            group.addTask {
                try await self.devRun(company: company, role: role, prompt: prompt, devPlugin: devPlugin, devId: devId,
                                      trialRoot: trialRoot, now: now)
            }
            group.addTask { await self.waitForStop(); return nil }
            let first = try await group.next()
            group.cancelAll()
            // Every child ends (and the trial's clean-up runs) before the group returns.
            while (try? await group.next()) != nil {}
            return first
        }
        if Task.isCancelled { throw CancellationError() }
        guard let finished = outcome, let result = finished else { throw ExtensionError.message(ExtensionTry.stoppedRefusal) }
        return result
    }

    /// A dev-run turn (`ext try`, 10b): one itemless Quick turn of a throwaway handle on the Sandboxed profile, with the role's
    /// template, a fresh session, no company tools and no grants, the role's normal mounts plus `devPlugin` (readable and
    /// read-only on this turn only). It passes the same sandbox gate as any sandboxed turn and writes no agent or turn row. Its
    /// home, lab, notes and shell prefix live under `trialRoot` (`.brahma/ext-try/<id>`, S29), which the caller removes whole;
    /// its settings, MCP config, taint flag and temp dir are removed here.
    nonisolated func devRun(company: Company, role: String, prompt: String, devPlugin: URL, devId: String, trialRoot: String,
                            now: Date) async throws -> ExtensionTryResult {
        let paths = self.paths
        let handle = "try-" + String(UUID().uuidString.lowercased().filter { $0 != "-" }.prefix(8))
        let agent = Agent(id: "try-\(UUID().uuidString.lowercased())", companyId: company.id, name: handle, role: role,
                          model: ExtensionTry.model, sessionId: UUID().uuidString.lowercased(), sessionStarted: false, state: .running,
                          blocker: nil, requestedBlocker: nil, paused: false, readySince: nil, createdAt: now)
        let settingsFile = SettingsFile.path(paths: paths, agentId: agent.id)
        let mcpConfig = paths.runDir.appending(path: "\(agent.id).mcp.json")
        let places = DevRunPlaces()
        func cleanUp() async {
            let records = turnRecordDirectory
            _ = try? await runner.waitForTurnProcesses(agentId: agent.id, records: records)
            let tmp = places.claudeTmp
            await blocking.run {
                for url in [settingsFile, mcpConfig] { _ = try? EngineFiles.removeNoFollow(url, under: paths.runDir) }
                if let tmp { _ = try? EngineFiles.removeNoFollow(tmp, under: tmp.deletingLastPathComponent()) }
                TaintFlag.remove(home: paths.home, agentId: agent.id)
            }
        }
        // R4-6 (ruling 35): the trial writes no turn row, so a purge's running-turn check can't see it; it holds the company's
        // purge fence shared for its whole run instead (refused while a purge holds it).
        let fence: PurgeFence.Hold?
        do {
            let store = self.store
            fence = try await blocking.tryRun { try store.holdPurgeFence(companyId: company.id) }
        } catch let e as WorkError {
            throw ExtensionError.message("the trial did not run: \(e.message)")
        }
        defer { fence?.release() }
        do {
            let result = try await devRunTurn(agent: agent, company: company, prompt: prompt, devPlugin: devPlugin, devId: devId,
                                              trialRoot: trialRoot, settingsFile: settingsFile, mcpConfig: mcpConfig, places: places,
                                              now: now)
            await cleanUp()
            return result
        } catch {
            await cleanUp()
            throw error
        }
    }

    private nonisolated func devRunTurn(agent: Agent, company: Company, prompt: String, devPlugin: URL, devId: String, trialRoot: String,
                                        settingsFile: URL, mcpConfig: URL, places: DevRunPlaces, now: Date) async throws -> ExtensionTryResult {
        let store = self.store, paths = self.paths
        let template = store.catalog.template(role: agent.role, pack: company.packId)
        // The role's normal mounts (no grants: a throwaway holds none), then the dev copy as `<id>@dev`.
        let mounts = try await blocking.tryRun {
            try ExtensionLibrary.mounts(company: company, role: agent.role, agent: agent, grants: GrantInputs(), profile: .sandboxed,
                                        kind: .work, itemScoped: false, store: store, paths: paths, now: now)
        }.filter { $0.id != devId }
        var prepared = try await prepareSandbox(agent: agent, company: company, kind: .work, item: nil, turnId: agent.id,
                                                extraDomains: ExtensionLibrary.agentNetwork(mounts), trialRoot: trialRoot)
        places.claudeTmp = prepared.scope.claudeTmp
        if !prepared.grants.isEmpty, let rebuild = prepared.rebuild {
            prepared.scope = try await blocking.tryRun { try rebuild(GrantInputs()) }
            prepared.grants = []
        }
        prepared.scope.readable.append(devPlugin)
        prepared.scope.readOnlyDirs.append(devPlugin)
        try prepared.scope.validate()

        let mode = ModeDecision(mode: .quick, rung: .r0, model: ExtensionTry.model, effort: .low, maxEffortLevel: .low,
                                maxBudgetUSD: ModeCaps.quick.budgetSonnetLE, maxTurns: ModeCaps.quick.maxTurns,
                                wallClock: ModeCaps.quick.wallClock, quotas: ModeCaps.quick.quotas, reasons: ["ext try: Quick (haiku low)"])
        let systemPrompt = RolePrompt.render(agent: agent, company: company, template: template, tools: [], sandboxed: true)
            + "\n\nThis is the owner's one-off trial of the extension \(devId)@dev. You have no company tools in this turn."
        try await blocking.tryRun { try SettingsFile.writePrivate(Data("{\"mcpServers\":{}}".utf8), to: mcpConfig) }
        var request = TurnRequest(agent: agent, company: company, prompt: prompt, appendSystemPrompt: systemPrompt,
                                  mcpConfigPath: mcpConfig.path, workingDirectory: prepared.scope.cwd.path, profile: .sandboxed,
                                  addDirs: prepared.scope.readOnlyDirs.map(\.path),
                                  environment: ["BRAHMA_AGENT_ID": agent.id, "BRAHMA_HOME": paths.home.path,
                                                "BRAHMA_WORKSPACES": paths.workspaces.path])
        request.kind = .work
        request.mounts = mounts.map(\.url) + [devPlugin]
        request.mode = mode
        request.hookExecutable = mcpExecutable
        request.turnRecordDirectory = turnRecordDirectory
        request.expectations = TurnProfileCompiler.expectations(for: mode, agents: store.recordedBuiltinAgents())
        request.settingsFilePath = settingsFile.path
        request.postToolHook = TaintPolicy.postToolHook(executable: mcpExecutable, database: paths.database.path, agentId: agent.id)
        request.taintFlagFile = TaintFlag.url(home: paths.home, agentId: agent.id)?.path
        request.taintDatabase = paths.database.path
        request.sandbox = prepared.scope
        request.shellPrefix = prepared.shellPrefix.path
        request.containmentMarker = prepared.marker
        let compiled = TurnProfileCompiler.profile(for: request)
        // The same per-launch sandbox gate as every sandboxed turn: a shape the canary has not verified does not run.
        if let gate = sandboxCanary {
            let key: SandboxCanaryKey
            do { key = try await canaryKey(gate: gate, shape: compiled.settings.shape()) } catch { throw SandboxRefusal(reason: "\(error)") }
            guard try store.sandboxVerified(key) else {
                throw ExtensionError.message("the sandbox is not verified for this CLI build and settings shape yet; run the engine "
                                             + "(brahma run) so its canary checks it, then try again")
            }
        }
        let settingsText = try TurnProfileCompiler.settingsJSON(compiled)
        try await blocking.tryRun { try SettingsFile.write(settingsText, to: settingsFile) }
        // Plan L Task 14 fix round 2 (S1-ext): a trial in an imported company the owner has not trusted reads the imported tree,
        // so it runs tainted with the import's source, through the same flag file its hooks read (removed in `cleanUp`).
        let importTaint = try store.importTaint(companyId: company.id)
        if let importTaint {
            let written = await blocking.run { TaintFlag.write(home: paths.home, agentId: agent.id, source: importTaint) }
            guard written else { throw ExtensionError.message("could not mark the trial as reading the imported repo; it did not run") }
        }

        var state = TurnStreamState()
        var skills: [String] = [], tools: [String] = []
        var sessionId: String?
        var problem: String?
        do {
            events: for try await event in runner.run(request) {
                state.apply(event)
                switch event {
                case .initialized(let id, _):
                    sessionId = id
                case .initInfo(let info):
                    skills = info.skills
                    if let why = TurnAudit.initViolation(info, expectations: request.expectations) {
                        problem = "stopped at start: \(why)"
                        break events
                    }
                case .toolUse(let name, _):
                    if !tools.contains(name) { tools.append(name) }
                default:
                    break
                }
            }
        } catch {
            problem = problem ?? "\(error)"
        }
        let result = state.result
        var transcript: String?
        if let transcripts, let id = result?.sessionId ?? sessionId {
            let (label, companyId) = (agent.name, company.id)
            transcript = await blocking.run { transcripts.captureDevRun(sessionId: id, companyId: companyId, label: label, store: store) }
        }
        let outcome: String
        if problem?.hasPrefix("stopped at start") == true { outcome = "stopped" }
        else if let r = result, !r.isError { outcome = "succeeded" }
        else if let r = result, r.stopReason != nil { outcome = "capped" }
        else { outcome = "failed" }
        return ExtensionTryResult(extId: devId, handle: agent.name, role: agent.role, outcome: outcome, costUSD: result?.costUSD,
                                  skills: skills, tools: tools, text: result?.text, transcript: transcript,
                                  problem: problem ?? (outcome == "failed" ? (result?.text ?? "claude exited without a result") : nil),
                                  taint: importTaint)
    }
}

/// What a dev run made outside the places its handle names (its Claude temp dir), for the clean-up.
final class DevRunPlaces: @unchecked Sendable {
    private let lock = NSLock()
    private var _claudeTmp: URL?
    var claudeTmp: URL? {
        get { lock.withLock { _claudeTmp } }
        set { lock.withLock { _claudeTmp = newValue } }
    }
}
