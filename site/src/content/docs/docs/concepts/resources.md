---
title: Resources
description: Files, folders, zips and links you give the company. Scopes, the vault, the workspace mirror, the checks run before anything is stored, trust and taint, the secret sheet, announcements and purge.
sidebar:
  order: 11
---

## What it is

A resource is a file, folder, zip or link you give the company. You drop it on any composer in the app, or add it with `brahma resource`. Each resource gets a ref (`F-3`), a scope that says who may read it, and a trust mark that says whether it came from you or from outside.

Agents read resources through their tools. The bytes live in a vault under the data home, and every open checks the hash.

## How it works

**Scopes.** A drop defaults to the place it was dropped in: a DM to that agent, a channel to its members now, an Inbox answer to the asker, and the library or the CLI to the whole company. The scope is one of `company`, `team:<team>`, `agent:@<handle>` or `item:<KEY>`. An item scope is the item's owner, lease holder, reviewer, the owner's manager and the agent that wrote it. A drop is refused if anyone its announcement reaches could not read it. Change a scope later with `brahma resource <company> scope F-<n> <scope>`.

**The vault.** The bytes are copied into `<data home>/vault/` as `F-<n>.<ext>`, read-only and named by the engine. Every open checks the sha256. Agents read a resource through `recall(ref: "F-n")`, which returns the indexed text of text files. On Workspace and Full, an agent's shell can read the vault directly; only Sandboxed keeps the shell out.

**The mirror.** Company-scope, untainted, unflagged files are also copied read-only to `.brahma/resources/company` in the workspace. A planted link raises an engine alert and wipes the mirror: it fails closed.

**Checks before anything is stored.** Symlinks are refused, and so are executables (by extension and by content). Zips must be under `200 MB` unpacked, with a compression ratio of at most `100`, at most `10 000` entries and no `../` or link entries. `.git/` is skipped and names are cleaned.

**Trust.** A file is `EXTERNAL` (tainted, read as untrusted data) when it comes from inside a company workspace or Brahma's data folder, when it is a document type (PDF, Office, HTML, SVG, mail, RTF, zip), a text file over `64 KB`, or a download macOS quarantined. Everything else you add is `FROM YOU`. `--vouch` or `--untrusted` overrides this. A folder's scope, trust and purge cascade to its files.

**The secret sheet.** A file that looks like it holds a secret needs a choice: **Upload redacted**, **Upload anyway** (stored flagged: never indexed, mirrored or returned by Brahma's tools), **Store it as a secret instead** (one small text file), or **Cancel**. A value already stored in your Keychain can never be uploaded raw. The CLI's equivalents are `--redact` and `--anyway`.

**Announcements.** A DM, channel or Inbox drop sends one owner message, answer or comment. A library or CLI drop appears in each reader's next orientation under "New resources". A tainted resource is announced by ref only, never by its name. A link is named only as `[link F-n]` and is never fetched.

**Purge.** `brahma resource <company> purge F-<n> --yes` removes the vault bytes, the mirror copy and the index entries, including the search text left in the database file. The row stays as a tombstone, and mentions the engine built are rewritten to `[purged F-n]`. Backups and transcripts that may still contain the resource are reported, not rewritten, so you can delete or re-create them.

## In the app

**Work › Resources** is the library: a table of ref, name, kind, size, scope, trust, scan result and when it was added. You can also drop files on an owner DM, a channel, or an agent's question in the Inbox. One Send is one message; a link goes on its own.

<img src="/screenshots/resources.png" srcset="/screenshots/resources@2x.png 2x" width="1600" height="1000" alt="The Resources view of a seeded demo company: a table of four resources with ref, name, kind, size, scope, trust (FROM YOU or EXTERNAL), scan and added columns" loading="lazy" decoding="async" />

*Work › Resources in a seeded demo company. A PDF defaults to `EXTERNAL`; files you wrote are `FROM YOU`.*

## From the CLI

- [`brahma resource`](/docs/cli/resource/): `add`, `link`, `list`, `vouch`, `scope`, `purge`
- [`brahma secret`](/docs/cli/secret/)
- [`brahma export`](/docs/cli/export/)

## Related

- [Memory](/docs/concepts/memory/)
- [Handbook](/docs/concepts/handbook/)
- [Asks](/docs/concepts/asks/)
