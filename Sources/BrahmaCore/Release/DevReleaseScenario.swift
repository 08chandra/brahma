import Foundation

/// `brahma dev release-scenario <company>` (Plan L Task 12; BRAHMA_DEV=1 only): populates a demo company's Releases and Inbox
/// through the real deploy path, against the dev host (`LocalCopyHostingAdapter`, PR-32), never a real provider:
/// 1. the ops agent's deploy config (a sandboxed build into `dist`, `GET /`) and smoke check `test -f index.html`, which is
///    run on main (`Store.runSmoke`, the engine's smoke path);
/// 2. the dev host's token (a clearly-dev value in the home's vault: the file vault of a dev/demo home), loaded into the
///    redactor, and the no-op tool marker;
/// 3. R-1 proposed (`Store.proposeDeploy`), approved by the owner (`Store.ownerDecide`) and carried out by
///    `ReleaseExecutor.advance` — smoke on main, integrity, backup refs, build, stage, tools, deploy, smoke of the copy on
///    the in-process loopback `DevHostServer` — which leaves it `deployed`; the server is stopped afterwards;
/// 4. R-2 proposed and left `proposed` with its deploy ask pending;
/// 5. a `stripe-test-keys` human task (linked to `itemKey` when given) and a custom task with one url field.
/// The scenario holds the engine lock (`OrchestratorLock`) throughout: it refuses while an engine runs on the data home.
public enum DevReleaseScenario {
    /// The dev host's token secret: engine-held, never in argv, only in the deploy steps' environment.
    public static let tokenSecret = "DEV_HOST_TOKEN"
    /// Clearly not a real credential; long enough for the redactor (the executor refuses a token it cannot redact).
    static let devToken = "brahma-dev-host-token-NOT-A-REAL-SECRET-0001"
    public static let refusal = "the dev release scenario needs BRAHMA_DEV=1"
    public static let build = "mkdir -p dist && cp index.html dist/"
    public static let smokeCommand = "test -f index.html"
    public static let firstVersion = "0.1.0"
    public static let secondVersion = "0.2.0"

    public struct Summary: Sendable {
        public var deployed: Release
        public var proposed: Release
        public var deployAsk: Ask
        public var humanTasks: [Ask]
        public var smoke: MainSmokeRun
    }

    /// Runs the scenario for `companyId`. Throws `WorkError` with what is missing or what failed (R-1 not `deployed` names
    /// its reason). `environment` is the caller's: `BRAHMA_DEV` must be `"1"` and `BRAHMA_AGENT_ID` unset; steps get a
    /// check environment built from it (`ChildEnvironment`, which never passes `BRAHMA_DEV` on).
    public static func run(store: Store, paths: BrahmaPaths, companyId: String, vault: any SecretVault, itemKey: String? = nil,
                           expectText: String? = nil,
                           environment: [String: String] = ProcessInfo.processInfo.environment, owner: OwnerPrincipal) async throws -> Summary {
        guard environment["BRAHMA_DEV"] == "1", environment["BRAHMA_AGENT_ID"] == nil else { throw WorkError.forbidden(refusal) }
        let lock: OrchestratorLock
        do { lock = try OrchestratorLock.acquire(paths: paths) } catch OrchestratorLockError.alreadyRunning {
            throw WorkError.conflict("an engine is running on this data home; quit the app (or `brahma run`) first")
        }
        defer { withExtendedLifetime(lock) {} }
        return try await carryOut(store: store, paths: paths, companyId: companyId, vault: vault, itemKey: itemKey,
                                  expectText: expectText, environment: environment, owner: owner)
    }

