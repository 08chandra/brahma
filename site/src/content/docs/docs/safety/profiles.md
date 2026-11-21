---
title: Profiles
description: "Sandboxed, Workspace and Full: what an agent turn may touch under each profile, how a company's profile is set and narrowed, and why only Sandboxed is a sandbox."
sidebar:
  order: 3
---

## What it is

A profile is the set of limits an agent turn runs under. Every company has one, and a role inside a company can have its own. There are three:

| Profile | What it is | Agent's shell |
| --- | --- | --- |
| `sandboxed` (the default) | Each turn is confined with macOS Seatbelt to its own places in the company workspace. | Sandboxed. |
| `workspace` | A tool allow-list (shell, file tools, company tools) started in the workspace. | Runs as your user. **Not a sandbox.** |
| `full` | Every permission check bypassed. | Runs as your user, anywhere. |

The engine (`brahma run`, or the app) applies the profile to every turn it starts.

## How it works

**Setting it.** `brahma company profile <company> sandboxed|workspace|full [--role <id>]` sets a company's profile. With `--role`, only that role's agents get it; it overrides the company's profile for them.

**Narrowing it.** `brahma run --profile sandboxed|workspace|full` is a ceiling on every turn. It can narrow a company's profile, never widen it. A company set to `full` runs `sandboxed` under `brahma run --profile sandboxed`; a company set to `sandboxed` stays sandboxed under `brahma run --profile full`.

**Sandboxed.** The turn's shell, file tools and helper programs are confined. It can write only in its own places: the item turn's worktree, or the agent's lab, plus its home and its notes file. It cannot read your home folder (apart from the toolchain's read-only places and paths you grant), Brahma's data home, credentials, other companies' workspaces or `/Volumes`. Its network is limited to an allowlist. [The sandbox](/docs/safety/sandbox/) lists everything it blocks.

**Workspace.** The `claude` CLI is started in the workspace with a tool allow-list. The agent's Bash runs as your user and can read and write anything you can. That includes the Brahma database, so an agent on this profile can impersonate other agents or alter their state, and it includes other companies' workspaces. Brahma's own checks still apply to the agent's *tools*: resource scopes, lab privacy and the refusal of owner commands from inside a turn. The shell is outside them.

**Full.** Every permission check is bypassed. Use it only for companies and prompts you trust completely.

**Checks follow the profile.** An item's check runs under Brahma's own Seatbelt policy, not the turn's, for Sandboxed and Workspace companies. A check runs unconfined as your user only when its company's profile, and the profile of the item holder's role when there is one, are still Full after the `brahma run --profile` ceiling.

**Every profile.** Each turn ignores your personal `claude` settings, plugins, MCP servers and `CLAUDE.md` files (`--setting-sources ""`). A `CLAUDE.md` in the workspace is not loaded either. Each turn gets an allowlisted environment: `PATH, HOME, LANG, LC_*, TERM, USER, LOGNAME, SHELL, DEVELOPER_DIR, TMPDIR`, minus anything named like a token, secret or key, plus `BRAHMA_AGENT_ID`; never `BRAHMA_DEV`.

**Sub-agents and Ultra.** Sub-agents and the Ultra work mode run only on Sandboxed companies, and only once their probe gates pass. See [Modes and pacing](/docs/concepts/modes-and-pacing/).

## In the app

**Settings › Company** has a **Permissions** panel: the profile for every agent turn, a confirmation before Full, and per-role overrides. A `Full access` chip shows while the company or any role is on `full`. Its **Network** panel holds the Bash egress domains, WebFetch domains, local binding and toolchain read paths. The New company sheet creates companies on the default, `sandboxed`.

## From the CLI

- [`brahma company profile`](/docs/cli/company/profile/)
- [`brahma run`](/docs/cli/run/) (`--profile`)
- [`brahma network`](/docs/cli/network/) (what a sandboxed turn may reach)
- [`brahma lab clear-taint`](/docs/cli/lab/clear-taint/) (`--machine-wide`, after a Full-profile session)

## What it does not do

- **Workspace does not sandbox the shell.** It is a tool allow-list. The agent's Bash can read and write anything your user can, including the database, the MCP configs, the owner key and its hash, and other companies' workspaces.
- **Full bypasses every permission check.** Nothing below this line applies to it.
- **Switching back to Sandboxed does not stop strays.** A process an earlier Workspace or Full turn left running keeps running. Check `ps`.
- **Verification and approvals are not tamper-proof on Workspace and Full.** Merges and owner approvals are engine-owned for every agent *tool*, but an agent's shell can edit the database or the git repository directly, or run the `brahma` CLI. Brahma refuses owner commands when `BRAHMA_AGENT_ID` is set and strips `BRAHMA_DEV` from turns, but an agent can unset variables.
- **Taint flags can be cleared or forged on Workspace.** By removing or writing the flag files or editing the database. The Sandboxed profile blocks this.
- **A nested `claude`** launched from an agent's Bash on Workspace or Full can load your settings and Keychain auth. Brahma sets environment defusers; an agent can unset them.
- **Secrets in the environment.** On Workspace and Full an agent's Bash can inherit `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY` when you set them for the `claude` CLI. On Sandboxed the shell prefix unsets them before each Bash command.
- **A Full-profile turn that read outside content marks every lab on the machine.** Only you clear that mark. See [Taint and vouch](/docs/safety/taint-and-vouch/).

## Related

- [The sandbox](/docs/safety/sandbox/)
- [Companies](/docs/concepts/companies/)
- [Secrets and the owner key](/docs/safety/secrets/)
