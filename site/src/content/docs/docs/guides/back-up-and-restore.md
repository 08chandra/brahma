---
title: Back up and restore
description: "Take a verified snapshot now, add an off-machine folder target and copy to it, then restore from a snapshot: dry run first, review what the restore carried forward, accept main and resume."
sidebar:
  order: 9
---

## Goal

Have a snapshot you took yourself, a copy of the backups outside the Mac, and a restore you have rehearsed with `--dry-run`.

## Before you start

- `brahma backup` and `brahma restore` are owner commands.
- The engine makes backups on its own while it runs: a database snapshot every hour, a repository bundle and a data-home snapshot daily, and a copy to every target daily. This guide covers what you do by hand.
- For the off-machine target you need an existing, writable folder outside Brahma's data and workspaces: a folder on an external drive or a mounted share. Backups land under `<path>/<hostname>/`.
- To restore, the engine must not be running: quit the app and stop `brahma run` first.

## Steps

1. Take a snapshot now. It is integrity-checked; one that fails its check is deleted.

   ```text
   brahma backup now
   ```

   The CLI prints `snapshot: <path>`.

2. Add an off-machine folder target. The folder must exist, be writable and lie outside the data home and every workspace; it is checked again on every copy.

   ```text
   brahma backup target add folder /Volumes/Backup/brahma
   ```

   The CLI prints `added: <target>`. `brahma backup targets` lists the targets with their numbers; `brahma backup target rm <n>` removes one. For an rclone remote of type `crypt`: `brahma backup target add rclone <remote>`.

3. Snapshot and copy to every target in one step. A drive that is not connected is skipped.

   ```text
   brahma backup now --targets
   ```

4. List the snapshots, newest first, when you need to restore.

   ```text
   brahma restore --list
   ```

5. Rehearse the restore. `--dry-run` checks the snapshot and prints what would happen; nothing changes. `--latest` picks the newest snapshot that passes its integrity check; `--at <ISO-8601 time>` the newest at or before that time; or name a snapshot file.

   ```text
   brahma restore --latest --dry-run
   ```

6. Restore. Add `--with-files` to put the data home's files (archives, transcripts, role cards) back too, from the newest data-home snapshot at or before the database snapshot; it may be up to a day older.

   ```text
   brahma restore --latest --with-files
   ```

   The current database is kept next to it as `brahma.sqlite.pre-restore-<time>`. The CLI lists each setting it kept stricter and each row it brought back; read that list.

7. End the stop, then start the engine again (the app, or `brahma run`). A restore comes back stopped: nothing runs until you resume, and the engine re-adopts the repositories after the resume.

   ```text
   brahma resume
   ```

:::caution
A restore puts the database back, not the repositories. Commits made after the snapshot are kept, but Brahma alerts you and holds that company until you review `main` and accept it with `brahma main accept <company>`. Secrets and the owner key are never backed up. Messages and events made after the snapshot are gone.
:::

## Check it worked

```text
brahma backup list
```

Your manual snapshot is listed with its time, reason and path, newest first. `brahma backup targets` shows the folder target, and `brahma doctor` reports `backup-targets` as reachable. After a restore, `brahma status` shows the stop until `brahma resume`, and each company's alerts list what the restore carried forward.

## Related

- [Backups and restore](/docs/safety/backups/): the schedule, what is included, what a restore carries forward and what it does not do
- [Emergency stop](/docs/safety/emergency-stop/): the stopped state a restore comes back in
- [Reviews and the merge queue](/docs/concepts/reviews-and-merge-queue/): accepting `main` after it changed outside Brahma
- CLI: [`brahma backup now`](/docs/cli/backup/now/), [`brahma backup list`](/docs/cli/backup/list/), [`brahma backup targets`](/docs/cli/backup/targets/), [`brahma backup target add folder`](/docs/cli/backup/target/add/folder/), [`brahma backup target add rclone`](/docs/cli/backup/target/add/rclone/), [`brahma backup target rm`](/docs/cli/backup/target/rm/), [`brahma restore`](/docs/cli/restore/), [`brahma resume`](/docs/cli/resume/), [`brahma main accept`](/docs/cli/main/accept/), [`brahma doctor`](/docs/cli/doctor/)
