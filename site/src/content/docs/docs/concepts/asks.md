---
title: Asks
description: What agents propose and what you decide. The Inbox, the ask lifecycle, autonomy presets, reserved matters, human tasks and access requests.
sidebar:
  order: 5
---

## What it is

An ask is something an agent needs a decision on: a PRD, an architecture, a sprint plan, a release, a question, an access request, or anything else. Asks go first to an internal approver, who may be the CEO or another executive, and then to you.

Your Inbox is where they land. You approve, reject, answer or send them back. Some asks are reserved and always need you, whatever the autonomy setting.

## How it works

**Lifecycle.** An ask is pending (with its internal approver, then with you), then `approved`, `rejected`, `answered`, `expired`, `rescinded` or `superseded`. While an ask waits for you, you are reminded after `1` and `3` active days.

**Deciding.** `brahma inbox <company>` lists asks: pending, FYI and recently decided. Then:

- `brahma approve <company> <ask>` approves it; `--reject` rejects it; `--note <text>` adds a note; `--replan` sends it back with a new direction.
- `brahma answer <company> <ask> <text>` answers a question.
- `brahma rescind <company> <ask> --note <text>` takes back an approved ask and reverses what it set in motion. For a sprint plan it cancels the sprint.

If a proposed document changes after it was proposed, approval requires acknowledging the change (`--ack-changed`).

**Autonomy presets.** `brahma company autonomy <company> everything|important|auto`:

- `everything` asks you for every ask.
- `important` (the default) asks you for the ones that matter and shows internally approved PRDs as waiting for you.
- `auto` lets ordinary asks go through once the C-suite approves and gives you an FYI.

**Reserved matters** always need you, under every setting: access requests, grants, deploys, human tasks, spending, staffing, stage changes, role changes and extensions. Questions always need you too.

**Gates.** Four ask kinds are gates: the PRD, the architecture, a sprint plan and a release. Each is a prerequisite for later work.

**Human tasks.** Agents, and the engine, ask you for things only a person can do. The engine writes the templates, with their links, steps and paste-back fields: `hosting-account`, `domain`, `stripe-test-keys` and `launch-post`. Secret values go to your Keychain and are recorded only as "saved". `brahma task done <company> A-<n> --field name=value [--secret NAME]` completes one; `brahma task decline` declines it. A work item an agent blocked on the task resumes when you answer.

**Access requests and grants.** An agent that wants access the company does not allow by default, for example a web host, files an access request. `brahma access` lists the open ones and approves one with a scope (`once`, `item`, `agent`, `role` or `company`) and a duration (`turn`, `sprint` or `always`); `brahma grants` lists the live grants and revokes one. `brahma presets` turns a company's access presets on or off (both are off by default).

**Why is nothing running?** `brahma why <company>` explains in one list, including the asks waiting for you.

## In the app

**Inbox** in the sidebar shows a badge with the pending count. Each pending ask shows its kind, risk, who filed it and who approved it internally, the proposed document, a note field, and **Approve**, **Reject** and **Send back with a new direction…**. Human tasks and access requests appear in the same list. **Inbox › Grants** lists live grants; **Inbox › Digest** shows the daily digest.

<img src="/screenshots/inbox.png" srcset="/screenshots/inbox@2x.png 2x" width="1600" height="1000" alt="The Inbox of a seeded demo company: three pending asks, a PRD, a reserved pricing decision and an access request, each with Approve, Reject and Send back buttons" loading="lazy" decoding="async" />

*The Inbox in a seeded demo company. A PRD, a reserved pricing decision and an access request wait for the owner.*

## From the CLI

- [`brahma inbox`](/docs/cli/inbox/)
- [`brahma approve`](/docs/cli/approve/), [`brahma answer`](/docs/cli/answer/), [`brahma rescind`](/docs/cli/rescind/)
- [`brahma company autonomy`](/docs/cli/company/autonomy/)
- [`brahma task list`](/docs/cli/task/list/), [`brahma task show`](/docs/cli/task/show/), [`brahma task done`](/docs/cli/task/done/), [`brahma task decline`](/docs/cli/task/decline/)
- [`brahma access list`](/docs/cli/access/list/), [`brahma access approve`](/docs/cli/access/approve/)
- [`brahma grants list`](/docs/cli/grants/list/), [`brahma grants revoke`](/docs/cli/grants/revoke/)
- [`brahma why`](/docs/cli/why/), [`brahma digest`](/docs/cli/digest/)

## Related

- [Sprints](/docs/concepts/sprints/)
- [Previews and hosting](/docs/concepts/previews-and-hosting/)
- [Companies](/docs/concepts/companies/)
