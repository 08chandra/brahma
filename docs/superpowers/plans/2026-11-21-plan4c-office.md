# Plan 4c — Office view (the agent map's easter egg) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second renderer for the agent map, hidden until the owner finds it: a 3/4 top-down office floor in SpriteKit where every agent has a desk in its team's pod, executives have offices, the owner has a board room, and agent state and traffic become animation (typing, walking to the review room, notes carried between desks, parcels stamped in the mail room). It runs on the same live `MapModel` and `MapController` as the org chart.

**Architecture:** Three additions, one per existing layer, with nothing new in `BrahmaCore`.
- **`BrahmaAppModel/Map`** gets the pure pieces: `MapMode.office`, the `OfficeUnlock` state machine, `OfficeLayout` (rooms, pods, desks, corridor routes from a `MapModel`), `OfficeActivity` and the item-phase facets of `MapAgent`, and a `collapsed` set that is empty in office mode.
- **`BrahmaMapKit/Office`** renders it: `OfficeTextures` (procedural art drawn with CoreGraphics into cached textures), `OfficeScene` (+ nodes and motion), a shared `MapCameraDriver` extracted from the org chart, `MapAccessible` for VoiceOver, and a `MapSceneFactory` that `OrgView` and `MapBench` use to pick a scene by mode.
- **`BrahmaApp`** shows the `ORG | OFFICE` segmented control once unlocked, the reveal chip, and honours `--map-skin`.

**Tech Stack:** Swift 6.2 toolchain (manifest stays `swift-tools-version: 6.0`, `.macOS(.v14)`), SwiftPM, Swift Testing, SwiftUI/Observation, SpriteKit (`SKRenderer` offscreen), Metal (offscreen only), CoreGraphics/CoreText (textures). No new packages, assets or targets.

**Spec:** `docs/superpowers/specs/2026-11-21-office-view-design.md` (cited as *spec §n*). It supersedes the Village skin in `docs/superpowers/specs/2026-10-21-brahma-design-v2.md` §4.12.3 and master roadmap §2.15; the owner decisions in spec §1 are binding. The 4b plan (`docs/superpowers/plans/2026-10-21-plan4b-maps.md`) is the reference for every type this plan extends.

**Builds on (all on `main`):** Plan 4b: `MapModel`, `MapInputs`, `MapAgent`, `VisualKind`, `MapThrottle`, `MapController` (+ Navigation, Replay, Vacancies), `OrgTree`, `OrgLayout`, `SyntheticCompany`, `MapOverlay`, `LaunchOptions`, `ThemeHex`; `BrahmaMapKit`: `OrgScene` (+ `OrgCards`, `OrgParticles`), `MapSKView`, `OrgView`, `MapPalette`, `LabelTextures`, `MapSnapshotter`, `MapBench`; `BrahmaApp`: `AgentMapPanel`, `MapHeader`, `MapWindow`, `Harness`, `AppDelegate.installMapController`; tests `OrgSceneTests`, `MapPerfTests`, `MapControllerTests`, `MapModelTests`, `MapQueueTests`, `MapOverlayTests`, `LaunchOptionsTests`, `ThemeHexTests`.

**Sequencing (spec §9):**
- Tasks 1–10 can start now against `main`, in parallel with Plans S and R (R keeps the `BrahmaCore` umbrella import; 4c adds no target and no migration). Plan P's Task 7 rewrites `MapController.swift`'s polling and its Task 2 edits `MapControllerTests.swift`; 4c therefore keeps its controller changes small and apart: three stored properties and the `collapsed` guard in `MapController.swift`, two lines in `inputs(for:)`, everything else in `MapController+Office.swift`, and every new controller test in `OfficeControllerTests.swift`. **If Plan P merges while Tasks 1–10 are in progress, rebase at the next task boundary.**
- Task 11 (the header toggle, unlock hooks and reveal chip) edits `MapHeader.swift` and `AgentMapPanel.swift`, which Plan P's Task 12a/12b also touch: **rebase onto `main` after Plan P has merged before starting Task 11.** If Plan P has not merged when Task 11 is reached, stop and report instead of editing those files.
- The perf rows (Task 9) do not depend on P's polling change: `MapBench` calls `pollSynthetic()` on a virtual clock.
- The office adds no visible element until unlocked, so Plan P's frozen screen inventory (`ScreenInventoryTests`) is unchanged by default.

**Decisions this plan pins (with reasons):**
- **Projection: 3/4 top-down, not isometric** (spec §5.1): text stays horizontal, hit tests stay rectangles, routes and camera need no projection.
- **Art: procedural textures drawn in code** (spec §7): original by construction, token-coloured, no asset pipeline. `THIRD_PARTY_NOTICES.md` is unchanged.
- **LOD by living-agent count** (spec §5.5), not by frame time, so snapshots and tests are reproducible.
- **Walks are driven by activity changes, notes by events** (spec §5.4): a DM is a note on a corridor route in the event's 0.9 s; a figure walks (0.8 s) only when its activity gains a destination. The queue constants are untouched.
- **No collapse in the office**: `MapController.collapsed` is `[]` while `mode == .office`, so `frame(now:)` resolves every event to its real agent.
- **Item phases come from the snapshot already in memory** (spec §6.2): `WorkItem.status`, `WorkItem.mergeState`, `WorkSnapshot.latestRuns`, `WorkSnapshot.inbox.count`. No Store query is added.
- **Camera easing is extracted, not duplicated**: `MapCameraDriver` (Task 6) replaces the camera code in `OrgParticles.swift`; `OrgSceneTests` must pass unchanged after the extraction.
- **Unlock has two routes feeding one state machine** (spec §4.1): typing `office` on a focused map, or five clicks on BOARD within 3 s. Persisted per owner under `brahma.map.office.unlocked`. The demo stays read-only.
- **Harness runs never see the unlock** (spec §4.3): when `LaunchOptions.isHarness`, `AppModel.mapDefaults` is a volatile suite `brahma.harness.<pid>` (cleared at launch), so snapshots, inventories and benches are machine-independent and `--map-skin=office` is the only way a harness run shows the office. A stored `office` mode without an unlock falls back to `.org`.
- **VoiceOver elements are office-only in 4c** (spec §5.6): `OrgScene` does not conform to `MapAccessible`, so Plan P's frozen inventory is untouched before any unlock. `OrgScene` does conform to `MapMotionReducible` (pulses off), which adds no element.
- **Execution order:** 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12. Tasks 3 and 4 depend only on Task 2 and Task 1 respectively and may run in parallel; Task 10 needs 5–8; Task 11 needs Plan P merged.

## Global Constraints

