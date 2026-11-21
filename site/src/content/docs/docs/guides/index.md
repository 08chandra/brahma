---
title: Guides
description: "Short task guides for the owner: add an agent, keep main green with a smoke check, give agents files, purge a resource, run a preview, run the engine from the terminal, and back up and restore."
sidebar:
  order: 2
---

Each guide does one thing. It names the goal in one line, says what you need before you start, gives numbered steps with one command each, and ends with how to check that it worked.

Every command and flag in these guides was taken from the `brahma` CLI's own `--help` output. The [CLI reference](/docs/cli/) has the same text for every command. In each guide, replace `<company>` with your company's name or slug.

| Guide | What you end up with |
| --- | --- |
| [Add an agent](/docs/guides/add-an-agent/) | A new seat in the org chart, hired with a role, a model and a manager. |
| [Set a main check](/docs/guides/set-a-main-check/) | A smoke check the engine runs on every new `main`, so a red `main` blocks deploys. |
| [Drop files for agents](/docs/guides/drop-files-for-agents/) | Files, a folder or a link the company can read, with the scope and trust you chose. |
| [Purge a resource](/docs/guides/purge-a-resource/) | A resource's bytes, mirror copy and search text removed, with a list of what may still hold it. |
| [Deploy a preview](/docs/guides/deploy-a-preview/) | A web preview the engine builds from `main` and keeps running on a loopback port. |
| [Run from the terminal](/docs/guides/run-from-the-terminal/) | The engine running under `brahma run`, and the commands that watch and steer it. |
| [Back up and restore](/docs/guides/back-up-and-restore/) | A snapshot you took yourself, an off-machine copy, and a restore you tried first as a dry run. |

## Related

- [Concepts](/docs/concepts/): what each piece is and how it works
- [Safety](/docs/safety/): what the limits are and what they do not do
- [Troubleshooting](/docs/troubleshooting/): symptoms and fixes
- [CLI reference](/docs/cli/)
