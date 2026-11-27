# Plan X4 — VM isolation by default (spec sub-plans X8a + X8b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution:** subagent-driven, on a branch cut from `main` **after X1 (and X1b if merged) is on `main` and green**. Model policy (owner, 2026-11-21): Fable for implementers and routine reviews; **Opus (high)** for the security-touching tasks (T5, T7, T8, T10, T12, T13, T15, T16, T18) and the final review. Never Sonnet or Haiku.
>
> **Naming.** The file is `planX4` by the controller's numbering of the post-X1 plans. In the spec this work is **X8a (P0: interface, Linux micro-VM, canary layer) and X8b (P1: macOS VM, Docker)**; both are planned here in full because they share every interface. The spec's own "X4" (Approved channels) is a different plan.

**Goal:** Every agent turn runs, by default, inside a local VM that holds no credential beyond its per-turn gateway token, reaches only the engine's gateway and egress proxy, and shares only its own worktree; Seatbelt stays as the labelled WEAKER ISOLATION fallback; one `IsolationBackend` interface sits behind X1's runtime seam; the canary proves each (runtime, backend, layout); the soak measures memory with many concurrent VMs.

**Architecture:**
- **One interface, four backends.** `IsolationBackend` (spec §8.8.4) wraps the runtime's `LaunchSpec`; neither side knows the other's internals. `SeatbeltBackend` is today's launch, byte-identical (X1's goldens). `LinuxVMBackend` (Apple Containerization), `MacOSVMBackend` (Virtualization.framework) and `DockerBackend` are clients of one new host-side helper process.
- **`brahma-vmhost`: a separate SwiftPM package** (`Packages/BrahmaVMHost`, platform floor macOS 26, Apple silicon) that links Containerization and Virtualization and nothing of Brahma's but `BrahmaVMProtocol` (a tiny shared target of value types). It serves `linux-vm` and `macos-vm`; **Docker needs no vmhost** (its relay and lifecycle live in the engine, so Docker works on macOS 14+). The main package keeps `.macOS(.v14)` and stays Linux-portable: the engine never imports a VM framework. The host process runs under S's new `Purpose.vmHost` Seatbelt profile and is signed with `com.apple.security.virtualization`. The engine spawns it through S's `Spawn` like `brahma-helper`; it serves requests on a Unix control socket in the engine run dir (0600), and every per-VM request carries that VM's capability token. **(controller's call: this also resolves the SwiftPM platform-floor conflict that a direct Containerization dependency would cause, at the price that `macos-vm` also needs macOS 26 in v1 — flagged for the owner; Task 0 verifies.)**
- **One VM per turn, pre-booted.** Each turn gets a fresh VM from a per-agent **spare** that was booted ahead of time and has never run a turn; after the turn the VM is discarded, so a tainted turn leaves nothing behind. The agent's own persistent state (the runtime's session files for `--resume`) lives on a per-agent **home volume**, an engine-created block image attached read-write and never read by the engine — not a host directory, so spec §8.8.2's "only shared path is the worktree" holds **(controller's call)**.
- **The VM has no network interface.** Two virtio-vsock relays: the gateway and the egress proxy, host side on the engine's loopback ports (set **per exec**, because X1's `EgressProxyPool` picks a port per allowlist), guest side on the guest's loopback. X1's deny-all proxy for the harness is a closed guest port (nothing listens), so the harness has no egress and Bash reaches the company allowlist through the egress relay, exactly the split that exists on the host today. The turn's `LaunchSpec` already carries the turn token; the backend substitutes the guest base URL and nothing else.
- **Mounts:** the agent's worktree read-write (virtiofs; Docker bind mount), a per-turn read-only history snapshot for in-VM `git` (reached through `GIT_DIR`, never by rewriting the worktree's `.git`), and the agent's home volume. Engine read-back is unchanged: S's hardened git and `SafeFS`/`Place`.
- **Layouts:** `wholeTurn` for gateway turns (the runtime CLI runs in the VM); `commandsOnly` for subscription turns (harness on the host under Seatbelt as today, every Bash command in the VM through `CLAUDE_CODE_SHELL_PREFIX`), labelled **VM (commands)** (spec §8.8.3).
- **Admission** counts VMs against a RAM budget and the macOS VM licence limit before a turn starts; `auto` falls back to labelled Seatbelt or waits (owner setting, default `wait`). Everything above the layer (taint, secret gate, review, merge, gateway caps, emergency stop, canary) is unchanged.

**Tech Stack:** Swift 6.2 toolchain (main manifest `swift-tools-version: 6.0`, `.macOS(.v14)`; `Packages/BrahmaVMHost` at `.macOS("26")`), SwiftPM, GRDB.swift 7.x, Swift Testing; Apple Containerization (`github.com/apple/containerization`, pinned tag recorded by Task 0), Virtualization.framework, virtio-vsock, virtiofs; Docker CLI (optional, never required).

**Spec:** `docs/superpowers/specs/2026-11-21-any-product-and-hedges-design.md` (*spec §n*): owner decisions 11 and **21**, §5 (anti-goals; the one owner-decided fallback), §6 (macOS 26 + Apple silicon for the Linux micro-VM), §8.8 (all of it), §9.5, §9.6, §10 rows 4, 5 and **6**, §11, §12 (CLI rows `company isolation`, `agent isolation`, `settings isolation-overflow`, `isolation images`), §14. Outline: `2026-11-21-planX-outlines.md` (X8a, X8b).

**Builds on (merged first), with the names this plan consumes:**
- **X1** (`2026-11-21-planX1-runtime-billing-pacing.md`): `BrahmaRuntime` with `AgentRuntime`, `LaunchSpec { executable, arguments, environment, files, sandbox, workingDirectory, stdin }`, `LaunchSandbox`, `TurnShape { profile, kind, mode, auth, key }`, `AuthRoute { subscription, gateway }`, `RuntimeCatalog`, `ClaudeRuntime`, `RuntimeProcessRunner`, `CanaryTurnShape`; `BrahmaGateway` with `TurnTokenRegistry`, `GatewayToken`, `GatewayLaunch.baseURL` (a parameter, never a constant); `LaunchAuth.decide`; `TurnLauncher`; `turn.runtime/authRoute` columns; `ChildEnvironment.gatewayVariables`.
- **S:** `Purpose`/`SandboxPolicyFactory`/`PurposePlaces`/`Place`/`PolicyDecision`, `Spawn`/`ToolPaths`, `Decision<T>`, hardened git (`SafeGit`), `SafeFS`/`EngineFiles`, `HelperProtocol`, the helper canary probes (S7b), `AlertScope`.
- **R:** `TickParticipant`, `TickStepID`, `EngineService`/`EngineServiceDeps`, the recovery order at start, `EngineStatusReport`, `ModuleGraphTests.allowedEdges`, `PublicSurfaceTests`.
- **P:** `.processTier`/`.liveTier`, `ChangeTopics.map`, `CLITreeFrozenTests`/`cli-tree.tsv`, `ScreenInventoryTests`, `ScriptedTurnRunner`, `scripts/fake-claude.sh`.
- **X6a:** `MetricValue`, `MeasureReport`, `turn.backend` read by the isolation row (X6a-T5 note), `SoakCheckpoint`.
- Existing: `SandboxCanary`, `CanaryProbe`, `CanaryProbeResult.Layer { local, turn }`, `SandboxCanaryKey`, `CanaryLeakMatcher`, `ShellPrefix.script/write(layout:…)`, `SeatbeltProfile.render`, `EmergencyStopObserver`, `EmergencyStop.signalGroups`, `MemoryPressureSource`, `Store.markTainted`, `HumanTaskTemplate`.

Where merged code differs, **Task 0 records the drift and every later task uses Task 0's names.**

## Global Constraints

