---
title: Emergency stop
description: "brahma stop and STOP EVERYTHING hold every company at once: what the engine cancels, which processes the command itself signals, how you resume, and the narrower tools (pause and kill)."
sidebar:
  order: 8
---

## What it is

The emergency stop holds every company at once. Nothing new starts until you resume. It is the one control that works on every company and every profile, and the command itself signals running turns, so a wedged engine cannot keep agents running.

## How it works

**Stopping.** `brahma stop [--note <why>]`, or **STOP EVERYTHING** in the app's top bar. The note is kept with the stop.

**What the engine does.** The running engine cancels every turn (Ultra included), check, merge, git task and sandbox canary, and starts nothing new until `brahma resume` (or **Resume** in the app). Previews and deploys stop too.

**What the command does on its own.** `brahma stop` signals the process group of every turn the database records as running, and of every check and merge child the engine recorded: `SIGTERM`, then `SIGKILL`. This does not depend on the engine being alive.

**While stopped.** `brahma mode gates --run` and `brahma ext try` refuse to start. `brahma why` reports the stop as the reason nothing runs. A restore also comes back stopped: see [Backups and restore](/docs/safety/backups/).

**Resuming.** `brahma resume` ends the owner's stop; scheduling starts again. Leases and timeboxes count company-active seconds, so time spent stopped does not expire them.

**Narrower tools.** You rarely need the full stop:

| Tool | Effect |
| --- | --- |
| `brahma company pause <company>` | No new turns for that company; its clock stops. `brahma company resume` undoes it. |
| `brahma pause <company> <agent>` | A running agent finishes its turn first, then sleeps. `brahma wake` undoes it. |
| `brahma kill <company> <agent>` | The agent stays killed. A running turn finishes in the orchestrator; its leases are reaped and its items handed off. |
| `brahma company profile <company> sandboxed` | Narrows future turns; does nothing to running ones. |

## In the app

**STOP EVERYTHING** is in the title bar, next to **Pause company**. It asks first: "Stop every agent, check, preview and deploy in all companies now? Nothing runs until you resume." While stopped, a banner reads "Everything is stopped. Resume when you're ready." with a **Resume** button.

## From the CLI

- [`brahma stop`](/docs/cli/stop/), [`brahma resume`](/docs/cli/resume/)
- [`brahma company pause`](/docs/cli/company/pause/), [`brahma company resume`](/docs/cli/company/resume/)
- [`brahma pause`](/docs/cli/pause/), [`brahma wake`](/docs/cli/wake/), [`brahma kill`](/docs/cli/kill/)
- [`brahma why`](/docs/cli/why/), [`brahma status`](/docs/cli/status/)

## What it does not do

- **It signals only what the engine recorded.** Turns come from the database; check and merge children from the engine's run-dir records. Probe-gate, canary and `ext try` processes are in neither, so `brahma stop` with no engine running does not signal them. A probe gate already running when you press stop finishes that gate.
- **It does not find strays.** A process an earlier Workspace or Full turn left running outside the recorded process groups is not signalled. Check `ps`.
- **It does not revoke grants, clear taint or undo merges.** It holds the future; it does not rewind the past. Use `brahma grants revoke`, `brahma lab clear-taint` and a restore for those.
- **It does not stop the `claude` CLI's own processes outside Brahma,** such as a `claude` session you started yourself.
- **Stopped is not quit.** The engine keeps running and keeps the lock. To hand the data home to `brahma restore`, quit the app and `brahma run` as well.

## Related

- [Backups and restore](/docs/safety/backups/) (a restore comes back stopped)
- [Companies](/docs/concepts/companies/) (pause and resume)
- [Agents and roles](/docs/concepts/agents-and-roles/) (pause, wake and kill)
