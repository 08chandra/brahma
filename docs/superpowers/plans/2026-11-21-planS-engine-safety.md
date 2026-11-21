# Plan S — Engine Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution:** this plan runs **subagent-driven** (owner decision), on a branch cut from `main` **after Plans 4a and C are both merged and `main` is green**. Tasks that touch sandbox, helper, principal, taint, path or prompt code are security-touching: their reviews run on opus (high), and the final review runs on opus.

**Goal:** Engine actions on agent-controlled data run in a sandboxed `brahma-helper` under the subject principal's limits. One principal model and one policy factory decide every Seatbelt policy, and unknown means most restricted. Prompts are built only from typed trusted and untrusted parts. File access, spawning and sandboxing live in one `BrahmaSafety` module, and a lint bans raw APIs elsewhere. Default-deny types replace the fail-open booleans and optionals.

**Architecture:** A new SwiftPM target `BrahmaSafety` (no `Store`, no GRDB) holds:
- the path layer (`EngineFiles`, `SafeFS`, `SafeRead`, `SandboxPath`, `Place`);
- spawning (`Spawn`, `ToolPaths`, `GroupRun`);
- the Seatbelt runtime (`SeatbeltRunner`, `SeatbeltProfile` over `ValidatedPolicy`);
- `SandboxPolicyFactory` with the value types `Principal`/`PrincipalSet`/`Purpose`;
- typed prompt text (`Trusted`, `Untrusted`, `PromptBuilder`, `RenderedPrompt`, `ToolOutput`);
- the helper protocol, server and client.

`BrahmaCore` re-exports it (`@_exported import BrahmaSafety`) and keeps `PrincipalResolver`, which reads `Store`. A new executable `brahma-helper`, which depends only on `BrahmaSafety`, runs one operation per process under `sandbox-exec`. Its stdin and stdout are JSON, and bulk output goes to a per-call directory that the engine reads only after the sandbox sweep proves the call quiescent.

**Tech Stack:** Swift 6.2 toolchain (manifest `swift-tools-version: 6.0`), SwiftPM, GRDB.swift 7.x (BrahmaCore only), swift-argument-parser 1.5+, Swift Testing, `/usr/bin/sandbox-exec`, git ≥ 2.43 (resolved absolute), `/usr/bin/unzip`.

**Spec (authoritative):** `docs/superpowers/specs/2026-11-21-engine-safety-design.md` (cited as "spec §n"). It argues from `docs/superpowers/specs/2026-11-21-design-analysis-input.md`. Read both before Task S1. Decisions marked "(architect's call)" in the spec are binding. Changing one needs a controller ruling.

**Owner decisions, 2026-11-21 (spec, top section):**
1. 3a's submit and auto-commit staging moves into the helper (Task S10b).
2. **All** MCP tool outputs are typed. A temporary legacy shim exists between S14a and S14b only, and S14b deletes it.
3. Deployed-site smoke moves into the helper (Task S9b).
4. With no Seatbelt available, helper-backed features say "unavailable".

## Global Constraints

Copied from Plans 3a, 5-lite, 4a and C (as amended) and still binding, except where Plan S amends them (marked **S**):
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The manifest stays `swift-tools-version: 6.0` and `.macOS(.v14)`.
- `BrahmaCore` **and `BrahmaSafety`** stay Linux-portable. Neither may use AppKit, SwiftUI, Observation, UserNotifications, CryptoKit or `Bundle.module`. Darwin-only APIs sit behind `#if canImport(Darwin)`. Security-framework code sits only inside `#if canImport(Security)`.
- **S:** Child processes are started only by `BrahmaSafety.Spawn`, with an absolute executable from `ToolPaths`. Never use `/usr/bin/env` and never inherit `PATH` lookup. This amends the old "`git` (via `/usr/bin/env git`) is fine" rule.
- **Every engine git call uses 3a's hardened `GitCommand`.** **S:** its flags and environment come from `BrahmaSafety.GitHardening`, and its executable from `ToolPaths.git`. The engine's own git never runs with an agent place as `cwd`.
- **S:** Every Seatbelt policy comes from `SandboxPolicyFactory.decide`. `SandboxPolicy.init` is internal to `BrahmaSafety`.
- **S:** Every action that runs agent code or reads agent places resolves its subject principals exactly once with `PrincipalResolver.resolve(_:)` and passes the `PrincipalSet` down. Nothing below that point re-reads leases or roles.
- **S:** An operation on agent-controlled data that spec §6.4.1 assigns to the helper goes through `HelperClient`. There is no in-process fallback, and a helper error maps to the caller's existing refusal text, never to an empty or "ok" result.
- **S:** `try?`, `?? true`, `?? false` and empty `catch {}` are banned in `Sources/BrahmaSafety` and `Sources/BrahmaCore/Principal`. Use `bestEffort(_ what: StaticString, _ body: () throws -> Void)` for logged cleanup.
- **S:** `EngineAlerts.raise` takes a required `scope: AlertScope`.
- **S:** Turn prompts, system prompts and tool results are `RenderedPrompt`/`ToolOutput`. Only `PromptBuilder` produces them. `Trusted` interpolation accepts `Int`, `Trusted` and `TrustedToken` only.
- Agent-controlled text printed by the CLI goes through `safe()`. In the app it uses `Text(verbatim:)` or `SafeMarkdown`. In prompts, single-line fields are newline-flattened, and multi-line fields are a block with every line prefixed `    | `. **S:** the renderer does this.
- Every turn and every check runs with `BRAHMA_AGENT_ID=<agent id>`, without `BRAHMA_DEV`, and with an allowlisted environment (`ChildEnvironment`). **S:** the helper's environment is `HelperEnv.make(callDir:)` only.
- **Engine files under `<ws>/.brahma/` go through `EngineFiles`.** Agent-named paths go through `SafeFS`. An `UnsafeEngineFile` is a refusal, never a retry.
- Every lookup has `WHERE companyId = ?`. Cross-company ids are refused as not found.
- Durations use company-active seconds. Timeouts use `AwakeTime`.
- No test touches the Keychain (`NoKeychainTests` stays green). Live model tests run only with `BRAHMA_LIVE=1` and use `haiku`.
- Tests use Swift Testing, with one `@Suite struct <FileName>` per new test file. Tests that spawn real Seatbelt processes use `.enabled(if: Toolchain.seatbeltAvailable)` and `.serialized`.
- **No behaviour change outside spec §8.** A changed golden, snapshot or refusal text must name its spec §8 row (B1–B10) in the commit message.
- **Fail-closed tests are never weakened.** A test that pins a refusal may be re-pointed (new type, helper transport) but must still assert a refusal.
- **No "while here" refactors.** Do only what the task lists. Moves are pure moves.
- Every task ends with `swift build` green for all targets and a full `swift test` run. Known flakes: `peopleOptional`, `PreviewSupervisionTests.stopKillsProcessGroup`, `BackupTargetTests.stalePidHandled`, `staleMemoryResultsDropped`, `MapControllerTests`, `ScratchHygieneTests.noStaleRootsAfterTheStartupSweep`, `LiveCLITests.devHostServesOnlyItsFolderAndGrantsOnlyTheCopy`. Each must pass when rerun alone. Never run two worktrees' full suites at once.
- Every commit message ends with:
  `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`

**Pinned numbers** (each a `static let` on the owning type):

| Constant | Value | Owner |
|---|---|---|
| Protocol version | 1 | `HelperProtocol.version` |
| Request / response / stderr caps | 64 KiB / 256 KiB / 16 KiB | `HelperProtocol.maxRequest`, `.maxResponse`, `.maxStderr` |
| Concurrent helpers · wait | 4 · 30 s then `.busy` | `HelperPool.slots`, `.maxWait` |
| Kill grace | 1 s of awake time | `HelperClient.termGrace` |
| rlimits | CPU = op time + 5 s · FSIZE per op · NOFILE 256 · CORE 0 | `HelperLimits` |
| Stale call dirs removed at start | older than 3600 s | `HelperClient.staleAfter` |
| `worktreeDiff` | 10 s · ≤ 2000 changed paths · ≤ 100 000 untracked considered · patch ≤ 5000 lines · git output ≤ 8 MiB · index ≤ 64 MiB · FSIZE 64 MiB | `HelperLimits.worktreeDiff` |
| `worktreeStatus` | 10 s · output ≤ 1 MiB | `HelperLimits.worktreeStatus` |
| `loopbackHTTP` | ≤ 20 requests · 10 s each · ≤ 210 s per call · request body ≤ 64 KiB · headers ≤ 16 KiB · body read ≤ 4 × `SmokeRequest.bodyKept` | `HelperLimits.loopbackHTTP` |
| `stageCopy` | 60 s · ≤ 2000 entries · depth ≤ 32 · 4a `ArtifactPolicy` caps · OpenAPI ≤ 2 MiB | `HelperLimits.stageCopy` |
| `extractText` | 30 s · `ArchiveLimits` (200 MiB, ratio 100) · text ≤ 2 MiB | `HelperLimits.extractText` |
| `worktreeCommit` | 60 s · 3a's `stage` caps as shipped (S1 records them) · ≤ 2000 changed paths · changed bytes ≤ 200 MiB · pack ≤ 256 MiB · FSIZE = 3a's per-file cap | `HelperLimits.worktreeCommit` |
| `httpsProbe` | ≤ 20 requests per round · 10 s each · ≤ 210 s per call · body read ≤ 64 KiB · headers ≤ 16 KiB · https only · no redirects | `HelperLimits.httpsProbe` |
| `selftest` | 5 s | `HelperLimits.selftest` |
| `SafeRead.smallText` default limit | 4096 bytes | `SafeRead.defaultLimit` |
| Budgets (p95, release build) | selftest ≤ 60 ms · diff 10k ≤ 400 ms · diff 1k ≤ 120 ms · status 10k ≤ 150 ms · HTTP overhead ≤ 60 ms · stage 20 MB ≤ 400 ms · commit 10k/10 changed ≤ 600 ms · https overhead ≤ 80 ms per round · extract 5 MB docx ≤ 2 s · RSS selftest ≤ 64 MB, diff ≤ 160 MB | `HelperBudgets` |
| Live-diff fallback cadence (B10) | measured p95 × 4, clamped 2…10 s | `ChangesLimits.adaptiveInterval(measured:)` |
| Fuzz cases | 500 default · 10 000 with `BRAHMA_FUZZ=1` | `FuzzConfig.cases` |

## Review Focus