From S, R, P, X1, still binding:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The main manifest stays `swift-tools-version: 6.0`, `.macOS(.v14)`.
- Swift 6, SwiftPM, GRDB, Swift Testing; one `@Suite struct <FileName>` per new test file.
- Core targets (`BrahmaRuntime`, the new `BrahmaIsolation`, `BrahmaVMProtocol`) stay Linux-portable: no AppKit, SwiftUI, Virtualization, Containerization or CryptoKit. Those frameworks are imported only inside `Packages/BrahmaVMHost`.
- Child processes only through S's `Spawn` with `ToolPaths` (`brahma-vmhost` and `docker` are added to `ToolPaths`, verified like the other tools); files only through `EngineFiles`/`Place`; `try?`, `?? true/false` and empty `catch {}` banned in `Sources/BrahmaIsolation` and `Packages/BrahmaVMHost` (added to S's `failOpen` zero scope). `SafetyLintTests` gains **no** baseline entry.
- New `Purpose` cases (`vmHost`) only through S's factory; new tick work only as R `TickParticipant`s; new tables mapped in P's `ChangeTopics.map`; new public names appended to `public-surface.txt`.
- **Existing CLI commands unchanged.** Added: `brahma company isolation`, `brahma agent isolation`, `brahma settings isolation-overflow`, `brahma isolation images [list|build <backend>|verify]`, `brahma isolation bench --vms <n>` (owner soak helper). Each has P-shaped help, `EXAMPLES:`, a `cli-tree.tsv` row appended, refuses inside an agent turn (`BRAHMA_AGENT_ID`), and state-changing ones call `requireOwnerShell()`; each has a `refusedInsideAgentTurn` test.
- **Fail closed, with the one owner exception.** An explicitly chosen backend never falls back. `auto` falls back to `seatbelt` only when no VM backend can run, and the fallback is labelled **WEAKER ISOLATION** on the agent row, the company rail and the Inbox, recorded per turn (`turn.backend`, `turn.fallbackReason`), reported by `doctor`, `why` and `measure`, with one owner notice per company per day (spec §8.8.1).
- **The VM holds no credential.** Its environment is exactly the `LaunchSpec.environment` the runtime compiled, which after X1 contains no real key: only the 64-hex turn token (`TurnTokenFormat.isWellFormed`). No Keychain, SSH agent socket, cloud credential, owner dotfile or `~/.claude` enters a VM. A test asserts the guest environment name set equals the spec's.
- **Tests never touch** the real Keychain, launchd or the network. Unit-tier tests never load Containerization or Virtualization (`FakeVMHost`); the one `.processTier` exception is `VMHostSelftestTests`, which runs `brahma-vmhost --protocol` and `--selftest` (framework availability only, no VM boot) and is skipped when the binary is absent; VM boots happen only in `.liveTier` (`BRAHMA_LIVE=1`) and owner-run scripts.
- **Exact commands.** Each task's focused run is `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter '<Suite>'` for every suite the task names; expected output ends `Test run with N tests passed after …` with no failures; then `scripts/test.sh unit` (and `process` where the task says so). For the vmhost package: `DEVELOPER_DIR=… swift test --package-path Packages/BrahmaVMHost`.
- **Agents never handle secrets. Nothing deploys without owner approval.** Never `pkill`; never kill a process you did not start (VM stop goes through the vmhost's own `stop`, then `EmergencyStop.signalGroups` on its recorded group).
- Every task ends with `swift build` green for all targets (and `swift build --package-path Packages/BrahmaVMHost` where the SDK is macOS 26) and `scripts/test.sh unit` green; tasks touching processes also run `scripts/test.sh process`.
- Commit messages end with `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`.

**Pinned numbers** (each a `static let` on the named type; Task 0 may replace a *(probe)* value with the measured one and records why):

| Constant | Value | Owner |
|---|---|---|
| Backend ids | `seatbelt`, `linux-vm`, `macos-vm`, `docker` | `IsolationBackendId` |
| Default selection | `auto`; order for a company whose surfaces need Xcode: `macos-vm → seatbelt`; otherwise `linux-vm → docker → seatbelt` | `AutoSelection.order` |
| RAM budget | `totalRAM − 8 GiB` reserved for the owner; per-VM size `linux-vm` 2 GiB *(probe; 0.5–2 GiB)*, `macos-vm` 6 GiB, `docker` 2 GiB | `Admission.reserve`, `ImageRecord.ramBytes` |
| Licence slots | at most **2** concurrent `macos-vm` instances | `Admission.macOSLicenceSlots` |
| Disk | an image build or a VM start needs ≥ 10 GiB free (`linux-vm`, `docker`) or ≥ 80 GiB (`macos-vm` build) | `Admission.diskFloor` |
| Overflow | `wait` (default) or `fallback`, owner-wide | `ownerSettings.isolationOverflow` |
| Spare VMs | one pre-booted spare per agent with a running or ready turn; a spare idle ≤ 15 min awake is stopped, and is evicted earlier when admission needs its RAM; a VM runs exactly one turn and is then discarded; start budget p95 ≤ 2 s (`linux-vm`) *(probe)*, ≤ 90 s (`macos-vm`) | `SparePool.idleLimit`, `IsolationBudgets` |
| Relays | exactly two per VM: gateway and egress proxy; guest-side loopback ports fixed `127.0.0.1:7777` (gateway) and `127.0.0.1:7778` (egress); host-side ports set per `exec`; the harness's deny-all proxy is the closed guest port `127.0.0.1:9` | `RelaySpec` |
| Mounts | `/work` = the agent's worktree (rw; in the split layout also at its host path); `/history` = the read-only per-turn snapshot reached by `GIT_DIR=/history GIT_WORK_TREE=/work GIT_INDEX_FILE=/tmp/brahma-index`; `/home/agent` = the agent's home volume (rw, engine-created, never engine-read); Docker adds `/run/brahma` (ro, relay sockets only) and `--tmpfs /tmp`; nothing else from the host | `MountSpec` |
| Images | sha256-pinned; the vmhost hashes the file **it opened** before boot (no verify-then-open gap); built for the owner's uid (`ImageRecord.uid`); the first build of each is an owner ask showing download and disk size, filed once by `auto` when no image exists | `ImageRecord`, `HumanTaskTemplate.isolationImage` |
| Control socket | `<home>/run/vmhost.sock`, 0600, engine uid; every `exec`/`stop` names a `vmId` and its 32-byte capability token; a wrong token is refused and logged | `VMHostProtocol` |
| Stop | `stop` grace 5 s, then the vmhost and its VM processes (`com.apple.Virtualization.VirtualMachine` XPC children) are `SIGKILL`ed; orphan VMs are found and stopped at engine start | `IsolationBudgets.stopGrace` |
| Labels | `WEAKER ISOLATION` for `seatbelt` always (fallback or explicit, with the reason or "chosen"); `VM` for `wholeTurn`; `VM (commands)` for `commandsOnly` on a VM backend | `IsolationLabel.for(backend:layout:reason:)` |
| Daily notice | one per company per owner-calendar day while any turn fell back | `FallbackNotice` |
| Memory soak | N ∈ {2, 4, 8} concurrent spare VMs, 10 min each, sampled every 10 s; pass = host free RAM ≥ 8 GiB at every sample and swap growth ≤ 256 MiB | `VMMemoryBench` |

## Review Focus

1. **A link written inside the VM escapes the worktree on read-back:** the guest writes `/work/evil -> /etc/passwd` (symlink) or a hard link into the history snapshot, then the engine's commit, diff or export follows it. Expected: refused exactly as a Seatbelt worktree's link is today (hardened git, `SafeFS`). → T8 `WorktreeMountTests.linkEscapeRefusedOnReadBack`, T18 red team.
2. **The relay reaches another host port:** the guest sends `CONNECT 127.0.0.1:<service socket port>` to the egress relay, or spoofs a vsock port. Expected: the host relays only to the two configured ports; the egress proxy refuses loopback and private targets; the canary's network probe proves it. → T7 `VsockRelayTests.onlyTwoPortsForwarded`, T13 probe `vm-network`.
3. **The split layout's shell prefix runs a command on the host** when the agent's VM is gone (stopped by STOP, crashed, idle-reaped). Expected: the prefix refuses with `isolation: VM unavailable`, the turn ends, nothing runs on the host. → T10 `SplitLayoutTests.prefixRefusesWhenVMGone`.
4. **Two turns are admitted at once and overshoot the RAM budget**, or a hung guest ignores `stop` on STOP. Expected: admission is serialized through one actor and never exceeds the budget; STOP kills the vmhost after `stopGrace`. → T3 `AdmissionTests.concurrentAdmissionNeverExceedsBudget`, T12 `EmergencyStopVMTests.hungGuestIsKilled`.
5. **A tampered or stale image boots:** an image file edited after its record, or a record whose sha256 no longer matches. Expected: the backend is unavailable with `image <id> failed verification`, and `auto` treats it as "no VM can run". → T4 `ImageRegistryTests.tamperedImageRefused`, T5 `VMHostProtocolTests.bootHashesOpenedFile`, T11 `AutoSelectionTests.unverifiedImageIsNoVM`.

---

## File Structure

```
Package.swift                                              + target BrahmaIsolation (→ BrahmaRuntime, BrahmaSafety, BrahmaStore, BrahmaVMProtocol), + BrahmaVMProtocol; + test target BrahmaIsolationTests
Packages/BrahmaVMHost/Package.swift                        separate package, .macOS("26"); executable brahma-vmhost; depends on apple/containerization (pinned) and ../..'s BrahmaVMProtocol by path
Packages/BrahmaVMHost/Sources/brahma-vmhost/{Main,LinuxVM,MacOSVM,Relay,Mounts,Selftest}.swift
Sources/BrahmaVMProtocol/VMHostProtocol.swift             VMHostRequest/Response, VMSpec, RelaySpec, MountSpec, VMHostProtocol.version
Sources/BrahmaRuntime/Isolation/IsolationBackend.swift    protocol + IsolationBackendId, IsolationLayout, HostFacts, BackendCapacity, IsolatedTurn, IsolatedLaunch
Sources/BrahmaRuntime/Isolation/SeatbeltBackend.swift     today's launch, wrapped
Sources/BrahmaRuntime/TurnShape.swift                     + backend, layout (key unchanged for today's shapes)
Sources/BrahmaModel/Isolation/{ImageRecord,IsolationSetting,VMInstance}.swift
Sources/BrahmaIsolation/{VMHostClient,FakeVMHost(in test support),LinuxVMBackend,MacOSVMBackend,DockerBackend,DockerRelay}.swift
Sources/BrahmaIsolation/{Admission,AutoSelection,SparePool,HomeVolume,ImageRegistry,HistorySnapshot,FallbackNotice,VMMemoryBench}.swift
Sources/BrahmaGateway/GatewayRoutes.swift, GatewayServer.swift   + /t/mcp/ route (T9)
Sources/BrahmaSafety/Policy/Purpose.swift                 + case vmHost(VMHostPlaces)
Sources/BrahmaStore/Store+Isolation.swift; Migrations.swift ("vX8-isolation")
Sources/BrahmaEngine/Turns/TurnLauncher.swift             backend selection, prepare, turn columns
Sources/BrahmaEngine/Tick/{IsolationStep,VMRecoveryStep}.swift
Sources/BrahmaEngine/Engine/Doctor.swift                  items isolation, isolation-images, vmhost
Sources/BrahmaService/EngineService.swift                 injects the backends (Darwin) into EngineServiceDeps.isolationBackends
Sources/brahma/IsolationCommands.swift                    company isolation, agent isolation, settings isolation-overflow, isolation images|bench
Sources/BrahmaAppModel/Isolation/IsolationModel.swift; Sources/BrahmaApp/Views/{IsolationPanel,IsolationBadge}.swift
scripts/isolation/{build-linux-image.sh,build-macos-image.sh}; images/linux/Containerfile; scripts/soak/vm-memory.sh
scripts/make-app.sh                                       builds Packages/BrahmaVMHost when the SDK allows; Contents/Helpers/brahma-vmhost; entitlement
Tests/BrahmaIsolationTests/, Tests/BrahmaRuntimeTests/, Tests/BrahmaEngineTests/, Tests/BrahmaCLITests/ (new files per task)
docs/runtimes/isolation.md                                owner doc (T18)
```

---

### Task 0: Re-read X1, S, R, P and X6a as merged; read the X8a-0 and X8b-0 probe reports; record the drift

**Files:**
- Create: `.superpowers/sdd/planX4/inventory.md`
- Read: `docs/research/x8a-0-probes.md`, `docs/research/x8b-0-probes.md` (pre-work items 5 and 6 of the outline file). If either is missing, run that pre-work first; its Swift spike lives outside `Sources/`.

**Interfaces:**
- Produces, in the inventory: (a) every "Builds on" name, "as named" or "renamed to"; (b) the merged `TurnShape`, `LaunchSpec`, `RuntimeProcessRunner`, `TurnLauncher`, `CanaryStep` and `SandboxCanary` signatures and where `ShellPrefix` landed; (c) the probe outcomes that set pinned numbers: cold/warm start, virtiofs throughput, relay latency, per-VM RSS, whether Containerization runs under a Seatbelt profile with `(allow mach-lookup)` for the virtualization services, the exact entitlement and signing facts, and `claude` running a headless turn inside the guest through the relay; (d) whether a SwiftPM dependency on `apple/containerization` resolves from a `.macOS(.v14)` package (expected no, which is why `brahma-vmhost` is a separate package), and the Containerization tag to pin; (e) R's `TickOrderTests` literal and the proposed slots for `isolation` (before `dispatch`) and `vmRecovery` (in R's recovery order, before any turn launch); (f) the process model: whether the guest runs inside Apple's `com.apple.Virtualization.VirtualMachine` XPC service (expected yes), whether killing the vmhost tears it down, how to enumerate those PIDs for the memory soak (children of the vmhost in `ProcessTable`), and whether a Containerization rootfs can be discarded without a restart (expected no, which is why a VM runs one turn); (g) the home-volume facts: ext4 image creation through Containerization's EXT4 API and attaching it as a second block device.

