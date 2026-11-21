---
title: Backups and restore
description: "What the engine backs up and when, what a data-home snapshot includes and leaves out, off-machine targets and WAL shipping, and what a restore carries forward so a rollback cannot widen access."
sidebar:
  order: 9
---

## What it is

Backups live under `<data home>/backups/` and are made by the engine (the app, or `brahma run`) while it runs. They cover the database and the data home's files, and each company's repository as a git bundle. A restore puts a database snapshot back, and carries forward the few things that must never roll back: revocations, taint marks and the stricter of each security setting.

## How it works

**Schedule.**

| What | When | Kept |
| --- | --- | --- |
| Database snapshot (`VACUUM INTO`, integrity-checked) | every hour | `48` |
| Repository bundle per company (`git bundle --all`, verified; skipped when no ref moved) | daily at `03:30` | `14` per company |
| Data-home snapshot (hard-linked against the previous one) | daily at `04:00` | `30` |
| Copy to every off-machine target | daily at `04:30` | |
| Database snapshot before a migration | when a migration runs | `10` |
| Manual database snapshot (`brahma backup now`) | when you ask | `20` |
| Database snapshot before a restore | when you restore | `5` |

A snapshot that fails its check is deleted and nothing is pruned. A failed backup posts a "Backup failed" notice.

**What is included.** The data-home snapshot holds everything under the data home (archives, transcripts, role cards, company files) except `run/`, `backups/`, `tmp/`, `cache/`, `owner/` and `secrets/`, SQLite `-wal`, `-shm` and `-journal` files, `*.lock` files and the live `brahma.sqlite` (which has its own snapshots). SQLite files in it are integrity-checked copies. Links are never followed. Workspaces are backed up only as their git history (the bundles).

**Restore.** Quit the app and `brahma run` first.

```text
brahma restore --list                  the database snapshots, newest first (also: brahma backup list)
brahma restore --latest                the newest snapshot that passes its integrity check
brahma restore --at <ISO-8601 time>    the newest snapshot at or before that time
brahma restore <snapshot file>
  --with-files                         also put the data home's files back, from the newest data-home snapshot at or
                                       before the database snapshot (it may be up to a day older)
  --dry-run                            check the snapshot and show what would happen; change nothing
```

The current database is kept next to it as `brahma.sqlite.pre-restore-<time>`, and with `--with-files` whatever the files replaced is kept in `<data home>/.pre-restore-<time>`.

**What a restore carries forward.** A restore comes back stopped: nothing runs until `brahma resume`. Before the swap it reads the current database and writes into the restored one what must not roll back:

- grant revocations and used-up uses, and a revocation of every grant that had already ended in the current database (revoked, used up, expired on company-active time, or its sprint ended);
- every taint mark: agent sessions, items, lab and company marks, the machine-wide mark, and lab commits recorded tainted.

It also always sets the machine-wide lab mark, so no lab commit made after the snapshot is recorded clean; clear it with `brahma lab clear-taint --machine-wide` once you have checked the labs.

For each security-relevant company setting, the restore keeps the stricter of the current and the snapshot's value: autonomy, the company and role profiles, toolchain read paths, network and web domains (only entries both allow are kept), local listening, auto-merge, and the pause. Owner-wide, auto-merge stays off if it is off now, and the auto-merge folder list is the narrower of the two. Where auto-merge is kept off, auto-approvals in the snapshot that have not landed go back to a normal review.

Other rows are not carried, only reported: companies and agents removed after the snapshot come back, and so do disabled or removed extensions, access presets and removed secret entries (their values are not restored). The restore lists each setting it kept stricter and each row it brought back. The list is printed by the CLI, put in the stop note and raised as an engine alert in every company. Review it before you resume. If the current database cannot be read, every grant is revoked, every agent session and open item is marked, and the list says that what was rolled back is unknown.

**Git after a restore.** Repositories are never touched. After you resume, Brahma re-adopts each company's `main` as the snapshot recorded it. Commits made after the snapshot are kept, but Brahma alerts you and holds that company until you review `main` and accept it with `brahma main accept`.

