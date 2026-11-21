---
title: Modes and pacing
description: How much runs at once and how spend is paced. Company usage modes, the plan tier, the five-hour usage gates, weekly pacing and the owner's reserve, per-turn work modes, and the health gate.
sidebar:
  order: 7
---

## What it is

Brahma runs on your own `claude` CLI plan, so it has to pace itself. Three things decide what runs: the company's usage mode and the plan tier set how many turns run at once and how close to the five-hour limit they may go; weekly pacing spreads spend across the seven-day window and keeps a reserve for you; and the engine picks a work mode for each turn.

A health gate holds everything when the network, your account, the CLI or the disk is not right.

## How it works

**Usage mode and concurrency.** `brahma company mode <company> low|balanced|max` sets the company's mode. The concurrency cap per mode comes from the plan tier (`brahma settings plan`, default `max5x`):

| Plan tier | `low` | `balanced` | `max` |
| --- | --- | --- | --- |
| `pro` | `1` | `1` | `2` |
| `max5x` (default) | `1` | `3` | `8` |
| `max20x` | `2` | `6` | `16` |

`brahma run --hard-cap <n>` (default `16`) is your own ceiling on top. The plan tier is a setting; the CLI-reported plan never overrides it.

**Five-hour usage gates.** No new turn starts when five-hour utilisation reaches `80%` (low), `90%` (balanced) or `97%` (max), when a request is rejected for usage, or once paid overage is in use. A usage warning alone, for example on the seven-day window, does not stop turns. Low mode also turns sub-agents off and caps effort; max mode raises effort one step for P0 and critical-path items.

**Weekly pacing.** Spend is paced against a straight line across your seven-day window, keeping a reserve for you: `30%` by default. `brahma settings share` sets the percentage the companies may use (`10` to `100`; the rest is yours), and `brahma company reserve <company> <reserve>` overrides it for one company (`0.0` to `0.9`). When ahead of the line, only work that others wait on runs. Past the reserve, nothing runs.

**Work modes.** The engine picks a mode per turn: `quick`, `standard` or `deep`. Two more exist behind gates. Plan-first is off on this CLI version (probe V-4). Sub-agents never run on Workspace or Full companies; on Sandboxed companies they stay off until their probe gates pass for the installed CLI build (L-2, V-3 and V-5, plus V-2 or V-8). `brahma mode gates` lists the gates, and `brahma mode ultra-status` explains why Ultra cannot run for a company right now.

**Health gate.** One global hold starts when:

- the network drops: `3` failed turns in `300` seconds;
- the account is logged out or the plan changed: `2` failures;
- the `claude` CLI changes version (it is re-probed);
- the disk falls under `5 GB` (released at `6 GB`).

While the hold is on, failed turns do not count against agents, retries do not spin, company-active time freezes, and everything resumes when the probe passes. `brahma doctor` runs the probe by hand.

**Time.** Durations count company-active seconds, so a pause, a hold or a closed laptop freezes them. Calendar text uses your time zone (`brahma settings timezone`).

**Why is nothing running?** `brahma why <company>` lists the reasons: an engine hold, a paused company, usage or weekly pace, agents blocked on someone, asks waiting for you, deadlocks, long-blocked items, or no `Ready` items.

## In the app

The title bar has the mode switch (`LOW` / `BALANCED` / `MAX`). The strip below it shows the five-hour and seven-day utilisation, when the window resets, and the pace line (`7D ON PACE`, or ahead by a percentage). A **WHY** banner appears when nothing is running and says why. **Work › Budget** shows the week's pace, the spend by mode and a storage panel.

<img src="/screenshots/map.png" srcset="/screenshots/map@2x.png 2x" width="1600" height="1000" alt="Mission Control with the agent-map panel (Initech, 12 agents): the mode switch and agent counts in the title bar, a WHY banner reading 3 asks wait for you, and the usage strip with five-hour and seven-day figures" loading="lazy" decoding="async" />

*Mission Control with the agent-map panel (Initech, 12 agents). The WHY banner and the usage strip sit above the panels.*

## From the CLI

- [`brahma company mode`](/docs/cli/company/mode/), [`brahma company reserve`](/docs/cli/company/reserve/), [`brahma company weight`](/docs/cli/company/weight/)
- [`brahma settings plan`](/docs/cli/settings/plan/), [`brahma settings share`](/docs/cli/settings/share/), [`brahma settings timezone`](/docs/cli/settings/timezone/)
- [`brahma run`](/docs/cli/run/)
- [`brahma mode gates`](/docs/cli/mode/gates/), [`brahma mode ultra-status`](/docs/cli/mode/ultra-status/)
- [`brahma doctor`](/docs/cli/doctor/), [`brahma why`](/docs/cli/why/), [`brahma status`](/docs/cli/status/)

## Related

- [Companies](/docs/concepts/companies/)
- [Work items](/docs/concepts/work-items/)
- [Agents and roles](/docs/concepts/agents-and-roles/)
