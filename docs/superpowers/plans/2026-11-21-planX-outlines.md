# Plan X — sub-plan outlines (X1b, X2, X3, X4, X5, X6b, X7, X8a, X8b, X9, X10, X11) and parallel pre-work

**Spec:** `docs/superpowers/specs/2026-11-21-any-product-and-hedges-design.md` (owner decisions 1–21; *spec §n*). Full task-level plans exist for **X1** (`2026-11-21-planX1-runtime-billing-pacing.md`) and **X6a** (`2026-11-21-planX6a-measure-soak.md`). Everything here is an outline: goal, scope, one line per task, dependencies, and acceptance tied to the §10 matrix. Each becomes a full plan at the time spec §13.2 sets, starting with an R-style **Task 0: re-read S, R, P (and every merged X plan) and record the drift**.

**Carried by every sub-plan** (from S, R, P and the spec): Swift 6, SwiftPM, GRDB, Swift Testing; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on every `swift`/`xcrun`/`codesign`; existing CLI commands unchanged (add only; P's CLI tests and `cli-tree.tsv` append-only); fail closed (unavailable beats weaker; the one owner exception is `auto` isolation's labelled Seatbelt fallback, decision 21); agents never handle secrets (keys only through `brahma secret set` or the app's secure field); nothing deploys without owner approval; the app keeps its ops-console layout (P's components, inventory baseline by additions only); new tables mapped in P's `ChangeTopics`; S's `SafetyLintTests` gains no baseline entry; new tick work only as R `TickParticipant`s; new helper ops and `Purpose` cases only through S's factory; model policy **Fable** for implementers and routine reviews, **Opus** for security reviews and final reviews, never Sonnet or Haiku.

**Build order** (spec §13.3 as amended by decisions 20 and 21):
`S → R → P → X1 → X1b (if cheap) → X8a ∥ X6a → DOGFOOD #1 → X3a ∥ X2 ∥ X6b ∥ X8b → X4 → X5 → DOGFOOD #2 (content report, decision 19) → X3b ∥ X9 ∥ X7 → X10 → X11 → owner publishes bench results`.

---

## X1b — More providers (decision 20)