    private static func carryOut(store: Store, paths: BrahmaPaths, companyId: String, vault: any SecretVault, itemKey: String?,
                                 expectText: String?, environment: [String: String], owner: OwnerPrincipal) async throws -> Summary {
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        guard let hosting = try store.hosting(companyId: companyId), hosting.accountId != nil else {
            throw WorkError.invalid("set the company's hosting first: brahma hosting set \(company.name) --provider … --project … --account-id …")
        }
        guard let main = company.mainCommit else { throw WorkError.invalid("main has no engine-accepted commit yet (brahma main accept)") }
        let agents = try store.agents(companyId: companyId).filter { $0.state != .killed }.sorted { $0.name < $1.name }
        // The ops agent: a devops agent when there is one, else any agent whose role may propose a deploy.
        let proposers = agents.filter { store.catalog.template(role: $0.role, pack: company.packId).companyTools.contains("propose_deploy") }
        guard let ops = proposers.first(where: { $0.role == "devops" }) ?? proposers.first else {
            throw WorkError.invalid("the company has no ops agent that can propose a deploy")
        }
        let engineer = agents.first { $0.role == "engineer" } ?? ops
        let itemId = try itemKey.map { key -> String in
            guard let item = try store.workItem(companyId: companyId, key: key) else { throw WorkError.notFound("no work item \(key.uppercased())") }
            return item.id
        }
        var base = environment
        base["BRAHMA_DEV"] = nil

        // 1. The ops agent's deploy config and smoke check, then the smoke on main.
        try store.setDeployConfig(companyId: companyId, by: ops.id, build: build, outputDir: "dist",
                                  smoke: [SmokeRequest(method: "GET", path: "/")], expectText: expectText)
        try store.setSmokeCheck(companyId: companyId, by: ops.id, check: CheckSpec(command: smokeCommand, timeoutSeconds: 120))
        let sandbox = SandboxRunners.platformDefault(baseline: { Orchestrator.checkBaseline(store: store, paths: paths) },
                                                     proxies: EgressProxyPool())
        let checks = SmokeChecks(sandbox: sandbox, paths: paths, environment: base)
        let blocking = Blocking()
        let smoke = try await store.runSmoke(companyId: companyId, commit: main, reason: .manual, releaseId: nil, checks: checks,
                                             blocking: blocking, clock: Store.now)
        guard smoke.status == .passed else {
            throw WorkError.invalid("the smoke check did not pass on main (\(smoke.status.rawValue): \(Store.flat(smoke.outputTail ?? "", max: 300)))")
        }

        // 2. The dev token (engine-held) in the vault and the redactor; the dev host's folder; the no-op tool marker.
        if try !store.secrets(companyId: companyId).contains(where: { $0.name == tokenSecret }) {
            try store.setSecret(companyId: companyId, name: tokenSecret, value: devToken, isTest: false, vault: vault)
        }
        _ = try store.reloadRedactorIfNeeded(vault: vault, logFailures: false)
        let hostRoot = paths.home.appending(path: "dev-host", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(hostRoot)
        let hostDir = try EngineFiles.directory(workspace: hostRoot, company.slug, mode: 0o700)
        let server = try DevHostServer(base: hostDir)
        defer { server.stop() }
        let adapter = LocalCopyHostingAdapter(id: hosting.provider, hostDir: hostDir, server: server.url)
        let lookup: HostingAdapters.Lookup = { _ in adapter }
        let layout = try store.releaseLayout(companyId: companyId)
        try BrahmaPaths.ensurePrivateDirectory(layout.root)
        let bin = "tools/\(adapter.cli)/node_modules/.bin"
        try EngineFiles.directory(workspace: layout.root, bin, mode: 0o700)
        _ = try EngineFiles.create(Data("dev host: nothing to install (the deploy runs /bin/cp)\n".utf8), workspace: layout.root,
                                   dir: bin, name: adapter.cliBin)

        // 3. R-1: proposed by the ops agent, approved by the owner, carried out by the executor.
        let (proposed, ask) = try store.proposeDeploy(companyId: companyId, by: ops.id, version: firstVersion,
                                                      notes: "First release of main through the dev host.", vault: vault,
                                                      adapters: lookup, npmPresent: true)
        _ = try EngineFiles.removeNoFollow(hostDir.appending(path: proposed.ref, directoryHint: .isDirectory), under: hostDir)
        server.serve(folder: proposed.ref)
        _ = try store.ownerDecide(askId: ask.id, approve: true, note: "dev release scenario", owner: owner)
        let executor = ReleaseExecutor(
            store: store, paths: paths, sandbox: DevHostSandbox(base: sandbox, hostDir: hostDir), vault: vault,
            http: URLSessionHTTPProbe(),
            smoke: { companyId, commit, reason, releaseId, acceptedMain in
                try await store.runSmoke(companyId: companyId, commit: commit, reason: reason, releaseId: releaseId,
                                         acceptedMain: acceptedMain, checks: checks, blocking: blocking, clock: Store.now)
            },
            adapters: lookup, environment: base)
        await executor.advance(companyId: companyId, now: Store.now())
        guard let deployed = try store.release(companyId: companyId, ref: proposed.ref), deployed.status == .deployed else {
            let r = try store.release(companyId: companyId, ref: proposed.ref)
            throw WorkError.invalid("\(proposed.ref) is \(r?.status.rawValue ?? "gone"), not deployed: \(r?.failedReason ?? "no reason")")
        }
        server.stop()

        // 4. R-2, left proposed with its deploy ask pending.
        let (second, secondAsk) = try store.proposeDeploy(companyId: companyId, by: ops.id, version: secondVersion,
                                                          notes: "Streaks and reminders.", vault: vault, adapters: lookup,
                                                          npmPresent: true)

        // 5. Two human tasks: Stripe test keys (linked to the item) and a custom task with one url field.
        let stripe = try store.requestHumanTask(companyId: companyId, by: engineer.id, template: .stripeTestKeys, itemId: itemId,
                                                reason: nil).ask
        let custom = try store.requestHumanTask(
            companyId: companyId, by: ops.id, template: nil, title: "Share the status page link",
            steps: ["Create a free status page for the site", "Paste its public address below"],
            links: [HumanTaskLink(title: "Statuspage", url: "https://www.atlassian.com/software/statuspage")],
            fields: [HumanTaskField(name: "status_page_url", label: "Status page URL", kind: .url, required: true)],
            reason: "Uptime is shown on the site's footer.").ask
        return Summary(deployed: deployed, proposed: second, deployAsk: secondAsk, humanTasks: [stripe, custom], smoke: smoke)
    }
}
