# Plan S — Engine safety: design spec

**Status:** approved to add (owner, 2026-11-21). Build order: after Plans 4a (workspace previews) and C (Collab-MVP) are merged to `main`, before the first real dogfood run.
**Motivating analysis:** `docs/superpowers/specs/2026-11-21-design-analysis-input.md` (cited below as "the analysis"). Plan S implements its recommendations 2–6 (the 6 part is limited to default-deny types and the required alert scope), with recommendation 8's property tests attached to the unified path layer.
**Implementation plan:** `docs/superpowers/plans/2026-11-21-planS-engine-safety.md`.
**Convention:** every decision made in this spec, not taken from the analysis or the owner, is marked **(architect's call)**. A builder may not reopen one of these without a controller ruling.

---

## Owner questions

None of these blocks the build. Each has a recommended default, and the plan is written for the default. An owner answer that differs changes the task named.

1. **Should 3a's submit and auto-commit staging (`GitWorkspace.commitAll` / `stage`) move into the helper as well?** That is the descriptor-fed walker that commits an agent's worktree at submit and at worktree removal.
   - *Default: no, not in Plan S.*
   - It writes engine-owned git objects from descriptors it has checked. It does not interpret agent bytes beyond copying them.
   - It is 3a's most-tested path, and moving it means importing a pack from the helper on every submit.
   - It is listed as follow-up F1 (§12). Choosing "yes" adds one task after S10, of about the same size as S10.
2. **How much of the MCP tool output boundary should be typed in Plan S?**
   - *Default: type the boundary (`ToolOutput`) and migrate the 12 tools that relay another principal's text (§6.6.5).* The other tools stay on a frozen legacy shim that no new tool may use.
   - Choosing "all tools" roughly doubles Task S14.
3. **Should deployed-site smoke checks move into the helper?** These are `DeploySmoke`, the release HTTP checks against hosting URLs.
   - *Default: no.* Their targets come from the owner-configured hosting provider. Moving them needs TLS through the egress proxy inside the helper. This is listed as follow-up F2.
   - Choosing "yes" adds an `httpsProbe` operation to Task S9.
4. **Is it acceptable that helper-backed features say "unavailable" on platforms without Seatbelt (Linux CI)?**
   - *Default: yes.* Today C's live diffs run in the engine's own process on any platform. After Plan S they need the helper, and with no sandbox they fail closed, consistent with `UnavailableSandboxRunner`.

---

## 1. Intent and why

Brahma's engine is unsandboxed. It supervises sandboxed agents and acts on what they produce: files, worktrees, ports and text. The analysis finds that security findings keep recurring for structural reasons, not one-off ones (§1 item 2–3, §7.1). There are four such reasons.

1. **The engine interprets agent-controlled bytes in its own process.**
   - Symlink, TOCTOU, unbounded-read, PATH and SSRF findings follow from this:
     - C1a's five re-review rounds;
     - 4a task-4 I1, a planted link that widened a GUI app's write grant;
     - 4a task-5 I1, smoke requests sent to any loopback port.
   - Hardened file I/O is spread over 33–35 files in three overlapping layers: `EngineFiles`, C's `SafeFS` and `SandboxPath`.
2. **The principal is re-derived for each feature.**
   - The "who is this for" decision is hand-written in at least three places:
     - `SandboxedCheckRunner.checkRoute`: on `main` at `:107-111`; in 4a it is a 40-line merge-run branch plus the surviving VerificationRun branch at `:169-171`;
     - `PreviewRunner.unsandboxed` (`main` `:453-457`, 4a `:587-591`);
     - the release smoke route.
   - Two of these fail open: `try?`, then `?? true`, then `.unsandboxed`.
   - `SandboxPolicy(…)` is hand-built at 16 sites in 11 files (§7).
3. **Untrusted text is relayed by string interpolation.**
   - The digest frames agent text with ad hoc `flat`/`quote` helpers and per-field `tainted: Bool` flags: 45 tainted-flag declarations and 15 `relayedTaint` sites (C tree).
   - Each fix is made per field, as in 4a task-6 I1 (artifact titles).
4. **Fail-open defaults can be written.**
   - Examples: `?? true` on a principal lookup, and `companyId: nil` meaning "broadcast to every company" (`EngineAlerts.swift:13-14,25`).
   - There are 700 `try?` in the C tree's `BrahmaCore`, 45 of them in Sandbox and Safety.

The analysis's prescription (§8 #2–#6) is to make the invariants executable:
- a sandboxed helper for engine actions on agent data;
- one principal model with one policy factory;
- typed trusted/untrusted prompt text;
- one safety module with a lint;
- default-deny API shapes.

Plan S builds exactly that, on the shapes 4a and C actually shipped. It keeps everything the analysis's §10 says to keep.

## 2. Goals

- **G1 — Helper.** Every engine operation on agent-controlled data runs in a short-lived `brahma-helper` process under `sandbox-exec`. "Agent-controlled data" means enumerating an agent-writable tree, running a tool over agent files, network requests to agent-run services, or parsing complex agent-authored formats (§6.4.1 gives the exact rule).
  - The helper's Seatbelt policy is derived from the action's subject principal: the helper can read no more than that principal could.
  - The operations are:
    - live and `wt:` worktree diffs and worktree status (replacing C's in-process `WorktreeListing` and `SafeGit.worktreeDiff` phases 1–3, and 3a's `isDirty` on item worktrees);
    - preview smoke, readiness and demo HTTP requests (4a and L);
    - artifact and OpenAPI staging copies with sniffing (4a);
    - archive text extraction (C2a).
- **G2 — One principal model.** A `Principal`/`PrincipalSet` is resolved once per action, from engine records only. The rules:
  - least-privileged contributor wins;
  - any lookup failure becomes `.unknown`;
  - `.unknown` never yields an unsandboxed run, extra network or extra places.
- **G3 — One policy factory.** `SandboxPolicyFactory.decide(...)` is the only way to obtain a runnable Seatbelt policy.
  - It switches exhaustively over a `Purpose` and returns `PolicyDecision { sandboxed(ValidatedPolicy) | fullOptOut | refused }`.
  - `SandboxPolicy`'s initializer is internal to the safety module.
  - The profile renderer consumes only a `ValidatedPolicy`, which closes the validate-then-re-resolve race (analysis §7.1, `SeatbeltRunner.swift:59-60`).
- **G4 — Typed prompt text.**
  - Turn prompts (system and user) are `RenderedPrompt` values. They can only be produced by `PromptBuilder` from `Trusted` (engine literals and validated tokens) and `Untrusted` (agent or external text, with provenance and taint) parts.
  - Framing, capping, flattening and taint handling happen in the renderer and cannot be skipped.
  - The MCP tool result boundary is typed the same way (`ToolOutput`).
- **G5 — One safety module plus a lint.**
  - A new SwiftPM target `BrahmaSafety` owns:
    - the path layer (`EngineFiles`, `SafeFS`, `SandboxPath`, `SafeRead`);
    - process spawning (`Spawn`, `ToolPaths`);
    - sandbox runtime and rendering;
    - the policy factory and the principal value types;
    - prompt text types and the helper protocol, server and client.
  - `SafetyLintTests` bans raw file, process, sandbox-policy and network APIs outside it. It starts from a baseline that may only shrink, and Plan S drives the agent-facing directories to zero.
- **G6 — Default-deny shapes.**
  - A `Decision` type has a mandatory deny path and no `Bool`/`Optional` coercion.
  - `EngineAlerts.raise` takes a required `AlertScope` (`.company(id)` or `.allCompanies(GlobalAlert)`).
  - `try?`, `?? true` and `?? false` are banned in `BrahmaSafety` and in the principal resolver.
- **G7 — Close the known fail-opens on `main`.**
  - The unknown-principal → unsandboxed branches of `checkRoute` (VerificationRun) and `PreviewRunner.unsandboxed`. The latter also ignores the engine ceiling.
  - The `GitWorkspace.regularText` check-then-read: `lstat`, then an unbounded `String(contentsOf:)` that follows links (`main` `:879-882`, used at `:862, :889-897, :906`).
- **G8 — Prove it.**
  - Property and fuzz tests on the path and policy layer.
  - Parity tests for every migrated operation.
  - Measured performance budgets for the helper.
  - A re-run of the full sandbox canary (model-free plus live), extended with helper probes.

## 3. Non-goals

- **A second Unix user for agents** (analysis #11), **an Endpoint Security extension**, or **moving off `sandbox-exec`** (analysis §7: options not recommended). The Seatbelt base stays `(allow default)` plus the existing deny lists (analysis §7.5). Plan S does not change the agent sandbox's rules.
- **Agent turn sandboxing** (`SandboxScope.forTurn`, `ClaudeSettingsCompiler`). Turns are already derived from their agent. Plan S only pins `forTurn`'s call sites with the lint (**architect's call**: unifying Claude Code settings with Seatbelt policies is a separate, larger design).
- **The engine as a launchd agent** (#10), **Orchestrator decomposition** (#9), **a `Store` `CompanyScope` handle** (#6's Store half; only the alert scope is in Plan S) and **a general BrahmaCore module split** (#12; only `BrahmaSafety` is extracted).
- **3a's `commitAll`/`stage`** (Owner question 1, default no) and **deployed-site smoke** (Owner question 3, default no).
- **App-side reading** (`BrahmaAppModel`) of engine-confined artifact copies. The app reads only engine-owned copies, so the lint scope is `Sources/BrahmaCore` and `Sources/brahma` (**architect's call**).
- **Persistent or warm helper processes.** Measured one-shot latency is well within budget (§9). A warm pool is follow-up F3, and only if the S8 benchmark fails its budget.
- **New owner-facing UI.** Plan S adds activity lines, `brahma doctor` items and one Insights note text. It adds no new view, sidebar item or CLI verb, which respects the concept budget.

## 4. Anti-goals (what Plan S must not do)

- **No regression of fail-closed behaviour.** Every existing refusal stays a refusal. Plan S adds new ones only in the fail-closed direction. This covers:
  - holds;
  - the emergency stop;
  - secrets-not-loaded;
  - `SandboxBaseline.problem`;
  - `UnavailableSandboxRunner`;
  - `SandboxPolicyCheck`;
  - `UnsafeEngineFile`;
  - `SafeFSError`;
  - the merge-run principal rulings S3, S3b, S4 and M2;
  - the tool taint allowlist.

  Every test that pins one of these keeps passing unchanged. A test edit that weakens an assertion needs a controller ruling naming the replacement test.
- **No silent behaviour change for owners.** Every change an owner could notice is listed in §8 with how it is surfaced (activity line, doctor item, Insights note or release note).
  - The digests stay byte-identical except for the listed intended deltas. Golden snapshots are captured before the migration (S13).
  - Diff output stays equivalent except for the listed git-semantics deltas, which are parity-tested (S10).
- **No in-process fallback.** When the helper is unavailable (no `sandbox-exec`, a missing or untrusted binary, a protocol mismatch, a spawn failure), the operation refuses with a typed `HelperError.unavailable(reason)`. The feature says "unavailable". It never quietly runs the old in-engine code. The old code is deleted in the same task that migrates its callers.
- **No unmeasured performance claims.** The budgets in §9 are asserted by a benchmark test (S8, re-run in S10–S12). A budget miss is a task failure. It is not waived silently: the controller rules on it, and the fallback is fixed in §9.
- **No new agent capability.** No helper operation may give its subject principal, or any reader, access to bytes the principal could not already read. Pinned by the property test "policy places ⊆ principal reach" (S7) and the helper canary probes (S16).
- **No widening of `Full`.** Only the company owner's explicit Full opt-out may yield an unsandboxed run. It applies only to purposes that run agent-written commands, and only when every principal in the set narrows to Full under the engine ceiling. Helper operations are always sandboxed, Full company or not (**architect's call**: they are engine reads, so sandboxing them costs a Full company nothing).

## 5. What exists (built on, not duplicated)

Names follow the shipped 4a/C code as of 4a `ce18541` and C `91e84e9` plus C2a's uncommitted files (`OpenRef`, `Vault`, `RefTaint`, `TextExtract`). **Task S1 re-greps on merged `main` and records every rename.** Later tasks use the shipped names.

| Shape | Where (4a/C) | Plan S does |
|---|---|---|
| `SandboxPolicy`, `SandboxNetwork`, `SandboxBaseline`, `SandboxPolicyCheck`, `SandboxedRunner`, `SeatbeltRunner`, `SeatbeltProfile`, `UnavailableSandboxRunner`, `StragglerReport`, `SandboxSweep` (marker sweep) | `Sandbox/`, `Turns/TurnProcess.swift` | Moves them to `BrahmaSafety` (S3). Makes the `SandboxPolicy` init internal and adds `ValidatedPolicy` (S7). Adds `SandboxNetwork.loopbackConnect(port:)` (S9). |
| `checkRoute` with the merge-run principal set (rulings S3/S3b/S4/M2) | 4a `SandboxedCheckRunner.swift:126-167` | Re-expressed as `PrincipalResolver.resolve(.mergeRun)` with identical semantics (S6). |
| `PreviewRunner.unsandboxed(store:company:setById:)` | 4a `PreviewRunner.swift:587` | Replaced by the resolver and the factory (S2 fix, S6, S7). |
| `PreviewPolicy.server/oneShot/appleBuild/guiApp`, `prepareAppData` | 4a `PreviewModel.swift:325`, `PreviewKinds.swift:77-95` | Become `Purpose` cases in the factory (S7). |
| `EngineFiles` (`OpenDirectory`, `readNoFollow`, `removeNoFollow`, `clear`, …), `UnsafeEngineFile` | `Util/EngineFiles.swift` | Moved (S3) and consolidated (S15). |
| `SafeFS`, `SafeFile`, `SafeFSError`, `SafeFSPlace` | C `Refs/SafeFS.swift` | Moved (S3). Its test hooks are put behind `#if DEBUG` (analysis §9). |
| `SafeGit` (committed-object reads, share refs, `verifyRev`, `worktreeDiff`) | C `Refs/SafeGit.swift` | Committed-object reads stay in the engine, as the analysis says to keep (§10). `worktreeDiff` phases 1–3 and `WorktreeListing` are replaced by the helper (S10). |
| `BackendAdapter.smoke/probe/origin/copyOpenAPI`, `WebAdapter` readiness and demo GET, `HTTPProbing` | 4a `Preview/` | Loopback requests move to the helper (S9). The OpenAPI copy moves to `stageCopy` (S11). |
| `Store.publishArtifact` (descriptor walk, sniff, ratio, glTF siblings) | 4a `Store+Artifacts.swift` | The file and folder walk, sniff and copy move to `stageCopy`. The engine keeps quota, numbering, rows, memory and activity (S11). |
| `TextExtract`, `SandboxedUnzipReader`, `ArchiveReader` | C `Refs/TextExtract.swift` (C2a) | Unzip plus tag-strip move to the helper's `extractText` (S12). |
| `TurnDigest`, `InboxDigest`, `WorkNoticeDigest`, `RolePrompt`, `OperatingRules`, `ReviewDigest`, `AuditDigest`, `UltraDigest`, `UntrustedBlock`, `TaintPolicy.relayedPrefix` | `Turns/`, `Work/Review.swift`, `Safety/Taint.swift` | Rebuilt on `PromptBuilder` (S13). |
| `RefAccess`/`Reader` (who may read a result) | C `Refs/RefAccess.swift`, ML `Memory/Access.swift` | Unchanged. The reader (requester) is distinct from the subject principal (§6.2.1). |
| `EngineAlerts.raise(… companyId: String? = nil)` | `Engine/EngineAlerts.swift` | Requires `AlertScope` (S4). |
| `GitCommand` hardened flags/env; `/usr/bin/env git` | `Git/GitWorkspace.swift:186, 201, 396, 430` | Flags move to `BrahmaSafety.GitHardening`. Spawning moves to `Spawn` with absolute `ToolPaths` (S5). |
| Sandbox canary (`brahma canary run`, `SandboxCanary`, `CanaryProbes`) | `Safety/` | Gains helper probes, then re-run (S16). |

## 6. Architecture

### 6.1 Overview

```
            BrahmaCore (engine, unsandboxed)                         BrahmaSafety (kernel; no Store, no GRDB)
 ┌─────────────────────────────────────────────┐        ┌───────────────────────────────────────────────────┐
 │ Orchestrator / Store / MCP / Preview / Refs  │        │ Path layer: EngineFiles, SafeFS, SafeRead,        │
 │                                              │ uses   │   SandboxPath (fd-anchored, size-bounded)         │
 │ PrincipalResolver ──► PrincipalSet ──────────┼───────►│ Principal, PrincipalSet, Reach (values)           │
 │   (engine records only; errors → .unknown)   │        │ SandboxPolicyFactory.decide(purpose, principals,  │
 │                                              │        │   places, network) → PolicyDecision               │
 │ callers build typed Places from records      │        │ ValidatedPolicy → SeatbeltProfile.render          │
 │                                              │        │ SeatbeltRunner / Spawn / ToolPaths / GroupRun     │
 │ HelperClient.call(op, subject) ──────────────┼───────►│ HelperClient (call dir, rlimits, caps, sweep,     │
 │                                              │        │   quiescence, strict decode)                      │
 │ PromptBuilder → RenderedPrompt → TurnRequest │        │ Trusted / Untrusted / PromptBuilder / ToolOutput  │
 └─────────────────────────────────────────────┘        └───────────────────────────────────────────────────┘
                                                                        │ sandbox-exec -p <ValidatedPolicy profile>
                                                                        ▼
                                                        ┌───────────────────────────────────────────────────┐
                                                        │ brahma-helper <op>  (depends on BrahmaSafety only) │
                                                        │ stdin: HelperRequest JSON ≤ 64 KiB                 │
                                                        │ stdout: HelperResponse JSON ≤ 256 KiB              │
                                                        │ bulk output: files under <call>/out only           │
                                                        └───────────────────────────────────────────────────┘
```

### 6.2 Principal model

#### 6.2.1 Subject versus requester

Every action has two parties, and Plan S keeps them apart (**architect's call**):
- **The requester** asks for the result: the owner in the app, a reviewer agent calling `open_ref`, the concierge. *Whether the requester may see the result* is access control. It stays with C's `RefAccess`, ML's `Reader`, `MemoryAccess` and the cross-company rule, and Plan S does not change it.
- **The subject principals** are the parties whose bytes are interpreted or whose code runs: the lease holder of a worktree, the authors of a merge candidate, the setter of a preview command, the publisher of an artifact. *What the sandbox allows* is derived only from the subject principals.

This is the confused-deputy fix. The owner's request to view an agent's live diff never runs with owner reach. It runs with the holder's reach, so a link the holder planted can only resolve to what the holder could already read.

#### 6.2.2 Types (in `BrahmaSafety`)

```swift
public enum Principal: Hashable, Sendable {
    case owner(companyId: String)
    case agent(AgentPrincipal)
    /// Engine-authored bytes only (canary scratch, doctor probes).
    case engine
    /// Bytes from outside the company (an imported extension, a dropped file not vouched for).
    case external(source: String)
    /// Could not be resolved. `reason` is engine text for logs and the owner note, never shown to agents.
    case unknown(reason: String)
}

public struct AgentPrincipal: Hashable, Sendable {
    public let agentId: String
    public let companyId: String
    public let role: String
    /// The agent's profile narrowed by its company, its role profile and the engine ceiling, at resolution time.
    public let profile: PermissionProfile          // moved to BrahmaSafety in S3
    /// The agent's granted domains (5-lite grants), already intersected with the company network scope.
    public let grantDomains: [String]
}

/// Everyone whose bytes or code one action touches. Never empty: an empty set is `[.unknown("no principal")]`.
public struct PrincipalSet: Hashable, Sendable {
    public let companyId: String
    public let members: [Principal]           // sorted, deduplicated
    public var hasUnknown: Bool { get }
    /// True only if members is non-empty, contains no .unknown/.external/.engine, and every .agent narrows to .full
    /// and every .owner's company profile (narrowed by the ceiling, carried in `ownerProfile`) is .full.
    public var allFull: Bool { get }
    /// The intersection of every agent member's grantDomains. Empty when any member is not .agent or .owner.
    public var commonGrantDomains: [String] { get }
    public let ownerProfile: PermissionProfile   // the company's own profile narrowed by the ceiling
}
```

#### 6.2.3 Resolution (`PrincipalResolver`, in `BrahmaCore`, because it reads `Store`)

```swift
public enum ActionSubject: Sendable {
    case verificationRun(runId: String)            // submit / merge check (3a)
    case mergeRun(runId: String)                   // 4a merge-queue check (kinds main, item, mainAtBase, batch)
    case preview(surfaceId: String)                // L/4a preview start, smoke, demo
    case mainSmoke(companyId: String)              // L release smoke check (company.smokeCheckSetById)
    case release(releaseId: String)                // L release tool run (proposedById)
    case worktree(companyId: String, key: String)  // C live diff, wt: refs, isDirty on item worktrees
    case publish(companyId: String, agentId: String?)   // 4a publish_artifact (nil = owner)
    case vaultBlob(companyId: String, provenance: Provenance) // C2a text extraction of a stored file
    case extensionBundle(source: String)           // 5-lite extension import and validation
    case engine                                    // canary, doctor
}

public struct PrincipalResolver {
    public init(store: Store, ceiling: PermissionProfile?)
    /// Total: never throws, never returns an empty set. Every failed lookup (a `try` that throws, a missing row, a missing
    /// role, an id that is neither "owner" nor an agent of `companyId`) becomes a `.unknown(reason)` member.
    public func resolve(_ subject: ActionSubject) -> PrincipalSet
}
```

The resolution rules carry the existing semantics, plus the fixes marked ✱:

| Subject | Members |
|---|---|
| `verificationRun` | The lease holder of `run.itemId`, else `run.requestedBy`. ✱ A lookup error, or neither one present → `.unknown`. Today the role lookup's `?? true` makes the result unsandboxed (`main` `:107-111`). |
| `mergeRun` | Exactly 4a's rule (`SandboxedCheckRunner.swift:126-167`): the setter for `main`/`mainAtBase`; for `main`/`item`, the run's item and its batch's items plus every queue-landed item, each item's holder and author; `mainAtBase` with a head the queue did not land → `.unknown`. Unknown kinds and missing data → `.unknown`. |
| `preview` | The surface's `setById`; `"owner"` → `.owner`. ✱ nil, or a failed lookup → `.unknown`. Today nil "follows the company" and becomes unsandboxed in a Full company (`PreviewRunner.swift:453-457`). |
| `mainSmoke` / `release` | `company.smokeCheckSetById` / `release.proposedById`, with the same rules as `preview`. |
| `worktree` | The current lease holder of the item with `key`, else the item's `ownerId`, else `.unknown`. |
| `publish` | The publishing agent, or `.owner`. |
| `vaultBlob` | `.agent(id)` for `Provenance.agent`, `.owner` for `.owner`, `.external` for `.external`, `.engine` for `.engine`. |
| `extensionBundle` | `.external(source)` (**architect's call**: an extension is never Full-eligible). |
| `engine` | `.engine`. |

Two further rules:
- **The ceiling.** `PrincipalResolver` narrows every profile by the engine ceiling (`brahma run --profile`). ✱ `PreviewRunner.unsandboxed` does not apply the ceiling today.
- **Resolve once.** The set is resolved exactly once per action, at the action's start, and passed down. Nothing below re-reads roles or leases. A test asserts that each migrated call site makes one `resolve` call per action (S6).

#### 6.2.4 Least-privileged wins

The factory combines a set as follows (**architect's call**, generalizing 4a's merge-run rule):
- `allFull` needs every member to be Full-eligible.
- Network grants are the intersection.
- Reach is the intersection.
- Toolchain is decided by the purpose only.
- Any `.unknown`, `.external` or `.engine` member makes the set ineligible for `fullOptOut` and for any `grantDomains`.

### 6.3 The policy factory

#### 6.3.1 Types

```swift
/// Why the engine runs something under Seatbelt. Exhaustive: a new purpose must be added here and decided below.
public enum Purpose: Sendable, Equatable {
    case check(CheckKind)                       // .submit, .merge (VerificationRun), .mergeQueue (MergeRun)
    case previewServer(port: LoopbackPort)
    case previewOneShot                         // CLI build/demo
    case appleBuild
    case guiApp(surface: String)
    case releaseTool                            // L ReleaseExecutor adapter tools
    case releaseSmoke                           // Store+Release main smoke command
    case providerProbe                          // Hosting/ProviderProbe
    case extensionUnzip, extensionValidate      // 5-lite extensions
    case doctorExtensions                       // Engine/Doctor+Extensions
    case canary(CanaryProbe)                    // SandboxCanary scratch runs
    case helper(HelperOp)                       // every brahma-helper call (§6.4)
}

/// Places an action may name, each verified as a real directory/file of the expected kind by an fd-anchored open and
/// carried as its resolved path. Only `BrahmaSafety` can make one (`Place.verify(_:kind:under:)`).
public struct Place: Hashable, Sendable { public let resolvedPath: String; public let kind: PlaceKind }

public struct NetworkScope: Sendable { public let companyDomains: [String] }   // CompanyNetwork.scope(...).allowedDomains

public enum PolicyDecision: Sendable {
    case sandboxed(ValidatedPolicy)
    /// The company owner's Full opt-out. It carries the reason for the activity line, and it is a distinct type, so the
    /// unsandboxed runner accepts only a FullOptOut (it cannot be reached from a Bool).
    case fullOptOut(FullOptOut)
    case refused(Refusal)
}

public enum SandboxPolicyFactory {
    public static func decide(_ purpose: Purpose, principals: PrincipalSet, places: PurposePlaces,
                              network: NetworkScope, baseline: SandboxBaseline) -> PolicyDecision
}
```

`PurposePlaces` is an enum, one case per `Purpose`, with typed associated `Place`s. For example:
- `.check(checkout: Place, workspace: Place)`;
- `.previewServer(run: Place)`;
- `.guiApp(run: Place, appData: Place)`;
- `.helperWorktree(worktree: Place, gitCommonDir: Place, call: Place)`.

The factory checks that the case matches the purpose; a mismatch is a `.refused` decision (**architect's call**, so callers cannot slip extra places in).

#### 6.3.2 Rules (exhaustive switch; each rule reproduces today's policy for that site)

- **writable/readable/network/toolchain.** The values today's site uses, moved in. Examples:
  - `check`: writable `[checkout]`, readable `[workspace]`, `.outbound(companyDomains)`, toolchain on.
  - `previewServer`: writable/readable `[run]`, `.loopbackListen(companyDomains + commonGrantDomains, [port])`, toolchain on.
  - `guiApp`: writable `[appData]` (named logically, as fix round 1 I1 requires), readable `[run]`.
  - `helper(op)`: §6.4.4.
- **Full opt-out.** `fullOptOut` only when **all** of the following hold:
  1. the purpose runs agent-written commands (`check`, `previewServer`, `previewOneShot`, `appleBuild`, `guiApp`, `releaseTool`, `releaseSmoke`);
  2. `principals.allFull`;
  3. `principals.ownerProfile == .full`.

  Otherwise the decision is sandboxed.
- **Unknown, external or engine members.** No `grantDomains`, never `fullOptOut`. Helper reach uses the purpose places only (§6.4.4).
- **Validation.** `SandboxPolicyCheck.validate` runs inside `decide`. Any throw becomes `.refused(reason)`. The only way to obtain a `ValidatedPolicy` is through `decide`.

#### 6.3.3 `ValidatedPolicy` closes the render race

`SandboxPolicyCheck.validate` today checks each path (`resolve(path) == path`, no `..`, no overlap). `SeatbeltProfile.render` then calls `SandboxPath.resolve` on each entry again (`SeatbeltProfile.swift:106-110`), so a link swapped in between changes what is rendered.

`ValidatedPolicy` stores the exact strings that validation accepted, and `render(_ v: ValidatedPolicy, …)` never resolves anything (**architect's call**). 4a's Task 7 carries a point fix for this race (4a progress, carried obligation d). Plan S makes it structural and keeps any test 4a added.

Why the remaining window is harmless: Seatbelt matches resolved paths at access time against literal real paths. A link swapped after rendering therefore resolves to a place outside the profile and is denied. This is the property the helper relies on (§6.4.6).

#### 6.3.4 Places for a pinned-but-not-yet-migrated site

None. S7 migrates all 16 construction sites (§7.2). After S7, `SandboxPolicy(` appears only in `BrahmaSafety/Policy/`, enforced by access control (`internal init`) and by the lint.

### 6.4 The helper

#### 6.4.1 What must run in the helper (the rule)

The engine may still do these in-process (**architect's call**):
- open **one** agent-named file through the fd-anchored path layer (`SafeFS`/`EngineFiles`/`SafeRead`: `O_NOFOLLOW` walk, regular, one link, owner, size cap) and read capped bytes;
- run pure, bounded Swift parsing on **≤ 64 KiB** of such bytes: UTF-8 decode, magic-byte sniff, image header dimensions;
- run git on **committed objects** in the engine-owned repository (C's `SafeGit` reads, 3a's `GitWorkspace` on engine-made exports and refs);
- walk a **quiescent** tree written by a finished helper (§6.4.6).

Everything else on agent-controlled data runs in the helper:
- enumerating an agent-writable directory tree;
- running a tool (git, unzip) whose inputs include agent-writable files other than engine copies;
- any network request to a service an agent's code runs (loopback previews);
- parsing complex formats: zip central directory, OOXML, glTF JSON, OpenAPI;
- copying more than one file, or folder copies.

Plan S migrates every current instance (§7.4). The lint (§6.8) stops new ones: `opendir`/`fdopendir`/`readdir`/`FileManager.enumerator`/`contentsOfDirectory` on agent places, `"git"` with a worktree as work tree, and `URLSession`/`HTTPProbing` to loopback are all banned outside `BrahmaSafety`.

#### 6.4.2 The binary

- A new executable target **`brahma-helper`** depends **only** on `BrahmaSafety` (**architect's call**).
  - No `Store`, no GRDB and no engine code ends up inside the sandbox.
  - It starts faster than `brahma`: 48 MB debug.
  - A confused helper cannot even link database code.
- `scripts/make-app.sh` builds and signs it next to `brahma` (`Contents/Helpers/brahma-helper`).
- The engine locates it as the sibling of `mcpExecutable`.
- At engine start, `HelperBinary.verify(url)` checks that the binary:
  - is a regular file, not a link;
  - is owned by the current user or root;
  - is not group- or world-writable;
  - is not inside any company workspace or data home;
  - answers `--protocol` with `HelperProtocol.version`.

  A failure sets a `brahma doctor` item `helper` to fail, and every helper call refuses `.unavailable`. It is not an engine hold: only helper-backed features stop (**architect's call**).

#### 6.4.3 Protocol

- **argv:** `brahma-helper <op>`, where `<op>` is a `HelperOp` raw value. Nothing agent-derived goes on argv.
- **stdin:** one JSON `HelperRequest { v: Int, op: HelperOp, callDir: String, args: OpArgs }`, at most 64 KiB.
  - Every path in `args` is an engine-computed absolute path, or a relative path the engine validated with `SafeFS.components` rules.
  - The helper re-validates both and refuses anything else.
- **stdout:** one JSON `HelperResponse { v: Int, result: OpResult | refusal: HelperRefusal{code, detail} }`, at most 256 KiB.
  - Bulk output (a patch, staged files, extracted text over 64 KiB) is written under `<callDir>/out/` and listed in the result with size and SHA-256.
- **stderr:** at most 16 KiB. It goes to the engine log only, sanitized (control characters replaced), and never into any prompt or owner text.
- **exit:** 0 when a response was written. Anything else is `HelperError.failed(exitStatus, signal)`.
- **Versioning:** `HelperProtocol.version = 1`. A mismatch on either side is a refusal: the binaries ship together, so a mismatch means a broken install.
- **Decoding:** strict. `JSONDecoder` with every field required, unknown keys rejected (custom `init(from:)` checks the key set), and string lengths bounded per field. A response over its cap is killed and refused.

#### 6.4.4 Operations

| `HelperOp` | Callers (merged 4a+C) | Subject | readable (all resolved, `Place`) | writable | network | toolchain | caps | time |
|---|---|---|---|---|---|---|---|---|
| `worktreeDiff` | `RefResolver` ×2, `OpenRef` ×1 (C1b/C2a); `LiveChanges`/`changesSnapshot`/`changesBoard` (C5b) | `.worktree` | the item worktree; the repo's git common dir | call dir | none | no | ≤ 2000 changed paths, ≤ 100 000 untracked entries considered, patch ≤ 5000 lines, git output ≤ 8 MiB, index ≤ 64 MiB | 10 s (`SafeGit.timeout`) |
| `worktreeStatus` | `isDirty(in:)` on item worktrees and run checkouts (`Orchestrator.swift:966, 1584`) | `.worktree` / `.verificationRun` | same / the checkout | call dir | none | no | output ≤ 1 MiB | 10 s |
| `loopbackHTTP` | `BackendAdapter.smoke` (start, demo), `WebAdapter` readiness GET and demo GET | `.preview` | — (helper binary only) | call dir | `.loopbackConnect(port)` | no | ≤ 20 requests per call; request body ≤ 64 KiB; kept body ≤ `SmokeRequest.bodyKept` chars (helper reads ≤ 4×); headers ≤ 16 KiB | per request 10 s; call ≤ 210 s |
| `stageCopy` | `Store.publishArtifact` (file, folder, glTF set); `BackendAdapter.copyOpenAPI` | `.publish` / `.preview` | the resolved source (file, folder, or the glTF's folder) | call dir | none | no | 4a's `ArtifactPolicy` caps and remaining quota; OpenAPI ≤ 2 MiB; ≤ 2000 entries, depth ≤ 32 | 60 s |
| `extractText` | `OpenRef` via `TextExtract.extract` (C2a) | `.vaultBlob` | an engine-made held copy of the blob | call dir | none | no (runs `/usr/bin/unzip` inside the helper) | `ArchiveLimits` (200 MiB decompressed, ratio 100); text out ≤ 2 MiB | 30 s |
| `selftest` | `brahma doctor`, the canary | `.engine` | call dir | call dir | none or `.loopbackConnect(testPort)` | no | — | 5 s |

All rows share these rules:
- The helper policy always adds the helper binary's resolved directory (and, on dev builds, the `.build/<triple>/<config>` directory) to `readable`.
- With purpose `.helper(op)` the factory:
  - never returns `fullOptOut`;
  - never adds `grantDomains`;
  - never enables the toolchain;
  - refuses unless every place is inside the subject set's reach.

  Reach is defined as follows (**architect's call**):
  - **agent:** the company workspace, minus `.git` internals listed in `SandboxScope.gitInternals`, minus `SandboxScope.engineOnlyDotBrahma` children, minus other agents' labs and notes, plus its own lab, home and notes;
  - **owner:** the company workspace;
  - **engine/external/unknown:** the purpose places only;
  - the call dir is always in reach.

  Pinned by a property test: for random subjects and places, `policy.readable ∪ policy.writable ⊆ reach ∪ {call dir, helper dir}`.

**How `worktreeDiff` works inside the helper (measured design, **architect's call**).**
- The helper runs the resolved absolute git (`ToolPaths.git`, passed in the request and re-checked by the helper to be one of `ToolPaths.gitCandidates`) with:
  - `GitHardening.flags` plus `-c core.untrackedCache=false -c core.excludesFile=/dev/null -c core.attributesFile=/dev/null`;
  - `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_LITERAL_PATHSPECS=1`;
  - `GIT_DIR=<common dir>` (never the item's admin dir, so no per-worktree config);
  - `GIT_WORK_TREE=<worktree>`;
  - `GIT_INDEX_FILE=<call>/index` (a fresh index: **the agent's index is never read**, so a forged stat cache cannot hide a change);
  - `GIT_OBJECT_DIRECTORY=<call>/objects` and `GIT_ALTERNATE_OBJECT_DIRECTORIES=<common dir>/objects`, so nothing is written to the repository.
- The steps:
  1. `read-tree <base sha>`;
  2. `update-index -q --refresh`;
  3. `ls-files -o --exclude-standard -z`, with a count and byte cap;
  4. `add --intent-to-add --all`;
  5. one `diff <base> --numstat -p --no-ext-diff --no-textconv --no-color --no-renames`, cut at the caps.
- Git does all ignore and attribute parsing, so the engine keeps no gitignore parser (C's principle). Git may follow anything, but it can only reach what the holder could already read.
- Modified-file mtimes (C5b `lastEdit`) come from `lstat` in the helper.
- `blobShas` is dropped from `WorktreeDiff`: grep finds no consumer.

**`loopbackHTTP`** is a minimal HTTP/1.1 client over a BSD socket to `127.0.0.1:<port>` only. It sends `Connection: close`, `Host: 127.0.0.1:<port>`, `Content-Length`; it follows no redirect and has no TLS, cookies or proxy.
- **architect's call:** it avoids CFNetwork's mach-service dependencies inside Seatbelt, and loopback previews are plain HTTP.
- `.loopbackConnect(port)` renders as `(deny network*)(allow network-outbound (remote ip "localhost:<port>"))`, with no proxy port.
- SSRF to any other local service becomes impossible at the kernel level.

**`stageCopy`** reproduces 4a's `publishArtifact` copy rules inside the helper:
- extension and sniff, no links, regular single-link files, a folder needs `index.html`, glTF bare-name siblings, per-kind caps;
- the zip central-directory ratio check.

It writes `out/` plus a manifest. The engine then re-checks the cheap fixed-size invariants on the quiescent copy (§6.4.6): kind by extension, magic bytes from the first 64 bytes, size and SHA-256, regular and single-link. It then copies into `.brahma/artifacts/<n>-…/` through `EngineFiles`.

Helper verdicts from complex parsers (zip ratio, glTF siblings) are **hints, never authorization** (**architect's call**). Every later consumer of those bytes either is sandboxed already (the app's QuickLook is out of process) or reads only the engine-confined copy.

#### 6.4.5 Lifecycle of one call (`HelperClient.call`)

1. **Gate.**
   - Refuse with `.unavailable` while the engine is in emergency stop, except owner-requested read-only operations (`worktreeDiff`, `worktreeStatus`, `extractText`).
   - Refuse with `.unavailable` while `HelperBinary` is unverified or the platform has no Seatbelt.
   - Take a slot from the global `HelperPool`: 4 concurrent calls; waiters are FIFO and time out after 30 s with `.busy` (**architect's call**).
2. **Resolve.** `PrincipalResolver.resolve(subject)`, once, by the caller, which passes the `PrincipalSet` in.
3. **Places.** Build `Place`s from engine records (fd-anchored verification).
4. **Call dir.** Create `<paths.home>/run/helper/<uuid>/` with `{home, tmp, out}`, mode 0700, by `EngineFiles` descriptors (never through a link).
5. **Policy.** `SandboxPolicyFactory.decide(.helper(op), principals, .helper…(places, call), network)`. A `.refused` decision ends the call.
6. **Spawn.**
   - Command: `Spawn.sandboxed(validated, executable: helperURL, args: [op], cwd: callDir, env: HelperEnv.make(callDir))`.
   - Environment: `PATH=/usr/bin:/bin`, `HOME=<call>/home`, `TMPDIR=<call>/tmp`, `LC_ALL=C`, plus the git variables above. No inherited environment.
   - The child gets its own process group, is registered in `ChildGroups.current` (so the emergency stop kills it) and carries a per-run Seatbelt marker for the sweep.
   - rlimits set in the child before exec:
     - `RLIMIT_CPU` = op time + 5 s;
     - `RLIMIT_FSIZE` = per-op max file (64 MiB for diff and status, the per-kind artifact cap for `stageCopy`);
     - `RLIMIT_NOFILE` = 256;
     - `RLIMIT_CORE` = 0.
7. **I/O.**
   - Write the request to stdin and close it.
   - Read stdout up to its cap and stderr up to 16 KiB.
   - The wall timeout runs on `AwakeTime`. Past it: SIGTERM to the group, a 1 s grace, then SIGKILL.
8. **Sweep.** `SandboxSweep` over the marker kills stragglers. If any could not be killed, or the process table could not be read, the call fails with `.failed(…)` and the call dir is quarantined (removed by descriptor at next start). It is never read.
9. **Decode** strictly. Then read the listed `out/` files through `EngineFiles` (regular, one link, size equals the manifest, SHA-256 matches).
10. **Clean up.** Remove the call dir by descriptor (`EngineFiles.clear`). A start-up sweep removes call dirs older than 1 hour that an earlier engine left.

#### 6.4.6 Quiescence

The write side of the call dir belongs to the helper until step 8. After a clean sweep, no process holding the run's sandbox exists. The helper has no means to pass a descriptor or delegate writes elsewhere:
- `deny job-creation`, `deny signal (target others)`;
- writable means only the call dir;
- no mach service except the marker.

From then on `<call>/out` is a **quiescent untrusted tree**. The engine may walk it with `EngineFiles` (still no-follow, names validated) without TOCTOU, because nothing can change it any more. This is the only kind of agent-influenced tree the engine walks in-process after Plan S.

#### 6.4.7 Failure semantics

Every helper error is a typed `HelperError`:
- `unavailable(reason)`;
- `busy`;
- `refused(HelperRefusal)` (the op's own refusal, mapped to the caller's existing refusal texts: `SafeGitError.tooManyChanges`, 4a's artifact refusals, C's generic `"ref <n> isn't available to you"`);
- `failed(reason)`;
- `timedOut`.

Each caller maps them to its existing user-facing texts. A helper failure never becomes "no changes", "ok" or an empty result (the anti-fail-open rule). Pinned per caller with a failing transport test (S9–S12).

### 6.5 Process spawning (`Spawn`, `ToolPaths`)

- **`ToolPaths`** is resolved once at engine start (**architect's call**).
  - The engine's own `PATH` is walked keeping only absolute directories that:
    - exist;
    - are owned by root or the current user;
    - are not group- or world-writable;
    - are not inside any company workspace or data home.
  - The first regular executable `git`, `claude`, `unzip` and `tar` found there is used.
  - The macOS `/usr/bin/git` shim is replaced by its real target (`xcrun --find git`, run once). Inside the helper sandbox the shim would need xcrun's cache writes.
  - `sandbox-exec`, `/bin/sh`, `/usr/bin/unzip` and `/usr/bin/tar` are fixed absolute paths.
  - git must be ≥ 2.43 (3a's attr-source floor).
  - Shown in `brahma doctor` (`tools: git /opt/homebrew/bin/git 2.52.0 …`).
- **`Spawn`** is the single process primitive: `posix_spawn` with its own group, an explicit argv[0] equal to the absolute path, and an explicit environment. Nothing goes through `/usr/bin/env`.
  - The engine's own git calls run with `cwd` = an engine-owned directory (the repo's common dir or the call dir), never an agent worktree, plus `GIT_DIR`/`GIT_WORK_TREE`.
  - `PATH` handed to any child is sanitized: relative and empty entries are dropped.
  - This removes the PATH-planted-git class (analysis §7.1).
- **Migrated sites (C tree, 14 lines in 5 files):**
  - `Git/GitWorkspace.swift` (5: the two version probes, `runOnce`, the grouped run at `:430`, `tar` at `:2236`);
  - `Turns/TurnRunner.swift` (4: `/usr/bin/env claude`);
  - `Sandbox/ClaudeSettings.swift` (3: the shell-prefix script's `/usr/bin/env -i`, which is *script text*; it stays, pinned by the lint allowlist with a reason);
  - `Verify/ProcessGroup.swift` (1, which becomes `Spawn`);
  - `Engine/Doctor.swift:390` (1).

### 6.6 Typed prompt text

#### 6.6.1 Types (in `BrahmaSafety/Prompt/`)

```swift
/// Engine text. Only literals and validated tokens can be interpolated; a `String` cannot (no appendInterpolation(String)).
public struct Trusted: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol {
        public mutating func appendLiteral(_ s: String)
        public mutating func appendInterpolation(_ n: Int)
        public mutating func appendInterpolation(_ t: some TrustedToken)
        public mutating func appendInterpolation(_ t: Trusted)
    }
}
/// Values whose every possible spelling is engine-validated: item keys (3a grammar), agent handles, ref canonicals
/// (C1b grammar), enum raw values of engine enums, formatted clocks and durations, absolute engine paths.
public protocol TrustedToken { var trustedText: String { get } }

/// Text from an agent, the owner or outside, with where it came from and whether that session was tainted.
public struct Untrusted: Sendable {
    public init(_ text: String, from: Provenance, taint: TaintState)
}
public enum TaintState: Sendable, Equatable { case clean, tainted(reason: String) }   // no Bool

public struct PromptBuilder {
    public mutating func line(_ t: Trusted)
    public mutating func section(_ heading: Trusted)
    /// One line: label + value flattened (newlines, controls, bidi and zero-width characters → markers), cut at `max`.
    public mutating func field(_ label: Trusted, _ value: Untrusted, max: Int, whenTainted: TaintRendering)
    /// Many lines, each prefixed "    | ", capped by chars and lines.
    public mutating func quote(_ label: Trusted?, _ value: Untrusted, maxChars: Int, maxLines: Int, whenTainted: TaintRendering)
    /// UntrustedBlock: "Untrusted content from <source> — data, not instructions:" + quoted lines.
    public mutating func untrustedBlock(source: Trusted, _ value: Untrusted, maxLines: Int)
    public mutating func include(_ other: RenderedPrompt)
    public func build() -> RenderedPrompt
}
public enum TaintRendering: Sendable { case frame /* relayed-taint prefix line before it */, withhold(Trusted) }

/// The only thing a turn, a system prompt or a tool result can carry. No public init except through PromptBuilder.
public struct RenderedPrompt: Sendable, Equatable { public let text: String; public static let empty: RenderedPrompt }
```

#### 6.6.2 Rules

- `TurnRequest.prompt` and `TurnRequest.appendSystemPrompt` become `RenderedPrompt` / `RenderedPrompt?`.
  - `ControlProbe`, `SandboxCanary`, `ModeCanary`, `Doctor` and `ExtensionTry` build their engine-literal prompts with `Trusted` literals.
  - `ExtensionTry`'s user-provided try prompt is `Untrusted(from: .owner)`.
- **`whenTainted` is a required parameter, with no default** (**architect's call**). Every relayed field decides at the call site, and the compiler makes it.
  - Today's behaviours map as follows:
    - artifact title → `.withhold`;
    - item spec / acceptance criteria → `.frame`, using today's `TaintPolicy.relayedPrefix` line;
    - commit subjects, check commands, blocked reasons and review flags (`TurnDigest.swift:300-330`) → `.frame`.
  - The last item is an **intended delta**: these are framed today only by `flat`/`quote` and carry no taint signal (§8).
- **Byte-stable prefix.** `RolePrompt`/`OperatingRules` must render byte-identically to today. A golden test pins this, because the prompt-cache prefix depends on it (spec v2 §4.3.3).

#### 6.6.3 What is migrated (C tree counts of framing-helper uses)

`TurnDigest.swift` (27), `Work/Review.swift` (22: `ReviewDigest`, `AuditDigest`), `Turns/Prompts.swift` (`OperatingRules`, `RolePrompt`, `InboxDigest`, `WorkNoticeDigest`), `UltraDigest`, `newResourcesBlock`, and C's digest additions (`DigestRefs`, thread lines) as merged.

#### 6.6.4 Parity

S13 first captures golden renders of every digest family over the existing test fixtures, plus a hostile fixture (newlines, ESC, bidi, ZWJ, 50 KB fields, tainted authors). It then migrates. Goldens may change only for the deltas listed in §8, each in its own commit with a before/after.

#### 6.6.5 Tool outputs (`ToolOutput`)

`CompanyTools.call(...)` and every tool handler return `ToolOutput` (= `RenderedPrompt`).
- **Migrated in S14** are the 12 tools that relay text written by another principal: `read_channel`, `list_channels`, `list_agents`, `list_work`, `show_work_item`, `search_memory`, `recall`, `search_kb`, `kb_read`, and C's `open_ref`, `search` and thread reads. Task S1 re-confirms the list on merged `main`.
- **Every other handler** returns `ToolOutput.legacy(_ s: String, tool: StaticString)`. A test pins the set of tools allowed to call `legacy` (frozen). A tool not in the set cannot use it, so a new tool must use `PromptBuilder`.

### 6.7 Default-deny shapes

- **`Decision`**: `public enum Decision<Allowed: Sendable>: Sendable { case allow(Allowed, because: Reason); case deny(Reason) }`. It has no `Bool` property, no `ExpressibleByBooleanLiteral` and no failable unwrap.
  - Used by `PolicyDecision`, `HelperBinary.verify`, `ToolPaths` checks and the principal Full-eligibility.
  - Existing `Bool`-returning safety predicates in the moved files are converted when touched by S3/S4. The lint forbids new `-> Bool` public functions in `BrahmaSafety/Policy` and `BrahmaSafety/Principal` (**architect's call**: narrow scope, so the move stays mechanical).
- **`AlertScope`**: `EngineAlerts.raise(store:db:text:now:reason:scope:)`, with `scope: AlertScope` **required**.
  - `enum AlertScope { case company(String); case allCompanies(GlobalAlert) }`.
  - `enum GlobalAlert { case engineHold, sandboxCheck, engineFile, doctor, secrets, cli }`. Every engine-wide reason is named, and adding one is a reviewed change.
  - All 30 call lines in 17 files (C tree) are migrated. A call that passed no `companyId` today becomes `.allCompanies(<named reason>)` **only if** the reviewer confirms that the condition is engine-wide. Otherwise it becomes `.company(id)`.
  - Each one is listed in the S4 commit message with its verdict. A wrong broadcast found here is a §8 bugfix delta.
- **Bans in `BrahmaSafety` and `Principal/`** (lint):
  - `try?`, `?? true`, `?? false`;
  - `catch { }` with an empty body;
  - `return true` as the last line of a `catch`.

  The 45 `try?` in Sandbox and Safety (C tree) that move into `BrahmaSafety` are rewritten with explicit handling in S4. Each becomes a refusal, a reported problem (`SandboxBaseline.problem`) or a documented best-effort cleanup through `bestEffort { … }`, a named helper that logs. The same ban is applied to `Safety/` files that stay in `BrahmaCore` (`Taint.swift`, `Secrets.swift`, `EmergencyStop.swift`, `OwnerShellGuard.swift`), through a baseline count that may only shrink (**architect's call**: they are not all fail-open, and S4 converts only the ones on a decision path).

### 6.8 The safety module and the lint

#### 6.8.1 `BrahmaSafety` contents (S3 moves; later tasks add)

| Area | Moved from (C tree) | Added |
|---|---|---|
| Path | `Util/EngineFiles.swift`, `Refs/SafeFS.swift`, `SandboxPath`/`resolvedForSandbox`/`IdentityRoots`/`checkAllowed` (out of `Sandbox/SandboxScope.swift`), `Util/SHA256.swift`, `Util/SHA1.swift`, `Util/AwakeTime.swift` | `SafeRead` (S2/S15), `Place` (S7) |
| Process | `Verify/ProcessGroup.swift` (`GroupRun`, `ProcessGroupChild`), `CheckOutcome` (from `Verify/CheckRunner.swift`), `Safety/ChildGroups.swift`, `ChildEnvironment` (from `Turns/TurnProfile.swift`), `ProcessTable`/`SandboxSweep` (from `Turns/TurnProcess.swift`) | `Spawn`, `ToolPaths` (S5) |
| Sandbox | `Sandbox/SandboxedRunner.swift`, `SeatbeltProfile.swift`, `SeatbeltRunner.swift`, `EgressProxy.swift` (+ `DomainMatcher`), `SandboxDomains`/`SandboxError`/`ProtectedPaths` (out of `SandboxScope.swift`), `PermissionProfile` (out of `Turns/ClaudeCommand.swift`), `UnsandboxedPreviewRunner` | `ValidatedPolicy`, `SandboxNetwork.loopbackConnect` |
| Git hardening | the flag and environment constants of `GitCommand` | `GitHardening` |
| Policy / Principal | — | `Principal`, `PrincipalSet`, `Purpose`, `PurposePlaces`, `PolicyDecision`, `SandboxPolicyFactory`, `Decision`, `Reach` |
| Prompt | `UntrustedBlock` (out of `Safety/Taint.swift`) | `Trusted`, `Untrusted`, `PromptBuilder`, `RenderedPrompt`, `ToolOutput` |
| Helper | — | `HelperProtocol`, `HelperOp`, request/response types, `HelperServer` (ops), `HelperClient`, `HelperPool`, `HelperBinary`, `LoopbackHTTP` |

Package and module rules:
- `BrahmaCore` gains `@_exported import BrahmaSafety` (**architect's call**). `BrahmaAppModel`, `brahma` and the tests keep compiling unchanged. Only `public` safety API is re-exported, and internals (`SandboxPolicy.init`) stay internal.
- `Package.swift`:
  - new targets `BrahmaSafety` (deps: `CSandboxCheck` only if a moved file needs it) and `brahma-helper` (deps: `BrahmaSafety`), and the test target `BrahmaSafetyTests`;
  - the products list gains the `brahma-helper` executable.
- **Linux portability holds:** the same rules as `BrahmaCore`, with Darwin-only code behind `#if canImport(Darwin)`.

#### 6.8.2 `SafetyLintTests` (in `BrahmaCoreTests`, same scan style as `EngineGitGuardTests`, comments blanked)

The lint scans `Sources/BrahmaCore` and `Sources/brahma`. It holds a checked-in baseline (`Tests/BrahmaCoreTests/Fixtures/safety-lint-baseline.json`: rule → file → count).

- **Fails** when:
  - a (rule, file) count exceeds its baseline;
  - a file not in the baseline has a hit;
  - a rule marked `zero` has any hit.
- **Prints** the exact baseline to paste when counts went *down*, so baselines only shrink (the test fails until the baseline is lowered, which makes shrinking sticky).

| Rule | Pattern (code only) | Start (C tree) | End of Plan S |
|---|---|---|---|
| `spawn` | `Process()`, `posix_spawn(`, `"/usr/bin/env"` as an executable, `[ "git"` argv | 14 lines / 5 files | **zero** (ClaudeSettings' script-text line allowlisted with a reason) |
| `sandboxPolicy` | `SandboxPolicy(` | 16 / 11 | **zero** (access control as well) |
| `descriptor` | `open(`, `openat(`, `fstatat(`, `lstat(`, `readlink(`, `realpath(`, `O_NOFOLLOW` | 170 open-family + 104 `O_NOFOLLOW` / ~48 files | **zero** in `Refs/`, `Preview/`, `Merge/`, `Store/Store+Artifacts.swift`, `MCP/`, `Changes/`; elsewhere the baseline may only shrink |
| `fileAPI` | `FileManager.default`, `Data(contentsOf:`, `String(contentsOf`, `.write(to:`, `FileHandle(for` | 265 + 43 / 68 files | **zero** in the same agent-facing set; baseline elsewhere (most hits are the engine's own data home, backups and extensions) |
| `dirWalk` | `enumerator(at:`, `contentsOfDirectory(`, `opendir(`, `fdopendir(`, `readdir(` | measured in S1 | **zero** outside `BrahmaSafety` except a listed allowlist of engine-owned roots (backups, data home sweep) |
| `loopbackHTTP` | `URLSession`, `HTTPProbing`, `URLSessionHTTPProbe` in `Preview/` | 26 lines / 9 files overall | **zero** in `Preview/`; release/push/health allowlisted |
| `failOpen` | `?? true`, `?? false`, `try?` | — | **zero** in `BrahmaSafety` and `Principal/`; baseline-only-shrinks in `Safety/` and `Sandbox/` remnants |
| `alertScope` | `EngineAlerts.raise(` without `scope:` | 30 / 17 | **zero** (the compiler enforces it too) |
| `turnScope` | `SandboxScope.forTurn(` | measured in S1 | the call sites present on merged `main`, frozen |
| `prompt` | a `String` stored into `TurnRequest.prompt`/`appendSystemPrompt`; `ToolOutput.legacy(` outside the frozen tool set | — | enforced by types; lint pins the frozen set |

`BrahmaSafetyTests` adds a second static test: no file in `Sources/BrahmaSafety` imports `GRDB` or references `Store`. That keeps the kernel engine-agnostic and the helper free of database code.

### 6.9 Path layer consolidation

The analysis names three overlapping layers and URL-taking APIs next to fd-anchored ones (§7.1). Plan S does **not** rewrite them (**architect's call**: they are reviewed and battle-tested). It:

1. moves all three into `BrahmaSafety` (S3);
2. adds `SafeRead`, the single bounded no-follow reader for small engine-verified files:

   ```swift
   SafeRead.smallText(_ relative: String, under root: Place, limit: Int = 4096) throws(SafeReadError) -> String
   ```

   It opens every component `O_NOFOLLOW` from `root`, then `fstat`: regular, one link, owner, size ≤ limit. It reads at most `limit+1` bytes and decodes UTF-8 strictly. S2 uses it to fix `GitWorkspace.regularText`.
3. makes every URL-variant entry point that can be handed an *agent* directory `internal`. Examples: `EngineFiles.readNoFollow(_ url:under:)` with an agent root. Agent-facing callers must go through `SafeFS` (agent-named) or `Place`-rooted APIs (engine places).
4. gives `UnsafeEngineFile` a typed `kind` (analysis §9, C minor 10), so `SafeFS.map` stops matching English text.
5. puts `SafeFS.testHookAfterComponent` and `SafeGit.testOnlyRun` behind `#if DEBUG` (C minors 12–13).
6. adds property and fuzz tests (§10.1).

## 7. Migration strategy per call-site family (counts from grep; C tree unless marked)

Counts are from the C tree (`planC-collab`, which contains 4a through `51d2cee`) plus 4a-only files (`Store+Artifacts.swift`). **S1 re-runs the same greps on merged `main`.** A count off by more than 20 % is reported to the controller before S2 starts. The family list does not change.

### 7.1 Known fail-opens (S2, then subsumed by S6)

| Site | Today | After |
|---|---|---|
| `checkRoute` VerificationRun branch (`main` `:107-111`; 4a `:169-171`) | `try?` lease → `?? requestedBy` → `try?` role → `?? true` → `.unsandboxed` | S2: any lookup error, a nil holder or a nil role → sandboxed, plus an activity line on the run's company ("<KEY>: check ran sandboxed — the engine could not confirm who wrote it (<reason>)"). S6: the resolver. |
| `PreviewRunner.unsandboxed` (`main` `:453-457`; 4a `:587-591`; 3 callers: `PreviewRunner`, `ReleaseExecutor:355`, `Store+Release:258`) | nil setter follows the company; `try?` role `?? true`; no ceiling | S2: nil or error → sandboxed, plus the activity line; ceiling applied. S6/S7: the resolver and the factory. |
| `GitWorkspace.regularText` (`main` `:879-882`; uses at `:862, :889, :890, :892, :894, :906`) | `lstat` then `String(contentsOf:)`: follows a swapped link, unbounded | S2: `SafeRead.smallText(limit: 4096)` from the admin dir / worktree `Place`. A link or an oversized file reads as nil, so `linkProblems` reports it (fail closed, same as today's "was changed"). |

### 7.2 `SandboxPolicy(` constructions → factory (S7): 16 sites in 11 files

| File (C tree line) | Purpose |
|---|---|
| `Sandbox/SandboxedCheckRunner.swift:186` | `.check(…)` |
| `Preview/PreviewModel.swift:325` (`PreviewPolicy.server`) | `.previewServer` |
| `Preview/PreviewKinds.swift:77, 84, 95` | `.previewOneShot`, `.appleBuild`, `.guiApp` |
| `Release/ReleaseExecutor.swift:527, 865` | `.releaseTool` (×2 shapes) |
| `Store/Store+Release.swift:290` | `.releaseSmoke` |
| `Hosting/ProviderProbe.swift:409, 434` | `.providerProbe` (×2 shapes) |
| `Extensions/ExtensionImporter.swift:316` | `.extensionUnzip` |
| `Extensions/ExtensionValidator.swift:677` | `.extensionValidate` |
| `Engine/Doctor+Extensions.swift:45` | `.doctorExtensions` |
| `Safety/SandboxCanary.swift:669, 743` | `.canary(…)` |
| `Refs/TextExtract.swift:98` | removed in S12 (becomes `.helper(.extractText)`) |

Each migration keeps the produced policy identical. A test per purpose compares `factory.decide(...)` with a literal expected `SandboxPolicy` built in the test via `@testable import BrahmaSafety`, using the old site's values. The only intended differences are the §8 deltas: unknown → sandboxed, ceiling applied, grant intersection.

### 7.3 Principal derivations → resolver (S6): 4 sites

`checkRoute` (both branches), `PreviewRunner.unsandboxed` (3 callers), and the release tool route (`ReleaseExecutor:355`). Each becomes `resolver.resolve(subject)` passed into `factory.decide`. 4a's merge-run tests (S3/S3b/S4/M2 rulings) must pass unchanged.

### 7.4 In-engine actions on agent data → helper

| Family | Sites today | Task |
|---|---|---|
| Worktree enumeration and diff | `WorktreeListing.walk` (1), `SafeGit.worktreeDiff` (definition plus 3 callers in `RefResolver:69, 327`, `OpenRef:281`; plus C5b's `changesSnapshot`/`LiveChanges`/`changesBoard` when merged) | S10 |
| Worktree status | `GitWorkspace.isDirty(in:)` callers on agent places: `Orchestrator.swift:966` (check checkout), `:1584` (plan worktree). The root-checkout callers (`MergeQueue:349`, `Store+MergeSettings:189`) act on the owner's root (subject `.owner`) and move too, for one code path (**architect's call**) | S10 |
| Loopback HTTP | `BackendAdapter.smoke` (start, demo), `WebAdapter.swift:35` (demo GET), `:100` (readiness GET) | S9 |
| Staged copies | `Store.publishArtifact` (file, folder, glTF; 16 descriptor calls and 14 `O_NOFOLLOW` in `Store+Artifacts.swift`), `BackendAdapter.copyOpenAPI` | S11 |
| Archive text | `SandboxedUnzipReader.members` + `TextExtract.extract` (1 caller, `OpenRef:137`) | S12 |
| `.git` pointer reads | `GitWorkspace.regularText` | S2 (in-process `SafeRead`, allowed by §6.4.1) |

The in-engine implementations are **deleted** in the task that migrates their callers, together with their now-dead tests. Their behavioural tests are kept and re-pointed at the helper path through an in-process test transport (§10.2).

### 7.5 Spawns → `Spawn`/`ToolPaths` (S5): 14 lines in 5 files (§6.5)

### 7.6 Prompts → `PromptBuilder` (S13–S14)

Turn prompts: 7 digest families (§6.6.3), 108 framing-helper uses in the turn and review files. Tool outputs: 12 relaying tools (§6.6.5).

### 7.7 Alerts → `AlertScope` (S4): 30 call lines in 17 files; about 22 pass no `companyId` today

### 7.8 Raw file APIs (S1 baseline → S15 targets)

The agent-facing directories go to zero (§6.8.2). The rest of `BrahmaCore` keeps a shrink-only baseline. Its hits are mostly the engine's own data home: `Backup/` 48, `Extensions/` 63 (owner-chosen bundles; unzip already sandboxed), `Git/` 35 (engine repo administration). The baseline is not driven to zero (**architect's call**: these are engine-owned places; converting them buys little and risks backup/restore regressions).

## 8. Behaviour changes an owner could notice (and how each is surfaced)

| # | Change | Who sees it | Surfaced by |
|---|---|---|---|
| B1 | A check, preview, release-tool run or main smoke whose author cannot be confirmed now runs **sandboxed** in a Full company (it was unsandboxed). | Full-company owners only | Activity line on the company: "`<subject>` ran sandboxed: the engine could not confirm who wrote it (`<reason>`)". Release note. |
| B2 | The engine ceiling (`brahma run --profile`) now also narrows preview, release-tool and main-smoke routing (it already narrowed checks). | Owners using `--profile` | Release note; `brahma doctor` shows the ceiling. |
| B3 | Preview network grants for a principal set are the **intersection** of its members' grants. | Rare (multi-author previews) | A preview start that fails on a blocked domain says which grant was dropped. |
| B4 | Live diffs, `wt:` refs, smoke requests, artifact publishing, OpenAPI copies and docx/xlsx/pptx text are produced by `brahma-helper`. When it is unavailable they say "unavailable (helper: `<reason>`)" instead of working. | Everyone, only when broken | `brahma doctor` item `helper`; the CHANGES/preview text says unavailable. |
| B5 | Live-diff semantics are exactly git's (nested repositories, gitignore, attributes), where C's in-process walker differed. S10's parity test lists each difference. | Owners viewing CHANGES | Release note listing the differences. |
| B6 | Smoke and readiness requests gain the helper's start cost (measured p95 overhead ≤ 60 ms per call; one call per start or demo, not per request). | Nobody, in practice | — |
| B7 | Commit subjects, check commands, blocked reasons and review flags in digests are taint-framed when their author's session was tainted (they were only flattened). | Agents (prompt text) | Not owner-visible. Listed for reviewers. |
| B8 | Alerts that were broadcast to every company although the condition belonged to one now go to that company only. Each case is listed in the S4 commit. | Multi-company owners | Release note. |
| B9 | git, claude, unzip and tar are resolved once at engine start to absolute paths. A `PATH` change takes effect at the next engine start. | Owners who change `PATH` | `brahma doctor` "tools" line. |
| B10 | When the S8 benchmark shows the live diff of the company's largest worktree over budget, `LiveChanges` refreshes at that worktree's measured cost × 4 (at least 2 s, at most 10 s), not every 2 s. | Owners with very large worktrees | The CHANGES header shows "refreshing every N s". |

## 9. Performance budget (measured, not guessed)

### 9.1 What was measured for this spec

Machine: the owner's Mac (Apple M4 Pro, 12 cores, 24 GB, macOS 26.2, git 2.52.0 Homebrew), on 2026-11-21. Method: a Python `perf_counter` harness, 20–40 runs after 3 warm-ups. Profile: a representative 18-rule Brahma-style Seatbelt profile (home deny, read allow-list, write deny-except, link and clone denies, mach and exec denies, `(deny network*)` plus one loopback port). Raw numbers:

| Operation | p50 | p95 |
|---|---|---|
| `/usr/bin/true` direct | 1.3 ms | 1.6 ms |
| `sandbox-exec` (allow-default) `true` | 6.0 ms | 7.1 ms |
| `sandbox-exec` (Brahma-like profile) `true` | 6.7 ms | 8.6 ms |
| `brahma --help` (48 MB **debug** binary) direct | 9.9 ms | 11.9 ms |
| same, under `sandbox-exec` | 15.4 ms | 21.3 ms |
| `git status --porcelain -uall`, 10 000-file repo, direct | 32.3 ms | 40.8 ms |
| same, sandboxed | 44.0 ms | 59.3 ms |
| **The helper diff pipeline** (§6.4.4: fresh index, `read-tree`, `update-index --refresh`, `add -N --all`, one `diff --numstat -p`), 10 000 files, 6 changed, direct | 243 ms | 251 ms |
| same, sandboxed | 257 ms | 269 ms |
| Variant that writes every blob (`add -A` into a scratch object dir, no refresh) | 976 ms | 1418 ms (rejected) |
| Variant that copies the agent's index (fast, but trusts a forgeable stat cache) | 131 ms | 162 ms (rejected, §6.4.4) |

Conclusions:
- Seatbelt adds about 5–15 ms per process.
- A one-shot helper's fixed cost is about 20 ms even with a debug binary.
- The diff cost is dominated by git hashing the worktree, which any design that refuses to trust the agent's index must pay.

### 9.2 Budgets (asserted by `HelperBenchTests`, `BRAHMA_BENCH=1`, release build, S8, re-run in S10–S12)

| Metric | Budget (p95) | Measured analogue |
|---|---|---|
| `selftest` round trip (spawn, request, response, sweep, cleanup) | ≤ 60 ms | 21 ms (debug `brahma` under Seatbelt) |
| `worktreeDiff`, 10 000-file worktree, ≤ 10 changed | ≤ 400 ms | 269 ms |
| `worktreeDiff`, 1 000-file worktree | ≤ 120 ms | — (S8 measures) |
| `worktreeStatus`, 10 000 files | ≤ 150 ms | 59 ms (`status` sandboxed) |
| `loopbackHTTP` overhead beyond the server's own time, per call | ≤ 60 ms | — |
| `stageCopy` of one 20 MB file | ≤ 400 ms | — |
| `extractText` of a 5 MB docx | ≤ 2 s | — |
| Engine-side CPU per observed live diff at the 2 s cadence, 10 000 files | ≤ 15 % of one core | ≈ 13 % (269 ms / 2 s) |
| Helper peak RSS (`selftest`, `worktreeDiff` 10k) | ≤ 64 MB / ≤ 160 MB | — |

### 9.3 Limits stated

- **Concurrency.** At most 4 concurrent helpers (`HelperPool`). C5b's existing rule (≤ 1 recompute per 2 s per (item, compare)) bounds live diffs. With 4 observed 10k-file diffs, worst-case CPU is about 0.5 core.
- **Fallback for a missed budget.**
  - If the `worktreeDiff` 10k budget is missed: rule B10 (cadence = measured × 4, clamped 2–10 s). This is fixed in advance and needs no further ruling.
  - Any other missed budget stops the task and goes to the controller. A warm helper pool (F3) is the pre-designed remedy, not an in-process fallback.

## 10. Testing strategy

### 10.1 Property and fuzz tests (S15, plus S7 for policy)

Deterministic seeds, 500 cases each by default, 10 000 with `BRAHMA_FUZZ=1`:
- **Concurrent swaps.** While `SafeFS.open`, `SafeRead.smallText`, `EngineFiles.read` and `stageCopy`'s engine re-check run, a racer thread swaps each path component between a directory, a symlink (to `~`, `/`, another worktree, a protected path), a FIFO, a hard link and a deleted entry. Invariant: the result is either the original bytes or a typed refusal. Never bytes from elsewhere, never a hang (FIFO opened `O_NONBLOCK`), never a crash.
- **Huge and sparse files.** A 1 TB sparse file and a 2 GB file. Reads stop at the cap plus 1 byte, and memory stays under 2 × cap.
- **Names.** Every Unicode scalar class in components (Cf, Zl, Zp, bidi, ZWJ, NUL, `/`, `..`, 255+ bytes, NFC/NFD pairs) → `badPath` or an exact round trip.
- **Depth and fan-out.** 300-deep and 100 000-wide trees → typed caps, bounded time.
- **Policy render ≡ validate.** For random policies (generated from real temp trees with random links), `render(validate(p))` contains exactly the validated strings, and swapping links between validate and render (a test hook) cannot change the profile text.
- **Reach.** For random principal sets and places, `factory.decide` never returns a policy whose places exceed reach, never `fullOptOut` with an unknown/external/engine member, and is invariant under member order.
- **Prompt.** For random `Untrusted` strings (control, bidi, `    | ` lookalikes, fake "Untrusted content from" headers, 1 MB), `field` output is one line, `quote` output has every line prefixed, a tainted `.withhold` field never contains the input, and no rendered prompt contains an unframed newline that came from input.

### 10.2 Helper tests

- **Unit (fast, every run).** `InProcessHelperTransport` (test target only) calls `HelperServer.handle(request)` directly, with the real op code, against temp trees. Every caller's behaviour tests are re-pointed at it.
- **Failing transports.** A failing transport (`unavailable`, `timedOut`, a garbage response, an oversized response, a version mismatch, a straggler survivor) is injected per caller. Each must produce its existing refusal text and never a success-shaped result.
- **Live sandbox (macOS, `.enabled(if: Toolchain.seatbeltAvailable)`, needs the built `brahma-helper`).** The real binary runs under the real factory policy. It is denied:
  - reading `<home>/brahma.db`;
  - reading `~/.ssh` through a worktree symlink;
  - connecting to a second loopback port;
  - writing outside `out/`;
  - exec of a denied tool.

  It is allowed its op. Gated like the existing `SeatbeltRunnerTests` (`.serialized`).

### 10.3 Parity tests

- **Diff (S10):** every C1a/C1b/C2a `worktreeDiff` behaviour test passes against the helper, or has a listed git-semantics delta (B5).
- **Publish (S11):** every 4a `ArtifactTests` case passes.
- **Smoke (S9):** every `BackendAdapterTests`/`MainSmokeTests` case passes.
- **Extract (S12):** C2a `OpenRefTests` extract cases pass.
- **Digests (S13):** goldens.

### 10.4 Canary (S16)

The canary is re-run end to end:
- `brahma canary run`: model-free, then one small haiku turn per sandboxed turn shape, with `BRAHMA_LIVE=1`.
- `SandboxCanaryProbeTests`.
- New helper probes in the model-free part: the `selftest` op run under each helper purpose's policy must be denied the data home, the owner's home, other workspaces, other loopback ports and writes outside the call dir.

Results are recorded in the final task report. A canary failure blocks the merge.

## 11. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The module extraction (S3) is a large mechanical diff that conflicts with whatever lands meanwhile. | Medium | S3 is a pure move with no behaviour change, done right after S2 on a freshly merged `main`. Test count and pass set must be identical before and after (recorded). `@_exported import` avoids touching importers. |
| Seatbelt edge cases inside the helper (mach services git or unzip need; dyld reading a dev binary under `~`). | Medium | The factory adds the helper dir. The live tests and canary probes run each op under its real policy. `ToolPaths` avoids the `/usr/bin/git` xcrun shim. Measured in §9.1: git works under a Brahma-like profile once the common dir is readable. |
| Helper latency or CPU at scale. | Low–medium | Measured (§9.1); budgets asserted (§9.2); pre-decided fallback B10; warm pool F3. |
| Git-semantics deltas versus C's walker surprise a reviewer (nested repos, ignored files). | Medium | Listed parity deltas, each a recorded ruling. Security invariants (no hidden change from a forged index, nothing outside the worktree, caps) are pinned separately. |
| A `whenTainted:` choice made wrongly while migrating digests. | Medium | Goldens plus a hostile fixture. `.frame` is the default when unsure (**architect's call**). `.withhold` only where 4a/C already withhold. |
| A wrong `AlertScope` verdict silences an engine-wide alert in other companies. | Low | Engine-wide reasons are a named enum. A reviewer checks each call's verdict, listed in the commit. A test pins that every `EngineHold` reason raises `.allCompanies`. |
| Owner-visible regressions in Full companies (B1). | Low | Only unknown-principal cases change, and each says so in the activity feed. |
| Plan S grows into a rewrite. | Medium | Non-goals (§3) and fixed task scopes. "While here" refactors are banned (Global Constraints in the plan). |
| C is cut per the analysis (C4c, C5b deferred) before Plan S starts. | Medium | S1 records which C shapes exist. S10 migrates whichever `worktreeDiff` callers exist. A C5b that lands later must use the helper (lint `dirWalk`/`spawn`). |

## 12. Follow-ups (not in Plan S)

- **F1.** `commitAll`/`stage` through the helper, importing a pack (Owner question 1).
- **F2.** Deployed-site smoke through the helper with TLS through the egress proxy (Owner question 3).
- **F3.** A warm per-principal helper pool, only if a budget fails.
- **F4.** `CompanyScope` for Store writes (analysis #6, second half).
- **F5.** Remaining raw file APIs in the engine-owned areas (Backup, Extensions).
- **F6.** Moving turn scopes (`SandboxScope.forTurn`) under the factory.
- **F7.** A separate macOS user for agents (analysis #11). The helper's design carries over unchanged.

## 13. Dependencies and ordering

- **Starts only when** 4a and C are both merged to `main` and `main` is green. Plan S runs on a branch from that `main`.
- **S1 is the re-baseline.** It records the shipped names and counts, which later tasks treat as authoritative over this spec's C-tree counts.
- **Parallel lane.** S13–S14 (prompts) are independent of S8–S12 (helper) and may run as a parallel lane. Everything else is sequential: S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9 → S10 → S11 → S12 → S15 → S16.
- **4b and dogfood.** Plan S must merge before the dogfood run. A 4b lane that lands meanwhile must pass `SafetyLintTests`. The baseline is not raised for it without a controller ruling.
