# Plan P — Polish before dogfood (design)

**Status:** design, 2026-11-21, revised after the owner's decisions of 01:13, 01:16 and 01:25 (see below). The owner approved the scope (design analysis items 1–3). Build order: 4a → C → 4b leftovers → S → R → **P** → first dogfood run.
**Plan:** `docs/superpowers/plans/2026-11-21-planP-polish.md`.
**Inputs:**
- `2026-11-21-design-analysis-input.md` (*analysis §n*)
- `2026-10-21-brahma-design-v2.md` §1.3 (concept budget), §4.12 (app layout)
- `docs/superpowers/specs/2026-10-20-visual-design.md` (the binding look for the polish pass)
- `2026-11-21-usability-review-input.md` (*review #n*; its screenshots are in `/Users/chandra/.claude/jobs/6d89b87c/tmp/usability/shots/`)
- `2026-10-20-visual-design.md` (BrahmaTheme)
- Plan R spec (`2026-11-21-restructure-service-design.md`, *R §n*)
- Ledgers under `*/.superpowers/sdd/` (4a, C, 5-lite, L)
- Code on `planC-collab` 91e84e9

P builds on R. It uses R's module split, R's in-process service host for tests, and R's control socket for change notifications.

---

## Owner decisions, 2026-11-21

### 01:13 — the app keeps its layouts; P polishes them

- **Rejected:**
  - the navigation restructure, meaning the former layout A: a 7-row five-noun sidebar with tabs, the Mission Control strip and the Insights pane;
  - folding the standalone Activity page.
- **Kept:** today's sidebar (14 fixed rows plus channels and DMs) and every screen's layout, with their detailed, dense look. Nothing moves and nothing is removed from a screen. The only exceptions are the five fixes the owner approved at 01:25.
- **Instead:**
  - a **polish pass** on the existing layouts (§5.1);
  - a **performance pass** on heavy views (§5.1.5);
  - a **usability review**. Its findings are written up for the owner, and each one is changed **only after the owner approves it** (§5.1.6).

### 01:16 — the CLI keeps every command as it is

- **Rejected:** regrouping commands under nouns, a `brahma dev …` namespace, renames, and deprecation aliases.
- **Kept:** every command name, path, option, argument, exit code and stdout format.
- **Instead:** P improves the CLI's **help text, examples and error messages** only (§5.2).

### 01:25 — usability review: five fixes approved, the rest held

The owner read the usability review (`2026-11-21-usability-review-input.md`) and approved these for P (§5.1.7):

1. **The agent map is reachable** (review #1). Mount `AgentMapPanel` in Mission Control's AGENT MAP slot, and delete the "COMING SOON" wording. If the 4b leftovers already did the slot swap, P only adds an **Open map** button and a **Window › Agent Map** menu item.
2. **The company goal is visible, and Budget gets the weekly share control** (review #2). The goal is a GOAL key-value in the top bar's second row. Budget gets a WEEKLY SHARE panel that sets exactly what `brahma settings share` sets.
3. **Keyboard and VoiceOver** (review #3), with no visual change. This covers a `Commands` scene, arrow-key selection in tables, focus states, and button traits and labels.
4. **Stuck agents and Inbox wording** (review #4 wording, review #5):
   - blocker text leads with the cause, and the agent offers **Retry now** and **Open permissions** actions;
   - the green "Approved by @ceo" on pending Inbox cards is fixed;
   - the "N asks wait for you" chip links to the Inbox.
5. **Sidebar exception:** the Inbox moves up to its own spot at the top of the sidebar. **This is the only sidebar change the owner allows.**

Also in scope: the review's **"Quick polish"** list, visual only. It is folded into the polish tasks.

**Held for later owner approval and not built in P:** the review's other hard-to-use items, #6 (activity feed), #7 (engine vocabulary), #9 (form validation timing), #10 (empty/error/loading behaviour) and #11 (control patterns). From #8 (truncation) and #12 (accessibility/contrast), P builds only the parts that the 01:13 polish scope already covers and that change nothing but drawing:
- column widths and flexible cells;
- `.help` on truncated cells;
- middle truncation;
- the `text2` contrast token;
- 24 pt hit areas through `contentShape`, with no change to the drawn size.

Anything else in #8 and #12 is held. These items are listed in the usability findings file with status `proposed` (§5.1.6).

### 01:16 — Plan R engine defaults confirmed

- Quitting the app leaves agents working. ⌥ Quit or the menu's Stop engine stops them. Desktop notifications pause while the app is closed.
- The engine starts at login.
- On an update, in-flight work gets up to 10 minutes to finish, then the engine restarts.
- `brahma run` / `brahma engine run` stays, for development.

---

## 1. Why

- **The app is built screen by screen across eight plans and has never had one consistency pass** (*analysis §4, §5*). It has 41 top-level view files in `BrahmaApp/Views`, plus Handbook, Map, Preview, Resources, Refs and Changes subfolders. Plans 2, 3a, 5-lite, L, ML, 4a, 4b and C each added screens against the visual-design brief.
  - The token contrast fails WCAG AA for the most-used secondary text. `text2` #6E7C89 measures 4.39 : 1 on `bg0`, 3.79 on `bg2` (panels), 3.40 on `bg3` (headers, hovered rows) and 2.92 on `bg4` (selected rows). `accent` #2D72D2 used as text (mentions) measures 3.44 on `bg2`. The `killed` color #404854 as text measures 1.76.
  - Empty, loading and error states differ from screen to screen, and agent text can overflow tables.
  - The analysis did not run the app (*analysis §4*), so a real audit is the first step.
  - The owner keeps the dense ops-console layouts (decision 01:13). Polish makes them consistent and fast without moving anything.
- **The CLI is hard to learn from its own help** (*analysis §2, §5 "CLI"*).
  - The CLI has 43 command files and 58 top-level entries (`Sources/brahma/Brahma.swift`). The help tree has 130 visible leaf commands on `planC-collab`, counted by walking `--help`. That is before the hidden `dev`/`hook` groups and before 4a's `artifacts`.
  - Only 15 commands have a `discussion`, and only one source file contains an example. There are 204 `fail(` and 34 `ValidationError(` messages, and many say what failed without saying what to do next.
  - The owner keeps the command tree as it is (decision 01:16), so P improves the help and the errors in place. The README is stale ("This is Plan 3a").
- **There is no golden-path test** (*analysis §2 must-haves, §6, §8 #7*). No test runs goal → org → backlog → work → check → review → merge → preview → owner Inbox on every plan merge. The real version (`LiveSmokeTests/goalToLiveURL`) needs `BRAHMA_LIVE=1` and real `claude`, and has never run as a gate.
- **The suite is slow and flaky** (*analysis §5*).
  - About 3,200 tests: 2,759 core, 411 app-model and 45 map.
  - Full runs take 252–508 s (`C2a-fullsuite.txt` 252.4 s, `C1a-fullsuite-c83e0b0.txt` 508.1 s).
  - About ten tests fail intermittently. Seven have recorded failures in the ledgers (§6.4).
  - Every implementer pays for this several times per task, and two worktrees cannot test at once.
- **The app polls the whole snapshot every 500 ms** (`AppModel.swift:316-324`, `Live/Snapshot.swift:50-91`). Each refresh reads every company's agents, channels, unread counts, Inbox count and stall report, plus the selected company's work, preview, releases, resources and last turns. The live map polls on its own loop (`MapController.swift:229`). *Analysis §3 Concurrency, §8 #15.*

## 2. Goals

1. **G1 App polish.**
   - Every existing screen matches `2026-10-20-visual-design.md`: spacing, alignment, type scale, hairlines, chips, and empty, loading and error states.
   - Every screen gets consistent hover, focus and keyboard behaviour, safe truncation and overflow, dark-mode contrast at **WCAG AA**, and the brief's micro-interactions.
   - Heavy views render and scroll within budget (§5.1.5).
   - **What is on each screen and where it lives do not change** (§4).
2. **G1b Usability write-up.** Anything that is hard to use is written up for the owner (screen, problem, why, proposed fix, effort) and left unchanged until the owner approves it. Polish proceeds on everything else.
3. **G2 CLI help and errors.**
   - Every command has a clear one-line abstract and every leaf has runnable examples.
   - Every error message says what failed and the exact next step.
   - Every `brahma …` hint the product prints names a command that exists.
   - Command names, paths, options, exit codes and stdout formats do not change (decision 01:16).
4. **G3 Golden path.** One deterministic end-to-end test runs in the default suite in under 30 s. A black-box script version (`scripts/golden-path.sh`) runs on every plan merge.
5. **G4 Determinism and speed.** The ten listed flakes are fixed at the root. The default ("unit") tier has no wall-clock sleeps or real ports. Process, sandbox and timing tests move to an opt-in `process` tier, alongside the existing `live` tier. The unit tier runs in **under 90 s** on an idle machine (*analysis §8 #7*), and two worktrees can run it at the same time.
6. **G5 Change notifications.** The app refreshes from engine-pushed change topics instead of a 500 ms timer. Each refresh reads only the parts of the snapshot whose topics changed, and a change shows up within 250 ms. A cheap fallback keeps the app correct when the service is unreachable.

## 3. Non-goals

- **The cost-per-outcome view** (*analysis §2 must-haves*). The owner did not include it in P. It is listed as the first post-dogfood candidate.
- **Any navigation or layout restructure** (owner decision 01:13). That rules out a new sidebar, tabs that replace rows, a Mission Control strip, an Insights pane, and moving or folding the Activity page.
- New owner features or new nouns. Usability fixes are **proposals** until the owner approves them one by one (§5.1.6). An approved fix is built in a follow-up task, or in P only if approval arrives before Task 15 ends.
- Changing the agent-facing CLI: `brahma mcp` and `brahma hook pre-tool|post-tool` keep their names and argv, because canary keys include the settings shape.
- Moving engine DB reads off the actor (R non-goal) and push-based map animation changes (the map keeps its render loop; only its data poll changes).
- **Any CLI regrouping, rename, alias or removal** (owner decision 01:16).

## 4. Anti-goals (binding)

- **No layout change.**
  - Every screen keeps its panels, columns, controls, rows and order, and the sidebar keeps its 14 fixed rows.
  - The only exceptions are the 01:25 approved fixes (§5.1.7). Each one updates the inventory baseline in its own commit, tagged `approved U-n`, with the diff listed.
  - `ScreenInventoryTests` compares the accessibility inventory of every screen before and after the polish (§5.1.1). Polish may add labels, help text and focus order. It may not add, remove or move elements.
  - **No CLI change beyond text.** The command tree, options, exit codes and the stdout of every non-help command are unchanged. `CLITreeFrozenTests` pins the tree from Task 8.
- **No script breakage.** Normal stdout and `--json` output stay byte-identical, and exit codes do not change. Only `--help` output and stderr error text change.
- **No weakened owner gating.** Error-message edits never move or reorder a `requireOwnerShell()`/`BRAHMA_AGENT_ID` check. Agent text in errors still goes through `safe()`.
- **No safety by notification.**
  - Change notifications are a latency optimization, never a correctness or safety signal.
  - Holds, stops and Inbox counts are still read from the DB.
  - A missed notification costs at most one fallback interval.
- **No deleted tests.** A flaky test is fixed or moved to a tier. It is never deleted or `.disabled`. Each moved test keeps a deterministic unit-tier sibling that covers its logic.

---

## 5. Architecture and decisions

### 5.1 App polish on the existing layouts (architect's call within decision 01:13)

#### 5.1.1 Audit first, against a frozen inventory

- **Screens in scope** (every one of today's, plus whatever 4a, C and the 4b leftovers add by P's start):
  - Rail, sidebar, top bar.
  - Mission Control: preview, agent map and activity panels.
  - Activity, Agents with the agent inspector and replay, Backlog with the item inspector, Board.
  - Releases, Handbook with pages, memory and the edit sheet, Resources, Budget with storage.
  - Inbox with the cards (access, deploy, human task, file request, live fallback), Grants, Digest.
  - Company settings, Backups.
  - Chat with the composer and the DM picker.
  - The search results.
  - C's Changes board and diff, its Show bar and palette, and its ref views.
  - The preview pane.
  - Every sheet: new company, hire, item editor, secret, KB edit, fill vacancy.
  - The menu bar extra, the engine banner, the startup error.
- **States per screen:** seeded (`scripts/seed-demo.sh`), empty (a fresh home), loading (a slowed store through the existing harness), error (an injected store failure), long content (generated agent text of 2,000 characters, 500 rows, handles of 64 characters), and the window at its minimum size (1100 × 700) and at full screen.
- **Inventory:**
  - A new harness flag, `--ui-inventory <out.json>`, dumps every screen's accessibility tree: role, identifier, label and frame order, without values.
  - `scripts/ui-inventory.sh` writes `Tests/Fixtures/ui-inventory/<screen>.json` **before** any polish.
  - `ScreenInventoryTests` (process tier, it launches the app) diffs the current tree against that baseline. Allowed: added labels, help and identifiers. Anything else fails.
- **Audit sheet:** `docs/superpowers/audits/2026-11-planP-ui-audit.md`, one row per finding: screen, state, finding, rule broken (§5.1.2–§5.1.4 or the visual-design spec line), and class.
  - **Polish** means it is fixed in P without changing content or location.
  - **Usability** means it goes to the owner write-up (§5.1.6) and is not fixed.
  - **Perf** means it goes to §5.1.5.

#### 5.1.2 Tokens and one shared set of components

- **Type scale** (from the brief): 10 pt uppercase labels (+0.6 tracking), 11 pt panel titles (semibold uppercase), 12 pt body, 13 pt body-strong, 11–12 pt SF Mono data, and 15 pt semibold for the company name only. These become `BrahmaTheme.Font.{label,panelTitle,body,bodyStrong,mono,monoSmall,companyName}`.
- **Spacing scale:** 2, 4, 8, 12, 16 (`spaceXXS…spaceL`, extending today's `spaceS/M/L`). Corner radius 2–3. Hairline 1 px using `line` and `lineStrong`. Rows are 22–24 pt in tables and 24 pt in the sidebar. Chips are 18 pt with radius 2, a 1 px status border and a 15 % fill.
- **Contrast fix (architect's call, token values only):**
  - `text2` #6E7C89 → **#84919E**. Measured: 5.84 on `bg0`, 5.44 on `bg1`, 5.04 on `bg2`, 4.52 on `bg3`. It keeps its place in the grey ramp below `text1` (8.21 on `bg1`).
  - On `bg4` (selected rows) tertiary text uses `text1`, because #84919E measures 3.88 there.
  - A new `accentText` **#609FF3** is used for accent-coloured *text* (mentions, links, "Open Inbox →"). It measures 5.99 on `bg2` and 4.61 on `bg4`. The `accent` fill and focus colour stay #2D72D2: as a UI component it needs 3 : 1, and it measures 3.44 on `bg2`.
  - A killed agent's *name* uses the new `text2` with a strikethrough. The `killed` colour #404854 stays for dots and glyphs only.
  - All status colours as text already pass on `bg0`–`bg3` (`ready` 4.54, `running` 4.60, `blocked` 4.63, `warning` 6.41 on `bg3`).
  - `ThemeContrastTests` computes WCAG contrast for every (text token × background token) pair the theme allows, from `ThemeHex`. It requires 4.5 : 1 for text and 3 : 1 for UI components. Disallowed pairs, such as `text2` on `bg4`, are listed explicitly.
- **Shared state components:** `EmptyState(text:)` (mono `text2` uppercase, per the brief), `LoadingState` (a mono "LOADING…" after 300 ms, with nothing shown before that so fast loads do not flicker), and `ErrorState(message:retry:)` (`danger` hairline, verbatim message, a Retry button). Every list and panel uses them.
- **`ThemeLintTests`** (static, with a shrink-only baseline like S's lint) scans `Sources/BrahmaApp` and `Sources/BrahmaMapKit/Views`. Outside `Theme/` it bans:
  - colour literals (`Color(red:`, `Color(hex:`, `NSColor(`);
  - `.font(.system(size:` off the type scale;
  - `.cornerRadius(`/`RoundedRectangle(cornerRadius:` outside 2–3;
  - numeric `.padding(`/`spacing:` literals off the spacing scale.

#### 5.1.3 Interaction

- **Hover:** rows and buttons use `bg3` with a 120 ms ease.
- **Focus:** the accent focus ring is visible on every focusable control.
- **Keyboard:**
  - Tab and Shift-Tab follow reading order. Arrow keys move the selection in tables and lists. Return opens the selected item, and Esc closes sheets and popovers.
  - ⌘F focuses the screen's existing filter or search field, where it has one.
  - Shortcuts that exist today are kept. The new ones come only from approved fix U-3 (§5.1.7).
- **Icon-only buttons** get `.help` plus an accessibility label.
- **Reduce Motion** is respected: no flash, no pulse, and instant transitions.

#### 5.1.4 Truncation and overflow

- Agent text in table cells is one line with tail truncation. The full text is in `.help`, shown with `Text(verbatim:)`.
- Ids, paths and URLs use middle truncation.
- Multi-line cells cap at 3 lines, with a "more" disclosure where the screen already has an inspector.
- **Top bar at narrow widths:** the collapse order is fixed. First the usage meter's resets go, then the sprint line, then the state chips (which collapse to counts). The company name and the mode control never collapse.
- At the minimum window size, nothing overlaps or clips mid-glyph (checked by the inventory frames).

#### 5.1.5 Performance of heavy views

| View | Load | Budget |
|---|---|---|
| Backlog, Board | 500 items | first render ≤ 150 ms; scroll p95 frame ≤ 16.7 ms |
| Activity panel and page | 500 lines + 50 lines/s | append without a full relayout; p95 ≤ 16.7 ms |
| Chat | 5,000 messages | open ≤ 200 ms; scroll p95 ≤ 16.7 ms |
| Inbox | 200 cards with documents | first render ≤ 200 ms |
| Handbook page | 200,000 bytes (ML cap) | render ≤ 300 ms |
| Changes diff (C) | 5,000 lines | scroll p95 ≤ 16.7 ms |
| Search results | 500 hits | ≤ 150 ms |

- **Method:**
  - A harness flag, `--perf-bench=<view>`, seeds the load into a temp home and measures with `os_signpost` and the existing `FrameStats` (4b), then prints JSON.
  - `PerfGate` tests (`BRAHMA_PERF=1`, existing gate) pin the presentation builders in `BrahmaAppModel`.
- **Allowed fixes:**
  - lazy containers with stable ids;
  - presentation rows precomputed off the main actor;
  - `Equatable` views;
  - no DB read on the main actor;
  - no per-row formatters (shared, cached).
- **Not allowed:** paging or truncating content the screen shows today. That would change what is on the screen.

#### 5.1.6 Usability review (owner-gated)

- During the audit, every **usability** finding goes to `docs/superpowers/audits/2026-11-planP-usability-findings.md`. A finding is anything hard to find, hard to understand, easy to get wrong, or slow to do. Each entry has:

| Field | Content |
|---|---|
| Screen | the view and state, plus a snapshot path |
| Problem | what the owner would struggle with, in one sentence |
| Why | the evidence: steps or clicks counted, a misleading label, a hidden state, an error that does not say what to do, a design-analysis citation |
| Proposed fix | the smallest change, with a before/after sketch (ASCII or a snapshot) |
| Effort | S (≤ ½ day), M (≤ 2 days), L (more) |
| Status | `proposed` → `approved` / `rejected` (by the owner, with date) |

- **Nothing in this file is built until the owner marks it `approved`.** Polish continues on everything else in the meantime.
- Navigation restructure is out of scope (decision 01:13) and is not re-proposed.
- When P ends, the controller sends the file to the owner. Fixes approved before Task 15 finishes may be built in P, as a task appended by the controller. Later approvals become a follow-up plan.

#### 5.1.7 Approved usability fixes (owner 01:25)

| Id | Fix | Exact behaviour | Layout effect (allowed) |
|---|---|---|---|
| U-1 | The agent map is reachable (review #1) | **If the merged 4b leftovers did not mount it:** `MissionControlView`'s AGENT MAP slot hosts `AgentMapPanel(model:)`, keeping the 4b controls (search, follow, fit, vacancies, replay, pop-out). The placeholder and its "MAP VIEW COMING SOON" chip are deleted. `AppModel.apply(.map)` selects Mission Control as today, now with the real map visible. **If they did:** P adds only an **Open map** button in the panel header and a **Window › Agent Map** menu item (⌘⇧M), both calling `openWindow(id: AgentMapPanel.windowId)`. | Slot content changes; slot position and size do not. |
| U-2 | Goal and weekly share (review #2) | **Top bar, row 2:** a `GOAL` key-value with `company.goal` in `Text(verbatim:)`, one line, tail-truncated, full text in `.help`. It is read-only (editing the goal is not approved). **Budget:** a new first panel, WEEKLY SHARE. It has a 10–100 % slider in 5 % steps plus a mono value. It reads `store.weeklyShare()` and writes `store.setWeeklyShare(_:)`, the same calls `brahma settings share` makes (`SettingsCommands.swift:56`), with the same validation and the same activity line. The help line reads "Share of your weekly Claude allowance the companies may use; the rest is kept for you." | One new top-bar key-value and one new Budget panel above the existing three |
| U-3 | Keyboard and VoiceOver (review #3) | **A `Commands` scene in `BrahmaApp.swift`:** New Company ⌘N, New Item ⌘⇧N, Hire ⌘⇧H, Find ⌘F (focuses the top-bar search field), Inbox ⌘I, and ⌘1…⌘9 for the sidebar's fixed rows in their order after U-5. ⌃⌥⌘. Stop Everything already exists in the menu extra and is mirrored in the app menu. **Tables:** Agents, Backlog, Memory, Resources, the Handbook tree, Grants and Inbox rows become `Button(.plain)` rows, as `SearchResultsView` already is, with `.onMoveCommand` ↑/↓ on the container, Return to open, and a visible focus ring. **Accessibility:** every interactive row and icon button gets `.isButton` and a label. | None (no visual change apart from focus rings) |
| U-4 | Stuck agents and Inbox wording (review #4 wording, #5) | **`BlockerText.describe`** (`Formatting.swift:73-83`) leads with the cause for `.retry`: `Turn failed: <cause> — retrying at HH:mm`. The cause is the last turn's failure line, flattened, with middle truncation in tables and the full text in `.help`. The inspector's BLOCKER row shows the same. **Owner actions** go under LAST TURN in the agent inspector when the failure class is known. **Retry now** calls a new `Store.ownerRetryNow(agentId:now:)`, which moves `blocked(.retry)` → `ready`, records an activity line, and refuses any other state. **Open permissions** selects Company › Settings at its permissions section when the failure class is sandbox scope or permissions. **Inbox cards:** the internal approval line (`InboxView.swift:137`) renders as `C-suite OK: @ceo` in `text1`, not `success`. Green is kept for RECENTLY DECIDED. **The WHY chip:** when the first stall reason is pending asks, clicking it selects the Inbox. Other reasons keep the popover, which gains an **Open Inbox** button whenever asks are pending. | Two buttons in the agent inspector; text changes |
| U-5 | Inbox at the top of the sidebar (review #4 placement) | The **Inbox** row, with its count chip and its two indented sub-rows **Grants** and **Digest**, moves out of the WORK group to the top of the sidebar, above Mission Control, followed by the usual section spacing. The row style is unchanged, and so are the order and content of the other 13 rows. (Architect's call: Grants and Digest travel with Inbox because they are its indented sub-rows today. Leaving them under WORK is a one-line change if the owner prefers.) | The only sidebar change |

- The Quick-polish list (review "Quick polish", 12 items) is merged into the audit sheet as Polish rows (Task 10) and built in the polish tasks.
- The review's other items go into the usability findings file as `proposed` (§5.1.6, Task 11).

### 5.2 CLI help, examples and errors (architect's call within decision 01:16)

The command tree is frozen. Plan P Task 8 records `swift run brahma` `--help` for every command path into `Tests/BrahmaCLITests/Fixtures/cli-tree.tsv`, giving path, options and arguments without the prose. `CLITreeFrozenTests` fails on any added, removed or renamed path, option or argument. A command added by a later plan updates the fixture in that plan.

**Help text:**
- **Abstract:** one line of at most 80 characters, starting with a verb in the imperative ("Show …", "Approve …"). Owner-only commands end with "(owner only)", as many already do. A command that needs the app or the engine running says so.
- **Examples:** every leaf command's `discussion` gets an `EXAMPLES:` block with 1–3 runnable lines that use the seeded demo names (`acme`, `@eng-1`, `A-3`).
  - Commands with destructive effects (`kill`, `stop`, `restore`, `grants revoke`, `secret rm`, `resource purge`, `memory delete`) add one line saying what cannot be undone.
- **Options and arguments:** each `help:` states its unit and default, for example "minutes, default 30", and its allowed values where it takes an enum.
- **Root help:** `brahma --help` keeps its flat list and order, with a better abstract and a 4-line "Start here" discussion (`status`, `inbox`, `why`, `doctor`). There are no new groups or headings, per decision 01:16.

**Errors:**
- **Shape:** `brahma: <what failed>: <why, if known>. <what to do>`. The "what to do" part names an exact command or app location, for example "Run 'brahma doctor' for details." or "Open Brahma › Settings › Company".
- The exit codes and stream (stderr) stay the same. Messages with agent or user text keep `safe()`.
- **Scope:** the 204 `fail(` and 34 `ValidationError(` messages in `Sources/brahma` (counted on `planC-collab`), plus `StoreError`, `WorkError` and `RestoreError` descriptions where the CLI prints them verbatim. Each one either already has the shape or is rewritten.
- **The engine's own hint strings:** 283 `brahma <verb>` strings in 125 files under `Sources/` tell the owner what to run. `CLIHintTests` checks that each one resolves to an existing command path and option. Today there is no such check, so a stale hint survives a rename.

**Tests:**
- `CLIHelpTests.everyCommandHasAbstract` (≤ 80 characters, imperative) and `everyLeafHasExamples`.
- `CLIHelpTests.examplesParse`: every example line parses with `Brahma.parseAsRoot`, so no example can rot.
- `CLIErrorStyleTests` checks every literal passed to `fail(`/`ValidationError(` against the shape: it ends with a sentence that starts with Run/Open/Use/Check/Try/Set or with a quoted command. A shrink-only allowlist covers messages where no next step exists, with a reason each.
- `CLIHintTests.everyHintResolves`.
- `CLITreeFrozenTests`.

### 5.3 Golden-path end-to-end test (architect's call)

Two layers, one scenario:

1. **`GoldenPathTests` (unit tier, < 30 s, in `BrahmaEngineTests`).**
   - It uses a real `Store`, real git, the real `Orchestrator` from R's in-process service host, and the real MCP tool dispatch (`CompanyTools`).
   - The `claude` side is a **`ScriptedTurnRunner`** (`TurnRunning`). It plays each role by issuing the tool calls a model would issue, through the same handler `brahma mcp` uses, keyed by role and turn number.
   - Preview processes use the existing `FakeSandbox` + `FakeHTTPProbe`. The clock is a `TestClock`.
   - Ticks are driven by `orchestrator.tick()` in a loop until a milestone or a step budget (≤ 400 ticks). There is no `runForever` and no sleeping.
   - Phases, each asserted:
     1. goal → company (software pack) → org chart generated;
     2. CEO turn writes the brief; lead turn creates backlog items with a check spec;
     3. dispatch leases item A-1 to `@eng-1` with its worktree;
     4. the engineer commits and submits;
     5. the engine check runs (fake runner, exit 0) and the review is routed;
     6. the reviewer approves;
     7. the merge queue lands on `main` (real git);
     8. the web preview reconciles to `running` at the merged commit;
     9. the deploy ask appears in the owner Inbox (`WorkSnapshot.inbox`);
     10. the owner approves through `Store.ownerDecide` and the release executes against the dev host.
   - It runs as part of the default suite on every task.
2. **`scripts/golden-path.sh` (process tier, about 2–4 minutes).**
   - The same scenario as a black box: a temp home, `brahma engine serve --unmanaged` (R), `BRAHMA_CLAUDE=scripts/fake-claude.sh` extended with a role script (`scripts/fake-claude-roles/`), real `sandbox-exec`, and a real loopback preview.
   - It asserts through the CLI only: `brahma status`, `brahma items list --json`, `brahma preview list` reaching `running`, HTTP 200 from the preview URL, and `brahma inbox` showing the deploy ask.
   - It is run by the controller at every plan merge, and it is listed in the Global Constraints of every future plan.

`LiveSmokeTests/goalToLiveURL` (real `claude`, `BRAHMA_LIVE=1`) stays unchanged as the third, manual layer.

### 5.4 Determinism and speed (architect's call)

**Tiers**, as a trait in `BrahmaTestSupport` (R):
- `.unit` is the default and needs no trait.
- `.process` covers real child processes, `sandbox-exec`, real ports, real timers above 100 ms, and Python. It is enabled by `BRAHMA_TEST_TIER=process` or `all`.
- `.live` is today's `BRAHMA_LIVE=1`, unchanged.
- The traits are defined as `.enabled(if: TestTier.process)`. That is the gating style already used at 52 sites, because Swift Testing tags cannot be filtered from `swift test` reliably on this toolchain.
- `scripts/test.sh [unit|process|all] [--changed]` wraps `swift test`. With `--changed`, it runs only the test targets of modules whose sources changed versus `main`, using R's per-module test targets.

**Unit-tier rule.**
- No `Task.sleep`, `Thread.sleep`, `usleep`, shell `sleep N`, real `Process()`, real port binds or `Date()` deadlines in unit-tier tests.
- Waits are events: continuations, `FakeSandbox.waitForSpawn`, `Gate.waitUntilWaiting`, or a `ManualClock` advance.
- `UnitTierHygieneTests` (static) scans unit-tier test files for those constructs. It starts from a **baseline allowlist** generated in Task 1. Today's counts are 51 `Task.sleep`, 12 `Thread.sleep`, 9 `usleep`, 65 `Process()` and 90 shell `sleep N`. The allowlist may only shrink. The same shrinking-baseline approach is what the analysis recommends for lints.

**Systemic causes** (from the ledgers):

| Cause | Evidence | Fix |
|---|---|---|
| `@MainActor` app-model tests wait on each other while CPU-heavy core tests saturate the machine. 31–59 of them finish at the same second. | `C2a-fullsuite.txt` (31 tests at 110–112 s), `C1a-fullsuite-c83e0b0.txt` (59 at 350–353 s) | Remove wall-clock bounds from app-model tests (injected clocks, below). Move the process-heavy core suites to `.process`. Unit-tier app-model tests then have nothing to wait behind. |
| Real wall-clock assertions (`Date().timeIntervalSince(began) < 30`) | `CLIAdapterTests.swift:103` | Fakes plus `ManualClock`. Real timeouts are tested once, in `GroupRun` with a stepping clock. |
| Shared machine resources across worktrees: `PortAllocator.range = 47100...47999` taken first-free, the `/private/tmp/b-<uid>` agent temp root, the `TurnRegistry` static keyed by agent id, the `$TMPDIR` scratch sweep | `Supervision.swift:84-87`, `Orchestrator+Sandbox.swift:49`, `TurnProcess.swift:500`, `ScratchHygieneTests` incident (4a progress :261) | Add `PortAllocating` (an injectable range; tests get a per-process base from the pid). The agent temp root becomes per data home in tests through `SandboxEnvironment`. `TurnRegistry` gets an instance per Orchestrator, with the static kept as the default. The scratch sweep only touches roots whose owning pid is dead **and** that belong to this checkout (a marker file holding the repo path). |
| The Mac slept mid-run (15 `idleTimeout`s at ~334 s) | C progress :98–100 | The unit tier has no awake-time deadlines, only event waits and `.timeLimit`. `scripts/test.sh` runs under `caffeinate -i` and prints "machine slept during run: rerun" when the awake clock and the wall clock diverge by more than 30 s. |
| One implementer's `pkill` killed another worktree's run | C progress :75 | Already a hard rule. `scripts/test.sh` never kills anything it did not start, and it writes its own pid file. |

**Per-test fixes** (ledger evidence in Appendix B):

| Test | Root cause | Fix | Tier after |
|---|---|---|---|
| `MapControllerTests.peopleOptional` | `live()` builds `MapController` with the real clock. Under load, more than 10 s pass between two polls, so people reload. Failed 10×. | Pass `MapTestClock` (exists, `MapControllerTests.swift:34`) through `live()`. Add the positive leg: advance 10 s, then expect `calls == 2`. | unit |
| `WorkModelTests.retryEngineClearsAccountHold` | Starts a real embedded engine: a real lock, real caffeinate, and a 50 ms tick racing the owner write. `retryEngine` uses `Date()`. | After R, `EngineHost` is gone. The test uses R's fake `EngineConnection` (`recheck` → passing), and `retryEngine` uses `clock()`. | unit |
| `SeatbeltRunnerTests.loopbackListenOnlyOwnPorts` | Real kernel ports, probed then closed and reused (time-of-check to time-of-use), with other processes connecting first. Failed 2× after 5-lite's retries. | Unit: assert `SeatbeltProfile.render` emits exactly the `localhost:<p>` bind and inbound rules for `.loopbackListen`. Process tier: the kernel check with a per-run nonce in the payload; listener exit 0 without the nonce counts as raced and is retried. `.serialized`. | unit + process |
| `SearchModelTests.staleMemoryResultsDropped` | `eventually { gate.isWaiting }` polls every 20 ms against a 60 s deadline on a starved main actor. Failed 3× (`Timeout()`). | `Gate.waitUntilWaiting()` on a continuation. The suite's `.timeLimit` is the only bound. | unit |
| `PreviewSupervisionTests.stopKillsProcessGroup` | Real `sleep 300` children, `ps` polled through Foundation `Process`, a 5 s deadline. Failed about 4× under load. | Unit: the stop logic against a fake `SandboxedProcess`. Process tier: the child writes its pids to a ready file, and `ProcessTable` (`TurnProcess.swift:30`) replaces `ps`. | unit + process |
| `CLIAdapterTests.demoTimeout` | A real `sleep 60` and a 1 s timeout with a wall-clock assertion. Failed 3× (61.3 s). | A fake `SandboxedRunner` returns `timedOut: true` with partial output. Delete the wall-clock assertion. | unit |
| `LiveCLITests.devHostServesOnlyItsFolderAndGrantsOnlyTheCopy` | A real loopback server probed through URLSession with 30 s timeouts. Failed once (62 s; 1.9 s alone). | Add the `DevHostServer.serve(connection:)` seam and drive it over `socketpair()`. Path logic is already unit-tested through `response(method:target:root:)`. | unit + process |
| `TurnContainmentTests` (timing) | `pid(in:)` and `gone()` poll 10 ms on the continuous clock. Fixed 300 ms and 50 ms sleeps before `classify`. | Ready files written after `sandbox-exec` applies. `TurnRegistry` gets clock and sleeper seams (`TurnProcess.swift:507/534`), so `ManualClock` drives `waitFailsClosedOnDeadlineAndCancellation`. The escapee tests move to `.process`. | unit + process |
| `WebAdapterTests.realServerIfPythonAvailable` | Python plus a first-free shared port range (time-of-check to time-of-use across worktrees). The `port+1` bind passes when the port is merely busy. | Move to `.process`. Use `PortAllocating` with a per-process base. Assert "Operation not permitted" for the `port+1` bind. | process |
| `BackupTargetTests.stalePidHandled` | Real processes, pid file, argv read through `KERN_PROCARGS2`, signals. The cause of the "left running" failure is not confirmed (`ProcessArguments.of` under load, inferred). Failed 4× after `OutsideChild` and many times before. | Add a `ProcessInspecting` seam (argv, isAlive, signal) to `WALShipper.reapStale` (`WALShipping.swift:406-427`), exposed through the existing `WALShipper.init(sleeper:awakeUptime:…)`. Unit-test the decision table: stale litestream gets TERM then KILL, an unrelated pid is never signalled, an unreadable pid file is removed. The real-process version moves to `.process` and passes `note:` so a failure says why. | unit + process |

**Runtime budget.**
- Unit tier: < 90 s wall time on an idle machine, measured by `scripts/test.sh unit --report`, which prints the 15 slowest suites.
- The heaviest suites today are ReviewTests 252 s, BackupTargetTests 185 s, MergeBatchTests 149 s, MergeQueueTests 141 s, SecretWireTests 127 s, SeatbeltRunnerTests 125 s and VerificationTests 124 s, all in the C2a log.
- Each heavy suite is either split into a unit part on fakes plus a `.process` part, or kept and justified in the report.
- Git-heavy suites (457 `git([` fixture calls in 27 files) get a cached template repository: one `git init` and commit per process, copied with `cp -c` (APFS clone) per test.

### 5.5 Change notifications (architect's call)

**Change topics live in the DB.** Migration `"vP-change-topics"`, appended after the last migration on `main` when P starts:
```sql
CREATE TABLE changeTopic (topic TEXT PRIMARY KEY, seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE changeEpoch (id INTEGER PRIMARY KEY CHECK (id = 1), epoch TEXT NOT NULL);   -- new UUID on create and on restore
-- one trigger per (table, INSERT|UPDATE|DELETE) for every table in ChangeTopics.map:
CREATE TRIGGER ct_workItem_u AFTER UPDATE ON workItem BEGIN UPDATE changeTopic SET seq = seq + 1 WHERE topic = 'work'; END;
```
- Triggers make the counters **transactional and cross-process**. The engine, the app, the CLI and every `brahma mcp` write the same DB, and GRDB's `ValueObservation` only sees writes made in its own process.
- **Topic map** (`ChangeTopics.map: [table: Topic]`, in `BrahmaStore`): `companies`, `agents`, `turns`, `messages`, `work` (items, leases, sprints, reviews, verification, merge rows), `inbox` (asks, grants, human tasks, file asks, notices), `preview`, `releases`, `resources`, `handbook`, `memory`, `usage`, `engine` (stop, holds, probes), `events` (activity).
- `ChangeTopicsTests.everyTableMapped` lists `sqlite_master` and fails on any table that is neither mapped nor in `ChangeTopics.unobserved`, which needs a reason per entry. A future plan's new table therefore cannot silently skip notifications.
- Hot-table cost: one extra single-row `UPDATE` per row write. `ChangeTopicsBenchTests` (`.process` tier) pins insert throughput on `activityEvent` and `message` at ≥ 80 % of the no-trigger baseline. If that fails, the topic for that table uses `ActivityEvent` max-id polling, which the app already does through its cursor.

**The engine pushes.**
- R's service runs a `ChangeFeed`. On every tick, and on a 100 ms awake-time timer while there is at least one subscriber, it checks `PRAGMA data_version` (a free in-memory check).
- When the value moves, it reads `changeTopic` (≤ 20 rows) and pushes `changed { epoch, topics: [topic: seq] }` to subscribers over R's socket (the `subscribe` stream).
- Notifications are coalesced to at most one every 100 ms per connection.
- The feed has an injectable trigger and clock, so tests drive it without timers.

**The app consumes.**
- `ChangeSubscription` (in `BrahmaAppModel`) keeps the last `seq` per topic.
- On `changed`, `AppModel` reloads only the parts of the snapshot whose topics moved:
  - `Snapshot.load` splits into `CompanySummaries.load`, `WorkSnapshot.load`, `PreviewSnapshot.load`, `ReleasesSnapshot.load`, `ResourcesSnapshot.load` and `lastTurns`;
  - `SnapshotParts.dependencies` maps each part to its topics.
- The activity cursor read (`events(afterId:)`) runs on `events`. The chat refresh runs on `messages`. The live map's poll runs on `messages`, `agents` and `work`, in place of its timer. The map keeps its render loop.
- **Fallback (always correct):** without a service connection (service down, old build, crash loop), the app polls `changeTopic` directly every **2 s**. That is one small read, and the same diff logic applies. A **60 s safety refresh** reloads everything, so a missed topic can never stay stale for long. `epoch` changes (restore) trigger a full reload and re-seed the cursors.
- **Turn stream** (`observeTurnStream`, transcript files): this is not DB data. It keeps its own 1 s read, and only while a view observes it (as today).
- Notice delivery (`deliverNotices`, every 4th tick today) runs on the `inbox` topic plus the 60 s safety refresh.

**Measured outcome**, recorded in the Task 7 commit:
- DB reads per minute from an idle app go from ~120 snapshot loads to ≤ 1 (the safety refresh) plus the 2 s topic read only when the service is down.
- Change-to-screen latency is ≤ 250 ms with the service up.

---

## 6. Migration strategy (counts on `planC-collab`)

| What | Count | How |
|---|---|---|
| Approved usability fixes (01:25) | 5 (U-1…U-5) + 12 quick-polish items | Plan P Tasks 12a–12c; inventory baseline updated per fix, tagged `approved U-n` |
| Screens in the polish pass | 41 top-level view files + 6 subfolders (`planC-collab`) | Audit → polish, layout frozen by `ScreenInventoryTests` |
| Theme literals outside `Theme/` | counted by `ThemeLintTests` in Task 12 | Shrink-only baseline |
| Contrast-failing tokens | `text2` (2.92–4.39), `accent` as text (2.65–3.98), `killed` as text (1.35–2.03) | Fixed via two token value changes and one new token (§5.1.2) |
| CLI command tree | 58 top-level entries, 130 visible leaves (+ hidden `dev`, `hook`; 4a's `artifacts`) | Frozen (`CLITreeFrozenTests`) |
| CLI abstracts / discussions / option help | 169 / 15 / 310 | Abstracts rewritten where they break the style; examples added to every leaf; option help states units and defaults |
| CLI error messages | 204 `fail(` + 34 `ValidationError(` | Rewritten to the §5.2 shape where needed |
| Hint strings naming commands | 283 in 125 files | Verified by `CLIHintTests`; fixed only if stale |
| README `brahma …` lines | 162 | The CLI section is rewritten (Task 9). The stale "This is Plan 3a" header is replaced. |
| Tests asserting CLI stderr text | counted in Task 8 Step 1 (19 files invoke the CLI) | Updated in the same commit as each message change, and listed in the commit body |
| App polling loops | `AppModel` 500 ms, `MapController`, map header and panel `.task` loops (4) | Topic-driven (§5.5) |
| Flaky tests | 10 | §5.4 table |
| Unit-tier sleep/process constructs | 51 `Task.sleep`, 12 `Thread.sleep`, 9 `usleep`, 65 `Process()`, 90 shell `sleep` | Baseline allowlist; shrink-only |

**Rollback:** each P area is a separate task.
- The rewrite table and new command paths can be reverted on their own.
- Polish commits are per screen group, and token values change in one commit, so each is revertible on its own.
- Change notifications sit behind `AppModel.updateMode` (`.notifications` or `.polling`; default `.notifications`). Flipping it restores the 500 ms poll without a rebuild of the engine side.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Polish drifts into redesign (moves, removals, "while I'm here") | The `ScreenInventoryTests` baseline is frozen before the first polish commit. Usability items are a separate, owner-gated file. The reviewer rejects any inventory change. |
| The `text2` change makes the dense look feel lighter | It is one token. The before/after snapshots are in the Task 12 commit, and the owner can veto it by reverting one commit. AA requires ≥ 4.5, so the alternative is darker backgrounds, which is a bigger change. |
| Hidden CLI breakage in owner scripts | Only `--help` and stderr text change. `CLITreeFrozenTests` pins paths and options, and exit codes are unchanged. |
| Trigger overhead on hot tables | Bench test; per-table opt-out to cursor polling |
| The golden path becomes a slow, flaky test itself | Unit tier is in-process with `ScriptedTurnRunner`, `TestClock` and a tick loop, so it has no sleeps. The real-process version is a script run per merge, not per task. |
| Splitting heavy suites loses coverage | No deletions (anti-goal). Every moved test keeps a unit sibling. The reviewer checks the test-count diff per task (`scripts/test.sh --report` prints counts per tier). |
| 4b's Mission Control slot swap or C's views change before P | The inventory baseline is taken on merged `main` at P's start, so P polishes whatever layout landed. |

---

## Appendix — Ledger evidence for the flaky tests

Roots:
- `WT=/Users/chandra/agent-company/.claude/worktrees`
- `L4A=$WT/plan4a-previews/.superpowers/sdd/2026-10-21-plan4a-workspace-previews`
- `LC=$WT/planC-collab/.superpowers/sdd/2026-10-21-planC-collab-mvp`
- `L5=$WT/plan5lite-safety/.superpowers/sdd/2026-10-21-plan5lite-safety`

The ledgers are gitignored, so search them with `/usr/bin/grep`, not the shell's grep function.

| Test | Recorded failures | Example |
|---|---|---|
| peopleOptional | 10 | `$L4A/task-2-fix2-fullsuite.txt:6800` "(provider.calls → 2) == 1" |
| retryEngineClearsAccountHold | 0 (flake list only, `$L4A/project-rules.md:30`) | — |
| loopbackListenOnlyOwnPorts | 2 after 5-lite's fix; several before | `$L4A/task-1b-fix1-fullsuite-run1.txt:6048` "own port not usable: own-exit=0" |
| staleMemoryResultsDropped | 3 | `$L4A/task-3-fullsuite-run1.txt:7028` "Caught error: Timeout()" |
| stopKillsProcessGroup | ~4 | `$L4A/task-3-fix3-fullsuite.txt:4819` |
| demoTimeout | 3 | `$LC/C2a-fullsuite.txt:3224` "61.345… < 30" |
| devHostServesOnlyItsFolder… | 1 | `$LC/C1b-fix1-fullsuite.txt:5015` |
| TurnContainmentTests timing | 0 (flake list only) | — |
| realServerIfPythonAvailable | 0 (flake list only) | — |
| stalePidHandled | 4 with `OutsideChild`, many before | `$LC/C2a-fullsuite.txt:7642` "the stale litestream was left running" |
| (systemic) sleep-poisoned run | 15 `idleTimeout`s at ~334 s | `$LC/progress.md:98-100` |
