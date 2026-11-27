---
title: The sandbox canary
description: "The self-test that vouches for the sandbox: probe lines you write, each expected to be denied, run model-free and then in one small turn built like a real one. Sandboxed companies wait until it passes."
sidebar:
  order: 7
---

## What it is

The sandbox canary is a self-test of the sandbox on your machine, for your `claude` build. Its probes are yours: one shell command per line, each a thing the sandbox is meant to stop. The canary runs them and checks that every one was denied and that a planted token never leaked.

Before a sandboxed turn starts, its `claude` build, turn shape and your probe file must have passed. Until then the agent waits and you get a sandbox-check alert naming the reason. Workspace and Full companies run without it.

## How it works

**The probe file.** `brahma canary edit` opens `<data home>/canary/probes.txt` in `$EDITOR` (default `vi`). When the file is missing it is created holding only header comments; the engine does the same. It must be a regular file you own, mode `0600`, never a link. Each line is one shell command, expected to be `DENIED`. A line ending in `# helper` is warn-only.

**Planted places.** Probes refer to `$CANARY_HOME_FILE`, `$CANARY_DATA_FILE`, `$CANARY_OUTSIDE_DIR` and `$OTHER_AGENT_LAB`, places where Brahma plants a dummy `BRAHMA-CANARY-<uuid>` token for the run. They are passed as environment variables, never spliced into the command. The planted places must not change during either run.

**Two layers.** Every probe runs twice.

1. **Model-free**, through a throwaway agent's shell prefix inside Brahma's own Seatbelt profile, the one around checks and previews: `10` s each, after a positive control that must succeed. This vouches for that sandbox, not for the agent turn's. The doctor reports it as `sandbox-canary-local`.
2. **One small haiku turn** built like a real sandboxed turn of the shape being verified: the real compiled settings, both hooks, budget- and time-capped. It is judged only from its raw stream. Each probe's tool result must be an error or a non-zero exit. A probe the model did not run, a command not found (exit `127`), or a probe stopped by one of the `claude` CLI's permission rules (it never reached the sandbox) fails as unverified. No stream line may contain the token: raw, encoded, its bare UUID or base64. The Read of the home token must be a permission denial. The session may have no tool, plugin, skill or MCP server beyond the expected ones. Only this layer vouches for the agent turn's sandbox. The doctor reports it as `sandbox-canary`.

**The key.** The file's SHA-256 is part of the canary key, with the `claude` build and the turn shape. Any edit to the probes needs a new pass.

**Running it.** `brahma canary run` runs both layers for the turn shape of each running sandboxed company, prints each line's verdict, exit status and redacted output, and records the passes (with the file's SHA prefix and probe count). The engine also runs it when a sandboxed agent waits, backing off after failures, and never pays for a turn whose shape it cannot build. `brahma doctor` reports `sandbox-backend`, `sandbox-canary-local`, `sandbox-canary` and `sandbox-helpers` without recording a pass.

**Writing probes.** The `claude` CLI's permission rules deny `launchctl`, `security`, `osascript`, `open`, `crontab`, `at`, `sudo`, `screencapture` and `claude` by name. Write such probes in a form the rules do not match, such as an absolute path (`/bin/launchctl`) or `sh -c '...'`, or the canary fails them as not run. A probe must test something the sandbox is meant to stop. `osascript -e 'get name of ...'` of the Finder, for one, is answered locally by LaunchServices and is not an escape test; real Apple events are gated by macOS Automation consent.

**The alert.** When a sandboxed agent cannot start, the sandbox-check alert names the first reason: a missing probe file, no probes (only comments or `# helper` lines), a probe line that failed, or a leak. It is answered when a pass is recorded for the waiting key.

## In the app

The sandbox-check alert appears as an engine alert in the company, quoting the first reason and each probe's summary (never a probe's output). It is resolved when a pass is recorded for the waiting key.

## From the CLI

- [`brahma canary edit`](/docs/cli/canary/edit/), [`brahma canary run`](/docs/cli/canary/run/)
- [`brahma doctor`](/docs/cli/doctor/)
- [`brahma mode gates`](/docs/cli/mode/gates/) (the probe gates for sub-agents and Ultra, separate from the canary)
- [`brahma why`](/docs/cli/why/)

## What it does not do

- **It checks only what your probe lines ask.** The canary is as thorough as the probes. A sandbox hole no probe tests is not found. Ultra's V-9 gate is pending for the same reason.
- **The model-free layer does not vouch for agent turns.** It vouches for Brahma's own Seatbelt profile, the one around checks and previews. Only the second layer vouches for the turn's sandbox.
- **It does not build fan-out shapes.** An Ultra (workflow) turn's shape is not built, so the canary reports `not run` for it.
- **A pass is for one key.** A new `claude` build, a changed probe file or a different turn shape needs a new pass.
- **It does not gate Workspace or Full companies.** They run whether or not the canary has passed.
- **Helper probes are warn-only.** A `# helper` line that succeeds shows under `sandbox-helpers` as a warning and does not block.
- **It spends a little of your plan.** The second layer is a real haiku turn.

## Related

- [The sandbox](/docs/safety/sandbox/)
- [Profiles](/docs/safety/profiles/)
- [Troubleshooting](/docs/troubleshooting/#sandbox-denial)
