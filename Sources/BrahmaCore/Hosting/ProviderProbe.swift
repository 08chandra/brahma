import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The owner-run live provider probe (Plan L Task 15, builder-check 9; `brahma hosting probe <company>`, hidden, owner only).
/// Deferred since Task 4 (PR-14): every Vercel pin, host list and output format was read from the CLI's package, never seen
/// against the real service, because the provider token is the owner's and never passes through an agent. The owner's
/// explicit run is the approval. With the company's engine-held `VERCEL_TOKEN` and account ID it:
/// 1. installs the pinned CLI token-free into `ReleaseLayout.deployTools` (as the executor does, when missing);
/// 2. stages an engine-written static page carrying a unique marker in a fresh folder under the releases root (no `.env`:
///    the engine's stager refuses one, so the `.env` item is a NOTE, not a verdict);
/// 3. runs the REAL `VercelAdapter` deploy plan through the REAL sandbox (token env-only, provider-config check, the
///    redactor-knows-token gate, pinned redaction, stdout-only URL parse, `vercel inspect` verification) against a throwaway
///    project `brahma-probe-<6 random [a-z0-9]>` (a reserved prefix, documented in the README), created and removed by
///    engine-composed `vercel project add|rm` steps;
/// 4. smokes its own deploy URL for the marker (the per-deploy URL parsed from the deploy step's stdout, pinned to the probe
///    project; the probe records no production URL, and never a guessed alias, final-review I6b); reads the hosts the CLI
///    contacted from the engine's egress proxy (allowed and denied) and whether the proxy was honoured; prints one verdict
///    per item the ledger left unverified;
/// 5. removes the project and lists what is left under the prefix.
/// Never run by a test or an agent: the adapter, sandbox, HTTP probe and environment are injectable so unit tests use the fake
/// adapter and FakeSandbox with no network.
public enum ProviderProbe {
    public static let projectPrefix = "brahma-probe-"
    public static let markerPrefix = "brahma-probe-marker-"
    public static let refusalAgent = "the provider probe is an owner command; it never runs inside an agent turn"
    public static let refusalProvider = "the provider probe runs against Vercel only; set the company's hosting provider to vercel first"
    public static let refusalToken = "the company has no VERCEL_TOKEN secret; store it with `brahma secret set <company> VERCEL_TOKEN`"
    public static let refusalAccount = "the company's hosting has no account ID; set it with `brahma hosting set <company> --account-id <team or account id>`"
    /// The output folder the probe's settings name (the page is staged by the probe itself; Vercel plans stage `.`).
    static let outputDir = "site"
    static let suffixAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public struct Report: Sendable {
        /// `brahma-probe-<suffix>`.
        public var project: String
        /// Engine-written verdict lines (redacted; the token is pinned out of every one).
        public var lines: [String]
        /// Every item passed and nothing was left behind.
        public var ok: Bool
        /// `brahma-probe-*` projects the final listing still shows.
        public var leftovers: [String]
    }

    /// The last pin over every report line (fix round 1, M2; defence in depth): the store's redactor, then the token itself
    /// when it was read. Every current line is already redacted where it is written; this keeps a future line that bypasses
    /// `tokenStep` from carrying the token.
    static func seal(_ lines: [String], token: String?, redactor: Redactor) -> [String] {
        let pin = Redactor()
        if let token, !token.isEmpty { pin.update([(name: "VERCEL_TOKEN", value: token)], version: "pinned") }
        return lines.map { pin.apply(redactor.apply($0)) }
    }

    /// Why the `.env` item is a NOTE (fix round 1, I3): the probe cannot decide it, and a real release never uploads one.
    static let envNote = "not decidable here: the engine refuses `.env` in release uploads (UploadStager), so a real deploy never "
        + "carries one, and the probe plants none (it would be served publicly); `.vercel` is refused by the config check before any step"

    /// Final-review I6a: the probe's `project add` hides whether a deploy to a project that does not exist fails.
    static let projectNote = "the probe created its own project (`vercel project add`); a real release never creates the project "
        + "(VERCEL_PROJECT_ID names it), so the owner creates it first; whether a deploy to a missing project fails is not decided here"

