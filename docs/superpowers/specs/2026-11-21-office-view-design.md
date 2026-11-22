# Office view (Plan 4c) — design

**Status:** draft for the owner's review (builder check applied). **Date:** 2026-11-21.
**Supersedes:** the "Village" skin in `2026-10-21-brahma-design-v2.md` §4.12.3 and master roadmap §2.15. The Hive (3D) skin is not in this plan.

## 1. Intent

The agent map (Plan 4b) is an org chart: an instrument-panel view of who reports to whom and what is moving between them. The owner wants a second way to look at the same company, as a place: an office floor where the agents are workers at desks, typing, walking to the review room, pinning notes on a team board, waiting outside the board room for the owner.

The owner's words, binding:
- "I don't want the Clash of Clans look, but make it look like an office instead where workers are working etc."
- It is an **easter egg**: hidden until found, then a toggle beside the org chart.
- **Original art only.** Nothing imitates an existing game's characters, art or look.

Why build it at all: the org chart answers "what is the structure"; the office answers "what does the company feel like right now" at a glance (how many screens are lit, who is at the review table, who is stuck at the board room door). It is also the home the v2 spec promised for the cosmetic rewards (§4.15: ☕ 🍜 🏆 🔥 ⭐ and a break room), which the ops-console views only show as text chips.

The office is **exempt from the ops-console brief** (v2 C-25, C-26): it may be warm, lit and playful, within the rules below.

## 2. Goals, non-goals, anti-goals

**Goals**
1. One more renderer on the same live `MapModel` and `MapController`: no new engine data path, no new Store query, no migration.
2. Agent state and work become animation (§5), readable at a glance in the app's dark theme.
3. Every map feature keeps working in the office: click → the same agent detail, hover card, team card, search and jump, follow, zoom, replay, pop-out, the context menu and vacancies.
4. Smooth (p95 frame ≤ 16.7 ms) at 50 agents with full animation; readable and under budget at 300 with graceful degradation.
5. Honours Reduce Motion and VoiceOver. Agent-supplied text is plain, cleaned text.
6. Hidden until discovered; once discovered, a persistent toggle.

**Non-goals**
- Hive / 3D (dropped from 4c; may return as its own plan).
- Any new data the map does not already read (the inbox is counted, not read).
- A separate theme or light mode for the app. The office is built from `ThemeHex` tokens so a light variant is a token swap later.
- Physical realism: walking speed, collisions, pathfinding around every chair.

**Anti-goals (a failure even if it works)**
- Looks like a known game (building-game sprites, chunky cartoon outlines, loot-style effects).
- Changes the engine, scheduling or prompts in any way; perks stay cosmetic.
- Degrades the org chart's performance, tests or behaviour.
- Shows raw agent text, or more agent text than the org chart shows.
- Shows up for an owner who has not found it (an inventory change on the frozen Plan P screens).

## 3. Constraints

- Swift 6, macOS 14, SwiftPM; the `BrahmaCore` → `BrahmaAppModel` → `BrahmaMapKit` → `BrahmaApp` layering and the 4b global constraints (`docs/superpowers/plans/2026-10-21-plan4b-maps.md`, "Global Constraints") all apply: no AppKit/SpriteKit outside `BrahmaMapKit` and `BrahmaApp`; colours only from `ThemeHex`; every drawn string is `MapText.clean` output; tests never touch the Keychain; perf asserts only under `BRAHMA_PERF=1 -c release`.
- No third-party assets, fonts, images or packages. `THIRD_PARTY_NOTICES.md` is unchanged.
- Agent states stay `ready, running, blocked, sleeping, killed`; paused non-killed renders like sleeping.
- `MapModel`'s queue constants (durations, caps, aggregate thresholds) are unchanged, so the office and the org chart behave the same under bursts.
- Polls only while a map is visible, exactly as 4b (the office changes nothing in `MapController.start/stop`).
- The Plan P screen inventory (`ScreenInventoryTests`) is frozen: the office adds no visible element to any screen until the owner has unlocked it.

## 4. The easter egg

