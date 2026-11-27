---
title: Reviews and the merge queue
description: A submitted item is reviewed in a fresh, clean-context session by its reviewer. Review flags, escalation, the engine-owned merge of the verified commit into main, auto-merge and what happens when main changes outside Brahma.
sidebar:
  order: 8
---

## What it is

When an agent submits an item and its check passes, the item goes to its reviewer. The review runs in a fresh session with a clean context: the reviewer sees the diff, the check result and the flags, not the author's conversation.

On approval the engine, not the agent, merges the verified commit into `main`. Each company has one merge queue; merges land one at a time, oldest approved item first.

## How it works

**The review turn.** The reviewer approves or requests changes. Review flags need explicit approval:

- a check edited after the item started;
- deleted or modified tests;
- an edited check script;
- code changed after the check passed;
- a flaky pass (a pass that needed a second run).

`3` review turns without a decision escalate to the reviewer's manager, or to you if there is none.

**The merge.** On approval the engine merges the verified SHA into `main`. Once per tick, after the checks, it starts the merge of each company's oldest approved item, one per company, into free slots. Nothing starts under an engine hold or for a paused company. Merges run in an engine-owned repository under the data home and land only the verified SHA. The engine re-verifies only when `main` moved and the branch had to be rebased first.

**Auto-merge.** Off by default. A company turns it on with `brahma company set <company> auto-merge-small on`; the owner-wide master switch `brahma settings auto-merge` must be on as well, and switching it off takes back every auto-approval that has not landed yet. With it on, small tier-`S` changes whose allowlisted check passes, set up by a lead, land without a review turn and are audited after. Every changed path must lie under one of the auto-merge paths, by default `Sources/`, `src/`, `lib/`, `app/` and `docs/` (`brahma settings auto-merge-paths`).

**Engine git safety.** Engine git ignores repository filters, drivers, hooks and replace objects, and allowlists repository config. Uncommitted changes found on `main` are quarantined under `refs/brahma/quarantine/*` and merges wait for you: approving the engine's ask (or `brahma main accept <company> <ref>`) merges exactly the recorded commit; rejecting it leaves `main` as it is and keeps the ref. If `main` changed outside Brahma, `brahma main accept <company>` accepts the new `main`. Git state planted in the workspace repository that would hold merges (stale lock files, `shallow`, `info/grafts`, deleted history objects) is repaired and reported to you.

**The smoke check on `main`.** When a company has a smoke check, the engine runs it on every new `main`. While it fails, `main` is red and deploys are blocked. See [Previews and hosting](/docs/concepts/previews-and-hosting/).

**Transcripts.** `brahma transcript <company> <turn id>|@handle` shows the recorded, redacted transcript of a turn, review turns included.

## In the app

**Work › Board** has an `IN REVIEW` column. An item's inspector shows its check runs, flags and review events under **HISTORY**. A quarantine or an outside change to `main` arrives as an ask in the **Inbox**. Merges and their results appear in the **Activity** feed.

## From the CLI

- [`brahma items show`](/docs/cli/items/show/)
- [`brahma company set`](/docs/cli/company/set/)
- [`brahma settings auto-merge`](/docs/cli/settings/auto-merge/), [`brahma settings auto-merge-paths`](/docs/cli/settings/auto-merge-paths/)
- [`brahma main accept`](/docs/cli/main/accept/)
- [`brahma transcript`](/docs/cli/transcript/)
- [`brahma release smoke`](/docs/cli/release/smoke/)

## Related

- [Work items](/docs/concepts/work-items/)
- [Previews and hosting](/docs/concepts/previews-and-hosting/)
- [Agents and roles](/docs/concepts/agents-and-roles/)