    /// Final-review I6c: not exercised by this probe.
    static let promotionNote = "not exercised: after `vercel rollback`, Vercel may stop assigning production to later `--prod` "
        + "deploys until `vercel promote`; only a deploy → rollback → deploy cycle would decide it"

    /// Six random `[a-z0-9]`.
    public static func randomSuffix() -> String {
        String((0..<6).map { _ in suffixAlphabet.randomElement()! })
    }

    public static func projectName(suffix: String) -> String { projectPrefix + suffix }

    /// `brahma-probe-` followed by exactly six lowercase letters or digits.
    public static func isProbeProject(_ name: String) -> Bool {
        name.range(of: "^\(projectPrefix)[a-z0-9]{6}$", options: .regularExpression) != nil
    }

    /// Runs the probe for `companyId`. Throws `WorkError` for a refusal (an agent shell, another provider, no token, no
    /// account, an engine running on the data home); anything that goes wrong while probing is a verdict line, not a throw.
    /// `sandbox` nil: the platform sandbox with the checks' baseline and `proxies` (the hosts report reads `proxies`).
    public static func run(store: Store, paths: BrahmaPaths, companyId: String, vault: any SecretVault,
                           sandbox: (any SandboxedRunner)? = nil, proxies: EgressProxyPool = EgressProxyPool(),
                           http: any HTTPProbing = URLSessionHTTPProbe(), adapters: HostingAdapters.Lookup = HostingAdapters.production,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           sleep: @escaping @Sendable (Duration) async -> Void = { try? await AwakeTime.sleep(for: $0) },
                           suffix: String? = nil) async throws -> Report {
        guard environment["BRAHMA_AGENT_ID"] == nil else { throw WorkError.forbidden(refusalAgent) }
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        guard let settings = try store.hosting(companyId: companyId), settings.provider == .vercel else {
            throw WorkError.invalid(refusalProvider)
        }
        let adapter = adapters(.vercel)
        guard try store.secrets(companyId: companyId).contains(where: { $0.name == adapter.tokenSecret }) else {
            throw WorkError.invalid(refusalToken)
        }
        guard let account = settings.accountId else { throw WorkError.invalid(refusalAccount) }
        let lock: OrchestratorLock
        do { lock = try OrchestratorLock.acquire(paths: paths) } catch OrchestratorLockError.alreadyRunning {
            throw WorkError.conflict("an engine is running on this data home; quit the app (or `brahma run`) first")
        }
        defer { withExtendedLifetime(lock) {} }
        let runner = sandbox ?? SandboxRunners.platformDefault(baseline: { Orchestrator.checkBaseline(store: store, paths: paths) },
                                                                proxies: proxies)
        var base = environment
        base["BRAHMA_DEV"] = nil
        let probe = Probe(store: store, paths: paths, company: company, settings: settings, account: account, adapter: adapter,
                          vault: vault.nonInteractive(), sandbox: runner, proxies: proxies, http: http, environment: base, sleep: sleep,
                          suffix: suffix ?? randomSuffix())
        return await probe.run()
    }

    // MARK: The run

    private struct StepResult {
        var exit: Int32?
        var timedOut: Bool
        var stdout: String
        var stderr: String
        var ok: Bool { exit == 0 && !timedOut }
        var detail: String { timedOut ? "timed out" : (exit.map { "exit \($0)" } ?? "could not start") }
    }

    private final class Probe {
        let store: Store, paths: BrahmaPaths, company: Company, adapter: any HostingAdapter, vault: any SecretVault
        let sandbox: any SandboxedRunner, proxies: EgressProxyPool, http: any HTTPProbing, environment: [String: String]
        let sleep: @Sendable (Duration) async -> Void
        let suffix: String, project: String, marker: String
        var settings: HostingSettings
        var lines: [String] = []
        var failures = 0
        var passes = 0
        var notes = 0
        /// The token once read: `finish()` pins it out of every line.
        var token: String?
        var leftovers: [String] = []
        var stepIndex = 0

