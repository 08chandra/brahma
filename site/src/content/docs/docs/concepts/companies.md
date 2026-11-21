---
title: Companies
description: A company is one goal, one workspace repository, one org of agents and its own settings. How companies are created, where their data lives, and the settings that shape them.
sidebar:
  order: 2
---

## What it is

A company is the unit Brahma runs. It has one goal, one workspace repository, one org chart of agents, and its own settings: usage mode, autonomy, profile, weight and reserve. Several companies can run at once under one engine and share its slots.

You create a company with `brahma company create` or the app's New company sheet. The engine (`brahma run`, or the app) then schedules its agents.

## How it works

**Creating one.** `brahma company create <name> --goal <text>` prints the company id and its workspace path. Options:

- `--agents <n>`: agents in the full org shape. `0` for an empty company, otherwise `5` to `500`; default `6`. Over `50` the CLI prints a note that the size is experimental.
- `--from-repo <folder|https-url>`: start from an existing repository. The source is a local folder or an `https://` URL; nothing else. The engine fetches it itself. No remote is configured, so the original is never pushed to or changed. Everything imported is treated as outside content until you lift the mark with `brahma company trust-import <name> --yes` (engine stopped).
- `--demo live`: the goal-to-URL demo. A four-agent org (`ceo`, `cto`, `eng-1`, `devops-1`), autonomy `important`, hosting on the default provider, the `hosting-account` task already in your Inbox, and the owner's kickoff in `#general`. The default goal is a one-page waitlist site.

**Profile.** Each company's agent turns run under a profile: `sandboxed` (the default), `workspace` or `full`. `brahma company profile` sets it, and `brahma run --profile` can only narrow it, never widen it. Sandboxed confines each turn to its own places in the workspace; workspace lets the agent's shell run anywhere you can; full gives agents access to your whole Mac.

**Usage mode.** `brahma company mode <name> low|balanced|max` sets how many turns the company may run at once and how close to the five-hour usage limit it may go. The caps come from the plan tier (`brahma settings plan`, default `max5x`) and are further capped by `brahma run --hard-cap` (default `16`). See [Modes and pacing](/docs/concepts/modes-and-pacing/) for the table.

**Weight.** `brahma company weight <name> <n>` sets a company's share of slots when several companies run.

**Autonomy.** `brahma company autonomy <name> everything|important|auto` sets how much you are asked. `important` is the default. Reserved matters always come to you. See [Asks](/docs/concepts/asks/).

**Reserve.** `brahma company reserve <name> <reserve>` overrides, for one company, the share of the weekly allowance kept for you (`0.0` to `0.9`, or `default`).

**Pause and resume.** `brahma company pause <name>` stops new turns for that company; `brahma company resume <name>` lets them start again. A paused company's clock stops too, so leases and timeboxes freeze.

**Settings.** `brahma company set <name> auto-merge-small on` turns on auto-merge for small changes in that company (the owner-wide switch `brahma settings auto-merge` must be on as well). See [Reviews and the merge queue](/docs/concepts/reviews-and-merge-queue/).

**Where the data lives.**

| What | Where | Override |
| --- | --- | --- |
| Database (`brahma.sqlite`), MCP configs | `~/Library/Application Support/Brahma/` | `BRAHMA_HOME` |
| Company workspaces | `~/Brahma/<company-slug>/` | `BRAHMA_WORKSPACES` |

Only one `brahma run` per data home is allowed (a lock on `orchestrator.lock`).

## In the app

The left edge of the window lists your companies as lettered badges; the one in front is selected. The title bar shows the company name, its usage mode (`LOW` / `BALANCED` / `MAX`), the agent counts, **Pause company** and **STOP EVERYTHING**. The strip below shows the active sprint, the autonomy setting and the usage figures.

**Settings › Company** holds the company's settings, including its hosting provider. The **+** at the bottom of the company strip opens the New company sheet, which has the same options as the CLI, including **EXISTING REPO**.

## From the CLI

- [`brahma company create`](/docs/cli/company/create/), [`brahma company list`](/docs/cli/company/list/)
- [`brahma company mode`](/docs/cli/company/mode/), [`brahma company weight`](/docs/cli/company/weight/), [`brahma company reserve`](/docs/cli/company/reserve/)
- [`brahma company profile`](/docs/cli/company/profile/), [`brahma company autonomy`](/docs/cli/company/autonomy/), [`brahma company set`](/docs/cli/company/set/)
- [`brahma company pause`](/docs/cli/company/pause/), [`brahma company resume`](/docs/cli/company/resume/)
- [`brahma company trust-import`](/docs/cli/company/trust-import/)
- [`brahma run`](/docs/cli/run/), [`brahma status`](/docs/cli/status/), [`brahma why`](/docs/cli/why/)

## Related

- [Agents and roles](/docs/concepts/agents-and-roles/)
- [Modes and pacing](/docs/concepts/modes-and-pacing/)
- [Asks](/docs/concepts/asks/)
