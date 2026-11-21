---
title: Troubleshooting
description: "Symptoms and fixes: the claude CLI not found or too old, the engine lock held by brahma run, Keychain prompt loops, a sandbox denial, the usage limit, and a busy preview port. Each entry names the exact check and the exact fix."
sidebar:
  order: 3
---

Start with two commands. `brahma doctor` checks the installed `claude` CLI, the sandbox, your backups and `npm`, and prints one line per check: `PASS`, `WARN` or `FAIL`, the check's name, and a detail. `brahma why <company>` explains why a company has nothing running. Most of the entries below are a line from one of them.

## Symptoms

### `claude` not found, or the wrong version

**What you see.** `brahma doctor` prints `FAIL  version  can't run 'claude --version'; is Claude Code installed?`, or `FAIL  version  <v> is older than the minimum 2.1.312`. The app's engine banner says "Can't find the claude CLI. Install Claude Code, or set BRAHMA_CLAUDE to its path, then relaunch Brahma." `brahma run` refuses to start and says "Run 'brahma doctor' for details."

**Check.**

```text
which claude
claude --version
brahma doctor
```

**Fix.** Install or update the `claude` CLI so that `claude` is on your `PATH` and `claude --version` prints `2.1.312` or newer. If it lives somewhere your `PATH` does not cover, set `BRAHMA_CLAUDE` to its full path in the environment Brahma starts from, then relaunch the app or run `brahma run` again. A version newer than the tested minimum gives `WARN  version`; the `probe` check below it says whether it still works. After any change, run `brahma doctor` again: `brahma run` and the app require a passing report, reused for `24` hours per `claude` version.

If `flags` fails with `missing flag: ...`, the installed `claude` lacks a flag Brahma passes on every turn. Update the CLI. If `sideload-allowed` fails, an administrator's managed settings set `disableSideloadFlags`, which makes the CLI ignore `--plugin-dir` and `--mcp-config`; Brahma cannot run under it.

### The lock is held by `brahma run`

**What you see.** `brahma run` prints `another Brahma engine (the Brahma app or 'brahma run') is already using <data home>`. Or, in the app, the engine banner reads "Engine running in terminal (brahma run). Brahma shows live state and your messages still go through; scheduling happens in the terminal. Brahma takes over when it stops."

**Check.** Only one engine per data home may run: it holds an exclusive lock on `<data home>/orchestrator.lock`. Find the other one:

```text
ps -ax | grep -E 'brahma run|Brahma\.app' | grep -v grep
```

**Fix.** This is not an error. Decide which engine you want. To use the app, stop `brahma run` with Ctrl-C; the app takes over when the lock is released. To use the terminal, quit the app, then run `brahma run`. If no engine is running and the lock still refuses, the previous engine has not exited yet; wait for it, or find it with `ps` and end it. Never delete the lock file while an engine runs: two engines on one database would double-schedule agents.

`brahma restore` also needs the lock free: quit the app and `brahma run` first.

### Keychain prompt loops

**What you see.** macOS asks, again and again, whether `brahma` or Brahma may use an item in your Keychain. Or agents stop and a notice reads "Secrets need your permission"; the agent's turns are held "until it loads".

**Check.**

```text
brahma secret list <company>
brahma notices
```

**Fix.** Background reads never prompt, so the prompt comes from an owner action, and the loop is one prompt per secret, per binary build. Run `brahma secret load` (or press **Load secrets** in the app) once in a terminal and answer **Always Allow** to each prompt. The engine then resumes the held turns.

Why it repeats: each Keychain item trusts only the Brahma binary that wrote it. A rebuilt or re-signed binary is a new application to macOS, so after every rebuild each secret asks once more. A rebuilt development binary also re-prompts for the login password on every Keychain access; for temp or demo data homes only, `BRAHMA_OWNER_KEY_STORE=file` keeps the owner-key hash out of the Keychain. If a secret still fails to load, set it again with `brahma secret set <company> <name>` or remove it with `brahma secret rm <company> <name>`; until every secret has loaded, the engine starts no turns, checks or merges.

If the prompt is for the owner key (service `dev.brahma.owner`) rather than a secret, owner commands need `<data home>/owner.key` to match the hash in the Keychain. The Mac app creates the key at launch, or run `brahma owner init` in a terminal. A lost or invalid key can only be replaced from the app.