- **Goal:** the gateway's remaining adapters, so any LLM API and fully local models work, including offline.
- **Scope:** `gemini` (native API), `bedrock` (Converse, SigV4 signed in the gateway), `vertex` (service-account key → short-lived tokens minted by the gateway), `azure-openai` (deployments, `api-version`), `local` (Ollama, LM Studio, llama.cpp server, vLLM via their OpenAI-compatible endpoints); loopback and `--lan` host rules; offline mode; zero-price local rows.
- **Tasks:**
  0. Re-read X1 as merged; read the X1b-0 probe report; record drift.
  1. `local` adapter and host rules: `http://127.0.0.1:<port>`/`localhost` only, `--lan` for an owner-named private host, a direct loopback upstream (not the 443-only egress proxy), zero-price rows only for `local`.
  2. Canary probe per configured local port: unreachable from agent Bash on every backend.
  3. `gemini` adapter: Messages ↔ `generateContent`/`streamGenerateContent`, function calling, usage metadata; goldens.
  4. `azure-openai` adapter: deployment-scoped URLs, `api-key` header, `api-version` pinned per release; reuses the Chat Completions translation.
  5. `bedrock` adapter: Converse/ConverseStream, SigV4 in-gateway (no AWS SDK), event-stream framing; keys `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` as company secrets.
  6. `vertex` adapter: service-account JSON as a company secret, JWT → access token in gateway memory only, refreshed before expiry; Gemini and Anthropic-on-Vertex model families.
  7. Offline mode: a company whose every route is `local` with an empty allowlist runs with the network off; doctor line; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` verified by an egress-log probe.
  8. Red team (Opus): SigV4 and JWT handling, key leakage in signed URLs and errors, LAN host abuse.
- **Depends on:** X1 (gateway, meter, probe, routes).
- **Acceptance:** §10 row 12 (1) local leg and (5) `LiveGateway/offline`; every adapter passes the X1 capability probe on at least one model (owner keys, live); unit goldens per adapter including streamed tool calls; key-leak scan (X1-T16) passes on each adapter.
- **Effort:** M (~8 tasks + Task 0).

## X2 — Codex adapter (decisions 3, 9, 16)

- **Goal:** Codex CLI as a second runtime with the same guarantees (P1–P8), API-key mode only in v1, on every isolation backend whose canary passes.
- **Scope:** spec §8.1.2, §8.1.5, §8.1.6; decisions 20 and 21 add the gateway's `openai-responses` inbound dialect and per-backend parity.
- **Tasks:**
  0. Re-read X1, X8a; read the X2-0 probe report (headless JSONL, `CODEX_HOME`, `-c` overrides, base-URL override, resume, MCP transports).
  1. `CodexRuntime: AgentRuntime` — compile (`codex exec`, prompt on stdin, per-turn `CODEX_HOME`), `RuntimeCatalog` row, model-class mapping set from the probe.
  2. `CodexStreamParser` → `TurnEvent`; the runtime never emits Claude-only cases.
  3. Engine-side per-turn MCP endpoint (Unix-socket bridge `brahma mcp-bridge` or loopback HTTP, by probe), per-turn token, same handlers as `brahma mcp`, marks the session tainted before returning EXTERNAL content.
  4. `Purpose.runtimeTurn(codex)` in S's factory: whole-process Seatbelt on the `seatbelt` backend; Codex's own sandbox off inside it.
  5. Gateway inbound dialect `openai-responses` (Codex → gateway), routed to OpenAI or translated to any provider through the canonical format; goldens.
  6. Gates C-1…C-9 as probe-gate records; the canary's Codex shapes, live layer judged from the raw stream.
  7. Runtime choice: `brahma agent runtime`, `brahma company runtime`, `brahma settings runtime-models`, the `review-runtime` company setting, People › RUNTIME row; switching ends sessions with a hand-off.
  8. Per-backend parity: Codex on `linux-vm` (whole turn) and `seatbelt`; canary per (codex, backend, layout).
  9. `docs/runtimes/adding-a-runtime.md` and the lint that no runtime id appears outside `BrahmaRuntime`.
  10. Red team (Opus): config isolation (planted `AGENTS.md`, profiles, MCP entries), credential reads, network, stop kills the tree.
- **Depends on:** X1; X8a for the VM legs; dogfood #1 data before the full plan.
- **Acceptance:** §10 row 1 (5) and row 6 (1): `LiveCanary/escapeSuite` passes on Codex-under-Brahma; row 6 (2) comparison probes (with X6b); a Codex turn lands an item in the golden-path scenario (live, owner OpenAI key); if any gate cannot pass, Codex is "unavailable" with a published reason and X2 ends at the probe report (spec §14).
- **Effort:** M (~10).

## X3 — Any product (decision 7), staged by decision 19

- **Goal:** pack schema v2 and non-code products end to end; **the content pack first** so dogfood #2 can build a 15–25-page cited research report to PDF/EPUB.
- **Scope:** spec §8.3. **X3a (before dogfood #2):** schema v2, model classes in role cards, the check-kit framework, the blob store and size policy, the complete `content` pack with `words`, `style`, `links`, `cite`, `spell`, `structure`, `build`, the toolchain registry with pandoc and Hunspell, editions (`pdf`, `epub`, `site`), EPUB preview, PDF diff, recurring items. **X3b (after dogfood #2):** `media`, `physical`, `business` packs, their kits and toolchains (ffmpeg, OpenSCAD, STEP converter), audio and STEP previews, image diff, contact sheets.
- **Tasks (X3a):**
  0. Re-read; read the X3-0 licence report; import the reviewed `docs/packs/content.json`.
  1. Pack schema v2 fields with v1 defaults; `RoleTemplate.models` as model classes with legacy decode (X1's `ModelClass`); pinning and the upgrade diff.
  2. `BrahmaCheckKit` target and `brahma-check` executable: rule list, `check-result.json`, the digest table (untrusted text under S's typed prompts).
  3. Text kits: `words`, `style`, `structure`, `spell` (Hunspell toolchain).
  4. Network kits: `links` and `cite` emit fetch lists; the engine fetches with S's `httpsProbe`; quote matching inside the helper; only pass/fail and URLs reach prompts.
  5. Toolchain registry (id, version, URL, sha256, licence), engine install into `<home>/toolchains/`, first install as an owner ask, missing toolchain → inconclusive.
  6. pandoc toolchain and the `build` kit.
  7. Blob store: `blob_add` company tool (S helper), pointer files, the submit backstop, auto-commit conversion, hash-verified reads, backup and purge rules.
  8. `landGate: owner` and rubrics: the owner sign-off card after review and checks; the reviewer scores the rubric with evidence.
  9. Editions: recipes built from `main` in a sandboxed export, `R-<n>` of kind `edition`, `brahma release export`.
  10. `ArtifactKind.epub` (zip guards; preview through the HTML edition) and PDF diff (helper `extractText`).
  11. The `content` pack: roles, item types, handbook sections, kits, editions, channel suggestions.
  12. Recurring items whose plain-code pre-check skips the turn when there is nothing to do (row 1 (4)).
  13. Software pack gains `family: software` and model classes; nothing else changes (golden).
- **Tasks (X3b):** `media` pack + `image`, `palette`, `svg`, `fonts`, `video`, `audio`, `deck` kits + ffmpeg; `physical` pack + `cad-build`, `units`, `bom`, `compliance` + OpenSCAD and the STEP→glTF converter; `business` pack + `model`, `figures`; `ArtifactKind.audio`, STEP preview, image diff, contact sheets; the new previews in P's components (row 10/11, X3-T15 in the spec).
- **Depends on:** X1 (model classes), S (helper ops), dogfood #1 data; the pack JSON pre-work.
- **Acceptance:** §10 row 1 (4) (a recurring item with nothing to do costs 0 turns over 7 days); row 10 and 11 (`LivePreviews/allKinds` once X3b lands); dogfood #2: the report lands through the content pack with every kit green, a `pdf` and an `epub` edition, owner sign-off on the outline and the final manuscript; every kit rule has a passing and a failing fixture; `measure` shows the non-code acceptance metric.
- **Effort:** L (~20: X3a ~13, X3b ~8).

## X4 — Approved channels core (decision 8)

- **Goal:** outside actions only through owner-connected accounts, engine-executed, fail closed, logged and stoppable; first types `email` and `github`.
- **Scope:** spec §8.4, §9.3; shared policy, grants, audit and kill switches with X-gateway.
- **Tasks:**
  0. Re-read; read the channel pre-work notes (SMTP/IMAP, GitHub fine-grained token scopes).
  1. Model and tables: channel, grant (5-lite ledger shape), action request, action, hash-chained `channelAction` log.
  2. Connect flows: app sheet and `brahma accounts connect --secret-stdin` into `dev.brahma.channels`; scope read-back; new channels start paused, dry-run, no grant.
  3. Grants: scopes, durations, rate and spend limits, allowlists, content policy, audience threshold, `ask-each` default, dry-run default, 30-day expiry for auto grants; reserved matters.
  4. `ChannelPolicy.decide` in the spec's order (refuse → ask → auto), money rules.
  5. Outbound DLP: known secrets refuse; 8-word shingles against private sources, entropy and credential patterns ask; attachments by ref and hash only.
  6. `ChannelExecutor` tick participant: exactly-once per request id, idempotency keys, `sending`/`unknown` outcomes, reconciliation, dry-run rendering.
  7. Agent tools `request_action` (queued), `list_channels_available`, `action_status`; work notices for results.
  8. Inbox cards: `channel` kind, `outbox`, `spend`; exact payload rendering; "approve and allow similar" opens a grant widening.
  9. Kill switches: per channel, CHANNELS OFF (top bar), emergency stop observer, `resume` does not re-enable, restore pauses and cancels.
  10. `email` type: SMTP send, IMAP poll into EXTERNAL items, Plan 7 guardrails (disclosure, unsubscribe, opt-outs, follow-up cap 2).
  11. `github` type: repository-scoped token, branches/PRs/comments/checks read, `.github/workflows/` always asks.
  12. Inbound quarantine: polled reads are EXTERNAL and taint the reader; the property test that no EXTERNAL input or tainted session ever yields `auto`.
  13. `brahma accounts …` CLI and Company › Settings › APPROVED CHANNELS; Insights counts.
  14. Audit log verify (`--verify`), exports, Replay.
  15. Red team (Opus): prompt injection through inbound mail, policy order, idempotency under crash, chain tampering, DLP evasion.
- **Depends on:** X1, S (helper, typed prompts), R (participants), P (notifications), dogfood #1 proven.
- **Acceptance:** `LiveChannels/emailDryRunThenLive`; the "no inbound → auto outbound" property test; first use always asks; a tainted session never acts without a card; kill switches work with the engine wedged; `measure` safety rows (channel refusals, DLP hits) become applicable; Opus security review closed.
- **Effort:** L (~18).

## X5 — PR mode and issue import (decisions 4, 12, 18)

- **Goal:** land through GitHub PRs under branch protection, import GitHub and Linear issues, with a trust list the owner controls.
- **Scope:** spec §8.5, §9.4.
- **Tasks:**
  0. Re-read X4 as merged.
  1. `brahma company landing local|pr [--engine-merge]`; required grants.
  2. Push stage after verification: the verified SHA to `brahma/<KEY>-<slug>` by URL and refspec from the engine repo, token only in the step's environment, in S's helper, network `github.com` only; secret and blob-pointer scan before every push.
  3. PR open with an engine-written body (check table, verdict, walkthrough link; agent text quoted untrusted).
  4. Wait for required checks and reviews; failure returns the item with redacted, EXTERNAL text.
  5. Merge: a human by default; `--engine-merge` only when GitHub reports mergeable, never admin bypass.
  6. Remote `main` fetch (hardened) and the trust list (decision 18): `brahma issues trust|untrust`, author/approver rules, `import: github` marking.
  7. GitHub issue import (`brahma issues link github`), EXTERNAL bodies, origin URL, trusted authors.
  8. Linear import with a read-only key.
  9. Sync-back comments as `comment` channel actions; `Fixes #n` closing.
  10. `measure` row: PR first-push CI pass rate; red team (Opus) on push and fetch.
