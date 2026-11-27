---
title: Secrets and the owner key
description: "Where a company's secrets live, who can read them, how values are redacted, what a test key is, and the owner key that gates owner-write commands and each turn's MCP token."
sidebar:
  order: 6
---

## What it is

A secret is a named value a company's work needs, such as an API key. You store it once; Brahma keeps it in the macOS Keychain and holds it on the engine's side. Agents never receive it, with one exception: a **test key** you created with `--test`, which an agent may ask to have in its environment for an item it holds.

The **owner key** is different. It is a file only you hold, and every owner-write command, including `brahma doctor`, refuses to run unless the file matches a hash kept in the Keychain. It exists so an agent's shell cannot simply run `brahma` as you.

## How it works

**Storing a secret.** `brahma secret set <company> NAME [--test]` reads the value from standard input (or prompts for it in a terminal) and stores it in the Keychain under the service `dev.brahma.secrets`. The database holds only names and flags. `brahma secret list` shows names and flags, never values. `brahma secret rm` removes one.

**Who may read it.** Each Keychain item trusts only the running Brahma binary and its sibling (the app and its bundled `brahma`). Other programs, `/usr/bin/security` included, get the system prompt instead of the value.

**Background reads never prompt.** The engine, `brahma mcp`, other CLI commands and app launch read secrets non-interactively. A read that needs your permission fails, is retried with backoff (`5` s doubling to `5` min) and pauses agents, and Brahma posts one notice: "Secrets need your permission". Run `brahma secret load` (or press **Load secrets** in the app) to allow access; macOS may ask you to allow it, and "Always Allow" ends the asking for that build.

**Nothing runs until every secret has loaded.** The engine starts no turns, checks or merges; `brahma mcp` refuses tool calls ("secrets are not loaded yet; try again shortly"); text writes fail instead of storing unredacted text. Read-only CLI commands never read secrets.

**Redaction.** Values are redacted from everything the engine stores: transcripts, messages, check output.

**Test keys.** A test key (`--test`) needs a name containing `KEY`, `TOKEN` or `SECRET` that is not a variable that changes how programs run (`GIT_*`, `SSH_*`, `DYLD_*`, `LD_*`, `NODE_*`, `PYTHON*`, `*PATH`, `*_OPTIONS`, ...). An agent asks for one with `use_secret` for an item it holds. From its next turn until it releases the item or the item is done, the key is in the agent's environment and its checks'. Every other secret is engine-held: no agent is ever given it.

**Providing one on request.** When an agent asks you for a secret, the ask appears in your Inbox; `brahma secret provide` answers it with a value read from standard input.

**The owner key.** Owner-write CLI commands refuse to run unless `<data home>/owner.key` (mode `0600`) hashes to the SHA-256 held in the Keychain (service `dev.brahma.owner`, account = the data-home path). No owner command creates the key: the Mac app does at launch, or you run `brahma owner init` in Terminal. It needs an interactive terminal. `--rotate` replaces a key and needs the current key to be valid; a lost or invalid key can only be replaced from the app after a user-presence check. The hash is keyed on the canonical (symlink-resolved) data home, and owner commands refuse a database that is a symlink or lies outside it.

**MCP turn tokens.** Each turn's `brahma mcp` only starts with a per-turn token, delivered in the `0600` per-turn MCP config, that is valid while that turn is in progress. Only its SHA-256 is stored. `brahma mcp` refuses a foreign `--agent`, and owner-write commands refuse to run inside an agent turn.

**Temp and demo data homes only.** `BRAHMA_SECRET_STORE=file` keeps values in a `0600` file `<data home>/secrets/vault.json`, and `BRAHMA_OWNER_KEY_STORE=file` keeps the owner-key hash in a `0600` file `<data home>/owner/keyhash`, instead of the Keychain. Both are refused for the default data home and for any other value, and print a warning when used.

## In the app

An engine banner with **Load secrets** appears while the app cannot read every secret; agents are paused until you press it. The **Secrets** panel in **Settings › Company** lists a company's secrets by name and flag; values go to the Keychain. Dropping a file that looks like it holds a secret on a composer opens the secret sheet, which offers **Store it as a secret instead**; see [Resources](/docs/concepts/resources/).

## From the CLI

- [`brahma secret set`](/docs/cli/secret/set/), [`brahma secret list`](/docs/cli/secret/list/), [`brahma secret rm`](/docs/cli/secret/rm/)
- [`brahma secret load`](/docs/cli/secret/load/), [`brahma secret provide`](/docs/cli/secret/provide/)
- [`brahma owner init`](/docs/cli/owner/init/)
- [`brahma doctor`](/docs/cli/doctor/)

## What it does not do

- **The Keychain asks once per item per binary build.** A rebuilt or re-signed binary is a new application to macOS, and only the binaries trusted by the build that last wrote an item can read it. After a rebuild, expect one prompt per secret, answered by `brahma secret load`.
- **The owner key and the turn token are a deterrent, not a security boundary on their own.** The Sandboxed profile denies agents the data home and the Keychain. On the Workspace and Full profiles an agent's shell can read the key, the hash and the MCP configs, or fake a TTY with `script`.
- **A test key does reach the agent.** It is in the environment of every turn and check for the item, for as long as the agent holds it. Create test keys for test accounts only.
- **Redaction covers what the engine stores.** The `claude` CLI keeps its own unredacted copy of each session transcript under `~/.claude/projects`.
- **The `claude` CLI's own credentials are not Brahma secrets.** `claude` receives `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` when you set them (Keychain login needs neither). On Sandboxed the agent's shell prefix unsets them before each Bash command; on Workspace and Full an agent's Bash can inherit them.
- **Secrets and the owner key are never backed up.** A restore does not bring them back; set them again. See [Backups and restore](/docs/safety/backups/).

## Related

- [Profiles](/docs/safety/profiles/)
- [Resources](/docs/concepts/resources/) (the secret sheet)
- [Troubleshooting](/docs/troubleshooting/#keychain-prompt-loops)