### A sandboxed turn is denied

**What you see.** An agent on the `sandboxed` profile reports `Operation not permitted`, a read it could not do, a host it could not reach, or `command not found` for a tool outside the toolchain. Or no sandboxed turn starts at all and the company shows a sandbox-check alert: `missing probe file`, `no probes in <path>`, `probe line N failed`, or a leak.

**Check.**

```text
brahma doctor                 sandbox-backend, sandbox-canary-local, sandbox-canary, sandbox-helpers
brahma network <company>      the effective Bash and WebFetch lists, loopback, toolchain paths
brahma access <company>       open access requests
brahma why <company>
```

**Fix.** Decide first whether the denial is right. The sandbox denies the home folder, the data home, credentials, other companies' workspaces, `/Volumes`, writes outside the turn's own places, hosts off the allowlist and helper programs; [The sandbox](/docs/safety/sandbox/) lists them. If the agent needs the thing:

- A host: `brahma network <company> add <domain>` (`--web` for a WebFetch domain), or approve the agent's request with `brahma access approve <company> A-<n> --scope once|item|agent|role|company --duration turn|sprint|always`. A grant takes effect from the agent's next turn.
- A directory to read: approve the agent's `request_access` the same way.
- A tool outside the toolchain's read-only places: `brahma network <company> toolchain add <path>`.
- A server the agent must listen on: `brahma network <company> local on`.

If the alert is about the canary, the sandbox has not been verified for your `claude` build and probe file. Write probes with `brahma canary edit`, then `brahma canary run`; the agents start when it passes. See [The sandbox canary](/docs/safety/canary/). Do not switch the company to `workspace` to get past a denial: that profile does not sandbox the shell at all.

### Usage limit reached

**What you see.** Nothing runs. `brahma why <company>` prints `usage limit (5-hour) until HH:mm`, or `weekly pace: ... — resumes about ...`, or `deep modes and Ultra are off while extra usage is on`. Mission Control shows a **WHY** banner with the same line. `brahma doctor` may print `FAIL  overage  the account is spending paid overage right now`.

**Check.**

```text
brahma why <company>
brahma status
brahma doctor
```

**Fix.** This is pacing, not a fault. No new turn starts once five-hour utilisation reaches `80%` (low), `90%` (balanced) or `97%` (max), once a request is rejected for usage, or once paid overage is in use. The gate opens when the window resets; `brahma why` prints the time. To run more now, raise the company's mode (`brahma company mode <company> max`) if it is below the threshold you are at, or lower the owner's reserve for the week (`brahma settings share`, or per company `brahma company reserve`). If the `claude` CLI is logged out or the plan changed, the engine holds with "Claude Code is logged out or the plan changed. Log in with `claude`, then run `brahma doctor` (or press Retry in the app)." A passing `brahma doctor` ends that hold. See [Modes and pacing](/docs/concepts/modes-and-pacing/).

### Preview port busy

**What you see.** A preview shows `Failed` in `brahma preview list <company>` with the message `port <p> is used by preview <company>/<name>; use {port} in run and url`, or `no free preview port in 47100…47999`. Or the preview is `Running` but the page does not load because something else listens on that port.

**Check.**

```text
brahma preview list <company>
lsof -nP -iTCP:<port> -sTCP:LISTEN
```

**Fix.** The engine allocates each preview the first free port in `47100`–`47999` and keeps it while the preview runs; at most `8` previews run per company. Write the preview command with `{port}` where the port goes (`PORT={port} npm start`) and the URL as `http://127.0.0.1:{port}/`, with `brahma preview set` or the agent's `set_preview_command`. A literal port in the URL is refused when another preview, of any company, already holds it. If a process outside Brahma holds the port, the allocator skips it; if it holds a port a preview was given, end that process and `brahma preview restart <company> <name>`. If every port is taken, remove previews you no longer need with `brahma preview remove`. See [Previews and hosting](/docs/concepts/previews-and-hosting/).

## Related

- [Safety](/docs/safety/)
- [Quick start](/start/)
- [`brahma doctor`](/docs/cli/doctor/), [`brahma why`](/docs/cli/why/), [`brahma status`](/docs/cli/status/)
