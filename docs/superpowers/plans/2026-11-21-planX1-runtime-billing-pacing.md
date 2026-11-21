# Plan X1 — Runtime seam, provider gateway, billing and pacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution:** subagent-driven, on a branch cut from `main` **after Plans S, R and P are merged and `main` is green**. Model policy (owner, 2026-11-21): Fable for implementers and routine reviews; **Opus (high)** for the security-touching tasks (X1-T4, T7, T8, T9, T10, T11, T13, T16) and the final review. Never Sonnet or Haiku.

**Goal:** Put every runtime-specific behaviour behind one `AgentRuntime` interface, with the Claude adapter byte-identical to today. Remove the ambient Claude auth path. Add an engine-side **provider gateway** (the spec's model proxy, generalized by owner decision 20) that holds every model key, speaks the Anthropic Messages format to `claude`, and routes to the Anthropic API or any OpenAI-compatible provider under per-provider dollar caps. Add per-company billing modes (`subscription`, `api-key`, `fallback`), model routes per company, role and agent, a capability probe that gates each routed model, and the owner-wide pacing presets with `conservative` as the default.

**Architecture:**
- Two new SwiftPM targets in R's layered graph (controller's call; Task 0 fixes the exact edges against R as merged):
  - `BrahmaRuntime` (above `BrahmaDomain`, below `BrahmaAgentTools` and `BrahmaEngine`): the `AgentRuntime` protocol and its value types, `RuntimeCatalog`, and the Claude adapter (`ClaudeRuntime`), which wraps today's `TurnProfileCompiler`, `ClaudeSettingsCompiler` and `StreamParser` unchanged. It does not depend on `BrahmaGateway`.
  - `BrahmaGateway` (above `BrahmaStore`, and above `BrahmaDomain` only if Task 0 finds `SecretVault` or `EmergencyStopObserver` there; below `BrahmaEngine`; no dependency on `BrahmaRuntime`): the loopback HTTP server, the token registry, the canonical request type, provider adapters (`anthropic`, `openai-compatible`), stream translation, the meter, the price book and the upstream transport.
  - **Shared value types go down to `BrahmaModel/Gateway/`** so no layer imports upward: `ModelClass`, `GatewayToken`, `GatewayLaunch`, `ModelRoute`, `RouteScope`, `ModelProbeLevel`, `ModelProbeRecord`, `ProbeStepResult`, `Provider`, `ProviderCaps`, `GatewayCharge`, `BillingMode`, `PacingPresetName`, `PriceRow`. The kernel's token-format check is `TurnTokenFormat.isWellFormed` in `BrahmaSafety` (Task 4), and `GatewayToken.isWellFormed` delegates to it. `BrahmaEngine` is the only target that imports both `BrahmaRuntime` and `BrahmaGateway`.
- One kernel addition in `BrahmaSafety`: `Net/LoopbackListener.swift` (a TCP listener bound to `127.0.0.1` only), beside R's `LocalSocket`, security-reviewed like it.
- The engine (R's `EngineService`) starts the gateway after the doctor and registers it as an `EmergencyStopObserver`. R's `TurnLauncher` decides each turn's auth (`LaunchAuth.decide`), mints a turn token, and revokes it at turn end. R's `UsageStep` gains billing fallback, per-provider caps and the pacing presets. Probes run in a new `ModelProbeStep` tick participant.
- The gateway reaches providers only with `URLSession` routed through S's `EgressProxyPool` (allowlist = the provider's pinned host, public addresses only, port 443), redirects refused.

**Tech Stack:** Swift 6.2 toolchain (manifest `swift-tools-version: 6.0`, `.macOS(.v14)`), SwiftPM, GRDB.swift 7.x, swift-argument-parser 1.5+, Swift Testing, POSIX sockets, `URLSession` (Darwin; FoundationNetworking compiles on Linux but the upstream is unavailable there until Plan 8).

**Spec:** `docs/superpowers/specs/2026-11-21-any-product-and-hedges-design.md` (cited as *spec §n*), especially owner decisions 1, 2, 3, 9 and **20**, §5 (anti-goals), §8.1 (runtime layer), §8.2 (billing, proxy, pacing, **§8.2.5 provider gateway**), §9.2, §10 rows 1, 3 and 12, §12 and §13. Owner decisions are binding; "controller's call" items are binding unless the controller rules otherwise.

**Builds on (all merged first), with the exact names this plan consumes:**
- **Plan S** (`plan-engine-safety`, `docs/superpowers/plans/2026-11-21-planS-engine-safety.md`): `BrahmaSafety` (S3) holding `ChildEnvironment`, `PermissionProfile`, `EgressProxy`/`EgressProxyPool`, `SeatbeltRunner`; `Spawn`/`ToolPaths` (S5); `Decision<T>`, `bestEffort`, `AlertScope` (S4); `PrincipalResolver` (S6); `SandboxPolicyFactory`/`Purpose` (S7); `RenderedPrompt`/`PromptBuilder`/`Trusted`/`Untrusted` (S13), with `TurnRequest.prompt: RenderedPrompt`; `ToolOutput` (S14); `SafetyLintTests` and its shrink-only baseline (S1); the helper canary probes (S16).
- **Plan R** (`plan-refactor-polish`, `…/2026-11-21-planR-restructure-service.md`): the targets `BrahmaFoundation → BrahmaModel → BrahmaStore → BrahmaGit → BrahmaDomain → BrahmaAgentTools → BrahmaEngine → BrahmaCore`; `ModuleGraphTests.allowedEdges`, `PublicSurfaceTests` + `public-surface.txt`, `GuardAllowlistTests`; `TickParticipant`, `TickStepID`, `TickGates`, `TickContext`, `TaskRegistry`, `TickOrderTests.orderIsPinned`, `TickGatesTests` (R Tasks 9–11); `UsageStep` producing `UsageDecisions { decisions, paceClosed, paceStrict }`; `CanaryStep`; `TurnLauncher` (R Task 11); `EngineService` and `EngineServiceDeps` (R Task 15); `LocalSocket` (R Task 14); `BrahmaTestSupport`; the test targets of R Task 12.
- **Plan P** (`…/2026-11-21-planP-polish.md`): test tiers (`.processTier`, `.liveTier`, `UnitTierHygieneTests`), `Signal`, `TemplateRepo`; `ChangeTopics.map`/`unobserved` with `everyTableMapped`; `CLITreeFrozenTests` + `cli-tree.tsv`, `CLIHelpTests`, `CLIErrorStyleTests`, `CLIHintTests`; `ScreenInventoryTests`, `ThemeLintTests`, shared `EmptyState`/`LoadingState`/`ErrorState`; `ScriptedTurnRunner` and `scripts/fake-claude.sh` role scripts; `scripts/test.sh`.

Where the merged code differs from these names, **Task 0 records the drift and every later task uses Task 0's names.**

## Global Constraints

