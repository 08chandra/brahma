---
title: Agent map
description: A live org chart of one company, drawn from the same snapshot the rest of the app reads. Cards, states, traffic along the reporting lines, folding, search, vacancies, replay and bursts.
sidebar:
  order: 13
---

## What it is

The agent map is a live org chart of one company. It is drawn from the same snapshot the rest of the app reads, so what it shows is what the engine knows. Mission Control carries an agent-map panel, and the full map opens in its own window (menu **Window → Agent Map**).

Messages travel as particles along the reporting lines. Hires, terminations, reorgs and promotions are animated. The last hour can be replayed.

## How it works

**What it shows.** Board at the top, then executives, directors, managers and ICs, in team bands. Each card has the agent's handle, role, a state (`ready`, `running`, `blocked`, `sleeping`, `killed`; paused agents look like sleeping), its current work item and, when blocked, the blocker. Open seats are `OPEN · <ROLE>` cards. A dashed line runs from a reviewer to the owner of every item that is in progress or in review.

**What moves.** Messages and broadcasts travel as particles along the reporting lines, hand-offs are labelled with the item key, and a sprint meeting is a hull drawn around its participants.

**Controls.**

- Above `60` active agents, managers (and directors whose reports are all ICs or vacancies) start folded into stubs (`▸ N REPORTS`). Click a stub or a manager's `▾` to open or fold a subtree.
- Search and jump to an agent, follow an agent, zoom to fit, show former agents.
- Vacancies: the map's context menu opens, withdraws and fills seats. **Fill asks for confirmation**, because it starts a paid agent. Vacancies that come from a provider are display-only.
- Replay: the last hour can be scrubbed and played back at speed. Meetings and reorgs are not replayed. When the hour holds more than `20 000` messages or state changes, the newest are kept and the replay is shown as truncated. A replay never writes: vacancy actions wait for LIVE.
- Pop-out window and full screen.

**Bursts.** Messages between the same pair within half a second are coalesced. Above `30` messages per second the map switches to aggregate mode: no particles, the edge pulses instead, with an `AGGREGATE · <rate> MSG/S` label. It drops back below `20`. The particle queue is capped at `400`, oldest traffic first.

**Redaction and windows.** Item titles and blocker reasons are redacted by the store's redactor and cleaned before they are drawn. Vacancy notes are owner-only and redacted. `system` traffic is not drawn. After a database restore the map starts fresh. While its window is closed the map keeps its chart current but queues no animations. Actions taken in the map window (select an agent, message, add or fill a vacancy, hire) bring the main window to the front, where they open.

**Demo.** `Brahma --map-demo --map-demo-agents=300` runs the map against a read-only synthetic company in a temporary home, with no write actions.

## In the app

<img src="/screenshots/map.png" srcset="/screenshots/map@2x.png 2x" width="1600" height="1000" alt="Mission Control with the agent-map panel (Initech: a 12-seat org, 6 agents seated)" loading="lazy" decoding="async" />

*Mission Control with the agent-map panel (Initech: a 12-seat org, 6 agents seated).*

The panel shows a card per agent with its handle, role and state. The full map, with the reporting lines, traffic and replay, is the **Agent Map** window.

## From the CLI

The map is an app view. The org chart it draws is the one these commands show and change:

- [`brahma org show`](/docs/cli/org/show/)
- [`brahma org vacancies`](/docs/cli/org/vacancies/), [`brahma org fill`](/docs/cli/org/fill/), [`brahma org vacancy`](/docs/cli/org/vacancy/)
- [`brahma org move`](/docs/cli/org/move/), [`brahma org acting`](/docs/cli/org/acting/)
- [`brahma status`](/docs/cli/status/)

## Related

- [Agents and roles](/docs/concepts/agents-and-roles/)
- [Companies](/docs/concepts/companies/)
- [Sprints](/docs/concepts/sprints/)
