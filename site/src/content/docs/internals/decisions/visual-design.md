---
title: Visual design
description: "The ops-console look: dark, dense and calm; hairline panels, mono data, small uppercase labels, colour only for meaning."
sidebar:
  order: 10
---

## Context

The owner wanted the app to look like a dark, dense, data-first analyst console, the kind of instrument panel an operations team watches all day, rather than a consumer chat app. The spec names the qualities to match and states that the implementation is original: no third-party names, logos or assets.

## Decision

- **Principles.** Dark by default; information-dense and calm. Hairline borders and panels, not cards with shadows; corner radius 2–3 pt. Numbers and ids in monospace; labels small, uppercase and tracked. Colour carries meaning only (state, severity, selection); the chrome is grey. Everything looks like an instrument panel: panel headers, toolbars, key-value grids, zebra tables, status chips, sparklines.
- **Tokens.** Five background steps from the window (`#0E1217`) through sidebar, panels and panel headers to the selected row; two hairlines; three text tones; one accent blue for selection, focus and primary buttons; a status set (running green, ready blue, blocked red, sleeping grey, killed dark grey, warning orange) and a six-colour chart series. The tokens are implemented as `BrahmaTheme` in the app and are the same values this website uses.
- **Typography.** The system UI face at 12–13 pt for body; panel titles 11 pt semibold uppercase in the secondary tone; the system mono at 11–12 pt for ids, handles, timestamps, counts, item keys and usage numbers. Compact line height; no large headings: the largest text is the company name in the top bar.
- **Layout and components.** A company rail of square monogram tiles; a sidebar of tiny section labels and 24 pt rows; a 40 pt top bar with the company name, the usage-mode control, agent state counts as chips and a monospace usage meter; panels with a 28 pt header strip; dense zebra tables; 18 pt status chips with a coloured border and a 15 % fill; a log-style activity feed; a flat, compact chat; a key-value inspector; empty states as small mono text, never illustrations; a dark grid for the agent map.
- **Motion.** Subtle and fast, 120–200 ms: row hover, panel focus ring, the activity flash, a status-chip pulse only for running.

## Consequences

- The app and this site share one token sheet, so a screenshot and the page around it read as one system.
- "Colour only for meaning" rules out decorative accents: the one accent marks selection, focus and the primary action; status colours mark status.
- Because the tertiary text tone sits below the AA contrast threshold on every surface, it is used only for marks, disabled states and large text, never for body or label text.

## Source

`2026-10-20-visual-design.md`