        init(store: Store, paths: BrahmaPaths, company: Company, settings: HostingSettings, account: String, adapter: any HostingAdapter,
             vault: any SecretVault, sandbox: any SandboxedRunner, proxies: EgressProxyPool, http: any HTTPProbing,
             environment: [String: String], sleep: @escaping @Sendable (Duration) async -> Void, suffix: String) {
            self.store = store; self.paths = paths; self.company = company; self.adapter = adapter; self.vault = vault
            self.sandbox = sandbox; self.proxies = proxies; self.http = http; self.environment = environment; self.sleep = sleep
            self.suffix = suffix
            project = ProviderProbe.projectName(suffix: suffix)
            marker = ProviderProbe.markerPrefix + suffix
            var s = settings
            s.project = project
            s.accountId = account
            s.productionURL = nil
            s.customDomain = nil
            s.build = nil
            s.outputDir = ProviderProbe.outputDir
            s.smoke = []
            s.expectText = marker
            self.settings = s
        }

        func pass(_ item: String, _ text: String) { passes += 1; lines.append("PASS  \(item): \(text)") }
        func fail(_ item: String, _ text: String) { failures += 1; lines.append("FAIL  \(item): \(text)") }
        func note(_ item: String, _ text: String) { notes += 1; lines.append("NOTE  \(item): \(text)") }
        /// Context for the owner, not a ledger item (never counted in the verdict).
        func info(_ item: String, _ text: String) { lines.append("INFO  \(item): \(text)") }

        func run() async -> Report {
            lines.append("probe project \(project) (\(adapter.cli), hosts \(adapter.network.joined(separator: ", ")), install host \(adapter.toolNetwork.joined(separator: ", ")))")
            let layout: ReleaseLayout
            do { layout = try store.releaseLayout(companyId: company.id) } catch {
                fail("layout", "no releases folder for the company (\(ReleaseExecutor.text(error)))")
                return finish()
            }
            let probeDir = layout.root.appending(path: "probe-\(suffix)", directoryHint: .isDirectory)
            let home = probeDir.appending(path: "home", directoryHint: .isDirectory)
            let upload = probeDir.appending(path: "upload", directoryHint: .isDirectory)
            defer {
                _ = try? EngineFiles.removeNoFollow(probeDir, under: layout.root)
            }

            // The plan: the real adapter's, from the probe's settings, under the releases root.
            let commit = company.mainCommit ?? String(repeating: "0", count: 40)
            let input = DeployInput(settings: settings, commit: commit, version: "probe", releaseRoot: layout.root, releaseDir: probeDir,
                                    deployTools: layout.deployTools(cli: adapter.cli), placeholderDir: layout.placeholderDir)
            let plan: DeployPlan
            do { plan = try adapter.deployPlan(input) } catch {
                fail("plan", "the adapter refused the probe settings (\(ReleaseExecutor.text(error)))")
                return finish()
            }
            lines.append("plan:\n" + plan.display.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))

            // The page (and nothing else: no `.env`, which the engine's own uploads never carry).
            do {
                try BrahmaPaths.ensurePrivateDirectory(layout.root)
                try EngineFiles.remove(workspace: layout.root, dir: "", name: "probe-\(suffix)")
                try EngineFiles.directory(workspace: layout.root, "probe-\(suffix)", mode: 0o700)
                try EngineFiles.directory(workspace: layout.root, "probe-\(suffix)/home", mode: 0o700)
                try EngineFiles.directory(workspace: layout.root, "probe-\(suffix)/upload", mode: 0o700)
                let page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Brahma provider probe</title></head>"
                    + "<body><p>\(marker)</p><p>This throwaway page was deployed by Brahma's provider probe and is removed by it.</p></body></html>\n"
                _ = try EngineFiles.create(Data(page.utf8), workspace: layout.root, dir: "probe-\(suffix)/upload", name: "index.html")
            } catch {
                fail("stage", "could not write the probe page (\(ReleaseExecutor.text(error)))")
                return finish()
            }

            // The token, under the executor's rule: read, passable, demonstrably redacted; else nothing runs with it.
            let token: String
            do { token = try readToken(plan); self.token = token } catch let e as WorkError {
                fail("token", e.message)
                return finish()
            } catch {
                fail("token", ReleaseExecutor.text(error))
                return finish()
            }

