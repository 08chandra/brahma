---
title: Set a main check
description: "Give a company a smoke check the engine runs on every new main and before every deploy. An ops-role agent sets it; you ask for it, run it on demand and read its result."
sidebar:
  order: 4
---

## Goal

Have a smoke check on `main`, so that `main` is red while it fails and no deploy can start.

## Before you start

- The company has a repository with something to check: a build or a test command that passes on `main` today.
- The company has an agent whose role carries the ops tools. In the built-in `software` pack those are the executives (`ceo`, `cpo`, `cto`, `ceo-cpo`, `cto-architect`), `architect` and `devops`. Engineers cannot set it.
- Know that the smoke check is set by an agent, not by a CLI command. The agent tool is `set_smoke_check`. There is no `brahma` command that writes it; the commands below ask for it, run it and show its result.

## Steps

1. See whether the company already has one. The last line of the release list reports the smoke check on `main`.

   ```text
   brahma release list <company>
   ```

   With no check it ends `main <commit>: smoke no smoke check`.

2. Ask an ops-role agent to set it. Name the command you want and say that it must pass on `main`. The agent calls `set_smoke_check`; the engine runs that command sandboxed in a clean export of `main`, with a `600` second timeout by default and at most `3600`.

   ```text
   brahma say <company> @cto "Set the smoke check on main to: npm ci && npm test. It must pass on main as it is now."
   ```

3. Follow the agent's reply.

   ```text
   brahma log <company> @cto
   ```

4. Run the check on `main` now, instead of waiting for the next merge.

   ```text
   brahma release smoke <company>
   ```

:::caution
While the check fails, `main` is red: the engine files a bug and refuses deploys until a merge turns it green. A check that fails for a reason outside the code (the network, your account, the disk) is re-run and not counted. Before you ask for a strict check, make sure it passes on `main` as it is.
:::

## Check it worked

```text
brahma release list <company>
```

The last line reads `main <commit>: smoke passed` once the run has finished; `not run` means the engine has not reached it yet. Releases above it show each deploy and its smoke result. If the line still says `no smoke check`, the agent has not set one; read its reply with `brahma log`.

:::note
A smoke check is not a work-item check. Each work item carries its own check command that the engine runs when the item is submitted (`brahma items add --check`, `brahma items edit --check`). See [Work items](/docs/concepts/work-items/).
:::

## Related

- [Previews and hosting](/docs/concepts/previews-and-hosting/): the smoke check, the deploy ask and what the engine does with them
- [Reviews and the merge queue](/docs/concepts/reviews-and-merge-queue/): what happens on every new `main`
- [The sandbox](/docs/safety/sandbox/): what an engine-run check cannot do
- CLI: [`brahma release list`](/docs/cli/release/list/), [`brahma release smoke`](/docs/cli/release/smoke/), [`brahma say`](/docs/cli/say/), [`brahma log`](/docs/cli/log/)
