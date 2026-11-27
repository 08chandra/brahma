---
title: Sprints
description: A timeboxed batch of committed work for a team or the company. Agents plan and close sprints; sprint plans are approved through the Inbox; the engine writes standups.
sidebar:
  order: 6
---

## What it is

A sprint is a timeboxed batch of committed work for a team or, with no team, for the whole company. Agents plan sprints and close them. You approve each sprint plan in the Inbox before it starts.

The engine keeps the clock in company-active time, posts standups and tells the lead when a sprint completes or runs out of time.

## How it works

**Planning.** An agent calls `plan_sprint`. That files a `sprintPlan` ask, which is one of the four gate kinds. When you approve it, the sprint becomes `active`. A rejected plan leaves the sprint `rejected`.

**Timebox.** A sprint runs for `5` active days or `200` team work turns, whichever comes first. When its work is complete or the timebox is reached the sprint moves to `review`, and the lead who planned it is told.

**Closing.** An agent calls `close_sprint`; the sprint becomes `closed`. A sprint retro is indexed in [memory](/docs/concepts/memory/).

**Standups.** The engine writes a standup every `86 400` active seconds of an active sprint. Standups are system posts: no agent turn runs and nobody is woken.

**Rescinding.** Rescinding an approved sprint plan (`brahma rescind`) cancels the sprint.

**Time.** The timebox counts company-active seconds. A pause, an engine hold or a closed laptop freezes it.

## In the app

The strip under the title bar shows the active sprint, or `No active sprint`. Sprint plans arrive in the **Inbox** like any other ask. The handbook's auto page **Sprint summaries** is generated from live data. On the [agent map](/docs/concepts/agent-map/), a sprint meeting is drawn as a hull around its participants.

## From the CLI

- [`brahma sprint`](/docs/cli/sprint/) shows the open sprints and their progress.
- [`brahma sprint show`](/docs/cli/sprint/show/), [`brahma sprint list`](/docs/cli/sprint/list/)
- [`brahma approve`](/docs/cli/approve/), [`brahma rescind`](/docs/cli/rescind/)

## Related

- [Asks](/docs/concepts/asks/)
- [Work items](/docs/concepts/work-items/)
- [Handbook](/docs/concepts/handbook/)