- **Depends on:** X4 (`github` channel), X3 (blob pointers, for the pre-push scan).
- **Acceptance:** §10 row 8: `LivePR/branchProtection`, `LiveIssues/injectedIssue` (0 channel actions without a card; the card names the taint source), PR first-push CI pass rate reported (target ≥ 90%).
- **Effort:** M (~10).

## X6b — Bench (decisions 5, 13)

- **Goal:** reproducible benchmark runs and a published benchmark design, plus the queue improvements the matrix promises.
- **Scope:** spec §8.6.3, §8.6.4; §10 rows 2, 6 (2), 7 (3).
- **Tasks:**
  0. Re-read X6a; import the reviewed `docs/bench/DESIGN.md`.
  1. Scenario format (pinned, versioned; repo+SHA or fixture, pack, seed backlog with hidden tests, runtimes, classes, pacing, billing, budget).
  2. `brahma bench run` in a throwaway home with file secret stores; hidden tests against `main` at the end.
  3. `bench-result.json` manifest (metrics, hidden-test pass rate, environment, sha256 of inputs) and the Markdown report; `brahma bench verify`, `bench list`.
  4. The soak as a reusable bench scenario (X6a's checkpoint/verify).
  5. Adaptive batch size in the merge queue (grow while green, shrink on failure) — row 2.
  6. `.brahma/backlog.jsonl` read-only mirror — row 2.
  7. Comparison probes: the canary list against stock Codex `--sandbox workspace-write` (owner-run) — row 6 (2).
  8. `LiveBench/queueBisect` and `LiveBench/limitResume`.
  9. Walkthrough A/B report hook (with X9) — row 7 (3).
- **Depends on:** X6a; X2 for runtime comparison.
- **Acceptance:** row 2 (1) `LiveBench/queueBisect` (extra runs ≤ 2·⌈log2 20⌉); row 3 (1) `LiveBench/limitResume`; `bench verify` re-checks every hash; bench runs are never run by tests.
- **Effort:** M (~9).

## X7 — Reach: lid closed, remote runner, Slack push, phone approvals (decisions 10, 12, 17)

- **Goal:** keep working with the lid closed on power, run companies on a second machine, and approve from the phone under passkeys.
- **Scope:** spec §8.7, §9.5.
- **Tasks:**
  0. Re-read; read the X7-0 lid-close facts for macOS 26.
  1. Lid-closed setting: the one-line owner command as a human task, detection, doctor line.
  2. On battery: drain new work, then `pmset sleepnow`.
  3. Awake-time and sleep safety checks against R's service.
  4. Runner model: a second engine endpoint over SSH stream-local forwarding; engine badges on the company rail.
  5. `brahma company move --to <runner>` (export → transfer → import; secrets re-entered); `brahma runners`.
  6. Slack as a third push target (counts not content, quiet hours).
  7. Phone pairing over Tailscale Serve HTTPS (MagicDNS name as relying party), passkey registration, `brahma devices`, 90-day expiry; Funnel refused.
  8. Per-action passkey approvals over the ask id and payload hash; the Mac-only list; money within Mac-set caps.
  9. Bounded limit raises from the phone (2× default, per-day counts, 15-minute cooling-off with cancel); `brahma settings phone-raise-max`.
  10. Red team (Opus): replayed and altered assertions, stale challenges, runner forwarding.
- **Depends on:** R (service, IPC), X4 (approval cards for channel and money actions).
- **Acceptance:** §10 row 4 (3) `LivePhone/approve` (an altered payload hash is refused); row 5 lid-closed leg (with X6a's soak); a moved company runs on the runner with the same canary and gates; no network listener is ever opened (a test scans listening sockets).
- **Effort:** L (~14). Linux runner = Plan 8, re-scoped, after X8a's Linux image work.

## X8a — Isolation interface and Linux micro-VM (decision 21, P0)

- **Goal:** every agent turn runs in a local Linux micro-VM by default, holding no credentials, reaching only the engine's gateway and egress proxy, sharing only its worktree; one isolation interface behind the runtime seam; a canary backend layer that proves it.
- **Scope:** spec §8.8 (backends `seatbelt` and `linux-vm`; `auto`; both layouts), §9.5.
- **Tasks:**
  0. Re-read X1 as merged; read the X8a-0 probe report (start times, virtiofs, vsock relay throughput, Seatbelt around the VM host, entitlement and ad-hoc signing, `claude` inside the VM through the relay).
  1. `IsolationBackend` protocol, `IsolationBackendId`, `IsolationLayout`, `HostFacts`, `IsolatedLaunch`; `TurnShape` gains `backend` and `layout` (seatbelt + subscription keys unchanged).
  2. `SeatbeltBackend` wrapping today's launch (golden parity with X1's goldens).
  3. Host facts and resource admission: RAM budget per VM, disk checks, `brahma settings isolation-overflow fallback|wait` (default wait).
  4. Linux image: reproducible build, pinned runtime CLIs, sha256 pin, verify at boot; `brahma isolation images`; first build is an owner ask with sizes.
  5. Containerization backend: VM lifecycle, warm VM per agent, per-turn writable layer; the VM host process under a new S `Purpose.vmHost` Seatbelt profile; `com.apple.security.virtualization` signing in `scripts/make-app.sh`.
  6. vsock relays for the gateway and egress proxy (host side on the engine's loopback ports; guest side on the VM's loopback); no other network interface (security).
  7. Worktree-only mount; the per-turn read-only history snapshot for in-VM `git`; engine read-back only through S's hardened git and `SafeFS`/`Place`.
  8. Whole-turn layout for gateway turns: `claude` runs in the VM with the relayed `ANTHROPIC_BASE_URL` and the turn token.
  9. Split layout for subscription turns (§8.8.3): harness on the host under Seatbelt, every Bash command in the agent's VM through `CLAUDE_CODE_SHELL_PREFIX`; labelled VM (commands).
  10. `auto` selection and the labelled fallback: WEAKER ISOLATION on the agent, the company rail and the Inbox; per-turn `turn.backend`/`turn.layout`; a daily notice; `doctor` and `why` lines; explicit backends fail closed; the `measure` isolation row (VM share, fallback turns with reasons) through X6a's `MetricValue`.
  11. Emergency stop and recovery: STOP kills every VM; orphan VMs from a crashed engine are found and stopped at start (R's recovery order).
  12. Canary backend layer (§8.8.6) per (runtime, backend, layout): owner files, credentials, network, token death after the turn.
  13. CLI and app: `brahma company isolation`, `brahma agent isolation`; Company › Settings › ISOLATION; People › agent ISOLATION row; badges.
  14. Red team (Opus): mount escapes (symlinks and hard links written by the VM, `.git` tricks), relay abuse (reaching other host ports), token reuse after the turn, resource exhaustion, image tampering.
- **Depends on:** X1 (gateway, `LaunchSpec`, `TurnShape`), S (factory, helper, hardened git), R (service, recovery, participants), P (components). Runs beside X6a; before dogfood #1.
- **Acceptance:** §10 row 6 (1) `LiveCanary/escapeSuite` DENIED on `linux-vm` (both layouts) and `seatbelt`; rows 4 and 5 (local VM, nothing to steal, owner-controlled egress); `LiveSoak/72h` runs on the default isolation with the VM share and every fallback reported (row 5 (3)); a gateway turn in the VM passes X1's key-leak scan; an explicitly chosen VM backend never falls back (test).
- **Effort:** L (~14 + Task 0). Resource note (spec §11): each warm Linux VM costs about 0.5–2 GB of RAM, so on the owner's 24 GB Mac with 8 GB reserved, about 8–16 VMs at once; conservative pacing's 2 concurrent turns stays far inside that.

## X8b — macOS VM and Docker backends (decision 21, P1)

- **Goal:** Xcode work in a macOS VM; Docker as an optional backend when installed.
- **Scope:** spec §8.8 backends `macos-vm` and `docker`.
- **Tasks:**
  0. Re-read X8a; read the X8b-0 report (IPSW image build time and size, boot time, Xcode from `.xip`, Simulator in the VM; Docker `--network none` with a relay socket on Docker Desktop, OrbStack, Colima).
  1. macOS image build from Apple's restore image as an owner ask (disk and download sizes shown).
  2. Xcode install from an owner-downloaded `.xip`, never an Apple ID inside the VM; image verify.
  3. Virtualization.framework backend: APFS-clone per turn, boot, stop; the 2-concurrent-VM licence limit enforced in admission.
  4. vsock relays and the worktree mount for the macOS guest (shared code with X8a).
  5. `claude`/`codex` whole turn in the macOS VM; split layout for subscription turns.
  6. `auto` extension: `macos-vm` for companies whose surfaces need Xcode; order `linux-vm → docker → seatbelt` for others **(controller's call: Docker is preferred only when the Linux micro-VM cannot run)**.
  7. macOS canary layer (owner files, Keychain, credentials, network, token death).
  8. Docker detection (a Docker-compatible engine answering on its socket, from the engine only; the socket is never mounted into containers) and the backend: `--network none`, relay socket, digest-pinned image, worktree bind mount only.
  9. Docker canary layer.
  10. App: image management (sizes, verify, delete), backend availability and reasons.
  11. Red team (Opus): Docker socket exposure, container escapes to the Docker VM, macOS VM shared-folder escapes.
- **Depends on:** X8a; dogfood #1 data.
- **Acceptance:** §10 row 6 (1) on `macos-vm` and `docker`; an iOS item builds and its preview runs on the host for a company on `macos-vm`; a third concurrent macOS VM turn waits (licence limit); no Docker install is ever required (a test with no Docker shows the backend "not installed" and nothing else changes).
- **Effort:** L (~12).

## X9 — Recorded walkthroughs

- **Goal:** engine-recorded, deterministic walkthroughs of the candidate build that gate landing.
- **Scope:** spec §8.9; §10 row 7.
- **Tasks:**
  0. Re-read; read the X9-0 browser-toolchain report (WebKit-based preferred for licence and size).
  1. Walkthrough YAML format and validator; `brahma-check walkthrough` results.
  2. Headless browser toolchain (registry, pinned) running in S's helper with loopback-only network.
  3. Recording against the preview of the candidate in a fresh export: MP4 with captions, contact sheet, console errors, failed requests.
  4. iOS and macOS walkthroughs through 4a's Simulator and window capture.
  5. Attachment to the review digest, the Inbox card and the PR body (X5).
  6. Owner RECORD WALKTHROUGH button in the preview pane, writing the YAML.
  7. `measure` row: walkthrough coverage; bench A/B with X6b.
- **Depends on:** X3 (toolchain registry), X5 (PR attachment).
- **Acceptance:** §10 row 7: `LiveWalkthrough/seededUIBug` (a broken "Sign up" fails the check and never reaches review); coverage ≥ 95% of web items in review during dogfood #2's software company; the A/B catch-rate report.
- **Effort:** M (~7).

## X10 — More channels

- **Goal:** the next channel types, one at a time, after X4 holds in dogfood #2.
- **Scope:** spec §8.4.11, §8.7.3, §9.3.4.
- **Tasks (about 3 each):** `slack` (Socket Mode bridge, owner-only private channel as owner chat, others EXTERNAL, never approvals); `bluesky` (posts, audience threshold, banned claims); `cloudflare-dns` (one zone, record allowlist, publish asks); `shopify` (products and drafts, publish and price changes ask); `stripe` (restricted key only, products and prices `modify`, refunds and payouts `money`, live mode an owner decision). Each: connect flow, action types and risk classes, executor adapter, scope read-back, canary-free live test, Opus review.
- **Depends on:** X4 proven in dogfood #2.
- **Acceptance:** §10 row 4 (1)(2) `LiveSlack/bridge` and the refusal test that no Slack event approves an ask; row 9 money path (with X11); each type's least-privilege refusal test (a broader token is refused).
- **Effort:** M (~15).

## X11 — Deployable full-stack templates (directive 15)

- **Goal:** templates with login, a database and payments that deploy to the owner's own accounts, only with owner approval.
- **Scope:** spec §8.10; §10 row 9.
- **Tasks:**
  0. Re-read; import the reviewed template repositories (pre-work).
  1. `cf-fullstack` scaffold (Workers, Pages, D1, passkey login, magic-link fallback through the `email` channel, Stripe Checkout and webhook, admin page) as a software-pack template the CTO card can pick.
  2. `vercel-fullstack` scaffold (Next.js, Neon, Auth.js, Stripe Checkout).
  3. `database-account` human task (Neon); reuse of `hosting-account` and `stripe-test-keys`.
  4. Local template smoke on every `main` (Wrangler local with D1, Stripe test mode): sign up, log in, write, read, checkout, webhook.
  5. Template walkthroughs (X9).
  6. Deploy plan with migrations; destructive migrations flagged irreversible on the card.
  7. Live keys only through the `stripe` channel; "LIVE PAYMENTS" deploy card.
  8. Refusal tests: no path deploys or switches to live keys without an owner approval.
- **Depends on:** X10 (`stripe`), X9.
- **Acceptance:** §10 row 9: `LiveTemplates/fullStackCheckout` with owner touches ≤ 4; the refusal test.
- **Effort:** M (~8).

---

## Pre-work that can run in parallel now (alongside S, R and P)

None of these writes product code under `Sources/` or `Tests/`. Probes that need an owner credential are **owner-run**: the owner enters the key; no agent ever sees it.

| # | Pre-work | Output | Touches Swift? |
|---|---|---|---|
| 1 | **X1-0 probes**: `claude -p` against a local stub server through `ANTHROPIC_BASE_URL` with a dummy key — headers and endpoints it calls; required SSE event order; whether 401/429 ever makes it fall back to the owner's login (watch the egress log with the subscription logged in); retry behaviour on 429; `--model <alias>`, `--fallback-model`, `ANTHROPIC_DEFAULT_*_MODEL`; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`; whether a turn-local `CLAUDE_CONFIG_DIR` is needed; rate-limit events in API mode. Owner-run leg with a real key: prompt cache across auth modes, resume across modes | `docs/research/x1-0-probes.md` + the stub under `docs/research/probes/x1-0/` | **No** (stub in Python or shell) |
| 2 | **X1 price seed**: current list prices for the Anthropic models `ModelAllowlist` resolves to and the OpenAI models to pin, with sources and a date | `docs/research/x1-prices.md` | No |
| 3 | **X1b-0 probes**: tool calling and streaming formats and usage reporting for Gemini, Bedrock Converse, Vertex, Azure OpenAI, Ollama, LM Studio, llama.cpp server, vLLM; which local servers report usage; offline traffic of `claude` | `docs/research/x1b-0-probes.md` | No |
| 4 | **X2-0 Codex probes** in a throwaway install: `codex exec` JSONL, `CODEX_HOME` isolation, `-c` overrides, base-URL override, resume, MCP transports (stdio, HTTP), model list, sandbox off, auth-store location | `docs/research/x2-0-probes.md` | No |
| 5 | **X8a-0 probes**: Containerization start times (cold and warm), virtiofs throughput on a 10k-file repo, vsock relay latency for streamed responses, the VM host process under a Seatbelt profile, entitlement and ad-hoc signing, `claude` in a Linux VM through a relay | `docs/research/x8a-0-probes.md` | **Swift spike only**, in a throwaway package outside the repo's `Sources/` (Containerization is a Swift API) |
| 6 | **X8b-0 probes**: macOS VM from IPSW (build time, disk, RAM, boot), Xcode from `.xip` without an Apple ID, Simulator in the VM, the 2-VM limit; Docker `--network none` with a relay socket on Docker Desktop, OrbStack and Colima | `docs/research/x8b-0-probes.md` | **Swift spike only**, outside `Sources/` |
| 7 | **X3-0 toolchain licence checks**: pandoc, Hunspell and dictionaries, ffmpeg builds (LGPL vs GPL), OpenSCAD, the OCCT-based STEP→glTF converter, a headless WebKit for X9; download sizes; what Apache-2.0 distribution allows (nothing bundled) | `docs/research/x3-0-licences.md` | No |
| 8 | **X3 pack content as JSON**: `content` first (decision 19), then `media`, `physical`, `business`: roles with role cards, item types with `landGate`, rubrics (≤ 12 criteria), kit defaults, editions, channel suggestions; validated later by schema v2; the owner reviews them | `docs/packs/{content,media,physical,business}.json` | No |
| 9 | **X6b benchmark design document**: scenarios (10 repos, post-cutoff issues, hidden tests from upstream fixes), the non-code track, protocol (budgets, 3 runs, medians and spread), baselines, publishing rules | `docs/bench/DESIGN.md` | No |
| 10 | **X11 template repositories** (outside Brahma): `cf-fullstack` and `vercel-fullstack` with their tests, smoke and walkthrough YAML | separate repositories the owner creates | **No Brahma Swift** (TypeScript) |
| 11 | **X7-0 lid-close facts** on macOS 26: clamshell, `pmset disablesleep`, `pmset sleepnow` without admin | `docs/research/x7-0-lid.md` | No |
| 12 | **X4/X5 provider notes**: SMTP/IMAP app-password flows; GitHub fine-grained token scope read-back; branch-protection and required-check APIs (owner test repository for the live leg) | `docs/research/x4-x5-providers.md` | No |
| 13 | **X9-0 browser toolchain choice**: WebKit-based headless options, licence, size, loopback-only operation | `docs/research/x9-0-browser.md` | No |