- [ ] **Step 1:** Generate (a)–(e) on merged `main`.
- [ ] **Step 2: Stop rules.** Stop and report to the controller if the probe found that (i) a `claude` turn cannot complete inside the Linux guest through the vsock relay, or (ii) the vmhost cannot drive Containerization under any Seatbelt profile (then `Purpose.vmHost` would have to be `fullOptOut`, which spec §8.8.2 does not allow). If only the macOS VM or Docker probes failed, continue: T15 or T16 ends at a probe report and the backend is "unavailable" with the published reason (spec §14).
- [ ] **Step 3: Commit** the inventory with the probe outcomes in the body.

---

### Task 1: `IsolationBackend` and its value types; `TurnShape` gains `backend` and `layout`

**Files:**
- Create: `Sources/BrahmaRuntime/Isolation/IsolationBackend.swift`, `Sources/BrahmaModel/Isolation/ImageRecord.swift`, `Tests/BrahmaRuntimeTests/IsolationTypesTests.swift`
- Modify: `Sources/BrahmaRuntime/TurnShape.swift` (or where X1 put it), `public-surface.txt`

**Interfaces:**
- Produces (spec §8.8.4; shapes are the controller's call where the spec is silent):
  - `public struct IsolationBackendId: RawRepresentable, Hashable, Codable, Sendable { public let rawValue: String; public static let seatbelt, linuxVM /* "linux-vm" */, macOSVM /* "macos-vm" */, docker: IsolationBackendId; public static let all: [IsolationBackendId] }`.
  - `public enum IsolationLayout: String, Codable, Sendable { case wholeTurn = "whole-turn", commandsOnly = "commands-only" }`.
  - `public struct ImageRecord: Codable, Equatable, Sendable { backend: IsolationBackendId; id: String; sha256: String; path: String; bytes: UInt64; ramBytes: UInt64; uid: UInt32; builtAt: Date; verifiedAt: Date?; cliVersions: [String: String] }` (in `BrahmaModel`, mirrored by Task 3's table).
  - `public struct HostFacts: Sendable, Equatable { public var osVersion: OperatingSystemVersion; public var appleSilicon: Bool; public var totalRAM: UInt64; public var freeRAM: UInt64; public var freeDisk: UInt64; public var images: [IsolationBackendId: ImageRecord]; public var imageVerified: Set<IsolationBackendId>; public var vmHostVerified: Bool; public var dockerAnswering: Bool }` — structural facts only, values; the engine fills it (`HostFacts.gather`, Task 3). Resource counts live in `Admission`'s own ledger, not here.
  - `public struct BackendCapacity: Sendable, Equatable { public var ramPerVM: UInt64; public var licenceSlots: Int? /* 2 for macos-vm, nil = unbounded */ }`.
  - `public struct BackendRefusal: Error, Equatable, Sendable { public enum Kind: String, Sendable { case structural /* OS, chip, no image ever, vmhost missing */, resource /* RAM, disk, licence slots */, transient /* image unverified, docker not answering */ }; public var kind: Kind; public var detail: String }` — `availability` returns `Result<BackendCapacity, BackendRefusal>`; `AutoSelection` reads `kind`.
  - `public struct IsolatedTurn: Sendable { public var turnId: String; public var companyId: String; public var agentId: String; public var worktree: Place; public var scratch: Place; public var gatewayPort: UInt16?; public var egressPort: UInt16?; public var layout: IsolationLayout }`.
  - `public struct IsolatedLaunch: Sendable, Equatable { public var spec: LaunchSpec /* what RuntimeProcessRunner spawns: for VM backends the executable is brahma-vmhost (exec client) or docker */; public var backend: IsolationBackendId; public var layout: IsolationLayout; public var vmId: String?; public var fallbackReason: String? }`.
  - `public protocol IsolationBackend: Sendable { var id: IsolationBackendId { get }; func availability(_ host: HostFacts) -> Result<BackendCapacity, BackendRefusal>; func layouts(for auth: AuthRoute) -> [IsolationLayout]; func prepare(_ spec: LaunchSpec, _ turn: IsolatedTurn) async throws(IsolationError) -> IsolatedLaunch /* admits resources, takes or boots a VM */; func canaryProbes(layout: IsolationLayout) -> [CanaryProbe]; func release(_ launch: IsolatedLaunch) async /* discards the turn's VM and releases its admission ticket */; func stopAll(reason: String) async }` — `stopAll` is the `EmergencyStopObserver` hook. **(controller's call: `canaryProbes` takes the layout; `release` is added because a turn's VM outlives its process.)**
  - `public enum IsolationError: Error, Equatable { case unavailable(BackendRefusal); case imageUnverified(String); case hostRefused(String) }`.
  - `TurnShape` gains `public var backend: IsolationBackendId = .seatbelt` and `public var layout: IsolationLayout = .commandsOnly`; `key` is unchanged when `backend == .seatbelt && layout == .commandsOnly`, else today's key + `+<backend.rawValue>/<layout.rawValue>`.

- [ ] **Step 1: Write the failing tests:** `IsolationTypesTests.todaysShapeKeysUnchanged` (every X1 golden shape with default backend and layout → X1's key string), `vmShapeKeyHasSuffix`, `layoutRawValues`, `backendIdsAreExactlyFour`.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run them, X1's `RuntimeTypesTests`, `PublicSurfaceTests`, the unit tier. Expected: PASS, no canary key changes.
- [ ] **Step 5: Commit:** `feat(runtime): IsolationBackend interface; TurnShape gains backend and layout (today's keys unchanged)`.

---

### Task 2: `SeatbeltBackend` — today's launch behind the interface (byte-identical)

**Files:**
- Create: `Sources/BrahmaRuntime/Isolation/SeatbeltBackend.swift`, `Tests/BrahmaRuntimeTests/SeatbeltBackendTests.swift`
- Modify: `TurnLauncher` (every launch goes `runtime.compile → backend.prepare → runner`), `RuntimeProcessRunner` (spawns `IsolatedLaunch.spec`)

**Interfaces:**
- Consumes: Task 1.
- Produces: `public struct SeatbeltBackend: IsolationBackend` — `id == .seatbelt`; `availability` always `.success(BackendCapacity(ramPerVM: 0, licenceSlots: nil))`; `layouts(for:)` = `[.commandsOnly]` for both auth routes (today's Claude shape; X2's whole-process Codex purpose adds `.wholeTurn` there); `prepare` returns the `LaunchSpec` unchanged with `fallbackReason: nil`; `canaryProbes` = today's probe file's blocking probes (so the comparison the app shows runs the same list); `release`/`stopAll` are no-ops (process groups are stopped by the existing path).

- [ ] **Step 1: Write the failing tests:** `SeatbeltBackendTests.prepareIsIdentity` (for every X1 golden shape, `prepare(spec).spec == spec`), `X1's ClaudeParityGoldenTests` still pass through the launcher's new path, `launcherRefusesUnknownBackend` (a `TurnRequest` naming a backend id with no registered backend → `TurnError` text `isolation backend <id> is not available`, nothing spawned).
- [ ] **Step 2:** FAIL. **Step 3:** Implement; `EngineServiceDeps.isolationBackends: [any IsolationBackend]` defaults to `[SeatbeltBackend()]`. **Step 4:** PASS with the unit and process tiers and `scripts/golden-path.sh`.
- [ ] **Step 5: Commit:** `feat(runtime): SeatbeltBackend; TurnLauncher prepares every launch through an IsolationBackend (goldens unchanged)`.

---

### Task 3: Schema `"vX8-isolation"`, host facts and resource admission

**Files:**
- Create: `Sources/BrahmaStore/Store+Isolation.swift`, `Sources/BrahmaModel/Isolation/{IsolationSetting,VMInstance}.swift`, `Sources/BrahmaIsolation/{HostFacts+Gather,Admission}.swift`, `Sources/brahma/SettingsIsolationOverflow.swift`, `Tests/BrahmaStoreTests/StoreIsolationTests.swift`, `Tests/BrahmaIsolationTests/AdmissionTests.swift`, `Tests/BrahmaCLITests/IsolationOverflowCommandTests.swift`
- Modify: `Migrations.swift` (append), `ChangeTopics.map`, `Package.swift` (target `BrahmaIsolation`, test target)

**Interfaces:**
- Produces tables: `company.isolation TEXT NOT NULL DEFAULT 'auto'`; `agent.isolation TEXT NULL /* nil = inherit */`; `ownerSettings.isolationOverflow TEXT NOT NULL DEFAULT 'wait'`; `turn.backend TEXT NULL`, `turn.layout TEXT NULL`, `turn.fallbackReason TEXT NULL`; `isolationImage(backend PK, id, sha256, path, bytes, ramBytes, uid, builtAt, verifiedAt, cliVersions TEXT /* JSON */)`; `vmInstance(id PK, backend, agentId, companyId, turnId NULL, hostPid, token TEXT /* capability, 64 hex */, state /* spare|running|stopping */, ramBytes, startedAt)`; `fallbackNotice(companyId, day TEXT, PK(companyId, day))`. `ChangeTopics`: `isolationImage`, `vmInstance`, `fallbackNotice` → `.usage`.
- Store API: `isolation(companyId:) -> IsolationSetting`, `setIsolation(_:companyId:)`, `agentIsolation(agentId:) -> IsolationBackendId?`, `setAgentIsolation(_:agentId:)`, `isolationOverflow() -> OverflowMode`, `setIsolationOverflow(_:)`, `image(backend:) -> ImageRecord?`, `saveImage(_:)`, `vmInstances() -> [VMInstance]`, `upsertVM(_:)`, `removeVM(id:)`, `fallbackNoticeSent(companyId:day:) -> Bool`, `markFallbackNotice(companyId:day:)`. Types: `public enum IsolationSetting: String, Codable { auto, seatbelt, linuxVM = "linux-vm", macOSVM = "macos-vm", docker }`, `public enum OverflowMode: String, Codable { wait, fallback }`, `VMInstance` mirroring the table.
- `extension HostFacts { static func gather(store: Store, images: ImageRegistry, vmHost: VMHostVerifying, docker: DockerProbe, now: Date) -> HostFacts }` — `sysctl hw.memsize`, `host_statistics64` free pages, `statfs` on the data home, images and their verification from Task 4's registry, the vmhost check from Task 5; `DockerProbe` is a protocol (`FakeDockerProbe` in tests) whose real form runs `docker version --format '{{.Server.Version}}'` through `Spawn` with a 3 s timeout.
- `public actor Admission { init(store: Store, totalRAM: UInt64, reserve: UInt64 = 8 << 30, diskFloor: [IsolationBackendId: UInt64], macOSLicenceSlots: Int = 2); func admit(_ backend: IsolationBackendId, ramPerVM: UInt64, freeDisk: UInt64) -> Result<AdmissionTicket, BackendRefusal>; func release(_ ticket: AdmissionTicket); func evictableSpares(for backend: IsolationBackendId) -> [String] }` with `public struct AdmissionTicket: Hashable, Sendable { id: UUID; backend: IsolationBackendId; ramBytes: UInt64 }` — the actor keeps its own ledger of tickets, seeded at start from `vmInstance` rows (so counts never come from a stale `HostFacts` snapshot); refuses (`kind: .resource`) when `Σ ramBytes(tickets) + ramPerVM > totalRAM − reserve`, when `freeDisk < diskFloor[backend]`, or when `macos-vm` tickets ≥ slots; the refusal text names the number (`RAM budget: 3 VMs × 2 GiB running, 16 GiB available`). Before refusing for RAM it reports spares the backend may evict (`SparePool`, Task 6).
- CLI: `brahma settings isolation-overflow [fallback|wait]` (prints the current mode with no argument).

- [ ] **Step 1: Write the failing tests:** `StoreIsolationTests.defaultsAreAutoAndWait`, `agentInheritsWhenNil`, `everyNewTableMapped`; `AdmissionTests.refusesOverRamBudget`, `macOSLimitedToTwo`, `diskFloorRefuses`, `ledgerSeededFromVMInstances`, `concurrentAdmissionNeverExceedsBudget` (Review Focus 4: 50 concurrent `admit` calls against a budget of 4 → exactly 4 tickets), `releaseFreesSlot`, `reportsEvictableSpares`; `IsolationOverflowCommandTests.setsAndShows`, `refusedInsideAgentTurn`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement; append the `cli-tree.tsv` row. **Step 4:** PASS with `StoreMigrationTests`, `ChangeTopicsTests`, P's CLI tests, the unit tier.
- [ ] **Step 5: Commit:** `feat(store,isolation): vX8-isolation schema, host facts and VM admission; brahma settings isolation-overflow`.

---

### Task 4: Linux image — registry, reproducible build, sha256 pin, verify at boot, `brahma isolation images`

**Files:**
- Create: `Sources/BrahmaIsolation/ImageRegistry.swift`, `images/linux/Containerfile`, `scripts/isolation/build-linux-image.sh`, `Sources/brahma/IsolationImagesCommand.swift`, `Tests/BrahmaIsolationTests/ImageRegistryTests.swift`, `Tests/BrahmaCLITests/IsolationImagesCommandTests.swift`
- Modify: `HumanTaskTemplate` (+ `isolationImage`), `HumanTasks.render` (steps: size shown, the one command), `Doctor.swift` (item `isolation-images`)

**Interfaces:**
- Produces:
  - `public struct ImageRegistry { init(store: Store, paths: BrahmaPaths); func verified(_ backend: IsolationBackendId, now: Date) -> Result<ImageRecord, BackendRefusal> }` — reads the record, opens the file as a `Place`, streams sha256 (through S's `SafeRead`), compares; a mismatch returns `.transient("image <id> failed verification")` and the doctor item fails; a record whose `uid` is not the owner's or whose `cliVersions["claude"]` differs from the host's `claude` version returns `.transient` with `rebuild: brahma isolation images build <backend>` and the doctor says so. Verification runs daily (`IsolationStep`) and on `brahma isolation images verify`; **the boot-time check is the vmhost's own** (Task 5: it hashes the file it opened), so there is no verify-then-open gap.
  - `images/linux/Containerfile`: a pinned base (Debian stable by digest), `git`, `curl`, `ca-certificates`, Node LTS by pinned tarball sha256, `@anthropic-ai/claude-code@<pinned>` (the version the host's `claude` reports; recorded in `cliVersions`), the guest relay (Task 7), a non-root user `agent` whose uid is the owner's (`getuid()` at build, recorded in `ImageRecord.uid`, so the virtiofs mount is writable), `/work`, `/history` and `/home/agent` mount points, an `/etc/hosts` with no outside names; no package manager cache, fixed mtimes (`SOURCE_DATE_EPOCH`), so two builds for the same uid hash identically.
  - `scripts/isolation/build-linux-image.sh`: builds the OCI rootfs with Apple's `container build` when present, else `docker build`; converts to the ext4 block image with `brahma-vmhost image build --rootfs <dir> --out <path>` (Task 5); writes `<home>/images/linux-vm/<sha256>.ext4` and prints the record JSON. The kernel is Containerization's pinned kernel artefact (URL and sha256 in `ImageRegistry.kernelPin`), fetched once through the egress policy (`github.com` only) and verified.
  - The first build is a human task `isolationImage` with the download size, the disk size and the one command; `brahma isolation images build linux-vm` runs the script from the owner shell. **No agent can start a build.**
  - CLI: `brahma isolation images` / `images list` (backend, id, size, RAM, built, verified), `images build <backend>`, `images verify`.

- [ ] **Step 1: Write the failing tests:** `ImageRegistryTests.missingImageIsStructural`, `tamperedImageRefused` (Review Focus 5: flip one byte after `saveImage` → refused; the doctor item fails), `uidOrCLIMismatchAsksRebuild`, `verifiedRecordsTime`; `IsolationImagesCommandTests.listShowsSizes`, `buildIsOwnerOnly`, `refusedInsideAgentTurn`; `ContainerfilePinTests.everyFetchIsPinned` (every `curl`/`ADD` in the Containerfile names a sha256; no `latest` tag).
- [ ] **Step 2:** FAIL. **Step 3:** Implement; run `shellcheck scripts/isolation/build-linux-image.sh` if installed. **Step 4:** PASS with the unit tier. Owner-run once (recorded in the task report): build the image twice and compare hashes (reproducibility).
- [ ] **Step 5: Commit:** `feat(isolation): pinned Linux image registry, reproducible build, verify at boot; brahma isolation images`.

---

### Task 5: `brahma-vmhost` — the separate package, its protocol, `Purpose.vmHost`, signing (security)

**Files:**
- Create: `Packages/BrahmaVMHost/Package.swift`, `Packages/BrahmaVMHost/Sources/brahma-vmhost/{Main,Selftest}.swift`, `Sources/BrahmaVMProtocol/VMHostProtocol.swift`, `Sources/BrahmaIsolation/VMHostClient.swift`, `Sources/BrahmaSafety/Policy/Purpose.swift` (+ `vmHost`), `Resources/BrahmaVMHost.entitlements`, `Tests/BrahmaIsolationTests/{VMHostProtocolTests,VMHostClientTests}.swift`, `Tests/BrahmaSafetyTests/VMHostPolicyTests.swift`
- Modify: `scripts/make-app.sh` (build the package when `xcrun --show-sdk-version` ≥ 26; copy to `Contents/Helpers/brahma-vmhost`; `codesign --entitlements Resources/BrahmaVMHost.entitlements`), `ToolPaths` (+ `vmHost`), `Doctor.swift` (item `vmhost`)

**Interfaces:**
- Produces:
  - `VMHostProtocol.version = 1`. The `--serve` process listens on `<home>/run/vmhost.sock` (0600, created by the engine and passed as an inherited fd). Requests (one JSON line each, ≤ 64 KiB): `imageBuild { rootfs, out }`, `volumeCreate { out, bytes }`, `start { vm: VMSpec } → { vmId, token }`, `exec { vmId, token, argv, env, cwd, relays: [RelaySpec] /* host ports for this exec */ }`, `stop { vmId, token, grace }`, `list`, `selftest`. Responses (≤ 256 KiB): `ok { result }` or `refusal { code, detail }`; `exec` streams the guest process's stdout lines as `{ "line": … }`, relays stdin, and ends with `{ "exit": n }`; a request whose `token` does not match the VM's is refused with `code: badToken` and logged. `VMSpec { backend, image: path+sha256, kernel: path+sha256, homeVolume: path, cpus, ramBytes, mounts: [MountSpec], env: [String: String] }`. Strict decoding as S's `HelperProtocol`. **Boot verification:** the vmhost opens the image and the kernel, hashes the open descriptors, compares with the spec's sha256 and boots from those descriptors; a mismatch is `refusal imageUnverified`.
  - `brahma-vmhost exec --vm <id>` is the thin client the runner spawns: it connects to the socket, sends `exec` with the token from its environment (`BRAHMA_VM_TOKEN`, set by the backend in the `IsolatedLaunch.spec.environment`, host side only; never in the guest env) and pipes stdin/stdout. `--protocol` prints the version; `--selftest` checks the entitlement is present on its own binary (`SecCodeCopySigningInformation`), Virtualization is available, and Containerization's kernel/rootfs APIs load; `--serve` runs the request loop.
  - `Purpose.vmHost(VMHostPlaces { images: Place; volumes: Place; worktrees: [Place]; scratch: Place; socket: Place; relayPorts: [UInt16] })` → `SandboxPolicyFactory.decide` yields a profile with: reads of the images and kernel; reads and writes of the volumes dir, the scratch (overlays, index files) and the mounted worktrees; the socket; `(allow network-outbound (remote ip "localhost:<port>"))` for exactly the relay ports in use; the mach services Task 0 found Virtualization needs; everything else denied, including the data home and the owner's home. The profile is re-rendered when the set of mounted worktrees changes (the vmhost is restarted at that point; spares re-boot).
  - `public final class VMHostClient: VMHosting { init(socket: Place, spawn: Spawn, tools: ToolPaths, policy: PolicyDecision); func start(_ spec: VMSpec) async throws(IsolationError) -> (vmId: String, token: String); func exec(vmId: String, token: String, argv: [String], env: [String: String], cwd: String, relays: [RelaySpec]) -> AsyncThrowingStream<String, Error>; func stop(vmId: String, token: String, grace: Duration) async; func list() async throws -> [VMInstance]; func createVolume(path: Place, bytes: UInt64) async throws }`; `protocol VMHosting` lets tests inject `FakeVMHost`; `protocol VMHostVerifying { func verify() -> Result<Void, BackendRefusal> }`.
  - `HostFacts.vmHostVerified`: at engine start `HelperBinary.verify`-style checks on `brahma-vmhost` (regular file, owner, not writable by group/world, not under a workspace, `--protocol` matches). Failure → doctor `vmhost: fail` and `linux-vm`/`macos-vm` unavailable (`structural`) with that reason; Docker is unaffected.

- [ ] **Step 1: Write the failing tests:** `VMHostProtocolTests.strictDecodingRejectsUnknownKeys`, `oversizeRequestRefused`, `badTokenRefused`, `bootHashesOpenedFile` (Review Focus 5: the vmhost's hashing function is given a descriptor whose file is replaced after open → it hashes the opened content); `VMHostClientTests.protocolMismatchIsUnavailable`, `execStreamsLinesThenExit` (`FakeVMHost`), `execTokenNeverInGuestEnv`; `VMHostPolicyTests.profileAllowsOnlyRelayPortsAndSocket`, `profileDeniesHomeAndDataHome` (rendered profile text); `.processTier`: `VMHostSelftestTests.protocolAndSelftest` (skips unless `.build/…/brahma-vmhost` exists and the SDK is ≥ 26).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. The package pins `apple/containerization` to Task 0's tag. **Step 4:** PASS with the unit and process tiers; `scripts/make-app.sh debug` produces `Contents/Helpers/brahma-vmhost` with the entitlement (`codesign -d --entitlements - ` shows it).
- [ ] **Step 5: Commit:** `feat(isolation): brahma-vmhost package and protocol; Purpose.vmHost profile; entitlement in make-app`.

---

### Task 6: `LinuxVMBackend` — one VM per turn, a pre-booted spare per agent, the home volume

**Files:**
- Create: `Sources/BrahmaIsolation/{LinuxVMBackend,SparePool,HomeVolume}.swift`, `Packages/BrahmaVMHost/Sources/brahma-vmhost/LinuxVM.swift`, `Tests/BrahmaIsolationTests/{LinuxVMBackendTests,SparePoolTests,HomeVolumeTests}.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 5.
- Produces: `public final class LinuxVMBackend: IsolationBackend` — `id == .linuxVM`; `availability` (structural, synchronous): `.structural` unless `osVersion.majorVersion ≥ 26 && appleSilicon && vmHostVerified` and an image record exists; `.transient` unless the image is verified; `layouts(for:)` = `[.wholeTurn]` for `.gateway`, `[.commandsOnly]` for `.subscription`; `prepare`: `Admission.admit` (on a RAM refusal, evict the spares `Admission.evictableSpares` names and retry once), then take the agent's spare from `SparePool` or boot one (`VMSpec`: the image, a fresh writable overlay in scratch, the agent's worktree, the agent's home volume, the turn's `LaunchSpec.environment` minus the host-only variables), start booting the next spare in the background, and return an `IsolatedLaunch` whose `spec.executable` is `brahma-vmhost`, `arguments = ["exec", "--vm", id, "--", …runtime argv]`, `environment` = `["BRAHMA_VM_TOKEN": token]` only, `stdin` = the runtime's prompt; `release` stops and discards the VM and its overlay and releases the ticket; `stopAll` stops every VM of this backend.
  - `actor SparePool { func take(agentId:) -> VMInstance?; func put(agentId:_:now:); func reapIdle(now:) -> [VMInstance]; func evict(ids:) -> [VMInstance]; idleLimit = 15 min awake }`; the reaper is `IsolationStep` (Task 11). A spare is booted only for an agent with a ready or running turn.
  - `HomeVolume { static func ensure(agentId:paths:host:) async throws -> Place }` — `<home>/volumes/<agentId>.ext4`, 4 GiB sparse, created once through `volumeCreate`, attached at `/home/agent`; deleted on kill-and-rehire (the existing agent-removal path) and never opened by the engine (a lint: no engine code names `volumes/` except `HomeVolume`).
  - In the guest, `exec` runs as the image's uid in `/work`, with `HOME=/home/agent`, `GIT_DIR=/history`, `GIT_WORK_TREE=/work`, `GIT_INDEX_FILE=/tmp/brahma-index`, and the `env` exactly as given: a test asserts the set of names equals `LaunchSpec.environment.keys` ∪ `{HOME, PATH, TERM, GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE}`, and that `BRAHMA_VM_TOKEN` is absent.

- [ ] **Step 1: Write the failing tests** (`FakeVMHost`): `LinuxVMBackendTests.structuralBelowMacOS26`, `transientWithoutVerifiedImage`, `wholeTurnOnlyForGateway`, `prepareTakesSpareThenBootsNext`, `oneVMPerTurnNeverReused` (two turns of one agent → two distinct vmIds; the first is stopped at `release`), `evictsSparesBeforeRefusing`, `guestEnvironmentIsExactlyTheSpecs` (no `ANTHROPIC_*` beyond the spec's; the token is the only credential-shaped value; no `BRAHMA_VM_TOKEN`), `releaseStopsAndDiscards`; `SparePoolTests.reapsAfterIdleLimit`, `oneSparePerAgent`, `evictReturnsInstances`; `HomeVolumeTests.createdOnceAndAttached`, `engineNeverOpensVolumes` (lint).
- [ ] **Step 2:** FAIL. **Step 3:** Implement; the vmhost side uses Containerization's container/VM API as Task 0 recorded. **Step 4:** PASS with the unit tier; `.liveTier` `LiveVM/linuxBootAndEcho` (owner-run once: boot, `echo ok`, stop; records start time against `IsolationBudgets`) and `LiveVM/resumeAcrossVMs` (a `claude --resume` on a second VM finds the session on the home volume).
- [ ] **Step 5: Commit:** `feat(isolation): LinuxVMBackend — one VM per turn from a pre-booted spare; per-agent home volume`.

---

### Task 7: vsock relays — gateway and egress proxy into the guest, nothing else (security)

**Files:**
- Create: `Packages/BrahmaVMHost/Sources/brahma-vmhost/Relay.swift`, `Sources/BrahmaIsolation/RelaySpec+Make.swift`, `images/linux/relay/main.go` (the guest relay: a static Go binary, ~60 lines, listening on `127.0.0.1:7777/7778` and forwarding to vsock ports 7777/7778; built in the Containerfile from a pinned Go toolchain), `Tests/BrahmaIsolationTests/VsockRelayTests.swift`
- Modify: `TurnLauncher` (for VM layouts it passes the runtime a `GatewayLaunch` whose `baseURL` is `http://127.0.0.1:7777/t/` — X1 made it a parameter, so `ClaudeGatewayCompile` is unchanged — and `HTTPS_PROXY=http://127.0.0.1:9` as the harness's deny-all; the shell prefix's company proxy becomes `http://127.0.0.1:7778`)

**Interfaces:**
- Produces: `RelaySpec { guestPort: UInt16; hostPort: UInt16; vsockPort: UInt32 }` × 2, made by `RelaySpec.make(gatewayPort:egressPort:)` **per exec** (the egress port comes from `EgressProxyPool` for that turn's allowlist); the host relay (in the vmhost) listens on vsock 7777/7778 for the VM and connects only to `127.0.0.1:<hostPort>` of the current exec's spec, refusing anything else by construction (there is no parsing of a target: a vsock port maps to one fixed host port, and a VM with no exec in flight has no mapping). The guest has no other network interface (`VMSpec` passes no NIC). The egress proxy's existing rules apply to CONNECT targets (public addresses only, port 443).

- [ ] **Step 1: Write the failing tests:** `VsockRelayTests.onlyTwoPortsForwarded` (Review Focus 2: the host relay's mapping is total over exactly `{7777, 7778}`; a request on vsock 7779 is refused and logged), `hostPortsSetPerExec` (two execs with different egress ports → the mapping follows the current exec; no exec → no mapping), `connectToLoopbackRefusedByProxy` (reuses S's `EgressProxyTests` fixture: `CONNECT 127.0.0.1:1 → 403`), `gatewayLaunchUsesGuestHost` (the compiled env has `ANTHROPIC_BASE_URL=http://127.0.0.1:7777/t/`, the harness `HTTPS_PROXY=http://127.0.0.1:9`, and the prefix's proxy `http://127.0.0.1:7778`, never the host ports), `noNICInVMSpec`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit tier; `.liveTier` `LiveVM/relayRoundTrip` (owner-run: a stub gateway on the host answers a `curl` from the guest through 7777; `curl https://example.com` through 7778 is refused unless `example.com` is on the company allowlist).
- [ ] **Step 5: Commit:** `feat(isolation): vsock relays for the gateway and egress proxy; the guest has no network interface`.

---

### Task 8: Worktree-only mount and the read-only history snapshot (security)

**Files:**
- Create: `Sources/BrahmaIsolation/HistorySnapshot.swift`, `Packages/BrahmaVMHost/Sources/brahma-vmhost/Mounts.swift`, `Tests/BrahmaIsolationTests/{HistorySnapshotTests,WorktreeMountTests}.swift`

**Interfaces:**
- Produces: `public enum HistorySnapshot { static func materialize(repo: Place, branch: String, into scratch: Place, git: SafeGit) throws -> Place }` — a bare repository holding only `main` and the agent's branch: `git init --bare <scratch>/history` then one `git fetch --no-tags <repo> main:main <branch>:<branch>` through S's hardened git (hooks, filters and fsmonitor disabled; no alternates, so the snapshot cannot reach the engine repo), owned by the engine and mounted read-only at `/history`; `MountSpec.worktree(place)` → `/work` rw, `MountSpec.history(place)` → `/history` ro, `MountSpec.home(place)` → `/home/agent` rw. The worktree's own `.git` file is **untouched** (it points at the engine repo's gitdir, which is not mounted, so without `GIT_DIR` guest git would simply fail); the guest reaches history through the `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` variables Task 6 sets, so `git status`, `git diff` and `git log` work and a guest `git commit` writes only into the read-only snapshot and fails. Commits stay engine-made (`worktreeCommit`; the agent's commit tool is unchanged). The snapshot lives in the turn's scratch and is removed with it (crash-safe: scratch is swept at engine start by R's recovery).
  - Read-back is **unchanged**: everything the engine reads from `/work` goes through S's `SafeFS`/`Place` and hardened git, so links, device files and oversize files are refused as today.

- [ ] **Step 1: Write the failing tests:** `HistorySnapshotTests.containsOnlyMainAndBranch`, `isBareReadOnlyNoAlternates`, `hooksAndFiltersDisabled`, `guestCommitFails` (a commit against the ro snapshot with `GIT_DIR` set fails and leaves the worktree's `.git` unchanged); `WorktreeMountTests.onlyWorktreeHistoryAndHomeMounted` (the `VMSpec` for a turn has exactly `/work` (plus its host-path alias in the split layout), `/history` and `/home/agent`; a planted extra mount fails the test), `linkEscapeRefusedOnReadBack` (Review Focus 1: a symlink `/work/evil → /etc/passwd` and a hard link into `/history` written by a fake guest → `SafeFS` refuses the open and `worktreeDiff` lists it as refused, exactly as the existing Seatbelt test does), `snapshotRemovedWithScratch`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit and process tiers.
- [ ] **Step 5: Commit:** `feat(isolation): worktree-only mount and a read-only history snapshot for in-VM git`.

---

### Task 9: Whole-turn layout for gateway turns, and company tools over the gateway relay

**Files:**
- Modify: `TurnLauncher` (layout choice from `LaunchAuth` result: `.gateway → .wholeTurn` when the backend offers it), `ClaudeRuntime.compile` (a `LaunchTarget.guest` hint: no settings-file sandbox inside the VM once the canary proves the VM layer (spec §8.8.7), `--setting-sources ""`, MCP config as streamable HTTP at `http://127.0.0.1:7777/t/mcp/` with the turn token as the bearer), X1's `GatewayRoutes` (+ `POST /t/mcp/` → `GatewayEndpoint.mcp`, admitted only with a live turn token), X1's `GatewayServer` (+ `MCPGatewayHandler`: dispatches to the same `brahma mcp` handlers with the token's `TurnGrant` as the principal, so taint marking and company scoping are unchanged)
- Create: `Sources/BrahmaGateway/MCPGatewayHandler.swift`, `Tests/BrahmaGatewayTests/MCPGatewayHandlerTests.swift`, `Tests/BrahmaEngineTests/WholeTurnLayoutTests.swift`

**Interfaces:**
- Produces: a gateway turn on `linux-vm` compiles to an `IsolatedLaunch` whose guest argv equals the Seatbelt argv except: no `--settings <sandbox file>` (replaced by the VM layer; kept until `canaryPassed(shape)` is true), `ANTHROPIC_BASE_URL` on the guest host, the MCP server reached through the gateway relay path `/t/mcp/` **(controller's call: company tools for whole-turn VM turns are served by X1's gateway listener on a per-turn token-authenticated route with the same handlers as `brahma mcp`, so no stdio child needs the database inside the VM; X2 reuses it for Codex)**. `turn.backend = "linux-vm"`, `turn.layout = "whole-turn"`.

- [ ] **Step 1: Write the failing tests:** `MCPGatewayHandlerTests.routeNeedsLiveTurnToken` (X1's `GatewayServerTests` style: `/t/mcp/` without a live token → 401; an ended turn's token → 401), `sameHandlersSameTaint` (a tool that returns EXTERNAL content marks the session tainted exactly as `brahma mcp` does), `scopedToTheTokensCompany`; `WholeTurnLayoutTests.gatewayTurnRunsWholeInVM` (`ScriptedTurnRunner` + `FakeVMHost`: the spawned executable is `brahma-vmhost`, the guest argv has no settings sandbox once the canary passed and keeps it before), `subscriptionTurnNeverWholeTurn`, `turnRowRecordsBackendAndLayout`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit and process tiers and `scripts/golden-path.sh` (Seatbelt goldens unchanged).
- [ ] **Step 5: Commit:** `feat(engine): whole-turn VM layout for gateway turns; company tools over the gateway relay`.

---

### Task 10: Split layout for subscription turns — `VM (commands)` (security)

**Files:**
- Modify: `ShellPrefix.script(layout:…)` (a new `SandboxLayout.vmCommands(vmId:tokenFile:)` renders a prefix that runs each command as `brahma-vmhost exec --vm <id> --cwd /work -- /bin/sh -c "$CMD"`; the capability token is read from a 0600 file in the turn's run dir named by the prefix, never from the harness environment; the host Seatbelt profile for the prefix gains the control socket path and that file), `TurnLauncher` (`.subscription → .commandsOnly` on VM backends; the turn's VM is taken from the spare pool at launch and discarded at turn end, as in the whole-turn layout), `IsolationLabel`
- Create: `Tests/BrahmaEngineTests/SplitLayoutTests.swift`

**Interfaces:**
- Produces: on a VM backend, a subscription turn keeps today's host harness (Claude's settings sandbox under Seatbelt) and replaces the Bash prefix: every command runs in the turn's VM with `/work` mounted at the worktree's host path too (so paths the model prints resolve on both sides). The token file lets the prefix exec only **this turn's** VM: the vmhost refuses any other `vmId`. If the VM is gone (stopped by STOP, crashed), the prefix exits 126 with `isolation: VM unavailable (<reason>)` and **never runs the command on the host**. The app shows **VM (commands)**.

- [ ] **Step 1: Write the failing tests:** `SplitLayoutTests.commandsRunInVM` (`FakeVMHost` records `exec` per Bash call), `harnessStaysOnHostUnderSeatbelt` (the harness `LaunchSpec` equals the Seatbelt golden except the prefix and the deny proxy), `otherAgentsVMRefused` (a prefix carrying turn A's token names turn B's `vmId` → `badToken`, nothing runs), `tokenNotInHarnessEnv`, `prefixRefusesWhenVMGone` (Review Focus 3: exit 126, no host process spawned, the turn ends `failed` with the reason), `labelIsVMCommands`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit and process tiers.
- [ ] **Step 5: Commit:** `feat(engine): split layout — harness on the host, every command in the agent's VM`.

---

### Task 11: `auto` selection, the labelled fallback, `measure`'s isolation row, `IsolationStep`

**Files:**
- Create: `Sources/BrahmaIsolation/{AutoSelection,FallbackNotice}.swift`, `Sources/BrahmaEngine/Tick/IsolationStep.swift`, `Tests/BrahmaIsolationTests/AutoSelectionTests.swift`, `Tests/BrahmaEngineTests/IsolationStepTests.swift`
- Modify: `TurnLauncher`, `Doctor.swift` (item `isolation`), `Store+StallReport` (`why` lines), X6a's `UsageMetrics.safety` → `isolation` row, R's `TickOrderTests` literal (`isolation` before `dispatch`, gates `[.running]`)

**Interfaces:**
- Produces:
  - `public enum AutoSelection { static func choose(setting: IsolationSetting, agentOverride: IsolationBackendId?, needsXcode: Bool, backends: [any IsolationBackend], host: HostFacts, overflow: OverflowMode) -> Choice }` with `Choice { case run(IsolationBackendId, fallbackReason: String?); case wait(reason: String) }`: an explicit setting runs only on that backend or waits (never falls back; explicit `seatbelt` runs with `fallbackReason: "chosen"` so it is labelled the same way); `auto` tries the order (`macos-vm` first when `needsXcode`, from the company's surfaces: iOS or macOS preview, check or build); when every VM backend refuses: a `.resource` refusal follows `overflow` (`fallback` → `.run(.seatbelt, reason)`, `wait` → `.wait(reason)`); a `.structural` or `.transient` refusal → `.run(.seatbelt, reason)` even under `wait` **(controller's call: waiting for a VM that can never exist, or for an image the owner has not built, would stall forever; the fallback is labelled either way)**. When the structural reason is "no image", `AutoSelection` also asks `TurnLauncher` to file the `isolationImage` human task once per backend (spec §8.8.1 "no image" → fallback, with the owner told how to end it). Admission in `prepare` may still refuse; a `.resource` refusal there follows `overflow` the same way.
  - `FallbackNotice.send(companyId:reason:now:)`: one owner notice per company per day (`fallbackNotice` table); an activity line per turn.
  - `IsolationStep: TickParticipant` — reaps idle spares, refreshes `HostFacts`, re-verifies images daily.
  - `measure` row `isolation`: VM turns ÷ turns (per backend and layout), fallback turns with reasons grouped (spec §10 row 5 (3)).
  - Doctor `isolation`: `pass` `default auto → linux-vm (image ok, 6 slots free)`; `warn` `auto falls back to seatbelt: <reason>` ; `why`: `@eng-1 waits: isolation linux-vm unavailable (RAM budget …)`.

- [ ] **Step 1: Write the failing tests:** `AutoSelectionTests.explicitNeverFallsBack` (every explicit VM backend × every refusal → `.wait`), `explicitSeatbeltIsLabelled`, `autoPrefersLinuxThenDockerThenSeatbelt`, `xcodeCompanyPrefersMacOSVM`, `waitHoldsOnResourceRefusal`, `structuralRefusalFallsBackEvenUnderWait`, `unverifiedImageIsNoVM` (Review Focus 5: `.transient` image refusal → Seatbelt with the reason), `noImageFilesTheAskOnce`, `fallbackAlwaysCarriesReason`; `IsolationStepTests.noticeOncePerDay`, `reapsIdleSpares`; X6a's `UsageMetricsTests.isolationRowCountsFallbacks`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit tier; `TickOrderTests` updated with the ruling in the commit.
- [ ] **Step 5: Commit:** `feat(engine): auto isolation with the labelled Seatbelt fallback; doctor, why and measure lines`.

---

### Task 12: Emergency stop and orphan recovery (security)

**Files:**
- Create: `Sources/BrahmaEngine/Tick/VMRecoveryStep.swift` (R's recovery order), `Tests/BrahmaEngineTests/EmergencyStopVMTests.swift`
- Modify: `EngineService` (registers every backend as an `EmergencyStopObserver`), `EmergencyStop.engineGroups(store:paths:)` (+ the vmhost's process group from `vmInstance.hostPid`, so `signalEngineGroups` and `brahma stop` reach it)

**Interfaces:**
- Produces: `stopAll` on each backend sends `stop` to every VM it started (grace `stopGrace`), then `SIGKILL`s the vmhost's process group **and every process whose parent is the vmhost** (Apple's `com.apple.Virtualization.VirtualMachine` XPC helpers, found through `ProcessTable`; Task 0 (f) confirms whether killing the vmhost already ends them) and marks `vmInstance.state = stopping` → removed; a stopped VM is recorded like a killed process group (`turn` ends `interrupted`). At engine start, `VMRecoveryStep` lists `vmInstance` rows, asks the vmhost `list`, stops every VM whose turn has no live process or whose row survived a crash, kills any VM XPC helper left without a vmhost, and removes the rows before any launch. `brahma stop` with a wedged engine: the DB-first path works because `EmergencyStop.engineGroups` now includes the vmhost group.

- [ ] **Step 1: Write the failing tests:** `EmergencyStopVMTests.stopKillsEveryVM`, `hungGuestIsKilled` (Review Focus 4: `FakeVMHost` ignores `stop` → the vmhost group and its children are killed after `stopGrace`), `orphansStoppedAtStart`, `orphanXPCHelperKilled`, `stopWorksWithEngineWedged` (`brahma stop` path finds the vmhost group from the table).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit and process tiers; P's `stopKillsProcessGroup` still green.
- [ ] **Step 5: Commit:** `feat(engine): STOP stops every VM; orphan VMs are stopped at start`.

---

### Task 13: Canary backend layer — probes per (runtime, backend, layout) (security)

**Files:**
- Modify: `SandboxCanary` (a third `CanaryProbeResult.Layer.backend`; the key gains `TurnShape.backend/layout`), `CanaryProbes` (built-in backend probes), `CanaryStep` (runs per shape the engine will use)
- Create: `Tests/BrahmaEngineTests/BackendCanaryTests.swift`, `Tests/BrahmaEngineTests/LiveCanaryBackendTests.swift` (`.liveTier`)

**Interfaces:**
- Produces: `IsolationBackend.canaryProbes(layout:)` for the VM backends returns the spec §8.8.6 list as named probes, run **inside** the guest (`exec`) for `wholeTurn` and through the prefix for `commandsOnly`; each must be denied or absent: `vm-owner-files` (`cat ~/.ssh/id_*` and the host home path, `/Users`, `~/.aws`, Keychains, browser profiles, the data home), `vm-other-agents` (another agent's worktree **and lab** paths), `vm-credentials` (`env | grep -i -E 'key|token|secret'` shows only the turn token name; no `~/.claude` **or `~/.codex`** login files; no `SSH_AUTH_SOCK`; no `BRAHMA_VM_TOKEN`), `vm-network` (Review Focus 2: `curl` to a public IP, the host LAN address, `127.0.0.1:<gateway host port>`, `127.0.0.1:<service socket>`, `169.254.169.254`, `/var/run/docker.sock` and vsock port 7779 all fail, while `127.0.0.1:7777` answers 401 without a token), `vm-token-death` (after the turn, the saved token gets 401; run by the engine). The same list runs on Seatbelt for the comparison the app shows (results stored per shape; `brahma canary run` prints a backend column). A shape whose backend layer failed is unavailable.

- [ ] **Step 1: Write the failing tests:** `BackendCanaryTests.keyIncludesBackendAndLayout`, `failedBackendLayerBlocksShape`, `seatbeltRunsSameList`, `probeListMatchesSpec` (the five names above and their contents, pinned, including labs and the Codex login); live: `LiveCanary/escapeSuite` gains the `linux-vm` legs (both layouts) and `LiveCanaryBackendTests.tokenDeadAfterTurn`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit tier; owner-run `BRAHMA_LIVE=1 … --filter LiveCanary` once, output in the task report.
- [ ] **Step 5: Commit:** `feat(safety): canary backend layer per (runtime, backend, layout); Seatbelt comparison`.

---

### Task 14: CLI and app — `company isolation`, `agent isolation`, ISOLATION panel, badges

**Files:**
- Create: `Sources/brahma/IsolationCommands.swift`, `Sources/BrahmaAppModel/Isolation/IsolationModel.swift`, `Sources/BrahmaApp/Views/{IsolationPanel,IsolationBadge}.swift`, `Tests/BrahmaCLITests/IsolationCommandTests.swift`, `Tests/BrahmaAppModelTests/IsolationModelTests.swift`
- Modify: `CompanySettingsView` (ISOLATION panel), the People inspector (ISOLATION row with the picker and the badge), the agent row, the company rail and Inbox cards (badge), P's inventory fixtures (additions only)

**Interfaces:**
- Produces: `brahma company isolation <co> [auto|linux-vm|macos-vm|docker|seatbelt]`, `brahma agent isolation <co> <handle> [<backend>|inherit]` (each prints the effective backend and why with no value); `@MainActor @Observable final class IsolationModel { var setting: IsolationSetting; var effective: [agentId: (backend, layout, label, reason?)]; var images: [ImageRecord]; var hostSummary: String; func set(_:) async; func setAgent(_:agentId:) async }`; `IsolationBadge` renders `IsolationLabel.for(backend:layout:reason:)`: `WEAKER ISOLATION` for every Seatbelt turn (fallback or chosen; P's warning tokens), `VM` for a whole-turn VM, `VM (commands)` for the split layout, with the reason as a tooltip and in the Inbox card body.

- [ ] **Step 1: Write the failing tests:** `IsolationCommandTests.setsCompanyAndAgent`, `showsEffectiveWithReason`, `refusedInsideAgentTurn`; `IsolationModelTests.badgeTextPerBackendAndLayout` (seatbelt + commandsOnly → `WEAKER ISOLATION`, never `VM (commands)`), `weakerIsolationCarriesReason`, `writesUseCLIValidation`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement with P's components; append `cli-tree.tsv` rows. **Step 4:** `scripts/make-app.sh debug`, `scripts/ui-inventory.sh` diff (only the new panel, row and badge), baseline commit tagged `approved Plan X spec §12`; snapshots of Company › Settings, People and the Inbox read; `ThemeLintTests`, `ScreenInventoryTests`, the unit tier green.
- [ ] **Step 5: Commit:** `feat(cli,app): isolation settings and badges`.

---

### Task 15: `MacOSVMBackend` — image from IPSW, Xcode from `.xip`, APFS clones, the 2-VM limit, canary layer (security)

**Files:**
- Create: `Sources/BrahmaIsolation/MacOSVMBackend.swift`, `Packages/BrahmaVMHost/Sources/brahma-vmhost/MacOSVM.swift`, `scripts/isolation/build-macos-image.sh`, `Tests/BrahmaIsolationTests/MacOSVMBackendTests.swift`

**Interfaces:**
- Produces: `MacOSVMBackend: IsolationBackend` — `id == .macOSVM`; `availability` needs Apple silicon, the macOS image verified, a free licence slot (`Admission.macOSLicenceSlots = 2`) and RAM; `layouts` as Linux; `prepare` clones the image (`clonefile(2)` APFS clone) per turn into scratch, boots through the vmhost (`VZVirtualMachineConfiguration`, virtiofs share of `/work` and `/history`, vsock relays, **no network device**), runs the turn as the guest's `agent` user over the vsock exec channel; `release` deletes the clone. Image build (`brahma isolation images build macos-vm`, owner): restore image from Apple (`VZMacOSRestoreImage.latestSupported`, sha256 recorded), an unattended setup that creates `agent`, installs the guest relay, then Xcode from an owner-downloaded `.xip` copied in by path (`xip --expand`, `xcode-select`, first-launch `xcodebuild -runFirstLaunch`); **no Apple ID is ever entered in the VM**; the human task shows disk (30–60 GB) and RAM. Canary: Task 13's list plus a Keychain probe (`security find-generic-password` returns nothing) and `xcodebuild -version` succeeds.

- [ ] **Step 1: Write the failing tests:** `MacOSVMBackendTests.thirdConcurrentVMWaits`, `cloneDeletedOnRelease`, `noNetworkDevice`, `xcodeCompanyRoutesHere` (with Task 11), `buildIsOwnerOnlyAndShowsSizes`; live (owner): `LiveVM/macosBootAndXcode`, `LiveCanary/escapeSuite` on `macos-vm`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit tier; the owner runs the live legs once and an iOS item of a `macos-vm` company builds (its preview runs on the host, unchanged).
- [ ] **Step 5: Commit:** `feat(isolation): macOS VM backend with APFS clones, the 2-VM limit and Xcode from an owner .xip`.

---

### Task 16: `DockerBackend` — optional, detected, never required (security)

**Files:**
- Create: `Sources/BrahmaIsolation/{DockerBackend,DockerRelay}.swift`, `Tests/BrahmaIsolationTests/{DockerBackendTests,DockerRelayTests}.swift`

**Interfaces:**
- Produces: `DockerBackend: IsolationBackend` — `id == .docker`; **no vmhost involved**, so it is available on macOS 14+; `availability` needs `HostFacts.dockerAnswering` (`.transient` otherwise) and the Linux image loaded by digest (`docker image inspect <digest>`); `prepare` admits, then runs `docker run --rm --network none --user <ImageRecord.uid> --read-only --tmpfs /tmp -v <worktree>:/work -v <snapshot>:/history:ro -v <home volume dir>:/home/agent -v <relay socket dir>:/run/brahma:ro --cap-drop ALL --security-opt no-new-privileges <digest> …argv` through `Spawn` (one container per turn, discarded after); `DockerRelay` is an engine-side relay built on R's `LocalSocket`: two Unix sockets in the turn's scratch (`gateway.sock`, `egress.sock`) each forwarding to one fixed loopback port for this turn; the guest relay connects to `/run/brahma/*.sock` and listens on `127.0.0.1:7777/7778`; the Docker socket is never mounted; `stopAll` = `docker kill` the recorded container ids. With no Docker installed: `brahma doctor` shows `docker: not installed (optional)` and nothing else changes.

- [ ] **Step 1: Write the failing tests:** `DockerBackendTests.notInstalledIsOptional` (every other test and the golden path pass with `FakeDockerProbe(false)`), `availableWithoutVMHost` (macOS 14 facts, vmhost absent → available), `runArgsPinned` (exact argv: `--network none`, no `docker.sock` mount, digest not tag, the image's uid), `oneContainerPerTurn`, `killOnStopAll`; `DockerRelayTests.eachSocketForwardsToOneFixedPort`, `socketsLiveInTurnScratch`; live (owner, if installed): `LiveCanary/escapeSuite` on `docker`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit tier.
- [ ] **Step 5: Commit:** `feat(isolation): optional Docker backend (--network none, relay socket, digest-pinned)`.

---

### Task 17: Memory soak with many concurrent VMs

**Files:**
- Create: `Sources/BrahmaIsolation/VMMemoryBench.swift`, `Sources/brahma/IsolationBenchCommand.swift`, `scripts/soak/vm-memory.sh`, `Tests/BrahmaIsolationTests/VMMemoryBenchTests.swift`
- Modify: X6a's `scripts/soak/run-72h.sh` (asserts the company's isolation is `auto` and prints the `isolation` row at the end), `MeasureReport` (per-VM RSS p50/p95 in the isolation row when a bench file exists)

**Interfaces:**
- Produces: `brahma isolation bench --vms <n> [--minutes 10] [--backend linux-vm] --out <file>` (owner): starts `n` spare VMs through the real backend, samples every 10 s the footprint (`proc_pid_rusage` `ri_phys_footprint`) of the vmhost **and of every process whose parent is the vmhost** (the `com.apple.Virtualization.VirtualMachine` XPC helpers that hold the guest memory; Task 0 (f)), `vm_stat` free pages and swap usage, then stops them and writes `vm-memory.json { backend, n, samples, rssPerVM: {p50, p95}, hostFreeMin, swapDelta, passed }`; `VMMemoryBench.evaluate(samples:reserve:) -> Verdict` passes when host free RAM ≥ 8 GiB at every sample and swap growth ≤ 256 MiB. `scripts/soak/vm-memory.sh` runs n = 2, 4, 8 in turn (never by tests) and updates `isolationImage.ramBytes` to the measured p95 when the owner confirms (`--apply`). `LiveSoak/72h` runs on default isolation, so the mission report shows the VM share and every fallback with its reason (spec §10 row 5 (3)).

- [ ] **Step 1: Write the failing tests:** `VMMemoryBenchTests.verdictFromSamples` (fixtures: pass, swap growth fail, reserve breach fail), `percentilesAreExact`, `applyUpdatesRamBytesOnlyWithFlag`; `.processTier` `benchWithFakeHostWritesFile`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement; append the `cli-tree.tsv` row. **Step 4:** PASS with the unit and process tiers; owner-run `scripts/soak/vm-memory.sh` once, results in the task report and in `docs/runtimes/isolation.md`.
- [ ] **Step 5: Commit:** `feat(isolation): VM memory soak (2/4/8 concurrent VMs); measured RAM per VM feeds admission`.

---

### Task 18: Red team, docs and final review

**Files:**
- Create: `docs/runtimes/isolation.md` (owner doc: backends, `auto`, labels, images, resource rules, what each refusal means, the probe results), `.superpowers/sdd/planX4/redteam.md`
- Modify: `README.md` ("Isolation": one section), this plan's §10 table with final task ids

- [ ] **Step 1: Red team (Opus, high).** Try and record, with the techniques the research names: **GitSpawn-class** — write symlinks, hard links, a `.git` directory, a `.gitattributes` filter and `.gitmodules` in `/work` from the guest and make the engine commit, diff or export them; **Pillar-class** — a tool result in the guest that instructs the model to read `/home/agent` session files of an earlier (tainted) turn or to call the MCP route with another turn's token; **prompt injection** through a fetched page inside the VM that tries to reach the host (the relay must be the only route); make the guest relay reach the service socket, the database or a preview port; reuse a turn token from a finished turn; exec another agent's VM with a stolen `vmId` (no token → refused); exhaust RAM by many fast turns on `auto` under `fallback`; swap an image file after verification (the vmhost hashes the descriptor it opened); flood the vmhost with oversize protocol lines; run `docker` with a crafted worktree path containing `:`; in the split layout, inject a prefix-escaping command. Every finding is fixed here with a test, or ruled on by the controller.
- [ ] **Step 2: Full verification.** `swift build` (all targets, release too), `swift build --package-path Packages/BrahmaVMHost -c release`, `scripts/test.sh all`, `scripts/golden-path.sh`, `scripts/make-app.sh debug && scripts/smoke-app.sh`, owner-shell `brahma doctor` and `brahma canary run` against a throwaway home with a real `claude` on `linux-vm`.
- [ ] **Step 3: Final review (Opus)** of the branch against spec §5, §8.8, §9.5, decision 21 and this Review Focus.
- [ ] **Step 4: Commit:** `docs: isolation backends; X4 red-team record`.

---

## §10 rows delivered by this plan (spec §10 requires this table; final ids)

**This plan's "beats" line (row 6, Codex app's default sandbox):** *By default every agent command runs in a fresh local VM, and gateway turns run whole inside it — a VM that holds nothing worth stealing (no keys, no logins, only a per-turn gateway token that dies with the turn) with the engine's proxy as the only egress — proven per (runtime, backend, layout) by the canary; Seatbelt remains, labelled weaker.* **Acceptance:** `LiveCanary/escapeSuite` reports DENIED for every probe of §8.8.6 on `linux-vm` (both layouts), `macos-vm`, `docker` (where installed) and `seatbelt`, including `vm-token-death`; an explicitly chosen VM backend never falls back (`AutoSelectionTests.explicitNeverFallsBack`).

| Row | Criterion | Task |
|---|---|---|
| 6 (1) | `LiveCanary/escapeSuite` DENIED on every backend and layout, backend layer included | T13, T15, T16 |
| 4, 5 (text) | a local VM holding only a per-turn token; owner-controlled egress through the relayed proxy | T6, T7, T8, T9 |
| 5 (3) | `LiveSoak/72h` on default isolation; `measure` shows the VM share and every fallback with its reason; memory with many concurrent VMs measured | T11, T17 |
| 12 (3) | a gateway turn in the VM passes X1's key-leak scan | T9 (`GatewayKeyLeakTests` run with `FakeVMHost` recording the guest env) |
| Gap row "Weaker isolation" | VMs by default, Seatbelt labelled | T11, T14 |

## Self-review notes

- **Spec coverage.** §8.8.1 backends and selection: T1, T3, T11, T14; `auto` and the labelled, never-silent fallback: T11; admission and `isolation-overflow`: T3. §8.8.2 whole turn in the VM, no credentials, relays as the only route, worktree-only mount, engine-side guards, STOP stops the VM, Seatbelt around the host process: T5–T9, T12. §8.8.3 split layout: T10. §8.8.4 interface and per-shape canary: T1, T13. §8.8.5 images: T4, T15, T16. §8.8.6 canary layer: T13. §8.8.7 probes: T0. §9.5 and §9.6 red team: T18. §12 CLI rows: T3, T4, T14, T17 (`isolation bench` is an addition for the soak, owner-only). Decision 21 sequencing (keys out of the VM first): the plan starts after X1.
- **Controller's calls made here:** the separate `brahma-vmhost` package (platform floor), so `macos-vm` also needs macOS 26 in v1 (**flagged for the owner**; Docker is engine-driven and works on macOS 14+); one VM per turn from a pre-booted spare (a Containerization rootfs cannot be discarded without a restart, and a reused VM would carry a tainted turn's state); the per-agent home volume for runtime session state (an engine-created block image, not a shared host path); the deny-all proxy as a closed guest port; per-exec relay host ports; the control socket with per-VM capability tokens; company tools for whole-turn VM turns over the gateway's `/t/mcp/` route; structural and transient refusals fall back even under `wait`, and "no image" files the owner ask; Seatbelt is always labelled WEAKER ISOLATION (spec §8.8.1 "labelled the same way"); `release` and `canaryProbes(layout:)` on the interface; the `isolation bench` command.
- **Type consistency:** `IsolatedLaunch.spec` (T1) is what `RuntimeProcessRunner` spawns (T2) and what the VM backends fill with `brahma-vmhost exec` (T6, T15) or `docker run` (T16); `RelaySpec` (T7) is passed per `exec` (T5); `BackendRefusal.kind` (T1) is produced by `availability` (T6, T15, T16), `ImageRegistry` (T4) and `Admission` (T3) and read by `AutoSelection` (T11); `HostFacts` (T1) is gathered in T3 from `ImageRegistry` (T4) and `VMHostVerifying` (T5); `ImageRecord` (T1) is stored by T3, built by T4/T15 and its `ramBytes` refined by T17; `VMInstance.token` (T3) is minted by `start` (T5) and used by `exec`/`stop` (T6, T10, T12); `turn.backend/layout/fallbackReason` (T3) are written by `TurnLauncher` (T9–T11) and read by `measure` (T11) and the badges (T14).
- **Effort:** 19 tasks (T0–T18). L: T5, T6, T7, T8, T9, T13, T15. M: T3, T4, T10, T11, T12, T16, T17, T18. S: T0, T1, T2, T14. T5 and T13 are the largest and may each be split by the implementer into protocol/profile and probes/key halves without changing any interface. Nine Opus reviews. About 18–22 implementer-days subagent-driven.