From S, R and P, still binding:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The manifest stays `swift-tools-version: 6.0` and `.macOS(.v14)`.
- Swift 6, SwiftPM, GRDB, Swift Testing; one `@Suite struct <FileName>` per new test file.
- Core targets (`BrahmaRuntime`, `BrahmaGateway` included) stay Linux-portable: no AppKit, SwiftUI, Observation, UserNotifications, CryptoKit or `Bundle.module`. Darwin-only code sits behind `#if canImport(Darwin)`.
- Child processes only through S's `Spawn` with `ToolPaths`; engine files only through `EngineFiles`/`Place`; sockets only through `LocalSocket` or this plan's `LoopbackListener`. `SafetyLintTests` gains **one** allowlisted entry only: `Sources/BrahmaGateway/Upstream.swift` (`URLSession`, if S's rules match it), with the reason "gateway upstream through the egress proxy", recorded under an Opus review in Task 8; nothing else. `try?`, `?? true`, `?? false` and empty `catch {}` are banned in `Sources/BrahmaGateway` and `Sources/BrahmaRuntime` (added to S's `failOpen` zero scope in Task 2).
- Prompts and tool outputs are `RenderedPrompt`/`ToolOutput` built by `PromptBuilder`. Agent- or provider-controlled text printed by the CLI goes through `safe()`; in the app through `Text(verbatim:)`/`SafeMarkdown`.
- Durations use awake time (`AwakeTime`) or company-active seconds; every clock is injected.
- **Tests never touch** the real Keychain, launchd, the network, or a model API. Live tests are `.liveTier` (`BRAHMA_LIVE=1`) and use owner-provided keys entered by the owner, never by an agent.
- Unit-tier tests bind no port and spawn no process (P's hygiene). Tests that do are `.processTier`.
- **Existing CLI commands are unchanged.** This plan adds commands and subcommands only, each with an abstract, help and `EXAMPLES:` that satisfy P's `CLIHelpTests`, errors in P's shape, and a row appended to `cli-tree.tsv` (never an edited row). **Every** new command and subcommand, including the read-only ones (`billing <co>`, `providers list`, the printing form of `company models`, `settings model-price` with no arguments), refuses inside an agent turn (`BRAHMA_AGENT_ID` set) per spec §12; those that change state also call `requireOwnerShell()`. Each command's tests include `refusedInsideAgentTurn`.
- Every new table is mapped in P's `ChangeTopics.map` (topic `usage` unless stated) or listed in `unobserved` with a reason.
- New public names are appended to R's `public-surface.txt` in the same commit; nothing existing is removed.
- **The app keeps its ops-console layout.** New panels use P's components and theme tokens; `ScreenInventoryTests` baseline changes only by additions, in a commit tagged `approved Plan X spec §12`.
- Fail closed: an unavailable runtime, gateway, provider, key, price, cap or probe means "unavailable" with the reason, never a weaker path (spec §5).
- **Agents never handle secrets.** Keys enter only through `brahma secret set` (owner shell, stdin) or the app's secure field. No key appears in any agent-readable file, environment, argv, prompt, tool result, transcript, log or the database.
- Nothing deploys without owner approval. Never `pkill`; never kill a process you did not start. Never run two worktrees' full suites at once.
- Every task ends with `swift build` green for all targets and `scripts/test.sh unit` green; tasks touching processes also run `scripts/test.sh process`.
- Every commit message ends with:
  `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`

**Pinned numbers** (each a `static let` on the named type):

| Constant | Value | Owner |
|---|---|---|
| Gateway bind | `127.0.0.1`, ephemeral port, never another address | `LoopbackListener` |
| Gateway path prefix | `/t/` (base URL `http://127.0.0.1:<port>/t/`) | `GatewayRoutes.prefix` |
| Served endpoints | `POST /t/v1/messages`, `POST /t/v1/messages/count_tokens`; everything else 404 | `GatewayRoutes.allowed` |
| Request caps | headers ≤ 32 KiB · body ≤ 32 MiB · request line ≤ 8 KiB | `GatewayLimits` |
| Turn token | 32 random bytes, lowercase hex (64 chars); accepted as `x-api-key` or `Authorization: Bearer` | `GatewayToken` |
| Token lifetime | new requests are refused the moment the turn ends; a response already streaming may finish within 30 s awake, then is cut | `TurnTokenRegistry.inFlightGrace` |
| Upstream | connect 10 s · idle stream 300 s awake · ≤ 32 concurrent requests per engine | `GatewayLimits` |
| Cap refusal | HTTP 429, `{"type":"error","error":{"type":"rate_limit_error","message":"Brahma: <reason>"}}`; Task 0 may switch the status to 400 `invalid_request_error` if X1-0 shows `claude` retries 429 indefinitely | `GatewayRefusal` |
| Default daily cap | monthly ÷ 20 | `ProviderCaps.defaultDailyDivisor` |
| Reservation / missing usage | input `ceil(bodyBytes / 3)` tokens at the higher of the input and cache-write prices; output `max_tokens`; the same estimate is charged when usage is missing | `GatewayMeter.estimate` |
| `count_tokens` on non-Anthropic adapters | `ceil(canonicalBytes / 4)`, answered locally | `OpenAICompatibleAdapter.countEstimate` |
| Capability probe | streaming · context = min(declared, 64 000 tokens) · tools ≥ 19/20 single + 5/5 multi-step · agentic smoke ≤ 300 s; each other step ≤ 120 s | `ModelProbe.thresholds` |
| Probe validity | keyed by (provider, model, adapter version, `claude` version); re-probe after 30 days | `ModelProbeRecord.maxAge` |
| Pacing `conservative` (default) | concurrency 2 · five-hour 0.60 · reserve 0.50 · daily share `(1 − r) / 7 + 0.05`, no catch-up · audits and standups skipped on owner-calendar days with no landing | `PacingPreset.conservative` |
| Pacing `standard` | company mode cap · mode threshold (0.80 / 0.90 / 0.97) · reserve 0.30 · weekly burst 0.15 (today) | `PacingPreset.standard` |
| Pacing `full` | hard cap · 0.97 · reserve owner-set, min 0.10 · weekly burst 0.15 | `PacingPreset.full` |
| Gateway overhead (p95, release, excluding upstream) | non-streamed ≤ 5 ms · first streamed byte forwarded ≤ 10 ms after upstream | `GatewayBudgets` |

## Review Focus

1. **`claude` quietly uses the owner's subscription login on a gateway turn,** for example after the gateway answers 401 or 429, so a capped company keeps spending on the subscription (or an API-mode turn is billed nowhere). Expected: a gateway turn either completes through the gateway or fails; it never reaches `api.anthropic.com` directly. → X1-0 probe item 2; Task 14 `LaunchAuthTests.gatewayTurnHasNoSubscriptionPath` (env and argv contain the gateway base URL, the token and the deny-all proxy variables); Task 16 `LiveGateway/noSubscriptionFallback`.
2. **Concurrent streamed requests overrun a cap.** Ten agents of one company stream at once with $0.10 left. Expected: total spend ≤ cap + one request's maximum cost. → Task 9 `GatewayMeterTests.concurrentRequestsNeverExceedCapPlusOneMax` (property, `FuzzConfig.cases`).
3. **A hostile or broken provider stream:** a 50 MB SSE event, a stream that never ends, a tool-call argument JSON split across 1-byte chunks, invalid UTF-8, a usage block claiming −5 or 10¹² tokens, a `[DONE]` before any content. Expected: bounded memory, the turn ends with an error event `claude` understands, and the charge is the fallback estimate, never negative or absurd. → Task 10 `OpenAICompatibleStreamTests.hostileStreamsAreBounded`.
4. **Endpoint and host smuggling:** `/t/v1/messages/../files`, `%2e%2e`, `//v1/batches`, absolute-form `POST http://evil/ …`, a `Host` header naming another provider, CRLF in a header value forwarded upstream, a provider base URL that redirects. Expected: only the two endpoints are served, only the pinned host is reached, no request header from the client is forwarded except an allowlist. → Task 7 `GatewayServerTests.onlyModelEndpointsServed`; Task 8 `AnthropicAdapterTests.forwardsOnlyAllowlistedHeaders`; Task 11 `ProviderHostTests.redirectingBaseURLRefused`.
5. **A provider key escapes:** an upstream 401 body echoing the key, a key logged in an error, the key in a transcript, the turn's environment or the database. Expected: every upstream error is redacted with the vault's value before it is relayed or stored, and a full gateway turn leaves the key nowhere. → Task 8 `AnthropicAdapterTests.upstreamErrorRedactsKey`; Task 16 `GatewayKeyLeakTests.keyNowhereAfterTurn`.

---

## File Structure

```
Package.swift                                          + targets BrahmaRuntime, BrahmaGateway; + test targets BrahmaRuntimeTests, BrahmaGatewayTests
Sources/BrahmaSafety/Net/LoopbackListener.swift        TCP listen on 127.0.0.1 only (kernel; Opus review)
Sources/BrahmaSafety/Process/ChildEnvironment.swift    claudeAuth removed; gatewayVariables admitted only from the compiled LaunchSpec
Sources/BrahmaRuntime/AgentRuntime.swift               protocol + RuntimeId, TurnShape, AuthRoute, ProbeGateId, ProbeEnvironment, RuntimeProbe
Sources/BrahmaRuntime/LaunchSpec.swift                 LaunchSpec, LaunchFile, LaunchSandbox
Sources/BrahmaRuntime/TurnEvent.swift                  TurnEvent (today's StreamEvent, moved and renamed) + RuntimeStreamParser
Sources/BrahmaRuntime/ModelClass.swift                 ModelClass, family mapping
Sources/BrahmaRuntime/RuntimeCatalog.swift             the only place runtime ids appear
Sources/BrahmaRuntime/Claude/ClaudeRuntime.swift       adapter over TurnProfileCompiler/ClaudeSettingsCompiler/StreamParser (moved here)
Sources/BrahmaRuntime/Claude/ClaudeGatewayCompile.swift   gateway turns: aliases, env, deny-all proxy, optional per-agent config dir
Sources/BrahmaGateway/GatewayServer.swift              HTTP/1.1 framing, SSE writer, serve(connection:)
Sources/BrahmaGateway/GatewayRoutes.swift              path and header allowlists
Sources/BrahmaGateway/TurnTokenRegistry.swift          mint, look up, revoke, expire; EmergencyStopObserver
Sources/BrahmaGateway/Canonical.swift                  CanonicalRequest/Response/StreamEvent (Anthropic Messages-shaped)
Sources/BrahmaGateway/Adapters/ProviderAdapter.swift   protocol + AdapterId
Sources/BrahmaGateway/Adapters/AnthropicAdapter.swift
Sources/BrahmaGateway/Adapters/OpenAICompatibleAdapter.swift   + OpenAICompatibleStream.swift
Sources/BrahmaGateway/Upstream.swift                   UpstreamTransport + EgressUpstreamTransport
Sources/BrahmaGateway/GatewayMeter.swift               reservations, charges, cap checks
Sources/BrahmaGateway/PriceBook.swift                  pinned rows + owner rows
Sources/BrahmaGateway/ModelGateway.swift               composition: server + registry + adapters + meter
Sources/BrahmaGateway/ModelProbe.swift                 capability probe steps 1–3
Sources/BrahmaStore/Store+Gateway.swift                providers, keys-by-name, caps, charges, routes, probes, prices, pacing preset
Sources/BrahmaStore/Migrations.swift                   "vX1-gateway"
Sources/BrahmaDomain/Billing/LaunchAuth.swift          pure per-turn auth decision
Sources/BrahmaDomain/Billing/PacingPreset.swift        preset values + DailyShare
Sources/BrahmaEngine/Tick/UsageStep.swift              presets, fallback, caps, gateway agents
Sources/BrahmaEngine/Tick/ModelProbeStep.swift         queued probes (step 4 runs a real turn through TurnLauncher)
Sources/BrahmaEngine/Turns/TurnLauncher.swift          auth decision, token mint/revoke, turn columns
Sources/BrahmaEngine/Engine/Doctor.swift               ambient-claude-auth, model-prices, pacing, gateway lines
Sources/BrahmaService/EngineService.swift              starts the gateway
Sources/brahma/BillingCommands.swift, ProvidersCommands.swift, ModelsCommands.swift   (+ settings pacing, settings model-price)
Sources/BrahmaAppModel/Billing/BillingModel.swift; Sources/BrahmaApp/Views/{BillingPanel,ModelsPanel,PacingPanel}.swift
Tests/BrahmaRuntimeTests/, Tests/BrahmaGatewayTests/, Tests/BrahmaEngineTests/, Tests/BrahmaCLITests/ (new files per task)
Tests/BrahmaRuntimeTests/Fixtures/turn-shapes/*.json   parity goldens (Task 1)
Tests/BrahmaGatewayTests/Fixtures/{anthropic,openai}/*.json|*.sse   adapter goldens
docs/runtimes/gateway.md                               owner doc: providers, routes, probes, caps (Task 19)
```

---

### Task 0: Re-read S, R and P as merged; record the drift; read the X1-0 probe report

**Files:**
- Create: `.superpowers/sdd/planX1/inventory.md` (ledger, not product docs)
- Read: `docs/research/x1-0-probes.md` (written by the X1-0 pre-work, see the outline file). If it does not exist, run the X1-0 probe script from that pre-work first.

**Interfaces:**
- Produces, in the inventory:
  - (a) every name in this plan's "Builds on" list, marked "as named" or "renamed to `<name>`";
  - (b) where `TurnProfileCompiler`, `ClaudeSettingsCompiler`, `StreamParser`, `TurnRunner`/`ClaudeProcessRunner`, `TurnProcess`, `ChildEnvironment`, `TurnRequest`, `SandboxCanaryKey`, `SecretVault`, `EmergencyStopObserver`, `ModelAllowlist` and `DoctorReport` live after R, and the exact target edges `BrahmaRuntime` and `BrahmaGateway` need. **Rule:** no new edge may point upward in R's graph; a type a lower layer needs moves down to `BrahmaModel` (a value) or is passed in as a value or closure. `TurnRequest` and `PermissionProfile` stay where R and S put them; only the compiler, settings and parser code moves into `BrahmaRuntime`;
  - (c) R's `TickOrderTests` literal list as merged, and where `ModelProbeStep` goes (proposal: after `canary`);
  - (d) the X1-0 outcomes that change this plan: the refusal status (429 vs 400), the request headers `claude` sends, the endpoints it calls, whether `--model <alias>` and `ANTHROPIC_DEFAULT_HAIKU_MODEL` work with a custom base URL, whether `claude` ever contacts another host on a gateway turn, whether `claude` honours `HTTPS_PROXY` for its own calls (the deny-all proxy), whether a per-agent `CLAUDE_CONFIG_DIR` is still needed to keep it off the owner's login, whether `--resume` works across auth modes, and the exact query strings it sends (`?beta=true`);
  - (e) the turn shapes that exist (profile × kind × mode × sub-agents × itemless), which Task 1 records.

- [ ] **Step 1:** Generate (a)–(e) on merged `main`. For (b) use `rg -l` on the type names and R's `ModuleGraphTests.allowedEdges`.
- [ ] **Step 2: Stop rule.** If X1-0 found that a gateway turn can reach Anthropic through the owner's login even with `ANTHROPIC_BASE_URL`, the turn token and the deny-all proxy set (and, if needed, a per-agent config dir) (Review Focus 1), **stop and report to the controller**: gateway turns would not be fail-closed. If only the alias probe failed, continue: routes to non-Anthropic models are then marked unavailable for `claude` turns with the reason (spec §14), and Tasks 12–13 still build the routes and probe.
- [ ] **Step 3: Commit** the inventory, with the X1-0 outcomes in the commit body.

---

### Task 1: Turn-shape parity goldens (before any move)

**Files:**
- Create: `Tests/BrahmaEngineTests/ClaudeParityGoldenTests.swift` (moves to `BrahmaRuntimeTests` in Task 3), `Tests/BrahmaEngineTests/Fixtures/turn-shapes/<shape>.json`

**Interfaces:**
- Produces: one golden per shape of Task 0 (e), each `{ "argv": [...], "settings": <settings JSON or null>, "envNames": [sorted names], "env": {name: value for non-secret names}, "mcpConfig": <JSON with the token replaced by "<TOKEN>"> }`. Paths under temp roots are normalized to `<HOME>`, `<WS>`, `<RUN>`.

- [ ] **Step 1: Write `ClaudeParityGoldenTests.captureOrCompare`.** For each shape, build the `TurnRequest` with the same fixtures `TurnProfileTests` and `SettingsCompilerTests` use, compile it through today's path (`ClaudeCommand.arguments`, `ClaudeSettingsCompiler`, `ChildEnvironment.make(purpose: .claude)`, `MCPConfig.write`), normalize, and write the golden when `BRAHMA_RECORD_GOLDENS=1`, else compare byte for byte.
- [ ] **Step 2:** Record on the unmodified code. Run without the variable. Expected: PASS for every shape.
- [ ] **Step 3: Add `ClaudeParityGoldenTests.everyShapeCovered`:** the set of shapes equals Task 0 (e). Expected: PASS.
- [ ] **Step 4: Commit the goldens alone:** `test(core): Claude turn-shape parity goldens before the runtime seam`.

---

### Task 2: `BrahmaRuntime` target — the interface and its value types

**Files:**
- Create: `Sources/BrahmaRuntime/{AgentRuntime,LaunchSpec,TurnEvent,RuntimeCatalog}.swift`, `Sources/BrahmaModel/Gateway/ModelClass.swift`, `Tests/BrahmaRuntimeTests/{RuntimeTypesTests,RuntimeIdLintTests}.swift`
- Modify: `Package.swift` (target `BrahmaRuntime` with Task 0's edges; test target), `ModuleGraphTests.allowedEdges`, `SafetyLintTests` (add `Sources/BrahmaRuntime` to the `failOpen` zero scope), `public-surface.txt`

**Interfaces:**
- Produces (spec §8.1.1; shapes are the controller's call where the spec leaves them open):
  - `public protocol AgentRuntime: Sendable { var id: RuntimeId { get }; func probe(_ env: ProbeEnvironment) async -> RuntimeProbe; func gates(for shape: TurnShape) -> [ProbeGateId]; func compile(_ r: TurnRequest, _ caps: RuntimeProbe) throws(RuntimeCompileError) -> LaunchSpec; func parser() -> any RuntimeStreamParser; func canaryShape(for shape: TurnShape) -> CanaryTurnShape; var taintSignal: TaintSignalMode { get }; func usageSignal(for auth: AuthRoute) -> UsageSignalMode }` — **(controller's call, deviating from spec §8.1.1's property)** `usageSignal` takes the auth route because one runtime reports subscription rate limits on its own login and is proxy-metered through the gateway.
  - `public struct RuntimeId: RawRepresentable, Hashable, Codable, Sendable { public let rawValue: String }`. No static instances outside `RuntimeCatalog`.
  - `public enum AuthRoute: String, Codable, Sendable { case subscription, gateway }`.
  - `public struct TurnShape: Hashable, Codable, Sendable { public var profile: PermissionProfile; public var kind: TurnKind; public var mode: WorkMode?; public var auth: AuthRoute; public var key: String { get } }` — `key` is today's canary shape string when `auth == .subscription` (so existing canary keys do not change) and `<today's>+gateway` otherwise.
  - `public struct ProbeGateId: RawRepresentable, Hashable, Codable, Sendable`.
  - `public struct ProbeEnvironment: Sendable { public var executable: String; public var tools: ToolPaths; public var cliVersion: String?; public var cliFlags: Set<String> }` — the doctor's facts passed in as values (`DoctorReport` lives in `BrahmaEngine`, above this target).
  - `public struct RuntimeProbe: Codable, Equatable, Sendable { public var runtime: RuntimeId; public var cliVersion: String?; public var passedGates: Set<ProbeGateId>; public var authRoutes: Set<AuthRoute>; public var notes: [String] }`.
  - `public struct LaunchSpec: Sendable, Equatable { public var executable: String; public var arguments: [String]; public var environment: [String: String]; public var files: [LaunchFile]; public var sandbox: LaunchSandbox; public var workingDirectory: String; public var stdin: RenderedPrompt }` with `LaunchFile { path: String; contents: Data }` (always written 0600 through `EngineFiles`) and `enum LaunchSandbox: Sendable, Equatable { case claudeSettings(path: String); case policy(PolicyDecision); case unsandboxed(PermissionProfile) }`.
  - `public enum TurnEvent` = today's `StreamEvent`, moved here and renamed, every case and associated value unchanged; `public typealias StreamEvent = TurnEvent` keeps call sites compiling. A doc comment maps the spec's normalized names to the cases (`.session` = `.initialized`, `.usage` = `TurnResult.usage` inside `.result`, …) and marks the Claude-only cases (`taskStarted`, `taskProgress`, `taskNotification`, `backgroundTasks`, `effortCapped`, `sandboxNote`, `workflow`) as ones other runtimes never emit **(controller's call: a rename keeps every consumer and test byte-identical; the spec's minimum set is a subset)**.
  - `public protocol RuntimeStreamParser { mutating func parse(line: String, now: Date) -> [TurnEvent] }`.
  - `public enum TaintSignalMode: String, Codable, Sendable { case syncHook, launchTainted }`, `public enum UsageSignalMode: String, Codable, Sendable { case rateLimitEvents, proxyMetered, none }`.
  - `public struct CanaryTurnShape: Sendable, Equatable { public var shapeKey: String; public var request: @Sendable (CanaryInputs) -> TurnRequest }` (equatable on `shapeKey`), where `public struct CanaryInputs: Sendable { public var paths: BrahmaPaths; public var probeFile: URL; public var claudePath: String; public var company: Company; public var agent: Agent }` holds what today's canary request builder takes.
  - `public enum ModelClass: String, Codable, Sendable, CaseIterable { case deep, standard, fast; public static func of(family: String) -> ModelClass? }` in `BrahmaModel` (`opus`→`deep`, `sonnet`→`standard`, `haiku`→`fast`; callers pass the family from `ModelAllowlist.family`, so `BrahmaModel` does not import it).
  - `public enum RuntimeCatalog { public static let claude: RuntimeId; public static var all: [any AgentRuntime] { get }; public static func runtime(_ id: RuntimeId) -> (any AgentRuntime)?; public static func defaultModel(_ c: ModelClass, on id: RuntimeId) -> String? }` — Claude: `deep=opus`, `standard=sonnet`, `fast=haiku`.
  - `RuntimeCompileError: Error, Equatable { case unavailable(String) }`.

- [ ] **Step 1: Write the failing tests.**
  - `RuntimeTypesTests.modelClassOfFamily`: `opus`, `claude-opus-5-5` → `.deep`; `sonnet` → `.standard`; `haiku` → `.fast`; `gpt-5` → nil.
  - `RuntimeTypesTests.subscriptionShapeKeyUnchanged`: for every shape in Task 1's set, `TurnShape(…, auth: .subscription).key` equals today's canary shape string (read through `SandboxCanaryKey`'s current builder).
  - `RuntimeTypesTests.catalogMapsClaudeClasses`.
  - `RuntimeIdLintTests.runtimeIdsOnlyInCatalog` (spec §8.1.1, §8.1.6): outside `Sources/BrahmaRuntime`, no source file constructs a `RuntimeId` (`RuntimeId(` in any form; decoding through `Codable` is the only other way in) or compares a `rawValue` with a string literal (`rawValue\s*==\s*"`); comments blanked with S's `EngineGitGuardTests.code`. A planted offending file in a temp copy of the scan root makes it fail (positive control).
- [ ] **Step 2:** Run them. Expected: FAIL (types undefined).
- [ ] **Step 3:** Implement the types; `RuntimeCatalog.all` returns `[]` until Task 3. Add the target and its edges.
- [ ] **Step 4:** Run the focused tests, `ModuleGraphTests`, `PublicSurfaceTests`, then the unit tier. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(runtime): BrahmaRuntime target — AgentRuntime, LaunchSpec, TurnEvent, ModelClass, RuntimeCatalog`.

---

### Task 3: The Claude adapter behind the seam (byte-identical)

**Files:**
- Move (`git mv`, pure move, imports only): `TurnProfile.swift` (minus `ChildEnvironment`, which S moved), `ClaudeCommand.swift` (minus `PermissionProfile`), `Sandbox/ClaudeSettings.swift` (the compiler and `ShellPrefix`), `StreamParser.swift`, `TurnStreamState.swift` → `Sources/BrahmaRuntime/Claude/` (Task 0 (b) is the authority on their post-R paths).
- Create: `Sources/BrahmaRuntime/Claude/ClaudeRuntime.swift`, `Tests/BrahmaRuntimeTests/ClaudeRuntimeTests.swift`
- Modify: the production runner (`ClaudeProcessRunner`, renamed `RuntimeProcessRunner` with `typealias ClaudeProcessRunner`), which now compiles through `RuntimeCatalog.runtime(request.runtime)` and parses with `runtime.parser()`; `TurnRequest` gains `public var runtime: RuntimeId = RuntimeCatalog.claude`; R's `CanaryStep`/`SandboxCanary` build canary turns through `canaryShape(for:)`; move `ClaudeParityGoldenTests` to `BrahmaRuntimeTests` and point it at `ClaudeRuntime.compile`.

**Interfaces:**
- Consumes: Task 2.
- Produces:
  - `public struct ClaudeRuntime: AgentRuntime` with `id == RuntimeCatalog.claude`, `taintSignal == .syncHook`, `usageSignal(.subscription) == .rateLimitEvents`, `usageSignal(.gateway) == .proxyMetered`, `gates(for:)` returning today's probe gate ids for that shape (from `probeGate` rows: F7-agents, V-1, … as Task 0 lists them).
  - `compile(_:_:)` returns the `LaunchSpec` whose `arguments`, settings file contents, environment and MCP config equal today's output for every subscription shape.
  - `ClaudeStreamParser: RuntimeStreamParser` wrapping `StreamParser.parseAll(line:now:)`.

- [ ] **Step 1: Write the failing tests.**
  - `ClaudeParityGoldenTests.captureOrCompare` now compiles through `ClaudeRuntime().compile` and must match Task 1's goldens unchanged.
  - `ClaudeRuntimeTests.parserMatchesStreamParser`: every `stream-*.jsonl` fixture parses to the same events through `ClaudeStreamParser` as through `StreamParser.parseAll`.
  - `ClaudeRuntimeTests.runnerUsesCatalog`: a `TurnRequest` with an unknown `RuntimeId` → the runner's stream throws `TurnError` with text `runtime <id> is not available` (fail closed), and nothing is spawned (fake `Spawn` seam).
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Do the moves (one commit, imports and `internal`→`package` only), then add `ClaudeRuntime` and switch the runner and the canary to it (second commit).
- [ ] **Step 4:** Run the focused tests, `TurnProfileTests`, `SettingsCompilerTests`, `StreamParserTests`, `TurnRunnerTests`, the canary tests, the unit and process tiers, `scripts/golden-path.sh`, and `BRAHMA_LIVE=1 … --filter LiveSandboxProbeTests` once. Expected: green, goldens unchanged, canary keys unchanged (no canary re-run on first start).
- [ ] **Step 5: Commit** (two commits): `refactor(runtime): move the Claude compiler and parser into BrahmaRuntime (pure move)`, then `feat(runtime): ClaudeRuntime adapter; the runner compiles and parses through RuntimeCatalog (byte-identical goldens)`.

---

### Task 4: Remove the ambient Claude auth path (security)

**Files:**
- Modify: `Sources/BrahmaSafety/Process/ChildEnvironment.swift` (delete `claudeAuth` and its pass-through; add `gatewayVariables`), `Sources/BrahmaEngine/Engine/Doctor.swift` (item `ambient-claude-auth`), `Tests/BrahmaSafetyTests/ChildEnvironmentTests.swift`, `Tests/BrahmaEngineTests/DoctorAmbientAuthTests.swift`
- Golden change: none for argv or settings. `envNames` goldens do not change (the fixtures' base environment has no auth variables); add one fixture whose base environment has them (Step 1).

**Interfaces:**
- Produces:
  - `ChildEnvironment.make(...)` never copies `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` or any `ANTHROPIC_*` from `base`, for every purpose.
  - `public static let gatewayVariables: Set<String> = ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]` (Task 0 (d) may adjust the model variable names to what X1-0 found). They are admitted **only** from a new parameter `gateway: [String: String]`, which only `ClaudeGatewayCompile` (Task 12/14) fills; `ANTHROPIC_API_KEY` there must be a 64-hex turn token (`TurnTokenFormat.isWellFormed`, a new five-line function in `BrahmaSafety/Process/` that `GatewayToken` reuses) or `make` drops it and the compile fails. `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` are also admitted from `gateway:` (Task 12's deny proxy) and then override any base value.
  - `isReserved` keeps refusing every `ANTHROPIC_*` and `CLAUDE_*` name as a secret name (unchanged).
  - Doctor item `ambient-claude-auth`: `warn` with detail `ignored (ANTHROPIC_API_KEY is set in your environment; Brahma uses only the company key; see brahma billing)` when the engine's own environment has `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` (naming which), else `pass` with `none in the engine's environment`.

- [ ] **Step 1: Write the failing tests.**
  - `ChildEnvironmentTests.ambientAuthNeverPassed`: base has both variables plus `ANTHROPIC_BASE_URL=https://x` → output has none of them, for `.claude`, `.general`, `.check`.
  - `ChildEnvironmentTests.gatewayVarsOnlyFromGatewayParameter`: the same names in `extra` or `engineClaudeVars` are dropped; through `gateway:` they pass.
  - `ChildEnvironmentTests.malformedTurnTokenDropped`: `gateway: ["ANTHROPIC_API_KEY": "sk-ant-real"]` → dropped.
  - `ClaudeParityGoldenTests` gains the shape `workSandboxedAmbientAuth` whose golden shows no auth variable.
  - `DoctorAmbientAuthTests.warnsAndNamesVariable`, `passesWhenAbsent`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. List the owner-visible change for the release note in the commit body: "an `ANTHROPIC_API_KEY` in your shell no longer switches turns to API billing; use `brahma billing`".
- [ ] **Step 4:** Run the focused tests, the unit tier and `scripts/golden-path.sh`. Expected: green.
- [ ] **Step 5: Commit:** `fix(safety): turns never inherit Claude auth from the engine's environment; doctor names an ignored key (spec §8.2.2)`.

---

### Task 5: Schema — migration `"vX1-gateway"` and the store API

**Files:**
- Modify: `Sources/BrahmaStore/Migrations.swift` (append `"vX1-gateway"` after the last migration on merged `main`), `ChangeTopics.map`
- Create: `Sources/BrahmaStore/Store+Gateway.swift`, `Sources/BrahmaModel/Gateway/{Provider,ProviderCaps,ModelRoute,ModelProbeRecord,GatewayCharge,BillingMode,PacingPresetName,PriceRow}.swift`, `Tests/BrahmaStoreTests/StoreGatewayTests.swift`

**Interfaces:**
- Produces the tables (every company-owned row has `companyId` and every lookup has `WHERE companyId = ?`):
  - `provider(id TEXT PK, adapter TEXT, baseURL TEXT, host TEXT, keySecret TEXT NULL, lan BOOL, builtin BOOL, createdAt)` — owner-wide;
  - `providerCap(companyId, provider, monthlyUSD REAL, dailyUSD REAL, PK(companyId, provider))`;
  - `gatewayCharge(id INTEGER PK, companyId, turnId TEXT NULL, itemId TEXT NULL, agentId TEXT NULL, provider, model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, usd REAL, estimated BOOL, at DATETIME)` + index `(companyId, provider, at)`;
  - `modelRoute(companyId, scope TEXT /* company|role|agent */, subject TEXT /* '' | role id | agent id */, class TEXT, provider, model, PK(companyId, scope, subject, class))`;
  - `modelProbe(provider, model, adapterVersion, cliVersion, level TEXT /* ModelProbeLevel: agent|textOnly|unavailable */, steps TEXT /* JSON */, declaredContext INTEGER, probedAt, PK(provider, model, adapterVersion, cliVersion))` + `modelProbeRequest(id, provider, model, requestedBy, companyId NULL, status, createdAt)`;
  - `priceRow(provider, model, inPerMTok REAL, outPerMTok REAL, cacheReadPerMTok REAL NULL, cacheWritePerMTok REAL NULL, setBy TEXT, PK(provider, model))` (owner rows; pinned rows live in code);
  - `company.billingMode TEXT NOT NULL DEFAULT 'subscription'`;
  - `ownerSettings.pacingPreset TEXT NOT NULL DEFAULT 'conservative'`, `ownerSettings.dayStartUtil REAL NULL`, `ownerSettings.dayStartDate TEXT NULL`;
  - `turn.runtime TEXT NULL`, `turn.authRoute TEXT NULL`, `turn.provider TEXT NULL`, `turn.routedModel TEXT NULL`, `turn.meteredUSD REAL NULL`;
  - `itemFact.meteredUSD REAL NOT NULL DEFAULT 0`;
  - seeds the four built-in providers: `anthropic` (adapter `anthropic`, `https://api.anthropic.com`, key `ANTHROPIC_API_KEY`), `openai` (`openai-compatible`, `https://api.openai.com/v1`, `BRAHMA_KEY_OPENAI`), `openrouter` (`https://openrouter.ai/api/v1`, `BRAHMA_KEY_OPENROUTER`), `groq` (`https://api.groq.com/openai/v1`, `BRAHMA_KEY_GROQ`). **Key names (controller's call):** provider keys use names that can never be test keys — `ANTHROPIC_API_KEY` (spec §8.2.1; `ANTHROPIC_*` is already never injectable) and `BRAHMA_KEY_<PROVIDER>` for every other provider (`BRAHMA_*` is never injectable). So an existing test key such as `OPENAI_API_KEY` keeps working exactly as today, and no provider key can reach an agent or a check by construction.
- Store API (`extension Store`, all `throws`):
  - `billingMode(companyId:) -> BillingMode`, `setBillingMode(_:companyId:)` — `BillingMode: String, Codable { subscription, apiKey = "api-key", fallback }`;
  - `providers() -> [Provider]`, `provider(id:) -> Provider?`, `addProvider(_:)`, `removeProvider(id:)` (refuses a built-in, and a provider any route or cap names);
  - `providerCaps(companyId:provider:) -> ProviderCaps?`, `setProviderCaps(_:companyId:provider:)` — `ProviderCaps { monthlyUSD: Double; dailyUSD: Double }`;
  - `recordCharge(_ c: GatewayCharge)`, `spend(companyId:provider:period: SpendPeriod, now: Date) -> Double` (`SpendPeriod { day, month }` in the owner's time zone);
  - `routes(companyId:) -> [ModelRoute]`, `setRoute(_:)`, `clearRoutes(companyId:scope:subject:)`;
  - `probeRecord(provider:model:adapterVersion:cliVersion:) -> ModelProbeRecord?`, `saveProbe(_:)`, `queueProbe(provider:model:requestedBy:companyId:) -> String`, `nextQueuedProbe() -> ModelProbeRequest?`, `finishProbeRequest(id:status:)`;
  - `priceRows() -> [PriceRow]`, `setPriceRow(_:)`;
  - `pacingPreset() -> PacingPresetName`, `setPacingPreset(_:)` — `PacingPresetName: String { conservative, standard, full }`;
  - value types in `BrahmaModel/Gateway/`: `public enum ModelProbeLevel: String, Codable, Sendable { case agent, textOnly, unavailable }`; `public struct ModelProbeRecord: Codable, Equatable, Sendable { provider, model, adapterVersion, cliVersion: String; level: ModelProbeLevel; steps: [ProbeStepResult]; declaredContext: Int?; probedAt: Date; static let maxAge: TimeInterval = 30 * 86_400 }` (`ProbeStepResult` is defined here too, filled by Task 13); `public struct ModelRoute: Codable, Equatable, Sendable { companyId: String; scope: RouteScope; subject: String; modelClass: String; provider: String; model: String }` with `RouteScope { company, role, agent }`; `public struct GatewayCharge` mirroring the table;
  - `providerKeyNames() -> Set<String>` (every `keySecret` of every provider record).
- `ChangeTopics.map`: `provider`, `providerCap`, `gatewayCharge`, `modelRoute`, `modelProbe`, `modelProbeRequest`, `priceRow` → `.usage`.

- [ ] **Step 1: Write the failing tests** (`StoreGatewayTests`):
  - `migrationSeedsBuiltins`; `billingDefaultsToSubscription`; `pacingDefaultsToConservative`;
  - `spendSumsByOwnerDay` (charges at 23:59 and 00:01 owner time split across days; a different company's charge never counts);
  - `capsAreCompanyScoped`; `removeProviderRefusedWhileRouted`; `builtinCannotBeRemoved`;
  - `routesRoundTripPerScope`;
  - `everyNewTableMapped` (P's `ChangeTopicsTests.everyTableMapped` stays green — run it).
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement the migration and API. Do not edit earlier migrations.
- [ ] **Step 4:** Run the focused tests, `StoreMigrationTests`, `ChangeTopicsTests`, `RestoreTests` and the unit tier. Expected: green.
- [ ] **Step 5: Commit:** `feat(store): providers, caps, charges, routes, probes, prices and pacing preset (vX1-gateway)`.

---

### Task 6: Price book and `brahma settings model-price`

**Files:**
- Create: `Sources/BrahmaGateway/PriceBook.swift`, `Sources/brahma/SettingsModelPrice.swift` (a new subcommand of `settings`), `Tests/BrahmaGatewayTests/PriceBookTests.swift`, `Tests/BrahmaCLITests/ModelPriceCommandTests.swift`

**Interfaces:**
- Produces:
  - `public struct Price: Codable, Equatable, Sendable { inPerMTok, outPerMTok: Double; cacheReadPerMTok, cacheWritePerMTok: Double? }` and `func cost(_ u: GatewayUsage) -> Double` (cache rows default to the input price when nil).
  - `public struct PriceBook: Sendable { public static let pinned: [String: Price] /* key "<provider>/<model>" */; public init(owner: [PriceRow]); public func price(provider: String, model: String) -> Price? }` — owner rows win over pinned rows; no prefix or wildcard matching (an unknown model is refused, spec §8.2.3).
  - Pinned rows: the Anthropic models `ModelAllowlist.models` resolves to (full ids X1-0 recorded) and the OpenAI models the release notes name. The table carries a `pinnedOn: String` date shown by the doctor.
  - CLI: `brahma settings model-price <provider>/<model> <usd per Mtok in> <usd per Mtok out> [--cache-read <usd>] [--cache-write <usd>]` and `brahma settings model-price` (lists pinned and owner rows). Values must be finite and ≥ 0; zero is accepted only for a provider whose adapter is `local` (X1b; until then refused with "zero prices are only for local providers").

- [ ] **Step 1: Write the failing tests:** `PriceBookTests.unknownModelHasNoPrice`, `ownerRowOverridesPinned`, `noPrefixMatching` (`claude-opus-5-5-x` unpriced when only `claude-opus-5-5` exists), `costUsesCacheRates`; `ModelPriceCommandTests.setsAndLists`, `refusesNegativeAndNaN`, `refusesZeroForRemote`, `refusedInsideAgentTurn` (`BRAHMA_AGENT_ID` set).
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement; append the `cli-tree.tsv` row. **Step 4:** Run them and P's CLI tests. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(gateway): pinned price book with owner rows; brahma settings model-price`.

---

### Task 7: Gateway core — `LoopbackListener`, HTTP framing, turn tokens (security)

**Files:**
- Create: `Sources/BrahmaSafety/Net/LoopbackListener.swift`, `Sources/BrahmaGateway/{GatewayServer,GatewayRoutes,TurnTokenRegistry}.swift`, `Tests/BrahmaSafetyTests/LoopbackListenerTests.swift`, `Tests/BrahmaGatewayTests/{GatewayServerTests,TurnTokenRegistryTests}.swift`
- Modify: `Package.swift` (target `BrahmaGateway` → `BrahmaSafety`, `BrahmaFoundation`, `BrahmaModel`, `BrahmaStore`; test target), `ModuleGraphTests`, `SafetyLintTests` (`failOpen` zero scope adds `Sources/BrahmaGateway`)

**Interfaces:**
- Produces:
  - `public enum LoopbackListener { public static func listen(backlog: Int32 = 64) throws(LoopbackListenerError) -> (fd: Int32, port: UInt16) }` — `AF_INET`, binds `127.0.0.1:0` only, `SO_REUSEADDR` off, `FD_CLOEXEC` set; `accept(_ fd: Int32) throws -> Int32` rejects a peer whose address is not `127.0.0.1`.
  - `public struct GatewayToken: Hashable, Sendable { public let value: String; public static func mint() -> GatewayToken; public static func isWellFormed(_ s: String) -> Bool }`.
  - `public struct TurnGrant: Sendable, Equatable { public var turnId: String; public var companyId: String; public var agentId: String; public var itemId: String?; public var provider: String; public var aliases: [String: String] /* request model → upstream model */; public var passThroughFamilies: Set<String> /* anthropic billing: accepted Claude model ids */; public var textOnlyModels: Set<String> }`.
  - `public final class TurnTokenRegistry: Sendable { public init(clock: AwakeClock); public func mint(_ g: TurnGrant) -> GatewayToken; public func admit(_ token: String) -> TurnGrant? /* nil once the turn ended or the token was revoked */; public func endTurn(_ token: GatewayToken) /* refuses new requests at once; in-flight streams may finish within inFlightGrace, then are cut */; public func revokeAll(reason: String) /* cuts in-flight streams too */ }`, conforming to `EmergencyStopObserver` (`stopAll` revokes every token and cuts every stream at once).
  - `public enum GatewayRoutes { public static let prefix = "/t/"; public static func classify(method: String, target: String) -> GatewayEndpoint? }` with `GatewayEndpoint { messages, countTokens }`. `classify` refuses absolute-form targets, percent-encoded dots or slashes, `..` or `.` segments, double slashes and fragments. A query string is accepted only if it equals one of `GatewayRoutes.allowedQueries` (the exact queries X1-0 recorded `claude` sending, expected `beta=true`).
  - `public final class GatewayServer: Sendable { public init(registry: TurnTokenRegistry, handler: any GatewayHandler); public func serve(connection fd: Int32) async /* one HTTP/1.1 connection, keep-alive */ }` with `public protocol GatewayHandler: Sendable { func handle(_ r: GatewayRequest, grant: TurnGrant, reply: GatewayReply) async }`. `GatewayReply` writes a JSON body or chunked SSE events and is the only writer of the socket.
  - Refusals: unknown path 404, wrong method 405, missing or unknown token 401 (`authentication_error`), oversize 413, malformed 400 — each in the Anthropic error JSON shape, with no echo of the request.

- [ ] **Step 1: Write the failing tests.**
  - `LoopbackListenerTests.bindsLoopbackOnly` (`.processTier`): the bound address is `127.0.0.1`; a connect to the machine's non-loopback address on that port fails.
  - `GatewayServerTests` (unit tier, over `socketpair`):
    - `onlyModelEndpointsServed`: the smuggling inputs of Review Focus 4 → 404/400, and the handler is never called; the recorded query (`?beta=true`) is served; `?beta=true&x=1` is refused;
    - `tokenRequired`: no token, a malformed token, the token of an ended turn (immediately after `endTurn`) → 401;
    - `tokenInEitherHeader`: `x-api-key` and `Authorization: Bearer` both accepted;
    - `oversizeRefused`: 32 MiB + 1 body → 413 without reading the rest; 33 KiB of headers → 431-equivalent 400;
    - `keepAliveServesSequentialRequests`;
    - `sseIsChunkedAndFlushed`: the handler writes three events with a `Signal` between them; the client reads each before the next is written.
  - `TurnTokenRegistryTests.stopRevokesAll` (in-flight streams cut too), `endTurnRefusesNewRequestsAtOnce`, `inFlightStreamFinishesWithinGrace`, `inFlightStreamCutAfterGrace`, `tokensAreUnique` (10 000 mints).
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. The accept loop runs on a dedicated thread (like R's IPC server) and hands each fd to `serve(connection:)`.
- [ ] **Step 4:** Run the focused tests, `SafetyLintTests`, `ModuleGraphTests`, the unit and process tiers. Expected: green.
- [ ] **Step 5: Commit:** `feat(gateway): loopback-only listener, turn tokens and HTTP/SSE framing serving only the model endpoints`.

---

### Task 8: Canonical format, upstream transport and the `anthropic` adapter (security)

**Files:**
- Create: `Sources/BrahmaGateway/{Canonical,Upstream,ModelGateway}.swift`, `Sources/BrahmaGateway/Adapters/{ProviderAdapter,AnthropicAdapter}.swift`, `Tests/BrahmaGatewayTests/{AnthropicAdapterTests,ModelGatewayTests,FakeUpstream}.swift`, `Tests/BrahmaGatewayTests/Fixtures/anthropic/*`

**Interfaces:**
- Produces:
  - `public struct CanonicalRequest: Codable, Sendable` — the Anthropic Messages request (`model`, `system`, `messages` with text / image / `tool_use` / `tool_result` blocks, `tools`, `tool_choice`, `max_tokens`, `stream`, `temperature`, `top_p`, `stop_sequences`, `metadata`); unknown top-level keys are kept in `extra: [String: JSONValue]` for pass-through to the `anthropic` adapter only.
  - `public enum CanonicalStreamEvent: Sendable` (`messageStart`, `contentBlockStart`, `contentBlockDelta`, `contentBlockStop`, `messageDelta(stopReason:usage:)`, `messageStop`, `ping`, `error`) with `func sse() -> Data`.
  - `public struct GatewayUsage: Codable, Equatable, Sendable { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens: Int }`, clamped to `0...10_000_000` each.
  - `public protocol ProviderAdapter: Sendable { var id: AdapterId { get }; var version: String { get }; func upstream(_ r: CanonicalRequest, rawBody: Data, model: String, endpoint: GatewayEndpoint, provider: Provider, key: String) throws(GatewayError) -> UpstreamRequest; func translate(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>, streamed: Bool, into reply: GatewayReply, redact: @Sendable (String) -> String) async throws(GatewayError) -> GatewayUsage? }`.
  - `public struct AdapterId: RawRepresentable, Hashable, Codable, Sendable` (`anthropic`, `openai-compatible`; X1b adds the rest).
  - `public protocol UpstreamTransport: Sendable { func send(_ r: UpstreamRequest) async throws(GatewayError) -> UpstreamResponse }`; `UpstreamRequest { url: URL; method: String; headers: [String: String]; body: Data }`; `UpstreamResponse { status: Int; headers: [String: String]; body: AsyncThrowingStream<Data, Error> }`.
  - `public struct EgressUpstreamTransport: UpstreamTransport` — `#if canImport(Darwin)`: an ephemeral `URLSession` whose `connectionProxyDictionary` names the `EgressProxyPool.proxy(for: [provider.host])` port, redirects refused (`willPerformHTTPRedirection` → nil), cookies and cache off; on Linux `send` throws `.unavailable("the gateway upstream is not available on this platform yet")`.
  - `AnthropicAdapter`: forwards `rawBody` unchanged when the request's model is a granted pass-through family; when the model is an alias from `grant.aliases`, it re-encodes the body with only `model` replaced by the routed model (every other field byte-for-byte from the canonical decode with `extra`); it sends to `https://<host>/v1/messages` (or `/count_tokens`); headers sent upstream are exactly `x-api-key: <key>`, `content-type`, `anthropic-version` and `anthropic-beta` (copied only if they match `^[a-z0-9,._-]{1,512}$`); the response streams through unchanged while a tap reads `message_start.usage` and the final `message_delta.usage`.
  - `public final class ModelGateway: Sendable, GatewayHandler` composing registry, adapters, upstream, vault and meter (meter wired in Task 9): looks up the grant, resolves `(provider, upstream model)` from `grant.aliases[request.model]`, or accepts `request.model` when its family is in `grant.passThroughFamilies`, else 400 `model <m> is not routed for this turn`; refuses a request carrying `tools` when the resolved model is in `grant.textOnlyModels`; reads the key with `vault.nonInteractive().value(companyId:name:)` and never stores it; `public func start() throws -> UInt16`, `public func stop()`.
  - `GatewayError: Error, Equatable { case unavailable(String), refused(status: Int, type: String, message: String), upstream(status: Int, message: String) }`.

- [ ] **Step 1: Write the failing tests** (unit tier; `FakeUpstream` replays fixtures and records requests):
  - `AnthropicAdapterTests.passesThroughBodyByteIdentical`;
  - `forwardsOnlyAllowlistedHeaders`: client headers `cookie`, `x-forwarded-for`, `host: evil`, `anthropic-beta: a\r\nx: y` → none forwarded except a valid `anthropic-beta`;
  - `readsStreamingFinalUsage` (fixture `stream-tools.sse`) and `readsNonStreamedUsage`;
  - `upstreamErrorRedactsKey`: upstream 401 body contains the key → the client sees the error with `[redacted]`, and the stored `gatewayCharge`/event text has no key;
  - `ModelGatewayTests.unroutedModelRefused`, `passThroughOnlyForGrantedFamilies`, `toolsRefusedForTextOnlyModel`, `missingKeyIsUnavailable` (vault without the key → 503-shaped `unavailable` naming the secret, never a request upstream), `upstreamUnavailableIsAnError` (never an empty 200).
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. The key lives only in the local scope of one `upstream(...)` call.
- [ ] **Step 4:** Run the focused tests and the unit tier. Expected: green.
- [ ] **Step 5: Commit:** `feat(gateway): canonical request, egress-pinned upstream and the anthropic adapter (key swap, usage tap, redacted errors)`.

---

### Task 9: Meter and caps (security)

**Files:**
- Create: `Sources/BrahmaGateway/GatewayMeter.swift`, `Tests/BrahmaGatewayTests/GatewayMeterTests.swift`
- Modify: `ModelGateway` (reserve before sending, settle after), `Sources/BrahmaDomain/...` item budget (`Store.itemUsage` adds `meteredUSD`), `OutcomeFactsObserver` (fills `itemFact.meteredUSD`)

**Interfaces:**
- Produces:
  - `public final class GatewayMeter: Sendable { public init(store: Store, prices: @Sendable () -> PriceBook, clock: @Sendable () -> Date); public func reserve(_ g: TurnGrant, model: String, maxTokens: Int, inputBytes: Int) throws(GatewayError) -> Reservation; public func settle(_ r: Reservation, usage: GatewayUsage?) }`.
  - Admission rule (controller's call, spec §8.2.3 worst case): for each of the day and month periods, admit iff `spend + reserved < cap`, where `reserved` sums the open reservations; a reservation holds `GatewayMeter.estimate` (pinned table). **The reservation is written to the database before the request is sent** (`gatewayCharge` with `state = 'reserved'` and the estimate as `usd`), and `settle` updates that row to `state = 'settled'` with the actual cost, or `'estimated'` when usage is missing. A client that disconnects mid-stream settles with the usage seen so far, or the estimate. At gateway start, every `reserved` row left by a dead engine becomes `estimated` at its reserved amount, so a `kill -9` never under-records spend. `spend` sums every row in every state. Refusal: `GatewayError.refused(status: GatewayRefusal.status, type: "rate_limit_error", message: "Brahma: <provider> <daily|monthly> cap of $<cap> reached for <company>")`.
  - No caps row → refused (`no cap set for <provider>; run brahma billing <co> caps <provider> --monthly-cap <usd>`). An unpriced model → refused (`no price for <provider>/<model>; run brahma settings model-price …`).
  - An in-flight response is never cut (spec §8.2.3).
  - `Store.itemUsage(db:itemId:)` cost = `costLE + meteredUSD`, so item budgets bound gateway spend too; `itemFact.costLE` stays subscription-only and `itemFact.meteredUSD` holds the gateway dollars (spec §8.2.1 "facts split cost by mode").

- [ ] **Step 1: Write the failing tests:**
  - `GatewayMeterTests.refusesAtCap`, `noCapNoRequest`, `unpricedRefused`;
  - `concurrentRequestsNeverExceedCapPlusOneMax` (property, `FuzzConfig.cases`): random concurrent reserve/settle sequences, with actual usage drawn **both below and above** the estimate → per period, total charged ≤ cap + the largest single charge + Σ max(0, actual − reserved) over requests admitted before the cap was reached; and when no actual exceeds its reservation, total ≤ cap + the largest single charge. A deliberately broken meter that admits on `spend < cap` alone (ignoring reservations) must fail it (positive control);
  - `crashBeforeSettleCountsReservation`: reserve, drop the meter without settling, start a new meter on the same store → the row is `estimated` and counts against the cap;
  - `disconnectSettlesWithSeenUsage`;
  - `missingUsageChargedAtEstimate` (row has `state = 'estimated'`); `nonASCIIInputEstimateIsConservative` (a CJK body's estimate ≥ the fixture's true token count);
  - `negativeOrHugeUsageClamped`;
  - `monthRollsOverInOwnerTimeZone`;
  - `itemBudgetCountsMetered`: an item whose turns charged $3 through the gateway with tier cap $2 is blocked by the budget step with today's text.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run the focused tests, `BudgetTests`, `OutcomeFactsTests` and the unit tier. Expected: green.
- [ ] **Step 5: Commit:** `feat(gateway): per-provider daily and monthly caps enforced before sending, with in-flight reservations`.

---

### Task 10: The `openai-compatible` adapter — translation with tools and streaming (security)

**Files:**
- Create: `Sources/BrahmaGateway/Adapters/{OpenAICompatibleAdapter,OpenAICompatibleStream}.swift`, `Tests/BrahmaGatewayTests/{OpenAICompatibleAdapterTests,OpenAICompatibleStreamTests}.swift`, `Tests/BrahmaGatewayTests/Fixtures/openai/*` (request and response goldens, streamed tool calls, errors)

**Interfaces:**
- Produces:
  - Request mapping (canonical → Chat Completions): `system` → a leading `system` message; text blocks → `content`; images → `image_url` data URLs; `tool_use` → assistant `tool_calls[{id, type: "function", function: {name, arguments: <JSON string>}}]`; `tool_result` → `role: "tool"` messages with `tool_call_id` (error results prefixed `Error: `); `tools` → `{type: "function", function: {name, description, parameters}}`; `tool_choice` `auto|any|tool` → `auto|required|{function}`; `max_tokens`, `temperature`, `top_p`, `stop`; `stream: true` adds `stream_options: {include_usage: true}`. Dropped, never invented: thinking blocks, `cache_control`, citations, `metadata`, `extra`.
  - Response mapping (non-streamed and streamed): content → text blocks; `tool_calls` → `tool_use` blocks (arguments parsed as JSON; unparsable arguments become a `tool_use` with `input: {}` and the turn sees a `tool_result`-shaped error on its next request — never a crash); `finish_reason` `stop|length|tool_calls|content_filter` → `end_turn|max_tokens|tool_use|end_turn`; `usage.prompt_tokens/completion_tokens/prompt_tokens_details.cached_tokens` → `GatewayUsage`.
  - `struct OpenAICompatibleStream` — a state machine from Chat Completions SSE chunks to `CanonicalStreamEvent`s, emitting `message_start` once, one content block per text run or tool call (index-tracked, arguments accumulated across deltas), `message_delta` with stop reason and usage, `message_stop`. Bounds: one SSE line ≤ 1 MiB, total tool-call arguments ≤ 4 MiB, total stream ≤ 64 MiB; a violated bound ends the reply with an `error` event (`overloaded_error`, "Brahma: provider stream exceeded <bound>").
  - `count_tokens` → answered locally with `countEstimate`, never sent upstream.
  - Upstream headers: `Authorization: Bearer <key>`, `content-type`, nothing else. URL = `provider.baseURL` + `/chat/completions`.

- [ ] **Step 1: Write the failing tests:**
  - `OpenAICompatibleAdapterTests.requestGoldens` (5 fixtures: text, system, tools, tool round-trip, image) and `responseGoldens` (text, tool call, length stop, content filter, error JSON);
  - `droppedFieldsNeverSent` (thinking, cache_control, metadata);
  - `unparsableToolArgumentsSurvive`;
  - `OpenAICompatibleStreamTests.toolCallSplitAcrossChunks` (arguments split into 1-byte deltas → one `tool_use` with the exact input), `interleavedToolCalls`, `usageFromFinalChunk`, `noUsageIsNil`;
  - `hostileStreamsAreBounded` (Review Focus 3; peak memory checked through the bound counters, not RSS);
  - `streamEventsSatisfyClaudeOrdering`: for every fixture, the emitted sequence is `message_start (content_block_start delta* content_block_stop)* message_delta message_stop` — the ordering X1-0 recorded as what `claude` requires.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run the focused tests and the unit tier. Expected: green.
- [ ] **Step 5: Commit:** `feat(gateway): openai-compatible adapter — Messages↔Chat Completions with tools and streamed tool calls, bounded`.

---

### Task 11: Providers registry, host pinning and `brahma providers` (security)

**Files:**
- Create: `Sources/BrahmaGateway/ProviderHost.swift`, `Sources/brahma/ProvidersCommands.swift`, `Tests/BrahmaGatewayTests/ProviderHostTests.swift`, `Tests/BrahmaCLITests/ProvidersCommandTests.swift`
- Modify: `Store.validateSecret` — today a non-test secret whose name `ChildEnvironment.isReserved` matches is refused (`reservedName`), which would refuse `ANTHROPIC_API_KEY` and `BRAHMA_KEY_*`. Allow, for **engine-held (non-test) secrets only**, exactly `ANTHROPIC_API_KEY` and names matching `^BRAHMA_KEY_[A-Z0-9_]{1,40}$`; every other reserved name stays refused. `ModelGateway` refuses a provider key whose secret row is flagged test (defence in depth; such a row cannot be created).

**Interfaces:**
- Produces:
  - `public enum ProviderHost { public static func validate(baseURL: URL, adapter: AdapterId, lan: Bool) -> Decision<String /* pinned host */>; public static func isProviderKeyName(_ n: String) -> Bool /* ANTHROPIC_API_KEY or BRAHMA_KEY_* */ }` — `providers add --key-secret` must satisfy `isProviderKeyName`; remote adapters need `https`, a host name (never an IP literal), no user info, no query or fragment, port 443 or none; X1b's `local` adapter rules are added there. `lan` is refused in X1 ("LAN providers arrive with local servers in X1b").
  - `brahma providers [list]` (id, adapter, host, key secret name and whether this company… — `list` is owner-wide; with `--company <co>` it shows whether the key is set for that company, never the value); `brahma providers add <id> --adapter openai-compatible --base-url <url> [--key-secret <NAME>]` (Mac/owner shell only; id matches `^[a-z][a-z0-9-]{1,31}$`; the key-secret name must be a valid `SecretName` and must not be an existing **test** key in any company); `brahma providers remove <id>`.
  - A redirect from the pinned host is already refused by the transport (Task 8); `add` makes no network call.

- [ ] **Step 1: Write the failing tests:** `ProviderHostTests.httpsHostRequired`, `ipLiteralRefused`, `userInfoRefused`, `redirectingBaseURLRefused` (a `FakeUpstream` returning 302 → `GatewayError.upstream`, and no second request recorded), `lanRefusedInX1`; `ProvidersCommandTests.addListRemove`, `keySecretMustBeProviderKeyName` (`--key-secret OPENROUTER_API_KEY` refused with the hint `use BRAHMA_KEY_OPENROUTER`), `refusedInsideAgentTurn`; `SecretTests.providerKeyNamesAcceptedEngineHeld` (`brahma secret set acme ANTHROPIC_API_KEY` and `BRAHMA_KEY_OPENROUTER` succeed), `providerKeyNamesNeverTestKeys` (`--test` refused for both), `existingTestKeysUnchanged` (`OPENAI_API_KEY --test` still accepted and still injected), `otherReservedNamesStillRefused` (`BRAHMA_DEV`, `CLAUDE_CODE_OAUTH_TOKEN`); `ModelGatewayTests.testFlaggedKeyRefused`.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement; append `cli-tree.tsv` rows. **Step 4:** Run them, `SecretTests` and P's CLI tests. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(gateway): provider records with pinned https hosts; provider keys can never be test keys; brahma providers`.

---

### Task 12: Model routes and gateway compilation of `claude` turns

**Files:**
- Create: `Sources/BrahmaDomain/Billing/RouteResolver.swift`, `Sources/BrahmaRuntime/Claude/ClaudeGatewayCompile.swift`, `Sources/brahma/ModelsCommands.swift` (`brahma company models`, `brahma agent model` as new subcommands of the existing groups), `Tests/BrahmaDomainTests/RouteResolverTests.swift`, `Tests/BrahmaRuntimeTests/ClaudeGatewayCompileTests.swift`, `Tests/BrahmaCLITests/ModelsCommandTests.swift`
- Modify: `TurnRequest` gains `public var gateway: GatewayLaunch? = nil`; `ClaudeRuntime.compile` calls `ClaudeGatewayCompile.apply` when it is set

**Interfaces:**
- Produces:
  - `public struct ResolvedRoute: Equatable, Sendable { public var provider: String; public var model: String; public var scope: RouteScope }` (`RouteScope` from Task 5; a nil `ResolvedRoute` means the runtime default).
  - `public enum RouteResolver { public static func resolve(agent: Agent, class c: ModelClass, routes: [ModelRoute]) -> ResolvedRoute? }` — agent, then role (`agent.actingRole ?? agent.role`), then company; nil means the runtime default (no route).
  - `public struct GatewayLaunch: Sendable, Equatable { public var baseURL: String /* http://127.0.0.1:<port>/t/ */; public var token: GatewayToken; public var aliases: [ModelClass: String] /* class → "brahma-<class>" for routed classes only */ }`.
  - `ClaudeGatewayCompile.apply(_ spec: inout LaunchSpec, _ g: GatewayLaunch, decisionModel: String)`:
    - environment through `ChildEnvironment.make(gateway:)`: `ANTHROPIC_BASE_URL = g.baseURL`, `ANTHROPIC_API_KEY = g.token.value`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1`, and the default-model variables for each routed class;
    - when the turn's decision model's class is routed: `--model brahma-<class>` and `--fallback-model brahma-<class>` (fallback never changes the model, spec §8.2.5); otherwise argv is unchanged (Anthropic pass-through);
    - **No subscription path, by construction (Review Focus 1):** gateway turns get `HTTPS_PROXY`/`HTTP_PROXY` = a deny-all egress proxy (`EgressProxyPool.proxy(for: [])`, which refuses and logs every `CONNECT`) and `NO_PROXY=127.0.0.1,localhost`, so a direct call from `claude` to any vendor host is refused and recorded. The shell prefix restores the base proxy variables (or unsets them) for agent commands, so agent Bash keeps its normal network path;
    - `CLAUDE_CONFIG_DIR` is left as today unless X1-0 shows `claude` still reaches the owner's login with the deny proxy set; then it is a **per-agent, persistent** gateway config dir under the agent home (not per turn, so `--resume` keeps working), and a switch between subscription and gateway turns for the same agent starts a fresh session with a hand-off note, as a runtime switch does (controller's call; X1-0 includes a resume-across-modes probe).
  - CLI: `brahma company models <co> [--role <role>] [deep=<p/m>] [standard=<p/m>] [fast=<p/m>]` (prints the resolved table when no assignment is given), `brahma company models <co> clear [--role <role>]`, `brahma agent model <co> <handle> <class>=<p/m>|<class>=inherit`. `<p/m>` must name an existing provider and a model with a price (or the command says which `model-price` to run). Setting a route never runs a probe itself; it queues one (Task 13).

- [ ] **Step 1: Write the failing tests:**
  - `RouteResolverTests.agentBeatsRoleBeatsCompany`, `actingRoleUsed`, `noRouteIsNil`;
  - `ClaudeGatewayCompileTests.routedClassUsesAlias` (argv golden `work-sandboxed-gateway-routed.json`), `unroutedAnthropicKeepsArgv` (argv equals the subscription golden; env differs only by the gateway variables), `fallbackModelIsSameAlias`, `tokenNeverInArgvOrSettings`, `gatewayTurnHasDenyProxy`, `shellPrefixRestoresProxyForBash`, `configDirIsPerAgentAndStable` (when enabled), `anthropicRouteRewritesModel` (an `anthropic/<model>` route: alias in argv, the gateway rewrites the body's `model` field);
  - `ClaudeParityGoldenTests`: every subscription golden still matches (gateway is nil).
  - `ModelsCommandTests.setResolveClear`, `unknownProviderRefused`, `unpricedModelRefusedWithHint`, `agentInheritClears`.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement; append `cli-tree.tsv` rows. **Step 4:** Run them, the parity goldens and P's CLI tests. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(runtime,domain): model routes per company, role and agent; claude turns compiled for the gateway`.

---

### Task 13: Capability probe and `ModelProbeStep` (security)

**Files:**
- Create: `Sources/BrahmaGateway/ModelProbe.swift`, `Sources/BrahmaEngine/Tick/ModelProbeStep.swift`, `Tests/BrahmaGatewayTests/ModelProbeTests.swift`, `Tests/BrahmaEngineTests/ModelProbeStepTests.swift`, `Tests/BrahmaGatewayTests/Fixtures/probe/*` (the 20 tool prompts and their schemas, the 5 multi-step scripts, the smoke repo)
- Modify: `ProvidersCommands.swift` (`brahma providers probe <id> <model> --company <co> [--wait]` — the company supplies the key and caps; the record is global), R's `TickOrderTests`/`TickGatesTests` literals (one new id `modelProbe` after `canary`, gates `[.stop, .hold]`), `Orchestrator.participants`

**Interfaces:**
- Produces:
  - `public struct ModelProbe { public static let thresholds: ProbeThresholds; public init(gateway: ModelGateway, clock: AwakeClock); public func runGatewaySteps(provider: Provider, model: String, companyId: String) async -> [ProbeStepResult] }` — steps 1 `streaming`, 2 `context`, 3 `tools` (spec §8.2.5), sent through `ModelGateway` with an engine-minted probe grant (`agentId = "engine"`, the company's caps apply, charges recorded with `turnId = nil`).
  - `public struct ProbeStepResult: Codable, Equatable, Sendable { public var step: String; public var passed: Bool; public var score: String /* e.g. "19/20" */; public var detail: String }`; `ModelProbeRecord.level` = `agent` (1–4 pass), `textOnly` (1–2 pass, 3 fails), else `unavailable`.
  - `final class ModelProbeStep: TickParticipant` — `id = .modelProbe`; runs at most one queued `modelProbeRequest` at a time as a `TaskRegistry` task: steps 1–3, then step 4 (`agentic smoke`) only if 1–3 passed.
  - `struct ProbeScratch` (step 4, not through `TurnLauncher`, which works only on the engine's own store): `static func make(under runDir: URL, fixture: URL) throws -> ProbeScratch` creates a scratch data home with its own `Store` file, one company and one agent, and a fixture worktree (`notes.txt`); `func request(route: ResolvedRoute, gateway: GatewayLaunch) -> TurnRequest` builds a Sandboxed work turn whose MCP config points at the scratch database; the step runs it with `RuntimeProcessRunner` + `ClaudeRuntime.compile` directly, under a probe grant charged to the requesting company. Pass = the engine reads `notes.txt` with `SafeRead` and finds exactly the expected one-line change, and the scratch database has the agent's `post_message`. The scratch home is removed afterwards (`bestEffort`). Saves the record; files an owner notice `model <p/m>: <level> (streaming ✓, context 64k ✓, tools 19/20 ✓, smoke ✓)`.
  - `brahma providers [list]` gains a PROBES section: per probed `(provider, model)`, the level, each step's score and the probe date, so the owner sees the results (decision 20).
  - Queueing: setting a route (Task 12) or a first gateway launch for an unprobed `(provider, model)` queues a probe; `brahma providers probe` queues one and, with `--wait`, polls the record (DB as the bus; no IPC message added). A queued request always names the company whose key and caps it uses: the CLI requires `--company`, and automatic probes use the company that triggered them.

- [ ] **Step 1: Write the failing tests** (unit tier with `FakeUpstream` scripted model behaviours, and `ScriptedTurnRunner` for step 4):
  - `ModelProbeTests.perfectModelIsAgent`, `badToolsIsTextOnly` (14/20), `noStreamingIsUnavailable`, `contextRecorded`, `multiStepNeedsAllFive`;
  - `ModelProbeStepTests.runsOneAtATime`, `smokeOnlyAfterGatewaySteps`, `smokeFailureIsTextOnlyOrUnavailable`, `recordKeyedByVersions` (a different `claude` version → a new probe is queued), `staleAfter30Days`, `heldByStop` (gates), `noticeFiled`.
  - R's `TickOrderTests.orderIsPinned` updated with `modelProbe` after `canary` (ruling recorded in the commit).
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run the focused tests, `TickOrderTests`, `TickGatesTests`, the unit and process tiers. Expected: green.
- [ ] **Step 5: Commit:** `feat(gateway,engine): capability probe (streaming, context, tool calls, agentic smoke) gates every routed model`.

---

### Task 14: Billing modes, `LaunchAuth` and launch integration

**Files:**
- Create: `Sources/BrahmaDomain/Billing/LaunchAuth.swift`, `Sources/brahma/BillingCommands.swift`, `Tests/BrahmaDomainTests/LaunchAuthTests.swift`, `Tests/BrahmaEngineTests/GatewayTurnTests.swift`, `Tests/BrahmaCLITests/BillingCommandTests.swift`
- Modify: R's `TurnLauncher` (decide, mint, set `TurnRequest.gateway`, revoke at turn end, write the turn columns), `UsageStep` (fallback and gateway agents), `Scheduler.select` (new parameter `gatewayAgents: Set<String> = []`), the turn-end accounting (`Store.writeAccounting`: gateway turns set `meteredUSD` from the turn's charges and leave `costLE` nil; `recordSpend`/`UsageCalibration` and the mode-cost EMA are fed **only** by subscription turns), the rate-limit recording path (`.rateLimit` events from gateway turns never update `usageState`), `EngineService` and `EngineServiceDeps` (a new `makeGateway: (Store, any SecretVault) throws -> ModelGateway` dependency; the service starts it after the doctor and registers it and the registry with the emergency stop; R's foreground `brahma engine run` starts it the same way), `brahma why`

**Interfaces:**
- Produces:
  - `public enum TurnAuth: Equatable, Sendable { case subscription; case gateway(provider: String, aliases: [ModelClass: ResolvedRoute], passThrough: Bool) }`.
  - `public struct LaunchAuthInputs: Sendable { agent; company; billing: BillingMode; decisionClass: ModelClass; routes: [ModelRoute]; subscriptionOpen: Bool; providerOpen: (String) -> Decision<Void> /* key set, caps set and not reached, provider exists */; probeLevel: (String, String) -> ModelProbeLevel?; priced: (String, String) -> Bool; gatewayAvailable: Decision<Void>; canaryPassed: (TurnShape) -> Bool /* the +gateway shape's canary, spec §8.1.2 */ }`. A gateway result whose shape has not passed its canary is a deny (`canary for <shape> not passed yet`); R's `CanaryStep` then runs it, as it does for subscription shapes.
  - `public enum LaunchAuth { public static func decide(_ i: LaunchAuthInputs) -> Decision<TurnAuth> }` — the table (controller's call, spec §8.2.1 and §8.2.5):

| Resolved route for the decision class | Billing | Result |
|---|---|---|
| non-Anthropic provider | any | gateway, if gateway available, provider open, priced, probe `agent`; else deny with the first failing reason |
| `anthropic/<model>` (explicit) | `subscription` | subscription with `--model <model>` if `ModelAllowlist` allows it and `subscriptionOpen`; else deny (controller's call: an explicit Anthropic route is never ignored) |
| `anthropic/<model>` (explicit) | `api-key`, `fallback` | as the rows below, with the gateway rewriting `model` to the routed model |
| none | `subscription` | subscription if `subscriptionOpen`, else deny (`usage gate closed`) |
| none | `api-key` | gateway(anthropic, pass-through) if open and priced, else deny |
| none | `fallback` | subscription if open, else gateway(anthropic) if open and priced, else deny |

  Other routed classes of the same agent (e.g. `fast` for background calls) are added to the aliases only if their probe level is `agent` or `textOnly`; a `textOnly` model goes into `TurnGrant.textOnlyModels`.
  - `UsageStep`: for a `fallback` company whose subscription decision is closed and whose `anthropic` caps are open, `UsageDecisions` marks the company open for gateway launches (no `usageLimit` blocker written); an agent whose resolved route is non-Anthropic is put in `gatewayAgents` and is never blocked by the subscription gate. A reached cap is a usage closure: `brahma why` and Budget say `<provider> daily cap reached ($x of $y); resets <time>`.
  - CLI: `brahma billing <co>` (shows mode, caps and today's and this month's spend per provider), `brahma billing <co> subscription|api-key|fallback [--monthly-cap <usd>] [--daily-cap <usd>]` (caps apply to `anthropic`; `api-key`/`fallback` refused until the `anthropic` monthly cap exists; daily defaults to monthly ÷ 20), `brahma billing <co> caps <provider> --monthly-cap <usd> [--daily-cap <usd>]`.

- [ ] **Step 1: Write the failing tests:**
  - `LaunchAuthTests`: one test per table row and each deny reason; `fallbackNeverChangesModel` (a closed subscription with a route to `openai/x` for `fast` only and a `deep` decision → gateway(anthropic), never openai); `textOnlyNeverMain` (a `deep` route to a `textOnly` model → deny); `gatewayTurnHasNoSubscriptionPath` (for every gateway result, the compiled `LaunchSpec` carries the base URL, the token and the deny-all proxy variables, and never the owner's own proxy settings).
  - `LaunchAuthTests.gatewayShapeHeldUntilCanaryPassed`.
  - `GatewayTurnTests` (`.processTier`: the gateway binds its port; in-process engine, `ScriptedTurnRunner`, `FakeUpstream`): `apiKeyCompanyRunsThroughGateway` (turn row `authRoute = gateway`, `meteredUSD` set, `costLE` nil, calibration unchanged); `fallbackSwitchesWhenGateCloses` (a rejected rate-limit event closes the subscription; the next turn is a gateway turn; the first new turn after `resetsAt` is subscription again); `gatewayRateLimitEventsIgnored`; `tokenRevokedAtTurnEnd`; `stopRevokesTokens` (`brahma stop` → in-flight gateway requests get 401 on their next call).
  - `BillingCommandTests.apiKeyNeedsCap`, `dailyDefaultsToTwentieth`, `showsSpend`, `capsForProvider`, `refusedInsideAgentTurn`.
  - `SchedulerTests.gatewayAgentsBypassSubscriptionClosure` and `defaultIsUnchanged` (the existing `SchedulerTests` pass untouched).
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement; append `cli-tree.tsv` rows. **Step 4:** Run the focused tests, `OrchestratorTests`, `UsageGateTests`, `SchedulerTests`, the unit and process tiers, and `scripts/golden-path.sh`. Expected: green.
- [ ] **Step 5: Commit:** `feat(engine): billing modes (subscription, api-key, fallback) with per-turn auth; gateway turns metered, never calibrated`.

---

### Task 15: Pacing presets

**Files:**
- Create: `Sources/BrahmaDomain/Billing/PacingPreset.swift`, `Sources/brahma/SettingsPacing.swift` (new `settings` subcommand), `Tests/BrahmaDomainTests/PacingPresetTests.swift`, `Tests/BrahmaEngineTests/PacingStepTests.swift`
- Modify: `UsageStep` (threshold, reserve, burst, daily share, concurrency ceiling), `AuditStep` and the standup pass in `SweepStep` (skip on no-landing days under `conservative`), `Doctor` (item `pacing`), `UsageGate`/`Pace` (a `burst` parameter, default today's 0.15)

**Interfaces:**
- Produces:
  - `public struct PacingPreset: Equatable, Sendable { public var name: PacingPresetName; public var concurrency: Int?; public var fiveHourThreshold: Double?; public var reserve: Double; public var reserveIsMinimum: Bool; public var weeklyBurst: Double; public var dailyShare: Bool; public var dailyBurst: Double; public var skipIdleRituals: Bool; public static let conservative, standard, full: PacingPreset }` with the pinned values.
  - Effective values per company (spec §8.2.4; narrows, never widens):
    - concurrency: `cfg.hardCap = min(cfg.hardCap, preset.concurrency ?? .max)` — all companies and both auth routes together;
    - five-hour threshold: `min(UsageGate.threshold(company.usageMode), preset.fiveHourThreshold ?? 1)`;
    - reserve: today's value is `company.ownerReserve ?? (1 − weeklyShare)`. `conservative`: `max(0.50, today's)`. `standard`: **today's value, unchanged** (its 30% is today's default share, not a floor). `full`: `max(0.10, today's)`. **(Controller's call: `standard` is exactly today's behaviour, as the spec's table note says; this reads the spec's "larger of the preset's and the company override" as applying to `conservative` and `full`.)**
    - daily share **(controller's call on scope)**: under `conservative` only, where for weekly-only accounts (Ultra) it is the short-window guard the spec names; `standard` stays exactly today's behaviour and `full` is the explicit opt-up, so neither gets it. `DailyShare.evaluate(util:dayStartUtil:reserve:burst:dayEnd:) -> UsageDecision`: closed until the owner's next midnight when `util − dayStartUtil ≥ (1 − reserve) / 7 + burst`. `dayStartUtil` is recorded at the first snapshot of each owner-calendar day (`ownerSettings.dayStartUtil/dayStartDate`); unused share never carries over.
    - `skipIdleRituals` (`conservative`): `AuditStep` and the standup pass do nothing for a company with no landing since the owner's midnight (`Store.landedCount(companyId:since:)`, from 4a's merge records).
  - The weekly pace keeps its critical-path exemption; the daily share applies to everything (it is the short-window guard).
  - CLI: `brahma settings pacing [conservative|standard|full]` (shows the effective numbers; `full` prints the terms reminder `Full pacing uses as much of your plan as Brahma can. Check Anthropic's usage policy: https://www.anthropic.com/legal/aup`).
  - Doctor item `pacing`: `pass` with the preset and its numbers; `warn` on `full` with the same reminder.

- [ ] **Step 1: Write the failing tests:**
  - `PacingPresetTests.valuesPinned`, `narrowsNeverWidens` (property: for random company modes, reserves and shares, every effective value is at most as permissive as `standard`'s for `conservative`, and `standard` equals today's values exactly), `fullReserveFloor`, `dailyShareClosesAtShare`, `dailyShareNoCatchUp` (an idle day does not raise the next day's share), `dailyShareResetsAtOwnerMidnight`;
  - `PacingStepTests.conservativeCapsConcurrencyAtTwo` (three companies, ten ready agents → two turns), `weeklyOnlyUsesDailyShareUnderConservative`, `standardHasNoDailyShare`, `skipsAuditsWithoutLanding`, `auditsRunAfterALanding`, `standardIsTodayBehaviour` (every existing `UsageGateTests`/`OrchestratorTests` usage case passes with the preset set to `standard`).
  - `PacingCommandTests.showsEffectiveNumbers`, `fullPrintsReminder`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. Existing tests that assume today's defaults set `standard` explicitly in their fixture (listed in the commit body); none is weakened.
- [ ] **Step 4:** Run the focused tests and the unit tier. Expected: green.
- [ ] **Step 5: Commit:** `feat(engine): pacing presets — conservative default (2 turns, 60%, 50% reserve, daily share), standard, full`.

---

### Task 16: Canary probes and the key-leak scan (security)

**Files:**
- Modify: `CanaryProbes` (probe `model-gateway`: inside a sandboxed turn, `curl -s -m 3 http://127.0.0.1:<gateway port>/t/v1/messages`; expected **denied** on Seatbelt layouts; X8a gives the whole-turn VM layout its own expectation — reachable only through the relay, and only with the live turn token), the canary key builder (gateway shapes key as `TurnShape.key` with `+gateway`; the live layer runs through the gateway with the triggering agent's route, and is not attempted for a route whose probe is not `agent`)
- Create: `Tests/BrahmaEngineTests/GatewayKeyLeakTests.swift`, `Tests/BrahmaEngineTests/GatewayCanaryTests.swift`, `Tests/BrahmaEngineTests/LiveGatewayTests.swift` (`.liveTier`)

**Interfaces:**
- Produces:
  - `GatewayKeyLeakTests.keyNowhereAfterTurn` (`.processTier`): a company with a `MemoryVault` key `sk-test-<random 40>`; one gateway turn through the real `RuntimeProcessRunner` with `scripts/fake-claude.sh` taught to call the gateway with `curl` (it reads `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` like `claude`); then scan for the key: the fake's recorded environment and argv, every file under the run dir and the agent home, the transcript, every text column of every table, the engine log. Expected: zero hits. The same scan with a deliberately broken compile that puts the key in the environment must find it (the scan's positive control).
  - `GatewayCanaryTests.gatewayUnreachableFromSandboxedBash` (`.processTier`, `Toolchain.seatbeltAvailable`): the rendered Sandboxed profile cannot connect to a listening gateway port.
  - Live tests (owner-run, owner keys, `BRAHMA_LIVE=1`): `LiveGateway/noSubscriptionFallback` (with the owner's subscription logged in, a gateway turn with an exhausted $0.01 cap ends with the Brahma refusal; the turn's deny proxy logged no `CONNECT` and the gateway logged the refused request — and, as the positive control, the same turn compiled without the deny proxy variables is shown to be detectable by the deny log when `claude` is pointed at it), `LiveBench/apiCap` (spec §10 row 1 (2)), `LiveGateway/providerMatrix` (row 12 (1): Anthropic API and one OpenAI-compatible provider each land one item of the golden-path scenario).

- [ ] **Step 1: Write the failing tests.** **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement the probe and the scan helper `KeyLeakScan.scan(home:runDir:db:needle:) -> [String]` (test support).
- [ ] **Step 4:** Run the focused tests, the process tier and `BRAHMA_LIVE=1 … --filter LiveSandboxProbeTests` once. Expected: green.
- [ ] **Step 5: Commit:** `test(engine): gateway canary probe and key-leak scan; live gateway acceptance tests`.

---

### Task 17: Doctor, `brahma why` and Budget lines

**Files:**
- Modify: `Doctor.swift` (items `gateway`, `model-prices`), `WhyCommand`/`Store+StallReport` (route, probe, cap and billing reasons), `BudgetModel` (per-provider spend rows), `Tests/BrahmaEngineTests/DoctorGatewayTests.swift`, `Tests/BrahmaDomainTests/StallReportGatewayTests.swift`

**Interfaces:**
- Produces:
  - Doctor `gateway`: `pass` `listening on 127.0.0.1:<port>; providers: anthropic (key set in 2 companies), openrouter (no key)`; `fail` when the gateway could not start (API and routed turns then wait, subscription turns are unaffected).
  - Doctor `model-prices`: `warn` naming every model the gateway refused as unpriced in the last 7 days and every model id gateway turns' `initInfo.model` reported without a price; `pass` otherwise. The price table's `pinnedOn` date is in the detail.
  - `brahma why <co>` lines: `@eng-1 waits: model openrouter/x is textOnly (tools 14/20, needs 19)`, `… openai daily cap reached ($2.00 of $2.00); resets 00:00`, `… billing api-key: no anthropic cap set`.

- [ ] **Step 1–4:** Tests `DoctorGatewayTests.passAndFail`, `unpricedModelsNamed`; `StallReportGatewayTests.eachReasonRendered` (agent text through `safe()`). FAIL → implement → PASS with the unit tier.
- [ ] **Step 5: Commit:** `feat(engine): doctor gateway and model-prices items; why and Budget explain routes, probes and caps`.

---

### Task 18: App — BILLING, MODELS and PACING panels; the agent MODEL row

**Files:**
- Create: `Sources/BrahmaAppModel/Billing/BillingModel.swift`, `Sources/BrahmaApp/Views/{BillingPanel,ModelsPanel,PacingPanel}.swift`, `Tests/BrahmaAppModelTests/BillingModelTests.swift`
- Modify: `CompanySettingsView` (adds BILLING and MODELS panels after the existing ones), the Budget screen (PACING panel), the People agent inspector (a MODEL row), P's `Fixtures/ui-inventory/*.json` (additions only)

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class BillingModel { var mode: BillingMode; var caps: [String: ProviderCaps]; var spend: [String: (day: Double, month: Double)]; var routes: [ModelRoute]; var probes: [ModelProbeRecord]; var preset: PacingPresetName; func setMode(_:monthlyCap:dailyCap:) async; func setCaps(provider:monthly:daily:) async; func setRoute(_:) async; func setPreset(_:) async; var errorMessage: String? }` — every write goes through the same `Store` calls as the CLI, with the CLI's validation and messages.
  - BILLING: mode picker, per-provider caps and spend (mono numbers, zebra table). MODELS: the route table (scope, class, provider/model) and probe results per model with each step's score; a key is never shown, only "set"/"not set". PACING: the three presets with their numbers; `full` shows the reminder. Agent inspector MODEL row: resolved route per class with its scope and probe level.
  - Provider keys are entered only through the existing secret sheet (Company › Settings › SECRETS); the MODELS panel links to it.

- [ ] **Step 1: Write `BillingModelTests`:** `apiKeyNeedsCapShowsCLIMessage`, `routesRoundTrip`, `presetChangeNarrowsShownNumbers`, `keyValueNeverInModel`.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement with P's components and tokens.
- [ ] **Step 4:** `scripts/make-app.sh debug`, `scripts/ui-inventory.sh` and diff (only the new panels and row), update the baseline in a commit tagged `approved Plan X spec §12`; take UI snapshots of Company › Settings, Budget and the agent inspector and read them; run `ThemeLintTests`, `ScreenInventoryTests` and the unit tier. Expected: green.
- [ ] **Step 5: Commit:** `feat(app): BILLING, MODELS and PACING panels; agent MODEL row`.

---

### Task 19: Red team, docs and final review

**Files:**
- Create: `docs/runtimes/gateway.md` (owner doc: billing modes, caps, providers, routes, probe levels, what each refusal means), `.superpowers/sdd/planX1/redteam.md`
- Modify: `README.md` ("Billing and models": one section; the release note lines for the ambient-auth change and the `conservative` default), this plan's §10 mapping table (below) with the final task ids

- [ ] **Step 1: Red team (Opus, high).** Try, and record each attempt and result: steal a turn token from another agent's turn on Workspace (env readable through `ps`) and spend beyond that turn's caps (expected: the token refuses new requests the moment the turn ends; caps still bound spend); reach the gateway from Sandboxed Bash; smuggle a non-model endpoint; make the gateway connect to a private address through a provider base URL whose DNS answers 10.0.0.1 (expected: the egress proxy refuses); prompt-inject a tool result so the model asks for another provider's model name (expected: 400 not routed); make a provider stream exceed bounds; get a key into a transcript through an upstream error. Every finding is fixed in this task with a test, or ruled on by the controller.
- [ ] **Step 2: Full verification.** `swift build` (all targets, release too), `scripts/test.sh all`, `scripts/golden-path.sh`, `scripts/make-app.sh debug && scripts/smoke-app.sh`, the owner-shell `brahma doctor` and `brahma canary run` against a throwaway home, and `BRAHMA_BENCH=1` gateway overhead bench (`GatewayBenchTests`, release) against `GatewayBudgets`.
- [ ] **Step 3: Final review (Opus)** of the branch against spec §5 anti-goals, §8.1–§8.2, §9.2, decision 20 and this Review Focus.
- [ ] **Step 4: Commit:** `docs: billing, providers and models; X1 red-team record`.

---

## §10 rows delivered by X1 (spec §10 requires this table; final ids)

| Row | Criterion | Task |
|---|---|---|
| 1 (2) | `LiveBench/apiCap`: $2/day cap never exceeded beyond one response | X1-T9 (meter), X1-T16 (live test) |
| 3 (2) | `fallback` continues on API; cap overruns = 0 | X1-T14, X1-T9; X6a measures idle-while-actionable |
| 3 (pacing) | pacing that never hits the wall | X1-T15 |
| 12 (1) | `LiveGateway/providerMatrix` (Anthropic + OpenAI-compatible; local is X1b) | X1-T10, T11, T16 |
| 12 (2) | textOnly/unavailable models never get tool requests; routed agents wait with the reason | X1-T8, T13, T14 |
| 12 (3) | key-leak scan | X1-T16 |

## Self-review notes

- **Spec coverage.** §8.1.1 interface: T2–T3. §8.1.4 classes: T2 (`ModelClass`), T12 (routes); `RoleTemplate.models` as classes is X3. §8.1.2 runtime choice CLI and §8.1.5 Codex: X2. §8.2.1 billing: T5, T14. §8.2.2 ambient path: T4. §8.2.3 proxy: T7–T9. §8.2.4 pacing: T15. §8.2.5 gateway: T7–T13. §9.2: T4, T7–T11, T16, T19. §12 CLI rows `billing`, `settings pacing`, `settings model-price`, `providers`, `company models`, `agent model`: T6, T11, T12, T14, T15. App surfaces: T18. Doctor lines: T4, T15, T17.
- **What X8a (decision 21) consumes from X1, so X1 must not close it off:** `LaunchSpec` is a value a backend can wrap (`IsolationBackend.prepare(_:_:)`); `TurnShape` is a struct X8a extends with `backend` and `layout` (its `key` keeps today's string for `seatbelt` + subscription); the gateway binds loopback only and X8a relays it into the VM over vsock, so `GatewayLaunch.baseURL` is a parameter, never a constant; `TurnGrant` is per turn, so a VM's token dies with its turn.
- **Deferred on purpose:** `brahma agent runtime`, `brahma company runtime`, `brahma settings runtime-models` (only one runtime exists until X2); X1b adapters; Admin-API reconciliation (F-X1).
- **Type consistency:** `TurnGrant` (T7) is minted by `TurnLauncher` (T14) from `TurnAuth` (T14) and `ResolvedRoute` (T12); `GatewayLaunch` (T12) carries the token from `TurnTokenRegistry.mint` (T7); `ModelProbeLevel` is the `level` of `ModelProbeRecord` (T5) set by T13 and read by `LaunchAuth` (T14); `GatewayUsage` (T8) is priced by `Price.cost` (T6) in `GatewayMeter` (T9); `PacingPresetName` (T5) names `PacingPreset` (T15).
- **Effort:** 20 tasks (T0–T19). L: T3, T7, T10, T13, T14. M: T5, T8, T9, T12, T15, T16, T18. S: T0, T1, T2, T4, T6, T11, T17, T19. About 12–15 implementer-days subagent-driven, with Opus reviews on eight tasks; 3 calendar weeks at owner pacing.