**Export.** `brahma export <company> --to <new directory> [--no-workspace]` writes a self-contained copy of one company: its database rows, its repository as a bundle (left out with `--no-workspace`), its files, transcripts, archive and roles. Machine-specific records (turn tokens, restore records, the stop, the canary) are left out.

**Off-machine targets.**

```text
brahma backup target add folder <path>   mirror the backups to <path>/<hostname>/ (an external drive, a NAS mount)
brahma backup target add rclone <remote> upload through an rclone remote, which must be of type crypt
brahma backup targets                    list them
brahma backup target rm <n>
brahma backup now [--targets]            a database snapshot now, then (with --targets) a copy to every target
```

A folder must exist, be writable and lie outside the data home and every workspace; it is checked again on every copy. A drive that is not connected is skipped, with one notice a day.

**WAL shipping (optional).** `brahma backup wal enable <replica>` ships the database's write-ahead log with Litestream to a folder (with a folder target's checks) or a URL Litestream understands (`s3://bucket/path`); `brahma backup wal disable` stops it. Both take effect when the engine next starts. Credentials go in the engine's environment (`AWS_*`, `LITESTREAM_*`, `SSH_AUTH_SOCK`), never in the URL. With it on, `brahma restore --at` first has Litestream rebuild that moment (checked before it is used) and falls back to the newest snapshot if that fails.

**Doctor.** `brahma doctor` reports `backup-targets` (every configured target reachable) and `wal-shipping`.

## In the app

**Settings › Backups** shows the last hourly snapshot, the last data-home snapshot and the last target copy; lists the targets (add and remove); has the WAL switch (disabled with "Install litestream to enable" when Litestream is missing); and **Back up now**.

## From the CLI

- [`brahma backup now`](/docs/cli/backup/now/), [`brahma backup list`](/docs/cli/backup/list/)
- [`brahma backup targets`](/docs/cli/backup/targets/), [`brahma backup target add folder`](/docs/cli/backup/target/add/folder/), [`brahma backup target add rclone`](/docs/cli/backup/target/add/rclone/), [`brahma backup target rm`](/docs/cli/backup/target/rm/)
- [`brahma backup wal enable`](/docs/cli/backup/wal/enable/), [`brahma backup wal disable`](/docs/cli/backup/wal/disable/)
- [`brahma restore`](/docs/cli/restore/), [`brahma main accept`](/docs/cli/main/accept/)
- [`brahma export`](/docs/cli/export/)
- [`brahma doctor`](/docs/cli/doctor/)

## What it does not do

- **Secrets and the owner key are never backed up.** `owner/` and `secrets/` are left out of every snapshot. After a restore on a new machine, set secrets again and let the app create a new owner key.
- **Uncommitted work is not backed up.** Workspaces are backed up only as their git history. Uncommitted files in a workspace are not, and neither are agent labs (separate repositories under `.brahma/labs`) or other `.brahma` state outside the workspace's git history.
- **A restore does not touch git.** It restores the database; the repositories keep whatever commits they have. You review and accept `main` afterwards.
- **A restore loses what happened after the snapshot.** Messages, hand-offs and events made after it are gone. Ultra approvals used after the snapshot become usable again.
- **`--with-files` may be up to a day older** than the database snapshot it goes with.
- **`rclone` and `litestream` are not bundled.** Without them those features read "unavailable".
- **Targets are not hidden from every profile.** Sandboxed turns and sandboxed checks can neither read nor delete a folder target or the WAL replica folder. On the Workspace profile the `claude` CLI's file tools are denied them too, but the agent's Bash is not sandboxed and can reach them; Full-profile turns and checks can reach them.
- **It is not Time Machine.** Include `~/Library/Application Support/Brahma` and `~/Brahma` in Time Machine; Brahma's own backups live inside the first.

## Related

- [Emergency stop](/docs/safety/emergency-stop/)
- [Taint and vouch](/docs/safety/taint-and-vouch/) (the machine-wide lab mark a restore sets)
- [Companies](/docs/concepts/companies/) (where the data lives)
