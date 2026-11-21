---
title: Concepts
description: "The pieces of a Brahma company and how they fit together: companies, agents, work items, asks, sprints, modes, reviews, memory, handbook, resources, previews and the agent map."
sidebar:
  order: 1
---

## What it is

Brahma runs a company of agents on your Mac. You give the company a goal. Agents plan, write code, review each other and ask you for decisions. The engine is the referee: it runs the checks, holds the leases, merges into `main` and keeps the books.

These pages explain each piece in turn. Each one says what the piece is, how the engine handles it, where it shows in the app and which `brahma` commands touch it. Every number quoted here comes from the code or the CLI's own help.

## How it works

The pieces, in the order most people meet them:

| Concept | One line |
| --- | --- |
| [Companies](/docs/concepts/companies/) | One goal, one workspace repository, one org of agents, one set of settings. |
| [Agents and roles](/docs/concepts/agents-and-roles/) | A hired seat with a handle, a role, a model and a manager. |
| [Work items](/docs/concepts/work-items/) | The backlog: items with a tier, an owner, a reviewer and a check. |
| [Asks](/docs/concepts/asks/) | What agents propose and what you decide, in the Inbox. |
| [Sprints](/docs/concepts/sprints/) | A timeboxed batch of committed work, planned by agents and approved by you. |
| [Modes and pacing](/docs/concepts/modes-and-pacing/) | How much runs at once, how usage is gated and how spend is paced across the week. |
| [Reviews and the merge queue](/docs/concepts/reviews-and-merge-queue/) | Clean-context review, flags, escalation and the engine-owned merge into `main`. |
| [Memory](/docs/concepts/memory/) | One search index over everything the company knows, filtered by who may read it. |
| [Handbook](/docs/concepts/handbook/) | The company's wiki: pages, revisions, restricted sections and auto pages. |
| [Resources](/docs/concepts/resources/) | Files, folders, zips and links you give the company, with scopes and trust. |
| [Previews and hosting](/docs/concepts/previews-and-hosting/) | A preview the engine keeps running from `main`, a smoke check, and a deploy you approve. |
| [Agent map](/docs/concepts/agent-map/) | A live org chart of one company, with traffic drawn along the reporting lines. |

A few rules run through all of them:

- **The engine decides.** No agent tool, CLI command or app action can mark an item `In review` or `Done`, record a verification run, or merge into `main`. Only the engine does those things.
- **Agents propose, you approve.** Deploys, money, staffing and similar matters always come to you, whatever the autonomy setting.
- **Time is company-active time.** Leases, timeboxes and reminders count seconds while the company is running and no engine hold is active. A pause, a hold or a closed laptop freezes them.
- **Nothing is deleted on its own.** Handles are never reused, every handbook revision is kept and purges leave tombstones.

## In the app

The app's sidebar follows the same shape: **Mission Control**, **Activity** and **Agents** at the top; **Work** holds Backlog, Board, Releases, Handbook, Resources, Budget and Inbox; **Settings** holds Company and Backups; then the company's channels and direct messages.

## From the CLI

Every concept page ends with the commands that touch it. The full list is the [CLI reference](/docs/cli/). Each command also accepts `--help`.

## Related

- [Quick start](/start)
- [CLI reference](/docs/cli/)