Copied from the 4b plan and still binding, plus 4c's own:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The manifest stays `swift-tools-version: 6.0` and `.macOS(.v14)`. Build the app only with `scripts/make-app.sh [debug|release]`.
- `BrahmaCore` is not modified by this plan. `BrahmaAppModel` adds no import beyond Foundation, Observation, BrahmaCore, BrahmaKeychain: no AppKit, SpriteKit or CoreGraphics. SpriteKit, Metal, AppKit and CoreGraphics appear only in `BrahmaMapKit` and `BrahmaApp`.
- Agent states stay exactly `ready, running, blocked, sleeping, killed`; paused non-killed renders like sleeping (`MapModel.displayState`).
- Agent-controlled text is never trusted: every string the office draws or speaks (VoiceOver) is a `MapAgent` / `MapModel` field that is already `MapText.clean` output. The office adds no string source and never re-reads raw `Agent` text. SwiftUI overlays use `Text(verbatim:)`.
- Colours only from `ThemeHex` via `MapPalette`; the office's new tokens are added to `ThemeHex` (Task 4). No ad-hoc colours.
- `MapThrottle`'s pinned numbers (durations, caps, aggregate thresholds) are unchanged. `VisualKind` gains exactly one case, `phaseChange`, with duration 0.2 s.
- Polls only while visible: `MapController.start/stop` and `AgentMapPanel`'s lifecycle are not changed.
- No third-party assets, fonts, images or packages. No new SwiftPM target, resource bundle or migration.
- Tests never touch the real Keychain (`makeHome()`/`seedAcme`, `UserDefaults(suiteName: UUID().uuidString)!`, `MemoryVault`; never `import Security`). `NoKeychainTests` scans `Tests/`.
- Tests use Swift Testing, one `@Suite struct <FileName>` per new file, `@MainActor` for scenes and controllers. GPU-dependent tests are `.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device")`. Perf assertions run only with `BRAHMA_PERF=1` and `-c release`.
- Snapshot PNGs go to `.superpowers/maps/` (`MapSnapshotter.writeIfRequested`) and `.superpowers/ui/`; both are gitignored and read locally with the Read tool.
- The frozen Plan P screen inventory may not change for an owner who has not unlocked the office.
- Every commit message ends with the trailers:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`
- Out of scope: Hive/3D; a re-lock control; a frame-time LOD governor; replaying item phases; a light theme; any engine, scheduling or prompt change.

**Pinned numbers** (each a `static let` on the owning type; spec §6.3):

| Constant | Value | Owner |
|---|---|---|
| Desk top / front face / chair | 36×24 / 6 / 12×8 pt | `OfficeLayout.desk`, `.chair` |
| Pod: columns / desk gap / aisle / padding / head row | 2 / 8 / 16 / 12 / 36 pt | `OfficeLayout.pod` |
| Corridor / wing gap / rooms strip | 32 / 48 / 140 pt | `OfficeLayout.corridor`, `.wingGap`, `.roomsStrip` |
| Rooms w×h: board / CEO / exec / director / review / break / mail | 200×120 / 160×120 / 120×100 / 120×100 / 260×120 / 180×120 / 160×120 | `OfficeLayout.boardRoom` … `.mailRoom` |
| Review-room chairs / board-door spots | 12 / 8 | `OfficeLayout.reviewSeats`, `.doorSpots` |
| Figure size / hidden below zoom | 10×16 pt / 0.3 | `OfficeTextures.figureSize`, `OfficeScene.figureZoom` |
| Walk / desk glide | 0.8 s / 0.4 s | `OfficeScene.walkDuration`, `.moveDuration` |
| Typing frames / glow pulse | 4 Hz / 1 Hz, alpha 0.6–1.0 | `OfficeScene.typingHz`, `.pulseHz` |
| Idle stroll interval | 20…40 s, seeded by FNV-1a of the agent id | `OfficeScene.strollRange` |
| LOD: full ≤ / static ≤ / desk-only above | 50 / 150 | `OfficeScene.fullLOD`, `.staticLOD` |
| Zoom range / text / items | 0.15…3 / 0.5 / 1.2 | `OfficeScene.zoomRange`, `.textZoom`, `.itemZoom` |
| Unlock word / per-key window / Board clicks / click window | `office` / 2 s / 5 / 3 s | `OfficeUnlock.word`, `.keyWindow`, `.boardClicks`, `.clickWindow` |
| Reveal chip / mode cross-fade | 3 s / 0.6 s | `MapOverlay.revealDuration`, `OrgView.modeFade` |
| Ask folders on the board table | ≤ 9, then `9+` | `OfficeScene.askFolders` |
| Wall-of-fame glyphs | 6 | `OfficeScene.fameLimit` |
| VoiceOver elements / rebuild rate | ≤ 300 / ≤ 1 Hz | `MapSKView.accessibilityLimit`, `.accessibilityInterval` |
| Phase-change event duration / priority | 0.2 s / same as `.stateChange` (4) | `MapThrottle` |
| Perf targets (p95 ≤ 16.7 ms) | 50 full at 50 msg/s + bursts; 50 full at 15 msg/s (particles); 150 static; 300 desk-only | `MapPerfTests` |
| Persistence keys | `brahma.map.office.unlocked`; `brahma.map.mode.<companyId>` (4b) | `MapController.officeUnlockedKey`, `.modeKey` |

## Review Focus

1. **Agent text at a desk or spoken by VoiceOver**: a 5 000-mark "Zalgo" handle, a 10 000-character role, a bidi-override item key. It renders as one capped, cleaned line and VoiceOver reads the same cleaned text, never the raw string. → Task 5 `OfficeSceneTests.deskTextIsClean`; Task 8 `MapAccessibilityTests.labelsAreCleanText`.
2. **A burst in the office**: 2 000 messages in one poll at 50 agents. Notes come from the bounded pool, aggregate mode switches notes to dots, structural events still play, and p95 stays in budget. → Task 7 `OfficeSceneTests.burstStaysBoundedInOffice`; Task 10 `MapPerfTests.officeSixtyFpsAt50Bursts`.
3. **The world changes mid-walk**: an agent is killed while walking to the review room, a note is in flight to an agent who just left, the mode is switched while a replay is playing or an agent is followed. Figures and notes retarget on the next frame, nothing crashes, and replay and follow survive the mode switch. → Task 7 `retargetWhenAgentKilledMidWalk`, `noteRetargetsWhenRecipientLeaves`; Task 10 `OfficeControllerTests.modeSwitchKeepsReplayAndFollow`.
4. **Odd orgs on the floor**: zero agents (rooms only), no managers (pre-3a company), only executives, a 500-agent company, a vacancy under a killed manager. Every living agent has a desk, nothing overlaps, the CEO is in the corner, the orphan vacancy is in the board anteroom, and the floor fits the pinned bounds. → Task 3 `OfficeLayoutTests.*`; Task 5 `emptyCompanyShowsRoomsOnly`.
5. **Unlock misfires**: typing `office` into the FIND field, five slow Board clicks, four Board clicks then an agent click. None unlocks; the inventory stays frozen. → Task 1 `OfficeUnlockTests.slowKeysReset`, `slowClicksReset`, `otherClickResets`; Task 11 Step 6 (manual check that the FIND field keeps the keystrokes).

---

## File Structure

```
Sources/BrahmaAppModel/Map/
  MapTypes.swift          (modified) MapMode.office; VisualKind.phaseChange
  OfficeUnlock.swift      OfficeUnlock (pure state machine)
  OfficeActivity.swift    MapItemPhase, OfficeActivity
  OfficeLayout.swift      OfficeRoomKind, OfficeRoom, OfficePod, OfficeDesk, OfficeLayout (make, location, route, seats)
  MapModel.swift          (modified) MapInputs.itemPhases/openAsks; MapAgent.activity/waitingOnOwner/shipping; openAsks; diff → phaseChange
  MapQueue.swift          (modified) duration/priority/isTraffic for .phaseChange
  MapController.swift     (modified, small) stored officeUnlocked/officeRevealAt/unlock; collapsed guard; two lines in inputs(for:) (phases, reviewing, asks)
  MapController+Office.swift  unlockOffice, officeKey, officeBoardClick, officeOtherClick, the item-phase/reviewing derivation helpers
  MapOverlay.swift        (modified) reveal chip
  Synthetic.swift         (modified) phases, reviewers, perks, openAsks in the demo company
  LaunchOptions.swift     (modified) --map-skin, isHarness
  ../AppModel.swift       (modified) mapDefaults: UserDefaults used by ensureMapController
  ../Presentation/ThemeHex.swift (modified) office tokens, blend, contrastRatio
Sources/BrahmaMapKit/
  MapCamera.swift         MapCameraDriver (extracted from Org/OrgParticles.swift)
  MapScene.swift          MapScene protocol, MapSceneFactory
  MapAccessibility.swift  MapAccessibilityItem, MapAccessible, MapMotionReducible
  Office/OfficeTextures.swift  procedural art, tile sheet
  Office/OfficeNodes.swift     OfficeDeskNode, OfficeFigureNode, OfficeRoomNode, OfficePodNode
  Office/OfficeScene.swift     OfficeScene: layers, rebuild, LOD, hit tests, camera, zoom
  Office/OfficeMotion.swift    OfficeMotionState; walks, notes, events, strolls, highlight
  Org/OrgParticles.swift  (modified) camera code replaced by MapCameraDriver; phaseChange handled; MotionParticle.Kind += note, folder
  Org/OrgScene.swift      (modified) MapScene and MapMotionReducible conformance (not MapAccessible: spec §5.6)
  Views/MapSKView.swift   (modified) first responder, onKey, accessibilityChildren, reduce-motion observation
  Views/OrgView.swift     (modified) hosts either scene by controller.mode, cross-fade, unlock hooks
  MapBench.swift          (modified) run(agents:mode:…)
Sources/BrahmaApp/
  Views/Map/MapHeader.swift     (modified) segmented control when unlocked
  Views/Map/AgentMapPanel.swift (modified) reveal chip via MapOverlay.chips
  AppDelegate.swift             (modified) --map-skin on the demo controller
