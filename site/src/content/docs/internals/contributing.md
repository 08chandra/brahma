---
title: Contributing
description: "How to build and test Brahma, where plans and specs live, how to build this site, and the licence contributions are accepted under."
sidebar:
  order: 4
---

## Build and test

Brahma is a Swift package. The README states the requirements and the commands:

> Requires macOS 14+, Swift 6 and the `claude` CLI on your `PATH`, logged in.

```
swift build
swift test                                   # unit tests, no network
BRAHMA_LIVE=1 swift test --filter LiveSmokeTests   # real claude turns (haiku), uses subscription quota
```

The binary is `.build/debug/brahma` (or `swift run brahma ...`). The Mac app is built with `scripts/make-app.sh`, which produces `.build/Brahma.app`.

:::note
The live smoke tests run real `claude` turns and spend some of your plan's quota. Everything else runs offline.
:::

## Conventions

- **Plans and specs** live under `docs/superpowers/`: design specs in `docs/superpowers/specs/`, implementation plans in `docs/superpowers/plans/`. The [Decisions](/internals/decisions/) pages distil the specs; the specs themselves are the source of truth.
- **`.superpowers/`** at the repository root is local and private. It is never committed and nothing in it is documented here.
- **`BrahmaCore` stays portable.** Mac-only behaviour (Keychain, Seatbelt, AppKit, SpriteKit) lives in the other targets or behind protocols; see the [architecture](/internals/architecture/) page for which target owns what.
- **Public API** is what the [API reference](/api/) shows. Types that the app or the CLI do not need stay internal.

## Building this site

The website is a static Astro site in `site/`. From the repository root:

```
scripts/site-build.sh                     # generators (if present) → npm ci → Chromium → OG images → build → checks
scripts/site-build.sh --skip-generators   # fast content iteration; skips screenshots, CLI and API reference
```

Inside `site/`, `npm run dev` serves the site with live reload and `npm run check:links` verifies that every root-relative link in the build resolves. The CLI reference under `/docs/cli/` and the API reference under `/api/` are generated at build time and are not committed; `site/README.md` describes the generators and the deployment switches.

## Licence

Brahma is licensed under the Apache License, Version 2.0 ([full text](/license/)). Contributions are accepted under the same licence: by submitting a change you license it under Apache-2.0, with no additional terms (inbound = outbound). Keep the `LICENSE` and `NOTICE` files as they are.
