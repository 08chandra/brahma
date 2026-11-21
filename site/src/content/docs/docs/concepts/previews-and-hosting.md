---
title: Previews and hosting
description: From a goal to a URL you can open. A preview the engine keeps running from main, a smoke check that keeps main green, a hosting provider you pick, a deploy you approve, releases, rollback and human tasks.
sidebar:
  order: 12
---

## What it is

A company goes from a goal to a URL in the same way every time: a walking skeleton, a preview the engine keeps running from `main`, a smoke check that keeps `main` green, then a deploy you approve.

Agents never deploy. They set the preview command, the smoke check and the deploy config, and propose a deploy. The engine does exactly what you approved, once. Anything only a person can do becomes a human task in your Inbox.

## How it works

**Previews.** A preview is a web server the engine builds from `main` in a fresh `.git`-free export (sandboxed, except on a Full-profile company) and keeps running on a loopback port (`127.0.0.1`, ports `47100`–`47999`, at most `8` per company). It is restarted when `main` moves. The command is written with `{port}` where the engine's port goes (`PORT={port} npm start`, `http://127.0.0.1:{port}/`). A preview never runs from an agent's working tree, and its process group is killed on restart. Agents set it with `set_preview_command`; you can set one with `brahma preview set`.

**Hosting.** You pick the provider and project with `brahma hosting set <company> --provider cloudflare-pages|vercel --project <name>`, or in **Company › Settings › HOSTING**. Cloudflare Pages is the default. Vercel is the alternative; its project must already exist, and a Vercel release needs your production URL in HOSTING. The hosting token arrives through the `hosting-account` human task and goes to your Keychain. It is never in a prompt, an argument, a log or the database, and agents never receive it. On the Workspace and Full profiles, an agent process running at the same moment as a deploy step could read that step's environment; deploy from a Sandboxed company when the token matters.

**The smoke check on `main`.** `set_smoke_check` sets the command the engine runs, sandboxed in a clean export, on every new `main` and before every deploy. Its timeout is `600` seconds by default and at most `3600`. While it fails, `main` is red: the engine files a bug and deploys are blocked. `brahma release smoke` runs it on demand.

**The deploy ask.** `propose_deploy` records a release (`R-<n>`, the exact `main` commit) and puts one ask in your Inbox. It shows the provider and project, the commit, the release notes, the build command and output folder, the smoke check, the deployed site's smoke requests and expected text, and the exact deploy and rollback commands the engine will run. Approving it is the only way a deploy starts. The engine then, each step recorded before the next:

1. checks the commit is still on the engine-accepted `main` and runs the smoke check at it;
2. re-renders the plan and refuses if anything differs from what you approved;
3. records `refs/brahma/main-backup` and `refs/brahma/releases/<version>`;
4. builds in a clean `.git`-free export of the commit, sandboxed, with no secrets, `30` minutes at most;
5. stages the upload: at most `500 MB` and `20 000` files; never a symlink, a hard link or an `.env` file;
6. installs the provider CLI if missing (pinned versions, token-free, in a folder agent code cannot write);
7. runs the deploy steps, `15` minutes each, with the token only in their environment;
8. smoke-checks the live URL, `6` attempts `10` seconds apart;
9. marks the release `deployed` or `failed`.

You are told either way. The redacted deploy and build logs land in `<workspace>/.brahma/releases/R-<n>/`, which agents can read and never write.

**Rollback.** Only the live release can be rolled back. `brahma release rollback <company> R-<n>` or the **Roll Back** button runs the rollback commands recorded with that release, exactly as shown, then smoke-checks the site. A rollback never touches `main` and is never retried by the engine. If the engine stops mid-release, the release records where it was and nothing runs again on restart.

**Human tasks.** The templates are engine-written, with their links, steps and paste-back fields: `hosting-account`, `domain`, `stripe-test-keys` (test-mode keys only) and `launch-post`. Secret values go to the Keychain and are recorded only as "saved". See [Asks](/docs/concepts/asks/).

**The demo.** `brahma company create <name> --demo live` creates the goal-to-URL demo. Do the hosting task, then approve the brief and the deploy when they arrive.

## In the app

Mission Control has a **PREVIEW** pane that loads only the loopback origin, with a **Restart** button and the preview's status. **Work › Releases** lists every release with its status, commit, URL and smoke result; the **PATH TO LIVE** strip shows `main`'s health and the milestones. **Company › Settings › HOSTING** holds the provider, project and production URL. Deploy asks and human tasks arrive in the **Inbox**.

<img src="/screenshots/console.png" srcset="/screenshots/console@2x.png 2x" width="1600" height="1000" alt="Mission Control of a seeded demo company before any preview exists: the PREVIEW pane reads NO PREVIEW, beside the agent-map panel and above the activity feed" loading="lazy" decoding="async" />

*Mission Control in a seeded demo company. The PREVIEW pane fills in once an agent sets a preview command.*

## From the CLI

- [`brahma preview list`](/docs/cli/preview/list/), [`brahma preview set`](/docs/cli/preview/set/), [`brahma preview restart`](/docs/cli/preview/restart/), [`brahma preview remove`](/docs/cli/preview/remove/)
- [`brahma hosting show`](/docs/cli/hosting/show/), [`brahma hosting set`](/docs/cli/hosting/set/)
- [`brahma release list`](/docs/cli/release/list/), [`brahma release show`](/docs/cli/release/show/), [`brahma release rollback`](/docs/cli/release/rollback/), [`brahma release smoke`](/docs/cli/release/smoke/)
- [`brahma task list`](/docs/cli/task/list/), [`brahma task show`](/docs/cli/task/show/), [`brahma task done`](/docs/cli/task/done/), [`brahma task decline`](/docs/cli/task/decline/)
- [`brahma milestones`](/docs/cli/milestones/)

## Related

- [Reviews and the merge queue](/docs/concepts/reviews-and-merge-queue/)
- [Asks](/docs/concepts/asks/)
- [Companies](/docs/concepts/companies/)
