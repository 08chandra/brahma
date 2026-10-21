# Plan 2 — Brahma Mac App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native SwiftUI `Brahma.app`, built from SwiftPM with a script, that embeds the Plan 1 `Orchestrator`. It gives the owner a Slack-style company rail, a sidebar, live chat and DMs, search, a mission-control skeleton (layout B) with a live activity feed, a top bar, an agent roster with hire/pause/wake/kill, and a menu bar extra. Quitting pauses the engine and relaunch resumes it, and the app coordinates with `brahma run` through `OrchestratorLock`.

**Architecture:** Three layers. `BrahmaCore` gets a few Linux-portable store additions (owner read marks, unread counts, a fresh-read company update, recent events). `BrahmaAppModel` is a new library target with `@MainActor @Observable` models, formatting and the `EngineHost`. It imports Foundation and Observation only, so Swift Testing can cover all of it. `BrahmaApp` is a thin SwiftUI/AppKit executable. Live updates come from one poller, `AppModel.tick()`, which runs every 500 ms. It reads new `ActivityEvent`s by id cursor, and it reloads a full `Snapshot` when events arrive or every 4th tick. Agents' MCP servers and the CLI write from other processes, which GRDB `ValueObservation` cannot see, so polling the shared WAL database is the one sync mechanism. `scripts/make-app.sh` builds `Brahma.app`. The `brahma` CLI is bundled at `Brahma.app/Contents/Helpers/brahma`, and agents' MCP configs point to it.

**Tech Stack:** Swift 6 (Xcode toolchain, manifest `swift-tools-version: 6.0`), SwiftPM, SwiftUI + AppKit (macOS 14+), Observation, GRDB.swift 7.x (via BrahmaCore), Swift Testing, `codesign` (ad-hoc).

**Spec:** `docs/superpowers/specs/2026-10-20-agent-company-design.md` (§6.1, §6.2, §6.7 multiple companies, §6.12, §6.13). Roadmap and Plan 1 conventions: `docs/superpowers/plans/2026-10-20-plan1-core-engine.md`.

**Decisions this plan pins (with reasons):**
- **SwiftPM + script, no Xcode project.** It is reproducible, diffable and needs no generator. `make-app.sh` assembles the bundle, writes `Info.plist` and ad-hoc signs inside-out.
- **CLI helper at `Contents/Helpers/brahma`, not `Contents/MacOS/brahma`.** The default APFS volume is case-insensitive, so `MacOS/Brahma` (the app) and `MacOS/brahma` would be the same file. `Contents/Helpers` is Apple's location for nested helper tools and codesign handles it.
- **Lock policy: "first engine wins, the app is a live client otherwise, and it takes over automatically".** On launch the app tries `OrchestratorLock`. If `brahma run` holds the lock, the app shows a banner ("Engine running in terminal…") and never schedules. Owner actions (posting, pause/wake/kill, mode, hire) still write the DB, exactly as `brahma say` or `brahma pause` do while `brahma run` runs, so the window is not dead. Every 5 s the app retries the lock and takes over when the terminal engine exits. Nothing can double-schedule, because scheduling requires the lock.
- **Quit = stop the engine, not pause the companies.** `runForever` is cancelled: in-flight turns are recorded `interrupted` and their agents return to `ready`. `Company.status` is never written, so relaunch resumes (spec §6.1). Closing the window keeps the engine running in the menu bar.
- **PATH for Finder launches.** A GUI app gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, where neither `claude` nor the agents' tools (node, git from Homebrew) are found. At launch the app reads the login shell's PATH (`$SHELL -ilc`, 3 s timeout), merges it into its own environment so every child inherits it, and resolves `claude` (override: `BRAHMA_CLAUDE`).
- **Chat replaces the top half; the activity feed stays at the bottom** (spec §9 leaves this choice to the builder). The whole window is mission control, and the owner keeps watching activity while chatting.
- **Visual verification without Screen Recording permission.** `--ui-snapshot` makes the app render its own window (or its attached sheet) to PNG with `NSView.cacheDisplay`. `--smoke-test` checks the full launch → load → window → engine → quit path with no XCUITest.

**Roadmap:** unchanged from Plan 1. Plan 3 adds org and work (sprint and Auto mode in the top bar), Plan 4 adds the real map and previews, and Plan 5 adds requests, notifications and Keychain.

## Global Constraints

- Names: app `Brahma.app`, bundle id `dev.brahma.app`, executable `Brahma`, library `BrahmaCore`, CLI `brahma`. New targets: `BrahmaAppModel` (library), `BrahmaApp` (executable), `BrahmaAppModelTests` (tests).
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The manifest stays `swift-tools-version: 6.0` (Swift 6 language mode). The deployment target stays `.macOS(.v14)` (it already has `@Observable`, `MenuBarExtra`, `.inspector` and `onKeyPress`).
- No `.xcodeproj`. Build the app only with `scripts/make-app.sh [debug|release]`, whose output is `.build/Brahma.app`.
- `BrahmaCore` stays Linux-portable (spec §6.13): no AppKit, SwiftUI, Observation or Apple-only APIs. `BrahmaAppModel` imports only `Foundation`, `Observation` and `BrahmaCore` (no SwiftUI, no AppKit). SwiftUI and AppKit appear only in `Sources/BrahmaApp`.
- The app uses the same data as the CLI: `BrahmaPaths.fromEnvironment()` (`BRAHMA_HOME`, `BRAHMA_WORKSPACES`), DB `<home>/brahma.sqlite` opened with `Store(path:)` after creating `<home>`, and workspaces `paths.workspaces`. Agent MCP configs use the bundled `Brahma.app/Contents/Helpers/brahma`.
- One engine per data home. The app constructs an `Orchestrator` only while holding `OrchestratorLock.acquire(paths:)`.
- Quit stops the engine through `Orchestrator.runForever` cancellation, with a 15 s bound, and never writes `Company.status`. Closing the main window never stops the engine.
- The owner is `@owner`. Owner messages go through `MessageRouter` with `Sender.owner`.
- Agent states are exactly `ready, running, blocked, sleeping, killed`. Usage modes are `low, balanced, max`, displayed as "Low", "Balanced", "Max" (spec §6.7).
- Agent-controlled text (messages, turn summaries, activity text, blockers, handles, company names) is never shown through `LocalizedStringKey` or Markdown parsing. Use `Text(verbatim:)` or `Text(MessageText.attributed(...))`.
- Live state changes only through `AppModel.tick()`. Poll DB reads run off the main actor (`Task.detached`). Do not use GRDB `ValueObservation`.
- Tests use Swift Testing. Each test file holds one `@Suite struct <FileNameWithoutExtension>` (add `@MainActor` when it touches models) so that `swift test --filter <Suite>` selects it.
- UI screenshots go to `.superpowers/ui/` (already gitignored) and are never committed.
- Every commit message ends with these two lines (use your own model name):
  `Co-Authored-By: Claude <your model name> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`
- Out of scope: org-chart generation, work items, sprints, gates, Auto mode (Plan 3); real map rendering, previews, worktrees (Plan 4); sandbox, Keychain, notifications, requests inbox, file drop (Plan 5). Do not add UI for them beyond the placeholders named here.

## Review Focus