Tests/BrahmaAppModelTests/
  OfficeUnlockTests.swift  OfficeLayoutTests.swift  OfficeControllerTests.swift (every new controller test; MapControllerTests is P's)
  (modified) MapModelTests.swift MapQueueTests.swift MapOverlayTests.swift LaunchOptionsTests.swift ThemeHexTests.swift
Tests/BrahmaMapKitTests/
  OfficeTexturesTests.swift  OfficeSceneTests.swift  MapAccessibilityTests.swift
  (modified) MapPerfTests.swift  OrgSceneTests.swift (camera extraction must leave it green)
scripts/map-demo.sh (doc line)  scripts/map-snapshots.sh (filter adds OfficeSceneTests|OfficeTexturesTests)
README.md  docs/superpowers/specs/2026-10-21-brahma-design-v2.md (After-4c note)  docs/superpowers/plans/2026-10-21-master-roadmap.md  docs/superpowers/specs/2026-10-21-traceability.md
```

---

### Task 1: `MapMode.office`, the unlock state machine, persistence, `--map-skin`, the reveal chip

**Files:**
- Create: `Sources/BrahmaAppModel/Map/OfficeUnlock.swift`, `Map/MapController+Office.swift`
- Modify: `Sources/BrahmaAppModel/Map/MapTypes.swift` (`MapMode`), `MapController.swift` (stored properties, `init`, `collapsed` only), `MapOverlay.swift`, `LaunchOptions.swift`, `AppModel.swift` (`mapDefaults`)
- Test: `Tests/BrahmaAppModelTests/OfficeUnlockTests.swift`, `OfficeControllerTests.swift`; modify `MapOverlayTests.swift`, `LaunchOptionsTests.swift`

**Interfaces:**
- Consumes: `MapController` (its `defaults`, `clock`, `mapNow()`, `mode`, `collapsed`), `MapOverlay.chips(stats:followHandle:now:)`, `LaunchOptions.parse`, `AppModel.ensureMapController()`.
- Produces:
  - `MapMode.office` with `title == "OFFICE"` (`org` stays first in `allCases`).
  - `LaunchOptions.isHarness: Bool` (`smokeTest || snapshotPath != nil || mapDemo || mapBench != nil`; Task 11 adds P's `uiInventory` if it exists); `AppModel.mapDefaults: UserDefaults = .standard` (`@ObservationIgnored public var`, as `dropDefaults`), passed to every `MapController` the model builds.
  - `MapController.init` reads `officeUnlocked` from `defaults` and, when the stored mode is `.office` but `officeUnlocked` is false, uses `.org`.
  - `public struct OfficeUnlock: Equatable, Sendable` with `static let word = "office"`, `keyWindow: TimeInterval = 2`, `boardClicks = 5`, `clickWindow: TimeInterval = 3`; `public init()`; `public mutating func key(_ c: Character, at t: TimeInterval) -> Bool` (true on the keystroke that completes the word; case-insensitive; a key later than `keyWindow` after the previous one, or a wrong letter, resets to the empty prefix, and the wrong letter is then tried as a first letter); `public mutating func boardClick(at t: TimeInterval) -> Bool` (true on the 5th click inside `clickWindow` of the first counted click); `public mutating func otherClick()` (resets the click count); `public mutating func reset()`.
  - `MapController`: `public static let officeUnlockedKey = "brahma.map.office.unlocked"`; `public private(set) var officeUnlocked: Bool` (read from `defaults` in `init`); `public func unlockOffice()` (sets the flag and the default, sets `mode = .office`, sets `officeRevealAt = mapNow()`; a no-op when already unlocked); `public internal(set) var officeRevealAt: TimeInterval?`; `public func officeKey(_ c: Character)` and `public func officeBoardClick()` and `public func officeOtherClick()` feed an internal `OfficeUnlock` with `mapNow()` and call `unlockOffice()` when it returns true (all three are no-ops once unlocked); `collapsed` returns `[]` when `mode == .office`.
  - `MapOverlay`: `public static let revealDuration: TimeInterval = 3`; `chips(stats:followHandle:now:revealAt: TimeInterval? = nil)` appends `MapChip(text: "YOU FOUND THE OFFICE", isWarning: false, dismissible: false)` first while `revealAt != nil && now - revealAt < revealDuration && now >= revealAt`.
  - `LaunchOptions.mapSkin: MapMode?` from `--map-skin=org|office` (anything else → nil); `--map-skin` implies nothing else.

- [ ] **Step 1: Write the failing tests.** `OfficeUnlockTests`:
```swift
@Test func wordUnlocksWithinWindow() { /* o,f,f,i,c at 0,0.5,1,1.5,2.0 → false; e at 2.5 → true */ }
@Test func upperCaseAccepted() { /* "OFFICE" → true */ }
@Test func slowKeysReset() { /* o f f i c at 0…1.6, e at 4.0 → false; then o…e quickly → true */ }
@Test func wrongKeyRestartsPrefix() { /* o f x → false; then o f f i c e → true (x reset, and "offo..." handles the overlap: "offoffice" → true) */ }
@Test func fiveBoardClicksWithinWindow() { /* 0, 0.5, 1, 1.5, 2.9 → true on the fifth */ }
@Test func slowClicksReset() { /* 0, 1, 2, 3.5 (new window starts), 4, 4.5, 5, 6.2 → true only on the fifth inside a 3 s window */ }
@Test func otherClickResets() { /* 4 board clicks, otherClick(), 1 board click → false */ }
```
  `OfficeControllerTests` (new file; synthetic controller, fresh `UserDefaults` suite, virtual clock):
```swift
@Test func officeUnlockPersistsAndSwitchesMode() { /* officeUnlocked false; 5× officeBoardClick() → officeUnlocked, mode == .office, officeRevealAt == mapNow(); a second controller on the same suite starts unlocked and keeps its stored mode */ }
@Test func officeKeysUnlockOnce() { /* "office" via officeKey → unlocked; further keys and clicks change nothing (revealAt unchanged) */ }
@Test func storedOfficeModeWithoutUnlockFallsBack() { /* suite with mode "office" and no unlock → controller.mode == .org; with the unlock → .office */ }
@Test func collapsedEmptyInOfficeMode() { /* 300 agents: collapsed non-empty in .org; mode = .office → collapsed.isEmpty; back to .org → non-empty again */ }
```
  `MapOverlayTests.revealChipForThreeSeconds` (chip present at `revealAt + 2.9`, absent at `+3.0`, absent with nil); `LaunchOptionsTests.mapSkin` (`--map-skin=office` → `.office`; `=org` → `.org`; `=hive` → nil; absent → nil) and `isHarness` (true for each harness flag, false for a plain launch).
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "OfficeUnlockTests|OfficeControllerTests|MapOverlayTests|LaunchOptionsTests"`. Expected: FAIL (compile errors on the new names).
- [ ] **Step 3:** Implement. `MapMode.office` makes `MapHeader`'s `MapMode.allCases.count > 1` branch true: in this task change that condition to `false` with a `// Task 11` comment so the header stays unchanged until the wiring task (the inventory must not change). `AppModel.ensureMapController()` passes `mapDefaults`; `AppDelegate` sets `model.mapDefaults = UserDefaults(suiteName: "brahma.harness.\(ProcessInfo.processInfo.processIdentifier)")!` after `removePersistentDomain(forName:)` when `options.isHarness`, and passes the same suite to the demo controller it installs.
- [ ] **Step 4:** Run the filter, then the full `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(app-model): office map mode, unlock state machine, per-owner persistence and --map-skin` with the trailer lines.

---

### Task 2: Item phases and office activity in `MapModel`

**Files:**
- Create: `Sources/BrahmaAppModel/Map/OfficeActivity.swift`
- Modify: `MapTypes.swift` (`VisualKind`), `MapModel.swift`, `MapQueue.swift`, `MapController.swift` (two lines in `inputs(for:)` calling helpers in `MapController+Office.swift`), `Synthetic.swift`, `Sources/BrahmaMapKit/Org/OrgParticles.swift` (the exhaustive switches)
- Test: modify `Tests/BrahmaAppModelTests/MapModelTests.swift`, `MapQueueTests.swift`, `OfficeControllerTests.swift`

**Interfaces:**
- Consumes: `WorkItem.status` (`WorkItemStatus.inProgress/.inReview`), `WorkItem.mergeState` (`MergeState.none/.pending/.verifying`), `WorkSnapshot.latestRuns[item.id]?.status` (`VerificationStatus`), `WorkSnapshot.inbox`, `WorkItem.reviewerId`, `Agent.blocker` (`Blocker.owner`), `Meeting.participantIds`.
- Produces:
  - `public enum MapItemPhase: String, Equatable, Sendable { case working, inReview, checking, merging, passed, failed }` with `public static func of(status: WorkItemStatus, mergeState: MergeState, run: VerificationStatus?) -> MapItemPhase`: `.merging` when `mergeState != .none`; else `.checking` when run is `.queued`/`.running`; else `.inReview` when status is `.inReview`; else `.passed` when run is `.passed`; else `.failed` when run is `.failed`/`.timedOut`/`.error`; else `.working`. `var isShipping: Bool` is true for `checking, merging, passed, failed`.
  - `public enum OfficeActivity: Equatable, Sendable { case typing, reviewing, meeting(String), waitingOnOwner, blocked, idle, away, gone }` with `public static func of(state: AgentState, paused: Bool, waitingOnOwner: Bool, reviewing: Bool, meetingId: String?) -> OfficeActivity`: killed → `.gone`; paused or sleeping → `.away`; blocked → `.waitingOnOwner` if `waitingOnOwner` else `.blocked`; then (running or ready) `meetingId` → `.meeting(id)`; `reviewing` → `.reviewing`; running → `.typing`; ready → `.idle`.
  - `MapInputs.itemPhases: [String: MapItemPhase] = [:]`, `MapInputs.reviewing: Set<String> = []` (reviewer ids of items with `status == .inReview` whose `ownerId` and `reviewerId` are both living agents), `MapInputs.openAsks: Int = 0` (all with defaults in `init`). `MapController+Office.swift` holds `static func itemPhases(_ work: WorkSnapshot, newest: [String: WorkItem]) -> [String: MapItemPhase]` and `static func reviewing(_ work: WorkSnapshot, living: Set<String>) -> Set<String>`; `inputs(for:)` calls them and passes `snapshot.work.inbox.count`.
  - `MapAgent.waitingOnOwner: Bool = false`, `MapAgent.shipping: MapItemPhase? = nil` (the phase when `isShipping`, else nil), `MapAgent.activity: OfficeActivity = .idle` (defaults in `init`).
  - `MapModel.openAsks: Int` (`public private(set)`, clamped ≥ 0); `MapModel.phase(agentId:) -> MapItemPhase?`.
  - `VisualKind.phaseChange(from: MapItemPhase, to: MapItemPhase)`: `MapThrottle.duration` 0.2, `priority` 4, `isTraffic` false; emitted by `diff` for an agent whose phase changed (absent counts as `.working`). `OrgParticles.isContentEvent` includes it; `playCardEffect` returns true for it and draws nothing.
  - `SyntheticCompany.make` additionally returns `itemPhases: [String: MapItemPhase]` (every running agent with an item: 60 % working, 15 % inReview, 10 % checking, 10 % merging, 5 % failed, by the seeded shuffle), `reviewing: Set<String>` (for each `inReview` item, one living teammate of its owner), `people: MapPeople` (perks for 10 % of agents, drawn from `["☕", "🍜", "🏆", "🔥", "⭐"]`, one or two each) and `openAsks: 3`; `MapController.inputs(_ w: SyntheticWorld)` passes them.

- [ ] **Step 1: Write the failing tests.** `MapModelTests`:
```swift
@Test func phaseOfItemFacets() { /* table: (inProgress, none, nil)→working; (inReview, none, nil)→inReview; (inProgress, pending, nil)→merging; (inReview, none, running)→checking; (inProgress, none, passed)→passed; (inProgress, none, timedOut)→failed; isShipping true for the last four */ }
@Test func activityTable() { /* every (state, paused, waitingOnOwner, reviewing, meetingId) row of spec §5.4 → the listed activity; paused running → away; blocked+owner → waitingOnOwner; ready+reviewing → reviewing; running+meeting → meeting */ }
@Test func reviewerOfInReviewItemIsReviewing() { /* inputs.reviewing = [reviewer], reviewer running → agents[reviewer].activity == .reviewing; the item's owner (running) stays .typing; a reviewer that is sleeping stays .away */ }
@Test func ownerBlockerIsWaitingOnOwner() { /* Agent.blocker = .owner(reason:) → waitingOnOwner, activity .waitingOnOwner; .agent blocker → .blocked */ }
@Test func shippingFromPhase() { /* .merging → shipping == .merging; .working → nil */ }
@Test func phaseChangeEmitsEvent() { /* apply with working, apply with checking → pending has .phaseChange(from: .working, to: .checking) from .agent(id) */ }
@Test func openAsksClamped() { /* openAsks: -3 → 0; 12 → 12 */ }
```
  `MapQueueTests.phaseChangeIsStructural` (never dropped at the queue cap, duration 0.2, spawned before `.message`). `OfficeControllerTests.itemPhasesReviewingAndAsksFromSnapshot` (seeded Acme: an item `inReview` with a reviewer and a `latestRuns` entry `running` → the owner's phase is `.checking`, `inputs.reviewing` contains the reviewer; an `inProgress` item's reviewer is not in `reviewing`; two inbox asks → `model.openAsks == 2`).
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "MapModelTests|MapQueueTests|OfficeControllerTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement. In `MapModel.apply`, `reviewing` is `inputs.reviewing` filtered to agents present in the snapshot; the meeting map is participant id → the first meeting that lists it (meetings sorted by id).
- [ ] **Step 4:** Run the full `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS (the `OrgSceneTests` still compile: the new `VisualKind` case is handled).
- [ ] **Step 5:** Commit `feat(app-model): item phases, office activity and phase-change events on the map model` with the trailer lines.

---

### Task 3: `OfficeLayout`

**Files:**
- Create: `Sources/BrahmaAppModel/Map/OfficeLayout.swift`
- Test: `Tests/BrahmaAppModelTests/OfficeLayoutTests.swift`

**Interfaces:**
- Consumes: `MapModel` (`tree`, `agents`, `groups`, `vacancies`, `showFormer`, `teamCard(managerId:)` for pod titles), `OrgTree` (`order`, `nodes[id].tier`, `childIds`, `teamLabel`), `Department`, `MapRect`, `MapPoint2`, `MapEndpoint`.
- Produces (all `public`, `Equatable`, `Sendable`):
  - `enum OfficeRoomKind { case board, ceo, executive(agentId: String), director(agentId: String), review, breakRoom, mail }`
  - `struct OfficeRoom { var id: String; var kind: OfficeRoomKind; var rect: MapRect; var title: String; var door: MapPoint2 }` — ids `"room:board"`, `"room:ceo"`, `"office:<agentId>"`, `"room:review"`, `"room:break"`, `"room:mail"`; `title` is `BOARD ROOM`, `CEO`, the cleaned role for an executive office, `REVIEW`, `BREAK ROOM`, `MAIL ROOM`.
  - `struct OfficePod { var id: String; var managerId: String?; var rect: MapRect; var title: String; var department: Department; var labelRect: MapRect; var board: MapPoint2 }` — id `"pod:<managerId>"` or `"pod:dept:<department.rawValue>"`; `title` from `teamCard(managerId:).title` or `department.title`.
  - `struct OfficeDesk { var id: String; var rect: MapRect; var seat: MapPoint2; var podId: String?; var roomId: String?; var facesDown: Bool }` — id is the agent id or `"vacancy:<id>"`.
  - `struct OfficeLayout` with the pinned statics (`desk`, `chair`, `pod`, `corridor`, `wingGap`, `roomsStrip`, `boardRoom`, `ceoOffice`, `execOffice`, `directorOffice`, `reviewRoom`, `breakRoom`, `mailRoom`, `reviewSeats = 12`, `doorSpots = 8`), `var rooms: [String: OfficeRoom]`, `var pods: [String: OfficePod]`, `var desks: [String: OfficeDesk]`, `var corridors: [MapRect]`, `var size: (w: Double, h: Double)`;
    `static func make(model: MapModel) -> OfficeLayout`;
    `func location(_ e: MapEndpoint) -> MapPoint2?` (owner → board door; agent → desk seat; nil for unknown);
    `func route(from: MapPoint2, to: MapPoint2) -> [MapPoint2]` (Manhattan: start → the nearest corridor point → along corridors → the nearest corridor point to the end → end; every segment between the first and last lies inside the union of `corridors` and the room/pod the end is in; a start or end that is in no corridor exits perpendicular to the nearest corridor edge);
    `func reviewSeat(_ index: Int) -> MapPoint2` (12 seats around the review table, then standing spots along its wall), `func doorSpot(_ index: Int) -> MapPoint2` (8 spots outside the board door, then a queue continuing along the wall), `func fameShelf() -> MapPoint2`, `func mailCounter(_ index: Int) -> MapPoint2`.
  - Placement rules (spec §5.2, rules 1–6): the top strip holds the board room at x 0, then one `execOffice` per `.csuite` agent in tree order, then the CEO office flush with the right edge (`rect.x + rect.w == size.w`); killed agents get a desk only with `showFormer`. **Pods:** every agent whose direct reports include at least one agent that is not itself a manager-with-reports gets `pod:<id>` holding exactly those reports; the head desk is the owner's unless the owner has an office (CEO, C-suite, director), in which case there is no head desk and the title is the owner's team label or department. Pods never nest: a sub-manager's pod follows its parent's pod. **Wings:** one per `.director` in tree order (director office, the director's pod if any, then the pods of every manager in its subtree, flattened in tree order), then one **floor wing** titled `FLOOR` without an office for the pods of managers under no director, then department pods (`pod:dept:<department>`) for agents with no manager and no executive kind. Vacancies with a living manager go into that manager's pod as the last desk (creating a pod for the manager if needed), without one into a 2-desk anteroom beside the board room. The rooms strip is the last `roomsStrip` points: break room at x 0, review room centred, mail room flush right; `size` is the bounding box plus one corridor of margin.

- [ ] **Step 1: Write the failing tests** (`OfficeLayoutTests`, pure, models from `SyntheticCompany.make` and hand-built `Agent`s via `MapSupport`):
```swift
@Test func everyLivingAgentHasADesk() { /* 12, 50, 300 → desks ⊇ living agent ids; killed only with showFormer */ }
@Test func noDeskOrRoomOverlaps() { /* 300: no two desk rects intersect; no desk intersects a room it is not in; pods don't intersect; rooms don't intersect */ }
@Test func ceoCornerAndExecutiveOffices() { /* room:ceo maxX == size.w and y == 0; one office:<id> per csuite agent */ }
@Test func podPerManagerInsideItsWing() { /* every agent with a non-manager direct report has pod:<id>; a pod under a director lies inside that director's wing bounds; pods never intersect */ }
@Test func everyTreeShapeGetsDesks() { /* CEO + 4 ICs → room:ceo and pod:<ceo> with 4 desks, no head desk; a director with 2 direct ICs and 2 managers → the director's pod first in its wing; a manager whose report is a manager-with-reports → two sibling pods, parent's first; an executive with 3 IC reports → office:<id> plus pod:<id> in the FLOOR wing */ }
@Test func vacancyPlacement() { /* vacancy with manager → desk in that pod; with killed/absent manager → in the anteroom beside room:board */ }
@Test func oddOrgs() { /* zero agents → 4 rooms + board, no desks, size > 0; no managers (all roots) → department pods; only executives → offices only; 500 agents → size.w ≤ 3000, size.h ≤ 1800 */ }
@Test func deterministicAndStableUnderHire() { /* make twice equal; adding a leaf IC to the last pod leaves every other pod's desks' rects unchanged */ }
@Test func routesStayInCorridors() { /* 50 agents, 40 seeded desk pairs: every middle segment lies within corridors ∪ the end's pod/room; no middle segment intersects a desk interior */ }
@Test func locationsAndSeats() { /* location(.owner) == board door; location(.agent) == seat; reviewSeat(0..<12) inside room:review and distinct; reviewSeat(13) inside room:review; doorSpot(0..<8) outside room:board, within 2·corridor of its door */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OfficeLayoutTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `OfficeLayout.swift`. A pod's height is `pod.head + ceil(n/2) · (desk.h + desk.face + chair.h + pod.gap)`; the wing width is the sum of its pod widths plus corridors; wings wrap to a new row when wider than `max(1 600, strip width)`.
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5:** Commit `feat(app-model): office floor layout with rooms, pods, desks and corridor routes` with the trailer lines.

---

### Task 4: Office tokens and procedural textures

**Files:**
- Create: `Sources/BrahmaMapKit/Office/OfficeTextures.swift`
- Modify: `Sources/BrahmaAppModel/Presentation/ThemeHex.swift`
- Test: `Tests/BrahmaMapKitTests/OfficeTexturesTests.swift`; modify `Tests/BrahmaAppModelTests/ThemeHexTests.swift`

**Interfaces:**
- Consumes: `ThemeHex` tokens, `MapPalette.color`, `MapPalette.department`, `LabelTextures.emoji`, `MotionTextures.render` pattern (CoreGraphics into `SKTexture` at 2×), `MapSnapshotter`.
- Produces:
  - `ThemeHex`: `officeLamp: UInt32 = 0xF2C572`, `officeGlass: UInt32 = 0x2EC4B6`, `officeCarpetAlpha: Double = 0.12`, `officeFloor = bg0`, `officeRoomFloor = bg2`, `officeWall = lineStrong`, `officeDeskTop = bg3`, `officeDeskFace = bg2`; `public static func blend(_ fg: UInt32, over bg: UInt32, alpha: Double) -> UInt32`; `public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double` (WCAG relative luminance).
  - `@MainActor public enum OfficeTextures` with `static let scale: CGFloat = 2`, `static let figureSize = CGSize(width: 10, height: 16)`; `enum ScreenState { case off, dim, lit }`; `enum FigurePose: CaseIterable { case sit, typeA, typeB, walkA, walkB, stand, raisedHand }`; `enum BubbleGlyph: CaseIterable { case exclaim, ellipsis, check }`; `enum BadgeGlyph: CaseIterable { case typing, reviewing, blocked, waiting, away }`; cached textures `deskTop`, `deskFace`, `chair`, `monitor(_ state: ScreenState)` (white screen for `.lit` so a tint gives the status colour; `.dim` 40 %; `.off` `bg1`), `lampGlow` (48 pt radial, white, tinted), `figureBody(_ pose: FigurePose)` (white, tinted by department), `figureHead` (`text1`), `note`, `folder`, `parcel`, `parcelStrap(failed: Bool)`, `box`, `balloon`, `bubble(_ g: BubbleGlyph)`, `badge(_ g: BadgeGlyph)`, `placard` (`HIRING`, mono 8 via `LabelTextures`), `pinBoard`, `table`, `counter`, `sofa`, `shelf`, `door`, `wallH`, `wallV`, `floorTile` (24 pt seam in `mapGrid`, as `OrgScene.gridTexture`);
    `static func points(_ t: SKTexture) -> CGSize` (`size / scale`);
    `static func tileSheet() -> SKScene` (every variant on a `bg0` 800×400 scene, labelled, for human review).
  - Drawing rules: flat token-coloured shapes, 1 px outlines at most, no gradients except the radial lamp glow, no faces, no limbs beyond the two 2 pt hands (spec §5.3, §7).

- [ ] **Step 1: Write the failing tests.** `ThemeHexTests.officeTokensAndContrast`: `blend(text2, over: bg0, 1) == text2`; `contrastRatio(text0, bg2) ≥ 4.5`; `contrastRatio(text2, blend(ThemeHex.series[0], over: bg0, alpha: officeCarpetAlpha)) ≥ 3`; the same for every `series` carpet; `contrastRatio(officeLamp, bg0) ≥ 4.5`. `OfficeTexturesTests`:
```swift
@Test func everyTextureIsDrawn() { /* every texture and every enum variant has size > 1×1 and points(.) == declared size for desk (36×24), figure (10×16), note (7×9) */ }
@Test func monitorLitIsWhiteForTinting() { /* render monitor(.lit) alone on bg0: fraction near 0xFFFFFF > 0.3 */ }
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device")) func tileSheet() { /* render tileSheet() at 800×400; fraction(bg0) > 0.5; writeIfRequested "office-tiles" */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ThemeHexTests|OfficeTexturesTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the tokens, the helpers and `OfficeTextures.swift`.
- [ ] **Step 4:** Run the filter, then `BRAHMA_MAP_SNAPSHOT_DIR=$PWD/.superpowers/maps DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OfficeTexturesTests` and Read `.superpowers/maps/office-tiles.png`. Expected: flat, legible shapes in the app's tokens; nothing resembling a game sprite; the figure is a peg with no face.
- [ ] **Step 5:** Commit `feat(map): office tokens and procedural office textures` with the trailer lines.

---

### Task 5: `OfficeScene` — floor, rooms, pods, desks, figures at rest, LOD, hit tests, snapshots

**Files:**
- Create: `Sources/BrahmaMapKit/Office/OfficeScene.swift`, `Office/OfficeNodes.swift`, `Sources/BrahmaMapKit/MapScene.swift`
- Modify: `Sources/BrahmaMapKit/Org/OrgScene.swift` (conform to `MapScene`), `scripts/map-snapshots.sh` (filter `"OrgSceneTests|OfficeSceneTests|OfficeTexturesTests"`)
- Test: `Tests/BrahmaMapKitTests/OfficeSceneTests.swift`

**Interfaces:**
- Consumes: Task 3 `OfficeLayout`; Task 2 `MapAgent.activity/shipping/waitingOnOwner`, `MapModel.openAsks`; Task 4 `OfficeTextures`, tokens; `MapInteractive`, `MapHit`, `LabelTextures`, `MapPalette`, `OrgScene.textZoom/itemZoom` values.
- Produces:
  - `MapScene.swift`: `@MainActor public protocol MapScene: SKScene, MapInteractive { var mode: MapMode { get }; func present(controller: MapController?); func zoomToFit(margin: CGFloat); var contentBounds: CGRect { get }; func targetRect(_ id: String) -> CGRect? }` (`targetRect` is the card rect in the org chart, the desk rect in the office; `OrgScene` conforms with `mode == .org`); `public enum MapSceneFactory { public static func make(_ mode: MapMode, size: CGSize) -> any MapScene }`.
  - `@MainActor public final class OfficeScene: SKScene, MapScene` with `mode == .office`; statics `zoomRange = 0.15...3.0`, `textZoom = 0.5`, `itemZoom = 1.2`, `figureZoom = 0.3`, `fullLOD = 50`, `staticLOD = 150`, `moveDuration = 0.4`, `walkDuration = 0.8`, `typingHz = 4.0`, `pulseHz = 1.0`, `askFolders = 9`, `fameLimit = 6`; `public enum OfficeLOD: Equatable { case full, staticFigures, deskOnly }`; `public static func lod(living: Int) -> OfficeLOD`; `public private(set) var lod: OfficeLOD`; `public var reduceMotion: Bool` (initialised from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`; settable); `public func rebuild(model: MapModel)`; `public func hit(at p: CGPoint) -> MapHit?` (desk → `.agent` / `.vacancy`; board room → `.owner`; pod label rect → `.team(managerId)`; else nil); `public func deskRect(_ id: String) -> CGRect?`, `public func roomRect(_ id: String) -> CGRect?`, `public var layout: OfficeLayout`; test accessors `deskNode(_ id:) -> OfficeDeskNode?`, `figureNode(_ id:) -> OfficeFigureNode?`.
    Layers back to front: floor tiles, room floors and carpets, walls, pods (label, pin board), desks (top, face, chair, monitor, lamp glow, items, placard/box), figures (y-sorted: `zPosition = -position.y`), bubbles and badges, highlight ring, chip layer. Layout y grows downward and is drawn at `-y`, as `OrgScene`.
  - `OfficeNodes.swift`: `final class OfficeDeskNode: SKNode` with `func configure(agent: MapAgent, zoom: Double, lod: OfficeLOD, reduceMotion: Bool)`, `func configure(vacancy: Vacancy, zoom: Double)`, `var screenColor: UInt32` (test accessor: the monitor tint hex, `ThemeHex.status(…)` for lit/dim states, `bg1` for off), `var lampOn: Bool`, `var badge: OfficeTextures.BadgeGlyph?`; `final class OfficeFigureNode: SKNode` (body + head sprites, `var pose`, `func tint(_ d: Department)`, `var collar: Int?` trust tier); `final class OfficeRoomNode: SKNode` (floor, walls, door, furniture, title, `var doorLit: Bool`, `var count: Int` for the desk-only door counters, `var askFolders: Int`); `final class OfficePodNode: SKNode` (carpet, label, pin board).
  - Rest state rules (spec §5.4, right-hand columns): screen `lit` + status colour for `typing`/`blocked`/`waitingOnOwner`; `dim` for `idle`/`reviewing`/`meeting`; `off` and lamp off for `away`/`gone`; `gone` adds the box and strikes the handle (reuse the org card's strikethrough label call); figures: at full and static LOD a figure sits at its seat for `typing`/`idle`/`blocked` (raised hand + `!` bubble when blocked), stands at `doorSpot(i)` for `waitingOnOwner` (`…` bubble), sits at `reviewSeat(i)` for `reviewing`/`meeting` (indices in tree order), is absent for `away`/`gone`; at desk-only LOD there are no figures and the review and board doors show counts; under `reduceMotion` every desk shows its `badge` and nothing pulses. Perks: ≤ 2 emoji at the desk corner from `itemZoom`; the break-room shelf shows the first `fameLimit` perks in tree order. The board table shows `min(openAsks, askFolders)` folders or `9+`. Text: handle from `textZoom` (mono 9, `text0`), role from `itemZoom` (8, `text1`).

- [ ] **Step 1: Write the failing tests** (`OfficeSceneTests`, `@MainActor`, models built as `OrgSceneTests.model(agents:…)` does, extended with `itemPhases` and `people`):
```swift
@Test func oneDeskPerLivingAgentAndRooms() { /* 50 → deskNode for every living id, none for killed; roomRect for room:board/ceo/review/break/mail non-nil */ }
@Test func hitTests() { /* desk centre → .agent; HIRING desk → .vacancy; board room → .owner; pod label → .team(manager); empty floor → nil */ }
@Test func lodByCount() { /* lod(living: 50) == .full, 51 → .staticFigures, 150 → .staticFigures, 151 → .deskOnly; scene.lod follows the model; deskOnly → figureNode(id) == nil for all */ }
@Test func screenAndFigureFollowActivity() { /* running → screenColor == ThemeHex.running, pose typeA/typeB; ready → dim, pose sit; blocked → running? no: screenColor == blocked, pose raisedHand, bubble exclaim; owner-blocked → figure at doorSpot(0) ±1 pt with ellipsis bubble; sleeping → lampOn false, no figure; reviewing → figure at reviewSeat(0) ±1 pt */ }
@Test func formerDeskShowsBox() { /* showFormer + killed → desk present, box child present, lampOn false */ }
@Test func reduceMotionShowsBadges() { /* reduceMotion = true → every desk has a badge matching its activity; pulse action absent */ }
@Test func perksAndAsks() { /* people.perks[id] = ["☕","🏆"] → 2 item sprites at zoom 1.5, 0 at zoom 1.0; 7 perks across agents → shelf shows 6; openAsks 12 → board table shows "9+" label */ }
@Test func deskTextIsClean() { /* a Zalgo 5 000-mark handle and a 10 000-char role → the desk's label texts == agent.handle / agent.role (already clean), lengths ≤ 41 / 40 */ }
@Test func emptyCompanyShowsRoomsOnly() { /* 0 agents → 5 rooms, 0 desks, contentBounds non-empty, zoomToFit does not crash */ }
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device")) func officeSnapshots() { /* 12, 50, 300 at 1600×900 after zoomToFit: fraction(bg0) > 0.3, fraction(running) > 0.0005 (lit screens + glow), fraction(officeLamp) > 0 at 12 and 50; writeIfRequested "office-12", "office-50", "office-300"; zoom 1.5 crop of a pod → "office-50-detail"; reduceMotion → "office-50-reduce-motion" */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OfficeSceneTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `MapScene.swift`, `OfficeScene.swift` and `OfficeNodes.swift`; make `OrgScene` conform to `MapScene` (`targetRect` = `cardRect`). Desk nodes are reused by id and pooled when they leave, as `OrgCardNode`s are; a desk whose rect moved glides over `moveDuration`.
- [ ] **Step 4:** Run the full `swift test`, then `scripts/map-snapshots.sh`, and Read `office-12.png`, `office-50.png`, `office-300.png`, `office-50-detail.png`, `office-50-reduce-motion.png`. Expected: the floor plan of spec §5.2 (board room top left, CEO corner top right, wings of pods, the three rooms along the bottom); lit screens in status colours on a dark floor; figures at desks at 12 and 50, none at 300; badges and no glow in the reduce-motion image; handles legible in the detail crop; nothing that reads as a game.
- [ ] **Step 5:** Commit `feat(map): office scene with rooms, pods, desks, resting figures, LOD and hit tests` with the trailer lines.

---

### Task 6: `MapCameraDriver` — the org chart's camera, shared

**Files:**
- Create: `Sources/BrahmaMapKit/MapCamera.swift`
- Modify: `Sources/BrahmaMapKit/Org/OrgParticles.swift` (remove `MotionState.CameraState`, `updateCamera`, `syncZoom`, `fitGoal` users; delegate to the driver), `Org/OrgScene.swift` (`cameraMoved`, `zoomToFit`, `userMovedCamera` call the driver)
- Test: `Tests/BrahmaMapKitTests/OrgSceneTests.swift` must pass **unchanged**

**Interfaces:**
- Consumes: `MapController.camera`, `.cameraRequest`, `.follow`, `.zoom`; `SKCameraNode`.
- Produces: `@MainActor final class MapCameraDriver` with `static let ease: TimeInterval = 0.3`; `init(scene: SKScene, camera: SKCameraNode, zoomRange: ClosedRange<Double>)`; `func update(controller: MapController, now: TimeInterval, targetRect: (String) -> CGRect?, contentBounds: CGRect)` (the easing, follow, auto-fit and snap-on-first-frame rules exactly as `OrgScene.updateCamera` has them today); `func syncZoom(controller: MapController)`; `func userMoved()`; `func zoomToFit(contentBounds: CGRect, margin: CGFloat)`; `var zoom: Double { get set }` (clamped); `func reset()` (on controller change).

- [ ] **Step 1:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OrgSceneTests` and record the pass count. Expected: all PASS (the baseline).
- [ ] **Step 2:** Create `MapCamera.swift` by moving the camera code out of `OrgParticles.swift`/`OrgScene.swift` behind the signatures above; `OrgScene` keeps its public `zoom`, `zoomToFit`, `userMovedCamera` and `fitGoal` as thin forwards so no test changes.
- [ ] **Step 3:** Run the same filter. Expected: the same tests PASS with no test edit; `git diff --stat Tests/` is empty.
- [ ] **Step 4:** Run the full `swift test`. Expected: all PASS.
- [ ] **Step 5:** Commit `refactor(map): extract the camera driver from the org scene for reuse by the office` with the trailer lines.

---

### Task 7: Office motion — walks, notes, events, strolls, highlight, follow

**Files:**
- Create: `Sources/BrahmaMapKit/Office/OfficeMotion.swift`
- Modify: `Office/OfficeScene.swift` (`update(controller:events:now:)`, `present`, `userMovedCamera`), `Org/OrgParticles.swift` (`MotionParticle.Kind` += `.note`, `.folder`; `MotionParticle.configure` picks the office textures for them)
- Test: modify `Tests/BrahmaMapKitTests/OfficeSceneTests.swift`

**Interfaces:**
- Consumes: Task 5 scene and nodes; Task 6 `MapCameraDriver`; Task 3 `OfficeLayout.route/location/reviewSeat/doorSpot/mailCounter`; `MotionParticle`, `MotionRoute`, `MotionState.poolSize` (150), `MapController.frame(now:)`, `highlightId`, `highlightDuration`; `SplitMix64`.
- Produces:
  - `OfficeScene.update(controller: MapController, events: [VisualEvent], now: TimeInterval)` — per frame: leave events hold the layout and start the desk-cleared animation; rebuild when `structureRevision`, a content event (`stateChange`, `phaseChange`, `promotion`) or the 0.25 s refresh is due; spawn event visuals; advance figures, notes, bubbles, strolls, the highlight ring and the camera (`driver.update(… targetRect: { self.figureOrDeskRect($0) } …)`).
  - `final class OfficeMotionState` (figure targets `[String: CGPoint]`, walks `[String: (from: CGPoint, to: CGPoint, start: TimeInterval)]`, strolls `[String: TimeInterval]` (next stroll time), notes via the shared particle pool, parcels `[String: SKNode]` by agent id, bubbles, `camera: MapCameraDriver`).
  - Behaviour (spec §5.4): a figure whose activity location changed walks there over `walkDuration` along `layout.route` (full LOD), appears there (static LOD), or is absent (desk-only). `.message` → a `.note` particle along `route(location(from), location(to))` for the event's duration, the sender's pose flips to `typeA` for 0.2 s; in aggregate mode the particle kind is `.dot`. `.broadcast` → a note sprite pinned at the sender's pod `board` fading over the duration, or a ring at an executive's door. `.handoff` → a `.folder` particle to the recipient, or to `mailCounter(0)` without one. `.phaseChange` → to a shipping phase: a parcel with the item key (`LabelTextures.text(agent.item prefix up to the first space)`) appears at `mailCounter(i)`; to `.passed`: a `check` bubble for 1 s then the parcel leaves; to `.failed`: the strap turns `blocked`; to `.working`/`.inReview`: the parcel is removed. `.hire` → the desk slides in from its pod aisle over 0.4 s and a balloon rises 24 pt and fades over 2 s. `.leave` → 1.5 s: figure alpha → 0, items slide into a box, lamp off; the layout is held meanwhile (as `OrgScene` holds for leaves). `.reorg` → the figure walks to the new seat while the desks glide. `.promotion` → a trophy sprite pops on the desk (scale 0 → 1.2 → 1 over 1.2 s). `.meetingStart/End` → `roomNode("room:review").doorLit` on/off; the title label is the event's `label`. Idle strolls: at full LOD an `.idle` figure walks to the break-room sofa and back after a `strollRange` interval seeded by `fnv1a(agentId)`; off under `reduceMotion` and above `fullLOD`. Retargeting: a walk or note whose end `location` is nil or moved more than 1 pt retargets to the new location (or the sender's seat for a note) on the next frame. Highlight: a ring around `deskRect(highlightId)` while set. Follow: the camera target is the figure's current position at full/static LOD and the desk at desk-only. Under `reduceMotion`: no walks, no notes (events become a 0.2 s badge flash), no strolls, no pulses.
  - Test accessors: `figurePosition(_ id:) -> CGPoint?`, `figureTarget(_ id:) -> CGPoint?`, `particleSprite(_ eventId:)`, `particleTarget(_ eventId:)`, `parcelCount: Int`, `reviewOccupants: [String]`, `doorQueue: [String]`, `particlesInUse: Int`, `particleSpriteCount: Int`.

- [ ] **Step 1: Write the failing tests** (`OfficeSceneTests`, synthetic controllers stepped with `scene.update(controller:events:now:)` and `MapSnapshotter.render` for action advancement, as `OrgSceneTests` does):
```swift
@Test func walkToReviewRoomOnReviewing() { /* 12 agents, full LOD: flip an agent to reviewing → figureTarget == reviewSeat(0); at t+0.4 position strictly between seat and desk; at t+0.8 position == seat ±1 */ }
@Test func messageNoteFollowsCorridorRoute() { /* a .message event → particleSprite kind note; particleTarget == location(to); mid-flight the sprite lies on layout.route(...) within 1 pt */ }
@Test func handoffWithoutRecipientGoesToMailRoom() { /* .handoff to nil → particleTarget == mailCounter(0) */ }
@Test func phaseChangeStampsParcel() { /* working→checking: parcelCount 1; →passed: check bubble present, after 1 s parcelCount 0; →failed: strap color == blocked */ }
@Test func hireBalloonAndLeaveClearsDesk() { /* .hire → balloon child on the desk, gone after 2 s; .leave → after 1.5 s desk node absent and layout rebuilt */ }
@Test func retargetWhenAgentKilledMidWalk() { /* start a walk to a colleague-targeted stroll, kill the target's model agent mid-walk → next frame figureTarget is its own seat; no crash */ }
@Test func noteRetargetsWhenRecipientLeaves() { /* in-flight .message, recipient killed → particleTarget == sender's seat */ }
@Test func staticLODTeleports() { /* 80 agents: activity change → figurePosition == target immediately; no walk entry */ }
@Test func reduceMotionNoWalkNoNotes() { /* reduceMotion: activity change → figure at target immediately; .message → particlesInUse == 0 and the desk badge flashes */ }
@Test func idleStrollsOnlyAtFullLOD() { /* 12 agents: advance 40 s → at least one idle figure visited the sofa (target within break room); 80 agents → none */ }
@Test func followAndHighlight() { /* controller.follow(id) → camera position == figure position ±1 after 0.3 s; jump(to:) → ring around deskRect for 1.5 s then hidden */ }
@Test func burstStaysBoundedInOffice() { /* 50 agents, 2000 messages ingested in one poll → particlesInUse ≤ 150, particleSpriteCount ≤ 150, stats.aggregate true within 2 s and particles are dots, structural events still spawned */ }
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device")) func officeFlowSnapshot() { /* 50 agents at 15 msg/s for 3 s: notes present; writeIfRequested "office-50-flow" */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OfficeSceneTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `OfficeMotion.swift` and the scene's `update`. `fnv1a(_ s: String) -> UInt64` is a private helper in `OfficeMotion.swift` (64-bit FNV-1a over UTF-8).
- [ ] **Step 4:** Run the full `swift test`, then `scripts/map-snapshots.sh`, and Read `office-50-flow.png`. Expected: notes on corridors, a figure or two in the review room, a parcel in the mail room, the static snapshots unchanged.
- [ ] **Step 5:** Commit `feat(map): office motion — walks, notes, parcels, hires, leaves, strolls, follow and highlight` with the trailer lines.

---

### Task 8: Accessibility — VoiceOver elements and Reduce Motion for both scenes

**Files:**
- Create: `Sources/BrahmaMapKit/MapAccessibility.swift`
- Modify: `Views/MapSKView.swift`, `Office/OfficeScene.swift`, `Org/OrgScene.swift`, `Org/OrgCards.swift` (pulse off under reduce motion)
- Test: `Tests/BrahmaMapKitTests/MapAccessibilityTests.swift`

**Interfaces:**
- Consumes: `MapScene`, `MapHit`, `MapHoverCard` fields (`handle`, `role`, `stateLabel`, `item`), `MapModel.hoverCard(agentId:)`, `NSAccessibilityElement`, `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
- Produces:
  - `public struct MapAccessibilityItem: Equatable { var id: String; var label: String; var frame: CGRect /* scene coords */; var hit: MapHit }`.
  - `@MainActor public protocol MapAccessible: AnyObject { var accessibilityRevision: Int { get }; func accessibilityItems(limit: Int) -> [MapAccessibilityItem] }` — **`OfficeScene` only in 4c** (spec §5.6): one item per desk (`"<handle>, <role>, <stateLabel>"` + `", <item>"` when present; a vacancy `"Open seat, <roleTitle>"`), the board room (`"Board room, owner, <n> open asks"`), and the review, break and mail rooms by title. Items are in tree order; `limit` truncates. `OrgScene` does not conform (Plan P's frozen inventory); the protocol needs no change for it to conform later.
  - `@MainActor public protocol MapMotionReducible: AnyObject { var reduceMotion: Bool { get set } }` — `OfficeScene` (Task 5) and `OrgScene` (running-bar pulse and chip pop off when true) conform.
  - `MapSKView`: `static let accessibilityLimit = 300`, `static let accessibilityInterval: TimeInterval = 1`; `isAccessibilityElement()` stays false; `accessibilityChildren()` → cached `[NSAccessibilityElement]` when the scene is a `MapAccessible` (role `.button`, label, frame converted scene → view → screen, `accessibilityPerformPress` calls `onClick?(hit, sceneCentre)`), rebuilt when the scene's `accessibilityRevision` changed and at most every `accessibilityInterval`; `nil` (the superclass's answer) for a scene that is not `MapAccessible`; observes the reduce-motion notification and sets `(scene as? MapMotionReducible)?.reduceMotion` from `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (also on `presentScene`).

- [ ] **Step 1: Write the failing tests** (`MapAccessibilityTests`, `@MainActor`):
```swift
@Test func officeItemsOnePerDeskPlusRooms() { /* 50 agents → items.count == living + vacancies + 4 (board, review, break, mail); board label ends with "3 open asks" with openAsks 3 */ }
@Test func labelsAreCleanText() { /* Zalgo handle, bidi role → label == "\(agent.handle), \(agent.role), \(stateLabel)"; contains no U+202E, ≤ 160 chars */ }
@Test func cappedAt300() { /* 500 agents (desk-only) → accessibilityItems(limit: 300).count == 300 */ }
@Test func orgSceneExposesNoElements() { /* MapSKView with a presented OrgScene (40 agents) → accessibilityChildren() is nil or empty, isAccessibilityElement() == false (the frozen inventory) */ }
@Test func viewExposesChildrenAndPress() { /* MapSKView with a presented OfficeScene (12 agents) → accessibilityChildren().count == items.count; performing press on the first desk element calls onClick with .agent(id) */ }
@Test func reduceMotionPropagates() { /* set view.reduceMotionOverride (test hook) true → (scene as MapMotionReducible).reduceMotion == true for both scenes */ }
```
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MapAccessibilityTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. `MapSKView.reduceMotionOverride: Bool?` is the test hook (nil reads the system).
- [ ] **Step 4:** Run the full `swift test`. Expected: all PASS, `OrgSceneTests` unchanged.
- [ ] **Step 5:** Commit `feat(map): VoiceOver elements per desk and card, Reduce Motion for both map scenes` with the trailer lines.

---

### Task 9: Bench and perf tests for the office

**Files:**
- Modify: `Sources/BrahmaMapKit/MapBench.swift`, `Tests/BrahmaMapKitTests/MapPerfTests.swift`

**Interfaces:**
- Consumes: Task 5 `MapSceneFactory.make`, `OfficeScene`; `MapBench.run`.
- Produces: `MapBench.run(agents: Int, mode: MapMode = .org, rate: Double = 50, burst: (TimeInterval, Int)? = (10, 200), seconds: Double = 30, expandAll: Bool = false) -> MapBenchResult`; the controller's `mode` is set before `present`; the scene comes from `MapSceneFactory.make(mode, size:)`; `expandAll` is ignored in `.office`; `MapBenchResult.mode` reports it (the `MAP BENCH mode=office …` line).

- [ ] **Step 1: Write the perf tests** (`MapPerfTests`, gated as the existing ones):
```swift
@Test func officeSixtyFpsAt50Bursts() { /* run(agents: 50, mode: .office) → p95Ms ≤ 16.7 */ }
@Test func officeSixtyFpsAt50Particles() { /* run(agents: 50, mode: .office, rate: 15, burst: nil) → aggregateSeconds == 0, p95Ms ≤ 16.7 */ }
@Test func officeAt150Static() { /* run(agents: 150, mode: .office) → p95Ms ≤ 16.7 */ }
@Test func officeAt300DeskOnly() { /* run(agents: 300, mode: .office) → p95Ms ≤ 16.7 */ }
```
- [ ] **Step 2:** Run `BRAHMA_PERF=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -Xswiftc -enable-testing --filter MapPerfTests`. Expected: the four office lines and the four org lines all PASS. If an office row fails, profile (Time Profiler, Metal System Trace); the expected levers are node pooling, texture sharing, rebuilding only on revision, and y-sort only for moved figures. Raise a pinned threshold in the report rather than editing it silently.
- [ ] **Step 3:** Run the full debug `swift test`. Expected: all PASS (perf skipped).
- [ ] **Step 4:** Commit `perf(map): office bench rows at 50, 150 and 300 agents` with the trailer lines. Keep the printed lines for Task 12.

---

### Task 10: `OrgView` hosts both scenes; `MapSKView` keys and unlock hooks; the demo flag

**Files:**
- Modify: `Sources/BrahmaMapKit/Views/OrgView.swift`, `Views/MapSKView.swift`, `Sources/BrahmaApp/AppDelegate.swift` (`installMapController` site: the demo controller is built with `model.mapDefaults` and `controller.mode = options.mapSkin ?? .org`), `scripts/map-demo.sh` (usage comment: `--map-skin=office`)
- Test: modify `Tests/BrahmaAppModelTests/OfficeControllerTests.swift`; `Tests/BrahmaMapKitTests/OfficeSceneTests.swift` (factory test)

**Interfaces:**
- Consumes: Task 1 `officeKey`, `officeBoardClick`, `officeOtherClick`, `mode`; Task 5 `MapSceneFactory`, `MapScene`; Task 8 `MapSKView` accessibility.
- Produces:
  - `OrgView` (name kept; doc comment updated: "the map in SwiftUI: the scene for `controller.mode`"): `static let modeFade: TimeInterval = 0.6`; `makeNSView` presents `MapSceneFactory.make(controller.mode, size:)`; `updateNSView` when `controller.mode != (view.scene as? MapScene)?.mode` presents the new scene with `SKTransition.crossFade(withDuration: modeFade)` (0 under reduce motion), calls `present(controller: nil)` on the old scene and `present(controller:)` then `controller.zoomToFit()` on the new; `dismantleNSView` presents nil on whichever scene is shown. Clicks on `.owner` call `controller.officeBoardClick()`; any other click calls `controller.officeOtherClick()`; `onKey` calls `controller.officeKey`.
  - `MapSKView`: `acceptsFirstResponder == true`; `mouseDown` makes the view first responder; `keyDown` forwards each `Character` of `event.characters` (unmodified keys only: no command/control/option) to `public var onKey: ((Character) -> Void)?`; other keys are passed to `super`. `isAccessibilityElement()` stays false, so first-responder status adds nothing to the accessibility tree (Task 11 Step 4 confirms with the inventory diff).
  - `OfficeControllerTests.modeSwitchKeepsReplayAndFollow`: follow an agent, `mode = .office`, `follow` and `camera` unchanged; enter replay, switch mode, `isReplaying` still true and `replay?.time` unchanged.
  - `OfficeSceneTests.factoryPicksSceneByMode`: `MapSceneFactory.make(.org, …) is OrgScene`, `.office` → `OfficeScene`, both `mode` match.

- [ ] **Step 1: Write the failing tests** named above.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "OfficeControllerTests|OfficeSceneTests"`. Expected: FAIL on the factory test; the controller test passes already if Task 1 kept mode independent (keep it as a regression guard).
- [ ] **Step 3:** Implement the view, the key handling and the demo flag.
- [ ] **Step 4:** Run the full `swift test`, then `scripts/make-app.sh debug && scripts/map-demo.sh 50 --map-skin=office --ui-snapshot=.superpowers/ui/office-demo-50.png --smoke-hold=4` and `scripts/map-demo.sh 300 --map-skin=office --ui-snapshot=.superpowers/ui/office-demo-300.png --smoke-hold=4`, and Read both PNGs. Expected: the office in the demo window with the map header (no ORG|OFFICE control yet: the header change is Task 11), figures at 50, lit desks only at 300. Then `scripts/map-demo.sh 50` (no skin) and confirm the org chart still opens.
- [ ] **Step 5:** Commit `feat(map): the map view hosts the org chart or the office by mode; key and Board-click unlock hooks; --map-skin for the demo` with the trailer lines.

---

### Task 11: Header toggle and reveal chip (after Plan P has merged)

**Files:**
- Modify: `Sources/BrahmaApp/Views/Map/MapHeader.swift`, `Views/Map/AgentMapPanel.swift` (`MapChipsOverlay.refresh` passes `controller.officeRevealAt`)
- Test: `scripts/ui-inventory.sh` diff (Plan P's), UI snapshots

**Interfaces:**
- Consumes: Task 1 `officeUnlocked`, `officeRevealAt`, `MapOverlay.chips(…revealAt:)`; the existing `Segmented` control call in `MapHeader`.
- Produces: the `Segmented(options: MapMode.allCases…)` control is shown when `controller.officeUnlocked` (replacing Task 1's `false`), with `label: "Map mode"` and accessibility label `Map mode`; nothing else in the header moves. The chip overlay shows `YOU FOUND THE OFFICE` for 3 s after an unlock.

- [ ] **Step 1:** Confirm `git log main --oneline | grep -i "plan p\|U-1\|approved U-1"` shows Plan P merged and `MissionControlView` hosts `AgentMapPanel`. If not, stop and report (this task waits).
- [ ] **Step 2:** Rebase `plan4c-office` onto `main`; resolve conflicts in `MapHeader.swift` / `AgentMapPanel.swift` keeping P's labels and 4c's additions. Run the full `swift test`. Expected: PASS.
- [ ] **Step 3:** Implement the header condition and the chip.
- [ ] **Step 4:** Add P's `uiInventory` flag to `LaunchOptions.isHarness`. Run `scripts/ui-inventory.sh` and diff against `Tests/Fixtures/ui-inventory/`. Expected: **no change** (the control is hidden while locked; the harness suite never holds an unlock; the map view is not an accessibility element). Run `ScreenInventoryTests`. Expected: PASS. If the diff shows a new element from the map view's first-responder status, drop the keyboard route (`onKey` unwired, `acceptsFirstResponder` back to default, `wordUnlocks*` tests kept on the pure state machine) and record the fallback in the commit body (spec §4.1).
- [ ] **Step 5:** `scripts/make-app.sh debug && scripts/ui-snapshot.sh task4c-map-locked mission` and Read it: no ORG|OFFICE control. Then run the demo (`scripts/map-demo.sh 50`), click BOARD five times: the office fades in, the chip shows, and the `ORG | OFFICE` control appears in the header; switching back to ORG and again to OFFICE cross-fades. Persistence is not checkable from the demo (a harness run uses the volatile suite, spec §4.3); it is covered by `OfficeControllerTests.officeUnlockPersistsAndSwitchesMode` (Task 1).
- [ ] **Step 6:** Manual check (Review Focus 5): with the map shown, click the FIND field and type `office`: the text appears in the field and the map does not unlock; click the map and type `office`: it unlocks. Record both in the commit body.
- [ ] **Step 7:** Commit `feat(app): ORG|OFFICE map mode control once the office is found, with the reveal chip` with the trailer lines.

---

### Task 12: Docs, traceability and final verification

**Files:**
- Modify: `README.md` ("Agent map" section), `docs/superpowers/specs/2026-10-21-brahma-design-v2.md` (append an "After 4c" note under §4.12.3 without rewriting the original), `docs/superpowers/plans/2026-10-21-master-roadmap.md` (row 15 and §2.15: Office replaces Village; Hive not in 4c), `docs/superpowers/specs/2026-10-21-traceability.md` (R-246 "not in 4c, no plan", R-247 "Office view, 4c", R-265 "break room display: 4c")

- [ ] **Step 1:** Write the README "Office" subsection: one sentence that the map has an easter egg (the trigger is not documented, pending the owner's answer to spec §11 Q2; if the owner says to document it, add the two routes); what the office shows (spec §5.2–5.4 in a paragraph); LOD thresholds; Reduce Motion and VoiceOver behaviour; `--map-skin=office`, `scripts/map-demo.sh 50 --map-skin=office`, `scripts/map-snapshots.sh` (now writes `office-*.png`); the perf table rows from Task 9 (machine, chip, macOS, the four `MAP BENCH mode=office` lines) and the on-screen `Brahma --map-demo --map-demo-agents=50 --map-skin=office --map-bench=20` line; replace "Hive and Village arrive in Plan 4c" with the office note.
- [ ] **Step 2:** Update the spec note, the roadmap and the traceability rows.
- [ ] **Step 3: Final verification.**
  1. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: all PASS; perf skipped; `NoKeychainTests` green.
  2. `BRAHMA_PERF=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -Xswiftc -enable-testing --filter MapPerfTests`. Expected: 8 lines, all PASS.
  3. `scripts/map-snapshots.sh`; Read every `office-*.png` once more against spec §5.
  4. `scripts/make-app.sh release && .build/Brahma.app/Contents/MacOS/Brahma --map-demo --map-demo-agents=50 --map-skin=office --map-bench=20` (temp home as `scripts/map-demo.sh` sets it). Expected: `fps ≥ 58`.
  5. `grep -rn "Village" README.md docs/superpowers/plans/2026-10-21-master-roadmap.md` shows only historical mentions marked superseded.
  6. `git diff main --stat -- Sources/BrahmaCore Package.swift THIRD_PARTY_NOTICES.md` is empty.
- [ ] **Step 4:** Commit `docs(map): office view in the README, spec note, roadmap and traceability; 4c final verification` with the trailer lines.

---

## Self-review notes (done inline)

- **Spec coverage:** §4.1–4.3 → Tasks 1 (unlock, fallback, harness suite), 10, 11; §5.1–5.3 → Tasks 3 (rules 1–6), 4, 5; §5.4 → Tasks 2, 5, 7; §5.5 → Task 5 (`lod`), 7 (behaviour), 9 (bench); §5.6 → Tasks 5 (badges), 7 (reduce-motion motion rules), 8 (VoiceOver office-only, observation); §5.7 → Tasks 5 (hits), 7 (follow, highlight), 10 (mode switch keeps replay/follow); §6.2 → Task 2 (incl. `reviewing`); §6.4 → Global Constraints + Review Focus 1; §7 → Task 4; §8 → Tasks 6, 9; §9 → header Sequencing, `MapController+Office.swift`, `OfficeControllerTests`, Task 11 Step 1; §11 (builder check) → folded into Tasks 1, 2, 3, 8, 11; §12 Q2 → Task 12 Step 1.
- **Type consistency:** `MapScene` (Task 5) is what `MapSceneFactory`, `MapBench` (Task 9) and `OrgView` (Task 10) use; `targetRect` is the camera driver's parameter (Task 6) and the office's figure-or-desk rect (Task 7); `officeKey/officeBoardClick/officeOtherClick` (Task 1) are the hooks `OrgView` wires (Task 10); `MapOverlay.chips(…revealAt:)` (Task 1) is what `MapChipsOverlay` passes (Task 11); `OfficeLOD` cases `full, staticFigures, deskOnly` are used in Tasks 5, 7, 9.
- **Proportion:** no task carries a function body; code blocks are test names with assertions.
