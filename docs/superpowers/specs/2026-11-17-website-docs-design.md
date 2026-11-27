# Brahma website and documentation — design

Date: 2026-11-17. Owner: chandra. Status: approved 2026-11-19 (owner delegated all decisions; license chosen).

## Intent

Brahma needs a public home. The person who lands on it is an **AI developer who
wants to use Brahma to run a company of AI agents**. The site has one job above
all others: **get that developer from "what is this?" to a running company as
fast as possible**, and then be the place they come back to when they need to
understand something — including how Brahma itself is built.

The owner's words: the site "should be simple but get the dev up and running as
fast as possible", and "the entire codebase should also have documentation on
the site". Installation is the developer's choice: "either have an installer
for a stable version or build from source". The code "will be on GitHub
eventually". The owner handed every other decision to the builder; those calls
are marked **(builder's call)** below so the owner can check them.

## Goals

1. **Fast start.** A developer who arrives cold can install Brahma and watch
   their first company's agents pick up work within one page of instructions.
2. **Two install paths, side by side:** a stable installer, or build from
   source. Both converge on the same first-company steps.
3. **Usage docs:** concepts, guides and a complete CLI reference.
4. **Codebase docs:** an architecture overview, a page per module, design
   decisions, and a generated API reference for every public Swift symbol.
5. **Looks like the product.** The site uses the app's own design language
   (docs/superpowers/specs/2026-10-20-visual-design.md), so the site and the
   app feel like one thing.
6. **Stays accurate.** Everything that can be generated from the code is
   generated (CLI reference, API reference), so it cannot drift.

## Non-goals

- Pricing, accounts, sign-up, payments or a waitlist. (builder's call: nothing
  is for sale yet, and the project notes say Anthropic's terms on commercial
  use of subscriptions must be checked before selling anything.)
- A blog, changelog feed, newsletter, community forum or analytics/tracking.
- A hosted/online version of Brahma or any live connection to a real engine.
- The release pipeline itself (signing, notarizing, packaging the installer).
  It is a separate small project; see "Installer dependency" below.

## Anti-goals (would make it a failure even if it works)

- Marketing fluff that delays the developer from getting started.
- Any claim the code does not back up: no invented benchmarks, "secure by
  default"-style guarantees, customer logos or testimonials.
- Anything that looks like Palantir's or Anthropic's branding, names, logos or
  assets. The visual language is "inspired by", per the visual-design spec, and
  must stay original.
- Docs that contradict the shipped behaviour. Where hand-written docs and code
  disagree, the code wins and the docs are fixed.
- Leaking anything private: no secrets, no owner data, no internal ledgers or
  agent transcripts on the public site.

## Audience and tone

AI developers comfortable with a terminal, Git and Swift tooling. Plain,
direct, technical English; short sentences; copyable commands; screenshots of
the real app. No hype words.

## Site structure

```
/                 Home: one-line pitch, real console screenshot, "Get started",
                  "Build from source", GitHub link (when public), a 4-step
                  "how it works" strip, 3–4 capability cards linking into docs.
/start            Quick start (the backbone):
                    1. Install — two tabs: Installer | Build from source
                    2. Connect Claude (claude CLI login; what Brahma needs)
                    3. Create your first company
                    4. Give it a goal; watch agents claim work, open reviews,
                       and merge; where to look in the app
                    5. Next steps
/docs/...         Using Brahma
  concepts/       companies, agents and roles, work items, asks, sprints,
                  modes and pacing, reviews and the merge queue, memory,
                  handbook, resources, previews and hosting, the agent map
  safety/         profiles, sandbox, taint and vouch, secrets, the canary,
                  emergency stop, backups
  guides/         task-oriented how-tos (e.g. add an agent, set a main check,
                  drop files for agents, purge a resource, deploy a preview)
  cli/            generated: one page per `brahma` command and subcommand
  troubleshooting
/internals/...    Inside Brahma (codebase docs)
  architecture    the big picture: engine/orchestrator, turns, MCP tools,
                  store (GRDB), sandbox, app model, app views, CLI; a diagram
  modules/        one page per module: BrahmaCore areas (Access, Backup,
                  Engine, Extensions, Git, Handbook, Hosting, Lifecycle, MCP,
                  Memory, Messaging, Model, Modes, Org, Owner, Platform,
                  Preview, Release, Resources, Safety, Sandbox, Scheduler,
                  Store, Timers, Turns, Verify, Work, Orchestrator), plus
                  BrahmaAppModel, BrahmaApp, BrahmaMapKit, BrahmaKeychain,
                  CSandboxCheck, and the brahma CLI
  decisions/      design decisions distilled from docs/superpowers/specs
  contributing    build, test, project conventions, how plans/specs work
/api/             generated Swift API reference (all public symbols)
```

"Dynamic pages" means pages generated from content and code, not a server:
concept, guide, module and decision pages come from content files; CLI and API
pages come from the code at build time. (builder's call)

## How it is built (builder's calls)

- **Location:** a new `site/` directory in the agent-company repo, so the site
  and docs live next to the code they describe and change in the same commits.
- **Framework:** Astro with its Starlight docs theme (content collections,
  Markdown/MDX, sidebar navigation, built-in Pagefind search), with custom
  Astro pages for Home and Quick start. Static output; no server.
- **Hosting:** Cloudflare Pages (already Brahma's default deploy adapter).
  Domain is TBD and not needed to build or preview.
- **Theme:** the visual-design spec's tokens ported to CSS variables (bg0–bg4,
  line, text0–2, accent #2D72D2, status colors); Starlight restyled to match:
  hairline panels, 2–3 pt corners, small uppercase section labels, monospace
  for commands, IDs and numbers, color only where it means something.
  **Dark only**, matching the app. Body text must meet WCAG AA contrast on the
  dark background; keyboard navigation and visible focus throughout.
- **Product imagery:** real screenshots from the app's snapshot targets
  (the `.superpowers/ui` / snapshot tests the plans already produce), never
  mock-ups that show features the app does not have.
- **CLI reference:** generated from the swift-argument-parser definitions
  (`brahma --experimental-dump-help` JSON, or the equivalent) into one page per
  command at build time.
- **API reference:** generated from the Swift source and doc comments with
  DocC (symbol graphs → static DocC output) and published under `/api`, themed
  as close to the site as DocC's theme settings allow. Public symbols are
  covered; modules with thin doc comments get their prose on the module pages.
- **Usage content sources:** today's README (982 lines: build, commands, work
  system, agent map, safety, live/preview/deploy, memory/handbook/resources,
  backups) is split and rewritten into the concept/guide pages; the specs feed
  the decisions pages. The README shrinks to a short intro that links to the
  site.
- **Freshness check:** a script (run in the normal test flow) regenerates the
  CLI reference and fails if the committed pages are stale, and checks that
  every internal link resolves.

## Build, deploy and generated content (builder's calls, after the builder check)

- **Where it builds:** on the owner's Mac (macOS + Xcode are needed for the CLI
  dump, DocC and screenshots). Deploys use `wrangler pages deploy` (direct
  upload), not Cloudflare's git-connected Linux builds.
- **What is committed:** content files, generator scripts and the theme. The
  generated CLI pages, DocC output and screenshots are build artifacts and are
  not committed. The "freshness check" is therefore: the site build runs the
  generators from the current code, and fails if a generator fails or any
  internal link (including links into `/api` and CLI pages) is broken.
- **API reference size:** ~6,800 public symbols. If the DocC output exceeds
  Cloudflare Pages' 20,000-files-per-deployment limit, `/api` is published as a
  second Pages project (e.g. `api.<domain>`) and the main site links to it.
- **Deploy access:** the builder builds and previews locally. The real
  Cloudflare deploy is an owner step (`wrangler login` + one deploy command,
  documented in `site/README.md`). The builder never handles a Cloudflare token.
- **README:** stays as it is until the site goes live; shrinking it to a stub
  that links to the site is a go-live step, not part of this build (it avoids
  conflicts with Plans 4a and C, which edit the README).
- **Quick-start verification:** automated with the repo's fake Claude
  (`scripts/fake-claude.sh` via `BRAHMA_CLAUDE`), plus one real end-to-end run
  of the build-from-source path on the owner's subscription (a few cents).
  Owner-only interactive steps (`brahma owner init`, Keychain prompts) are
  documented exactly and checked by the owner once.

## Installer dependency

The "Installer" tab needs a stable, signed and notarized Brahma app (with the
`brahma` CLI) published somewhere (e.g. GitHub Releases). That release pipeline
does not exist yet and needs the owner's Apple Developer account for
notarization. Until it exists, the Installer tab says the first stable release
is coming and points to Build from source. When it exists, only that tab's
download link and checksum change.

## License (owner decision, 2026-11-19)

Brahma is licensed under **Apache-2.0** (owner: "use an open source license
that would be best for me as the dev"). The repo root carries `LICENSE` (the
official Apache-2.0 text) and `NOTICE` ("Copyright 2026 The Brahma Authors";
the Brahma name and logo are not licensed). The site footer says "Apache-2.0",
the Build-from-source and Contributing pages link to LICENSE, and Contributing
states that contributions are accepted under Apache-2.0 (inbound = outbound).

## Public-repo dependency

The repo will be public on GitHub "eventually". The site is built and
previewed privately now. Links that need the public repo (clone URL, "view
source" links on module pages, GitHub button) come from one config value and
stay hidden until it is set. Nothing else waits on it.

## Constraints

- Must not touch the Swift targets or their tests, except adding doc comments
  and a docs-generation script; the site can be built in parallel with Plans
  4a and C without conflicts.
- Works with the repo's existing toolchain on macOS 14+; Node is needed only to
  build the site.
- Nothing private is published (see anti-goals). The `.superpowers/` ledgers,
  agent transcripts and owner data are never site content.

## Left to the builder

Exact page copy, page order inside each section, diagram style, which
screenshots go where, Starlight component overrides, how DocC output is themed
and linked from module pages, and the exact generator scripts — within the
decisions above.

## Done when

- `/start` takes a developer from nothing to a running first company, via
  build-from-source, verified by following it on a clean checkout.
- Every `brahma` command has a generated reference page.
- Every module listed above has an internals page, and `/api` covers all
  public symbols.
- The site builds to static files on the Mac, previews locally, and passes the
  generator and link checks; the deploy command is documented for the owner.
- An owner review of the Home and Quick start pages.