1. **The app is launched from Finder or the Dock** (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`). `claude` must still be found and agents' Bash must get the owner's PATH. If `claude` truly isn't installed, the owner sees a clear banner instead of every turn failing, and the lock is left free for `brahma run`. → Task 4 `ToolLocatorTests.loginPathParsedBetweenMarkers`, `ToolLocatorTests.mergedPathPutsLoginFirstAndDedups`, `EngineHostTests.missingToolsFailWithoutTakingLock`.
2. **Quit (⌘Q, menu Quit, logout, SIGTERM) while turns are in flight.** Turns are recorded `interrupted`, agents end `ready` with their inbox still pending, quit finishes within 15 s even if a child never exits, and relaunch runs those agents again. → Task 4 `EngineHostTests.stopInterruptsTurnAndReturnsAgentReady`, `EngineHostTests.stopIsBoundedWhenChildrenNeverExit`, `EngineHostTests.relaunchResumesInterruptedAgent`, `scripts/smoke-app.sh` check "no agent running after quit".
3. **`brahma run` is already running, or stops while the app is open.** There is no double scheduling, the app shows the external banner, and it takes over within about 5 s once the terminal engine exits. → Task 4 `EngineHostTests.firstHostEmbedsSecondIsExternal`, `AppModelEngineTests.tickRetriesTakeover`, `scripts/smoke-app.sh` external and takeover cases.
4. **Other processes write while the app is open** (MCP servers posting, `brahma say`, `brahma company weight`). The UI reflects the change within about 2 s, even when the write emits no event, and the app's own edits never overwrite fresher fields with a stale copy. → Task 2 `AppModelTests.pollSeesCrossProcessWrites`, `AppModelTests.snapshotRefreshesWithoutEventsWithin4Ticks`; Task 1 `OwnerViewTests.updateCompanyByIdReadsFresh`.
5. **Agent text containing Markdown or links** (`[click](http://evil)`, `**x**`). It renders verbatim and never as a live link or styled text. Only known `@handles` are emphasized. → Task 5 `MessageTextTests.messageTextIsVerbatim`.

---

## File Structure

```
Package.swift                                   + BrahmaAppModel, BrahmaApp, BrahmaAppModelTests
Sources/BrahmaCore/Store/Migrations.swift       + migration "v2-owner-read"
Sources/BrahmaCore/Store/Store+OwnerView.swift  markRead, unreadCounts, updateCompany(id:), recentEvents
Sources/brahma/RunCommand.swift                 lock-held message names the app too
Sources/BrahmaAppModel/
  AppModel.swift                AppModel: selection, sheets, company actions, tick/polling
  Live/Snapshot.swift           Snapshot, CompanySummary — loaded off-main
  Presentation/Formatting.swift StateCounts, UsageText, BlockerText, CompanyInitials, ChannelTitle, TimeText
  Presentation/Sidebar.swift    SidebarItem, SidebarRow, SidebarSections
  Presentation/MessageText.swift verbatim AttributedString with @mention emphasis
  Presentation/ActivityText.swift ActivityFilter, ActivityText, AgentBadge
  Forms/CompanyForm.swift       CompanyForm, FormError
  Forms/HireForm.swift          HireForm, AgentModelChoice
  LaunchOptions.swift           LaunchOptions, SelectTarget
  Engine/ToolLocator.swift      MCP helper, claude, login-shell PATH
  Engine/EngineHost.swift       EngineHost, EngineStatus, EngineTools, EngineSetupError
  Chat/ChatModel.swift          ChatModel, ChatMessage, ChatTarget
  Chat/MentionCompleter.swift
  Search/SearchModel.swift      SearchModel, SearchHit
  Agents/AgentDetail.swift      AgentDetail + AppModel agent actions
  MenuBar/MenuBarSummary.swift  MenuBarSummary, MenuCompanyRow
Sources/BrahmaApp/
  BrahmaApp.swift               @main App: Window("main") + MenuBarExtra
  AppDelegate.swift             boot, quit→stop, signals, activation policy, openMainWindow
  Harness.swift                 --smoke-test / --ui-snapshot
  Views/MainWindow.swift  CompanyRail.swift  Sidebar.swift  TopBar.swift  DetailView.swift
  Views/EngineBanner.swift  NewCompanySheet.swift  StartupErrorView.swift
  Views/ChatView.swift  Composer.swift  NewDMPicker.swift  SearchResultsView.swift
  Views/MissionControlView.swift  ActivityFeedView.swift  AgentsView.swift  HireSheet.swift
  Views/MenuBarContent.swift
Tests/BrahmaCoreTests/OwnerViewTests.swift
Tests/BrahmaAppModelTests/
  TestSupport.swift  AppModelTests.swift  FormattingTests.swift  LaunchOptionsTests.swift
  ToolLocatorTests.swift  EngineHostTests.swift  AppModelEngineTests.swift
  ChatModelTests.swift  MessageTextTests.swift  SearchModelTests.swift
  ActivityTextTests.swift  AgentActionsTests.swift  MenuBarSummaryTests.swift
scripts/make-app.sh  seed-demo.sh  fake-claude.sh  smoke-app.sh  ui-snapshot.sh
README.md                                       + "Mac app" section
```

---

### Task 1: Core additions for the owner's view

**Files:**
- Create: `Sources/BrahmaCore/Store/Store+OwnerView.swift`, `Tests/BrahmaCoreTests/OwnerViewTests.swift`
- Modify: `Sources/BrahmaCore/Store/Migrations.swift` (append migration), `Sources/brahma/RunCommand.swift:29-33` (lock message), `Tests/BrahmaCoreTests/CLIValidationTests.swift` (one test)

**Interfaces:**
- Consumes: `Store`, `Company`, `Channel`, `Message`, `ActivityEvent`, `OrchestratorLock` (Plan 1).
- Produces:
  - Migration `"v2-owner-read"`: table `ownerReadMark(channelId TEXT PRIMARY KEY REFERENCES channel(id) ON DELETE CASCADE, lastReadAt DATETIME NOT NULL)`.
  - `Store.markRead(channelId: String, upTo: Date) throws` stores `max(existing, upTo)` and never moves backward.
  - `Store.unreadCounts(companyId: String) throws -> [String: Int]` maps channelId → count of messages with `senderId != "owner"` and `createdAt > lastReadAt` (all messages if there is no mark). It covers channels of kind `.channel` plus DMs that have `owner` as a member. Agent-to-agent DMs are excluded and zero counts are omitted. Write it as one SQL query; GRDB's date text compares lexicographically.
  - `@discardableResult Store.updateCompany(id: String, _ change: (inout Company) -> Void) throws -> Company` re-reads, applies `change` and writes inside one write transaction. An unknown id throws `StoreError.notFound`.
  - `Store.recentEvents(companyId: String, limit: Int) throws -> [ActivityEvent]` returns the newest `limit` events for the company, oldest first.
  - `brahma run` lock-held error text: `another Brahma engine (the Brahma app or 'brahma run') is already using <home>`.

- [ ] **Step 1: Write failing tests** in `OwnerViewTests.swift` (`@Suite struct OwnerViewTests`). Use file-backed stores from `tempDir()` and `MessageRouter` with explicit `now:`:
```swift
@Test func unreadCountsChannelsAndOwnerDMsOnly() throws {
  /* ceo, cto hired. ceo posts #general "a","b"; ceo DMs owner "c"; ceo DMs cto "d"; owner posts #general "e".
     #expect(counts == [general.id: 2, ownerDM.id: 1]) — no key for dm:ceo:cto */
}
@Test func markReadIsMonotonic() throws {
  /* ceo posts at t1,t2,t3. markRead(upTo: t2); markRead(upTo: t1) → unreadCounts[general] == 1 */
}
@Test func markReadAtNewestClearsChannel() throws { /* markRead(upTo: newest.createdAt) → unreadCounts[general] == nil */ }
@Test func updateCompanyByIdReadsFresh() throws {
  /* stores A and B on the same file. A fetches company (stale copy). B: updateCompany(id:) { $0.priorityWeight = 3 }.
     A: updateCompany(id:) { $0.usageMode = .max } → returned and reloaded: priorityWeight == 3, usageMode == .max */
}
@Test func updateCompanyUnknownIdThrows() throws { #expect(throws: StoreError.notFound) { try s.updateCompany(id: "nope") { _ in } } }
@Test func recentEventsReturnsNewestOldestFirst() throws {
  /* 5 events for A, 2 for B, interleaved → recentEvents(companyId: A, limit: 3).map(\.text) == ["a3","a4","a5"] */
}
```
  In `CLIValidationTests`, add `import BrahmaCore`, and give the private `brahma(_:)` helper a `home: URL? = nil` parameter (nil keeps today's fresh `tempDir()`; it sets `BRAHMA_HOME` to `<home>/home`). Then add `runRefusesWhenLockHeld`: create a temp dir `d`, hold `OrchestratorLock.acquire(paths:)` on `BrahmaPaths(home: d/home, workspaces: d/ws)`, call `brahma(["run"], home: d)`, and expect exit code ≠ 0 and stderr containing `another Brahma engine (the Brahma app or 'brahma run') is already using`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OwnerViewTests`. Expected: FAIL (methods missing).
- [ ] **Step 3:** Implement the migration, the four `Store` methods and the message change.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS (live test skipped).
- [ ] **Step 5:** Commit `feat(core): owner read marks, unread counts, fresh company update, recent events` with the trailer lines.

---

### Task 2: App model, snapshot and live poller

**Files:**
- Modify: `Package.swift` (add `.target(name: "BrahmaAppModel", dependencies: ["BrahmaCore"])` and `.testTarget(name: "BrahmaAppModelTests", dependencies: ["BrahmaAppModel"])`)
- Create: `Sources/BrahmaAppModel/AppModel.swift`, `Live/Snapshot.swift`, `Presentation/Formatting.swift`, `Presentation/Sidebar.swift`, `Forms/CompanyForm.swift`
- Test: `Tests/BrahmaAppModelTests/TestSupport.swift`, `AppModelTests.swift`, `FormattingTests.swift`

**Interfaces:**
- Consumes: Task 1 store methods; Plan 1 `Store`, `MessageRouter`, `UsageGate.evaluate`, `RateLimitInfo`, `Turn`.
- Produces:
  - `struct StateCounts: Equatable, Sendable { var running, ready, blocked, sleeping, killed: Int; init(_ agents: [Agent]); var total: Int; var line: String }`. `line` is `"<r> running · <rd> ready · <b> blocked · <s> sleeping"` (killed omitted).
  - `struct CompanySummary: Equatable, Sendable, Identifiable { var company: Company; var counts: StateCounts; var unread: Int /* owner-member channels only */; var waitingOnOwner: Int /* agents blocked(.owner) */; var id: String; var badge: Int /* unread + waitingOnOwner */; var initials: String }`
  - `struct Snapshot: Equatable, Sendable { var companies: [CompanySummary]; var agents: [Agent] /* selected company */; var channels: [Channel] /* all of the selected company's channels: store.channels(companyId:) */; var unreadByChannel: [String: Int] /* raw store.unreadCounts(companyId:) */; var lastTurns: [String: Turn] /* agentId → lastTurn */; var usage: RateLimitInfo?; static let empty: Snapshot; static func load(store: Store, selectedCompanyId: String?) throws -> Snapshot }`. Only `CompanySummary.unread` (the rail badge) is restricted to owner-member channels: it sums `unreadCounts` over `channels(companyId:memberId: "owner")`, computed for every company.
  - `enum SidebarItem: Hashable, Sendable { case missionControl, activity, agents, channel(id: String), dm(handle: String) }`
  - `struct SidebarRow: Equatable, Identifiable, Sendable { var item: SidebarItem; var title: String; var unread: Int; var id: SidebarItem }`, `struct SidebarSections: Equatable, Sendable { var channels: [SidebarRow]; var directMessages: [SidebarRow]; var agentConversations: [SidebarRow] }`. Kind `.channel` goes to `channels` (`.channel(id:)`). A DM whose name has an `owner` component goes to `directMessages` (`.dm(handle:)`). Any other DM goes to `agentConversations` (`.channel(id:)`).
  - `enum ChannelTitle { static func title(_ c: Channel) -> String }` returns `"#general"`; `"dm:ceo:owner"` → `"@ceo"`; `"dm:ceo:cto"` → `"@ceo · @cto"`.
  - `enum TimeText { static func hm(_ d: Date, timeZone: TimeZone = .current) -> String /* "HH:mm" */; static func hms(_ d: Date, timeZone: TimeZone = .current) -> String /* "HH:mm:ss" */ }` (en_US_POSIX).
  - `enum UsageText { static func line(_ info: RateLimitInfo?, now: Date, timeZone: TimeZone = .current) -> String; static func gateLine(_ info: RateLimitInfo?, mode: UsageMode, now: Date, timeZone: TimeZone = .current) -> String? }`
  - `enum BlockerText { static func describe(_ b: Blocker?, handles: [String: String], timeZone: TimeZone = .current) -> String }`
  - `enum CompanyInitials { static func of(_ name: String) -> String }` returns the uppercased first grapheme of each of the first two words, or `"?"` if the name is blank.
  - `struct CompanyForm: Equatable, Sendable { var name = ""; var goal = ""; func validate() -> String? }`, `enum FormError: Error, Equatable { case invalid(String) }`
  - `enum AppSheet: String, Identifiable, Sendable { case newCompany, hire }`
  - `@MainActor @Observable final class AppModel`:
    - `init(store: Store, paths: BrahmaPaths, clock: @escaping @Sendable () -> Date = { .now })`; `let store: Store; let paths: BrahmaPaths`
    - `private(set) var snapshot: Snapshot; private(set) var loaded: Bool; private(set) var activity: [ActivityEvent] /* selected company, ≤ 500, oldest first */`
    - `private(set) var selectedCompanyId: String?; private(set) var sidebarSelection: SidebarItem = .missionControl; var selectedAgentId: String?; var presentedSheet: AppSheet?; var errorMessage: String?`
    - `var selectedCompany: CompanySummary? { get }; var sidebar: SidebarSections { get }; var usageLine: String { get }; var usageGateLine: String? { get }`
    - `func load() async` sets the cursor to `maxEventId()`, selects the first company, loads `recentEvents(limit: 200)` and the snapshot, then sets `loaded = true`.
    - `func tick(forceSnapshot: Bool = false) async`; `func startPolling(interval: Duration = .milliseconds(500))`; `func stopPolling()`
    - `func selectCompany(_ id: String) async` (resets `sidebarSelection = .missionControl`, `selectedAgentId = nil`, and reloads activity and snapshot); `func select(_ item: SidebarItem)`
    - `func createCompany(_ form: CompanyForm) async throws -> Company`; `func setUsageMode(_ mode: UsageMode) async`; `func setCompanyRunning(_ running: Bool, companyId: String) async`

`tick` algorithm (write it as stated):
```
events = []; repeat { batch = off-main store.events(afterId: cursor, limit: 500); events += batch; cursor = batch.last?.id ?? cursor } while batch.count == 500   // one tick drains a burst
append events whose companyId == selectedCompanyId to activity; drop oldest beyond 500
ticksSinceSnapshot += 1
if forceSnapshot || !events.isEmpty || ticksSinceSnapshot >= 4:
    new = off-main Snapshot.load(store, selectedCompanyId); if new != snapshot { snapshot = new }; ticksSinceSnapshot = 0
on a DB error: errorMessage = "Couldn't read the Brahma database: <error>"; keep polling
```
Mutating actions write through `Store` (mode and status through `updateCompany(id:)`, never a whole-row write of a cached copy) and then call `tick(forceSnapshot: true)`. `createCompany` validates (`FormError.invalid(message)`), calls `store.createCompany(name:goal:workspacesRoot: paths.workspaces)` with trimmed fields and selects the result.

Exact copy: `UsageText.line` returns `"Usage: no data yet"` for nil. Otherwise it returns `"5h <p>% · 7d <p>%"`, where a percent is `Int((v*100).rounded())` and a nil value shows `n/a`, followed by `" · resets HH:mm"` when `resetsAt > now`. `gateLine` returns `"Usage limit — new turns resume at HH:mm"` when `UsageGate.evaluate` is `.closed(until)` and nil when the gate is open. `BlockerText` returns `"Waiting on @cto"`, `"Waiting on you: <reason>"`, `"Usage limit until HH:mm"`, `"Turn budget until HH:mm"`, `"Retrying after failure <n> at HH:mm"`, or `""` for nil. `CompanyForm.validate` returns `"Name is required"` or `"Goal is required"`.

- [ ] **Step 1: Write `TestSupport.swift`:** `tempDir()`; `makeHome() throws -> (Store, BrahmaPaths)` (file-backed, `BrahmaPaths(home:workspaces:)` under a temp dir); `seedAcme(_ s: Store, _ p: BrahmaPaths) throws -> (Company, ceo: Agent, cto: Agent, eng: Agent)`, where Acme has ceo `ready`, cto `sleeping` and eng `blocked(.owner(reason: "key"))`, plus an empty company "Globex"; `eventually(timeout: Duration = .seconds(3), _ cond: () throws -> Bool) async throws`.
- [ ] **Step 2: Write failing tests.** `FormattingTests` (`@Suite struct FormattingTests`) uses `timeZone: .gmt` and fixed dates:
```swift
@Test func stateCountsLine() { /* [running, ready, ready, blocked, sleeping, killed] → line == "1 running · 2 ready · 1 blocked · 1 sleeping"; killed == 1; total == 6 */ }
@Test func usageLineFormats() { /* nil → "Usage: no data yet"; 0.38/0.12, resetsAt 14:00 > now → "5h 38% · 7d 12% · resets 14:00";
                                   nil utils → "5h n/a · 7d n/a"; resetsAt in past → no " · resets" */ }
@Test func usageGateLine() { /* status "rejected", resetsAt 14:00 → "Usage limit — new turns resume at 14:00"; util 0.85: .low → non-nil, .max → nil; allowed 0.1 → nil */ }
@Test func blockerText() { /* the five cases and nil, exact strings above, handles [cto.id: "cto"] */ }
@Test func companyInitials() { #expect(CompanyInitials.of("Acme Labs") == "AL"); #expect(CompanyInitials.of("acme") == "A")
                               #expect(CompanyInitials.of("  ") == "?"); #expect(CompanyInitials.of("über cool co") == "ÜC") }
@Test func channelTitles() { /* "#general", "@ceo", "@ceo · @cto" */ }
```
  `AppModelTests` (`@MainActor @Suite struct AppModelTests`):
```swift
@Test func loadSelectsFirstCompanyAndCountsStates() async throws {
  /* seedAcme; load() → loaded; companies.count == 2; selectedCompanyId == acme.id;
     selectedCompany.counts.line == "0 running · 1 ready · 1 blocked · 1 sleeping"; waitingOnOwner == 1 */ }
@Test func pollSeesCrossProcessWrites() async throws {
  /* load; second Store on same file: router.post(... "general", from: .agent(ceo.id), text: "hello from mcp");
     tick() → activity.last.text contains "hello from mcp"; selectedCompany.unread == 1 */ }
@Test func snapshotRefreshesWithoutEventsWithin4Ticks() async throws {
  /* load; second Store: updateCompany(id: acme) { $0.priorityWeight = 5 } (no event); 4 × tick() → selectedCompany.company.priorityWeight == 5 */ }
@Test func eventsCursorNeverDuplicates() async throws { /* tick ×2 with nothing new → activity.count unchanged; append 3 → +3 */ }
@Test func activityCappedAt500() async throws { /* append 520 Acme events → tick → activity.count == 500, last.id == maxEventId */ }
@Test func otherCompanyEventsStayOutOfFeed() async throws { /* Globex event → not in activity */ }
@Test func selectCompanyLoadsItsRecentActivity() async throws { /* 3 Globex events; select(.agents); selectCompany(globex) → activity.count == 3, sidebarSelection == .missionControl */ }
@Test func createCompanySelectsIt() async throws { /* createCompany(CompanyForm(name: " New Co ", goal: "Ship")) → name "New Co", selected, dir paths.workspaces/new-co exists */ }
@Test func createCompanyRejectsBlank() async throws { /* await #expect(throws: FormError.invalid("Name is required")) {…}; goal blank → "Goal is required" */ }
@Test func setUsageModeKeepsFreshFields() async throws { /* second Store sets weight 4; model.setUsageMode(.max) → store company: .max and weight 4 */ }
@Test func pauseAndResumeCompany() async throws { /* setCompanyRunning(false, acme) → store status .paused and selectedCompany.company.status == .paused without extra ticks */ }
@Test func sidebarSectionsGroupChannels() async throws {
  /* createChannel "architecture" [ceo]; ceo DMs owner; ceo DMs cto → channels titles ["#general","#architecture"],
     directMessages == [row .dm(handle:"ceo") "@ceo" unread 1], agentConversations titles ["@ceo · @cto"] with .channel(id:) */ }
```
- [ ] **Step 3:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "FormattingTests|AppModelTests"`. Expected: FAIL (types missing).
- [ ] **Step 4:** Implement the files listed. `startPolling` is a `Task` loop of `await tick()` and `Task.sleep(for: interval)`. `stopPolling` cancels it.
- [ ] **Step 5:** Rerun. Expected: PASS. Then run full `swift test` (same prefix). Expected: PASS.
- [ ] **Step 6:** Commit `feat(app-model): AppModel, snapshot and live event poller` with the trailer lines.

---

### Task 3: App bundle, window shell, top bar and launch harness

**Files:**
- Modify: `Package.swift` (add `.executableTarget(name: "BrahmaApp", dependencies: ["BrahmaAppModel"])`), `AppModel.swift` (add `apply(_:)`)
- Create: `Sources/BrahmaAppModel/LaunchOptions.swift`; `Sources/BrahmaApp/BrahmaApp.swift`, `AppDelegate.swift`, `Harness.swift`, `Views/MainWindow.swift`, `CompanyRail.swift`, `Sidebar.swift`, `TopBar.swift`, `DetailView.swift`, `NewCompanySheet.swift`, `StartupErrorView.swift`; `scripts/make-app.sh`, `scripts/seed-demo.sh`, `scripts/smoke-app.sh`, `scripts/ui-snapshot.sh` (all `chmod +x`, `set -euo pipefail`, run from repo root)
- Test: `Tests/BrahmaAppModelTests/LaunchOptionsTests.swift`

**Interfaces:**
- Consumes: Task 2 `AppModel`, `SidebarItem`, `AppSheet`, `CompanyForm`, formatting types.
- Produces:
  - `enum SelectTarget: Equatable, Sendable { case missionControl, activity, agents, agent(handle: String), channel(name: String), dm(handle: String), search(String), sheet(AppSheet); init?(_ s: String) }`. It parses `mission`, `activity`, `agents`, `agent:<h>`, `channel:<name>`, `dm:<h>`, `search:<q>`, `hire` and `new-company`, lowercasing handles and names. Anything else is nil.
  - `struct LaunchOptions: Equatable, Sendable { var smokeTest = false; var smokeHold: Double = 0; var smokeCloseWindow = false; var snapshotPath: String?; var select: SelectTarget?; static func parse(_ args: [String]) -> LaunchOptions }`. It parses flags `--smoke-test`, `--smoke-hold <s>`, `--smoke-close-window`, `--ui-snapshot <png>` and `--select <target>`, skips `args[0]`, and ignores unknown arguments such as `-psn_…` and `-NSDocumentRevisionsDebugMode YES`. Tasks 4 and 9 implement hold and close-window.
  - `AppModel.apply(_ t: SelectTarget)` resolves names against the snapshot: `.channel(name:)` becomes `select(.channel(id:))`, or, if there is no such channel, sets `errorMessage = "No channel #<name>"`. `.agent(handle:)` becomes `select(.agents)` plus `selectedAgentId`. `.sheet(s)` sets `presentedSheet = s`. Task 6 handles `.search`, which is a no-op until then.
  - The `AppDelegate` (`NSObject, NSApplicationDelegate`) owns `boot: Result<AppModel, BootError>`, where `BootError` is `{ path: String; message: String }`. `AppModel` is built from `BrahmaPaths.fromEnvironment()` after `createDirectory(home)` and `Store(path: paths.database.path)`, which is the same as the CLI's `openStore()`. It also owns `options: LaunchOptions` (parsed from `CommandLine.arguments`) and `var openMainWindow: (() -> Void)?` (set by `MainWindow.onAppear` from `@Environment(\.openWindow)`). `applicationDidFinishLaunching` runs `Task { await model.load(); model.startPolling(); Harness.runIfRequested(...) }`.
  - Smoke output format: one stdout line, flushed: `SMOKE OK companies=<n> agents=<total> engine=<label> windows=<k>` (Task 3 prints `engine=none`; Task 4 prints `EngineStatus.label`; Task 9 appends ` lifecycle=ok`). The line is printed after readiness and `smokeHold` seconds, then the app calls `NSApp.terminate(nil)` and exits 0. If readiness is not reached within 20 s, it prints `SMOKE FAIL <reason>` and calls `exit(1)`. Readiness means `model.loaded` and at least one visible window whose identifier starts with `main`.
  - Snapshot: once ready, the harness applies `select`, sets the content size to 1280×800, waits `max(1.5, smokeHold)` s, and renders `(window.attachedSheet ?? window)`'s `contentView?.superview ?? contentView` via `bitmapImageRepForCachingDisplay(in:)` and `cacheDisplay(in:to:)` to PNG at `snapshotPath`. It prints `SNAPSHOT <path>` and terminates, or prints `SNAPSHOT FAIL <reason>` and calls `exit(1)`.

Window layout (spec §6.2):
- Scene: `Window("Brahma", id: "main")`, `.defaultSize(width: 1280, height: 800)`, minimum content 900×600.
- Content: `HStack(spacing: 0) { CompanyRail().frame(width: 68); Divider(); NavigationSplitView { Sidebar() } detail: { DetailView() } }`, plus `.sheet(item:)` bound to `presentedSheet` and `.alert` for `errorMessage`.
- `navigationTitle` is the company name (or "Brahma"). `navigationSubtitle` is `counts.line`.
- Rail icon: 44×44, corner radius 10, initials in 15 pt semibold. Fill is accent when selected and `.quaternary` otherwise. A 10 pt status dot sits bottom-trailing (green = running, gray = paused). A red capsule badge sits top-trailing when `badge > 0` (shown as `99+` above 99). Add `.help(name)` and a context menu with "Pause"/"Resume". A "+" button at the bottom (`.help("New company")`) opens `.newCompany`.
- The sidebar is `List(selection:)` bound through `Binding(get: model.sidebarSelection, set: model.select)`. It has rows "Mission Control" (`square.grid.2x2`), "Activity" (`list.bullet.rectangle`) and "Agents" (`person.3`), then sections "Channels", "Direct messages" and "Agent conversations" (the last one collapsed by default). Rows with unread messages are bold, and DM rows show their count.
- TopBar (`ToolbarItemGroup(placement: .primaryAction)`, shown only when a company is selected) has three items. First, the usage text: `usageGateLine` in orange with `exclamationmark.triangle` if set, otherwise `usageLine` in secondary. Second, a segmented `Picker("Usage mode")` with options "Low", "Balanced", "Max" calling `setUsageMode`. Third, a button labelled "Pause company" (`pause.fill`) or "Run company" (`play.fill`).
- The `.hire` sheet shows `ContentUnavailableView("Hire Agent", systemImage: "person.badge.plus")` and a Close button until Task 8 replaces it.
- DetailView switches on `sidebarSelection` and shows `ContentUnavailableView` placeholders (titled with the item name) until Tasks 5, 7 and 8 replace them. With no companies it shows "Create your first company" and a "New Company" button.
- `NewCompanySheet` has a Name `TextField`, a Goal `TextField(axis: .vertical, lineLimit 3...6)`, the validation message in red, and Cancel/Create buttons (Create is the default and is disabled while `validate() != nil`).
- `StartupErrorView` shows `"Brahma couldn't open its database at <path>."` with the error and a Quit button. In smoke mode a boot failure prints `SMOKE FAIL store <message>` and exits 1.

Scripts:
- `make-app.sh [debug|release]` (default `release`). It exports the `DEVELOPER_DIR`, runs `swift build -c $C --product brahma` and `--product BrahmaApp`, and sets `BIN=$(swift build -c $C --show-bin-path)`. It rebuilds `.build/Brahma.app` from scratch: `Contents/MacOS/Brahma` ← `$BIN/BrahmaApp`, `Contents/Helpers/brahma` ← `$BIN/brahma`, and every `$BIN/*.bundle` except `*Tests.bundle` → `Contents/Resources/` (GRDB ships `GRDB_GRDB.bundle`). It writes `Contents/PkgInfo` (`APPL????`) and `Contents/Info.plist` with these keys: `CFBundleIdentifier dev.brahma.app`, `CFBundleName Brahma`, `CFBundleDisplayName Brahma`, `CFBundleExecutable Brahma`, `CFBundlePackageType APPL`, `CFBundleShortVersionString 0.2.0`, `CFBundleVersion 1`, `LSMinimumSystemVersion 14.0`, `LSUIElement false`, `NSHighResolutionCapable true`, `NSPrincipalClass NSApplication`, `LSApplicationCategoryType public.app-category.developer-tools`. It then runs `codesign --force --sign - Contents/Helpers/brahma`, then `codesign --force --sign - --identifier dev.brahma.app .build/Brahma.app` (no `--deep`) and `codesign --verify --strict`, and prints `built .build/Brahma.app`.
- `seed-demo.sh` refuses (exit 1, message `set BRAHMA_HOME and BRAHMA_WORKSPACES to temp dirs`) if either variable is unset or `BRAHMA_HOME` is the default `~/Library/Application Support/Brahma`. It runs these commands with `.build/Brahma.app/Contents/Helpers/brahma`: `company create Acme --goal "Build a todo app"`; `company create Globex --goal "Plan a newsletter"`; `hire Acme ceo --role ceo --model opus`; `hire Acme cto --role cto --model sonnet`; `hire Acme eng1 --role engineer --model sonnet`; `hire Acme designer --role designer --model haiku`; `company mode Acme balanced`; `pause Acme eng1`; `company pause Globex`; `say Acme '#general' "@ceo please draft a plan and ask @cto for a stack"`; `say Acme @cto "What stack do you suggest?"`.
- `smoke-app.sh` runs `make-app.sh debug`, creates a temp home and workspaces, seeds them, runs `Brahma --smoke-test`, and requires exit 0 and a line starting with `SMOKE OK companies=2 agents=4`. It ends by printing `SMOKE PASSED`.
- `ui-snapshot.sh <name> [select]` assumes `.build/Brahma.app` exists. It creates a temp home, seeds it, runs `Brahma --ui-snapshot .superpowers/ui/<name>.png [--select <select>]`, requires exit 0 and a non-empty file, and prints the path.

- [ ] **Step 1: Write failing tests** `LaunchOptionsTests` (`@MainActor @Suite struct LaunchOptionsTests`):
```swift
@Test func parsesSmokeAndSnapshot() { /* ["/x/Brahma","--smoke-test","--smoke-hold","8","--smoke-close-window"] → smokeTest, smokeHold 8, smokeCloseWindow;
   ["/x","--ui-snapshot","/tmp/a.png","--select","channel:general"] → snapshotPath "/tmp/a.png", select .channel(name: "general") */ }
@Test func ignoresUnknownAndPsnArgs() { #expect(LaunchOptions.parse(["/x","-psn_0_123","-NSDocumentRevisionsDebugMode","YES"]) == LaunchOptions()) }
@Test func selectTargets() { /* every form above, "dm:CEO" → .dm(handle: "ceo"), "search:stripe hooks" → .search("stripe hooks"), "bogus" → nil */ }
@Test func applyResolvesChannelByName() async throws { /* seeded+load; apply(.channel(name: "general")) → sidebarSelection == .channel(id: general.id);
   apply(.channel(name: "nope")) → selection unchanged, errorMessage == "No channel #nope" */ }
@Test func applyAgentAndSheet() async throws { /* .agent(handle: "cto") → .agents & selectedAgentId == cto.id; .sheet(.newCompany) → presentedSheet == .newCompany */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LaunchOptionsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `LaunchOptions`, `apply`, then the app target, views and scripts above.
- [ ] **Step 4:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: PASS.
- [ ] **Step 5:** Run `scripts/make-app.sh release`. Expected: last line `built .build/Brahma.app`. Running `codesign --verify --strict .build/Brahma.app` exits 0, and `plutil -extract CFBundleIdentifier raw .build/Brahma.app/Contents/Info.plist` prints `dev.brahma.app`.
- [ ] **Step 6:** Run `scripts/smoke-app.sh`. Expected: `SMOKE OK companies=2 agents=4 engine=none windows=1` and then `SMOKE PASSED`.
- [ ] **Step 7: UI smoke.** Run `scripts/make-app.sh debug && scripts/ui-snapshot.sh task3-shell mission && scripts/ui-snapshot.sh task3-new-company new-company`. Then open both PNGs with the Read tool. Expected in `task3-shell`: rail with "A" (green dot) and "G" (gray dot) and a "+"; sidebar with Mission Control/Activity/Agents, Channels "#general" and Direct messages "@cto"; title "Acme" with subtitle "0 running · 3 ready · 0 blocked · 1 sleeping"; "Balanced" selected; a "Pause company" button; "Usage: no data yet". Expected in `task3-new-company`: the sheet with Name/Goal fields and Create disabled. If the image is entirely blank (`cacheDisplay` failed), fall back to `screencapture -x -o -l <window number>` and note it in the task report.
- [ ] **Step 8:** Commit `feat(app): Brahma.app bundle, window shell, rail, sidebar, top bar, launch harness` with the trailer lines.

---

### Task 4: Embedded engine, lock policy, PATH and quit → pause

**Files:**
- Create: `Sources/BrahmaAppModel/Engine/ToolLocator.swift`, `Engine/EngineHost.swift`; `Sources/BrahmaApp/Views/EngineBanner.swift`; `scripts/fake-claude.sh`
- Modify: `AppModel.swift` (engine property and takeover cadence), `AppDelegate.swift`, `Harness.swift` (engine label, `--smoke-hold`), `MainWindow.swift` (banner above the detail), `scripts/smoke-app.sh`, `scripts/ui-snapshot.sh` (export `BRAHMA_CLAUDE=$PWD/scripts/fake-claude.sh`; if `BRAHMA_HOME` is already set by the caller, use it and its `BRAHMA_WORKSPACES` and skip creating and seeding a temp home)
- Test: `ToolLocatorTests.swift`, `EngineHostTests.swift`, `AppModelEngineTests.swift`; add `StubRunner` to `TestSupport.swift`

**Interfaces:**
- Consumes: Plan 1 `Orchestrator(store:runner:paths:config:mcpExecutable:profile:)`, `start()`, `runForever(interval:)`, `OrchestratorLock`, `ClaudeProcessRunner(claudePath:)`, `TurnRunning`, `SchedulerConfig`; Task 2 `AppModel`.
- Produces:
  - `enum ToolLocator`:
    - `static func mcpHelper(appBundle: URL, executable: URL, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile) -> String?`. It returns `<appBundle>/Contents/Helpers/brahma` if executable, else `<executable dir>/brahma` (the `swift run` / `.build/debug` layout), else nil.
    - `static func claude(environment: [String: String], searchPath: String, isExecutable: (String) -> Bool = …) -> String?`. If `BRAHMA_CLAUDE` is set, it returns that value only when it is executable; a bad override returns nil and does not fall back. Otherwise it returns the first `<dir>/claude` on `searchPath`.
    - `static func loginShellPath(shell: String, timeout: Duration = .seconds(3)) -> String?`. It runs `shell -ilc "printf '__BRAHMA_PATH__%s__END__' \"$PATH\""` with stdin `/dev/null`, stderr discarded and stdout redirected to a temp file (not a pipe: a grandchild such as `sleep` would keep a pipe open and block an EOF read). It waits on `terminationHandler` with a semaphore up to `timeout`, sends SIGKILL to the shell on timeout and returns nil, and otherwise reads the file, deletes it and returns `parseMarkedPath`.
    - `static func parseMarkedPath(_ output: String) -> String?`
    - `static func mergePath(login: String?, current: String) -> String` puts login entries first, then the current ones, de-duplicated with empty entries dropped.
  - `enum EngineStatus: Equatable, Sendable { case starting, embedded, external, stopping, stopped, failed(String); var label: String /* "starting","embedded","external","stopping","stopped","failed" */ }`
  - `struct EngineTools: Equatable, Sendable { var claudePath: String; var mcpExecutable: String }`; `enum EngineSetupError: Error, Equatable { case claudeNotFound, helperMissing(path: String) }`
  - `@MainActor @Observable final class EngineHost`:
    - `init(paths: BrahmaPaths, store: Store, makeRunner: @escaping @Sendable (String) -> any TurnRunning = { ClaudeProcessRunner(claudePath: $0) }, config: SchedulerConfig = .init(), tickInterval: Duration = .seconds(1))`
    - `private(set) var status: EngineStatus = .stopped`
    - `func start(tools: Result<EngineTools, EngineSetupError>) async`. If already embedded it does nothing. A tools failure leads to `.failed(msg)` without touching the lock. `OrchestratorLockError.alreadyRunning` leads to `.external`, with the tools remembered for takeover. `.cannotOpen(errno)` leads to `.failed("Can't open the engine lock in <home> (errno <n>).")`. Otherwise it holds the lock, creates the `Orchestrator` (profile `.workspace`), and calls `try await start()`. On error it releases the lock and sets `.failed("Crash recovery failed: <error>")`. On success it sets `engineTask = Task { await orchestrator.runForever(interval: tickInterval) }` and `.embedded`.
    - `func retryTakeover() async` runs `start(tools: remembered)` only while `.external`.
    - `func stop(timeout: Duration = .seconds(15)) async`. When `.embedded`, it sets `.stopping`, cancels the engine task, and races two **unstructured** tasks: one awaits `engineTask.value`, the other sleeps `timeout`; each signals a resume-once `CheckedContinuation` (guarded by a lock flag) and `stop` returns on the first signal. Do not use `withTaskGroup` or a bare `await engineTask.value`: a task group waits for all children at scope exit, and `runForever` ends with `await runner.waitForChildren()`, which may never return, so neither one bounds the wait. It then releases the lock (the process is exiting anyway on timeout) and sets `.stopped`. When `.external`, it just sets `.stopped`.
  - `AppModel.engine: EngineHost?` (settable). In `tick`, every 10th tick (about 5 s) it calls `await engine.retryTakeover()` if `engine?.status == .external`.
  - Failure copy (exact): `claudeNotFound` → `"Can't find the claude CLI. Install Claude Code, or set BRAHMA_CLAUDE to its path, then relaunch Brahma."`; `helperMissing(p)` → `"Brahma's helper tool is missing at <p>. Rebuild the app with scripts/make-app.sh."`.
  - Banner copy (exact). External (blue, `terminal`): `"Engine running in terminal (brahma run). Brahma shows live state and your messages still go through; scheduling happens in the terminal. Brahma takes over when it stops."`. Failed (orange, `exclamationmark.triangle`): the message plus a "Retry" button, which re-resolves tools and calls `start(tools:)`. Stopping: `"Stopping agents…"` with a small `ProgressView`. Embedded, starting and stopped show no banner.

App launch order (in `AppDelegate.applicationDidFinishLaunching`):
1. `signal(SIGPIPE, SIG_IGN)`. Set `SIGINT` and `SIGTERM` to `SIG_IGN` plus `DispatchSource` handlers on the main queue that call `NSApp.terminate(nil)`.
2. `model.load()` and `startPolling()`.
3. Off-main, compute `merged = mergePath(login: loginShellPath(shell: env["SHELL"] ?? "/bin/zsh"), current: env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")`, then `setenv("PATH", merged, 1)` so `claude` and the agents' tools inherit it.
4. Resolve tools with `mcpHelper(appBundle: Bundle.main.bundleURL, executable: Bundle.main.executableURL!)` and `claude(environment:searchPath: merged)`. Then `await engine.start(tools:)`, followed by the harness.

`applicationShouldTerminate`: call `model.stopPolling()`. If the engine is `.embedded` or `.starting`, return `.terminateLater` and run `Task { await engine.stop(timeout: .seconds(15)); sender.reply(toApplicationShouldTerminate: true) }`. Otherwise return `.terminateNow`. Never write `Company.status`. `applicationShouldTerminateAfterLastWindowClosed` returns `false`.

`fake-claude.sh` (test double used only by scripts; `chmod +x scripts/fake-claude.sh` and commit it as executable):
1. Read stdin to EOF.
2. Take the session id from the argument after `--session-id` or `--resume`, and the MCP config path from the argument after `--mcp-config`.
3. Read `mcpServers.company.command` and `args.2`, `args.4`, `args.6` (db, company and agent) with `plutil -extract … raw -o - <file>`.
4. Pipe three JSON-RPC lines into `<command> mcp --db … --company … --agent …`: `initialize` (protocolVersion `2025-06-18`), `notifications/initialized`, and `tools/call` `send_dm` with `{"to":"owner","text":"Acknowledged (fake turn)."}`. This is a DM to the owner, so no other agent wakes up.
5. Print exactly these three lines, with `<sid>` the session id and `<epoch>` = `$(( $(date +%s) + 10800 ))`, which match the keys `StreamParser` reads:
```
{"type":"system","subtype":"init","session_id":"<sid>","model":"fake"}
{"type":"rate_limit_event","session_id":"<sid>","rate_limit_info":{"status":"allowed","resetsAt":<epoch>,"rateLimitType":"five_hour","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.38,"resetsAt":<epoch>},"seven_day":{"utilization":0.12,"resetsAt":<epoch>}}}}
{"type":"result","subtype":"success","is_error":false,"result":"fake turn done","total_cost_usd":0,"api_error_status":null,"session_id":"<sid>"}
```

`smoke-app.sh` additions (export `BRAHMA_CLAUDE=$PWD/scripts/fake-claude.sh` once, at the top of the script, so every case uses it):
- (A) Run `--smoke-test --smoke-hold 8`. Expect `engine=embedded`. Afterwards, `Helpers/brahma status` has no line matching `^  @[a-z0-9_-]+  running`, and `Helpers/brahma log Acme @ceo` contains `Acknowledged (fake turn).` This proves the bundled MCP helper path end to end.
- (B) Make a temp `bin/claude` symlink to `fake-claude.sh` and start `PATH=$bin:$PATH Helpers/brahma run &`. After 2 s, run the app with `--smoke-test` and expect `engine=external`. Send `kill -INT` to the CLI and `wait`, which must exit 0.
- (C) Start `brahma run` again, then start the app in the background with `--smoke-test --smoke-hold 14`. After 3 s, send `kill -INT` to the CLI. The app's line must say `engine=embedded`.

- [ ] **Step 1: Add `StubRunner` to TestSupport.** It is `final class StubRunner: TurnRunning, @unchecked Sendable` with `enum Mode { case succeed, hangUntilCancelled }`, `init(mode:childrenNeverExit: Bool = false)` and a locked `requestCount`. `succeed` yields `.initialized(sessionId:model:)` and then `.result(TurnResult(isError: false, subtype: "success", text: "ok", costUSD: 0, apiErrorStatus: nil, sessionId: …))`. `hangUntilCancelled` yields nothing until the stream terminates. When `childrenNeverExit` is set, `waitForChildren()` awaits a detached 60 s sleep.
- [ ] **Step 2: Write failing tests.** `ToolLocatorTests` (`@Suite struct ToolLocatorTests`):
```swift
@Test func mcpHelperPrefersBundleHelpers() { /* both /A/Brahma.app/Contents/Helpers/brahma and …/MacOS/brahma exist → Helpers path */ }
@Test func devBuildUsesSiblingBinary() { /* bundle /p/.build/debug, executable /p/.build/debug/BrahmaApp, /p/.build/debug/brahma exists → it; none → nil */ }
@Test func claudeOverrideWins() { /* BRAHMA_CLAUDE=/x/fake executable → "/x/fake"; not executable → nil even if /usr/local/bin/claude exists */ }
@Test func claudeFoundOnSearchPath() { /* "/usr/bin:/opt/homebrew/bin", only /opt/homebrew/bin/claude → that path */ }
@Test func loginPathParsedBetweenMarkers() { /* "Welcome!\n__BRAHMA_PATH__/opt/homebrew/bin:/usr/bin__END__\n" → "/opt/homebrew/bin:/usr/bin"; "no markers" → nil */ }
@Test func mergedPathPutsLoginFirstAndDedups() { /* login "/opt/homebrew/bin:/usr/bin", current "/usr/bin:/bin:" → "/opt/homebrew/bin:/usr/bin:/bin"; login nil → "/usr/bin:/bin" */ }
@Test func loginShellPathTimesOut() { /* shell = temp script `sleep 10` → nil, elapsed < 3 s with timeout .seconds(1) */ }
@Test func realZshReturnsPath() { #expect(ToolLocator.loginShellPath(shell: "/bin/zsh")?.contains("/usr/bin") == true) }
```
  `EngineHostTests` (`@MainActor @Suite struct EngineHostTests`, `tickInterval: .milliseconds(10)`, tools `.success(EngineTools(claudePath: "claude", mcpExecutable: "/tmp/brahma"))`):
```swift
@Test func firstHostEmbedsSecondIsExternal() async throws { /* h1.start → .embedded; h2 (same paths).start → .external; stop both */ }
@Test func externalTakesOverWhenLockFrees() async throws { /* h1 embedded, h2 external; await h1.stop(); await h2.retryTakeover() → h2 .embedded */ }
@Test func stopInterruptsTurnAndReturnsAgentReady() async throws {
  /* hangUntilCancelled; owner DMs ceo; h.start; eventually { ceo.state == .running }; await h.stop()
     → status .stopped; ceo .ready; lastTurn(ceo).outcome == .interrupted; pendingInbox(ceo).count == 1 */ }
@Test func relaunchResumesInterruptedAgent() async throws {
  /* continue from the above state with a new host + StubRunner(.succeed) → eventually { ceo.state == .sleeping && lastTurn.outcome == .succeeded }; pendingInbox empty */ }
@Test func stopIsBoundedWhenChildrenNeverExit() async throws {
  /* hangUntilCancelled + childrenNeverExit; ceo running; measure await h.stop(timeout: .milliseconds(300)) < 2 s; status .stopped */ }
@Test func stopReleasesLockForCLI() async throws { /* after stop, OrchestratorLock.acquire(paths:) succeeds */ }
@Test func missingToolsFailWithoutTakingLock() async throws {
  /* start(tools: .failure(.claudeNotFound)) → .failed("Can't find the claude CLI. Install Claude Code, or set BRAHMA_CLAUDE to its path, then relaunch Brahma.");
     OrchestratorLock.acquire(paths:) succeeds; .helperMissing(path: "/x/brahma") → message contains "/x/brahma" */ }
@Test func stopNeverTouchesCompanyStatus() async throws { /* running company; start, stop → company.status == .running */ }
```
  `AppModelEngineTests` (`@MainActor @Suite struct AppModelEngineTests`):
```swift
@Test func tickRetriesTakeover() async throws { /* h1 embedded; model.engine = h2 (.external); await h1.stop(); 10 × model.tick() → h2.status == .embedded */ }
```
- [ ] **Step 3:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ToolLocatorTests|EngineHostTests|AppModelEngineTests"`. Expected: FAIL.
- [ ] **Step 4:** Implement `ToolLocator`, `EngineHost`, the `AppModel` cadence, AppDelegate wiring, the banner, the harness engine label and `--smoke-hold`, `fake-claude.sh`, and the script additions.
- [ ] **Step 5:** Rerun the filter, then full `swift test` (same prefix). Expected: PASS.
- [ ] **Step 6:** Run `scripts/smoke-app.sh`. Expected: cases A, B and C pass (lines `SMOKE OK … engine=embedded …`, `SMOKE OK … engine=external …`, `SMOKE OK … engine=embedded …`), then `SMOKE PASSED`.
- [ ] **Step 7: UI smoke.** From this task on, `ui-snapshot.sh` passes `--smoke-hold 4` so the fake turns can complete before the render. Run `scripts/ui-snapshot.sh task4-embedded mission`. Then, with `brahma run` running on a seeded temp home, capture `task4-external` the same way (the script uses the caller's `BRAHMA_HOME` when it is set). Read both. Expected: no banner, and the usage line `5h 38% · 7d 12% · resets HH:mm` after fake turns; the external banner text shown exactly.
- [ ] **Step 8:** Commit `feat(app): embedded engine with lock policy, login PATH, quit pauses and relaunch resumes` with the trailer lines.

---

### Task 5: Chat — channels and DMs with live updates and a composer

**Files:**
- Create: `Sources/BrahmaAppModel/Chat/ChatModel.swift`, `Chat/MentionCompleter.swift`, `Presentation/MessageText.swift`; `Sources/BrahmaApp/Views/ChatView.swift`, `Composer.swift`, `NewDMPicker.swift`
- Modify: `AppModel.swift` (chat lifecycle), `DetailView.swift` (chat case), `Sidebar.swift` ("+" on Direct messages)
- Test: `ChatModelTests.swift`, `MessageTextTests.swift`

**Interfaces:**
- Consumes: `MessageRouter.post/sendDM`, `Store.messages(channelId:limit:before:)`, `Store.channel(companyId:name:)`, `Store.markRead`, `ChannelTitle`, `SidebarItem`.
- Produces:
  - `enum ChatTarget: Hashable, Sendable { case channel(id: String), dm(handle: String) }`
  - `struct ChatMessage: Equatable, Identifiable, Sendable { var message: Message; var senderHandle: String /* "owner" or agent handle */; var isOwner: Bool; var id: String }`
  - `@MainActor @Observable final class ChatModel`:
    - `static let pageSize = 200`; `init(store: Store, companyId: String, target: ChatTarget)`; `let target: ChatTarget`
    - `private(set) var channel: Channel?; messages: [ChatMessage]; hasEarlier: Bool; title: String; readOnlyReason: String?; handles: [String] /* non-killed, sorted */; sendError: String?`; `var draft: String`
    - `func refresh() async` resolves the channel (`.dm(h)` resolves `"dm:" + ["owner", h].sorted().joined(":")`) and refetches the newest `max(pageSize, messages.count)` messages.
    - Loads are serialized: `refresh`, `loadEarlier` and `ensureLoaded` bump a `generation` counter when they start and drop their result if the counter changed before they apply it. `ensureLoaded` also sets `isPinned` while it runs, and `refresh` skips while it is set, so a stale tick refresh cannot overwrite what `open(hit)` loaded.
    - `func loadEarlier() async` prepends a page loaded `before: messages.first.createdAt`. `hasEarlier` = page was full.
    - `func ensureLoaded(messageId: String) async` pages earlier until the message is present or there are no earlier pages.
    - `@discardableResult func send() async -> Bool`
    - `func markRead() async` marks up to the newest loaded message.
    - `var mentionSuggestions: [String] { get }`; `func acceptMention(_ handle: String)`
  - `enum MentionCompleter { static func activePrefix(in text: String) -> String?; static func suggestions(for text: String, handles: [String], limit: Int = 8) -> [String]; static func complete(_ text: String, with handle: String) -> String }`. The active token is a trailing `@[A-Za-z0-9_-]*` that follows the start of the text or whitespace. `complete` replaces it with `"@<handle> "`.
  - `enum MessageText { static func attributed(_ text: String, handles: Set<String>) -> AttributedString }` builds plain `AttributedString(text)` (no Markdown). It sets `inlinePresentationIntent = .stronglyEmphasized` on `@h` tokens (same pattern as `MessageRouter.mentions`: `(?<![A-Za-z0-9_])@([A-Za-z0-9_-]+)`) whose lowercased handle is in `handles` or is `owner`.
  - `AppModel.chat: ChatModel?` (private set). `select(.channel/.dm)` creates a `ChatModel` and calls `Task { await chat.refresh() }`, and any other selection sets it to nil. In `tick`, if `events` contain `.message` for the selected company, it runs `await chat?.refresh()`.

Rules (exact copy):
- `send` trims whitespace and newlines; an empty draft returns false without writing. Posting is `.channel` → `router.post(companyId: companyId, channel: channel.name, from: .owner, text: trimmed)` and `.dm(h)` → `router.sendDM(companyId: companyId, from: .owner, to: h, text: trimmed)`. On success it clears `draft` and `sendError`, then refreshes and marks read. On failure it keeps the draft and sets `sendError`: `RouterError.unknownChannel(n)` → `"#<n> no longer exists."`, `.unknownAgent(h)` → `"No agent @<h> in this company."`, anything else → `"Couldn't send: <error>"`. When `readOnlyReason != nil`, `send` returns false.
- `readOnlyReason`:
  - a DM channel without an `owner` component → `"Agents' private conversation — read only."`
  - `.dm(h)` with h killed → `"@<h> was killed — history is read only."`
  - `.dm(h)` with h unknown → `"No agent @<h> in this company."`
  - `.channel(id)` not found → `"This conversation no longer exists."`
- Composer placeholder: `"Message #general"` or `"Message @cto"`.

View notes:
- `ChatView` uses `ScrollViewReader` and a `LazyVStack` of rows. Each row has an initial circle, the sender in bold (`"You"` for the owner, else `@handle`), the role in secondary text, `TimeText.hm`, and `Text(MessageText.attributed(...)).textSelection(.enabled)`.
- "Load earlier messages" appears at the top when `hasEarlier`.
- The view scrolls to the last message on appear and when the last id changes. It calls `markRead()` on appear and on last-id change while `controlActiveState == .key`.
- Composer: `TextField(axis: .vertical, lineLimit 1...6)`. Use `onKeyPress(.return)`: plain Return sends and returns `.handled`; Shift-Return appends `"\n"` to `draft` itself and returns `.handled`. The suggestion list sits above the field; `onKeyPress(.tab)` accepts the first suggestion and returns `.handled` when there is one, else `.ignored`. Check Return, Shift-Return and Tab by running the app (Step 5), because the snapshot cannot show key handling. `readOnlyReason` replaces the composer with secondary text, and `sendError` shows in red under it.
- `NewDMPicker` is a popover listing non-killed agents (`@handle — role`) that selects `.dm(handle:)`.
- DetailView, for chat: `VSplitView { ChatView; ActivityFeed placeholder (Task 7 fills it) }`.

- [ ] **Step 1: Write failing tests.** `MessageTextTests` (`@Suite struct MessageTextTests`):
```swift
@Test func messageTextIsVerbatim() {
  let input = "[click](http://evil.example) **bold** @ceo"
  let a = MessageText.attributed(input, handles: ["ceo"])
  #expect(String(a.characters) == input)
  #expect(a.runs.allSatisfy { $0.link == nil })
  /* run covering "@ceo" has inlinePresentationIntent == .stronglyEmphasized; run covering "**bold**" has none */
}
@Test func unknownMentionNotHighlighted() { /* "@ghost hi" with ["ceo"] → no emphasized run; "@owner" → emphasized */ }
@Test func mentionCompletion() {
  #expect(MentionCompleter.suggestions(for: "hi @c", handles: ["ceo","cto","eng"]) == ["ceo","cto"])
  #expect(MentionCompleter.suggestions(for: "hi @", handles: ["eng","ceo"]) == ["ceo","eng"])
  #expect(MentionCompleter.suggestions(for: "mail a@c", handles: ["ceo"]).isEmpty)
  #expect(MentionCompleter.suggestions(for: "hi @ceo done", handles: ["ceo"]).isEmpty)
  #expect(MentionCompleter.complete("hi @c", with: "cto") == "hi @cto ")
}
```
  `ChatModelTests` (`@MainActor @Suite struct ChatModelTests`):
```swift
@Test func loadsChannelOldestFirstWithHandles() async throws { /* ceo, owner, cto post → senderHandle ["ceo","owner","cto"], isOwner [false,true,false], title "#general" */ }
@Test func sendPostsAsOwnerAndClearsDraft() async throws { /* draft "  @ceo hi  " → true; last message senderId "owner", text "@ceo hi"; ceo pendingInbox 1; draft "" */ }
@Test func blankDraftDoesNothing() async throws { /* " \n" → false; message count unchanged */ }
@Test func dmWithoutChannelCreatesItOnFirstSend() async throws { /* .dm("cto"): channel nil, title "@cto"; send "hello" → channel.name "dm:cto:owner", 1 message */ }
@Test func agentConversationIsReadOnly() async throws { /* ceo DMs cto; .channel(id: dm) → readOnlyReason "Agents' private conversation — read only."; send false */ }
@Test func killedAgentDMIsReadOnly() async throws { /* kill cto; .dm("cto") → "@cto was killed — history is read only." */ }
@Test func missingChannelIsReadOnly() async throws { /* .channel(id: "missing") → "This conversation no longer exists." */ }
@Test func loadEarlierPages() async throws { /* 250 messages, increasing now: → count 200, hasEarlier; loadEarlier → 250, !hasEarlier, first is oldest */ }
@Test func markReadClearsUnread() async throws { /* ceo posts 2; markRead → store.unreadCounts(acme)[general] == nil */ }
@Test func tickRefreshesOpenChatOnMessageEvent() async throws { /* model.select(.channel(general)); await chat.refresh(); second Store posts as ceo; model.tick() → chat.messages.count + 1 */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ChatModelTests|MessageTextTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the model types, then the views.
- [ ] **Step 4:** Rerun, then full `swift test`. Expected: PASS.
- [ ] **Step 5: UI smoke.** Run `scripts/make-app.sh debug && scripts/ui-snapshot.sh task5-general channel:general && scripts/ui-snapshot.sh task5-dm dm:cto` and read both. Expected in `task5-general`: the owner's "@ceo please draft…" with "@ceo" and "@cto" bold and the composer "Message #general". Expected in `task5-dm`: "What stack do you suggest?" from "You" and the composer "Message @cto". Then launch the app with a seeded temp home and confirm by hand that Return sends, Shift-Return adds a line, and typing `@c` then Tab completes to `@ceo `.
- [ ] **Step 6:** Commit `feat(app): channel and DM chat with live updates, mentions and read marks` with the trailer lines.

---

### Task 6: Search across a company's messages

**Files:**
- Create: `Sources/BrahmaAppModel/Search/SearchModel.swift`, `Sources/BrahmaApp/Views/SearchResultsView.swift`
- Modify: `AppModel.swift` (search, open hit, `.search` in `apply`), `MainWindow.swift` (`.searchable`), `DetailView.swift`, `ChatView.swift` (highlight)
- Test: `SearchModelTests.swift`

**Interfaces:**
- Consumes: `Store.searchMessages(companyId:query:limit:)`, `ChannelTitle`, `SidebarItem`, `ChatModel.ensureLoaded(messageId:)`.
- Produces:
  - `struct SearchHit: Equatable, Identifiable, Sendable { var message: Message; var channelTitle: String; var senderHandle: String; var target: SidebarItem; var id: String }`. `target` is `.channel(id:)` for a channel or agent DM and `.dm(handle:)` for an owner DM.
  - `@MainActor @Observable final class SearchModel { init(store: Store); var query: String; private(set) var hits: [SearchHit]; private(set) var isSearching: Bool; func run(companyId: String) async throws }`. It trims the query, and a blank query sets `hits = []` without querying. Otherwise it searches with limit 50, off the main actor. `run` is `throws`; `AppModel.runSearch() async` wraps it (company = selected) and sets `errorMessage = "Search failed: <error>"` on a throw. The view and `apply(.search)` call `runSearch`, never `run` directly.
  - `AppModel.search: SearchModel`; `AppModel.highlightedMessageId: String?`; `func open(_ hit: SearchHit) async` selects `hit.target`, awaits `chat.refresh()` and `chat.ensureLoaded(messageId:)`, sets `highlightedMessageId`, and clears `search.query`. `selectCompany` clears the query. `apply(.search(q))` sets `search.query = q` and awaits `runSearch()`.
  - UI: `.searchable(text: $model.search.query, placement: .toolbar, prompt: "Search messages")` and `.task(id: query) { 250 ms debounce; await model.runSearch() }`. While the query is non-blank, the top area shows `SearchResultsView`. Each row shows `channelTitle · <sender> · HH:mm`, where sender is `You` for the owner and `@handle` otherwise, and the text verbatim on two lines. The empty state is `Text(verbatim: "No messages match “\(q)”.")`. Clicking a row opens the hit. ChatView scrolls to `highlightedMessageId`, tints the row with accent at 15% for 2 s, and then clears it.

- [ ] **Step 1: Write failing tests** `SearchModelTests` (`@MainActor @Suite struct SearchModelTests`):
```swift
@Test func findsAcrossChannelsAndDMs() async throws { /* ceo posts "stripe webhooks" in #general; ceo DMs owner "stripe keys" → 2 hits;
   titles {"#general","@ceo"}; targets {.channel(id: general.id), .dm(handle: "ceo")}; senderHandle "ceo" */ }
@Test func blankQueryClears() async throws { /* query "   " → hits == [] */ }
@Test func ftsSyntaxIsSafe() async throws { /* query "\"stripe AND (" → no error; errorMessage nil */ }
@Test func scopedToCompany() async throws { /* Globex message "stripe" absent from Acme results */ }
@Test func openHitSelectsConversationAndHighlights() async throws { /* open(hit) → sidebarSelection == hit.target, highlightedMessageId == id, search.query == "" */ }
@Test func openOldHitLoadsEarlierPages() async throws { /* 450 messages, hit = 10th oldest → after open, chat.messages contains it */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SearchModelTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rerun, then full `swift test`. Expected: PASS.
- [ ] **Step 5: UI smoke.** Run `scripts/make-app.sh debug && scripts/ui-snapshot.sh task6-search "search:stack"` and read it. Expected: two result rows, "#general · You · HH:mm" ("…ask @cto for a stack") and "@cto · You · HH:mm" ("What stack do you suggest?"), and the toolbar search field containing "stack".
- [ ] **Step 6:** Commit `feat(app): company-wide message search with jump-to-message` with the trailer lines.

---

### Task 7: Mission control skeleton and live activity feed

**Files:**
- Create: `Sources/BrahmaAppModel/Presentation/ActivityText.swift`; `Sources/BrahmaApp/Views/MissionControlView.swift`, `ActivityFeedView.swift`
- Modify: `AppModel.swift` (filter, handles), `DetailView.swift` (mission control, activity, and the bottom feed under chat and agents)
- Test: `ActivityTextTests.swift`

**Interfaces:**
- Consumes: `AppModel.activity`, `snapshot.agents`, `BlockerText`, `TimeText`.
- Produces:
  - `enum ActivityFilter: String, CaseIterable, Sendable { case all, messages, turns, states, problems; var title: String /* "All","Messages","Turns","State changes","Problems" */; func includes(_ k: ActivityKind) -> Bool }`. Mapping: messages {`.message`}, turns {`.turnStarted`, `.turnFinished`, `.toolUse`}, states {`.stateChanged`}, problems {`.usage`, `.error`}.
  - `enum ActivityText { static func line(_ e: ActivityEvent, handles: [String: String]) -> String }`. For `.stateChanged` with an `agentId` it returns `"@<handle> " + text.replacingOccurrences(of: " -> ", with: " → ")`. For other kinds it returns `text` unchanged.
  - `enum AgentBadge { static func label(_ a: Agent) -> String }` returns `"killed"` if killed, `"running (pausing)"` if running and paused, `"paused"` if paused, and otherwise `state.rawValue`.
  - `AppModel.activityFilter: ActivityFilter = .all`; `var filteredActivity: [ActivityEvent] { get }`; `var handles: [String: String] { get } /* selected company id → handle, plus "owner" → "owner" */`

Layout (spec §6.2, layout B):
- `MissionControlView` = `VSplitView { HSplitView { PreviewPlaceholder; AgentMapPlaceholder }.frame(minHeight: 240); ActivityFeedView(compact: true).frame(minHeight: 140) }`.
- In DetailView, chat and agents become `VSplitView { <top>; ActivityFeedView(compact: true) }`, and `.activity` is `ActivityFeedView(compact: false)` at full height.
- `PreviewPlaceholder`: title "Product preview". Body: `"No preview yet. When the company has a running product or design artifacts, they appear here."` Dashed rounded border, with a `Placeholder` capsule tag.
- `AgentMapPlaceholder`: title "Agent map" with a `Map view coming soon` capsule. Body is a `LazyVGrid(columns: [.adaptive(minimum: 150)])` of agent chips: `@handle` bold, role secondary, a colored dot plus `AgentBadge.label`, and a one-line `BlockerText`. Dot colors: running `.green`, ready `.blue`, blocked `.orange`, sleeping and paused `.gray`, killed `.red` (killed chips at 50% opacity). Tapping a chip selects `.agents` and sets `selectedAgentId`. With no agents the body says `"No agents yet."` and shows a "Hire Agent" button (`presentedSheet = .hire`).
- `ActivityFeedView`: header "Activity", a filter `Picker` (menu style; segmented when not compact), and the event count. Rows show `TimeText.hms` (monospaced digits, secondary), a kind symbol (message `bubble.left`, turnStarted `play.circle`, turnFinished `flag.checkered`, toolUse `wrench.and.screwdriver`, stateChanged `arrow.triangle.swap`, usage `gauge.with.dots.needle.67percent`, error `exclamationmark.triangle`), and `Text(verbatim: ActivityText.line(...))` with `lineLimit(2)`. The feed is newest at the bottom and auto-scrolls on a new last id. Empty state: `"No activity yet."`

- [ ] **Step 1: Write failing tests** `ActivityTextTests` (`@MainActor @Suite struct ActivityTextTests`):
```swift
@Test func stateChangeLineNamesAgent() { /* agentId ceo, "sleeping -> ready" → "@ceo sleeping → ready" */ }
@Test func otherKindsVerbatim() { /* .message "#general @ceo: [x](y)" → unchanged */ }
@Test(arguments: [(ActivityFilter.messages, ActivityKind.message, true), (.messages, .turnStarted, false), (.turns, .toolUse, true),
                  (.states, .stateChanged, true), (.problems, .usage, true), (.problems, .message, false), (.all, .error, true)])
func filterKinds(f: ActivityFilter, k: ActivityKind, ok: Bool) { #expect(f.includes(k) == ok) }
@Test func agentBadgeLabels() { /* paused+sleeping "paused"; running+paused "running (pausing)"; blocked "blocked"; killed+paused "killed" */ }
@Test func filteredActivityAppliesFilter() async throws { /* model with message + stateChanged events; filter .states → only stateChanged */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ActivityTextTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rerun, then full `swift test`. Expected: PASS.
- [ ] **Step 5: UI smoke.** Run `scripts/make-app.sh debug && scripts/ui-snapshot.sh task7-mission mission && scripts/ui-snapshot.sh task7-activity activity` and read both. Expected: the preview placeholder on the left and four agent chips on the right (eng1 "paused"), with the feed at the bottom showing lines like "@ceo sleeping → ready" and "#general @owner: …". The full-height activity view shows the segmented filter.
- [ ] **Step 6:** Commit `feat(app): mission control skeleton (layout B) with live activity feed` with the trailer lines.

---

### Task 8: Agent roster, detail and hire

**Files:**
- Create: `Sources/BrahmaAppModel/Forms/HireForm.swift`, `Agents/AgentDetail.swift`; `Sources/BrahmaApp/Views/AgentsView.swift`, `HireSheet.swift`
- Modify: `DetailView.swift` (agents case), `MainWindow.swift` (hire sheet)
- Test: `AgentActionsTests.swift`

**Interfaces:**
- Consumes: `Store.hire`, `Store.setPaused`, `Store.transition(agentId:to:)`, `Store.lastTurn` (via `snapshot.lastTurns`), `BlockerText`, `AgentBadge`, `TimeText`.
- Produces:
  - `enum AgentModelChoice: String, CaseIterable, Sendable { case opus, sonnet, haiku; var title: String /* "Opus","Sonnet","Haiku" */ }`
  - `struct HireForm: Equatable, Sendable { var handle = ""; var role = "engineer"; var model: AgentModelChoice = .sonnet; static let roleSuggestions = ["ceo","cto","cpo","architect","manager","engineer","designer","qa"]; var normalizedHandle: String /* trimmed, leading "@" dropped, lowercased */; func validate(existingHandles: Set<String>) -> String? }`
  - `struct AgentDetail: Equatable, Sendable { var agent: Agent; var stateLabel: String; var blockerText: String; var lastTurnLine: String; var lastTurnSummary: String?; var canPause: Bool; var canWake: Bool; var canKill: Bool }`
  - `extension AppModel`:
    - `func hire(_ form: HireForm) async throws -> Agent` validates (`FormError.invalid`), maps `StoreError.duplicateName` to `"@<h> already exists"` and `.invalidName` to the format message, forces a snapshot, and sets `selectedAgentId`.
    - `func setAgentPaused(_ agentId: String, _ paused: Bool) async`
    - `func kill(agentId: String) async`. A `LifecycleError` sets `errorMessage = "@<h> is already killed"`.
    - `func openDM(handle: String)` is `select(.dm(handle:))`.
    - `func detail(agentId: String, timeZone: TimeZone = .current) -> AgentDetail?`

Exact rules:
- Validation messages:
  - empty handle → `"Handle is required"`
  - `owner` → `"@owner is reserved"`
  - not matching `^[a-z0-9][a-z0-9_-]{0,31}$` → `"Handles use a–z, 0–9, - and _ (up to 32, starting with a letter or digit)"`
  - duplicate → `"@<h> already exists"`
  - blank role → `"Role is required"`
- `lastTurnLine`: no turn → `"No turns yet"`; in progress → `"in progress since HH:mm"`; otherwise `"<outcome.rawValue> at HH:mm"` using `endedAt ?? startedAt`.
- `canPause = state != .killed && !paused`
- `canWake = state != .killed && (paused || state == .sleeping || state == .blocked)`
- `canKill = state != .killed`
- Kill dialog copy: title `"Kill @<h>?"`, message `"@<h> stops for good. Its history is kept. This can't be undone."`, destructive button `"Kill @<h>"`.

View notes:
- `AgentsView` is a `Table` of the selected company's agents with columns Agent (`@handle`), Role, Model, State (dot + `AgentBadge.label`), Note (`BlockerText`) and Last turn. Its selection binds `selectedAgentId`.
- Its `.inspector` (width 300) is shown while an agent is selected. It contains a header with `@handle`, role and model; the state; the blocker; the last turn line with the summary verbatim (`lineLimit(6)`); and the buttons "Message" (`openDM`), "Pause", "Wake" and "Kill…", each enabled per its flag. A killed agent shows `"Killed — history kept."`.
- A toolbar button "Hire Agent" (`person.badge.plus`) sets `presentedSheet = .hire`.
- `HireSheet` is a Form with a Handle `TextField` (an "@" prefix label), a Role `TextField` plus a `Menu("Suggestions")` of `roleSuggestions`, a segmented Model picker, the validation message in red, and Cancel/Hire buttons (Hire is the default and is disabled while invalid).

- [ ] **Step 1: Write failing tests** `AgentActionsTests` (`@MainActor @Suite struct AgentActionsTests`):
```swift
@Test(arguments: [("", "engineer", "Handle is required"), ("owner", "engineer", "@owner is reserved"),
                  ("-bad", "engineer", "Handles use a–z, 0–9, - and _ (up to 32, starting with a letter or digit)"),
                  ("ceo", "engineer", "@ceo already exists"), ("qa1", "  ", "Role is required")])
func hireValidation(handle: String, role: String, message: String) { /* existingHandles ["ceo"] → validate == message */ }
@Test func hireCreatesSleepingAgentAndSelectsIt() async throws { /* handle "@QA1", role "qa", .haiku → name "qa1", model "haiku", .sleeping; selectedAgentId == id; in snapshot.agents */ }
@Test func hireStoreDuplicateMapsMessage() async throws { /* second Store hires "qa2" after validate; model.hire("qa2") → FormError.invalid("@qa2 already exists") */ }
@Test func pauseWakeKill() async throws { /* ceo ready: pause → sleeping+paused, canWake && !canPause; wake → ready; kill → killed, all flags false, stateLabel "killed" */ }
@Test func pauseRunningAgentShowsPausing() async throws { /* ceo running → setAgentPaused(true) → stateLabel "running (pausing)" */ }
@Test func killTwiceSetsError() async throws { /* kill; kill → errorMessage == "@ceo is already killed" */ }
@Test func detailLastTurnLine() async throws { /* no turn → "No turns yet"; finished succeeded at 14:02 (gmt) → "succeeded at 14:02" */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AgentActionsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rerun, then full `swift test`. Expected: PASS.
- [ ] **Step 5: UI smoke.** Run `scripts/make-app.sh debug && scripts/ui-snapshot.sh task8-agents agent:ceo && scripts/ui-snapshot.sh task8-hire hire` and read both. Expected in `task8-agents`: a table of 4 agents, eng1 "paused", and an inspector for @ceo with Message/Pause/Wake/Kill buttons. Expected in `task8-hire`: the hire sheet with Hire disabled.
- [ ] **Step 6:** Commit `feat(app): agent roster, detail inspector, pause/wake/kill and hire sheet` with the trailer lines.

---

### Task 9: Menu bar extra, window-close lifecycle, docs and final verification

**Files:**
- Create: `Sources/BrahmaAppModel/MenuBar/MenuBarSummary.swift`, `Sources/BrahmaApp/Views/MenuBarContent.swift`
- Modify: `BrahmaApp.swift` (MenuBarExtra scene), `AppDelegate.swift` (activation policy, reopen), `Harness.swift` (`--smoke-close-window`), `scripts/smoke-app.sh` (lifecycle case), `README.md`
- Test: `MenuBarSummaryTests.swift`

**Interfaces:**
- Consumes: `CompanySummary`, `EngineStatus`, `AppModel.setCompanyRunning`, `AppDelegate.openMainWindow`.
- Produces:
  - `struct MenuCompanyRow: Equatable, Identifiable, Sendable { var id: String; var name: String; var statusText: String; var toggleTitle: String; var isRunning: Bool }`
  - `struct MenuBarSummary: Equatable, Sendable { var totals: String; var pending: String; var engine: String; var rows: [MenuCompanyRow]; var anyRunningAgents: Bool; static func make(companies: [CompanySummary], engine: EngineStatus?) -> MenuBarSummary }`
  - `extension AppModel { var menuBar: MenuBarSummary { get } }`, a computed property in `MenuBarSummary.swift` built from `snapshot.companies` and `engine?.status`.

Exact copy:
- `totals` is `"<R> running · <RD> ready across <n> companies"` (`"1 company"` when n == 1), or `"No companies yet"` when n == 0.
- `pending` is `"<W> waiting on you · <U> unread"`, summing `waitingOnOwner` and `unread`.
- `engine`: embedded `"Engine: running in Brahma"`, external `"Engine: running in terminal (brahma run)"`, starting `"Engine: starting…"`, stopping `"Engine: stopping…"`, stopped `"Engine: stopped"`, failed(m) `"Engine: stopped — <m>"`, nil `"Engine: not started"`.
- Row `statusText` is `"Running · <r> running · <rd> ready"` or `"Paused"`. `toggleTitle` is `"Pause <name>"` or `"Resume <name>"`.

Scene and lifecycle:
- `MenuBarExtra { MenuBarContent() } label: { Image(systemName: anyRunningAgents ? "circle.hexagongrid.fill" : "circle.hexagongrid") }` with `.menuBarExtraStyle(.menu)`.
- The menu contains, in order:
  - disabled lines totals / pending / engine
  - Divider
  - one Button per row titled `toggleTitle` (calls `setCompanyRunning(!isRunning, companyId:)`)
  - Divider
  - "Open Brahma" (`⌘O`)
  - "Quit Brahma" (`⌘Q`, calls `NSApp.terminate(nil)`, which takes the Task 4 quit path)
- The AppDelegate observes `NSWindow.willCloseNotification`. When the closing window's identifier starts with `main`, it calls `NSApp.setActivationPolicy(.accessory)`: the Dock icon goes away, and the app and engine keep running in the menu bar.
- `openMainWindowFromMenu()` calls `NSApp.setActivationPolicy(.regular)`, then `openMainWindow?()`, then `NSApp.activate()`. `applicationShouldHandleReopen` calls it too.
- `--smoke-close-window`, after readiness, does the following: close the main window (`performClose`), wait 1 s, and require 0 visible main windows, `activationPolicy() == .accessory` and an engine status still `embedded`. Then call `openMainWindowFromMenu()`, wait 1 s, and require 1 window and `.regular`. If all of that holds, append ` lifecycle=ok` to the smoke line; otherwise print `SMOKE FAIL lifecycle <detail>` and exit 1.
- README gets a "Mac app" section:
  - build with `scripts/make-app.sh`, then open `.build/Brahma.app` or copy it to `/Applications`
  - it uses the same data as the CLI
  - the engine runs in the app unless `brahma run` holds the lock (banner, automatic takeover)
  - closing the window keeps it running in the menu bar; Quit stops agents (turns interrupted, agents ready) and relaunch resumes
  - `BRAHMA_CLAUDE` overrides the `claude` path, and the PATH is read from the login shell
  - update the Status line to "Plan 2: Mac app shell"

- [ ] **Step 1: Write failing tests** `MenuBarSummaryTests` (`@MainActor @Suite struct MenuBarSummaryTests`):
```swift
@Test func totalsAcrossCompanies() { /* A running (2 running, 1 ready), B paused (0, 3) → "2 running · 4 ready across 2 companies"; single → "… across 1 company" */ }
@Test func pendingSumsWaitingAndUnread() { /* A waiting 1 unread 2, B waiting 0 unread 3 → "1 waiting on you · 5 unread" */ }
@Test func rowsToggleTitles() { /* A → "Pause Acme", "Running · 2 running · 1 ready"; B → "Resume Globex", "Paused" */ }
@Test(arguments: [(EngineStatus?.some(.embedded), "Engine: running in Brahma"), (.some(.external), "Engine: running in terminal (brahma run)"),
                  (.some(.stopping), "Engine: stopping…"), (.some(.failed("x")), "Engine: stopped — x"), (nil, "Engine: not started")])
func engineLines(status: EngineStatus?, line: String) { #expect(MenuBarSummary.make(companies: [], engine: status).engine == line) }
@Test func noCompanies() { #expect(MenuBarSummary.make(companies: [], engine: nil).totals == "No companies yet") }
@Test func menuToggleDoesNotTouchOtherCompanies() async throws { /* setCompanyRunning(false, globexRunning) → Acme status unchanged */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MenuBarSummaryTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the summary, menu content, lifecycle, harness flag, smoke case (D) `--smoke-test --smoke-close-window --smoke-hold 2` (expects `lifecycle=ok`), and README.
- [ ] **Step 4:** Run full `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Run `scripts/smoke-app.sh`. Expected: cases A–D print `SMOKE OK …` (D ending ` lifecycle=ok`) and then `SMOKE PASSED`.
- [ ] **Step 6: Final UI pass.** Run `scripts/make-app.sh release`, then `ui-snapshot.sh` for `final-mission mission`, `final-chat channel:general`, `final-agents agent:cto`, `final-activity activity` and `final-search "search:plan"`. Read all five and confirm they match spec §6.2: rail at far left with dots and badges, slim sidebar, top bar with name, counts, mode, run/pause and usage, preview and map on top, feed below.
- [ ] **Step 7: Manual menu bar check.** Launch `.build/Brahma.app/Contents/MacOS/Brahma` with a seeded temp home and `BRAHMA_CLAUDE=scripts/fake-claude.sh`. Click the menu bar icon and confirm that the totals, pending and engine lines appear, that "Pause Acme" flips the rail dot to gray within 2 s, and that "Quit Brahma" exits within 15 s after which `brahma status` shows no agent `running`. Record the result in the task report.
- [ ] **Step 8:** Commit `feat(app): menu bar extra, close-to-menu-bar lifecycle, README` with the trailer lines.
