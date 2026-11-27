---
title: Run from the terminal
description: "Run the engine with brahma run instead of the app, cap concurrency and profile, and use status, inbox, log, say, why, stop and resume from a second terminal."
sidebar:
  order: 8
---

## Goal

Run the engine in a terminal, watch what it does, and steer the companies from a second terminal.

## Before you start

- The `claude` CLI is installed and `brahma doctor` passes. `brahma run` refuses to start without a passing report and says `Run 'brahma doctor' for details.`
- The app is not running the engine. Only one engine per data home may run; if the app holds the lock, `brahma run` prints `another Brahma engine (the Brahma app or 'brahma run') is already using <data home>`. Quit the app first. The app may be open while `brahma run` holds the lock: it then shows live state and a banner, and takes over when `brahma run` stops.
- You have two terminals: one for `brahma run`, one for everything else.

## Steps

1. Check the `claude` CLI (`version`, `flags`, a `probe` turn), your `plan-tier`, the sandbox items (`sandbox-backend`, `sandbox-canary`), `backup-targets`, `wal-shipping` and `npm`. One line per check: `PASS`, `WARN` or `FAIL`.

   ```text
   brahma doctor
   ```

2. Start the engine. It prints `brahma running (plan <tier>, up to <n> concurrent turns, profile <ceiling>); Ctrl-C to stop`, where the profile is `per company` or `at most <profile>`, then one line per state change, turn and message. `--hard-cap` caps concurrent turns across all companies (default `16`, and never more than your plan tier allows); `--profile` is a ceiling on every turn's profile and can only narrow a company's own profile, never widen it.

   ```text
   brahma run --hard-cap 4 --profile sandboxed
   ```

3. In the second terminal, see every company's agents, their state, their last turn and the latest usage.

   ```text
   brahma status
   ```

4. See what waits for your decision. `--all` adds FYIs and recent decisions. Answer with `brahma approve <company> A-<n>`, `brahma approve <company> A-<n> --reject --note "<why>"` or `brahma answer <company> A-<n> "<text>"`.

   ```text
   brahma inbox <company>
   ```

5. Post to a channel or an agent. The target is `#channel` or `@handle`.

   ```text
   brahma say <company> "#general" "Please post a short status in #general by the end of the day."
   ```

6. Read a channel or an owner DM. `--limit` is `1`-`1000`, default `30`.

   ```text
   brahma log <company> "#general" --limit 50
   ```

7. When a company shows `0 running`, ask why.

   ```text
   brahma why <company>
   ```

:::caution
`brahma stop` halts every agent, check, preview and deploy in all companies at once, and nothing runs until `brahma resume`. Pressing Ctrl-C in the `brahma run` terminal only ends this engine process: the app takes over if it is open, and nothing is marked stopped.
:::

## Check it worked

```text
brahma status
```

Each company is listed with its agents and `inbox: <n> waiting`. The `brahma run` terminal shows turns starting and finishing, and prints `notice: [<company>] A-<n> ... waits for you: <title>` when an ask needs you. Ctrl-C prints `stopped`.

## Related

- [Modes and pacing](/docs/concepts/modes-and-pacing/): usage modes, the plan tier and how many turns run at once
- [Profiles](/docs/safety/profiles/): what `--profile` narrows
- [Emergency stop](/docs/safety/emergency-stop/): `brahma stop` and `brahma resume`
- [Troubleshooting](/docs/troubleshooting/): the lock held by `brahma run`, `claude` not found, the usage limit
- CLI: [`brahma run`](/docs/cli/run/), [`brahma doctor`](/docs/cli/doctor/), [`brahma status`](/docs/cli/status/), [`brahma inbox`](/docs/cli/inbox/), [`brahma approve`](/docs/cli/approve/), [`brahma answer`](/docs/cli/answer/), [`brahma say`](/docs/cli/say/), [`brahma log`](/docs/cli/log/), [`brahma why`](/docs/cli/why/), [`brahma stop`](/docs/cli/stop/), [`brahma resume`](/docs/cli/resume/)