            // 1. The CLI, token-free.
            let toolEnvironment = ChildEnvironment.make(base: environment, extra: ["BRAHMA_AGENT_ID": "probe"], purpose: .check)
            let tools = layout.deployTools(cli: adapter.cli)
            let bin = tools.appending(path: "node_modules/.bin/\(adapter.cliBin)", directoryHint: .notDirectory)
            if ReleaseExecutor.exists(bin) {
                pass("CLI pin", "\(adapter.cli) already installed at \(bin.path)")
            } else {
                let install = await installTools(tools: tools, home: home, layout: layout, environment: toolEnvironment)
                guard install.ok, ReleaseExecutor.exists(bin) else {
                    fail("CLI pin", "installing \(adapter.cli) failed (\(install.detail)); tail: \(Store.flat(String(install.stdout.suffix(300) + " " + install.stderr.suffix(300)), max: 600))")
                    let proxy = proxies.existing(for: adapter.toolNetwork)
                    note("install hosts", hostsText(proxy))
                    return finish()
                }
                pass("CLI pin", "\(adapter.cli) installed token-free from \(adapter.toolNetwork.joined(separator: ", ")) (\(hostsText(proxies.existing(for: adapter.toolNetwork))))")
            }

            // 2. The project, then every plan step with the token.
            func stepArgv(_ words: [String]) -> [String] { [input.bin(adapter.cliBin)] + words }
            let created = await tokenStep(stepArgv(["project", "add", project]), plan: plan, token: token, home: home, tools: tools, probeDir: probeDir)
            if created.ok {
                pass("project add", "\(project) created (\(Store.flat(String(created.stdout.suffix(200)), max: 200)))")
            } else {
                fail("project add", "\(created.detail); stdout: \(Store.flat(String(created.stdout.suffix(300)), max: 300)); stderr: \(Store.flat(String(created.stderr.suffix(300)), max: 300))")
            }
            var deployed = created.ok
            var deployStdout = "", deployStderr = ""
            if deployed {
                let deployStep = plan.steps.lastIndex { $0.label == "deploy" } ?? (plan.steps.count - 1)
                for (i, step) in plan.steps.enumerated() {
                    let r = await tokenStep(step.argv, plan: plan, token: token, home: home, tools: tools, probeDir: probeDir)
                    let tolerated = step.okIfOutputContains.map { r.stdout.contains($0) || r.stderr.contains($0) } ?? false
                    guard r.ok || (!r.timedOut && tolerated) else {
                        fail("deploy", "the \(step.label) step failed (\(r.detail)); stdout: \(Store.flat(String(r.stdout.suffix(400)), max: 400)); stderr: \(Store.flat(String(r.stderr.suffix(400)), max: 400))")
                        deployed = false
                        break
                    }
                    if i == deployStep { deployStdout = r.stdout; deployStderr = r.stderr }
                }
            }
            var deployURL: URL?
            if deployed {
                pass("deploy", "every plan step exited 0")
                info("deploy output", "stdout tail (redacted): \(Store.flat(String(deployStdout.suffix(300)), max: 300))")
                // Which stream carried "Production:" (stdout-only parsing; the bare-URL fallback otherwise).
                let onOut = deployStdout.contains("Production:"), onErr = deployStderr.contains("Production:")
                switch (onOut, onErr) {
                case (true, _): pass("Production: on stdout", "the deploy step printed \"Production:\" on stdout" + (onErr ? " (and stderr)" : ""))
                case (false, true): note("Production: on stdout", "\"Production:\" was printed on stderr only; the stdout bare-URL fallback must do the work")
                case (false, false): note("Production: on stdout", "no \"Production:\" line on either stream")
                }
                deployURL = adapter.deployURL(fromOutput: deployStdout, settings: settings)
                if let url = deployURL {
                    pass("deploy URL", "parsed from stdout: \(url.absoluteString)")
                    reportHash(url)
                } else {
                    let urls = deployStdout.split(whereSeparator: \.isNewline).filter { $0.contains("https://") }.suffix(3).map { Store.flat(String($0), max: 200) }
                    fail("deploy URL", "no per-deploy URL of \(project) on stdout; URL-like stdout lines: \(urls.isEmpty ? "none" : urls.joined(separator: " | ")); stderr tail: \(Store.flat(String(deployStderr.suffix(300)), max: 300))")
                }
                // The verify step, as the executor runs it.
                if let url = deployURL, let argv = plan.verifyArgv(url: url) {
                    let v = await tokenStep(argv, plan: plan, token: token, home: home, tools: tools, probeDir: probeDir)
                    if v.ok, adapter.verifiesDeployment(output: v.stdout + "\n" + v.stderr, settings: settings) {
                        pass("inspect", "`\(adapter.cliBin) inspect` exited 0 and named exactly \(project)")
                    } else {
                        let names = (v.stdout + "\n" + v.stderr).split(whereSeparator: \.isNewline).filter { $0.contains("name") || $0.contains("id") }.prefix(6)
                        fail("inspect", "\(v.detail); the output did not verify the project (lines: \(names.map { Store.flat(String($0), max: 120) }.joined(separator: " | ")))")
                    }
                } else if plan.verify != nil {
                    fail("inspect", "skipped: no deploy URL to verify")
                }
            }

