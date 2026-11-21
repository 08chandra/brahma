---
title: Deploy a preview
description: "Set a web preview the engine builds from main and keeps running on a loopback port: the run command with {port}, the URL, an optional build step and smoke requests; then restart or remove it."
sidebar:
  order: 7
---

## Goal

Have a preview of `main` the engine builds, runs on `127.0.0.1` and restarts whenever `main` moves, so you can open it in the app's **PREVIEW** pane or a browser.

## Before you start

- `brahma preview set`, `remove` and `restart` are owner commands. Agents usually set the preview themselves with `set_preview_command`; use the CLI when you want to set or replace it by hand.
- `main` has a web server to run: a start command that listens on a port you pass it, and a URL where it answers.
- The engine is running (the app, or `brahma run`). A preview is built and started by the engine in a fresh `.git`-free export of `main`, sandboxed except on a Full-profile company; the CLI only records what to run.
- A company may have at most `8` previews. Ports come from `47100`–`47999`.

## Steps

1. List the previews the company has. The default subcommand is `list`.

   ```text
   brahma preview list <company>
   ```

2. Set the preview. Write `{port}` where the engine's port goes, in both `--run` and `--url`. The name is lowercase letters, digits and dashes, at most `24` characters. `--build` runs first; `--smoke` is a request the engine checks, repeatable up to `10` times.

   ```text
   brahma preview set <company> site --build "npm ci && npm run build" --run "PORT={port} npm start" --url http://127.0.0.1:{port}/ --smoke "GET / 200"
   ```

   The CLI answers `Preview site (web) set; the engine builds it from main.`

3. When you change `main` outside Brahma, or the server got stuck, ask for a rebuild.

   ```text
   brahma preview restart <company> site
   ```

4. Remove a preview you no longer need. The engine stops it.

   ```text
   brahma preview remove <company> site
   ```

:::note
A preview is not a deploy. A deploy to Cloudflare Pages or Vercel starts only when you approve a deploy ask in the Inbox, after an ops-role agent has set the hosting, the smoke check and the deploy config and called `propose_deploy`. Set the provider and project with `brahma hosting set`; see [Previews and hosting](/docs/concepts/previews-and-hosting/).
:::

## Check it worked

```text
brahma preview list <company>
```

The line for `site` shows its kind, status, the URL it answers at (or the engine's message while it builds) and the `main` commit it was built from. Open the URL in a browser, or in the app's **PREVIEW** pane in Mission Control, which has a **Restart** button.

## Related

- [Previews and hosting](/docs/concepts/previews-and-hosting/): previews, the smoke check, hosting, the deploy ask, releases and rollback
- [The sandbox](/docs/safety/sandbox/): what the preview's build and run cannot do
- [Set a main check](/docs/guides/set-a-main-check/)
- CLI: [`brahma preview list`](/docs/cli/preview/list/), [`brahma preview set`](/docs/cli/preview/set/), [`brahma preview restart`](/docs/cli/preview/restart/), [`brahma preview remove`](/docs/cli/preview/remove/), [`brahma hosting set`](/docs/cli/hosting/set/), [`brahma release list`](/docs/cli/release/list/)
