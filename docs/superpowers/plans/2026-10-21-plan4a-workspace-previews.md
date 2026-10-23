# Plan 4a — Brahma Merge Queue, Main Guard & Non-Web Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 4a sits on top of the plans before it in the build order. Amended Plan 3a gives each item a worktree and merges one approved item at a time. Plan 5-lite adds the sandbox, the secret scan, owner notices and the kill switch. Plan L adds the web preview, the main smoke, releases, deploys and repo import. Memory-lite is also in the order before 4a. On top of these, 4a adds:
- **A batched merge queue in plain code.** It replaces 3a's one-item merge step.
  - Approved items queue up. The engine rebases each verified commit onto `main`.
  - It re-runs the item's pinned check and a company "main check", hermetically in a fresh export of each candidate.
  - It applies 3a's flake and infrastructure rules, runs 5-lite's secret scan, and bisects failing batches.
  - It lands through 3a's merge-safety entry points. Every step is journaled and idempotent.
- **A main guard.** Only the queue (including its journaled engine commits) moves `main`. Any other move or rewrite is saved under a unique ref, and `main` is restored. The owner is told.
- **Previews beyond the web, from the same engine as L.**
  - Kinds: CLI demo output, backend smoke requests, the iOS Simulator (behind an owner approval, because it runs outside the sandbox) and macOS apps under a GUI sandbox policy.
  - Published artifacts for any industry pack (R-285): HTML, Markdown, PDF, images, tables, office documents, 3D models, CAD file cards, text and source-code files, and MP4/MOV video in a 9:16 phone frame for marketing clips.
  - Artifacts show before any preview runs (R-192).
  - Sprint-review demos reuse these previews.
  - App views for all of it, a merge-queue panel, and merge status in item detail.

**Architecture:**
- **Core.** The queue (`MergeQueue`, the `MergeBatch` journal, `MainGuard`) and the new adapters live in `BrahmaCore`.
  - They extend L's preview engine (`PreviewRunner`, `PreviewAdapter`, `PreviewDependencies`, `EngineLayout`, `EngineExport`); nothing L ships is duplicated.
  - Every engine git call goes through 3a's hardened `GitWorkspace`/`GitCommand`.
  - Every agent-written command runs through 5-lite's `SandboxedRunner` or sandboxed `CheckRunning`, in a fresh `.git`-free export. That covers builds, demos, servers, merge checks and built macOS apps.
  - Engine-fixed argv runs through plain `Process`: `xcrun simctl`, `lsof`, `ps`. The core therefore stays Linux-portable.
- **Landing.** Landing reuses 3a's `finishMerge`, with `MergeSafety.afterLanding` once per batch. L's main smoke picks up each new `main` head by itself.
- **App.** Rendering is app-side: terminal and backend views, WebKit, Quick Look (out of process), SceneKit for glTF only, AVKit, simulator screenshots and ScreenCaptureKit. App-to-engine requests are DB flags.

**Tech Stack:** Swift 6.2 toolchain (manifest stays `swift-tools-version: 6.0`), SwiftPM, GRDB.swift 7.x, swift-argument-parser 1.5+, Swift Testing, git ≥ 2.38. App target only: SwiftUI/AppKit/WebKit/QuickLookUI/ImageIO/SceneKit/AVKit/AVFoundation/ScreenCaptureKit. Also Xcode `xcodebuild`/`simctl`, and Claude Code CLI as pinned by 3a's `brahma doctor`.

**Spec:** `/Users/chandra/agent-company/docs/superpowers/specs/2026-10-20-agent-company-design.md`:
- §6.9 (iOS, macOS, CLI and backend adapters; sprint demos; Screen Recording only on first use);
- §6.16 B6 (a thin merge queue that rebases, runs checks, bisects and merges);
- §6.18 (deliverable previews for any industry pack);
- §6.13 (Linux-portable core);
- §6.24a (build order 3a → 5-lite → L → Memory-lite → 4a);
- **owner decision 2026-10-21 18:16 (R-285): non-software deliverable previews are in 4a**;
- chief review A7 (R-184, R-192): the artifact preview stays in 4a and shows before any preview runs.

Also `/Users/chandra/.claude/jobs/6d89b87c/tmp/operating-model-and-edge-cases.md` recommendation 10, the parts that stay in 4a:
- X-5: main protection;
- U-2 and X-9: a journaled merge;
- the pre-merge backup ref.

Inputs applied:
- `plan4a-after-L-changes.md`;
- `plan4a-buildercheck-fixes.md` items 1–15;
- `planL-4a-notes.md` A1–A7.

Builds on, all merged first:
- Plan 2;
- **amended Plan 3a** (`/Users/chandra/agent-company/.claude/worktrees/plan3a-work/docs/superpowers/plans/2026-10-20-plan3a-work-system.md`, with `plan3a-patch-notes.md`);
- **Plan 5-lite** (`/Users/chandra/.claude/jobs/6d89b87c/tmp/2026-10-21-plan5lite-safety.md`);
- **Plan L** (`/Users/chandra/.claude/jobs/6d89b87c/tmp/2026-10-21-planL-live.md`, 15 tasks);
- Memory-lite.

Plan 3b is not a dependency.

## Contract with 3a, 5-lite and L

The names come from the plan texts: † = 3a, ‡ = 5-lite, § = L. Task 1a's implementer checks each one against the merged code and records any rename in its commit message. Later tasks use the shipped names.

**3a (amended):**
- **Git.**
  - `struct GitWorkspace { let root: URL }`† runs every call through the hardened `GitCommand`†.
    - It resolves `GIT_DIR`/`GIT_WORK_TREE` from engine records.
    - It passes `-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -c diff.external= -c protocol.ext.allow=never` with env `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`, as engine identity `Brahma <engine@brahma.local>`.
    - Methods: `ensureRepo`, `worktreePath(key:)`, `branch(key:)`, `addWorktree`, `commitAll(in:message:)`, `removeWorktree`, `deleteBranch`, `head(of:)`, `mergeBase`, `nameStatus`, `diff`, `log`, `isDirty(in:)`.
  - `GitError.failed(command:status:stderr:)`†.
- **Merging (replaced step and kept effects).**
  - `approveForMerge(db:item:by:note:)`† is the single approval entry point, used by `Store.review` approve and by 3a's tier-S auto-approval (9c). It clears flags, sets `mergeState = .pending` (`MergeState { none, pending, verifying }`) and writes event `reviewApproved`.
  - 3a's tick merge step merges one pending item per company and calls `finishMerge(itemId:result:now:)`†, which receives the merge base and the main-side commit.
    - Before merging it commits a dirty root as `"Brahma: unattributed changes on main"`.
    - It refuses, raising `EngineAlerts.raise("main checkout is on <ref>; switch it back to main")`†, when the root's HEAD isn't `refs/heads/main`.
  - `finishMerge(.merged(c))` sets `done`, `doneAt` and `mergedCommit`, deletes the lease, writes event `merged`, removes the worktree and branch, runs `completeItem`†, and triggers `MergeSafety.afterLanding(companyId:mergedKey:)`† (dry-run and freshness).
  - `finishMerge(.conflict(files))` writes the conflict brief, clears `verifiedRevision`/`verifiedCommit`, sets `inProgress`, and sends the waking DM and notice (event `mergeConflict`).
  - **4a replaces the tick step and keeps both entry points.**
- **Verification.**
  - `CheckPaths`† (3a's amendment, not 5-lite's): `snapshotDir(key:revision:)` → `<ws>/.brahma/checks/<KEY>/rev<n>/`, `manifest(key:revision:)`, `runWorktree(runId:)` → `<ws>/.brahma/wt-check/<runId>`.
  - `CheckScripts`† (snapshot and `scriptHash`), and the integrity guard†: re-hash against the manifest; on a mismatch, status `error`, flag `"check snapshot tampered: <file>"`, item → `inProgress`.
  - `VerificationStatus`† including `inconclusive`. The inconclusive/infra rule†: a failure while an engine hold is active, or a tail classified `.network` by `EngineHealth.classify`†, is inconclusive and never blamed.
  - `CheckSpec`, `CheckOutcome`, `CheckRunning`†, `WorkItem.verifiedCommit`/`verifiedRevision`/`mergedCommit`†.
- **Events, wakes, items.** `WorkEventKind`† (has `merged`, `mergeConflict`), `recordItemEvent`†, `WakePolicy.noticeWakes`† in `Messaging/WakePolicy.swift`, `completeItem`†, `createWorkItem(by: .system)`†, `WorkError`.
- **Admission.** `Scheduler.select(… otherChildren:pressure:held:)`†, `MemoryPressure`†, `Store.setHold`†/holds†, `EngineAlerts.raise`†.
- **Asks.** `Store.propose(companyId:by:kind:risk:category:title:summary:payload:itemId:subjectId:supersedes:now:)`†, `AskKind.other`†, `ReservedMatters` category `"permissions"`† (owner under every preset), `applyAskEffects`†.
- **Plumbing.** `ChildEnvironment.make(base:extra:purpose:)`†, `Sender.system`, `MessageRouter.post/sendDM(db:…)`†, `TurnContext`/`TurnDigest`†, `CompanyTools`†/`CompanyToolNames`†/`RoleTemplate`†/`IndustryPack.rolesCovering`†, `requireOwnerShell()`†, `safe()`†, `Sprint`†, `SafeMarkdown`†, `MCPTests.executiveSeesEveryTool`, and the release/abandon paths in `Store+Leases`†.

**5-lite:**
- **Sandbox.**
  - `SandboxNetwork { none; outbound(allow:); loopbackListen(allow:ports:) }`‡ and `SandboxPolicy(writable:readable:network:toolchain:)`‡.
  - `SandboxedRunner.run(...)`/`spawn(...)`‡, `SandboxedProcess`‡, `SandboxRunners.platformDefault`‡ and `UnavailableSandboxRunner`‡.
  - `SandboxLayout(paths:company:agentHandle:)`‡ (`sharedCache`), `CompanyNetwork.scope(...)`‡ (`allowedDomains`) and the sandboxed `CheckRunning`‡.
- **Safety.**
  - `SecretScan.check(git:base:head:knownValues:)`‡ (findings never include values) and the known-values loader‡.
  - `Store.redactor`‡ (`apply`, `scrubFile`).
  - `TaintPolicy`‡ (`taintSafeTools`, `reviewedHighRisk`, `TaintTests.everyToolClassified`) and `UntrustedBlock.render(source:text:maxLines:)`‡.
- **Owner and stop.**
  - `Store.notifyOwner(companyId:title:body:)`‡.
  - `EmergencyStopObserver`‡ (`func stopAll(reason: String) async`, registered through `Orchestrator.init(…, stopObservers:)`) and `Store.engineStopped()`‡.
  - `RestoreHooks.afterRestore`‡.

**ML (Memory-lite, `/Users/chandra/.claude/jobs/6d89b87c/tmp/2026-10-21-planML-memory-lite.md`):**
- **File kinds (ruling a).** `Model/FileKinds.swift` (ML Task 6a) owns the whole table, and 4a defines none of it:
  - `ArtifactKind` (`html, markdown, pdf, image, video, table, spreadsheet, document, model3d, cad, text, code`, plus `from(fileName:)`, `isText` and `playlistExtensions = [m3u8, m3u, mpd, pls]`);
  - `ArtifactSniffer.matches(kind:ext:head:)` with one rule per extension, including the `video` rule;
  - `ArtifactPolicy` with 4a's caps unchanged (`maxFileBytes`, `maxVideoBytes`, `maxFolderBytes`, `maxFiles`, `titleMax`, `companyQuotaBytes`, `publishesPerHour`);
  - `ArchiveRatio.check(url:)` / `stats(url:)` and `ArchiveStats`.
- **Provenance.** `Model/Provenance.swift` (ML Task 1): `enum Provenance { owner, agent(String), engine, external(String) }` with `raw` and `init?(raw:)`.
- **Memory.** `MemoryIndex` (`search(companyId:scope:query:sources:limit:now:)`), `MemorySource`, `MemoryIngestDoc`, `Store.ingest(_:now:)` / `ingest(db:_:now:)`, `Store.removeMemoryDoc(companyId:source:sourceId:now:)`, `AccessClass` (`.company`), `Sensitivity`, `Reader`, and `ResourcePolicy.maxArchiveRatio`.
- **Ref forms.** Artifacts are `AR-<n>` (4a), asks `A-<n>` (alias `ask:<n>`) and resources `F-<n>`. `A`, `AR` and `F` are reserved prefixes, and `MemoryRefs.implied` resolves by them.
- **Migrations.** ML's are `"vML-memory"`, `"vML-kb"` and `"vML-resources"`, in that order. 4a's follow `"vML-resources"`.
Step 1 of Task 1a records the shipped names of these in the commit body.

**L:**
- **Layout and export.**
  - `EngineLayout`§ (`previewRuns` `.brahma/preview/runs`, `previewLogs` `.brahma/preview/logs`, `previewRun(commit:)`, `releasesDir`).
  - `EngineExport.export(workspace:commit:into:paths:)`§ produces a fresh tree with no `.git`.
- **Preview model.**
  - `PreviewKind`§ (`.web`), `PreviewStatus`§, `PreviewSurface`§, `PreviewState`§, `SmokeRequest`§/`SmokeResult`§ and `LoopbackURL`§.
  - `PreviewPolicy.server(_:run:company:sandbox:port:)`§ (writable `[run, previewLogs, sharedCache]`).
  - `PreviewLog`§, `PortAllocator`§, `HTTPProbing`§, `ListenProbing`§, `ProcessTable`§, `PreviewTimeouts`§.
  - `PreviewContext`§ (`surface, company, layout, run, commit, port, policy, environment, logURL, timeouts`), `PreviewUpdate`§, `PreviewAdapter`§ (`kind, availability, start, stop`), `PreviewDependencies`§ (`sandbox, http, listen, processes`) and `WebAdapter.startServer(_:deps:)`§.
- **Runner and tools.**
  - `PreviewRunner`§ (an `EmergencyStopObserver`; reconcile, debounce, crash loop, `maxConcurrentBuilds`; `init(store:paths:deps:sandboxLayout:timeouts:memory:clock:)`) and `FakeSandbox`§.
  - The `set_preview_command` tool and `brahma preview list|set|remove|restart`§.
  - `CompanyToolNames.ops`§ (`set_preview_command, set_smoke_check, set_deploy_config, propose_deploy`), on devops, architect and every executive.
  - `ActivityKind.preview`§ and `.release`§.
- **Releases.**
  - The main smoke tick (a run is queued for every new `main` head), `ReleasePolicy.mainIsGreen`§, and `refs/brahma/main-backup` (written before each deploy; 4a does **not** overwrite it).
  - `set_deploy_config`§, `proposeDeploy`§, `FakeHostingAdapter`§, the `ReleasesView`§, `brahma dev release-scenario`§ and `DemoSeed.live`§.
- **App.** `PreviewSnapshot`§ (`surfaces, states, live`), `PreviewTone`§, `PreviewTab`§, `PreviewTabs.make/defaultSelection`§, `PreviewBody`§ (`.empty, .status, .web`), `PreviewBodies.body`§, `PreviewNavigationPolicy.allowsWeb`§, `MainHealth`§, `PreviewPane`§ and `WebPreviewView`§.