            // 3. The smoke of the site at the probe's own deploy URL (it records no production URL), for the marker.
            if deployed {
                if let base = adapter.smokeBase(settings, deployURL: deployURL) {
                    let smoked = await DeploySmoke.run(base: base, requests: [], expectText: marker, http: http, sleep: sleep)
                    if smoked.ok {
                        pass("smoke", "GET \(base.absoluteString) answered \(smoked.results.first?.status ?? 0) with the marker")
                    } else {
                        let first = smoked.results.first { !$0.ok }
                        fail("smoke", "GET \(base.absoluteString): \(first?.error ?? "no result") (status \(first?.status.map(String.init) ?? "none"))")
                    }
                } else {
                    fail("smoke", "no smoke base")
                }
            } else {
                note("smoke", "skipped: nothing was deployed")
            }
            note(".env not read", ProviderProbe.envNote)
            // Final-review I6a/I6c: what this run cannot show, said rather than implied by a pass.
            note("project exists", ProviderProbe.projectNote)
            note("promotion after rollback", ProviderProbe.promotionNote)
            note("GIT_CEILING_DIRECTORIES", "set to \(plan.env["GIT_CEILING_DIRECTORIES"] ?? "(unset)") on every token step; a `.git` between the deploy folder and the releases root is refused by the config check; a repository above the root cannot be planted by this probe, so the ceiling itself is reported, not exercised")

            // 4. The hosts the CLI contacted (the egress proxy's allow and deny logs) and whether the proxy was honoured.
            let proxy = proxies.existing(for: plan.network)
            if let proxy {
                let allowed = Array(Set(proxy.allowedHosts)).sorted(), denied = Array(Set(proxy.deniedHosts)).sorted()
                if !allowed.isEmpty {
                    pass("HTTPS_PROXY honoured", "the CLI's TLS connections went through the engine's proxy (\(allowed.count) connections)")
                } else if deployed {
                    fail("HTTPS_PROXY honoured", "the deploy succeeded with no connection through the engine's proxy")
                } else {
                    note("HTTPS_PROXY honoured", "no connection through the proxy")
                }
                if denied.isEmpty {
                    pass("network hosts", "allow-list \(plan.network.joined(separator: ", ")) was sufficient; contacted: \(allowed.isEmpty ? "none" : allowed.joined(separator: ", "))")
                } else {
                    fail("network hosts", "refused: \(denied.joined(separator: ", ")); contacted: \(allowed.isEmpty ? "none" : allowed.joined(separator: ", ")) (add the refused hosts to VercelAdapter.network if the CLI needs them)")
                }
            } else {
                note("network hosts", "no egress proxy was started for \(plan.network.joined(separator: ", ")) (a non-proxying sandbox)")
                note("HTTPS_PROXY honoured", "not decided: no egress proxy ran")
            }

