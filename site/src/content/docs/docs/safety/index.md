---
title: Safety
description: "How Brahma limits what agents can touch: profiles, the sandbox, the taint rule, secrets, the sandbox canary, the emergency stop and backups. Each page says what the piece does and what it does not do."
sidebar:
  order: 2
---

## What it is

Every agent turn is a headless run of the `claude` CLI on your Mac, under your user account. Brahma puts limits around each turn: where it may read and write, which hosts it may reach, what it may decide after it has read outside content, and which secrets it may ever see. It also keeps the records you need when something goes wrong: a stop that halts everything, and backups you can restore.

These pages describe each limit as the code enforces it. Every page ends with a **What it does not do** section. Read those first if you are deciding whether to run a company on your machine.

## How it works

| Page | One line |
| --- | --- |
| [Profiles](/docs/safety/profiles/) | `sandboxed` (the default), `workspace` or `full`: what a turn may touch under each, and why only the first is a sandbox. |
| [The sandbox](/docs/safety/sandbox/) | What a Sandboxed turn and an engine-run check cannot do; the network allowlist. |
| [Taint and vouch](/docs/safety/taint-and-vouch/) | What a session may still do after it has read outside content; lab marks; grants and presets; how you vouch. |
| [Secrets and the owner key](/docs/safety/secrets/) | Where secrets live, who can read them, redaction, test keys, and the key that gates owner commands. |
| [The sandbox canary](/docs/safety/canary/) | The self-test whose probes you write. Sandboxed companies wait until it passes. |
| [Emergency stop](/docs/safety/emergency-stop/) | `brahma stop` and STOP EVERYTHING: what is cancelled and what is not. |
| [Backups and restore](/docs/safety/backups/) | What is backed up, when, and what a restore carries forward. |

The short version:

- The **Sandboxed** profile is the only one that confines an agent's shell. **Workspace** is a tool allow-list, not a sandbox. **Full** gives agents your whole Mac.
- The engine, not the agent, runs checks, decides reviews and merges into `main`. On Workspace and Full, an agent's shell can still edit the database or the repository directly.
- A session that has read outside content is tainted until the agent's next fresh session. It can keep working, but it cannot decide, approve or ask for access, and what it writes is marked.
- Secrets live in the Keychain. Agents never receive one, except a test key you created with `--test` and the agent asked for on an item it holds.
- Sandboxed companies do not run until the sandbox canary has passed for your `claude` build and your probe file.

## What it does not do

Brahma is a set of limits, not a promise. In particular:

- It does not sandbox the Workspace or Full profiles. On those profiles an agent's Bash runs as your user.
- It does not make verification, approvals or taint marks tamper-proof on Workspace and Full. An agent's shell can edit the database, the git repository, or the taint flag files.
- It does not test more of the sandbox than your canary probes ask. The canary is as thorough as the probes you write.
- It does not stop a process that an earlier Workspace or Full turn left running when you switch the company back to Sandboxed. Check `ps`.
- It does not redact the `claude` CLI's own copy of each session transcript under `~/.claude/projects`. Brahma's captured copy is redacted; the CLI's is not.
- Other Seatbelt mount routes beyond the known DiskArbitration and `mount_*` routes have not been exhaustively reviewed. Live tests have not been run.

Each page lists its own limits in more detail.

## Related

- [Companies](/docs/concepts/companies/) (where the profile is set)
- [Reviews and the merge queue](/docs/concepts/reviews-and-merge-queue/)
- [Troubleshooting](/docs/troubleshooting/)