**Decisions this plan pins (with reasons):**
- **Done means merged; the queue replaces 3a's step.**
  - `enqueueApproved` attaches to 3a's `approveForMerge` hook, so reviews and tier-S auto-approvals both enqueue (A3). It inserts a request pinned to `verifiedCommit`.
  - The queue sets `mergeState = .verifying` while a batch holds the item.
  - Landing calls `finishMerge(.merged(c), …, triggerAfterLanding: false)` per item, then `MergeSafety.afterLanding` **once per batch** (A3).
  - A conflict calls `finishMerge(.conflict(files))` with the merge base and the main-side commit.
  - Items with nothing ahead of `main` complete at approval.
- **One policy for `main` (the earlier 3a/4a conflict, plus fixes 1, 3 and 9).** The merge queue is the only writer of `main`, and that includes the unattributed-changes commit, which is a two-phase journaled step:
  1. Under `GitLock`, the queue builds the commit object without moving any ref (a temporary index, `write-tree`, `commit-tree -p <mainCommit>`; 3a's exact message and engine identity).
  2. It runs `SecretScan.check(base: mainCommit, head: <that commit>)`. A finding leaves the root untouched. The batch is re-queued without counting, the queue is held, and the owner is notified.
  3. It journals step `preparing` with `expectedParent = mainCommit` and `preparedCommit = <sha>`.
  4. It moves `main` with a compare-and-swap `update-ref refs/heads/main <sha> <mainCommit>` and refreshes the root index (`read-tree`; the working tree is unchanged).
  5. It journals `prepared`, setting `company.mainCommit = <sha>` in the same transaction.

  The guard compares `main` only with `company.mainCommit`. That value is written only by journaled queue steps, owner `adopt-main`, the 5-lite restore hook and first-tick adoption. A look-alike commit is foreign; agents can forge an author and subject but cannot write the journal.
  - Recovery at `preparing`: adopt when `main == preparedCommit`; discard when `main == expectedParent`.
  - Foreign moves are saved as unique `refs/brahma/foreign/<UTC stamp>-<n>`. When the root is on `main`, uncommitted edits are committed onto the foreign tip first.
  - When the root is **not** on `main`, the guard never touches the root. It restores with a compare-and-swap `update-ref refs/heads/main <mainCommit> <foreignTip>` and raises 3a's alert.
- **Hermetic merge checks (fix 6, A1).**
  - Rebases and merges happen in the engine-only `.brahma/wt/.merge` checkout, for git only.
  - Each candidate SHA is exported with L's `EngineExport` into a fresh `CheckPaths.runWorktree(runId:)`†. 3a's integrity guard runs there, then the pinned snapshot is overlaid, the check runs, and the export is deleted.
  - A tampered snapshot bounces with 3a's flag.
  - Failing runs follow 3a's rules: inconclusive or infra runs re-queue without blame, and every failing run is re-run once before an item is blamed. If the main check fails for the first item, it is re-run at `base`; failing there means main is already red, so the queue holds and notifies the owner (fix 2).
- **Backup refs (fix 15).** Before each landing the queue writes `refs/brahma/pre-merge/<batch number>` = the old `main`. L's `refs/brahma/main-backup` keeps its meaning (the last deployed release commit) and is never written by 4a.
- **Merge requests in flight are pinned (fix 8).** `cancelMerge` cancels only `queued` requests. Releasing or abandoning an item whose request is `running` or `landing` is refused: `"<KEY> is being merged (M-<n>); wait for the merge to finish"`.
- **The lock lives in the data home (fix 7).** `GitLock` uses `paths.home/run/git-<companyId>.lock`, which agents can't read or write.
- **Non-web previews extend L.**
  - The new kinds go into L's `PreviewKind`. `PreviewRunner` takes injected `adapters: [PreviewKind: any PreviewAdapter]` and picks the policy per kind:
    - web and backend use L's `server` with the allocated port;
    - cli and the macOS build use `oneShot(run:)`;
    - ios and macos builds use `appleBuild(run:)`;
    - macOS app runs use `guiApp(run:)`.
  - Every one runs in a fresh `previewRun(commit:)` export. Non-URL kinds get port 0 (`PORT=0`).
  - **iOS runs outside the sandbox.** The Simulator installs and runs the app itself, so an ios surface stays `unavailable` until the owner approves an owner-only `other` ask in the `permissions` category that says so (fix 4).
- **Artifacts are engine-owned copies under `.brahma/artifacts/`.**
  - Publishing opens each file `O_NOFOLLOW` after `realpath`, requires a regular file, and counts bytes while copying.
  - Magic bytes must match the extension. Per-company quota and per-agent rate limits apply.
  - Rendering happens in the app only, through one `FileBodyView(url:kind:root:provenance:)` that later plans reuse (Collab-MVP §6.1); the engine never renders anything.
    - For agent or external provenance (every artifact an agent publishes), PDF, Office, 3D and image thumbnails go through Quick Look **out of process**.
    - In-process ImageIO is used only for owner-trusted images, with a 64 MP cap.
    - glTF loads in process only when it is ≤ 20 MB (bounds-checked loader); larger files get the file card. CAD always gets a file card.
    - Video uses AVKit, and 9:16 clips sit in a reusable `PhoneFrame` that L's web viewport also uses.
    - Every renderer shares `RendererCaps`: lines cut at 4 KB, archive expansion ratio ≤ 100, and a timeout on every parse helper.
- **Channel posts carry engine-written status only (fix 12).** Sprint-demo posts list `ok`/`failed`, counts and the SHA. Raw demo lines, which are agent-influenced, appear only in the app.

## Global Constraints

Copied from Plans 3a, 5-lite and L and still binding:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The manifest stays `swift-tools-version: 6.0` and `.macOS(.v14)`.
- `BrahmaCore` stays Linux-portable: no AppKit, SwiftUI, Observation, CryptoKit or `Bundle.module`. `Process`, `FileManager` and `/bin/sh` are fine. Hashes use the FNV-1a 64 in `StableHash`. (5-lite: Security-framework code sits only inside `#if canImport(Security)`. `sandbox-exec` and `caffeinate` are reached through `Process` and degrade to the "unavailable" types when missing.)
- argv comes only from 3a's `TurnProfileCompiler` (extended by 5-lite); 4a does not change it. The prompt goes on stdin.
- Agent states stay exactly `ready, running, blocked, sleeping, killed`. Item statuses are exactly `backlog, ready, inProgress, inReview, done, blocked`.
- **Engine is the referee.** No MCP tool, CLI command or app action can set an item to `inReview` or `done`, or write a `verificationRun`. (L: and none writes a `release` status, a `mainSmokeRun`, or runs a deploy or rollback command. 4a: and none writes a `mergeRequest`, `mergeRun` or `mergeBatch`, moves `main` or sets `company.mainCommit`, except the owner-only `adopt-main`.)
- **Owner approval exists only through the owner's Inbox decision path** (3a's `ownerDecide` over asks). It is called only by `brahma approve` and the app, and never by `CompanyTools`. No message text from any sender changes a decision.
- Agent-controlled text printed by the CLI goes through `safe()`. In the app it uses `Text(verbatim:)`. In prompts, single-line fields are newline-flattened like `InboxDigest`, and multi-line fields are rendered as a block where every line is prefixed `    | `.
- New stored properties on existing records (`Company`, `Agent`, `Turn`, `TurnResult`) get default values, so existing memberwise inits and Plan 2 code keep compiling.
- Every turn and every check runs with `BRAHMA_AGENT_ID=<agent id>` and without `BRAHMA_DEV`. `brahma mcp` refuses an `--agent` that differs from `BRAHMA_AGENT_ID`. Owner-write CLI commands refuse to run when `BRAHMA_AGENT_ID` is set.
- **Cross-company ids.** Every Store method that takes an item, decision, sprint, lease or agent id from an agent-facing path (tools, and the `by:` and `agentId:` parameters) verifies that the object belongs to the acting agent's company, else `WorkError.forbidden("not in your company")`, and treats it as not found in the response text.
- Tests use Swift Testing, with one `@Suite struct <FileName>` per new test file (`@MainActor` for app models).
- Every commit message ends with:
  `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`
- **UI uses the BrahmaTheme design system from Plan 2** (brief: `/Users/chandra/.claude/jobs/6d89b87c/tmp/brahma-visual-design.md`, the "ops console"): panels with uppercase header strips, dense zebra tables with an accent left bar on the selected row, status chips, monospace for keys, ids, counts, timestamps and check output, and small bordered buttons with an accent primary. No ad-hoc colors, fonts or radii.
- Live tests run only with `BRAHMA_LIVE=1`. **Pacing (3a, owner on Max 5x):** `haiku` for individuals and `sonnet` for executives, never `opus`; Balanced mode; plan tier `max5x`. Merges and previews are plain code, not turns.
- Reserved matters, money, outbound messages, secrets and terminations never auto-approve under any preset (§6.24).

4a additions:
- **Sandbox.** Every agent-written command 4a runs goes through 5-lite inside a fresh `.git`-free export: `SandboxedRunner` for preview build, demo and run commands and built macOS apps; the sandboxed `CheckRunning` for merge checks. Only `git` (through `GitCommand`), `xcrun simctl`, `lsof` and `ps` use plain `Process`.
- **Git.** Every engine git call goes through 3a's `GitWorkspace`/`GitCommand`. 4a adds methods to `GitWorkspace` and never builds its own git argv.
- **Migrations** append after ML's last, `"vML-resources"` (ML follows L's `"vL-import"`), in this order: `"v4a-merge"`, `"v4a-merge-journal"`, `"v4a-preview-kinds"`, `"v4a-artifacts"`, `"v4a-demos"`. Never edit an earlier migration. Collab-MVP's `"vC-refs"`, `"vC-threads"`, `"vC-show"` and `"vC-changes"` come after `"v4a-demos"` (and before 4b's `"v4b-vacancy-note"`).
- **Agent-controlled text in 4a** includes commit subjects, file names (conflict lists, artifact names), preview logs, demo output, HTTP bodies, page titles, artifact titles and contents, and secret-scan labels.
  - In prompts it is quoted or flattened.
  - `@system` DMs and channel posts carry only engine-written reasons, counts, refs and paths.
  - Merge-run tails and `outputTail` are stored only after `Store.redactor`‡.
  - In the app, terminal output goes through `AnsiText`, and everything else uses `Text(verbatim:)`. HTML artifacts are confined by `PreviewNavigationPolicy.allowsArtifact` plus a content rule list that blocks everything except `file:` and `about:`.
- **Taint (A5).**
  - `TaintPolicy.reviewedHighRisk` += `set_main_check`.
  - `taintSafeTools` += `publish_artifact`, which copies a workspace file only and never takes a URL.
  - `TaintTests.everyToolClassified` must pass.
- **Kill switch (A4).** `MergeQueue` and the 4a adapters are stopped through `EmergencyStopObserver`‡. Nothing new starts while `Store.engineStopped()` is non-nil.
- **Cross-company tests.** `ArtifactTests.crossCompanyRefused` and `MergeQueueTests.crossCompanyItemIgnored`.
- `BrahmaAppModel` keeps Plan 2's rule: Foundation, Observation and BrahmaCore only. Apple UI frameworks appear only in `Sources/BrahmaApp`.
- **New `ActivityKind.merge`** (symbol `arrow.triangle.merge`), included in `ActivityFilter.work`.
- **Color tokens.**
  - Merge chips: queued `ready`; running/landing `running` (pulse); merged `success`; bounced `danger`; failed and held `warning`; cancelled `text2`.
  - `PreviewStatus.ran` uses `success`.
  - ANSI colors map to tokens: red `danger`, green `success`, yellow `warning`, blue `ready`, magenta `series[3]`, cyan `series[4]`, white/default `text0`, black/bright-black `text2`.
  - New tokens `BrahmaTheme.deviceRadius = 28` and `deviceBezel = 10`, used only by the phone frame.
- **Out of scope:**
  - the web preview, main smoke, releases, deploys, rollback and repo import (L);
  - worktree creation and the reviewer diff (3a);
  - maps (4b);
  - anything from 3b;
  - external comms (7);
  - GitHub remotes.

**Pinned numbers** (each is a `static let` on the owning type):