            // 5. The project goes; what is left under the prefix is reported.
            let removed = await tokenStep(stepArgv(["project", "rm", project, "--yes"]), plan: plan, token: token, home: home, tools: tools, probeDir: probeDir)
            if removed.ok {
                pass("project removed", "\(project) removed")
            } else {
                fail("project removed", "\(removed.detail); remove \(project) in the Vercel dashboard; stderr: \(Store.flat(String(removed.stderr.suffix(300)), max: 300))")
            }
            let listed = await tokenStep(stepArgv(["project", "ls"]), plan: plan, token: token, home: home, tools: tools, probeDir: probeDir)
            if listed.ok {
                let words = (listed.stdout + "\n" + listed.stderr).split(whereSeparator: { $0.isWhitespace || $0 == "\n" }).map(String.init)
                leftovers = Array(Set(words.filter { $0.hasPrefix(ProviderProbe.projectPrefix) && HostingSettings.isValidProject($0) })).sorted()
                if leftovers.isEmpty {
                    pass("leftover projects", "none under \(ProviderProbe.projectPrefix)*")
                } else {
                    fail("leftover projects", "still listed: \(leftovers.joined(separator: ", ")) (remove them in the Vercel dashboard)")
                }
            } else {
                fail("leftover projects", "`\(adapter.cliBin) project ls` failed (\(listed.detail)); check the dashboard for \(ProviderProbe.projectPrefix)* projects")
            }
            return finish()
        }

        func finish() -> Report {
            // NOTE lines are items this run could not decide: counted, never folded into "ok" as passes (fix round 1, M1).
            lines.append(failures == 0 ? "VERDICT ok: \(passes) passed, \(notes) noted (not decided)"
                                       : "VERDICT \(failures) item\(failures == 1 ? "" : "s") failed (\(passes) passed, \(notes) noted)")
            return Report(project: project, lines: ProviderProbe.seal(lines, token: token, redactor: store.redactor), ok: failures == 0,
                          leftovers: leftovers)
        }

        /// The 9-character hash segment Vercel is believed to put after the project (unverified until this probe).
        func reportHash(_ url: URL) {
            let host = url.host ?? ""
            guard host.hasSuffix(".vercel.app") else { note("9-char URL hash", "not a vercel.app URL (\(host)); nothing to check"); return }
            let rest = host.hasPrefix(project + "-") ? String(host.dropFirst(project.count + 1)) : host
            let segment = rest.split(separator: "-").first.map(String.init) ?? ""
            if VercelAdapter.isDeployURL(url.absoluteString, project: project) {
                pass("9-char URL hash", "the URL matched `<project>-[a-z0-9]{9}-<scope>.vercel.app` (segment \(segment), \(segment.count) chars)")
            } else {
                fail("9-char URL hash", "the URL did not match the strict form (segment after the project: \(segment), \(segment.count) chars)")
            }
        }

        /// The executor's token rule (`ReleaseExecutor.readToken`): read from the vault, passable, demonstrably redacted.
        func readToken(_ plan: DeployPlan) throws -> String {
            _ = try store.reloadRedactorIfNeeded(vault: vault, logFailures: false)
            guard let token = try vault.value(companyId: company.id, name: plan.tokenSecret), !token.isEmpty else {
                throw WorkError.invalid("the provider token \(plan.tokenSecret) could not be read from the vault")
            }
            guard ChildEnvironment.droppedSecretNames([plan.tokenSecret: token]).isEmpty else {
                throw WorkError.invalid("the provider token \(plan.tokenSecret) cannot be passed to a deploy step")
            }
            guard ReleaseExecutor.redacts(store: store, token: token) else {
                throw WorkError.invalid("the hosting token \(plan.tokenSecret) isn't loaded for redaction (or is too short to redact); nothing ran with it")
            }
            return token
        }

        func hostsText(_ proxy: EgressProxy?) -> String {
            guard let proxy else { return "no egress proxy ran" }
            let allowed = Array(Set(proxy.allowedHosts)).sorted(), denied = Array(Set(proxy.deniedHosts)).sorted()
            return "contacted: \(allowed.isEmpty ? "none" : allowed.joined(separator: ", ")); refused: \(denied.isEmpty ? "none" : denied.joined(separator: ", "))"
        }