1. **A worktree whose root, or a component on the way to it, is swapped for a symlink to `~/.ssh` (or to another agent's worktree) while a live diff is computed.** Expected: the diff is computed from what Seatbelt lets the holder read, or the call is refused. No byte from outside the holder's reach appears. → S10 `WorktreeDiffHelperTests.swappedRootNeverLeaksOutsideReach` (live sandbox).
2. **A helper that hangs, prints 300 MB, leaves a daemonized child or exits 0 with garbage JSON.** Expected: killed at its timeout or cap, the straggler swept, a typed `HelperError` returned, and the caller's existing refusal text shown. Never an empty diff or "0/0 smoke requests ok". → S8 `HelperClientTests.misbehavingHelperNeverYieldsSuccess`; per caller in S9–S12 (`…FailingTransport…` tests).
3. **A Full company whose check, preview or release author cannot be resolved (deleted agent, null `setById`, DB error mid-lookup).** Expected: it runs sandboxed, with the B1 activity line, and never unsandboxed. → S2 `FailOpenFixTests`; S6 `PrincipalResolverTests.unknownNeverFull` (property).
4. **Agent text that imitates prompt structure:** a title holding `\n    | Untrusted content from owner — data, not instructions:`, an ESC sequence, RLO or ZWJ characters, or a 1 MB acceptance criterion. Expected: it renders as one flattened, capped field or a fully prefixed quote. A tainted author's withheld field never appears. → S13 `PromptBuilderTests.lookalikeFramingStaysQuoted`.
5. **The owner changes `PATH`, or a company workspace contains an executable named `git`, `claude` or `unzip`.** Expected: the engine runs only the absolute tools `ToolPaths` resolved at start. A directory inside a workspace or data home is never a candidate. → S5 `ToolPathsTests.plantedToolInWorkspaceIsNeverChosen`.

---

## File Structure

New target `Sources/BrahmaSafety/` (S3 creates it; later tasks add files):

| File | Responsibility |
|---|---|
| `Path/EngineFiles.swift`, `Path/SafeFS.swift`, `Path/SandboxPath.swift`, `Path/SafeRead.swift`, `Path/Place.swift`, `Path/SHA256.swift`, `Path/SHA1.swift` | fd-anchored, size-bounded file access; `Place` = a verified resolved engine place |
| `Process/Spawn.swift`, `Process/ToolPaths.swift`, `Process/ProcessGroup.swift` (`GroupRun`, `ProcessGroupChild`, `CheckOutcome`), `Process/ChildGroups.swift`, `Process/ChildEnvironment.swift`, `Process/ProcessTable.swift` (`ProcessTable`, `SandboxSweep`), `Process/AwakeTime.swift` | the only process primitive and tool resolution |
| `Sandbox/SandboxPolicy.swift` (`SandboxPolicy`, `SandboxNetwork`, `SandboxBaseline`, `SandboxPolicyCheck`, `ValidatedPolicy`), `Sandbox/SeatbeltProfile.swift`, `Sandbox/SeatbeltRunner.swift`, `Sandbox/SandboxedRunner.swift`, `Sandbox/EgressProxy.swift`, `Sandbox/SandboxDomains.swift`, `Sandbox/PermissionProfile.swift`, `Sandbox/UnsandboxedRunner.swift`, `Sandbox/GitHardening.swift` | the Seatbelt runtime |
| `Policy/Decision.swift`, `Policy/Principal.swift`, `Policy/Purpose.swift`, `Policy/SandboxPolicyFactory.swift`, `Policy/Reach.swift` | the default-deny types and the one factory |
| `Prompt/Trusted.swift`, `Prompt/Untrusted.swift`, `Prompt/PromptBuilder.swift`, `Prompt/UntrustedBlock.swift` | typed prompt text |
| `Helper/HelperProtocol.swift`, `Helper/HelperServer.swift`, `Helper/HelperClient.swift`, `Helper/HelperPool.swift`, `Helper/HelperBinary.swift`, `Helper/Ops/*.swift` (`WorktreeDiffOp`, `WorktreeStatusOp`, `LoopbackHTTPOp`, `StageCopyOp`, `ExtractTextOp`, `SelftestOp`), `Helper/LoopbackHTTP.swift` | the helper |

Other new code:
- `Sources/brahma-helper/main.swift` is the executable: about 30 lines that call `HelperServer.main()`.
- `Sources/BrahmaCore/Principal/PrincipalResolver.swift`, `Principal/ActionSubject.swift`, `Principal/AlertScope.swift`.
- `Tests/BrahmaSafetyTests/` holds kernel unit, property and fuzz tests.
- `Tests/BrahmaCoreTests/SafetyLintTests.swift` and `Tests/BrahmaCoreTests/Fixtures/safety-lint-baseline.json`.
- `Tests/BrahmaCoreTests/InProcessHelperTransport.swift` is test-only.

---

### Task S1: Re-baseline on merged `main` and the safety lint

Plan S's first commit changes no product code. It records the shipped names and counts, and it freezes the spread of raw APIs.

**Files:**
- Create: `Tests/BrahmaCoreTests/SafetyLintTests.swift`, `Tests/BrahmaCoreTests/Fixtures/safety-lint-baseline.json`
- Modify: `docs/superpowers/specs/2026-11-21-engine-safety-design.md` (append §14 "Re-baseline on merged main": the measured counts for every §7 family, the renames, which C shapes exist, such as whether C5b's `LiveChanges` merged, and the confirmed relaying-tool list of §6.6.5)

**Interfaces:**
- Produces:
  - `SafetyLint.Rule` (enum: `spawn, sandboxPolicy, descriptor, fileAPI, dirWalk, loopbackHTTP, failOpen, alertScope, turnScope`), each with a regex and a scope (`zero` dirs, `baseline` elsewhere).
  - `SafetyLint.scan(root:) -> [Rule: [String: Int]]` (file → count, comments blanked with `EngineGitGuardTests.code`).
  - The baseline JSON shape `{ "<rule>": { "<path>": <count> } }`.
  - Later tasks lower counts. They never raise one without a controller ruling recorded in the commit.

- [ ] **Step 1: Write the failing lint tests.**
  - `@Test func noRuleExceedsBaseline()`: for every rule and file, `count <= baseline[rule][file] ?? 0`. The failure message names the file:line hits.
  - `@Test func baselineHasNoSlack()`: `count == baseline` for every entry. On a shrink it prints the JSON to paste and fails, so shrinking is sticky.
  - `@Test func zeroScopesAreZero()`: rules whose `zero` scope list is non-empty have no hits there. In S1 the zero scopes are empty; S7, S9–S12 and S15 fill them.
  - `@Test func scanFindsKnownSites()`: sanity checks that the scan is live: `spawn` finds `Sources/BrahmaCore/Git/GitWorkspace.swift`, `sandboxPolicy` finds `Sandbox/SandboxedCheckRunner.swift`, and `alertScope` finds ≥ 17 files. The pattern then fails loudly if it rots.
- [ ] **Step 2: Run it and confirm the expected failure.** Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SafetyLintTests`. Expected: FAIL. The baseline file is missing.
- [ ] **Step 3: Generate the baseline from the scan and check it in.** Write the regexes exactly as spec §6.8.2 lists them. `alertScope` matches `EngineAlerts.raise(` calls whose argument list, up to the matching `)`, has no `scope:`.
- [ ] **Step 4: Run it and confirm it passes.** Same command. Expected: PASS, 4 tests.
- [ ] **Step 5: Re-run the spec §7 greps on merged `main` and record them in spec §14.** The greps: `SandboxPolicy(`, `EngineAlerts.raise(`, spawn lines, `worktreeDiff(`, `isDirty(in`, `http.send`, `TextExtract.extract`, framing helpers per file, `try?` in Sandbox and Safety. If any family differs from the spec's count by more than 20 %, stop and report to the controller before S2.
- [ ] **Step 6: Full suite, then commit.** Run `swift build` and `swift test`. Commit with `git add Tests/BrahmaCoreTests/SafetyLintTests.swift Tests/BrahmaCoreTests/Fixtures/safety-lint-baseline.json docs/superpowers/specs/2026-11-21-engine-safety-design.md && git commit -m "test(core): safety lint with a shrink-only baseline; Plan S re-baseline on merged main"`.

---

### Task S2: Close the known fail-opens

**Files:**
- Create: `Sources/BrahmaCore/Util/SafeRead.swift` (S3 moves it), `Tests/BrahmaCoreTests/FailOpenFixTests.swift`, `Tests/BrahmaCoreTests/SafeReadTests.swift`
- Modify: `Sources/BrahmaCore/Sandbox/SandboxedCheckRunner.swift` (the VerificationRun branch of `checkRoute`), `Sources/BrahmaCore/Preview/PreviewRunner.swift` (`unsandboxed(store:company:setById:)` gains `ceiling:`), `Sources/BrahmaCore/Release/ReleaseExecutor.swift:355`, `Sources/BrahmaCore/Store/Store+Release.swift:258`, `Sources/BrahmaCore/Git/GitWorkspace.swift` (`regularText` and its 6 uses)

**Interfaces:**
- Produces:
  - `public enum SafeRead { static let defaultLimit = 4096; static func smallText(_ relative: String, under root: URL, limit: Int = defaultLimit) throws -> String }`.
  - `SafeReadError { linked, notRegular, multiplyLinked, notOwned, tooLarge(Int), notUTF8, io(String) }`. The root is engine-resolved. Each component is opened `O_NOFOLLOW` from the root, then `fstat` checks regular, `st_nlink == 1`, owner == `getuid()` and size ≤ limit. It reads at most `limit + 1` bytes.
  - `static func sandboxedNote(subject: String, reason: String) -> String`, which returns `"\(subject) ran sandboxed: the engine could not confirm who wrote it (\(reason))"`. This is the B1 text.

- [ ] **Step 1: Write the failing tests.**
  - `FailOpenFixTests.verificationRunWithUnknownHolderRunsSandboxed`: a Full company, a running submit `VerificationRun` with no lease and a `requestedBy` of an agent id that does not exist → `checkRoute(...)` returns `.sandboxed`. One `ActivityEvent` contains `"ran sandboxed: the engine could not confirm who wrote it"`.
  - `FailOpenFixTests.verificationRunWithLookupErrorRunsSandboxed`: inject a store whose `agent(id:)` throws (use the existing failing-store seam, else a closed database) → `.sandboxed`.
  - `FailOpenFixTests.previewWithNilSetterInFullCompanyIsSandboxed`: `PreviewRunner.unsandboxed(store:company:setById: nil, ceiling: nil) == false`.
  - `FailOpenFixTests.previewHonoursCeiling`: Full company, Full role, `ceiling: .sandboxed` → `false`.
  - `FailOpenFixTests.ownerSetterStillFollowsCompany`: `setById: "owner"` in a Full company → `true`. This is unchanged behaviour.
  - `FailOpenFixTests.knownFullHolderStillUnsandboxed`: unchanged.
  - `SafeReadTests.swappedLinkIsRefused`: the target is a symlink to a 1 GB sparse file → `SafeReadError.linked`.
  - `SafeReadTests.oversizedIsRefused`: 4097 bytes → `.tooLarge(4096)`.
  - `SafeReadTests.fifoDoesNotHang`: returns `.notRegular` within 1 s.
  - `SafeReadTests.hardLinkRefused`: `.multiplyLinked`.
  - `GitWorkspaceTests.linkedDotGitIsReportedChanged`: replace a worktree's `.git` file with a symlink to a valid-looking pointer → `linkProblems` contains `".git was changed"`.
- [ ] **Step 2: Run them and confirm they fail.** Run: `swift test --filter "FailOpenFixTests|SafeReadTests|GitWorkspaceTests/linkedDotGit"`. Expected: FAIL.
- [ ] **Step 3: Implement the fixes.**
  - `checkRoute`'s VerificationRun branch uses `do`/`catch`. Any thrown lookup, a nil holder, or a nil role → fall through to the sandboxed policy and append the B1 activity line. Use `run.companyId` and `subject` = the item key.
  - `PreviewRunner.unsandboxed` returns `false` for a nil `setById`, a thrown lookup or a missing agent. It applies `ceiling` with `PermissionProfile.narrower`.
  - Thread the orchestrator's `profileCeiling` to all 3 callers.
  - `regularText` becomes `SafeRead.smallText(name, under: dir)` mapped to `String?`. Every error → nil, which `linkProblems` already reports as changed.
- [ ] **Step 4: Run the focused tests, then the full suite.** Expected: PASS. Every existing `SandboxedCheckTests` and merge-run test passes unchanged.
- [ ] **Step 5: Lower the lint baseline.** `fileAPI` drops by 1 in `GitWorkspace.swift`.
- [ ] **Step 6: Commit.** `git commit -m "fix(core): unknown check/preview authors run sandboxed (B1, B2); bounded no-follow .git pointer reads"`

---

### Task S3: Extract the `BrahmaSafety` target (pure move)

**Files:**
- Modify: `Package.swift`. Add `.target(name: "BrahmaSafety", dependencies: ["CSandboxCheck"])`, but only if a moved file imports it; otherwise no dependencies. `BrahmaCore` depends on `BrahmaSafety`. Add `.testTarget(name: "BrahmaSafetyTests", dependencies: ["BrahmaSafety"])`.
- Move (via `git mv`, splitting files where the spec §6.8.1 table says "out of"):
  - `Util/EngineFiles.swift`, `Refs/SafeFS.swift`, `Util/SafeRead.swift`, `Util/SHA256.swift`, `Util/SHA1.swift`, `Util/AwakeTime.swift` → `Path/` and `Process/`;
  - `SandboxPath`, `resolvedForSandbox`, `IdentityRoots`, `checkAllowed`, `SandboxDomains`, `SandboxError`, `ProtectedPaths` out of `Sandbox/SandboxScope.swift`;
  - `PermissionProfile` out of `Turns/ClaudeCommand.swift`;
  - `ChildEnvironment` out of `Turns/TurnProfile.swift`;
  - `ProcessTable`, `SandboxSweep` out of `Turns/TurnProcess.swift`;
  - `CheckOutcome` out of `Verify/CheckRunner.swift`;
  - `Verify/ProcessGroup.swift`, `Safety/ChildGroups.swift`;
  - `Sandbox/SandboxedRunner.swift`, `SeatbeltProfile.swift`, `SeatbeltRunner.swift`, `EgressProxy.swift`;
  - `UnsandboxedPreviewRunner` out of `Preview/PreviewRunner.swift`;
  - `UntrustedBlock` out of `Safety/Taint.swift`;
  - `GitCommand`'s flag and environment constants out of `Git/GitWorkspace.swift` into `Sandbox/GitHardening.swift`.
- Create: `Sources/BrahmaCore/Exports.swift` (`@_exported import BrahmaSafety`), `Tests/BrahmaSafetyTests/KernelBoundaryTests.swift`

**Interfaces:**
- Produces: the same names, now in module `BrahmaSafety`. Whatever `BrahmaCore` uses becomes `public`. Make nothing else public.
  - `GitHardening.flags: [String]` (exactly 3a's `-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -c diff.external= -c protocol.ext.allow=never` as shipped).
  - `GitHardening.environment: [String: String]` (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1` as shipped).
- Tests that use moved internals add `@testable import BrahmaSafety`.

- [ ] **Step 1: Record the pre-move suite.** Run `swift test 2>&1 | tee .superpowers/sdd/<plan>/task-S3-before.txt`. Record the test count and the failures.
- [ ] **Step 2: Write `KernelBoundaryTests`.**
  - `@Test func kernelImportsNoEngine()`: no file under `Sources/BrahmaSafety` contains `import GRDB`, `Store`, `Orchestrator`, `Company(` or `Agent(`.
  - `@Test func helperDependsOnlyOnKernel()`: `Package.swift`'s `brahma-helper` target lists only `BrahmaSafety`. This test is added now and enabled in S8.
- [ ] **Step 3: Move the code.** Do the moves and splits. Fix access levels to the minimum public surface. Keep every doc comment with its code.
- [ ] **Step 4: Build all targets.** Run `swift build`. Expected: green, with no new warnings in the moved files.
- [ ] **Step 5: Run the full suite and compare.** The test count and the passing set must equal Step 1 (flakes rerun alone). Record the result in `task-S3-after.txt`.
- [ ] **Step 6: Update the lint.**
  - Scope it to `Sources/BrahmaCore` and `Sources/brahma`, now that the kernel lives elsewhere.
  - Regenerate the baseline. Counts may only fall.
  - Mark `spawn` zero-scope for `Sources/BrahmaCore/Verify` and `Sources/BrahmaCore/Sandbox`.
- [ ] **Step 7: Commit.** `git commit -m "refactor: extract BrahmaSafety (path, process, sandbox kernel); pure move, BrahmaCore re-exports it"`

---

### Task S4: Default-deny shapes — `Decision`, `AlertScope` and no fail-open in the kernel

**Files:**
- Create: `Sources/BrahmaSafety/Policy/Decision.swift`, `Sources/BrahmaCore/Principal/AlertScope.swift`, `Tests/BrahmaSafetyTests/DecisionTests.swift`, `Tests/BrahmaCoreTests/AlertScopeTests.swift`
- Modify:
  - `Sources/BrahmaCore/Engine/EngineAlerts.swift`;
  - the 30 call lines in 17 files (exact list from S1's §14);
  - every `try?`, `?? true` and `?? false` in `Sources/BrahmaSafety` (45 in the moved Sandbox and Safety code per the spec; S1 has the exact number);
  - `SafetyLintTests` (`failOpen` zero in `Sources/BrahmaSafety`, `alertScope` zero).

**Interfaces:**
- Produces:
  - `public enum Decision<Allowed: Sendable>: Sendable { case allow(Allowed, because: String); case deny(String) }`. No `Bool` accessor.
  - `public func bestEffort(_ what: StaticString, _ body: () throws -> Void)`. It logs `brahma: best-effort <what> failed: <error>` to stderr and swallows the error. Use it only for cleanup.
  - `public enum GlobalAlert: String, Sendable, CaseIterable { case engineHold, sandboxCheck, engineFile, doctor, secrets, cli }`.
  - `public enum AlertScope: Sendable, Equatable { case company(String); case allCompanies(GlobalAlert) }`.
  - `EngineAlerts.raise(store:db:text:now:reason:scope:)` and `raise(store:text:now:reason:scope:)`. `scope` has no default. `.company(id)` files into that company only, and an unknown id throws `WorkError.notFound`.

- [ ] **Step 1: Write the failing tests.**
  - `AlertScopeTests.companyScopeTouchesOneCompany`: two companies, `.company(a)` → a DM, an activity line and an ask in `a` only.
  - `AlertScopeTests.allCompaniesReachesEvery`.
  - `AlertScopeTests.everyHoldReasonIsGlobal`: for every `HoldReason`, the alert raised by `Store.setHold` uses `.allCompanies`.
  - `AlertScopeTests.unknownCompanyThrows`.
  - `DecisionTests.denyHasNoBoolCoercion`: a compile-time check. Write `let _: Bool = decision` inside an `#if false` block, plus a runtime `switch` that must be exhaustive.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL to compile, because `scope:` does not exist yet.
- [ ] **Step 3: Implement `AlertScope` and migrate every call.** For each call that passed no `companyId`, decide `.allCompanies(<reason>)` only when the condition is engine-wide: the engine hold, the canary, an engine file, doctor, secrets or the CLI. Otherwise use `.company(...)`. List every call with its verdict in the commit body. A broadcast that becomes company-scoped is a B8 delta.
- [ ] **Step 4: Rewrite the kernel's fail-opens.**
  - Each `try?`, `?? true` or `?? false` in `Sources/BrahmaSafety` becomes one of:
    - (a) `throw` or a refusal on a decision path;
    - (b) `SandboxBaseline.problem` or another reported problem;
    - (c) `bestEffort("…") { … }` for cleanup.
  - No decision-path site may become (c). Reviewers check each one against this rule.
- [ ] **Step 5: Run the focused and full suite.** Run `swift test --filter "AlertScopeTests|DecisionTests|SafetyLintTests"`, then the full suite. Expected: PASS, and every existing alert test passes, re-pointed to `scope:`.
- [ ] **Step 6: Commit.** `git commit -m "feat(core,safety): required AlertScope, Decision, no try?/?? true in the kernel (B8)"`

---

### Task S5: `Spawn` and `ToolPaths` — absolute tools, no `/usr/bin/env`

**Files:**
- Create: `Sources/BrahmaSafety/Process/Spawn.swift`, `Process/ToolPaths.swift`, `Tests/BrahmaSafetyTests/ToolPathsTests.swift`, `Tests/BrahmaSafetyTests/SpawnTests.swift`
- Modify:
  - `Sources/BrahmaCore/Git/GitWorkspace.swift`: the version probes (`:185-214`), `runOnce` (`:395`), the grouped run (`:430`), `tar` (`:2236`);
  - `Sources/BrahmaCore/Turns/TurnRunner.swift:163-167, 246`;
  - `Sources/BrahmaCore/Engine/Doctor.swift:390` (adds the doctor item `tools`);
  - `Sources/BrahmaSafety/Process/ProcessGroup.swift` (`GroupRun` calls `Spawn`);
  - `Sources/BrahmaCore/Orchestrator.swift` (resolve `ToolPaths` once at init and pass it down);
  - `SafetyLintTests` (`spawn` zero across `Sources/BrahmaCore` and `Sources/brahma`; `ClaudeSettings.swift`'s shell-prefix script text allowlisted with reason "script text, not a spawn").

**Interfaces:**
- Produces:
  - `public struct ToolPaths: Sendable, Equatable { public let git: String; public let claude: String?; public let unzip: String; public let tar: String; public let curl: String /* prefers /usr/bin/curl */; public let sh: String; public let sandboxExec: String; public let gitVersion: String }`
  - `public static func resolve(path: String, forbiddenRoots: [URL], xcrunFind: (String) -> String?) -> Result<ToolPaths, ToolPathsError>`.
    - Candidate directories: the absolute `PATH` entries that exist and are owned by root or `getuid()`, are not group- or world-writable, and are not inside a `forbiddenRoots` entry (company workspaces, data homes), judged by `SandboxPath.isInside` on resolved paths.
    - `/usr/bin/git` → `xcrunFind("git")`.
    - git must be ≥ 2.43.
  - `public static var gitCandidates: Set<String>`: the resolved git path, shared with the helper.
  - `public enum Spawn { static func run(_ exe: String, _ args: [String], cwd: URL, env: [String: String], stdin: Spawn.Input, timeout: Duration, outputCap: Int, group: Bool) throws -> Spawn.Output; static func start(...) throws -> any SandboxedProcess }`.
    - It precondition-checks that `exe` is absolute.
    - `env["PATH"]` is sanitized (relative and empty entries dropped).
    - argv[0] = `exe`.
  - `ToolPathsError { gitMissing, gitTooOld(String), claudeMissing }`. `claude` missing is allowed for the CLI. The orchestrator requires it.

- [ ] **Step 1: Write the failing tests.**
  - `ToolPathsTests.plantedToolInWorkspaceIsNeverChosen`: `PATH = "<ws>/bin:/usr/bin"`, with an executable `git` in `<ws>/bin` and `<ws>` in `forbiddenRoots` → the chosen git is not under `<ws>`.
  - `ToolPathsTests.relativeAndEmptyEntriesIgnored`: `PATH = ".::bin:/usr/bin"`.
  - `ToolPathsTests.worldWritableDirIgnored`.
  - `ToolPathsTests.shimResolvedToRealGit`: an injected `xcrunFind` returns `/x/real/git`.
  - `SpawnTests.relativeExecutableIsAProgrammingError`: tested through `Spawn.validate` returning `.deny`.
  - `SpawnTests.childPathIsSanitized`: spawn `/usr/bin/env` with `PATH=.:/usr/bin` and print `PATH` → `/usr/bin`.
  - `GitWorkspaceTests.engineGitNeverUsesAgentCwd`: a test runner seam records `cwd` for every git run during `addWorktree`, `commitAll`, `isDirty` and `diff`. None is under `.brahma/wt/`.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL.
- [ ] **Step 3: Implement `ToolPaths` and `Spawn`, then migrate the sites.**
  - `GitCommand` runs `ToolPaths.git` with `cwd` = the repository's common dir and `GIT_DIR`/`GIT_WORK_TREE` from engine records, as today.
  - `TurnRunner` uses `ToolPaths.claude` when the configured path is a bare name.
  - `brahma doctor` prints `tools: git <path> <version> · claude <path> · unzip <path> · tar <path>` (B9).
- [ ] **Step 4: Run the focused tests and the full suite.** Expected: PASS, and the lint's `spawn` rule is zero.
- [ ] **Step 5: Commit.** `git commit -m "feat(safety): Spawn + ToolPaths; engine tools by absolute path, never /usr/bin/env or an agent cwd (B9)"`

---

### Task S6: The principal model and `PrincipalResolver`

**Files:**
- Create: `Sources/BrahmaSafety/Policy/Principal.swift`, `Sources/BrahmaCore/Principal/ActionSubject.swift`, `Sources/BrahmaCore/Principal/PrincipalResolver.swift`, `Tests/BrahmaSafetyTests/PrincipalSetTests.swift`, `Tests/BrahmaCoreTests/PrincipalResolverTests.swift`
- Modify:
  - `Sources/BrahmaCore/Sandbox/SandboxedCheckRunner.swift` (both branches of `checkRoute` call `resolver.resolve` once; the full/sandboxed choice uses `principals.allFull && principals.ownerProfile == .full`);
  - `Sources/BrahmaCore/Preview/PreviewRunner.swift` (remove `unsandboxed(store:…)`; callers resolve `.preview`, `.mainSmoke` or `.release`);
  - `Release/ReleaseExecutor.swift:355`, `Store/Store+Release.swift:258`;
  - `SafetyLintTests` (`failOpen` zero in `Sources/BrahmaCore/Principal`).

**Interfaces:**
- Produces (exact shapes from spec §6.2.2–6.2.3):
  - `Principal`, `AgentPrincipal`, `PrincipalSet` (`members`, `companyId`, `ownerProfile`, `hasUnknown`, `allFull`, `commonGrantDomains`);
  - `ActionSubject` (10 cases);
  - `PrincipalResolver(store:ceiling:)` with `resolve(_:) -> PrincipalSet`, total and never throwing;
  - `PrincipalResolver.resolveCount` (an internal counter for the resolve-once test).
- Consumes: `PermissionProfile.narrower` (S3), `Store.lease(itemId:)`, `Store.agent(id:)`, `Store.workItem(id:)`, `Store.landedItemIds`, `Store.isQueueLandedHead`, `Store.company(id:)`, the grants lookup the 5-lite `grantDomains` path uses.

- [ ] **Step 1: Write the failing tests.**
  - `PrincipalSetTests.emptyBecomesUnknown`: `PrincipalSet(companyId:members: [], ownerProfile: .full).members == [.unknown(reason: "no principal")]`.
  - `PrincipalSetTests.unknownNeverFull` (property, `FuzzConfig.cases`): random member lists containing any `.unknown`, `.external` or `.engine` → `allFull == false` and `commonGrantDomains == []`.
  - `PrincipalSetTests.grantsIntersect`: `[a: ["x","y"], b: ["y","z"]]` → `["y"]`.
  - `PrincipalSetTests.orderInvariant`.
  - `PrincipalResolverTests`, one test per row of spec §6.2.3:
    - `verificationRunUsesHolderThenRequester`;
    - `verificationRunMissingIsUnknown`;
    - `mergeRunMatches4aRule`: port each 4a merge-run principal test's fixture and assert the same members;
    - `previewNilSetterIsUnknown`;
    - `previewOwnerSetterIsOwner`;
    - `worktreeHolderThenOwner`;
    - `vaultBlobFollowsProvenance`;
    - `extensionIsExternal`;
    - `lookupErrorIsUnknown` (a throwing store);
    - `ceilingNarrowsEveryProfile`.
  - `PrincipalResolverTests.resolvesOncePerAction`: `checkRoute` for one merge run → `resolveCount == 1`. A preview start → 1.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL.
- [ ] **Step 3: Implement the resolver, then migrate the 4 derivation sites (spec §7.3).** A Full decision made with an unknown member emits the B1 activity line. Use S2's `sandboxedNote`.
- [ ] **Step 4: Run the focused tests and the full suite.** Expected: every 4a merge-run, check-route and preview test passes unchanged, along with S2's `FailOpenFixTests`.
- [ ] **Step 5: Commit.** `git commit -m "feat(core,safety): Principal/PrincipalSet resolved once per action; least-privileged wins (B1-B3)"`

---

### Task S7: `SandboxPolicyFactory`, `Place` and `ValidatedPolicy`

**Files:**
- Create: `Sources/BrahmaSafety/Policy/Purpose.swift` (`Purpose`, `PurposePlaces`, `CheckKind`, `CanaryProbe`, `LoopbackPort`), `Policy/SandboxPolicyFactory.swift`, `Policy/Reach.swift`, `Path/Place.swift`, `Tests/BrahmaSafetyTests/SandboxPolicyFactoryTests.swift`, `Tests/BrahmaSafetyTests/PolicyRenderPropertyTests.swift`
- Modify:
  - `Sources/BrahmaSafety/Sandbox/SandboxPolicy.swift` (`init` becomes `internal`; `SandboxPolicyCheck.validate` returns `ValidatedPolicy`);
  - `Sandbox/SeatbeltProfile.swift` (`render(_ v: ValidatedPolicy, baseline:proxyPort:marker:)`, with no `SandboxPath.resolve` inside);
  - `Sandbox/SeatbeltRunner.swift`, `Sandbox/SandboxedRunner.swift` (`run`/`spawn` take `ValidatedPolicy`; the unsandboxed runner takes `FullOptOut`);
  - the 16 sites of spec §7.2;
  - `SafetyLintTests` (`sandboxPolicy` zero).

**Interfaces:**
- Consumes: `PrincipalSet` (S6).
- Produces:
  - `public struct Place: Hashable, Sendable { public let resolvedPath: String; public let kind: PlaceKind }` with `PlaceKind { directory, file }`.
  - `public static func verify(_ url: URL, kind: PlaceKind, under root: URL) throws -> Place`. It walks fd-anchored from `root` (`EngineFiles.OpenDirectory`), requires the expected kind, and requires `SandboxPath.resolve(url.path) == url.path`.
  - `public static func logical(_ url: URL, under root: Place) throws -> Place` (for `guiApp` app data named logically per 4a fix round 1 I1).
  - `Purpose` and `PurposePlaces` exactly as spec §6.3.1. `PurposePlaces` has one case per purpose:
    - `.check(checkout:workspace:)`;
    - `.previewServer(run:)`, `.previewOneShot(run:)`, `.appleBuild(run:)`, `.guiApp(run:appData:)`;
    - `.releaseTool(writable:readable:)`, `.releaseSmoke(dir:)`, `.providerProbe(writable:readable:)`;
    - `.extensionUnzip(unzipped:held:)`, `.extensionValidate(scratch:readable:)`, `.doctorExtensions(scratch:readable:)`;
    - `.canary(writable:readable:)`;
    - `.helper(op:targets: [Place], call: Place, helperDir: Place)`.
  - `public struct ValidatedPolicy: Sendable, Equatable { public let writable: [String]; public let readable: [String]; public let network: SandboxNetwork; public let toolchain: Bool }`. The only initializer is internal to `SandboxPolicyCheck`.
  - `public struct FullOptOut: Sendable { public let reason: String }`, created only inside the factory.
  - `public struct Reach: Sendable { allowed: [String]; denied: [String] }`, with the agent, owner and other rules of spec §6.4.4.
  - `SandboxPolicyFactory.decide(_:principals:places:network:baseline:reach:) -> PolicyDecision`.

- [ ] **Step 1: Write the failing tests.**
  - `SandboxPolicyFactoryTests.<purpose>MatchesLegacy`, one per purpose (13 tests): build the places from a temp tree, call `decide`, and compare to a literal `SandboxPolicy` holding the old site's values (via `@testable import BrahmaSafety`). Example `checkMatchesLegacy`: writable `[checkout]`, readable `[workspace]`, `.outbound(allow: companyDomains)`, toolchain on.
  - `fullOnlyForCodeRunningPurposes`: an `allFull` set with `.helper(.worktreeDiff)` → `.sandboxed`. With `.check` → `.fullOptOut`.
  - `mismatchedPlacesRefused`: `.check` with `.previewServer(run:)` → `.refused`.
  - `unknownGetsNoGrants`.
  - `placesOutsideReachRefused` (helper).
  - `PolicyRenderPropertyTests.renderUsesValidatedStringsOnly` (property): random temp trees with links. Validate, then use a test hook to swap a link between validate and render. The rendered profile text is identical and contains only the `ValidatedPolicy` strings.
  - `PolicyRenderPropertyTests.reachIsNeverExceeded` (property, spec §10.1 "Reach").
  - Keep any test 4a's Task 7 added for the `SeatbeltRunner.prepare` race, re-pointed to `ValidatedPolicy`.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL.
- [ ] **Step 3: Implement the factory, then migrate all 16 sites (spec §7.2).** Each site builds `Place`s from engine records and calls `decide`.
  - On `.refused` it uses that site's existing refusal path. Examples: `CheckRoute.refused(reason)`, a preview start `.failed`.
  - `Refs/TextExtract.swift:98` is the one exception. It moves onto a temporary internal `SandboxPolicyFactory.legacyExtract(unzipped:held:)` (writable `[unzipped]`, readable `[held]`, `.none`, no toolchain, unchanged from today) marked `// removed in S12`. The lint allowlists it as the only exception until S12.
  - `SafeRead.smallText` gains an overload `under root: Place`. S2's `URL` form becomes `internal`.
- [ ] **Step 4: Run the focused tests and the full suite.** Every preview, check, release, extension and canary test must pass unchanged.
- [ ] **Step 5: Commit.** `git commit -m "feat(safety): SandboxPolicyFactory is the only policy source; ValidatedPolicy closes the render race"`

---

### Task S8: Helper runtime — `brahma-helper`, protocol, client, `selftest` and the budget benchmark

**Files:**
- Create:
  - `Sources/brahma-helper/main.swift`;
  - `Sources/BrahmaSafety/Helper/HelperProtocol.swift`, `HelperServer.swift`, `HelperClient.swift`, `HelperPool.swift`, `HelperBinary.swift`, `Ops/SelftestOp.swift`, `HelperLimits.swift`;
  - `Tests/BrahmaCoreTests/InProcessHelperTransport.swift`, `Tests/BrahmaSafetyTests/HelperProtocolTests.swift`, `Tests/BrahmaCoreTests/HelperClientTests.swift`, `Tests/BrahmaCoreTests/HelperLiveTests.swift`, `Tests/BrahmaCoreTests/HelperBenchTests.swift`
- Modify:
  - `Package.swift` (`.executableTarget(name: "brahma-helper", dependencies: ["BrahmaSafety"])`; product `brahma-helper`);
  - `scripts/make-app.sh` (build, copy to `Contents/Helpers/brahma-helper`, `codesign --force --sign -`);
  - `Sources/BrahmaCore/Orchestrator.swift` (construct `HelperClient` with `HelperBinary.verify(sibling of mcpExecutable)`, `ToolPaths`, `PrincipalResolver`, the baseline closure, `ChildGroups.current` and the emergency-stop gate; remove stale call dirs at start);
  - `Sources/BrahmaCore/Engine/Doctor.swift` (item `helper`);
  - `Sources/BrahmaSafety/Sandbox/SandboxPolicy.swift` (add `SandboxNetwork.loopbackConnect(port: UInt16)`, rendered as `(deny network*)(allow network-outbound (remote ip "localhost:<port>"))` with no proxy; `SandboxPolicyCheck` refuses port 0);
  - `Tests/BrahmaSafetyTests/KernelBoundaryTests.swift` (enable `helperDependsOnlyOnKernel`).

**Interfaces:**
- Consumes: `SandboxPolicyFactory.decide(.helper(op), …)` (S7), `Spawn`/`ToolPaths` (S5), `SandboxSweep`, `ChildGroups`, `EngineFiles`, `PrincipalSet` (S6).
- Produces:
  - `public enum HelperOp: String, Codable, Sendable, CaseIterable { case worktreeDiff, worktreeStatus, worktreeCommit, loopbackHTTP, httpsProbe, stageCopy, extractText, selftest }`. S8 implements only `selftest`; the others are declared now and implemented by S9–S12 and S9b/S10b. An unimplemented op refuses with code `notImplemented`, and a test pins that each is implemented by the end of S12 (`HelperProtocolTests.everyOpImplemented`, enabled in S12).
  - `public struct HelperRequest<Args: Codable & Sendable>: Codable, Sendable { let v: Int; let op: HelperOp; let callDir: String; let args: Args }`.
  - `public enum HelperResult<R: Codable & Sendable>: Codable, Sendable { case ok(R); case refused(HelperRefusal) }` and `public struct HelperRefusal: Codable, Sendable, Equatable { let code: String; let detail: String }`.
  - `public struct HelperOutFile: Codable, Sendable { let name: String; let size: Int; let sha256: String }`. Names are one `SafeFS.components`-valid component, or a relative path for `stageCopy` folders.
  - `public enum HelperError: Error, Equatable, Sendable { case unavailable(String), busy, refused(HelperRefusal), failed(String), timedOut }`.
  - `public protocol HelperTransport: Sendable { func call<A, R>(_ op: HelperOp, args: A, policy: ValidatedPolicy, callDir: URL, limits: HelperLimits.Op) async throws(HelperError) -> (R, outDir: URL) }`. The production implementation is `SeatbeltHelperTransport(executable:tools:baseline:groups:)`.
  - `public final class HelperClient: Sendable` with `init(transport: any HelperTransport, home: URL, pool: HelperPool, gate: @Sendable (HelperOp) -> Decision<Void>)` and `func run<A, R>(_ op: HelperOp, args: A, principals: PrincipalSet, places: PurposePlaces, network: NetworkScope) async throws(HelperError) -> HelperReply<R>`.
    - `HelperReply<R> { result: R; files: [HelperOutFile]; read: (HelperOutFile, Int) throws -> Data }`. The client reads `out/` only after a clean sweep and removes the call dir on `deinit` of the reply, or by explicit `finish()`.
  - `HelperServer.main()` reads argv[1], decodes stdin strictly (rejecting unknown keys and wrong `v`), dispatches to the op and writes one response. `brahma-helper --protocol` prints `1`.
  - `SelftestOp`: args `{ probes: [SelftestProbe] }`, where `SelftestProbe` is one of `.read(path)`, `.write(path)`, `.connect(port)`, `.exec(path)`. The result is `[probe: "allowed" | "denied"]`. The canary (S16) and the live tests use it.
  - `HelperBinary.verify(_ url: URL, forbiddenRoots: [URL]) -> Decision<URL>` (rules in spec §6.4.2).

- [ ] **Step 1: Write the failing tests.**
  - `HelperProtocolTests.rejectsUnknownKeys`, `rejectsWrongVersion`, `rejectsOversizedRequest` (65 537 bytes), `roundTripsEveryOp`.
  - `HelperClientTests.misbehavingHelperNeverYieldsSuccess`: use scripted fake executables written to a temp dir and run under the real `SeatbeltHelperTransport`. They:
    - sleep forever → `.timedOut` within limit + 2 s;
    - print 300 MB → `.failed`;
    - exit 0 with `{}` → `.failed`;
    - fork a `sleep 1000` child and exit → the straggler is killed, and the result is `.failed` if it could not be killed, otherwise the response is honoured;
    - write a symlink into `out/` listed in the manifest → `.failed`.
    - In none of these cases is a value returned.
  - `HelperClientTests.callDirRemovedAndStaleSwept`.
  - `HelperClientTests.poolLimitsConcurrency`: 6 concurrent calls, at most 4 running, the 5th waits; with `maxWait` lowered to 0.2 s → `.busy`.
  - `HelperClientTests.emergencyStopRefusesWriteOps`: the stop is set → `stageCopy` gets `.unavailable`, `worktreeDiff` is allowed (spec §6.4.5 step 1).
  - `HelperClientTests.unverifiedBinaryIsUnavailable`: a group-writable binary → `.unavailable`, and the doctor item `helper` fails.
  - `HelperLiveTests.selftestDeniesOutsideReach` (live sandbox, needs the built `brahma-helper`; locate it like `brahmaExecutableURL()`). Under the `.helper(.selftest)` policy:
    - `.read(<home>/brahma.db)` → denied;
    - `.read(~/.ssh/known_hosts or a temp file under the denied home)` → denied;
    - `.write(<call>/../x)` → denied;
    - `.write(<call>/out/x)` → allowed;
    - `.connect(otherPort)` → denied under `.loopbackConnect(port)`, and `.connect(port)` → allowed.
  - `HelperBenchTests.budgets` (`.enabled(if: env BRAHMA_BENCH == "1")`, release build): measure p50/p95 over 40 runs of `selftest`. Assert `HelperBudgets.selftest` (60 ms). Print a table for the commit message.
- [ ] **Step 2: Run them and confirm they fail.** Run: `swift build --product brahma-helper && swift test --filter "HelperProtocolTests|HelperClientTests|HelperLiveTests"`. Expected: FAIL.
- [ ] **Step 3: Implement the protocol, server, client, pool and binary verification, plus the lifecycle steps 1–10 of spec §6.4.5.**
  - Set the rlimits in the child with a small wrapper. `brahma-helper` sets its own limits from `HelperLimits` before reading stdin, so no pre-exec hook is needed in `Spawn`.
  - The environment is exactly `HelperEnv.make(callDir:)`.
- [ ] **Step 4: Run the focused tests, the live tests and the full suite.** Then run `BRAHMA_BENCH=1 swift test -c release --filter HelperBenchTests`. Expected: PASS, with the budget table recorded in the commit message and in spec §9.2's "Measured" column (append a column).
- [ ] **Step 5: Commit.** `git commit -m "feat(safety): brahma-helper runtime (protocol v1, call dirs, rlimits, sweep, quiescence, pool) + selftest + budgets"`

---

### Task S9: Helper op `loopbackHTTP` — smoke, readiness and demo requests

**Files:**
- Create: `Sources/BrahmaSafety/Helper/LoopbackHTTP.swift`, `Helper/Ops/LoopbackHTTPOp.swift`, `Tests/BrahmaSafetyTests/LoopbackHTTPTests.swift`, `Tests/BrahmaCoreTests/LoopbackHelperTests.swift`
- Modify:
  - `Sources/BrahmaCore/Preview/BackendAdapter.swift` (`smoke`/`probe` go through `HelperClient`; `origin` and `servesOwnPort` stay as engine-side refusals before any call);
  - `Sources/BrahmaCore/Preview/WebAdapter.swift:35, :100` (demo and readiness GETs);
  - `Sources/BrahmaCore/Preview/PreviewAdapter.swift` (`PreviewDependencies` gains `helper: HelperClient`, `principals: PrincipalSet`; `http` stays only for non-loopback users);
  - `SafetyLintTests` (`loopbackHTTP` zero in `Sources/BrahmaCore/Preview`).

**Interfaces:**
- Consumes: `HelperClient.run` (S8), `SandboxNetwork.loopbackConnect` (S8), the `ActionSubject.preview` principals (S6).
- Produces:
  - `LoopbackHTTPArgs { port: UInt16; requests: [LoopbackRequest] }` with `LoopbackRequest { method: String /* GET HEAD POST PUT PATCH DELETE OPTIONS */; path: String /* starts "/", no "//" prefix, ≤ 2048 */; body: String?; timeoutMs: Int }`.
  - `LoopbackHTTPResult { responses: [LoopbackResponse] }` with `LoopbackResponse { status: Int?; contentType: String?; bodyPrefix: String; millis: Int; error: String? }`.
  - `LoopbackHTTP.send(_:port:) -> LoopbackResponse`, an HTTP/1.1 client over a BSD socket to `127.0.0.1` only (spec §6.4.4).
  - All requests of one start, demo or readiness GET go in **one** helper call.

- [ ] **Step 1: Write the failing tests.**
  - `LoopbackHTTPTests` against an in-test socket server:
    - `statusAndBodyPrefix`;
    - `redirectIsAnswerNotFollowed` (301 → status 301);
    - `chunkedAndContentLengthBodiesCapped`;
    - `oversizedHeadersRefused`;
    - `slowServerTimesOut`;
    - `nonLoopbackHostRejectedBeforeConnect`: the API takes only a port, so a compile-level check plus `path` validation `"//evil"` → error.
  - `LoopbackHelperTests.smokeGoesThroughHelperOnce`: 3 smoke requests → the transport records one `loopbackHTTP` call with 3 requests.
  - `LoopbackHelperTests.otherLocalServiceUnreachable` (live sandbox): a second server on another port gets no connection while a smoke runs against the preview port.
  - `LoopbackHelperTests.failingTransportFailsSmoke`: a transport throwing `.unavailable` → every `SmokeResult.ok == false` and `error == "unavailable (helper: …)"`. The update message never reports `n/n ok`.
  - Every existing `BackendAdapterTests`, `MainSmokeTests` and web-readiness test passes through `InProcessHelperTransport`.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL.
- [ ] **Step 3: Implement the op and migrate the callers.**
  - Redaction stays engine-side (`BackendAdapter.redacted`) and is applied to the helper's response.
  - Readiness polling keeps L's cadence. Each poll is one helper call with one GET.
- [ ] **Step 4: Run the focused tests and the full suite. Re-run `HelperBenchTests` with the HTTP overhead case.** Expected: PASS, with overhead ≤ 60 ms p95.
- [ ] **Step 5: Commit.** `git commit -m "feat(core,safety): preview smoke/readiness/demo HTTP via the helper, loopback port only (B4, B6)"`

---

### Task S9b: Deployed-site smoke through the helper (`httpsProbe`, plus `loopbackHTTP` for `DevHost`)

**Files:**
- Create: `Sources/BrahmaSafety/Helper/Ops/HTTPSProbeOp.swift`, `Tests/BrahmaCoreTests/DeploySmokeHelperTests.swift`
- Modify:
  - `Sources/BrahmaCore/Release/DeploySmoke.swift`: `run(base:requests:expectText:http:…)` becomes `run(base:requests:expectText:transport: SmokeTransport, …)`. The rounds, attempts, interval, `expectText` and cancellation logic stay.
  - `Release/ReleaseExecutor.swift:456`, which resolves `.release(releaseId)` once and passes the principals.
  - `Release/DevReleaseScenario.swift`.
  - `Release/UploadStager.swift`: a precondition that `stage` is called only after the build run reported a clean sweep (`StragglerReport` empty or all killed). Otherwise it throws `ReleaseError.stage("the build left processes running; output not staged")`.
  - `Sources/BrahmaSafety/Policy/SandboxPolicyFactory.swift`: `.helper(.httpsProbe)` may carry `.outbound(allow: [host])` with exactly one domain, and no other helper op may have network except `loopbackConnect`.
  - `SafetyLintTests`: `loopbackHTTP` zero in `Release/DeploySmoke.swift` and `DevReleaseScenario.swift`, plus the spec §6.8.2 allowlist.

**Interfaces:**
- Consumes: `HelperClient` (S8), `LoopbackHTTPOp` (S9), `EgressProxyPool.proxy(for:)` (5-lite), `ToolPaths.curl` (S5), `PrincipalResolver.resolve(.release / .mainSmoke)` (S6).
- Produces:
  - `public enum SmokeTransport { case https(host: String), devHost(port: UInt16) }` with `static func route(base: URL) -> Decision<SmokeTransport>`:
    - `https` with a non-IP host → `.https`;
    - `http://127.0.0.1:<port>` or `http://localhost:<port>` equal to a `DevHost` the engine started → `.devHost`;
    - anything else → `.deny("the smoke base must be an https host or Brahma's dev host")`.
  - `HTTPSProbeArgs { curl: String; proxyPort: UInt16; host: String; requests: [LoopbackRequest] }` (it reuses S9's request type; `path` is engine-built by `DeploySmoke.url(base:path:)`).
  - `HTTPSProbeResult { responses: [LoopbackResponse] }`.
  - The curl argv is exactly spec §6.4.4 "How `httpsProbe` works". `HOME=<call>/home`.

- [ ] **Step 1: Write the failing tests.**
  - All of L's `DeploySmokeTests` cases re-pointed through `InProcessHelperTransport`: rounds, `expectText`, redirect-as-answer, cancellation, off-host paths.
  - `DeploySmokeHelperTests.routeRefusesOtherBases`: `http://example.com`, `https://10.0.0.1`, `https://[::1]`, `file:///` → deny.
  - `devHostUsesLoopback`.
  - `curlArgvIsFixed`: snapshot the argv the op builds for a sample request; it must contain `--proto =https`, `--max-redirs 0`, `--proxy http://127.0.0.1:<p>` and `-q`.
  - `privateResolutionFailsSmoke` (live sandbox, no internet needed): a proxy allow-list for `localtest.me` (which resolves to 127.0.0.1) → the result is a failure whose text matches `privateHostText`, and the local test server sees no request (B12).
  - `failingTransportFailsRelease`: `.unavailable` → the smoke is not `ok`, and the release does not advance.
  - `uploadStagerRequiresCleanSweep`.
  - `DeploySmokeHelperTests.publicHTTPS` (`BRAHMA_LIVE=1` only): `GET https://example.com/` → status 200.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL.
- [ ] **Step 3: Implement the op and the routing, then migrate the 2 callers.** Redaction of bodies and errors stays engine-side, as today.
- [ ] **Step 4: Run the focused tests, the full suite and the bench (https overhead ≤ 80 ms per round, measured against a local TLS test server through the proxy).**
- [ ] **Step 5: Commit.** `git commit -m "feat(core,safety): deployed-site smoke via the helper through the egress proxy; DevHost via loopback (B12)"`

---

### Task S10: Helper ops `worktreeDiff` and `worktreeStatus`

**Files:**
- Create: `Sources/BrahmaSafety/Helper/Ops/WorktreeDiffOp.swift`, `Ops/WorktreeStatusOp.swift`, `Tests/BrahmaCoreTests/WorktreeDiffHelperTests.swift`
- Modify:
  - `Sources/BrahmaCore/Refs/SafeGit.swift` (delete `worktreeDiff` phases 1–3, `copyIgnoreFiles`, `blobId(of:…)` if unused, `Anchor`, `Budget`; keep committed-object reads);
  - delete `Sources/BrahmaCore/Refs/WorktreeListing.swift`;
  - add `Sources/BrahmaCore/Refs/WorktreeDiffs.swift`: `Store.worktreeDiff(companyId:key:against:) async throws -> SafeGit.WorktreeDiff`, which resolves `.worktree`, builds the `Place`s and calls the helper;
  - `Refs/RefResolver.swift:65-69, :323-327`, `Refs/OpenRef.swift:277-281`, plus C5b's `Changes/*` callers if merged;
  - `Sources/BrahmaCore/Git/GitWorkspace.swift` (`isDirty(in:)` becomes `Store.worktreeIsDirty(companyId:dir:subject:)` through the helper, and its 4 callers migrate);
  - `Changes/LiveChanges.swift` (if merged: the B10 adaptive interval);
  - `SafetyLintTests` (`dirWalk`, `descriptor` and `fileAPI` zero in `Sources/BrahmaCore/Refs` and `Changes`).

**Interfaces:**
- Consumes: `HelperClient` (S8), `ToolPaths.git` and `gitCandidates` (S5), `GitHardening` (S3), `PrincipalResolver.resolve(.worktree(…))` (S6).
- Produces:
  - `WorktreeDiffArgs { git: String; commonDir: String; worktree: String; base: String /* 40/64-hex, engine-verified */; caps: WorktreeDiffCaps }`.
  - `WorktreeDiffResult { files: [ChangedPath]; truncated: Bool; patchFile: HelperOutFile? }` with `ChangedPath { path: String; status: String /* A M D T */; added: Int?; removed: Int?; bytes: Int; mtime: Double? }`.
  - `SafeGit.WorktreeDiff` keeps `files`, `patch` and `truncated` and **drops `blobShas`** (spec §6.4.4).
  - Refusal codes map to `SafeGitError`: `tooManyChanges` → `.tooManyChanges`; `notInPlace` → `.io("the worktree of <KEY> is not in place")`; anything else → `.io("the worktree diff is unavailable")`.
  - `WorktreeStatusArgs { git; commonDir; worktree; excludeEngineDir: Bool }` → `WorktreeStatusResult { dirty: Bool }`.
  - `ChangesLimits.adaptiveInterval(measured: Duration) -> Duration` (B10: measured × 4, clamped 2…10 s).

- [ ] **Step 1: Write the failing tests.**
  - Re-point every existing C1a/C1b/C2a `worktreeDiff` behaviour test to `Store.worktreeDiff` over `InProcessHelperTransport` (gitignore, symlinks as link targets, binary, deletions, nested repo, `.git` entries, caps). Where git's semantics differ from the old walker, change the expectation and add the case to a `// B5 delta:` list in the test file and the commit message.
  - New tests:
    - `forgedAgentIndexCannotHideAChange`: write an agent index whose stat cache claims a modified file is clean → the helper diff still shows it, because the agent's index is never read.
    - `nothingWrittenToRepository`: the object count of `<ws>/.git/objects` is unchanged after a diff.
    - `swappedRootNeverLeaksOutsideReach` (live sandbox): replace `.brahma/wt/KEY` with a symlink to a temp dir standing in for a protected place (listed in the baseline's `protected`) → `.io` refusal, and no byte of that dir appears.
    - `failingTransportIsNeverEmptyDiff`: `.unavailable` → `SafeGitError.io`, never `files == []`.
    - `isDirtyThroughHelper`: clean → false, an edited file → true, a `.brahma`-only change → false.
    - `isDirtyFailureIsDirty`: transport failure → callers treat it as dirty or refuse, as today's `?? true` did at `Orchestrator.swift:1584`.
    - `adaptiveIntervalClamps`: 100 ms → 2 s, 1 s → 4 s, 5 s → 10 s.
  - `HelperBenchTests` gains `worktreeDiff10k`, `worktreeDiff1k` and `worktreeStatus10k`. Generate the 10 000-file fixture the way spec §9.1 did: 100 directories × 100 files of 40 lines, with 5 modified files and 1 new file.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL.
- [ ] **Step 3: Implement the ops (the exact pipeline in spec §6.4.4), then migrate the callers and delete the in-engine walker.** The helper re-checks that `args.git ∈ ToolPaths.gitCandidates` (passed in the request and validated as an absolute regular executable that is not inside the worktree).
- [ ] **Step 4: Run the focused tests, the full suite and the bench.** Expected: PASS, with budgets met (diff 10k ≤ 400 ms, 1k ≤ 120 ms, status ≤ 150 ms). If the 10k diff misses its budget, B10 applies (already implemented). Record that in the commit, and do not stop.
- [ ] **Step 5: Commit.** `git commit -m "feat(core,safety): worktree diff/status in the helper (fresh index, no repo writes); in-engine walker removed (B4, B5, B10)"`

---

### Task S10b: Commit staging in the helper (`worktreeCommit`)

**Files:**
- Create: `Sources/BrahmaSafety/Helper/Ops/WorktreeCommitOp.swift`, `Tests/BrahmaCoreTests/WorktreeCommitHelperTests.swift`, `Tests/BrahmaCoreTests/Fixtures/commit-parity/*.json` (tree shas captured from the old walker)
- Modify:
  - `Sources/BrahmaCore/Git/GitWorkspace.swift`: `commitAll`/`commitAllWithParent` become `async` and go through the helper for the staging. Delete `stage(_:in:relative:)`, its descriptor walker, `maxUnsafeAdds` and its helpers. Keep `ownTip`, the `update-ref <ref> <new> <expected>` swap and `testHook("checked")`. Add `importPack(_ file: VerifiedOutFile) throws`, which runs `index-pack --stdin --strict --fix-thin` with `GitHardening` and `cwd` = the common dir, and `verifyCommit(_ commit: String, parent: String, caps:) throws`.
  - `Sources/BrahmaCore/MCP/WorkTools.swift:421, 473` (submit and auto-commit before release).
  - `GitWorkspace.removeWorktree` (`:1231`, auto-commit at removal).
  - The `EngineGitGuardTests.gitCalls` pattern (it keeps matching `commitAll`).
  - `SafetyLintTests`: `descriptor` and `dirWalk` counts in `Git/GitWorkspace.swift` drop by the walker's hits.

**Interfaces:**
- Consumes: `HelperClient` (S8), `WorktreeDiffOp`'s environment builder (S10, shared as `HelperGitEnv.make(commonDir:workTree:callDir:)`), `PrincipalResolver.resolve(.worktree(…))` (S6).
- Produces:
  - `WorktreeCommitArgs { git: String; commonDir: String; workTree: String; tip: String /* full sha */; messageFile: String /* <call>/message */; identity: GitIdentity /* name, email, epoch seconds, tz, set by the engine */; caps: CommitCaps }`.
  - `WorktreeCommitResult { outcome: .nothingToCommit | .committed(commit: String, tree: String, pack: HelperOutFile) }`.
  - `GitWorkspace.commitAllWithParent(in:message:) async throws -> (parent: String?, commit: String)?`. It keeps the same contract as today: nil when there is nothing to commit, and `GitError.failed` texts unchanged for a moved branch. A helper refusal maps to `GitError.failed(command: "stage", status: -1, stderr: "could not stage the worktree (<code>)")` (B11).
  - Verification: `cat-file -t == commit`; exactly one parent == `tip`; `rev-list --objects tip..commit | count ≤ caps.maxObjects`; `ls-tree -r --name-only <commit>` has no path equal to or under `.brahma`.

- [ ] **Step 1: Capture parity before changing anything.**
  - On the pre-task code, add and run `WorktreeCommitHelperTests.captureParity` (with `BRAHMA_RECORD_GOLDENS=1`). It builds the fixture matrix of spec §10.3 "Commit" (regular, executable, symlink, deleted, gitignored, `.brahma`-only, nested repo, a non-UTF-8 name, a 3a-cap-exceeding file) and records each `commitAll` tree sha, or its refusal text.
  - Commit the fixtures alone: `test(core): commit-staging parity fixtures before the helper`.
- [ ] **Step 2: Write the failing tests.**
  - `treeShasMatchParity`: every fixture gives the same tree sha, or the same refusal.
  - `agentIndexNeverRead`: a forged agent index that marks a modified file clean → the commit still contains the change.
  - `forgedPackRejected`: a fake transport returns a pack holding a commit whose parent is not `tip` → `GitError`, and the branch is unchanged.
  - `packWithBrahmaPathRejected`.
  - `oversizedPackRefusedBeforeImport`.
  - `branchMovedMeanwhileFailsSwap`: unchanged 3a behaviour, kept.
  - `failingTransportNeverCommits`: `.unavailable` → submit refused with the B11 text, and no ref moved.
  - `swappedWorktreeRootCommitsNothingOutsideReach` (live sandbox).
  - All 3a, 4a and C tests that submit, auto-commit or remove worktrees pass unchanged through `InProcessHelperTransport`.
  - `HelperBenchTests.worktreeCommit10k`, ≤ 600 ms.
- [ ] **Step 3: Run them and confirm they fail.**
- [ ] **Step 4: Implement the op (spec §6.4.4 "How `worktreeCommit` works"), the import and the verification, then migrate the 3 callers and delete the walker.**
- [ ] **Step 5: Run the focused tests, the full suite and the bench.** If the budget is missed, stop and go to the controller. There is no pre-decided fallback for submit.
- [ ] **Step 6: Commit.** `git commit -m "feat(core,safety): submit/auto-commit staged in the helper, imported via index-pack --strict and verified; in-engine stage walker removed (B11)"`

---

### Task S11: Helper op `stageCopy` — artifact publishing and the OpenAPI copy

**Files:**
- Create: `Sources/BrahmaSafety/Helper/Ops/StageCopyOp.swift`, `Tests/BrahmaCoreTests/StageCopyHelperTests.swift`
- Modify:
  - `Sources/BrahmaCore/Store/Store+Artifacts.swift`: remove the descriptor walk, the folder and glTF copy, and the zip ratio parse. Keep: who, where (the realpath checks that pick the source `Place`), rate, quota, number, the transaction, the memory doc and the activity line. Add an engine re-check of the quiescent copy.
  - `Sources/BrahmaCore/Preview/BackendAdapter.swift` (`copyOpenAPI` uses `stageCopy` with `kind: .openapi`).
  - `SafetyLintTests` (`descriptor`, `fileAPI` and `dirWalk` zero in `Store/Store+Artifacts.swift` and `Preview/`).

**Interfaces:**
- Consumes: `HelperClient` (S8), `ActionSubject.publish` and `.preview` (S6), 4a's `ArtifactPolicy`, `ArtifactSniffer`, `ArchiveRatio` (moved into the helper op code in `BrahmaSafety`; `BrahmaCore` keeps thin re-exports if the app uses them).
- Produces:
  - `StageCopyArgs { source: String /* resolved Place */; mode: StageMode /* file, folder, gltf, openapi */; ext: String; neutralName: Bool; remainingQuota: Int }`.
  - `StageCopyResult { files: [HelperOutFile]; kind: String; hints: StageHints }` with `StageHints { zipRatioOK: Bool?; gltfSiblings: [String] }`. Hints are advisory (spec §6.4.4).
  - `Store.recheckStaged(_ reply: HelperReply<StageCopyResult>, ext: String) throws -> [VerifiedStagedFile]`. For each file it checks: regular, one link, size == manifest, SHA-256 == manifest, magic bytes from the first 64 bytes match `ext`, names valid. Any mismatch → `ArtifactRefusal` (4a's texts).

- [ ] **Step 1: Write the failing tests.**
  - All of 4a's `ArtifactTests` publish cases (file, folder with `index.html`, a link in a folder refused, glTF siblings, caps, quota, rate, a tainted neutral name, a FIFO refused, a zip bomb refused) re-pointed through `InProcessHelperTransport` must pass.
  - New tests:
    - `forgedManifestRejectedByEngineRecheck`: a fake transport lists a SHA-256 that does not match `out/` → refusal, and nothing published.
    - `forgedKindRejected`: the helper claims `png` for HTML bytes → refusal.
    - `sourceSwappedAfterResolveCannotReadOutside` (live sandbox): swap the source for a link to a file outside the workspace after the engine resolves it → refusal, and the outside bytes are never in `.brahma/artifacts`.
    - `failingTransportPublishesNothing`.
    - `openapiThroughHelper`: an oversized file → 4a's refusal text, and no copy left.
- [ ] **Step 2: Run them and confirm they fail.** Expected: FAIL.
- [ ] **Step 3: Implement the op, then migrate `publishArtifact` and `copyOpenAPI`.**
- [ ] **Step 4: Run the focused tests, the full suite and the bench (`stageCopy` of 20 MB ≤ 400 ms).**
- [ ] **Step 5: Commit.** `git commit -m "feat(core,safety): artifact and OpenAPI copies staged by the helper, re-checked on the quiescent copy"`

---

### Task S12: Helper op `extractText`

**Files:**
- Create: `Sources/BrahmaSafety/Helper/Ops/ExtractTextOp.swift` (moves `TextExtract.stripTags`, `decodeEntities`, `ordered`, member selection and `ArchiveLimits` checks into the op; it runs `/usr/bin/unzip` inside the helper), `Tests/BrahmaCoreTests/ExtractTextHelperTests.swift`
- Modify: `Sources/BrahmaCore/Refs/TextExtract.swift` (keep `metadata(kind:bytes:)` and `imageSize`, which parses ≤ 64 KiB in-engine per spec §6.4.1; `extract` becomes an `async` call to the helper with the held copy as a `Place`), `Refs/OpenRef.swift:137`. Delete `SandboxedUnzipReader`, `ArchiveReader` and S7's `legacyExtract` exception. Update `SafetyLintTests` (`sandboxPolicy` exception removed).

**Interfaces:**
- Produces:
  - `ExtractTextArgs { held: String; kind: String; ext: String; unzip: String /* ToolPaths.unzip */ }`.
  - `ExtractTextResult { text: String? /* ≤ 64 KiB inline */; textFile: HelperOutFile? /* else */; truncated: Bool }`.
  - `TextExtract.extract(kind:ext:held:helper:principals:) async throws -> String`. Its errors map to C2a's existing `open_ref` texts. `.unavailable` → the "metadata only" path that C2a uses when unzip is unavailable.

- [ ] **Step 1: Write the failing tests.** C2a's `OpenRefTests` extract cases re-pointed (docx, xlsx, pptx, non-UTF-8, a bomb, a ratio refusal). New tests:
  - `failingTransportGivesMetadataOnly`;
  - `huge2MiBTextGoesViaFile`;
  - `bombRefusedInsideHelper`: a 200 MiB+ claim → refusal, and the engine RSS growth stays under 20 MB.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the op and migrate the caller.**
- [ ] **Step 4: Run the focused tests, the full suite and the bench (5 MB docx ≤ 2 s).**
- [ ] **Step 5: Commit.** `git commit -m "feat(core,safety): archive text extraction in the helper; the engine receives capped text only"`

---

### Task S13: Typed prompt text and the digest families

S13, S14a and S14b may run as a parallel lane after S4.

**Files:**
- Create: `Sources/BrahmaSafety/Prompt/Trusted.swift`, `Prompt/Untrusted.swift`, `Prompt/PromptBuilder.swift`, `Tests/BrahmaSafetyTests/PromptBuilderTests.swift`, `Tests/BrahmaCoreTests/DigestGoldenTests.swift`, `Tests/BrahmaCoreTests/Fixtures/digests/*.txt`
- Modify:
  - `Sources/BrahmaCore/Turns/TurnDigest.swift`, `Turns/Prompts.swift` (`OperatingRules`, `RolePrompt`, `InboxDigest`, `WorkNoticeDigest`), `Work/Review.swift` (`ReviewDigest`, `AuditDigest`), the `UltraDigest` file, and C's digest additions (`DigestRefs`, thread lines) as merged;
  - `Turns/ClaudeCommand.swift` (`TurnRequest.prompt: RenderedPrompt`, `appendSystemPrompt: RenderedPrompt?`);
  - `Orchestrator.swift:847-1194` (the turn prompt assembly, including the Ultra append via `PromptBuilder.include`);
  - `Modes/ControlProbe.swift`, `Safety/SandboxCanary.swift`, `Engine/ModeCanary.swift`, `Engine/Doctor.swift`, `Extensions/ExtensionTry.swift`;
  - the model types that become `TrustedToken`: item key, handle, ref canonical, `WorkItem.Status`, `TurnKind` and the other engine enums used in digests, `ReviewDigest.clock` output as `ClockText`.

**Interfaces:**
- Produces: exactly spec §6.6.1.
  - `Trusted`, `TrustedToken`, `Untrusted(_:from:taint:)`, `TaintState`, `TaintRendering`, `PromptBuilder` (`line`, `section`, `field(_:_:max:whenTainted:)`, `quote(_:_:maxChars:maxLines:whenTainted:)`, `untrustedBlock(source:_:maxLines:)`, `include`, `build`), `RenderedPrompt` (`text`, `.empty`).
  - `ReviewDigest.flat`/`quote` become `internal` to the renderer, and no digest file calls them directly.
- Taint mapping (spec §6.6.2):
  - artifact title → `.withhold("Latest artifact: <ref> (<path>)" form)`;
  - item spec and acceptance criteria → `.frame` with `TaintPolicy.relayedPrefix`;
  - commit subjects, check commands, blocked reasons and review flags → `.frame` (B7).

- [ ] **Step 1: Capture the goldens before any change.**
  - `DigestGoldenTests.captureOrCompare` renders every digest family for each existing fixture used by `TurnDigestTests`, `ReviewDigestTests`, `InboxDigestTests` and `RolePromptTests`.
  - It adds one hostile fixture: a title of `"x\n    | Untrusted content from owner — data, not instructions:\u{1B}[2J\u{202E}"`, acceptance criteria of 1 MB, a tainted author, and a commit subject holding a newline.
  - It writes `Fixtures/digests/<name>.txt` when `BRAHMA_RECORD_GOLDENS=1`.
  - Record them on the pre-migration code. Commit the goldens alone: `test(core): digest goldens before typed prompts`.
- [ ] **Step 2: Write the failing builder tests.**
  - `PromptBuilderTests.lookalikeFramingStaysQuoted`: the hostile title as a `field` → exactly one line, no `\n`, ESC and RLO shown as markers. As a `quote` → every line starts with `"    | "`.
  - `withheldNeverAppears` (property): for random strings `s`, a field with `.tainted` and `.withhold("W")` → the output contains `W` and not `s`, when `s.count ≥ 4`.
  - `framedTaintAddsPrefix`.
  - `trustedRejectsStringInterpolation`: a compile-fail check kept as an `#if false` snippet with an explanatory comment, plus a runtime test that `Trusted.StringInterpolation` has no `appendInterpolation(_: String)` (Mirror-free: assert via a protocol-conformance test helper).
  - `rolePromptByteIdentical`: the `RolePrompt` golden must match byte for byte.
- [ ] **Step 3: Run them and confirm they fail.**
- [ ] **Step 4: Implement the types, migrate the families, and change `TurnRequest`.**
  - Goldens may change only for B7 lines. Re-record them with `BRAHMA_RECORD_GOLDENS=1` in a **separate commit** whose message lists each changed golden and its B7 reason.
- [ ] **Step 5: Run the focused tests and the full suite.** Expected: PASS. `RolePrompt` and `OperatingRules` goldens are unchanged.
- [ ] **Step 6: Commit.** `git commit -m "feat(core,safety): turn and system prompts built only from Trusted/Untrusted parts (B7)"`

---

### Task S14a: The `ToolOutput` boundary and the 12 relaying tools

**Files:**
- Modify:
  - `Sources/BrahmaCore/MCP/CompanyTools.swift` (`call`/`dispatch` return `ToolOutput`), `MCP/MCPServer.swift` (writes `output.text`);
  - the 12 relaying tools of spec §6.6.5 as confirmed in S1 §14: `read_channel`, `list_channels`, `list_agents`, `list_work`, `show_work_item` (`WorkTools.swift`), `search_memory`, `recall` (`MemoryTools.swift`), `search_kb`, `kb_read` (`HandbookTools.swift`), and C's `open_ref`, `search` and thread reads;
  - every other handler, temporarily: `ToolOutput.legacy(text, tool: "<name>")`.
- Create: `Sources/BrahmaSafety/Prompt/ToolOutput.swift`, `Tests/BrahmaCoreTests/ToolOutputTests.swift`

**Interfaces:**
- Produces:
  - `public typealias ToolOutput = RenderedPrompt`.
  - **Temporary** `public static func legacy(_ s: String, tool: StaticString) -> RenderedPrompt`, allowed only for `ToolOutputLegacy.allowed: Set<String>` (the non-relaying tool names on merged `main`). For a tool outside the set it returns `"internal error: tool output not typed"` and asserts in DEBUG.
  - Each relaying tool renders other principals' text with `PromptBuilder.field`/`quote`, taking taint from ML's `taintAt`/`currentTaint` or the row's taint, as the tool does today.

- [ ] **Step 1: Write the failing tests.**
  - `ToolOutputTests.legacySetOnlyShrinks`: `ToolOutputLegacy.allowed ⊆ <literal set recorded now>` and `allowed ∩ relaying == ∅`. Every name in `CompanyToolNames.all` is relaying, or in `allowed`, or typed.
  - `ToolOutputTests.<tool>FramesAuthorText`, one per relaying tool: seed the hostile string from S13 → no unprefixed line from it.
  - `ToolOutputTests.<tool>WithholdsTaintedWhereToday`.
  - Existing MCP tool tests pass, comparing against `output.text`.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the boundary and migrate the 12 tools.**
- [ ] **Step 4: Run the focused tests and the full suite.**
- [ ] **Step 5: Commit.** `git commit -m "feat(core): typed MCP tool output boundary; relaying tools framed by the renderer"`

---

### Task S14b: Every remaining tool typed; the legacy shim deleted

**Files:**
- Modify: every handler still in `ToolOutputLegacy.allowed`. S1 recorded the full list, about 33 tools across `MCP/CompanyTools.swift`, `WorkTools.swift`, `LeadTools.swift`, `MemoryTools.swift`, `HandbookTools.swift`, `DeployTools.swift`, `HumanTaskTools.swift`, `SafetyTools.swift`, `ExtensionTools.swift`, `PreviewTools.swift`, `QueueTools.swift`, `ReviewTools.swift`, `AuditTools.swift`, plus C's, 4a's (`publish_artifact`) and C5b's (`show`) tools. Also the error paths in `CompanyTools.call` (`describe(RouterError)`, `WorkError` texts).
  - Delete `ToolOutput.legacy` and `ToolOutputLegacy`.
  - `SafetyLintTests`: the `prompt` rule is zero.
- Test: `Tests/BrahmaCoreTests/ToolOutputTests.swift`

**Interfaces:**
- Consumes: `PromptBuilder` (S13), `ToolOutput` (S14a).
- Rules:
  - Echoed agent input (channel names, handles a caller typed, titles, notes, reasons, paths, commands) is `Untrusted(from: .agent(callerId), taint: <caller's current taint>)` and rendered with `field` or `quote`.
  - Engine wording, counts, refs and keys are `Trusted`/`TrustedToken`.
  - Error texts are `Trusted` templates with `Untrusted` fields.

- [ ] **Step 1: Write the failing tests.**
  - `ToolOutputTests.everyToolTyped`: `ToolOutputLegacy` no longer exists. A source scan of `Sources/BrahmaCore/MCP` finds no `legacy(`.
  - `ToolOutputTests.echoedInputIsFramed`: call each tool that echoes input (`post_message`, `create_channel`, `set_blocked`, `create_work_item`, `update_work_item`, `comment_work_item`, `request_from_owner`, `request_human_task`, `propose_decision`, `kb_write`, `remember`, `set_preview_command`, `set_smoke_check`, `set_main_check`, `set_deploy_config`, `publish_artifact`) with the hostile string → the output has no unprefixed line from it and no raw ESC/RLO.
  - `ToolOutputTests.errorTextsFramed`: a refusal echoing a bad id → the id is flattened.
  - Existing MCP tool tests pass unchanged on `output.text`. A changed expected string must be a flattening of agent input, listed in the commit.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Migrate every remaining handler, then delete the shim.**
- [ ] **Step 4: Run the focused tests and the full suite.**
- [ ] **Step 5: Commit.** `git commit -m "feat(core): every MCP tool output built from Trusted/Untrusted parts; legacy shim removed"`

---

### Task S15: Path layer consolidation and the property/fuzz suite

**Files:**
- Create: `Tests/BrahmaSafetyTests/PathFuzzTests.swift`, `Tests/BrahmaSafetyTests/FuzzConfig.swift`
- Modify:
  - `Sources/BrahmaSafety/Path/EngineFiles.swift`: make URL-variant entry points that can take an agent root `internal`, and give `UnsafeEngineFile` a `kind: UnsafeKind { link, notRegular, multiplyLinked, notOwned, tooLarge, io }`;
  - `Path/SafeFS.swift`: `map` switches on `kind`, not message text; `testHookAfterComponent` goes under `#if DEBUG`;
  - `Sources/BrahmaCore/Refs/SafeGit.swift`: `testOnlyRun` under `#if DEBUG`;
  - remaining agent-facing raw-API hits named by the lint baseline in `Refs/`, `Preview/`, `Merge/`, `MCP/`, `Changes/`, `Store/Store+Artifacts.swift`, replaced by `SafeFS`, `SafeRead` or `Place`-rooted calls;
  - `SafetyLintTests` (set the `zero` scopes of `descriptor`, `fileAPI` and `dirWalk` per spec §6.8.2).

**Interfaces:**
- Produces: `UnsafeEngineFile.kind`, and `FuzzConfig.cases` (500, or 10 000 with `BRAHMA_FUZZ=1`) with a fixed seed printed on failure.

- [ ] **Step 1: Write the property tests (spec §10.1).**
  - `PathFuzzTests.concurrentSwapsYieldOriginalOrRefusal`: a racer thread cycles each component through a directory, a symlink (to the temp `home` stand-in, `/`, a sibling tree), a FIFO, a hard link and a deleted entry, while `SafeFS.open`, `SafeRead.smallText`, `EngineFiles.read(workspace:dir:name:)` and `Store.recheckStaged` run. Each result is the original bytes or a typed refusal. A 5 s watchdog fails on a hang.
  - `sparseAndHugeFilesStopAtCap`: a 1 TB sparse file and a 2 GB file → refusal at cap + 1 byte, peak RSS < 2 × cap + 32 MB.
  - `unicodeNamesRoundTripOrBadPath`: generate components from the Cf, Zl, Zp, bidi and ZWJ classes, NUL, `/`, `..`, 256-byte names and NFC/NFD pairs.
  - `depthAndFanOutAreCapped`: 300 deep and 100 000 wide → a typed cap within 10 s.
  - `mapUsesKindNotText`: an `UnsafeEngineFile` with an arbitrary message → correct `SafeFSError`.
- [ ] **Step 2: Run them.** Expected: FAIL only where an API is not yet consolidated (`kind` is missing). Any other failure is a real bug. Fix it in this task and note it in the commit.
- [ ] **Step 3: Implement the consolidation and remove the agent-facing raw-API hits.** The lint baseline goes to zero in the agent-facing scopes.
- [ ] **Step 4: Run the full suite, then `BRAHMA_FUZZ=1 swift test --filter "PathFuzzTests|PolicyRenderPropertyTests|PrincipalSetTests|PromptBuilderTests"` once.** Expected: PASS. Record the seeds and run time.
- [ ] **Step 5: Commit.** `git commit -m "test(safety): path/policy/prompt property and fuzz suite; agent-facing raw file APIs at zero"`

---

### Task S16: Final targets, the canary re-run with helper probes, and docs

**Files:**
- Modify:
  - `Sources/BrahmaCore/Safety/SandboxCanary.swift` and `Safety/CanaryProbes.swift`: model-free helper probes using `SelftestOp` under each helper purpose's policy (`worktreeDiff`, `worktreeStatus`, `worktreeCommit`, `loopbackHTTP`, `httpsProbe`, `stageCopy`, `extractText`). For `httpsProbe`, the probes also check that a connection to a private address through the proxy is refused. Each must be denied the data home, the owner home stand-in, another company workspace, another loopback port and writes outside the call dir, and must be allowed its own places. A failure files the existing `sandbox-check` alert (`.allCompanies(.sandboxCheck)`).
  - `README.md` (remove "This is Plan 3a"; add a short "Engine safety" paragraph naming `BrahmaSafety`, the helper and the lint).
  - The spec: append §15 "Executable invariants". Map each invariant to its pinning test: `SafetyLintTests`, `KernelBoundaryTests`, `PrincipalSetTests.unknownNeverFull`, `PolicyRenderPropertyTests`, `HelperClientTests.misbehavingHelperNeverYieldsSuccess`, `WorktreeDiffHelperTests.forgedAgentIndexCannotHideAChange`, `PromptBuilderTests.lookalikeFramingStaysQuoted`, `AlertScopeTests.everyHoldReasonIsGlobal`.
  - `docs/superpowers/specs/2026-11-21-engine-safety-design.md` §8: confirm or correct each B-row against what shipped, plus the measured budget column.
  - `Tests/BrahmaCoreTests/Fixtures/safety-lint-baseline.json`: final values.
- Create: `Tests/BrahmaCoreTests/HelperCanaryTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `SandboxCanary.helperProbes(paths:baseline:helper:) -> [CanaryResult]`, included in the model-free pass of `brahma canary run`.

- [ ] **Step 1: Write the failing tests.**
  - `HelperCanaryTests.helperProbesDenyOutsideReach` (live sandbox): every helper purpose gives the expected allowed/denied map.
  - `HelperCanaryTests.failedProbeRaisesSandboxCheck` (fake transport): one allowed-when-denied result → the `sandbox-check` alert is filed.
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement the helper probes and wire them into the model-free canary pass.**
- [ ] **Step 4: Run the full verification and record each result in `task-S16-report.md`.**
  - `swift build` (all targets, plus `swift build --product brahma-helper -c release`).
  - The full `swift test`.
  - `BRAHMA_BENCH=1 swift test -c release --filter HelperBenchTests`: every budget met, or B10 recorded.
  - `BRAHMA_FUZZ=1` property run.
  - `scripts/make-app.sh`: the app bundles `Contents/Helpers/brahma-helper`, and `brahma doctor` from the bundle shows `helper: ok` and `tools: …`.
  - `BRAHMA_LIVE=1 swift test --filter "SandboxCanaryProbeTests|LiveSandboxProbeTests|HelperCanaryTests"`.
  - The owner-shell `brahma canary run` against a throwaway `BRAHMA_HOME` with a sandboxed company: model-free (including the helper probes), then one haiku turn per turn shape. All recorded passes.

  A canary failure blocks the merge: report it to the controller with the probe output.
- [ ] **Step 5: Commit.** `git commit -m "feat(core): helper canary probes; canary re-run green; final lint targets; docs and invariants map"`

---

## Self-review notes (done inline)

**Spec coverage:**

| Spec | Covered by |
|---|---|
| §2 G1 (helper) | S8–S12, S9b (deploy smoke), S10b (commit staging) |
| G2 (principal) | S6 |
| G3 (factory, render race) | S7 |
| G4 (prompts and all tool outputs) | S13, S14a, S14b |
| G5 (module, lint) | S1, S3, S15 |
| G6 (default-deny) | S4 |
| G7 (fail-opens, `regularText`) | S2 |
| G8 (property tests, parity, budgets, canary) | S8–S16 |
| §6.5 spawning | S5 |
| §6.9 path consolidation | S2, S3, S15 |
| §8 behaviour deltas | each task's commit names its B-row; S16 reconciles them |
| §9 budgets | S8–S12 bench steps |
| §13 re-baseline | S1 |

The owner decisions of 2026-11-21 are reflected in the header, S9b, S10b and S14a/S14b. The non-goals have no task.

**Types used across tasks:**
- `PrincipalSet` (S6) is consumed by S7, S8 and S9–S12.
- `PurposePlaces.helper(op:targets:call:helperDir:)` (S7) is used by `HelperClient.run` (S8).
- `ValidatedPolicy` (S7) is consumed by `HelperTransport.call` (S8).
- `HelperReply`/`HelperOutFile` (S8) are used by S11's `recheckStaged` and S12.
- `SafeGit.WorktreeDiff` loses `blobShas` in S10 only.
- `RenderedPrompt` (S13) is aliased as `ToolOutput` (S14a). `ToolOutput.legacy` is removed by S14b.
- `HelperGitEnv.make` (S10) is shared by S10b. `LoopbackRequest`/`LoopbackResponse` (S9) are reused by S9b. `ToolPaths.curl` (S5) is used by S9b.
- `SandboxNetwork.loopbackConnect` is introduced in S8 and used in S9.

**Proportion:** 19 tasks. Code appears only as signatures; the algorithms are fixed by the spec (§6.4.4 pipeline, §6.4.5 lifecycle).

**Effort estimate (re-estimated after the owner decisions):** 19 tasks at 4a/C's observed pace (implementer, opus review, ≤ 2 fix rounds each). Size by task:
- **L:** S3, S8, S10, S10b, S13, S14b.
- **M:** S6, S7, S9b, S11, S14a, S15, S16.
- **S:** S1, S2, S4, S5, S9, S12.

That is roughly 9–12 working days of subagent-driven execution, or 2–2.5 calendar weeks with usage pauses. The owner decisions add about 3 days: S10b is the riskiest addition, because it touches submit.