| Constant | Value | Owner |
|---|---|---|
| Merge batch size default / range | 1 / 1...8 | `MergeSettings` |
| Merge strategies | `ff` (rebase + fast-forward, default) · `merge` (rebase + `--no-ff` merge commit) | `MergeStrategy` |
| Main-moved re-queues / engine-error attempts before `failed` | 3 / 3 | `MergeQueue.maxRequeues`, `.maxAttempts` |
| Failing merge-check re-runs before blame | 1 (pass-after-fail ⇒ pass, run flagged `flaky`) | `MergeQueue.blameReruns` |
| Inconclusive merge-check retries | 3 (3a's rule) | `MergeQueue.maxInconclusive` |
| `GitLock` wait | 30 s | `GitLock` |
| Conflict files shown | 20 | `MergeOrientation` |
| Demo timeout | 120 s | `PreviewTimeouts.demo` |
| Artifact sizes | file 50 MB · video 500 MB · folder 200 MB / 500 files · title 120 chars | `ArtifactPolicy` |
| Artifact quota / rate | 2 GB per company · 20 publishes per agent per rolling hour | `ArtifactPolicy` |
| OpenAPI file | ≤ 2 MB, regular, inside the run | `OpenAPISummary` |
| Image decode (in process, owner-trusted only) | ≤ 64 000 000 pixels (width × height from properties, before decoding), thumbnail ≤ 4096 px | `RendererCaps.maxImagePixels` |
| glTF in process | file ≤ 20 MB; larger → file card | `RendererCaps.maxInProcessModelBytes` |
| Shared renderer caps | line 4096 bytes (truncated with `…`) · archive expansion ratio ≤ 100 · parse timeout 5 s | `RendererCaps` |
| Phone-frame aspect | width ÷ height in 0.5...0.6 | `VideoLayout.phoneRange` |
| Frames | iOS screenshot poll 500 ms · macOS capture ≤ 10 fps | app |
| Terminal caps | 2000 lines · 4096 bytes per line (`RendererCaps.maxLineBytes`) | `AnsiText` |
| CSV caps | 2000 rows × 100 cols · 1000 chars per cell · 4096 bytes per line | `CSVTable` |
| glTF caps | 2 000 000 vertices · 64 MB buffers | `GLTFMesh` |

## Review Focus

1. **Something other than the queue moves `main`.** Cases:
   - an agent commits at the root, resets, amends, or forges an "unattributed" commit;
   - the root is left on another branch;
   - the owner commits by hand;
   - a DB restore.

   Expected: foreign moves are saved under a unique ref and `main` is restored (by a ref compare-and-swap when the root is off `main`); the engine's journaled commit is accepted; restores re-adopt. → Task 3 `MainGuardTests.rewriteRestoredAndReported`, `.forgedUnattributedCommitIsForeign`, `.journaledUnattributedCommitAccepted`, `.rootOffMainRestoredByRefOnly`, `.restoreHookReadopts`.
2. **A crash at any merge step**, including between building the unattributed commit and journaling it. Expected: recovery resumes from the journal, and nothing merges twice or is lost. → Task 2 `MergeRecoveryTests.resumesFromEveryStep`, `.crashAfterPrepareCommitBeforeJournal`, `.landedCandidateRecordedOnce`.
3. **Red main, flakes and outages in the queue.** Cases: main is already red; a check is flaky; the network drops mid-check; the kill switch fires. Expected: no innocent item is bounced. A red main holds the queue and notifies the owner. Inconclusive runs re-queue. A pass-after-fail is a pass flagged flaky. A stop halts at the journaled step. → Task 2 `MergeBatchTests.redMainHoldsQueue`, `.flakyCheckRerunOnce`, `.networkFailureIsInconclusive`; Task 1b `MergeQueueTests.mergeQueueHonorsEmergencyStop`.
4. **Hostile files and output.** Cases:
   - renamed playlists or HTML posing as MP4/PDF, symlinks, a FIFO;
   - oversized images, malicious glTF accessors;
   - huge CSVs, ANSI floods;
   - HTML that fetches remote URLs;
   - conflict names that imitate digest lines.

   Expected: content sniffing refuses mismatches; only regular files are copied; parsers stop at their caps; untrusted formats render out of process; web content loads only `file:`. → Task 6 `ArtifactTests.magicBytesMismatchRefused`, `.fifoRefused`, `.symlinkEscapeRefused`; Task 8a `ArtifactParsingTests.gltfIndexOutOfRangeRefused`, `.gltfAccessorOverrunRefused`, `AnsiTextTests.dropsNonSGRSequences`; Task 1b `MergeQueueTests.conflictFileNamesQuoted`.
5. **Previews that escape their sandbox.** Cases: an iOS app (it runs outside Seatbelt), a macOS app whose bundle names `../../` as its executable, an `app_path` outside the run. Expected: iOS stays unavailable until the owner approves the stated risk; paths, bundle ids and executables are validated; macOS apps run under the GUI policy. → Task 7 `AppleAdapterTests.iosNeedsOwnerApproval`, `.bundleValidation`, `.macAppShowsWindowUnderPolicy` (live).

---

## File Structure

```
Sources/BrahmaCore/
  Merge/Merge.swift              MergeStrategy, MergeSettings, MergeRequestStatus, MergeFailure, MergeRequest, MergeRun, MergeOrientation
  Merge/MergeJournal.swift       MergeStep, MergeBatch
  Merge/GitLock.swift            GitLock (paths.home/run/git-<companyId>.lock); EngineLayout extension (mergeCheckout, mergeLogs, artifacts)
  Merge/GitWorkspace+Queue.swift detached checkouts, rebase, merge, prepare/advance main (CAS), ff with root check, refs, ancestry, -z conflict list
  Merge/MergeQueue.swift         MergeQueue (batch, hermetic checks, blame rules, bisect, land, recover, stop), MergeBatchOutcome
  Merge/MainGuard.swift          MainGuard, MainGuardResult
  Merge/BranchInspector.swift    DiffStat, BranchInfo, BranchInspector
  Store/Store+Merge.swift        enqueueApproved, queue queries and writes, journal, settings, holds, main check, mainCommit, adoptMain
  Preview/PreviewKinds.swift     PreviewKind cases, validate rules, policies, demo default, SimulatorControlling, MacAppLaunching, Unavailable*
  Preview/CLIAdapter.swift Preview/BackendAdapter.swift Preview/ArtifactAdapter.swift Preview/AppleAdapters.swift Preview/DemoRunner.swift
  Model/Artifact.swift           Artifact (ArtifactKind, ArtifactSniffer, ArtifactPolicy, ArchiveRatio and ArchiveStats are ML's Model/FileKinds.swift; Provenance is ML's Model/Provenance.swift; 4a adds none of them)
  Store/Store+Artifacts.swift
  MCP/QueueTools.swift           set_main_check, publish_artifact
  (modified) Model/Company.swift Model/Turn.swift Model/WorkItem.swift Messaging/WakePolicy.swift Org/IndustryPack.swift Org/SoftwarePack.swift
             Work/Review.swift (approveForMerge hook) Store/Store+Leases.swift (release/abandon refusal) Store/Migrations.swift Turns/TurnDigest.swift
             MCP/WorkTools.swift MCP/LiveTools.swift§ MCP/CompanyTools.swift Safety/Taint.swift‡ Preview/PreviewModel.swift§ Preview/PreviewAdapter.swift§
             Preview/PreviewRunner.swift§ Orchestrator.swift
Sources/brahma/  MergeCommands.swift ArtifactCommands.swift  (modified) PreviewCommands.swift§ DevCommands.swift StatusCommand.swift Brahma.swift
Sources/BrahmaAppModel/
  Preview/RendererCaps.swift AnsiText.swift OpenAPISummary.swift CSVTable.swift GLTFMesh.swift VideoLayout.swift FrameSource.swift
  Preview/FileBody.swift PreviewBodiesMore.swift ArtifactSnapshot.swift AppModel+Artifacts.swift
  Merge/MergeSnapshot.swift MergePresentation.swift AppModel+Merge.swift
  (modified) Preview/PreviewSnapshot.swift§ Preview/PreviewPresentation.swift§ Live/Snapshot.swift Presentation/Sidebar.swift Presentation/ActivityText.swift LaunchOptions.swift
Sources/BrahmaApp/
  Views/Preview/TerminalPreviewView.swift BackendPreviewView.swift FileBodyView.swift ArtifactPreviewView.swift QuickLookView.swift ImagePreviewView.swift FileCardView.swift
  Views/Preview/SimulatorFramesView.swift WindowCaptureView.swift ModelPreviewView.swift VideoPreviewView.swift PhoneFrame.swift
  Views/MergeQueueView.swift MergeSettingsSheet.swift ItemMergeSection.swift
  (modified) Theme/BrahmaTheme.swift Views/Preview/PreviewPane.swift§ Sidebar.swift DetailView.swift BacklogView.swift MainWindow.swift ActivityFeedView.swift
Tests/BrahmaCoreTests/
  MergeFixture.swift MergeStoreTests.swift MergeQueueTests.swift MergeBatchTests.swift MergeRecoveryTests.swift MergeCLITests.swift MainGuardTests.swift
  PreviewKindsTests.swift CLIAdapterTests.swift BackendAdapterTests.swift ArtifactTests.swift AppleAdapterTests.swift DemoTests.swift
  Fixtures/simctl-devices.json Fixtures/simctl-devicetypes.json Fixtures/artifacts/ (sniffing samples)  (LiveSmokeTests: + two tests; PackTests, MCPTests, TaintTests: edits)
Tests/BrahmaAppModelTests/
  AnsiTextTests.swift ArtifactParsingTests.swift ArtifactPresentationTests.swift MergePresentationTests.swift QueueModelLayerTests.swift
scripts/seed-demo.sh (extend)  scripts/fixtures/ (mock.html, parts.csv, clip-9x16.mp4, make-clip.sh)  README.md (extend)
```

---

### Task 1a: Merge schema, store and enqueue at approval

**Files:**
- Create: `Sources/BrahmaCore/Merge/Merge.swift`, `Store/Store+Merge.swift`, `Tests/BrahmaCoreTests/MergeFixture.swift`, `MergeStoreTests.swift`
- Modify:
  - `Store/Migrations.swift` (`"v4a-merge"`), `Model/Company.swift`, `Model/Turn.swift` (`ActivityKind.merge`);
  - `Model/WorkItem.swift` (`WorkEventKind` + `mergeQueued`, `mergeFailed`, both in the activity list), `Messaging/WakePolicy.swift`† (`mergeFailed` wakes the holder or assignee);
  - 3a `approveForMerge`† (calls `enqueueApproved`);
  - 3a `finishMerge`† gains `triggerAfterLanding: Bool = true` (the default keeps 3a's behavior);
  - `Store/Store+Leases.swift`† (release and abandon refuse while a request is running or landing);
  - `MCP/WorkTools.swift` (`review` text, `show_work_item.merge`), `Turns/TurnDigest.swift` (Merge lines).

**Interfaces:**
- Consumes: the contract section.
- Produces:
  - Migration `"v4a-merge"`:
    - `company` + `mainCheck TEXT` (JSON `CheckSpec`), `mainCheckSetById TEXT`, `mergeBatchSize INTEGER NOT NULL DEFAULT 1`, `mergeStrategy TEXT NOT NULL DEFAULT 'ff'`, `mainCommit TEXT`, `mergeHold TEXT`. `Company` gets the matching defaulted properties.
    - `mergeRequest(id TEXT PK, companyId FK cascade, itemId FK cascade, number INT NOT NULL, status TEXT NOT NULL, headCommit TEXT NOT NULL, checkRevision INT, baseCommit TEXT, candidateCommit TEXT, mergedCommit TEXT, batchId TEXT, failure TEXT, detail TEXT, conflictFiles TEXT NOT NULL DEFAULT '[]', outputTail TEXT, outputPath TEXT, attempts INT NOT NULL DEFAULT 0, requeues INT NOT NULL DEFAULT 0, inconclusive INT NOT NULL DEFAULT 0, retryRequestedAt, enqueuedAt, startedAt, finishedAt)`, with index `(companyId, status, number)`.
    - `mergeRun(id TEXT PK, companyId, batchId TEXT, requestId TEXT REFERENCES mergeRequest ON DELETE CASCADE, prefix INT, candidateCommit TEXT, kind TEXT /* main|item|mainAtBase */, itemId TEXT, command TEXT, scriptHash TEXT, status TEXT /* VerificationStatus */, attempt INT NOT NULL DEFAULT 1, flaky BOOLEAN NOT NULL DEFAULT 0, exitCode INT, outputPath TEXT, outputTail TEXT, startedAt, finishedAt)`.
  - `enum MergeStrategy: String, Codable, CaseIterable, Sendable { case ff, merge; var title: String /* "Rebase + fast-forward", "Rebase + merge commit" */ }`; `struct MergeSettings: Equatable, Sendable { var mainCheck: CheckSpec?; var batchSize: Int; var strategy: MergeStrategy; static let batchRange = 1...8 }`.
  - `enum MergeRequestStatus: String, Codable, Sendable { case queued, running, landing, merged, bounced, failed, cancelled; var title: String; var isOpen: Bool }`; `enum MergeFailure: String, Codable, Sendable { case conflict, itemCheckFailed, mainCheckFailed, secretFound, snapshotTampered, engineError, mainMoved }`.
  - `struct MergeRequest`, `struct MergeRun` (`Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord`, one property per column; `ref` = `"M-\(number)"`).
  - **Enqueue (A3).** `Store.enqueueApproved(db: Database, item: WorkItem, ahead: Int, secretFindings: [String], now: Date) throws -> MergeRequest?`, called from inside 3a's `approveForMerge` after its bookkeeping. The caller (`Store.review` or the 9c auto-approval path, both through `approveForMerge`) computes `ahead = revListCount("main..<verifiedCommit>")` and `secretFindings = SecretScan.check(base: main, head: verifiedCommit)` before the transaction.
    - `ahead == 0` → nil. The caller runs `finishMerge(.merged(head(main)))`.
    - Findings → bounce `.secretFound`.
    - Otherwise → a `queued` request (`headCommit = verifiedCommit`, `checkRevision = verifiedRevision`) and event `mergeQueued` `"queued to merge as M-<n> (position <p>)"`. The review tool returns `"Approved <KEY>; it is queued to merge as M-<n>."`.
  - Queries: `mergeRequests(companyId:statuses:limit: Int = 200)`, `latestMergeRequest(itemId:)`, `mergeSettings(companyId:)`.
  - Engine writes. None is reachable from `CompanyTools`; each is one transaction and refuses a request whose item belongs to another company. Every stored tail goes through `Store.redactor.apply` first.
    - `claimMergeBatch(companyId:size:now:)` moves `queued` requests to `running` (`attempts += 1`) and sets their items to `mergeState = .verifying`.
    - `recordMergeRun(_:)`.
    - `markLanding(requestIds:candidates:base:now:)`.
    - `recordLanded(_ landed: [(requestId: String, mergedCommit: String)], mainCommit: String, now:) throws -> [WorkItem]`. In one write: the requests become `merged`, `company.mainCommit` is set, and `ActivityEvent(kind: .merge, "<KEY> merged into main (<sha7>)")` is written. Then, **for each item whose status isn't already `done`** (fix 10), `finishMerge(itemId:result: .merged(mergedCommit), triggerAfterLanding: false)`†. Then `MergeSafety.afterLanding(companyId:mergedKey: <last key>)`† runs once.
    - `bounceMerge(requestId:failure:detail:conflictFiles:mergeBase:mainSide:outputTail:outputPath:now:)`:
      - `.conflict` → the request is `bounced`, then `finishMerge(.conflict(files), mergeBase:, mainSide:)`† (A3).
      - `.snapshotTampered` → 3a's tamper effect (its flag and DM).
      - Otherwise → the item becomes `inProgress` with `mergeState = .none`; event `mergeFailed` with `detail`; a system DM to the owner: `"<KEY> was not merged: <detail>. See Merge under Current work in your orientation."`. The DM never carries output.
    - `requeueMerge(requestIds:countsAsRequeue:inconclusive: Bool = false, now:)` sets the items back to `.pending`.
    - `failMerge(requestId:detail:now:)` sets `failed`, writes activity and calls `notifyOwner`‡ with title `"Merge M-<n> (<KEY>) stopped"` and body `"<detail>. Retry it from the merge queue or with brahma merge retry."`.
    - `setMergeHold(companyId:reason: String?, now:)`.
    - `cancelMerge(db:itemId:)` cancels **only `queued`** requests (fix 8). 3a's release and abandon refuse when a `running`/`landing` request exists: `"<KEY> is being merged (M-<n>); wait for the merge to finish"`.
  - Detail copy (exact):
    - item check: `"its check failed after rebasing on main (<exit n|timed out after <s>s|could not run>)"`
    - main check: `"the main check failed after rebasing on main (<…>)"`
    - secret: `"a possible secret (<labels…1>) is in the change; remove it, rotate it if it was real, and resubmit"`
  - `struct MergeOrientation: Equatable, Sendable { var request: MergeRequest; var position: Int?; static func load(store:item:) throws -> MergeOrientation? }`. `TurnContext` + `merge`. `TurnDigest` renders under 3a's commits block one of:
    - `Merge: M-<n> queued (position <p>)`;
    - `Merge: M-<n> merging`;
    - `Merge: M-<n> not merged — <detail…1>`, plus the quoted last 20 tail lines for a check failure (conflicts keep 3a's brief).

    `show_work_item` adds `"merge": {ref, status, failure, detail}`.

- [ ] **Step 1: Map the contract.** Read the merged 3a, 5-lite, L and Memory-lite code. Record the shipped name of every †, ‡ and § symbol, and use those names in all later steps.
- [ ] **Step 2: Write failing tests.** `MergeFixture` builds on 3a's `World` and `GitFixture`, with 5-lite's sandboxed check runner (or its fake), L's `FakeSandbox`, and `approve(_ key:, change:)` through the real tools. `MergeStoreTests`:
```swift
@Test func approvalQueuesThroughApproveForMerge() throws { /* review approve → M-1 .queued headCommit == verifiedCommit; events end [reviewApproved, mergeQueued]; tool text exact */ }
@Test func tierSAutoApprovalAlsoQueues() throws { /* 3a 9c auto path → M-1 queued */ }
@Test func noChangesCompletesAtApproval() throws { }
@Test func secretFoundAtEnqueueBounces() throws { /* "AKIA"+16 → no request; .inProgress; detail "(aws-key)"; no value anywhere */ }
@Test func cancelOnlyQueued() throws { /* queued → release cancels; running → release refused exact */ }
@Test func tailsAreRedacted() throws { /* outputTail containing a vault value stored as redacted */ }
@Test func mergeFailedWakesHolder() throws { }
@Test func digestMergeLines() { /* exact three forms */ }
```
- [ ] **Step 3:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MergeStoreTests`. Expected: FAIL.
- [ ] **Step 4:** Implement the migration, model, Store methods, hooks, refusals and digest lines.
- [ ] **Step 5:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS. 3a's merge tests still go through its own step until Task 1b.
- [ ] **Step 6:** Commit `feat(core): merge requests enqueued at approval with secret scan and digest lines` with the trailer lines, putting the contract mapping in the body.

---

### Task 1b: Git methods, lock and the merge queue replacing 3a's step (one request)

**Files:**
- Create: `Sources/BrahmaCore/Merge/GitLock.swift`, `Merge/GitWorkspace+Queue.swift`, `Merge/MergeQueue.swift`, `Merge/BranchInspector.swift`, `Tests/BrahmaCoreTests/MergeQueueTests.swift`
- Modify: `Orchestrator.swift`. The queue tick step replaces 3a's merge step†; leave 3a's step code unreachable, with a comment naming 4a. Register `MergeQueue` in `stopObservers`‡.

**Interfaces:**
- Consumes: Task 1a; 3a `GitWorkspace`/`GitCommand`, `CheckPaths`, the integrity guard, the inconclusive rule, `finishMerge`, `EngineAlerts.raise`; 5-lite sandboxed `CheckRunning`, `SecretScan`, `EmergencyStopObserver`, `engineStopped`; L `EngineExport`, `EngineLayout`.
- Produces:
  - `extension EngineLayout { var mergeCheckout: URL /* .brahma/wt/.merge */; var mergeLogs: URL /* .brahma/merge */; var artifacts: URL /* .brahma/artifacts */ }`.
  - `enum GitLock { static func withLock<T>(paths: BrahmaPaths, companyId: String, wait: Duration = .seconds(30), _ body: () throws -> T) throws -> T }` uses an exclusive `flock` on `paths.home/run/git-<companyId>.lock` (fix 7), polling `LOCK_NB` every 50 ms, and throws `GitLockError.timeout`. It is taken around every write to the root, `main`, refs and `.merge`. If 3a ships a git lock, use it at this path.
  - `extension GitWorkspace`. Every method goes through `GitCommand`; `.merge` uses the engine-resolved `GIT_DIR`:
    - `ensureDetachedWorktree(at:name:commit:)` and `checkoutDetached(in:commit:)` (`checkout --detach --force`, then `clean -fdx`).
    - `rebase(in:onto:upstream:) -> RebaseResult { ok(head), conflict(files: [String], mergeBase: String, mainSide: String) }`. Files come from `diff --name-only --diff-filter=U -z`, split on NUL (fix 14), and it aborts on conflict.
    - `mergeNoFF(in:commit:message:) -> String`.
    - `prepareRootCommit(message:parent:) -> String?`: a temporary `GIT_INDEX_FILE`, `add -A`, `write-tree`, `commit-tree -p <parent>`. It returns nil when the tree equals the parent's tree. It moves no ref.
    - `advanceMain(from:to:) -> Bool`: `update-ref refs/heads/main <to> <from>` (compare-and-swap), then `read-tree HEAD` at the root when the root is on `main`.
    - `rootBranch() -> String?` (`symbolic-ref -q HEAD`).
    - `fastForwardMain(to:) -> FastForwardResult { ok, blockedByLocalChanges, notFastForward, rootNotOnMain(ref: String) }` (A2). It checks `rootBranch() == "refs/heads/main"` first, then runs `merge --ff-only` at the root.
    - `updateRef(_:to:)`, `revParse(_:) -> String?`, `isAncestor(_:of:) -> Bool`, `revListCount(_:) -> Int`, `shortstat(base:head:) -> String`.
  - `struct DiffStat: Codable, Equatable, Sendable { var files, insertions, deletions: Int; static let zero; static func parse(shortstat: String) -> DiffStat }`; `struct BranchInfo: Codable, Equatable, Sendable { var branch: String; var worktreePath: String?; var ahead: Int; var behind: Int; var diff: DiffStat; var head: String? }`; `enum BranchInspector { static func info(git: GitWorkspace, key: String) throws -> BranchInfo }`.
  - `struct MergeBatchOutcome: Equatable, Sendable { var merged, bounced, requeued, failed: [String]; var held: String?; var mainCommit: String? }`.
  - `actor MergeQueue: EmergencyStopObserver { init(store: Store, paths: BrahmaPaths, checks: any CheckRunning /* 5-lite sandboxed */, knownValues: @escaping @Sendable () -> [(String, String)], clock: @escaping @Sendable () -> Date = Store.now); func runNextBatch(company: Company) async -> MergeBatchOutcome?; func stopAll(reason: String) async }`. In this task the batch size is 1, with no journal and no blame rules (Task 2 adds them). For request R with head H:
```
if store.engineStopped() != nil or company.mergeHold != nil → return nil
under GitLock: base = revParse("main"); if root dirty: c = prepareRootCommit("Brahma: unattributed changes on main", parent: base)
   → SecretScan(base, c) non-empty → setMergeHold("possible secret in uncommitted changes at the workspace root") + notifyOwner + requeue(false); return
   → advanceMain(from: base, to: c); company.mainCommit = c; base = c                       (Task 2 journals this as preparing/prepared)
ensureDetachedWorktree(.merge, base); checkoutDetached(.merge, H); rebase(onto: base, upstream: mergeBase(base, H))
   → conflict(files, mergeBase, mainSide): bounce(.conflict, files, mergeBase, mainSide)
candidate = HEAD; if .merge strategy: checkoutDetached(base); candidate = mergeNoFF(candidate, "Merge <KEY>: <title…1, ≤72>")
check run (hermetic, fix 6 / A1): runId → EngineExport.export(commit: candidate, into: CheckPaths.runWorktree(runId)); 3a integrity guard on the
   snapshot for R.checkRevision (mismatch → bounce(.snapshotTampered)); overlay the snapshot; sandboxed CheckRunning cwd = that dir,
   env ChildEnvironment.make(…, purpose: .check, extra: ["BRAHMA_AGENT_ID": "merge"]); delete the dir after; MergeRun row (tail redacted)
   order: company.mainCheck (if set), then the item check; first failure → bounce(main|itemCheckFailed, tail)
SecretScan(base, candidate) non-empty → bounce(.secretFound)
land, under GitLock: revParse("main") != base → requeue(countsAsRequeue: true)
   updateRef("refs/brahma/pre-merge/<n>", base) (fix 15; n = the request number here, mergeBatch.number from Task 2); markLanding
   fastForwardMain(candidate): .ok → recordLanded([(R, candidate)], mainCommit: candidate)
     .blockedByLocalChanges → requeue(false) | .notFastForward → requeue(true)
     .rootNotOnMain(ref) → requeue(false) + EngineAlerts.raise("main checkout is on <ref>; switch it back to main") (once per hold)
any GitError → requeue(false) while attempts < maxAttempts, else failMerge(detail)
```
  - `stopAll(reason:)` (A4) cancels the in-flight check (process-group terminate through `CheckRunning` cancellation) and the batch task. In this task, in-flight requests return to `queued` (not counted); Task 2 turns that into "stop at the journaled step". No batch is claimed while `engineStopped()` is non-nil.
  - Orchestrator tick step "merge" replaces 3a's step. For each running company with a queued request, no hold and no `mergeTasks[companyId]`, it starts `runNextBatch`. Batches count in `otherChildren`, and none starts while the engine is held or under critical pressure†. Cancellation and `waitUntilIdle` await `mergeTasks`.

- [ ] **Step 1: Write failing tests** in `MergeQueueTests`:
```swift
@Test func landsFastForwardThroughFinishMerge() async throws {
  /* merged; root has the file; item .done, mergedCommit == main; worktree + branch gone; mainCommit == main; refs/brahma/pre-merge/1 == old main;
     L's refs/brahma/main-backup unchanged; MergeSafety.afterLanding called exactly once */ }
@Test func mergeCommitStrategy() async throws { }
@Test func rebasesWhenMainMoved() async throws { }
@Test func conflictUsesFinishMergeWithBase() async throws { /* bounced; finishMerge(.conflict) received files ["a.txt"], mergeBase and mainSide; .merge clean */ }
@Test func conflictNamesParsedWithNul() async throws { /* file "a b\tc.txt" → exact name */ }
@Test func binaryConflictListed() async throws { }
@Test func branchWithMergeCommitsRebases() async throws { }
@Test func checksRunInFreshExport() async throws { /* check cwd is CheckPaths.runWorktree(runId), has no .git, deleted after; .merge never used as cwd */ }
@Test func tamperedSnapshotBounces() async throws { /* edit a snapshot file → bounced .snapshotTampered; 3a flag present */ }
@Test func mainCheckRunsFirst() async throws { }
@Test func mergesVerifiedCommitNotLaterEdits() async throws { }
@Test func secretInCandidateBouncesBeforeLanding() async throws { }
@Test func dirtyRootCommittedWithoutMovingRefFirst() async throws { /* dirty root → commit built, scanned, then CAS-advanced; mainCommit == it; item lands on top */ }
@Test func secretInDirtyRootHoldsQueue() async throws { /* uncommitted AKIA… at root → main unchanged, root untouched, mergeHold set, owner notified */ }
@Test func rootOnOtherBranchDoesNotLand() async throws { /* root `git checkout -b x` → no landing; request queued (requeues 0); one EngineAlerts.raise "main checkout is on refs/heads/x; switch it back to main" */ }
@Test func rootEditsDuringBatchRequeue() async throws { }
@Test func conflictFileNamesQuoted() async throws { }
@Test func reopenedItemQueuesAgain() async throws { }
@Test func crossCompanyItemIgnored() async throws { }
@Test func mergeQueueHonorsEmergencyStop() async throws { /* stop during a 2 s check → check process gone; request queued; no landing; no claim while stopped; after resume → lands */ }
@Test func orchestratorRunsQueueNotThe3aStep() async throws { }
@Test func branchInfoReadsRepo() throws { }
```
  Update 3a's merge tests to assert a queued request, then call `runNextBatch`, keeping their end-state assertions.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MergeQueueTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the layout extension, lock, git methods, `MergeQueue`, `BranchInspector` and the replaced tick step.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core): merge queue replaces the one-item step; hermetic re-checks, scans and safe landing` with the trailer lines.

---

### Task 2: Batching with bisect and blame rules, the journal and recovery, settings, `set_main_check`, `brahma merge`

**Files:**
- Create: `Sources/BrahmaCore/Merge/MergeJournal.swift`, `MCP/QueueTools.swift`, `Sources/brahma/MergeCommands.swift`, `Tests/BrahmaCoreTests/MergeBatchTests.swift`, `MergeRecoveryTests.swift`, `MergeCLITests.swift`
- Modify: `Store/Migrations.swift` (`"v4a-merge-journal"`), `Merge/MergeQueue.swift`, `Store/Store+Merge.swift`, `Org/IndustryPack.swift` (`ops` + `set_main_check`; new `design`), `Org/SoftwarePack.swift` (design list; version +1 once for 4a), 5-lite `Safety/Taint.swift`‡ (A5), `MCP/CompanyTools.swift`, `Orchestrator.swift` (`start()` recovery), `StatusCommand.swift`, `Brahma.swift`; `Tests/BrahmaCoreTests/PackTests.swift`, `MCPTests.swift`, `TaintTests.swift`‡

**Interfaces:**
- Consumes: Tasks 1a–1b; 3a `rolesCovering`, the inconclusive rule, `requireOwnerShell`, `safe()`; L `ops`§; 5-lite `TaintPolicy`, `notifyOwner`.
- Produces:
  - Migration `"v4a-merge-journal"`: `mergeBatch(id TEXT PK, companyId FK cascade, number INT NOT NULL, base TEXT, step TEXT NOT NULL, requestIds TEXT NOT NULL, expectedParent TEXT, preparedCommit TEXT, candidates TEXT NOT NULL DEFAULT '{}', landCommit TEXT, landedIds TEXT NOT NULL DEFAULT '[]', error TEXT, startedAt, updatedAt, finishedAt)`.
  - `enum MergeStep: String, Codable, CaseIterable, Sendable { case claimed, preparing, prepared, rebased, checked, backedUp, landing, landed, recorded, cleaned, done }`; `struct MergeBatch`.
  - `Store.advanceBatch(id:to:…)` refuses to move backwards: `WorkError.conflict("batch already at <step>")`. The `prepared` advance sets `company.mainCommit = preparedCommit` in the same transaction.
  - **Journal (fix 1).** Each step is written before its action and updated after it:
    - `claimed`;
    - `preparing`, recording `expectedParent` and `preparedCommit` **before** `advanceMain`;
    - `prepared`;
    - `rebased` (`candidates`);
    - `checked` (`landCommit`, `landedIds`);
    - `backedUp` (the `pre-merge` ref);
    - `landing`;
    - `landed`;
    - `recorded` (`recordLanded`);
    - `cleaned` (worktree removal);
    - `done`.

    Every action is idempotent: `advanceMain` and `updateRef` are compare-and-swap or same-value; a fast-forward to a commit `main` already contains is skipped; `recordLanded` skips `merged` requests and `done` items; removal tolerates absence.
  - **Blame rules (fix 2).** For any failing run, in this order:
    1. **Infra or inconclusive.** If 3a's inconclusive rule holds (hold active, `.network` tail, or `engineStopped`), the run is `inconclusive`. The batch re-queues without counting (`inconclusive += 1`). After `maxInconclusive` the request is `failed` with `"check could not run reliably (infrastructure)"`.
    2. **Re-run once.** Re-run the same check at the same candidate once (`attempt 2`). A pass is a pass with `flaky = true` and the item flag `"flaky check during merge: failed, then passed"`.
    3. **Main check failing at the first prefix.** If it is the main check failing at `lo == 1`, run it once at `base` (`kind mainAtBase`). If it fails there too, main is already red: re-queue everything without counting, `setMergeHold("the main check fails on main itself")`, and `notifyOwner`‡ with title `"Merge queue held"` and body `"The main check fails on main <sha7>, so no item is blamed. Fix main or change the main check, then run brahma merge resume <company>."`.
  - Batch algorithm (write it as stated):
```
tip = base; S = []
for R in batch: rebase R.head onto tip → conflict: bounce(R, conflict, files, mergeBase, mainSide); continue; else c_R; tip = c_R; S.append(R)
test(j) = at c_{S[j]} (fresh export each): main check, then item checks of S[1...j]; first failure after the blame rules → fail
if S.isEmpty → done
if test(k) passes → secret-scan(base, c_{S[k]}) → land(c_{S[k]}, S)
else: lo = 1, hi = k; while lo < hi { mid = (lo+hi)/2; if test(mid) passes { lo = mid + 1 } else { hi = mid } }
      if lo == 1 and the failing run is the main check → mainAtBase rule (may hold and stop here)
      culprit = S[lo]; if lo > 1 → secret-scan + land(c_{S[lo-1]}, S[1..<lo])
      bounce(culprit, main → mainCheckFailed; own → itemCheckFailed; earlier item's → itemCheckFailed with
             "its change made <KEY2>'s check fail after rebasing on main (<…>)")
      requeue(S[lo+1...], countsAsRequeue: false)
secret finding at land → bounce the item(s) whose own range holds it; requeue the rest (not counted)
```
  - Recovery: `MergeQueue.recover(company:) -> Int` runs from `start()` before scheduling.
    1. Steps `claimed`, `rebased` and `checked`: reset `.merge`, re-queue unbounced requests (not counted), and finish the batch with `error "interrupted"`.
    2. Step `preparing`:
       - `main == preparedCommit` → advance to `prepared` (adopting it), then case 1;
       - `main == expectedParent` → drop `preparedCommit`, then case 1;
       - anything else → case 1, and the guard handles `main`.
    3. Steps `prepared` (with `mainCommit` already set), `backedUp` and `landing`:
       - `landCommit` is an ancestor of `main` → continue from `landed`;
       - `main == base` → redo the fast-forward and continue;
       - otherwise → case 1.
    4. Steps `landed`, `recorded` and `cleaned`: run the remaining steps.
    5. Orphan `running`/`landing` requests → re-queue.
  - **Emergency stop (A4).** `stopAll` kills in-flight processes and leaves the batch at its last journaled step. `recover` runs on the first tick after `engineStopped()` clears.
  - Settings and holds:
    - `Store.setMergeSettings(companyId:_:by: Sender)` (owner/system).
    - `Store.setMainCheck(companyId:by agentId:check:now:)`, which refuses anyone outside `rolesCovering("cto")` with `"only the CTO can set the main check"` and calls `notifyOwner`‡.
    - `Store.requestMergeRetry(requestId:by:)` (owner).
    - `Store.resumeMergeQueue(companyId:by:)` (owner) clears `mergeHold`. A new `main` head whose `mainAtBase` passes also clears a red-main hold.
  - Tool lists:
    - `CompanyToolNames.ops`§ += `set_main_check`;
    - `CompanyToolNames.design = ["publish_artifact"]` goes to `designer`, `architect` and every executive (implemented in Task 6);
    - pack version +1, once for 4a;
    - `TaintPolicy.reviewedHighRisk` += `set_main_check`; `taintSafeTools` += `publish_artifact` (A5).
  - Tool `set_main_check {command: string | "none", timeout?: int}` returns `"Main check set: <command>."` or `"Main check cleared."`.
  - CLI:
    - `brahma merge <company>` (default `list`): header `main <sha7> · batch <n> · <strategy title> · main check: <cmd|none>[ · HELD: <reason>]`, then `M-<n>  <KEY>  <status>  @owner  <detail|sha7>`;
    - `merge settings <company> [--batch n] [--strategy ff|merge] [--main-check <cmd>] [--main-timeout s] [--clear-main-check]`;
    - `merge retry <company> <M-n|KEY>`;
    - `merge resume <company>`;
    - all owner-write except `list`; `brahma status` adds `  merge queue: <k> open`.

- [ ] **Step 1: Write failing tests.**
  - `PackTests`: `opsHasSetMainCheck`, `designList`, version +1.
  - `TaintTests.everyToolClassified` passes, and add `queueToolsClassified`.
  - `MergeBatchTests` (batch 3):
```swift
@Test func batchLandsAllWhenGreen() async throws { }
@Test func bisectFindsCulprit() async throws { }
@Test func earlierItemsCheckBlamesCulprit() async throws { }
@Test func conflictInBatchSkipsOnlyThatItem() async throws { }
@Test func secretInBatchBouncesOnlyItsItem() async throws { }
@Test func redMainHoldsQueue() async throws { /* main check fails at base too → nobody bounced; mergeHold set; owner notified exact; resume clears */ }
@Test func flakyCheckRerunOnce() async throws { /* fail then pass → merged; mergeRun attempt 2 flaky; item flag present */ }
@Test func networkFailureIsInconclusive() async throws { /* tail "getaddrinfo ENOTFOUND" → inconclusive, requeued not counted; 3 → failed with the infrastructure reason */ }
@Test func mainMovedOutsideQueueRequeues() async throws { }
@Test func settingsValidation() throws { }
@Test func mainCheckOnlyByCTO() throws { }
```
  - `MergeRecoveryTests`:
```swift
@Test(arguments: MergeStep.allCases.filter { $0 != .done })
func resumesFromEveryStep(step: MergeStep) async throws {
  /* stop right after writing `step`; recover; assert per step: request statuses, each item's status (done only once, with mergedCommit),
     worktree folders removed exactly for landed items, exactly one `merged` event per item, batch .done, mainCommit == main */ }
@Test func crashAfterPrepareCommitBeforeJournal() async throws { /* advanceMain done, `prepared` not written (step preparing) → recover adopts preparedCommit as mainCommit; guard .ok */ }
@Test func preparingNotAppliedIsDiscarded() async throws { /* main == expectedParent → preparedCommit dropped; root edits still uncommitted; next batch prepares again */ }
@Test func landedCandidateRecordedOnce() async throws { }
@Test func journalNeverMovesBackwards() throws { }
@Test func engineErrorRetriesThenFails() async throws { }
@Test func stopResumesFromJournal() async throws { /* stop at `checked` → after resume, recover then land */ }
```
  - `MergeCLITests`: `mergeListAndSettings`, `mergeSettingsRefusedInAgentShell`, `mergeRetryRequeues`, `mergeResumeClearsHold`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MergeBatchTests|MergeRecoveryTests|MergeCLITests|PackTests|MCPTests|TaintTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the journal, blame rules, batching and bisect, recovery, the stop path, settings, holds, tool lists, the tool and the CLI.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): batched, journaled merge queue with bisect, flake and red-main rules` with the trailer lines.

---

### Task 3: Main guard — only the queue moves `main`

**Files:**
- Create: `Sources/BrahmaCore/Merge/MainGuard.swift`, `Tests/BrahmaCoreTests/MainGuardTests.swift`
- Modify: `Store/Store+Merge.swift` (`adoptMain`), `Orchestrator.swift` (tick step "main guard" before "merge"; `RestoreHooks.afterRestore`‡ registration), `Sources/brahma/MergeCommands.swift` (`adopt-main`)

**Interfaces:**
- Consumes: Tasks 1a–2; 3a `EngineAlerts.raise`; 5-lite `RestoreHooks`, `notifyOwner`.
- Produces:
  - `enum MainGuardResult: Equatable, Sendable { case ok, adopted(String), restored(foreignRef: String, to: String), skipped }`; `enum MainGuard { static func check(company:store:git:paths:now:) throws -> MainGuardResult }`, under `GitLock`:
    - An unfinished `mergeBatch`, or `engineStopped()` → `.skipped`.
    - `mainCommit == nil` → `adoptMain(by: .system)` → `.adopted`.
    - `revParse("main") == mainCommit` → `.ok`. Uncommitted root edits are not a move.
    - Foreign case, `ref = refs/brahma/foreign/<yyyyMMdd-HHmmss UTC>-<n>`, with `n` the smallest suffix not already taken (fix 3):
      - **Root on `main`:**
        1. If the root is dirty, `commitAll(root, "Brahma: unattributed changes on main")` onto the foreign tip.
        2. `updateRef(ref, to: main)`.
        3. `reset --hard <mainCommit>` at the root.
      - **Root not on `main` (fix 3, A2):** never touch the root. `updateRef(ref, to: main)`, then `update-ref refs/heads/main <mainCommit> <foreignTip>` (compare-and-swap), then `EngineAlerts.raise("main checkout is on <ref>; switch it back to main")`.
      - Both: `ActivityEvent(kind: .merge, "main was changed outside the merge queue; restored to <sha7>, the other tip is saved as <ref>")` and `notifyOwner`‡ titled `"main restored"`, with that text and `"Run brahma merge adopt-main <company> if that change was yours."`. The result is `.restored`.
    - The guard never inspects authors or subjects; a commit is accepted only if it equals `mainCommit`.
  - `Store.adoptMain(companyId:by: Sender, commit:)` (owner/system) writes activity `"main adopted at <sha7> by <the owner|the engine>"`. CLI `brahma merge adopt-main <company>` (owner-write).
  - The restore hook re-adopts `main` after a DB restore.
  - Tick step "main guard" runs for every running or paused company, before "merge".

- [ ] **Step 1: Write failing tests** in `MainGuardTests`:
```swift
@Test func firstTickAdoptsMain() throws { }
@Test func rewriteRestoredAndReported() throws { }
@Test func uncommittedForeignEditsPreserved() throws { }
@Test func journaledUnattributedCommitAccepted() async throws { }
@Test func forgedUnattributedCommitIsForeign() throws { /* engine author + exact subject, not journaled → .restored */ }
@Test func rootOffMainRestoredByRefOnly() throws { /* root on branch x with a foreign main → root files and HEAD untouched; main == mainCommit via CAS; alert raised */ }
@Test func foreignRefNamesAreUnique() throws { /* two restores in the same second → "-1" and "-2" */ }
@Test func adoptMainAcceptsOwnerCommit() throws { }
@Test func guardSkipsDuringBatchAndStop() throws { }
@Test func restoreHookReadopts() throws { }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MainGuardTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the guard, `adoptMain`, the hook and the tick step.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): main guard restores foreign moves of main; adopt-main and restore re-adoption` with the trailer lines.

---

### Task 4: Non-web preview kinds on L's engine — model, policies, adapter injection, Apple protocols

**Files:**
- Create: `Sources/BrahmaCore/Preview/PreviewKinds.swift`, `Tests/BrahmaCoreTests/PreviewKindsTests.swift`
- Modify: `Store/Migrations.swift` (`"v4a-preview-kinds"`), L's `Preview/PreviewModel.swift`§, `Preview/PreviewAdapter.swift`§, `Preview/PreviewRunner.swift`§ (adapter injection, per-kind policy, `ran`, port 0, stop of 4a processes), `MCP/LiveTools.swift`§ (`set_preview_command` args), `Sources/brahma/PreviewCommands.swift`§, `Turns/TurnDigest.swift`

**Interfaces:**
- Consumes: L's preview model, policy, runner, tool and `EngineExport`§; 5-lite `SandboxNetwork`/`SandboxPolicy`/`SandboxLayout`/`CompanyNetwork`‡; 3a `Store.propose`, `ReservedMatters` "permissions", `applyAskEffects`.
- Produces:
  - Migration `"v4a-preview-kinds"`: `previewSurface` + `demo TEXT`, `openapiPath TEXT`, `appPath TEXT`, `bundleId TEXT`, `device TEXT`, `outsideSandboxAskId TEXT`, `outsideSandboxApprovedAt`; `previewState` + `simulatorId TEXT`, `outputPath TEXT`, `smokeResults TEXT NOT NULL DEFAULT '[]'`. The record types get matching defaulted properties.
  - `PreviewKind` + `backend, cli, ios, macos, artifact` (titles "Backend", "CLI", "iOS", "macOS", "Artifacts"). `PreviewStatus` + `ran` ("Ran").
  - `PreviewSurface.validate` replaces L's "only web" rule with these exact messages:
    - backend without run or url → `"a backend preview needs run and url"`
    - cli without demo → `"a cli preview needs demo"`
    - ios without build/app_path/bundle_id → `"an ios preview needs build, app_path and bundle_id"`
    - macos without build/app_path → `"a macos preview needs build and app_path"`
    - kind artifact → `"artifacts appear automatically; use publish_artifact"`
    - an absolute or `..` path → `"paths must be relative to the repo root"`
    - bundle_id not `^[A-Za-z0-9.-]{1,155}$` → `"bundle_id may contain letters, digits, '.' and '-'"`
    - device not `^[A-Za-z0-9 ()._-]{1,64}$` → `"device names are 1–64 letters, digits, spaces and ()._-"`

    L's name, command, url and smoke rules still apply.
  - `PreviewContext`§ + `outputURL: URL` (defaulted). `PreviewUpdate`§ + `simulatorId`, `smokeResults`, `outputPath` (defaulted). `PreviewTimeouts`§ + `demo = .seconds(120)`.
  - `struct DemoCapture: Equatable, Sendable { var ok: Bool; var line: String; var outputPath: String? }`. `PreviewAdapter`§ + `demo(_:state:) async -> DemoCapture`, with a default for web: one GET, `ok = status < 400`, line `"<name>: HTTP <status>"`.
  - Apple protocols, declared here (fix 5):
    - `protocol SimulatorControlling: Sendable { func availability() -> String?; func ensureDevice(name: String, deviceType: String?) throws -> String; func boot(_ udid: String) throws; func install(_ udid: String, app: URL) throws; func launch(_ udid: String, bundleId: String) throws; func terminate(_ udid: String, bundleId: String) throws; func shutdown(_ udid: String) throws; func screenshot(_ udid: String, to: URL) throws }`;
    - `protocol MacAppLaunching: Sendable { func availability() -> String?; func executable(inApp: URL, run: URL) throws -> URL }`;
    - `struct UnavailableSimulator` (`"iOS previews need macOS with Xcode"`) and `struct UnavailableMacApps` (`"macOS app previews need macOS"`).
  - `PreviewDependencies`§ + `simulator: any SimulatorControlling = UnavailableSimulator()`, `macApps: any MacAppLaunching = UnavailableMacApps()`.
  - `extension PreviewPolicy`. All three use network `.outbound(allow: CompanyNetwork.scope(...).allowedDomains)`:
    - `oneShot(_ l: EngineLayout, run: URL, company: Company, sandbox: SandboxLayout) -> SandboxPolicy`: writable `[run, l.previewLogs, sandbox.sharedCache]`, readable `[run]`, `toolchain: false`;
    - `appleBuild(...)`: the same with `toolchain: true`. The environment carries `BRAHMA_DERIVED_DATA=<sharedCache>/DerivedData/<surface>`, and 5-lite's role rule says to pass `-derivedDataPath` (fix 4);
    - `guiApp(...)`: writable `[sandbox.sharedCache/apps/<surface>]`, readable `[run]`, `toolchain: true` (fix 4).
  - `PreviewRunner`§ changes:
    - **Adapter injection (fix 5).** `init` + `adapters: [PreviewKind: any PreviewAdapter] = PreviewAdapters.defaults(deps)`.
    - **Per-kind policy.** web and backend run → L's `server(port:)`; cli → `oneShot`; ios and macos build → `appleBuild`; macos run → `guiApp`.
    - **Ports.** Non-URL kinds get port 0 (`PORT=0`).
    - **`ran`** is terminal: no crash tracking. It re-runs when `main` moves, the config changes or a restart is flagged.
    - **The ios gate (fix 4).** A new or changed ios surface whose `outsideSandboxApprovedAt` is nil stays `unavailable` with message `"waiting for the owner to allow a Simulator preview (it runs outside the sandbox)"`. The first time, it files one owner ask: kind `other`, category `permissions`, risk high, title `"Allow iOS Simulator preview <name>"`, summary `"The iOS Simulator installs and runs the app outside Brahma's sandbox: it can read and write the Simulator's own data and reach the network. Approve only if you trust this company's code."`. Approval (`applyAskEffects`) sets `outsideSandboxApprovedAt`; changing `build`, `app_path` or `bundle_id` clears it.
    - **Stop.** `stopAll(reason:)`§ also stops simulators and macOS apps (A4).
  - Tool `set_preview_command`§ accepts `kind: web|backend|cli|ios|macos` plus `demo?`, `openapi_path?`, `app_path?`, `bundle_id?`, `device?`. CLI `preview set` gains `--kind`, `--demo`, `--openapi`, `--app-path`, `--bundle-id` and `--device`.

- [ ] **Step 1: Write failing tests** in `PreviewKindsTests`:
  - `kindValidationMessages`;
  - `webStillValid`;
  - `toolAcceptsNewKinds`;
  - `policyPerKind` (cli → `.outbound`, readable `[run]`, writable `[run, previewLogs, sharedCache]`; ios build → `toolchain`; macos run → `guiApp`; backend → `.loopbackListen` with `ports == [allocated]`);
  - `injectedAdaptersUsed`;
  - `nonURLKindsGetPortZero`;
  - `ranIsTerminal`;
  - `iosNeedsOwnerAsk` (one ask with the exact summary; approval → leaves `unavailable`; changing `app_path` clears it);
  - `webDemoDefault`;
  - `previewCLIFlags`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "PreviewKindsTests|PreviewModelTests|PreviewRunnerTests"`. Expected: the new tests FAIL; L's tests pass.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): non-web preview kinds, per-kind sandbox policies and the iOS owner gate` with the trailer lines.

---

### Task 5: CLI and backend preview adapters

**Files:**
- Create: `Sources/BrahmaCore/Preview/CLIAdapter.swift`, `Preview/BackendAdapter.swift`, `Tests/BrahmaCoreTests/CLIAdapterTests.swift`, `BackendAdapterTests.swift`
- Modify: `PreviewAdapters.defaults`

**Interfaces:**
- Consumes: Task 4; L `WebAdapter.startServer`§, `HTTPProbing`§, `SmokeResult`§.
- Produces:
  - `CLIAdapter.start` runs an optional build, then `demo`, both through `deps.sandbox.run` with cwd `c.run`, policy `oneShot` and timeout `demo`. Output goes to `outputURL`, redacted with `Store.redactor.scrubFile` and capped at 1 MB. The result is `ran` with `"exit <n>"` or `"timed out after <s> s"`. `demo` re-runs it: `ok = exit 0`, line `"<name>: demo exit <n>, <lines> lines"`.
  - `BackendAdapter.start` calls `WebAdapter.startServer`, then runs the smoke requests (10 s each; JSON content type with a body). `ok = status != nil && (expectStatus.map { $0 == status } ?? status! < 400)`. The result is `running` with `"<ok>/<n> smoke requests ok"`, and the requests re-run on every restart. `demo` re-runs them.
  - `openapiPath` is resolved at start: `realpath` must be inside `c.run`, the file must be regular and ≤ 2 MB (fix 11). It is copied to `previewLogs/<surface>-openapi.json`, which is the only file the app reads, else message `"openapi_path must be a regular file of at most 2 MB inside the repo"`.

- [ ] **Step 1: Write failing tests.**
  - `CLIAdapterTests`: `demoOutputCaptured` (cwd == `c.run`, no `.git`), `demoFailureIsRanNotCrash`, `demoTimeout`, `outputIsRedacted`, `rerunWhenMainMoves`.
  - `BackendAdapterTests`: `smokeResultsRecorded`, `bodyIsCapped`, `smokeStaysOnOrigin`, `unreachableRequestRecordsError`, `openapiConfined` (a symlink out of the run → refused; 3 MB → refused).
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "CLIAdapterTests|BackendAdapterTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement and register both adapters.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core): CLI demo and backend smoke-request preview adapters` with the trailer lines.

---

### Task 6: Published artifacts — confined, sniffed, rate-limited, video and CAD included

**Files:**
- Create: `Sources/BrahmaCore/Model/Artifact.swift`, `Store/Store+Artifacts.swift`, `Preview/ArtifactAdapter.swift`, `Sources/brahma/ArtifactCommands.swift`, `Tests/BrahmaCoreTests/ArtifactTests.swift`, `Fixtures/artifacts/`
- Modify: `Store/Migrations.swift` (`"v4a-artifacts"`), `MCP/QueueTools.swift` (`publish_artifact`), `Turns/TurnDigest.swift`, `Brahma.swift`

**Interfaces:**
- Consumes:
  - ML `ArtifactKind`, `ArtifactSniffer`, `ArtifactPolicy`, `ArchiveRatio`/`ArchiveStats`, `ResourcePolicy.maxArchiveRatio` (`Model/FileKinds.swift`);
  - ML `Provenance` (`Model/Provenance.swift`);
  - ML `MemorySource`, `MemoryIngestDoc`, `Store.ingest(db:_:now:)`, `Store.removeMemoryDoc(companyId:source:sourceId:now:)`, `AccessClass.company`, `MemoryIndex.search`;
  - Task 1b `EngineLayout.artifacts`; Task 4 `DemoCapture`;
  - 3a `Store.lease(agentId:)`, `GitWorkspace.worktreePath(key:)`, `WorkError`, `Store.slug(for:)`.
- Produces:
  - Migration `"v4a-artifacts"`: `artifact(id TEXT PK, companyId FK cascade, number INT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, storedPath TEXT NOT NULL, entryFile TEXT NOT NULL, sourcePath TEXT NOT NULL, publishedById TEXT NOT NULL, itemId TEXT REFERENCES workItem ON DELETE SET NULL, bytes INT NOT NULL, createdAt)`.
  - **File kinds come from Plan ML** (`Model/FileKinds.swift`, ML Task 6a). 4a defines none of these types and adds no rows, caps or sniff rules to ML's file:
    - `ArtifactKind` (cases `html, markdown, pdf, image, video, table, spreadsheet, document, model3d, cad, text, code`, plus `from(fileName:)`, `isText` and `playlistExtensions`);
    - `ArtifactSniffer.matches(kind:ext:head:)` (fix 11; mismatch → `"the file's content doesn't match .<ext>"`);
    - `ArtifactPolicy` (`maxFileBytes` 50 MB, `maxVideoBytes` 500 MB, `maxFolderBytes` 200 MB, `maxFiles` 500, `titleMax` 120, `companyQuotaBytes` 2 GB, `publishesPerHour` 20);
    - `ArchiveRatio.check(url:)` / `stats(url:)` with `ArchiveStats`.

    Step 1 only checks that the shipped names match this list and records any rename in the commit. A value that differs is reported, and ML's value wins.
  - **The `code` kind.** `.code` (swift, ts, py, sh, sql, toml, … per ML's table; text rule) is **publishable**, at the 50 MB file cap. Every `switch` over `ArtifactKind` in 4a handles it: `FileBody.make` maps it to `.text`, so it renders as capped mono text, never executed or parsed. The playlist refusal text stays `"streaming playlists can't be published; publish the video file"`.
  - `Store.publishArtifact(companyId:by:sourcePath:title:itemKey:baseDirectory:now:) throws -> Artifact`, with exact messages:
    - **Resolution.** `realpath` must be inside the workspace (`"artifacts must be inside your company workspace"`) and outside `.brahma/` except the caller's own leased worktree. That covers `.brahma/preview/runs`, `.brahma/wt/.merge`, `.brahma/artifacts` and other worktrees: `"that folder can't be published"`.
    - **Each file.** Opened with `open(O_RDONLY | O_NOFOLLOW)` after `realpath`. `fstat` must show `S_ISREG` (`"only regular files can be published"`). Bytes are counted while copying, and the copy aborts as soon as the cap is passed. This applies per file inside folders too.
    - **Content.** Magic bytes must match.
    - **Archive bombs.** Zip-based kinds (xlsx, docx, pptx, key, pages, numbers, usdz) go through ML's `ArchiveRatio.stats(url:)`. A ratio above `ResourcePolicy.maxArchiveRatio` (100), a total uncompressed size above 2 GB, or `hasSymlink`/`hasUnsafeName` is refused with `"this archive expands too much to preview safely"`.
    - **Limits.** Size caps (`"artifact files are limited to 50 MB"`, `"videos are limited to 500 MB"`, `"folders are limited to 500 files and 200 MB"`). Quota: `"this company's artifacts use <n> GB of 2 GB; delete old ones first"`. Rate: `"you can publish 20 artifacts per hour"`.
    - **Folders and glTF.** A folder needs `index.html`, and any symlink inside is refused. glTF copies only bare-name siblings (`"unsupported glTF resource <uri>"`).
    - **Storage.** Copies go to `.brahma/artifacts/<number>-<slug(title)>/`. `itemKey` must be in the same company. Activity: `"AR-<n> published by @<h>: <title>"`.
  - `Store.artifacts(companyId:limit: Int = 20)`, `latestArtifact(companyId:)`, `artifactBytes(companyId:)`, `deleteArtifact(id:by: .owner)`.
  - **Memory (ML delta).** 4a adds the source `MemorySource("artifact")` (a static `artifact` in a 4a extension; ML's list is open to later plans). On publish, in the same transaction, it calls `Store.ingest(db:_:now:)` with `MemoryIngestDoc(companyId:, source: .artifact, sourceId: <artifact id>, ref: "AR-<n>", title: <title>, body: "<kind> artifact: <title>", access: .company, readerSet: nil, futureHolders: false, sensitivity: .normal, provenance: artifact.provenance, authorId: publishedById, itemId:, createdAt:)`, so Collab's Show bar finds artifacts through `MemoryIndex`. `deleteArtifact` calls `removeMemoryDoc(companyId:source:sourceId:now:)`. Test `publishedArtifactIsSearchable`.
  - `Provenance` is ML's (`Model/Provenance.swift`, with `raw` and `init?(raw:)`); 4a does not define it. `Artifact` + `var provenance: Provenance`, a computed property over ML's type: `publishedById == "owner"` → `.owner`, otherwise `.agent(handle)`.
  - Tool `publish_artifact {path, title, item?: KEY}` (the `design` list; taint-safe; no URL argument) returns `"Published AR-<n> “<title>” (<kind>); it shows in the preview pane."`.
  - `ArtifactAdapter.demo`: `ok = true`, line `"artifacts: latest AR-<n>"` (the title appears only in the app).
  - `TurnDigest`: `Latest artifact: AR-<n> <title…1> (<abs entry path>)`.
  - **Artifact keys are `AR-<n>`** (controller ruling: asks own `A-<n>`). `Artifact.ref` is `"AR-\(number)"`, with `number` a per-company sequence starting at 1. `Artifact.parseRef(_ s: String) -> Int?` accepts `AR-<n>` case-insensitively and a bare `<n>`. It **refuses** `A-<n>`, so an ask ref is never taken for an artifact; the CLI says `"artifact keys look like AR-<n>"`.
  - CLI: `brahma artifacts <company>` (`list`: `AR-<n>  <kind>  <title>  @<by>  <yyyy-MM-dd HH:mm>`, sanitized); `artifacts publish <company> <path> --title t [--item KEY]` (prints the tool's `Published AR-<n> …` line); `artifacts rm <company> <AR-n>` (owner-write).
  - **Rendering boundary (A6).** The engine never parses or renders spreadsheets, documents, PDFs, 3D or CAD files; only the app does, and those go through out-of-process Quick Look or the bounded loaders in Task 8a.

- [ ] **Step 1: Write failing tests** in `ArtifactTests`. Before writing them, check that ML's shipped `Model/FileKinds.swift` matches the consume list above (it is not edited here). The kind-table test below exercises ML's table, including `cad`, `video` and `code`:
```swift
@Test(arguments: [("mock.html", "html"), ("PRD.md", "markdown"), ("deck.PPTX", "document"), ("bom.xlsx", "spreadsheet"), ("parts.csv", "table"),
                  ("chair.glb", "model3d"), ("part.STL", "model3d"), ("part.STEP", "cad"), ("logo.svg", "image"), ("notes.txt", "text"), ("reel.MP4", "video"), ("main.swift", "code")])
func kindsByExtension(file: String, kind: String) { }
@Test func publishFromWorktreeCopies() throws { }
@Test func magicBytesMismatchRefused() throws { /* m3u8 text renamed reel.mp4 → mismatch; HTML renamed x.pdf → mismatch; fixture samples pass */ }
@Test func fifoRefused() throws { /* mkfifo in the worktree → "only regular files can be published", returns promptly */ }
@Test func symlinkEscapeRefused() throws { /* final-component symlink swapped after realpath → O_NOFOLLOW refuses */ }
@Test func engineFoldersRefused() throws { /* .brahma/preview/runs/<sha>/x.html, .brahma/wt/.merge/x, another item's worktree */ }
@Test func sizeCountedWhileCopying() throws { /* file grows past 50 MB during copy (test hook) → aborted, no partial artifact */ }
@Test func quotaAndRateLimit() throws { }
@Test func archiveRatioRefused() throws { /* a 10 KB docx-named zip whose central directory claims 50 MB → "this archive expands too much to preview safely"; a normal docx fixture passes */ }
@Test func playlistRefused() throws { /* reel.m3u8 → "streaming playlists can't be published; publish the video file" */ }
@Test func codeFilePublishes() throws { /* main.swift → kind code, entry copied, Published AR-n line says (code) */ }
@Test func gltfCopiesOnlyBareSiblings() throws { }
@Test func crossCompanyRefused() throws { }
@Test func roleFiltered() throws { }
@Test func digestLatestArtifactLine() throws { /* render contains "Latest artifact: AR-1 Landing mock (" */ }
@Test func artifactsCLI() throws { /* publish → stdout starts "Published AR-1"; list line starts "AR-1  markdown  Spec  @owner"; `artifacts rm Acme AR-1` ok; `artifacts rm Acme A-1` → exit 1 "artifact keys look like AR-<n>" */ }
@Test func publishedArtifactIsSearchable() throws { /* publish "Landing mock" → MemoryIndex(store:).search(companyId:scope: .owner, query: "landing", sources: nil, limit:, now:) contains ref AR-1 (company access, so an unrelated agent finds it too); after delete → absent */ }
@Test func artifactRefParsing() { /* "AR-3", "ar-3", "3" → 3; "A-3", "AR-", "AR-0", "AR-x" → nil */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ArtifactTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Add the small sniffing samples under `Fixtures/artifacts/`.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(core,cli): publish_artifact with confined, sniffed, rate-limited copies` with the trailer lines.

---

### Task 7: iOS Simulator and macOS app adapters, and the sprint-review demo

**Files:**
- Create: `Sources/BrahmaCore/Preview/AppleAdapters.swift`, `Preview/DemoRunner.swift`, `Tests/BrahmaCoreTests/AppleAdapterTests.swift`, `DemoTests.swift`, `Fixtures/simctl-devices.json`, `simctl-devicetypes.json`
- Modify: `Store/Migrations.swift` (`"v4a-demos"`), `PreviewAdapters.defaults`, `PreviewDependencies.live`§, `PreviewRunner`§ (`demo(sprint:)`), `Orchestrator.swift` (tick "demos"), `Tests/BrahmaCoreTests/LiveSmokeTests.swift` (`macAppShowsWindowUnderPolicy`)

**Interfaces:**
- Consumes: Tasks 4–6; 3a `Sprint`, `Store.sprints`, `MessageRouter.post(db:…)`; 5-lite `UntrustedBlock.render`‡.
- Produces:
  - `struct SimctlController: SimulatorControlling` runs `xcrun simctl …` through `Process`:
    - availability: off macOS, or when `xcrun --find simctl` fails → the unavailable message;
    - devices: a dedicated `Brahma <slug>` device, created with `deviceType` if listed, else the first iPhone (owner simulators are never touched);
    - `boot` tolerates "Booted".
  - `struct ProcessMacAppLauncher: MacAppLaunching`. `executable(inApp:run:)` does the following, with errors `"app_path must stay inside the repo"` and `"CFBundleExecutable must be a plain file name"` (fix 4):
    1. Requires `realpath(app)` inside `realpath(run)`.
    2. Reads `CFBundleExecutable` via `PropertyListSerialization`, refusing any name containing `/`, `..` or `'`.
    3. Requires `Contents/MacOS/<name>` to be a regular executable whose `realpath` is still inside the app.
  - `IOSAdapter.start`. It requires `outsideSandboxApprovedAt` (Task 4), else `unavailable`:
    1. Build through `deps.sandbox.run` (`appleBuild`).
    2. `realpath(c.run/appPath)` must be inside `c.run` and be a directory ending `.app`.
    3. `ensureDevice`, `boot`, `install`, `launch(bundleId)`.
    4. The result is `running` with `simulatorId`.

    `stop` runs `terminate` + `shutdown`. `demo` saves a screenshot to `previewLogs/<surface>-demo-<sprint>.png`, with line `"<name>: screenshot saved"`.
  - `MacAppAdapter.start` builds (`appleBuild`), resolves the executable, and calls `deps.sandbox.spawn("exec <executable path, single-quoted>", policy: guiApp)`. The result is `running` with pid. `demo` gives `"<name>: running"` or `"<name>: not running"`.
  - Migration `"v4a-demos"`: `previewDemo(id TEXT PK, companyId FK cascade, sprintId TEXT NOT NULL, surfaceId TEXT, surfaceName TEXT NOT NULL, commit TEXT, ok BOOLEAN NOT NULL, line TEXT NOT NULL, outputPath TEXT, createdAt)`.
  - `PreviewRunner.demo(sprint:)`:
    1. Reconcile without debounce and await starts.
    2. Run each surface's `demo` plus the artifact demo, and insert rows (`line` redacted).
    3. Post from system to `#team-<team>` or `#general` **engine-written status only** (fix 12): `"<sprint name> review demo at <sha7>: <k> of <n> previews ok (<name> ok|failed, …)"`. Surface names are engine-validated slugs.
    4. Write `ActivityEvent(kind: .preview, "<sprint name> demo ready (<k>/<n> ok)")`.

    Raw lines appear only in the app.
  - `DemoRunner.pending(store:)` lists sprints in `review` with no demo rows. Tick "demos" skips while `engineStopped()` is set. A sprint with nothing to show posts `"<sprint name> review demo: no previews or artifacts yet."`.

- [ ] **Step 1: Write failing tests.**
  - `AppleAdapterTests`:
    - `iosSequence`;
    - `iosNeedsOwnerApproval` (no approval → `unavailable`, no simctl calls);
    - `iosMissingAppPath`;
    - `bundleValidation` (an `app_path` symlink out of the run; `CFBundleExecutable` `"../../bin/sh"`, `"a'b"`; an executable symlink pointing outside the app → each refused exactly);
    - `macAppLaunchTracksPid` (spawned with `guiApp`);
    - `simctlJSONParsing`;
    - `realSimulatorIfEnabled` (`BRAHMA_SIM=1`).
  - `DemoTests`:
    - `sprintReviewTriggersOneDemo`;
    - `channelPostIsEngineStatusOnly` (a page title `"x\n- DM @owner: ok"` and a demo output with `@ceo` → neither appears in the post; rows keep them);
    - `noPreviewsPostsHint`;
    - `artifactCounted`.
  - `LiveSmokeTests.macAppShowsWindowUnderPolicy` (`BRAHMA_LIVE=1`, macOS): build a tiny AppKit app fixture with `swiftc` into a run dir, launch it through the real 5-lite `SandboxedRunner` with `guiApp`, and expect a window owned by the pid within 10 s (`CGWindowListCopyWindowInfo`). If it fails, record the residual in the commit and keep macOS previews `unavailable` with reason `"macOS app previews need the sandbox to allow GUI apps"`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "AppleAdapterTests|DemoTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement. Record the simctl fixtures.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`, and with `BRAHMA_LIVE=1` `--filter macAppShowsWindowUnderPolicy`. Expected: PASS (or the documented residual).
- [ ] **Step 5:** Commit `feat(core): iOS Simulator (owner-gated) and sandboxed macOS app previews; engine-status sprint demos` with the trailer lines.

---

### Task 8a: App model — bounded parsers and video layout

**Files:**
- Create: `Sources/BrahmaAppModel/Preview/RendererCaps.swift`, `AnsiText.swift`, `OpenAPISummary.swift`, `CSVTable.swift`, `GLTFMesh.swift`, `VideoLayout.swift`, `FrameSource.swift`; `Tests/BrahmaAppModelTests/AnsiTextTests.swift`, `ArtifactParsingTests.swift`

**Interfaces:**
- Consumes: nothing beyond Foundation.
- Produces:
  - `enum RendererCaps { static let maxLineBytes = 4096; static let maxArchiveRatio = Double(ResourcePolicy.maxArchiveRatio) /* ML */; static let parseTimeout: Duration = .seconds(5); static let maxImagePixels = 64_000_000; static let maxInProcessModelBytes = 20_971_520; static func truncateLine(_ s: Substring) -> String /* cut at a UTF-8 boundary ≤ 4096 bytes, plus "…" */; static func parse<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T /* runs detached; throws RendererError.timedOut after parseTimeout and cancels */ }`. Every helper below goes through `RendererCaps.parse` when called from the app, and the app shows a timeout as `.status("CAN'T SHOW THIS FILE", "it took too long to read", [])`.
  - `enum AnsiColor` (16 colors); `struct AnsiSpan: Equatable, Sendable { var text: String; var color: AnsiColor?; var bold: Bool }`; `enum AnsiText { static let maxLines = 2000; static func parse(_ text: String) -> [[AnsiSpan]] }`. It stays pure, so Collab reuses it for run logs:
    - SGR codes 0, 1, 22, 30–37, 39 and 90–97 apply;
    - every other CSI, OSC, DCS and lone ESC is dropped, and `\r` resets the line;
    - other controls are removed;
    - lines are cut with `RendererCaps.truncateLine` (4 KB), and parsing works from the end so only the last 2000 lines are ever built (fix 11).
  - `struct OpenAPIOperation`; `enum OpenAPISummary { static let maxBytes = 2_097_152; static func parse(_ data: Data) -> [OpenAPIOperation]? }` (JSON only, larger input → nil, ≤ 500 operations).
  - `struct CSVTable { var header: [String]; var rows: [[String]]; var truncated: Bool; static let maxRows = 2000; static let maxColumns = 100; static let maxCellChars = 1000; static func parse(_ text: String, separator: Character = ",") -> CSVTable }`. It is RFC 4180, stops reading at the caps, cuts cells at 1000 chars, and cuts any physical line at 4 KB.
  - `struct GLTFMesh { var positions: [Float]; var normals: [Float]?; var indices: [UInt32]; static let maxVertices = 2_000_000; static let maxBufferBytes = 67_108_864; static func load(_ url: URL) throws -> GLTFMesh }`; `enum GLTFError: Error { case invalid(String), unsupported(String), tooLarge }`:
    - all arithmetic is overflow-checked (`multipliedReportingOverflow`);
    - every accessor is validated against its bufferView (`byteOffset + count × stride ≤ byteLength`) and every bufferView against its buffer;
    - every index must be `< vertexCount`;
    - mode 4 only, VEC3 float positions and normals;
    - `.gltf` URIs are bare sibling names or `data:` base64 only.
  - `enum VideoLayout { case phone, plain; static let phoneRange = 0.5...0.6; static func layout(width: Double, height: Double, rotationDegrees: Double) -> VideoLayout }` swaps width and height for ±90° rotation.
  - `protocol FrameSource: AnyObject { func start(onFrame: @escaping @Sendable (Data) -> Void); func stop() }`; `SimulatorScreenshotSource(udid:interval: .milliseconds(500), shell:)` never overlaps two captures.

- [ ] **Step 1: Write failing tests.**
  - `AnsiTextTests`: `sgrColorsApplied`, `dropsNonSGRSequences`, `carriageReturnOverwritesLine`, `keepsLastLines`, `longLineCut`, `hugeInputBounded` (50 MB of `"a\n"` parses in < 2 s).
  - `ArtifactParsingTests`:
    - `csvQuotesAndCaps` (3000 rows → truncated; a 5000-char cell → 1000);
    - `rendererCaps` (`truncateLine` on 10 000 bytes of multi-byte text → ≤ 4096 bytes plus `…` on a UTF-8 boundary; `parse` of a body sleeping 10 s throws `timedOut` within 6 s);
    - `openAPIOperations`, `openAPITooLargeIsNil`;
    - `gltfTriangle`, `gltfRefusesPathURIs`, `gltfVertexCap`;
    - `gltfIndexOutOfRangeRefused` (index 7 with 3 vertices);
    - `gltfAccessorOverrunRefused` (count × stride past the bufferView);
    - `gltfOverflowRefused` (count `Int.max`);
    - `videoLayout` (1080×1920 phone; 1920×1080 plain; 1920×1080 rotated 90° phone; 1080×1350 plain);
    - `frameSourceNeverOverlaps`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "AnsiTextTests|ArtifactParsingTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(app-model): bounded ANSI, CSV, OpenAPI and glTF parsers and video layout` with the trailer lines.

---

### Task 8b: App model — preview tabs and bodies, artifacts and the merge snapshot

**Files:**
- Create: `Sources/BrahmaAppModel/Preview/FileBody.swift`, `PreviewBodiesMore.swift`, `ArtifactSnapshot.swift`, `AppModel+Artifacts.swift`, `Merge/MergeSnapshot.swift`, `MergePresentation.swift`, `AppModel+Merge.swift`; `Tests/BrahmaAppModelTests/ArtifactPresentationTests.swift`, `MergePresentationTests.swift`, `QueueModelLayerTests.swift`
- Modify: L's `PreviewSnapshot.swift`§ and `PreviewPresentation.swift`§, `Live/Snapshot.swift`, `Presentation/Sidebar.swift`, `Presentation/ActivityText.swift`, `LaunchOptions.swift`, `AppModel.swift`. Add placeholder switch arms in `BrahmaApp`.

**Interfaces:**
- Consumes: Task 8a; L `PreviewSnapshot`/`PreviewTabs`/`PreviewBody`/`PreviewBodies`/`MainHealth`§; Tasks 1–7 Store APIs; `BranchInspector`.
- Produces:
  - `PreviewSnapshot`§ + `artifacts: [Artifact]`, `demos: [PreviewDemo]`.
  - **Tabs (A7).** `PreviewTabs.make`§ puts the surfaces first, then `ARTIFACTS` (id `"artifacts"`) when any artifact exists, then `LIVE`. `defaultSelection` takes the first good surface, else ARTIFACTS, else LIVE, else the first tab. So with no preview running, the latest artifact shows (R-192).
  - `PreviewBody`§ + `.terminal(lines:footer:)`, `.backend(smoke:logTail:operations:)`, `.simulator(udid:)`, `.window(pid:)`, `.artifact(Artifact, all: [Artifact])`. `PreviewBodies.body`§ maps the new kinds. ran cli gets footer `"exit <n> · <sha7>"`, and `unavailable` → `.status("<NAME> UNAVAILABLE", message, [])`. The backend body reads only the engine's copied OpenAPI file.
  - `struct SmokeRow`.
  - `PreviewNavigationPolicy` + `allowsArtifact(_:root:)` (a file URL under root, or about:blank).
  - **`FileBody`, extracted beside `.artifact`** (Collab §6.1). It is a body for *any* file, so Collab's `resource` and `file` refs reuse it:
    - `struct FileBody: Equatable, Sendable { enum Mode { case web, markdown, quickLook, image, table, gltf, video, text, fileCard }; var url: URL; var kind: ArtifactKind; var root: URL; var mode: Mode; var bytes: Int64; static func make(url: URL, kind: ArtifactKind, root: URL) -> FileBody }`.
    - `make` stats the file but parses nothing. Modes:
      - pdf, spreadsheet, document, and model3d except gltf/glb → `.quickLook`;
      - gltf/glb → `.gltf` when ≤ 20 MB, else `.fileCard`;
      - cad → `.fileCard`; video → `.video`; image → `.image`; svg → `.web`;
      - text and code → `.text` (`code` is ML's new kind: capped mono text, never parsed).
    - `func effectiveMode(for p: Provenance) -> Mode`: for `.agent`/`.external`, `.image` becomes `.quickLook` (Quick Look thumbnail, out of process). In-process images are for `.owner` and `.engine` only.
    - `.artifact(Artifact, all:)` now renders through `FileBody.make(url: a.entryURL, kind: a.kind, root: a.storedPath)`. The video layout comes from the view (Task 9b).
  - `AppModel` + `phoneFrameOverride: [String: Bool]`, `selectArtifact(_:)`, `deleteArtifact(_:)`.
  - Merge:
    - `struct MergeSnapshot { var open, recent: [MergeRequest]; var settings: MergeSettings; var mainCommit: String?; var hold: String?; var unfinishedBatch: MergeBatch?; static func load(store:companyId:) throws -> MergeSnapshot }`;
    - `struct MergeRow`, `enum MergeRows`, `struct MergeSettingsForm` (validation messages `"Batch size must be 1–8"`, `"Timeout must be 1–3600 seconds"`);
    - `AppModel` + `mergeRows`, `mergeSettingsForm`, `saveMergeSettings`, `retryMerge`, `resumeMergeQueue`, and `itemMerge` (loaded detached).
  - `SidebarItem.mergeQueue` (under Work, after Releases), `AppSheet.mergeSettings`. `SelectTarget` parses `merge`, `merge-settings`, `preview:artifacts` and `artifact:<AR-n>` (through `Artifact.parseRef`; `artifact:A-3` is rejected).

- [ ] **Step 1: Write failing tests.**
  - `ArtifactPresentationTests`:
    - `tabOrderSurfaceArtifactsLive`;
    - `defaultShowsArtifactsBeforeAnyPreview` (one failed surface + one artifact → ARTIFACTS; a running web → web; no surfaces with live → ARTIFACTS when artifacts exist);
    - `bodiesForNewKinds`;
    - `fileBodyModes` (each kind; code → `text`; cad → `fileCard`; stl → `quickLook`; glb 1 MB → `gltf`, glb 25 MB → `fileCard`; png → `image`, effective `quickLook` for `.agent("design-1")` and `image` for `.owner`);
    - `navigationPolicy`.
  - `MergePresentationTests`: `rowsOrderAndText`, `settingsFormValidation`, `holdShown`.
  - `QueueModelLayerTests` (`@MainActor`): `snapshotCarriesMergeAndArtifacts`, `saveMergeSettingsPersists`, `retryAndResume`, `itemMergeLoads`, `selectTargets`, `phoneFrameOverrideToggles`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ArtifactPresentationTests|MergePresentationTests|QueueModelLayerTests|PreviewPresentationTests"`. Expected: the new tests FAIL; L's presentation tests are updated to the new tab order and pass.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: every target builds and all tests PASS.
- [ ] **Step 5:** Commit `feat(app-model): artifact tab and render modes, non-web bodies, merge snapshot` with the trailer lines.

---

### Task 9a: App views — terminal, backend and artifact previews

**Files:**
- Create: `Sources/BrahmaApp/Views/Preview/TerminalPreviewView.swift`, `BackendPreviewView.swift`, `FileBodyView.swift`, `ArtifactPreviewView.swift`, `QuickLookView.swift`, `ImagePreviewView.swift`, `FileCardView.swift`; `scripts/fixtures/mock.html`, `parts.csv`
- Modify: L's `Preview/PreviewPane.swift`§ (ARTIFACTS tab and body arms), `scripts/seed-demo.sh`

**Interfaces:**
- Consumes: Tasks 8a–8b; Plan 2 theme components; 3a `SafeMarkdown`†.
- Produces (all agent text is `Text(verbatim:)`):
  - `TerminalPreviewView(lines:footer:)`: `bg0`, mono `AnsiSpan` text with the token map, a `monoTiny` footer and auto-scroll.
  - `BackendPreviewView`: a SMOKE zebra table over a LOG tail, with an "API" toggle.
  - `ArtifactPreviewView(artifact:all:)`: a header (picker listing `AR-<n> <title>` with the ref in mono, kind chip, provenance chip `BY @<h>`/`BY YOU`, "Reveal in Finder"), then `FileBodyView(url: entryURL, kind:, root: storedPath, provenance: artifact.provenance)`.
  - `FileBodyView(url:kind:root:provenance:)` (reused by Collab-MVP for files and resources) switches on `FileBody.make(…).effectiveMode(for: provenance)`. File reads and parses run through `RendererCaps.parse`:
    - `.web` (html, and svg with JavaScript off): `WKWebView` with a non-persistent data store. Its content rule list (fix 11) is a catch-all block on `.*`, then `ignore-previous-rules` for `^file:` and `^about:`. It loads with `loadFileURL(entry, allowingReadAccessTo: storedPath)`, navigation is limited by `allowsArtifact`, and new windows are refused.
    - `.markdown`: `SafeMarkdown`†.
    - `.quickLook`: `QuickLookView`, an `NSViewRepresentable` `QLPreviewView` (out of process, system XPC). It is used for PDF, Office and non-glTF 3D, and for **agent/external images** through `QLThumbnailGenerator` at 2048 px.
    - `.image` (owner or engine provenance only): `ImagePreviewView`. ImageIO reads only the properties first. If `width × height > RendererCaps.maxImagePixels` (64 MP), it shows a file card. Otherwise it uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize = 4096`.
    - `.table`: a `CSVTable` zebra grid.
    - `.fileCard`: `FileCardView` (A6), a `Panel` with name, kind (`CAD`), size, published-by and an "Open in…" button that calls `NSWorkspace.open` with the owner's default app. No in-app render.
    - `.text`: mono text, ≤ 1 MB, each line through `RendererCaps.truncateLine`.
    - `.gltf` and `.video`: Task 9b.
  - `PreviewPane`§: the ARTIFACTS tab with the picker; artifacts show before any preview runs.
  - `seed-demo.sh` (Initech, after L's seed):
    1. **Copy** `scripts/fixtures/{mock.html,parts.csv,clip-9x16.mp4}` into `<workspace>/docs/` (fix 14).
    2. `brahma preview set Initech demo --kind cli --demo "printf '\033[32mPASS\033[0m streaks\n'; ls"`.
    3. `brahma artifacts publish Initech <workspace>/docs/mock.html --title "Landing mock"`, then the same for `parts.csv --title "Parts list"` and `clip-9x16.mp4 --title "Launch reel"`, which become `AR-1`, `AR-2` and `AR-3` in that order (the snapshot targets below rely on this).

- [ ] **Step 1:** Implement. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`. Expected: no warnings in new files.
- [ ] **Step 2: UI smoke.** `scripts/make-app.sh debug && scripts/seed-demo.sh`, then `scripts/ui-snapshot.sh task9a-cli preview:demo` and `scripts/ui-snapshot.sh task9a-table artifact:AR-2`. Read both. Expected: a green `PASS` line with the exit footer; the zebra table for `Parts list`.
- [ ] **Step 3:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 4:** Run `scripts/smoke-app.sh`. Expected: `SMOKE OK … lifecycle=ok`.
- [ ] **Step 5:** Commit `feat(app): terminal, backend and artifact previews (Quick Look, images, tables, file cards)` with the trailer lines.

---

### Task 9b: App views — simulator, macOS window, glTF and phone-framed video

**Files:**
- Create: `Sources/BrahmaApp/Views/Preview/SimulatorFramesView.swift`, `WindowCaptureView.swift`, `ModelPreviewView.swift`, `VideoPreviewView.swift`, `Sources/BrahmaApp/Theme/PhoneFrame.swift`; `scripts/fixtures/make-clip.sh`, `clip-9x16.mp4`
- Modify: `Sources/BrahmaApp/Theme/BrahmaTheme.swift` (`deviceRadius = 28`, `deviceBezel = 10`), L's `PreviewPane.swift`§ (Open Simulator and Bring to Front buttons; `.simulator`/`.window`/`.gltf`/`.video` arms)

**Interfaces:**
- Consumes: Tasks 8a–8b, 9a.
- Produces:
  - `SimulatorFramesView(udid:)` polls a `SimulatorScreenshotSource` from appear to disappear. The image is decoded with the ImageIO thumbnail path, and `"WAITING FOR SIMULATOR"` shows before the first frame. "Open Simulator" runs `open -a Simulator --args -CurrentDeviceUDID <udid>`.
  - `WindowCaptureView(pid:)`:
    - **Permission.** On first appear it calls `CGPreflightScreenCaptureAccess()`. If that is false, it shows `MonoEmptyState("SCREEN RECORDING NEEDED", detail: "Brahma needs Screen Recording permission to show the app's live window.")` and "Allow…" (`CGRequestScreenCaptureAccess()`). This is the only prompt.
    - **Capture.** `SCStream` (`desktopIndependentWindow`, ≤ 10 fps) of the largest window owned by the pid; `"NO WINDOW YET"` otherwise.
    - **TCC note (fix 4).** The Screen Recording grant is tied to the app's code signature. Ad-hoc debug builds (`make-app.sh debug`) get a new identity on each rebuild, so the grant may not persist and can't be verified in automated snapshots. Verify by hand on a release build and say so in the commit.
  - `ModelPreviewView(url:)`: an `SCNView` for **gltf/glb ≤ 20 MB only**, via `GLTFMesh` (through `RendererCaps.parse`) → `SCNGeometry` with a `text1` material. Larger files get the file card. Other 3D formats use Quick Look (Task 9a). Errors show `"CAN'T SHOW THIS MODEL"`.
  - `VideoPreviewView(artifact:)`:
    - `AVPlayerView` (inline controls) with `AVPlayer(url: entryURL)`, for file URLs that pass `allowsArtifact` only.
    - It reads `naturalSize`/`preferredTransform` (`AVURLAsset.load(.tracks)`), applies `VideoLayout` and `phoneFrameOverride`, and offers a "PHONE FRAME" `MonoChip` toggle.
    - It starts paused and muted, and loops when shorter than 60 s.
  - `PhoneFrame<Content: View>` lives in the theme, so L's `WebPreviewView(url:path:viewport:)` can host its `iphone` viewport in it (Collab §6.1). It has `init(aspect: CGFloat = 9.0 / 16.0, @ViewBuilder content: () -> Content)` and no knowledge of video or web. It uses `aspectRatio(aspect, contentMode: .fit)`, a `deviceBezel` bezel in `bg1`, a 1 px `lineStrong` outline, outer radius `deviceRadius` and inner radius `deviceRadius − deviceBezel`. Content is clipped, with no notch or brand mark, centered on `bg0` with `spaceL` padding.
  - `scripts/fixtures/make-clip.sh` (fix 14) writes `clip-9x16.mp4` when `ffmpeg` exists:
```
ffmpeg -y -f lavfi -i "color=c=0x1A2129:s=1080x1920:d=2,drawtext=text='Launch':fontcolor=0xE6EBF0:fontsize=120:x=(w-tw)/2:y=(h-th)/2" \
  -c:v libx264 -pix_fmt yuv420p -preset veryslow -crf 40 -an -movflags +faststart clip-9x16.mp4
```
    Otherwise it uses a Swift fallback (`swift scripts/fixtures/MakeClip.swift`, `AVAssetWriter` H.264 1080×1920, 2 s, 1 fps solid frames). The committed result is ≤ 300 KB, checked with `stat -f%z`.

- [ ] **Step 1:** Implement, and generate and commit the clip. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`. Expected: no warnings.
- [ ] **Step 2: UI smoke.** `scripts/make-app.sh debug && scripts/seed-demo.sh`, then `scripts/ui-snapshot.sh task9b-video artifact:AR-3`. Read it. Expected: the phone frame with the PHONE FRAME chip on. AVPlayer content may be blank in `cacheDisplay`; the frame must show.
- [ ] **Step 3:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 4:** Run `scripts/smoke-app.sh`. Expected: `SMOKE OK`, and no preview process is left after quit.
- [ ] **Step 5:** Commit `feat(app): simulator frames, sandboxed macOS window capture, glTF and phone-framed video` with the trailer lines, including the TCC verification note.

---

### Task 10: Merge-queue panel, item merge detail, docs and live end-to-end test

**Files:**
- Create: `Sources/BrahmaApp/Views/MergeQueueView.swift`, `MergeSettingsSheet.swift`, `ItemMergeSection.swift`
- Modify: `Sources/BrahmaApp/Views/Sidebar.swift`, `DetailView.swift`, `BacklogView.swift`, `MainWindow.swift`, `ActivityFeedView.swift`, 3a `Sources/brahma/DevCommands.swift`† (`dev merge-scenario`), `scripts/seed-demo.sh`, `README.md`, `Tests/BrahmaCoreTests/LiveSmokeTests.swift`

**Interfaces:**
- Consumes: Task 8b; L `MainHealth`§, `set_deploy_config`§, `proposeDeploy`§, `FakeHostingAdapter`§, `ReleasesView`§; 5-lite `MemoryVault`/`Store.setSecret`‡; Plan 2 theme components.
- Produces:
  - Sidebar: "Merge queue" under Work, after Releases, with a mono count of open requests.
  - `MergeQueueView`: `Panel(title: "Merge queue")`.
    - **Header.** `MAIN <sha7>`, `BATCH <n>`, the strategy, `MAIN CHECK <cmd|NONE>`, L's `MainHealth` chip, and "Settings…". A `warning` chip `HELD: <reason>` comes with a "Resume" button. A `running` chip `BATCH AT <STEP>` shows while a batch is unfinished.
    - **Table.** A zebra table with columns REF, KEY, TITLE, OWNER, STATUS, DETAIL, COMMIT and QUEUED. Failed rows have "Retry".
    - **Empty.** `MonoEmptyState("MERGE QUEUE EMPTY", detail: "Approved items with changes wait here while the engine rebases, re-runs checks and merges them.")`.
  - `MergeSettingsSheet`: batch `Stepper` 1–8, strategy `Picker`, main check and timeout fields. The validation message is in `danger`. Buttons are Cancel and Save.
  - `ItemMergeSection`: BRANCH, AHEAD / BEHIND, DIFF, VERIFIED and MERGE (chip, `M-<n>`, position or detail), plus the redacted check-failure tail. Conflicts keep 3a's brief.
  - ActivityFeedView: `.merge` lines use `arrow.triangle.merge`.
  - `brahma dev merge-scenario <company>` (`BRAHMA_DEV=1`) leaves one merged and one bounced (conflict) request through the real tools and queue. `seed-demo.sh` runs it after `brahma merge settings Initech --main-check "test -f index.html"`.
  - README "Merge queue and main" section. It covers:
    - Done meaning merged, verified-commit pinning, hermetic re-checks, the flake, infra and red-main rules, batching and bisect, the secret scan, the journal and recovery;
    - the main policy (only the queue moves `main`, the journaled unattributed commit, foreign refs, `adopt-main`, `refs/brahma/pre-merge/<n>` vs L's `main-backup`);
    - the commands, including artifact keys `AR-<n>` (asks keep `A-<n>`);
    - the non-web previews: the iOS owner gate and why, Screen Recording, and the artifact kinds including CAD cards and phone-framed video.

- [ ] **Step 1:** Add `mergeQueueEndToEnd` to `LiveSmokeTests` (10 min limit, `BRAHMA_LIVE=1`; `haiku` individuals, `sonnet` executives; Balanced; `max5x`).
  1. Create a company. Hire `eng` (engineer), `lead` (manager) and `cto`.
  2. Main check `test -f hello.txt`. L's smoke check `grep -qx hello dist/hello.txt`. `set_deploy_config` with build `mkdir -p dist && cp hello.txt dist/` and `output_dir dist`, a subfolder (fix 5).
  3. Register L's `FakeHostingAdapter`, and store its token in a `MemoryVault` via `Store.setSecret`.
  4. Create `SMOKE-1` ("Create hello.txt containing hello"): check `grep -qx hello hello.txt`, tier S, ready, owner `eng`, reviewer `lead`.
  5. DM eng with 3a's live-test instruction.
  6. Run a real `Orchestrator` until `done`.

  Expect:
  - `git show main:hello.txt` == `hello`;
  - one merged request, with mergeRun main and item `passed`, both run in deleted `wt-check` dirs;
  - the batch `done`;
  - `refs/brahma/pre-merge/1` == the old main;
  - `mainCommit == main`, and the guard returns `.ok`.

  Then wait until L's main smoke for the new head is `passed`, and call `proposeDeploy(version: "0.1.0")` as `cto`. After the owner approves, the release is `deployed` through `FakeHostingAdapter`.
- [ ] **Step 2:** Implement the views, the dev command and the edits. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`. Expected: no warnings.
- [ ] **Step 3: UI smoke.** `scripts/make-app.sh debug && scripts/seed-demo.sh`, then `scripts/ui-snapshot.sh task10-merge merge`, `scripts/ui-snapshot.sh task10-merge-settings merge-settings` and `scripts/ui-snapshot.sh task10-item item:INITE-2`. Read each. Expected:
  - MERGED and BOUNCED rows, `BATCH 1`, `MAIN CHECK test -f index.html`, the main-health chip;
  - the settings sheet;
  - the MERGE section in the inspector.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (all PASS, live skipped) and `scripts/smoke-app.sh`. With quota available, run `BRAHMA_LIVE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LiveSmokeTests` (PASS). If you skip the live run, say so.
- [ ] **Step 5:** Commit `feat(app): merge-queue panel and item merge detail; docs and live merge-to-deploy test` with the trailer lines.
