---
title: Purge a resource
description: "Remove a resource's bytes, mirror copy and search text with brahma resource purge, then deal with the backups and transcripts the purge reports."
sidebar:
  order: 6
---

## Goal

Delete one resource so that no agent tool, mirror or search index can return it, and know which backups and transcripts may still hold it.

## Before you start

- `brahma resource` is an owner command.
- You have the resource's ref (`F-<n>`). Purging a folder purges its files; a single file inside a folder can be purged on its own.
- A purge is not undone. The row stays as a tombstone and the ref is never reused.

## Steps

1. Find the ref and confirm it is the one you mean.

   ```text
   brahma resource <company> list
   ```

2. Purge it. `--yes` is required; without it nothing is deleted.

   ```text
   brahma resource <company> purge F-3 --yes
   ```

   The CLI prints `purged F-3; <n> backups and <m> transcripts made since it was added may still contain it; reads through an agent's shell or the mirror are not tracked one by one`, then one line per backup that `contains purged content · delete or re-create` and one per `transcript of turn <id>` that may contain it. Its last line reminds you that the `claude` CLI's own unredacted session logs under `~/.claude/projects` are not scrubbed by a purge.

3. Take a fresh snapshot, so the newest backup no longer holds the bytes. Then delete or re-create the older snapshots the purge listed.

   ```text
   brahma backup now
   ```

:::caution
The purge removes the vault bytes, the workspace mirror copy and the index entries, including the search text in the database file. It does not rewrite backups or transcripts: it reports them. Anything an agent already copied into its workspace, or wrote into a message, is not a resource and is not touched.
:::

## Check it worked

```text
brahma resource <company> list
```

The row is still listed, as a tombstone. Mentions the engine built now read `[purged F-3]`, and an agent's `recall(ref: "F-3")` answers `F-3 was purged by the owner.` Check `brahma backup list` and remove the snapshots the purge named.

## Related

- [Resources](/docs/concepts/resources/): what a purge removes and what it only reports
- [Backups and restore](/docs/safety/backups/): where snapshots live and how long they are kept
- [Drop files for agents](/docs/guides/drop-files-for-agents/)
- CLI: [`brahma resource`](/docs/cli/resource/), [`brahma backup now`](/docs/cli/backup/now/), [`brahma backup list`](/docs/cli/backup/list/), [`brahma transcript`](/docs/cli/transcript/)
