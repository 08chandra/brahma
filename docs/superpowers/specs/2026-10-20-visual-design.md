# Brahma visual design — "ops console" (owner: "make the UI look like something from Palantir")

Inspired by the Palantir Gotham/Foundry look (and the open-source Blueprint
design language): a dark, dense, data-first analyst console. Original
implementation — no Palantir names, logos, or assets.

## Principles
- Dark by default (a light variant can come later); information-dense; calm.
- Hairline borders and panels, not cards with shadows. Corner radius 2–3 pt.
- Numbers and IDs in monospace; labels small, uppercase, tracked.
- Color only carries meaning (state, severity, selection) — the chrome is grey.
- Everything looks like an instrument panel: panel headers, toolbars,
  key–value grids, tables with row striping, status chips, sparklines.

## Tokens (implement as `BrahmaTheme` in the app target; SwiftUI `Color`s from hex)
Backgrounds (darkest → lightest):
- `bg0` #0E1217 window background
- `bg1` #141A21 sidebar / rail
- `bg2` #1A2129 panels
- `bg3` #212A33 panel headers, table header, hovered rows
- `bg4` #2A3540 selected row (with accent left bar)
Borders: `line` #2F3A45 (1 px hairline), `lineStrong` #3D4A57
Text: `text0` #E6EBF0 primary, `text1` #A7B3BF secondary, `text2` #6E7C89 tertiary/labels
Accent: `accent` #2D72D2 (selection, focus, primary buttons), `accentDim` #1F4F91
Status:
- running `#32A467` (green), ready `#4C90F0` (blue), blocked `#E76A6E` (red),
  sleeping `#6E7C89` (grey), killed `#404854` (dark grey, strikethrough name)
- warning `#EC9A3C` (orange), success `#32A467`, danger `#E76A6E`
Charts/series: #4C90F0, #32A467, #EC9A3C, #C774E8, #2EC4B6, #E76A6E

## Typography
- UI: SF Pro (system) 12–13 pt body; panel titles 11 pt semibold UPPERCASE,
  tracking +0.6, color `text1`.
- Data: SF Mono 11–12 pt for IDs, handles in tables, timestamps, counts,
  percentages, item keys (e.g. `ENG-142`), usage numbers.
- Line height compact (≈1.25). Avoid large headings; the largest text is the
  company name in the top bar at 15 pt semibold.

## Layout & components
- **Company rail** (far left, 52 pt): square 32 pt tiles with 2-letter monogram,
  `bg1`; status dot (running/paused) bottom-right; unread badge top-right in
  `accent`; selected tile has a 2 pt accent bar on the left.
- **Sidebar** (`bg1`): section headers as tiny uppercase labels; rows 24 pt
  high; `#` and `@` glyphs in `text2`; unread counts as small monospace chips.
- **Top bar** (`bg2`, 40 pt, bottom hairline): company name · sprint/cadence ·
  a segmented usage-mode control (LOW | BALANCED | MAX) · Auto-mode toggle ·
  agent state counts as colored chips (`● 12 RUNNING  ● 30 READY …`) · usage
  meter (`5H 52% ▮▮▮▯▯ · 7D 26% · RESETS 20:00`) in monospace.
- **Panels**: `bg2` with a 28 pt header strip (`bg3`, uppercase title, right-
  aligned tiny actions/filters), 1 px `line` border, 8 pt inner padding.
  Mission control = a 2×1 grid of panels (PREVIEW, AGENT MAP) over an ACTIVITY
  panel; draggable split dividers (1 px lines).
- **Tables** (roster, backlog, approvals, search results): dense 22–24 pt rows,
  zebra striping (`bg2`/#1D252E), monospace for keys/numbers, sortable column
  headers in uppercase `text2`, selected row `bg4` + accent left bar.
- **Status chips**: 18 pt high, radius 2, colored 1 px border + 15% fill of
  the status color, uppercase 10 pt label (RUNNING, BLOCKED…).
- **Activity feed**: log-style lines: `HH:mm:ss` mono `text2` · colored kind
  glyph · `@handle` · text; new lines flash `bg3` for 600 ms.
- **Chat**: compact, Slack-like but flat: avatar = 20 pt monogram square
  colored by role family; handle in `text0` semibold, timestamp mono `text2`;
  @mentions in `accent`; composer is a bordered `bg2` field with a monospace
  hint line.
- **Inspector / detail** (right side): key–value grid (labels `text2`
  uppercase 10 pt, values `text0`, mono for ids/numbers), sections separated
  by hairlines, action buttons as small bordered buttons (primary = accent
  fill).
- **Empty states**: small mono text in `text2` ("NO ACTIVE TURNS"), not
  illustrations.
- **Map placeholder (until Plan 4)**: dark grid background (`bg0` with
  #18202A grid lines every 24 pt), agents as small nodes with status-colored
  rings — this sets the look the Hive/Village views will match.
- Window: hidden title bar / unified toolbar, `.preferredColorScheme(.dark)`,
  no translucency/vibrancy in content areas (solid backgrounds).

## Motion
Subtle and fast (120–200 ms): row hover, panel focus ring, activity flash,
status-chip pulse only for `running`.