        /// `npm install --prefix <tools> … <cli>` as `ReleaseExecutor.ensureTools` runs it: token-free, the install hosts only.
        func installTools(tools: URL, home: URL, layout: ReleaseLayout, environment: [String: String]) async -> StepResult {
            do {
                try BrahmaPaths.ensurePrivateDirectory(layout.root.appending(path: "tools", directoryHint: .isDirectory))
                try EngineFiles.directory(workspace: layout.root, "tools/\(adapter.cli)", mode: 0o700)
            } catch { return StepResult(exit: nil, timedOut: false, stdout: "", stderr: "the tools folder is not safe to use (\(ReleaseExecutor.text(error)))") }
            let resolved = URL(fileURLWithPath: SandboxPath.resolve(tools.path), isDirectory: true)
            var env = environment
            env["HOME"] = home.path
            let out = home.appending(path: "install.out", directoryHint: .notDirectory)
            let command = ShellQuote.joinArgv(["npm", "install", "--prefix", tools.path, "--no-audit", "--no-fund", adapter.cli], rawRefs: [])
            // Plan S Task S7: the factory's `.providerProbe` rule, the executor's install shape (engine principals: never Full).
            let decision = ReleaseExecutor.toolDecision(.providerProbe, writable: [resolved], readable: [resolved], network: adapter.toolNetwork,
                                                        baseline: sandbox.policyBaseline())
            let outcome = await sandbox.run(command: command, cwd: tools, environment: env, timeout: ReleasePolicy.stepTimeout, outputURL: out,
                                            decision: decision)
            _ = try? EngineFiles.removeNoFollow(tools.appending(path: ".brahma-tmp"), under: layout.root)
            let text = store.redactor.apply(EngineFiles.readNoFollow(out, under: layout.root, limit: 1 << 20).map { String(decoding: $0, as: UTF8.self) } ?? outcome.tail)
            _ = try? EngineFiles.removeNoFollow(out, under: layout.root)
            return StepResult(exit: outcome.exitCode, timedOut: outcome.timedOut, stdout: text, stderr: "")
        }

        /// One token step as `ReleaseExecutor.tokenStep` runs it: the provider config check, engine-composed argv, the token
        /// only in the environment, stdout and stderr to engine-only files under the releases root, both redacted by the
        /// store's redactor AND with the token pinned, then removed.
        func tokenStep(_ argv: [String], plan: DeployPlan, token: String, home: URL, tools: URL, probeDir: URL) async -> StepResult {
            stepIndex += 1
            do { try adapter.refuseProviderConfig(plan, releaseRoot: probeDir.deletingLastPathComponent()) } catch {
                return StepResult(exit: nil, timedOut: false, stdout: "", stderr: (error as? WorkError)?.message ?? ReleaseExecutor.text(error))
            }
            let out = probeDir.appending(path: "step-\(stepIndex).out", directoryHint: .notDirectory)
            let err = home.appending(path: "step-\(stepIndex).err", directoryHint: .notDirectory)
            let cwd = URL(fileURLWithPath: plan.cwdPath, isDirectory: true)
            func real(_ url: URL) -> URL { URL(fileURLWithPath: SandboxPath.resolve(url.path), isDirectory: true) }
            var env = ChildEnvironment.make(base: environment, extra: ["BRAHMA_AGENT_ID": "probe"], purpose: .check, secrets: [plan.tokenSecret: token])
            env["HOME"] = home.path
            for (name, value) in plan.env where name != plan.tokenSecret { env[name] = value }
            let command = ShellQuote.joinArgv(argv, rawRefs: []) + " 2>>" + ShellQuote.quote(err.path)
            // Plan S Task S7: the factory's `.providerProbe` rule, the executor's token-step shape.
            let decision = ReleaseExecutor.toolDecision(.providerProbe, writable: [real(home), real(cwd)], readable: [real(cwd), real(tools)],
                                                        network: plan.network, baseline: sandbox.policyBaseline())
            let outcome = await sandbox.run(command: command, cwd: cwd, environment: env, timeout: ReleasePolicy.stepTimeout, outputURL: out,
                                            decision: decision)
            let pin = Redactor()
            pin.update([(name: plan.tokenSecret, value: token)], version: "pinned")
            func text(_ url: URL) -> String {
                defer { _ = try? EngineFiles.removeNoFollow(url, under: probeDir) }
                guard let data = EngineFiles.readNoFollow(url, under: probeDir, limit: 1 << 20) else { return "" }
                return pin.apply(store.redactor.apply(String(decoding: data, as: UTF8.self)))
            }
            let stdout = text(out), stderr = text(err)
            return StepResult(exit: outcome.exitCode, timedOut: outcome.timedOut, stdout: stdout, stderr: stderr)
        }
    }
}
