---
title: Drop files for agents
description: "Give a company files, a folder or a link from the terminal with brahma resource add and link: choose the scope, decide the trust mark, and handle a file that looks like it holds a secret."
sidebar:
  order: 5
---

## Goal

Add files the company's agents can read, scoped to the readers you choose, with the trust mark you intend.

## Before you start

- `brahma resource` is an owner command.
- The files are outside every company workspace and outside Brahma's data folder. A file from inside either is stored as `EXTERNAL` (tainted) whatever else you pass.
- No symlinks and no executables: both are refused. A zip must unpack to under `200 MB`, with at most `10 000` entries.
- Decide who should read it. The scope is `company` (the default), `team:<team>`, `agent:@<handle>` or `item:<KEY>`.

## Steps

1. Add the files. Several files, or one folder. With no `--scope` the whole company can read them.

   ```text
   brahma resource <company> add ~/Documents/brief.md ~/Documents/pricing.csv
   ```

   Each file is printed as `added F-<n> ...` with its scope and trust. Text files you wrote are `FROM YOU`; document types (PDF, Office, HTML, SVG, mail, RTF, zip), text over `64 KB` and quarantined downloads are `EXTERNAL`.

2. Scope a file to one agent, a team or an item when it should not reach the whole company.

   ```text
   brahma resource <company> add ~/Documents/launch-plan.pdf --scope agent:@cto
   ```

3. Set the trust mark yourself when the default is wrong. `--vouch` marks a file trusted whatever its type; `--untrusted` makes agents read it as untrusted data.

   ```text
   brahma resource <company> add ~/Documents/spec.pdf --vouch
   ```

4. If a file looks like it holds a secret, the add is refused with `add --redact to upload a redacted copy, or --anyway to upload it flagged`. Upload a redacted copy, or `--anyway` to store it flagged (never indexed, mirrored or returned by the tools). A value already stored as a secret is never uploaded raw.

   ```text
   brahma resource <company> add ~/Documents/config-notes.txt --redact
   ```

5. Add a link instead of a file. It is stored by URL only and is never fetched.

   ```text
   brahma resource <company> link https://example.com/spec --scope team:platform
   ```

:::note
A CLI drop appears in each reader's next orientation under "New resources". A tainted resource is announced by ref only, never by its name. To change who reads one later: `brahma resource <company> scope F-<n> <scope>`. To clear taint later: `brahma resource <company> vouch F-<n>`.
:::

## Check it worked

```text
brahma resource <company> list
```

Every resource is listed on one line: `F-<n> · <kind> · "<name>" · <size> · <scope> · FROM YOU` or `EXTERNAL (<reason>)`, then `· added <day>`. In the app, **Work › Resources** shows the same table. Agents read a resource through `recall(ref: "F-n")`; company-scope, untainted, unflagged files also appear read-only at `.brahma/resources/company` in the workspace.

## Related

- [Resources](/docs/concepts/resources/): scopes, the vault, the mirror, the checks before anything is stored
- [Taint and vouch](/docs/safety/taint-and-vouch/): what an agent may still do after reading outside content
- [Secrets and the owner key](/docs/safety/secrets/): storing a value as a secret instead of uploading it
- [Purge a resource](/docs/guides/purge-a-resource/)
- CLI: [`brahma resource`](/docs/cli/resource/), [`brahma secret set`](/docs/cli/secret/set/)