### 4.1 Discovery (controller's call; the owner may change it)
Two routes, either unlocks:
- **Type `office`** while the map has keyboard focus (click the map first). `MapSKView` accepts first responder and feeds key characters to a pure `OfficeUnlock` state machine: the letters must arrive within 2 s of each other; any other key resets.
- **Click the BOARD card five times** within 3 s. A left click on Board does nothing today (only the right-click menu), so this conflicts with nothing. In the office the Board room door is the same target.

On unlock: the view cross-fades to the office (0.6 s) and a chip at the bottom left reads `YOU FOUND THE OFFICE` for 3 s (reuses the map chip style). The unlock is **persisted per owner** (`UserDefaults` key `brahma.map.office.unlocked`, this Mac's user), independent of company. There is no re-lock in 4c (`defaults delete` works for a developer); a small "Hide the office" item can come later if the owner asks.

The keyboard route needs the map view to accept first responder. That does not add an accessibility element (the view stays `isAccessibilityElement == false`), so the frozen screen inventory is unaffected; the wiring task verifies this with an inventory diff, and if the diff is not empty the keyboard route is dropped and the Board clicks stay (controller's call). A stored mode of `office` for a company whose owner has not unlocked falls back to `org`.

### 4.2 After discovery
The map header shows the existing `Segmented` control `ORG | OFFICE` (4b built it for the day `MapMode` had a second case; it appears only when `controller.officeUnlocked`). The chosen mode is stored per company as 4b already does (`brahma.map.mode.<companyId>`). The pop-out window shows the same mode as the inline panel (the mode lives on the controller).

### 4.3 Developer access, and harness runs never see the unlock
`--map-skin=office` (a `LaunchOptions` flag, used with `--map-demo`, `--map-bench` and `--ui-snapshot`) opens the demo in the office without unlocking or persisting anything. `scripts/map-demo.sh 50 --map-skin=office`.

**Harness policy (controller's call):** a harness run (`--smoke-test`, `--ui-snapshot`, `--map-demo`, `--map-bench`, and Plan P's `--ui-inventory`) gives the map controller a volatile `UserDefaults` suite (`brahma.harness.<pid>`, cleared at launch) instead of `.standard`, so it never reads a developer's unlock and never writes one. Snapshots, inventories and benches are therefore the same on every Mac, and `--map-skin=office` is the only way a harness run shows the office. A developer who unlocks in `scripts/map-demo.sh` sees the office only for that run.

## 5. What the owner sees

### 5.1 Projection and look
**3/4 top-down "dollhouse" view**, not true isometric. Floor plan rectangles, with every piece of furniture given a short front face (6 pt, darker) and figures drawn upright; depth is y-sorting. Chosen because text stays horizontal and legible, hit tests stay axis-aligned rectangles, layout reuses `MapRect`, and no projection math enters routes or the camera. (True isometric was rejected: diamond tiles make handles unreadable below zoom 1 and every walking path needs projecting.)

**A night office lit by its screens.** The floor is `bg0` with a faint 24 pt tile seam (`mapGrid`, the app's map lattice), so the office sits in the same world as the org chart. Rooms have `bg2` floors and `line` walls; pods have a carpet tint (department colour at 12 % alpha). Light comes from the desks: a running agent's monitor glows in the status colour and throws a soft radial glow on the desk; a blocked desk glows `blocked`; a ready desk is dim (`ready` at 40 %); a sleeping desk is dark with the lamp off. So the state legend is "which desks are lit, and in what colour" — readable at any zoom, and it is the org chart's status colours.

Scale: the whole floor is one `SKScene`; zoom range 0.15…3 as the org chart. Handles show from zoom 0.5, roles and desk items from 1.2 (the same thresholds as `OrgScene.textZoom` / `itemZoom`).

### 5.2 Floor plan (`OfficeLayout`, a pure function of the `MapModel`)
```
┌───────────────┬──────────┬──────────┬───────────────────┐
│  BOARD ROOM   │ CxO off. │ CxO off. │   CEO (corner)    │  top wall: owner + executives
├───────────────┴──────────┴──────────┴───────────────────┤
│  wing: Director A        │  wing: Director B            │  one wing per director (or per
│  ┌pod──┐ ┌pod──┐ ┌pod──┐ │  ┌pod──┐ ┌pod──┐             │  manager when there are no directors)
│  │▭▭ ▭▭│ │▭▭ ▭▭│ │▭▭ ▭▭│ │  │▭▭ ▭▭│ │▭▭ ▭▭│             │  pods: one per manager with reports
│  │▭▭ ▭▭│ │▭▭   │ │▭▭ ▭▭│ │  │▭▭ ▭▭│ │▭▭ ▭▭│             │  desks in facing pairs; manager desk at
│  └─────┘ └─────┘ └─────┘ │  └─────┘ └─────┘             │  the pod head; HIRING desk for a vacancy
├──────────────┬───────────┴───────────┬──────────────────┤
│  BREAK ROOM  │     REVIEW ROOM       │    MAIL ROOM     │  bottom strip: shared rooms
└──────────────┴───────────────────────┴──────────────────┘
```
- **Board room** (top left): the owner. Its table shows the open Inbox asks as folders (count only; up to 9, then `9+`). Clicking it hits `.owner` (the same context menu). Agents waiting on the owner stand at its door.
- **Executive offices** along the top wall: the CEO gets the largest, in the corner, with a glass wall; other C-suite agents get single offices. A single-office agent has a desk inside and the same desk behaviour.
- **Wings and pods.** The assignment rule covers every tree shape (controller's call, pinned so snapshots are stable):
  1. Walk the tree in `OrgTree.order`. The Board is the board room; the CEO (tier `.ceo`) the corner office; other `.csuite` agents exec offices; `.director`s a director office at the head of their wing.
  2. **Every agent with direct reports that are not themselves managers-with-reports gets a pod** holding those direct reports (ICs and childless managers). The pod's owner sits at the head desk, unless the owner has an office (CEO, C-suite, director), in which case the head desk is omitted and the pod is titled by the owner's team or department. So a 5-agent company (CEO + 4 ICs) is a corner office and one pod.
  3. A manager whose reports include another manager-with-reports does not nest: the sub-manager's pod is a sibling placed right after its parent's pod (tree order). Pods are rectangles side by side, never inside one another.
  4. **A wing per director**: in tree order, the director's office, the director's own pod (if any), then the pods of every manager in the director's subtree, flattened.
  5. Pods whose owner is under no director (the CEO's or an executive's direct managers, root managers) form one **floor wing** after the director wings, with no office, titled `FLOOR`.
  6. Agents with no manager and no executive kind (pre-3a companies, several roots) go in department pods (`Department.of`) at the end of the floor wing.

  Pods hold desks in two facing columns, the head desk alone at the top. Pod label: the team card title (`TEAM-1 · ENGINEERING`) or the department title, mono 10 `text2`, on a department-colour carpet tint. Clicking the label hits `.team(managerId)` for a pod with a manager head; a pod without one has no team hit.
- **Vacancies**: a dashed, unlit desk with a `HIRING` placard in its manager's pod (under Board: a desk in the board room's anteroom). Hits `.vacancy(id)`; the same actions and the same provider/org rule as 4b.
- **Former agents** (only with SHOW FORMER): a dark desk with a cardboard box on it and no figure; the handle struck through, as the org card.
- **Shared rooms** (bottom strip): the **review room** (a long table with chairs; reviewers and meeting participants sit here), the **break room** (a counter, a sofa, and a shelf: the "wall of fame"), the **mail room** (a counter with parcels: items being checked or merged).
- **Collapse does not exist in the office.** Every living agent has a desk (300 desks fit in roughly 2 600 × 1 500 pt). `MapController.collapsed` returns the empty set while `mode == .office`, so `frame(now:)` resolves every event to the real agent, not a visible ancestor.
- **Order and stability**: pods and desks are placed in `OrgTree.order`, so a re-layout after a hire moves as little as possible, and a layout is a deterministic function of the tree (snapshot tests depend on this). A desk whose rect moved glides there in 0.4 s (the org card rule); its figure walks.

### 5.3 Workers and desks (original procedural art)
Everything is drawn in code with CoreGraphics into cached `SKTexture`s at 2× (as `MotionTextures` and `LabelTextures` already do) and tinted with `SKSpriteNode.color` / `colorBlendFactor`; see §7 for why.

- **Desk**: 36 × 24 pt top (`bg3`), 6 pt front face (`bg2`), a monitor (10 × 7) whose screen is the state light, a lamp whose glow is on for `running`/`ready`/`blocked` and off for `sleeping`; chair in front. No wood grain, no outlines thicker than 1 px: flat, token-coloured shapes in the app's language.
- **Figure**: a 10 × 16 pt "peg" — a rounded body in the agent's department family colour (`MapPalette.department`) and a round head in `text1`. No face, no limbs beyond two 2 pt "hands" that alternate when typing. Two frames for typing, two for walking, one for sitting, one for standing with a raised hand. Trust tier (when a provider supplies it) is a 1 px collar in `ThemeHex.trustTier`.
- **Desk items** (cosmetic, ≤ 2 per agent, from `MapAgent.perks`, each ≤ 8 cleaned characters): drawn as 10 pt emoji glyph textures (`LabelTextures.emoji`) on the desk corner — a mug, a bowl, a trophy, a flame, a star — exactly the strings the provider sent. Shown from zoom 1.2.
- **Break room wall of fame**: up to 6 perk glyphs from the agents who hold them (deterministic order: tree order), rebuilt on structure change.
- **Speech bubbles**: a 12 pt rounded bubble with one glyph drawn as a path: `!` (blocked), `…` (waiting on the owner), `✓` (checks passed, 1 s).
- **Notes and parcels**: a 7 × 9 pt paper (`text0`) for a DM, a 9 × 9 folder (`warning`) for a hand-off, a 10 × 8 parcel (`bg4` with a `warning` strap) in the mail room.

### 5.4 State and work → animation
Each `MapAgent` gets an `activity`, computed in `MapModel` (pure, tested) from the agent and the item facets the controller already has in memory:

| Situation (data) | Activity | At full LOD | At "desk state only" LOD |
|---|---|---|---|
| `running`, no review/meeting | `.typing` | at desk, hands alternate 4 Hz, screen lit `running`, glow pulses 0.6–1.0 at 1 Hz | screen lit `running` |
| `running` or `ready`, and the agent is the **reviewer** of an item `inReview` | `.reviewing` | walks to a review-room chair, sits; desk screen dim | screen dim, chair marker in review room |
| participant of a `Meeting` (4b sprints) | `.meeting(id)` | walks to the review room; the room's door light is on and shows the meeting title | door light on |
| `blocked`, blocker is **the owner** (`Blocker.owner`) | `.waitingOnOwner` | stands at the board room door with a `…` bubble; desk screen `blocked` | screen `blocked`, door marker |
| `blocked`, other blockers | `.blocked` | sits, raised hand, `!` bubble, screen `blocked` | screen `blocked` |
| `ready` (idle) | `.idle` | sits, screen dim; every 20–40 s (seeded by agent id) strolls to the break room and back (full LOD only, ≤ 50 agents) | screen dim |
| `sleeping` or paused | `.away` | empty chair, lamp and screen off | screen off |
| `killed` (SHOW FORMER) | `.gone` | box on a dark desk | box |
| owner's item has `mergeState != .none` or its latest check run is `running`/`queued` | `.shipping` (flag, in addition to the above) | a parcel with the item key sits on the mail-room counter; `passed` stamps it (`✓` bubble, 1 s), `failed` gives it a `blocked` strap | parcel |

Events (`VisualEvent`, from the same throttled queue as the org chart, same durations):

| Event | Office visual |
|---|---|
| `.message` a→b | a note travels a→b along a corridor route (`OfficeLayout.route`) in 0.9 s; the sender's figure does a short hand gesture. Owner ⇄ agent routes start/end at the board room door. Aggregate mode (≥ 30 msg/s): notes become the org chart's dots, no gesture. |
| `.broadcast` | a note is pinned on the sender's pod board (a small board at each pod head) and fades over 0.6 s; with no pod (an executive) a ring "chime" at their office door. |
| `.handoff` a→b (or a→nobody) | a folder travels a→b in 1.4 s; with no recipient it travels to the mail room. |
| `.stateChange` | the desk light cross-fades to the new colour in 0.2 s and the figure's activity changes (walks if the new activity has a destination). |
| `.phaseChange` (new, §6.2) | mail-room parcel appears, is stamped or removed. |
| `.hire` | the new desk slides in from the pod aisle in 0.4 s with a `text0` balloon on a 1 px string that drifts up and fades over 2 s. |
| `.leave` | 1.5 s: the figure fades, the desk items slide into a box, the lamp goes out; then the layout closes the gap (layout held while a leave plays, as 4b does). |
| `.reorg` | the figure walks from the old desk to the new one while both desks glide to their new rects. |
| `.promotion` | a trophy pops on the desk (the org chart's chip pop, 1.2 s). |
| `.meetingStart` / `.meetingEnd` | review-room door light on/off with the meeting title; participants walk in/out via `.meeting`. |

Walks take 0.8 s (ease in-out) whatever the distance; figures slide along the corridor route. A figure whose destination disappears (the agent is killed, its desk moves) retargets on the next frame; a note whose end disappears retargets to the sender's desk, as 4b particles retarget on collapse.

### 5.5 Level of detail (deterministic, by living-agent count)
| Living agents | LOD | What changes |
|---|---|---|
| ≤ 50 | **full** | everything in §5.4 |
| 51–150 | **static** | no walking (figures appear at their destination), no typing frames, no idle strolls, no glow pulse; notes and events still play |
| > 150 | **desk state only** | no figures; desks show state by light; notes are 4b dots; bubbles become 4 pt markers; the review-room and board-room doors show counts |

Thresholds are `OfficeScene.fullLOD = 50` and `.staticLOD = 150`. LOD is by count, not by measured frame time, so snapshots and tests are reproducible; a frame-time governor is a possible follow-up. Below zoom 0.5 desks lose text; below 0.3 figures hide (they would be a pixel).

### 5.6 Accessibility
- **Reduce Motion** (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, observed for changes): no walking, typing, strolls, pulses or travelling notes. Each desk shows a **state badge** (the org chip style: status colour, one glyph: `▶` typing, `✎` reviewing, `✋` blocked, `…` waiting, `⏾` away) and events become 0.2 s cross-fades. Same for `--ui-snapshot` runs when the system setting is on.
- **VoiceOver**: `MapSKView` exposes accessibility children built from the scene (`MapAccessible` protocol): one element per desk and room with label `@handle, role, state, item` (all cleaned text) and the desk's frame; Board room `Board room, owner, N open asks`; rooms by name. Capped at 300 elements, rebuilt on structure change and at most once a second. **Office only in 4c** (controller's call): giving the org chart the same elements would add hundreds of entries to Plan P's frozen screen inventory before any unlock, which the anti-goals forbid. The protocol is written so `OrgScene` can conform in a later plan with an approved inventory update. After an unlock the inventory on that Mac does change, but harness runs never see an unlock (§4.3), so `ScreenInventoryTests` is unaffected.
- Colour is never the only carrier: the lamp (on/off), the bubble glyph and the badge carry state as well as the screen colour.

### 5.7 Interaction (unchanged behaviour, new targets)
| Action | Target |
|---|---|
| click a desk / figure | `.agent(id)` → the same agent detail (`controller.handle`) |
| double click | follow (camera tracks the figure, or the desk at desk-only LOD) |
| hover | the same `MapHoverCard` |
| click a pod label | `.team(managerId)` → the team card |
| click Board room | `.owner` (left: nothing except the unlock counter; right: menu) |
| right click | `MapMenu.entries(controller.actions(for:))`, unchanged |
| search / jump | highlight ring around the desk for 1.5 s |
| zoom-to-fit | fits the whole floor |
| replay | the same scrubber; activities follow the replayed states; item phases are not replayed (not in the timeline), so replay shows typing/away/blocked only |
| pop-out | the same window; mode follows the controller |

## 6. How it is built (what the owner decided and the controller fixed; the rest is the builder's)

### 6.1 Layers
- `BrahmaAppModel/Map`: `MapMode.office`; `OfficeUnlock` (pure state machine); `OfficeLayout` (pure: rooms, pods, desks, routes, size); `OfficeActivity` and the item facets in `MapModel`; `MapController.officeUnlocked`, `unlockOffice()`, `collapsed` empty in office mode; `LaunchOptions.mapSkin`.
- `BrahmaMapKit/Office`: `OfficeTextures` (procedural art), `OfficeScene` (+ `OfficeFigures.swift`, `OfficeMotion.swift`), `MapAccessible`; `OrgView` hosts either scene and cross-fades on mode change; `MapSKView` gains key handling, the unlock hooks and accessibility children; `MapBench.run(mode:)`.
- `BrahmaApp`: `MapHeader` shows the segmented control when unlocked; the reveal chip; `Harness` honours `--map-skin`.
- Tests: `OfficeLayoutTests`, `OfficeUnlockTests`, `MapModelTests` (activity), `OfficeSceneTests` (snapshots via `MapSnapshotter`, hit tests, LOD, reduce motion, retargeting), `MapPerfTests` (office rows), `LaunchOptionsTests`.

### 6.2 Data the office needs that the org chart did not draw
All of it is already in `Snapshot` in memory; nothing new is read from the Store.
- `MapInputs.itemPhases: [String: MapItemPhase]` (agent id → the phase of the owner's newest active item: `working`, `inReview`, `checking`, `merging`, `passed`, `failed`), derived in `MapController.inputs(for:)` from `WorkItem.status`, `WorkItem.mergeState` and `WorkSnapshot.latestRuns`; `MapInputs.openAsks: Int` from `WorkSnapshot.inbox.count`.
- `MapAgent.activity: OfficeActivity`, `MapAgent.waitingOnOwner: Bool` (from `Agent.blocker` being `.owner`), `MapAgent.shipping: MapItemPhase?`.
- `VisualKind.phaseChange(from:to:)`, emitted by `MapModel.diff` when an agent's phase changes; duration 0.2 s, priority beside `.stateChange`, not traffic. The org scene treats it as a content refresh and draws nothing.
- `MapInputs.reviewing: Set<String>`: the reviewer ids of items whose `status == .inReview` with a living owner and reviewer, computed in `inputs(for:)`. (`DottedLinks.reviewers` cannot serve: it includes `inProgress` items and carries no status.)
- The synthetic company (`SyntheticCompany`) gets phases, reviewers, a few perks and open asks, so the demo and the snapshots show the review room, the mail room and the break room.
- `MapHeader` shows the `ORG | OFFICE` control on `controller.officeUnlocked`, not on `MapMode.allCases.count > 1` as 4b wrote it: that one line is what keeps the egg hidden once the case exists.

### 6.3 Pinned numbers (each a `static let` on the owning type)
| Constant | Value | Owner |
|---|---|---|
| Desk top / front face / chair | 36×24 / 6 / 12×8 pt | `OfficeLayout.desk` |
| Pod: columns / desk gap / aisle / padding / head (manager) row | 2 / 8 / 16 / 12 / 36 pt | `OfficeLayout.pod` |
| Corridor between pods / between wings / rooms strip height | 32 / 48 / 140 pt | `OfficeLayout` |
| Rooms (w×h): board / CEO / exec / director / review / break / mail | 200×120 / 160×120 / 120×100 / 120×100 / 260×120 / 180×120 / 160×120 | `OfficeLayout.rooms` |
| Figure | 10×16 pt; hides below zoom 0.3 | `OfficeTextures.figure`, `OfficeScene.figureZoom` |
| Walk duration / desk glide | 0.8 s / 0.4 s | `OfficeScene.walkDuration`, `moveDuration` |
| Typing frame rate / glow pulse | 4 Hz / 1 Hz, 0.6–1.0 | `OfficeScene` |
| Idle stroll interval | 20–40 s, seeded by agent id | `OfficeScene.strollRange` |
| LOD thresholds (living agents) | full ≤ 50, static ≤ 150, desk-only above | `OfficeScene.fullLOD`, `.staticLOD` |
| Text zoom thresholds | handles ≥ 0.5, roles and items ≥ 1.2 (as `OrgScene`) | `OfficeScene.textZoom`, `.itemZoom` |
| Unlock: word / per-key window / Board clicks / click window | `office` / 2 s / 5 / 3 s | `OfficeUnlock` |
| Reveal chip / cross-fade | 3 s / 0.6 s | `OfficeScene.revealDuration`, `OrgView.modeFade` |
| Board room ask folders | up to 9, then `9+` | `OfficeScene` |
| Wall of fame glyphs | 6 | `OfficeScene.fameLimit` |
| VoiceOver elements | ≤ 300, rebuilt ≤ 1 Hz | `MapSKView.accessibilityLimit` |
| Perf targets | p95 ≤ 16.7 ms: 50 agents full LOD at 50 msg/s with bursts; 150 static; 300 desk-only | `MapBench`, `MapPerfTests` |
| Persistence keys | `brahma.map.office.unlocked` (owner), `brahma.map.mode.<companyId>` (4b) | `MapController` |

### 6.4 Safety
- Strings drawn in the office: handle, role, item key/title, blocker line, perks, team title, meeting title, vacancy title and note. All are `MapAgent`/`MapModel` fields that are already `MapText.clean` output (and redacted by the controller where 4b redacts). The office adds no string source.
- Counts (asks, agents in a room) are integers formatted by the app.
- No new Store access, no new migration, no file or network access; the easter egg state is one `UserDefaults` boolean.
- A synthetic (demo) controller stays read-only; unlocking from the demo is allowed and persists (it is the same owner), but the demo never writes to any store.

## 7. Art approach (decided)

**Procedural, vector-drawn in code** into cached textures (`OfficeTextures`), the approach 4b already uses for cards, dots and rings.

Why this, over the alternatives:
- **Original by construction.** Shapes drawn from the app's own tokens cannot imitate anyone's sprites, which is the owner's hardest rule. A CC0 pack would need licence verification per file and would still look like someone else's game; it would also fight the dark ops palette.
- **One colour source stays true.** Every pixel comes from `ThemeHex`, so the office matches the org chart and a future light theme is a token change, not a redraw. Pre-rendered PNGs would freeze colours.
- **No asset pipeline.** SwiftPM resources in a library need `Bundle.module`, which the repo avoids; a build-time sprite script adds a toolchain step for about twenty 36-pt sprites. Code-drawn textures need neither.
- **Cheap at runtime.** Textures are drawn once at 2× and shared; a figure is one `SKSpriteNode` with a tint, so 300 desks are a few hundred quads from a handful of textures (the same budget logic as the org chart's 300 cards).

Review aid: `OfficeSceneTests.tileSheet` renders every texture variant on one sheet (`office-tiles.png`) so a human can read the art without running the app.

## 8. Performance plan
- Nodes: one `SKSpriteNode` per desk part (top, face, screen, lamp glow) and per figure; pooled by id and reused across rebuilds, as `OrgCardNode`s are. Notes come from `MotionParticle`'s pool (new textures, same pool). Walls and carpets are one batched texture per room type (as `DottedTexture` batches curves).
- Rebuilds only on `structureRevision`, collapsed-set or content events, plus the 0.25 s refresh, as `OrgScene`.
- `MapBench.run(agents:mode:)` drives the office offscreen; `MapPerfTests` adds three office rows (50 full, 150 static, 300 desk-only) and `--map-bench` with `--map-skin=office` measures on screen. Numbers go into the README table.
- The org chart's perf tests must still pass unchanged (the office adds no work to the org path).

## 9. Sequencing
- **Depends on main:** 4b (`BrahmaMapKit`, `MapModel`, `MapController`, `MapBench`, `MapSnapshotter`), all on main.
- **Plan P** (`.claude/worktrees/plan-refactor-polish/.../2026-11-21-planP-polish.md`) wires the map into Mission Control (U-1) and freezes the screen inventory. The office is invisible until unlocked, so it does not disturb the inventory. P also edits `MapController.swift` (Task 7: polls on change topics instead of its timer) and `MapControllerTests.swift` (Task 2: `live()` takes a clock). 4c's controller edits are small and kept apart: three stored properties and the `collapsed` guard in `MapController.swift`, two lines in `inputs(for:)`, everything else in a new `MapController+Office.swift`; new tests go in a new `OfficeControllerTests.swift`, not in `MapControllerTests`. The final wiring task touches `MapHeader` and `AgentMapPanel`, which P polishes. **Recommended:** start 4c now against main, in parallel with Plans S and R; rebase at the next task boundary when P merges, and in any case before the wiring task. The 4c perf rows are independent of P's polling change: `MapBench` calls `pollSynthetic()` on a virtual clock.
- **Plan R** restructures `BrahmaCore` into layers under an umbrella; 4c imports `BrahmaCore` and `BrahmaAppModel` only, adds no target and no migration, so R does not conflict.
- **Plan 3b** (people, perks) is not required: perks and trust arrive through `MapPeopleProviding` when 3b lands; until then the demo shows synthetic perks and a live company shows none.

## 10. Left to the builder
- Exact rectangles inside rooms (table, chairs, counter), the corridor routing details beyond "Manhattan along corridors, never through a desk", and the balloon/bubble paths.
- The glyph shapes in bubbles and badges.
- How `OrgView` names its two scenes internally and the exact `SKTransition`.
- Test fixture sizes beyond the pinned 12 / 50 / 150 / 300.

## 11. Builder check (2026-11-21) — calls made
A fresh builder read this document and asked four questions; all were settled here as the controller's calls (none changes what the owner asked for), and two spec claims were corrected:
1. VoiceOver elements are office-only in 4c (§5.6), because of Plan P's frozen inventory.
2. Harness runs use a volatile defaults suite and never see or write the unlock (§4.3); a stored `office` mode without an unlock falls back to `org` (§4.1).
3. The desk assignment rule now covers every tree shape (§5.2, rules 1–6).
4. Sequencing against Plan P's `MapController` edits (§9): small in-place edits, the rest in extension files; rebase at a task boundary when P merges.
Corrections: `reviewing` is a new `MapInputs` field, since `DottedLinks.reviewers` carries no status (§6.2); the header's `allCases.count > 1` condition must become `officeUnlocked` (§6.2).

## 12. Open questions for the owner (with the controller's recommended answers)
1. **Trigger:** keep both routes (type `office`, or five clicks on BOARD)? *Recommended: yes, both; they share one state machine and one test file.*
2. **README:** mention the easter egg? *Recommended: one sentence ("the map has an easter egg") without the trigger; the trigger lives in this spec and the plan.*
3. **Re-lock:** is a "Hide the office" item wanted in 4c? *Recommended: no; add later if asked.*
4. **Idle strolls** (ready agents visiting the break room at full LOD): keep, or desks only? *Recommended: keep; it is what makes the floor feel alive at ≤ 50 agents, and it is off under Reduce Motion and above 50 agents.*
5. **Perks in the break room** ("wall of fame", up to 6 glyphs): wanted, or desk items only? *Recommended: keep; it is the §4.15 break room, cosmetic, and empty until a provider sends perks.*

## Corrections (4c build, 2026-11-22)
These notes record the controller's rulings during the build. The text above is left as written; where they differ, these notes win.
- **R33, accessibility of the map view (§4.1, §5.6).** The map view keeps SKView's own accessibility-element answer, which is an AXGroup, in every mode. It does not force `isAccessibilityElement == false`. "Stays false" was a wrong premise: a plain SKView does not answer false, and forcing it would drop the view from its parent's accessibility children and change the frozen inventory. Keeping parity with a plain SKView leaves the inventory unchanged. The office adds children only when its scene is shown.
- **R13, floor size (§5.2).** The floor wraps its wings adaptively toward a 5:3 shape instead of at a fixed width. The minimum is max(1600, the shared-rooms strip width), widened in 32 pt steps. 300 agents give about 2656×1364 pt.
- **R16, pod titles (§5.2 rule 2).** A pod with no team card is titled, and tinted, by its members' most common department, not by its owner's department. The team-card title still wins whenever one exists.
- **R26, pod-label hits (§5.2, §5.7).** A pod label is a `.team` hit only when the pod has a head desk. The label of a pod owned by an agent with an office hits nothing.
- **R10, Board clicks (§4.1).** The Board clicks use a sliding window: the office unlocks when the last five clicks fall within 3 s, so a stray earlier click never delays it.
- **R15, the live demo (§6.2).** The live `--map-demo` office does not yet have item phases, reviewers, perks or open asks. The edit to the demo controller that would feed them was denied, and they stay out until the owner approves it. The scene tests and snapshots build `MapInputs` from `SyntheticCompany` directly, so they still show the review, mail and break rooms.
- **Final review M3, wing titles (§5.2 rule 5).** Wings are not titled, and the `FLOOR` title of the floor wing is not drawn; the pods carry the titles. A director's wing is identified by its office, which is titled with the director's handle (cleaned, cut to fit left of the door); an executive's office keeps its role.
- **Final review M6, flat orgs (§5.2, §5.5).** A flat org (many roots in one department) gives one tall, two-column department pod, so "300 desks fit in roughly 2 600 × 1 500 pt" holds for treed orgs only. A later plan may split pods beyond about 24 members.
