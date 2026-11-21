# Brahma website

The public website and documentation for Brahma, built with [Astro](https://astro.build)
and [Starlight](https://starlight.astro.build). Everything under `site/` is a static site;
the output in `site/dist/` is what gets deployed.

Node and npm are used only inside this directory. The rest of the repository is a Swift package.

## Build

From the repository root:

```
scripts/site-build.sh                     # generators (if present) → npm ci → Chromium → OG images → build → checks → Lighthouse
scripts/site-build.sh --skip-generators   # fast content iteration; skips screenshots, CLI and API reference
scripts/site-build.sh --skip-lighthouse   # everything but the Lighthouse gate (about three minutes)
```

The script runs each generator that exists and is executable (`scripts/site-screenshots.sh`,
`scripts/site-cli-docs.sh`, `scripts/site-api-docs.sh`), printing `== <step>` before each and
failing with the step's name if one fails. It then runs `npm ci`, `npx playwright install chromium`
(the browser the OG generator, the screenshot scripts, Lighthouse and the UI tests drive; a no-op
once installed), `npm run og`, `npm run build`, `npm run check` and `npm run check:lighthouse` in
`site/`. With `--skip-generators` the generated-output check would fail by construction, so the
script runs `check:links`, `check:forbidden` and `check:ui` individually and skips `check:generated`
with a warning. The flags combine.

Inside `site/`:

```
npm ci              # install the exact versions in package-lock.json
npx playwright install chromium   # once per machine: the browser for og, screenshots and test:ui
npm run og          # generate public/og/*.png (Open Graph cards, gitignored)
npm run dev         # local dev server with live reload
npm run build       # static build into dist/
npm run preview     # serve dist/ locally
npm run check:links     # verify every root-relative href/src in dist/ resolves
npm run check:forbidden # fail on private content or forbidden branding in dist/ (see below)
npm run check:generated # fail when the generators' output is missing from dist/
npm run check:ui        # = test:ui
npm run check           # check:links && check:forbidden && check:generated && check:ui
npm run check:lighthouse  # Lighthouse gate (see below); writes .reports/lighthouse/
npm test                # unit tests (node:test, tests/*.test.mjs)
npm run test:ui         # browser tests (tests/*.spec.mjs) against a preview it starts on port 4321; build first
npm run screenshots:all   # every page at 1440 and 390 px into .reports/screenshots/; fails on horizontal overflow
npm run screenshots:final # the owner's "show me the site" set into .screenshots/final/ (12 PNGs)
```

## Quality gate

`npm run check` runs after every build (`scripts/site-build.sh`); `npm run check:lighthouse` runs
after it unless `--skip-lighthouse`. All four read `dist/`, so build first.

- **`check:forbidden`** (`scripts/check-forbidden.mjs dist`) scans every text file in `dist/`.
  Everywhere, including the generated `/api` reference: build-machine paths (`/Users/`),
  `.superpowers`, the `BRAHMA_OWNER_KEY` token, email addresses, and the login name of the user
  running the check (`$USER`, compared but never printed). Outside `dist/api/`: the brand words
  `Palantir` and `Anthropic` (case-sensitive) and empty links (`href=""`). Hits print as
  `path:line: <pattern>` without the matched text. The only allowances, each an exact token, are
  listed at the top of the script: the `claude` CLI's environment-variable names
  (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR`) and the translator credits
  inside Pagefind's vendored search UI. When the checker hits a hand-written page, fix the page;
  do not widen the checker.
- **`check:generated`** (`scripts/check-generated.mjs dist`) requires at least 50 files under
  `dist/docs/cli/`, `dist/api/index.html` and the BrahmaCore DocC index, the seven app
  screenshots (`.png` and `@2x.png`) and the five OG images.
- **`check:ui`** is `test:ui`.
- **`check:lighthouse`** (`scripts/lighthouse.mjs dist`) serves `dist/` itself
  (`scripts/serve-dist.mjs`, a small `node:http` static server on a free port, gzip for text, never
  `astro preview`) and runs the pinned `lighthouse` CLI with Playwright's Chromium (`CHROME_PATH`)
  on `/`, `/start`, `/docs/concepts/companies/`, `/docs/cli/` and `/internals/architecture/`,
  mobile and desktop. Every category must score at least 95 and CLS must be 0. One warm-up run is
  discarded and a run that misses is repeated once (the repeat counts; both are recorded). Output:
  `.reports/lighthouse/<page>-<preset>.json` and `.reports/lighthouse/summary.md`.

Screenshots: `scripts/screenshots.mjs <baseURL | --serve[=distDir]> <outDir> [paths… | -]` captures
each path at 1440×900 and 390×844 and fails on horizontal overflow at either width, naming the page
and the widest element. `--serve` serves `dist/` itself for the run; `-` reads paths from stdin,
which is how `screenshots:all` feeds it `scripts/all-pages.mjs dist` (every `dist/**/index.html`
route except `/api/**`). Both output directories are gitignored.

Every dependency is pinned to an exact version in `package.json`; `package-lock.json` is committed.
Use `npm ci`, not `npm install`, unless you are deliberately changing a dependency.

## Content layout

Starlight maps `src/content/docs/` to the site root.

```
site.config.ts                   title, description, repoURL, apiBase, license (imported by config and components)
astro.config.mjs                 Astro + Starlight configuration, sidebar
src/content.config.ts            content collections (docs, i18n)
src/content/docs/index.md        home page            → /
src/content/docs/404.md          not-found page       → /404
src/content/docs/license.mdx     license + notice     → /license/
src/content/docs/docs/           "Using Brahma"       → /docs/...     (autogenerated sidebar group)
src/content/docs/internals/      "Inside Brahma"      → /internals/...(autogenerated sidebar group)
src/content/i18n/en.json         UI string overrides (none yet)
src/styles/tokens.css            design tokens and the dark-only theme
public/                          static files served as-is (favicon)
scripts/check-links.mjs          zero-dependency link checker over dist/
scripts/check-forbidden.mjs      private-content and branding checker over dist/
scripts/check-generated.mjs      generated-output presence checker over dist/
scripts/all-pages.mjs            lists every page route in dist/ (except /api/)
scripts/screenshots.mjs          page screenshots at 1440 and 390 px + overflow assertion
scripts/serve-dist.mjs           static server for dist/ used by screenshots and Lighthouse
scripts/lighthouse.mjs           Lighthouse gate (five pages, mobile + desktop)
```

The sidebar has two autogenerated groups, "Using Brahma" (`docs/`) and "Inside Brahma"
(`internals/`), plus a link to the API reference at `/api/`.

## Generated content

These paths are produced by `scripts/site-*.sh` at build time and are gitignored; never edit or
commit them:

| Path | Generator | Contents |
| --- | --- | --- |
| `src/content/docs/docs/cli/` | `scripts/site-cli-docs.sh` | CLI reference from `brahma --help` |
| `public/api/` | `scripts/site-api-docs.sh` | DocC API reference, served at `/api/` |
| `public/screenshots/` | `scripts/site-screenshots.sh` | app screenshots |
| `src/generated/modules.json` | `scripts/site-api-docs.sh` | module facts for `ModuleFacts.astro` |
| `public/og/` | build-time generators | social images |

`npm run check:links` is strict about every root-relative link except links into `/api/`: when
`dist/api/index.html` is absent (the API generator did not run) it prints
`SKIP /api/ (generator output absent)` instead of counting them as broken.

### API reference

`scripts/site-api-docs.sh` builds every target (debug, a plain `swift build`), then extracts each
module's public symbol graph from the built modules with `swift-symbolgraph-extract` into
`.build/symbol-graphs` (synthesized members skipped; extracted on every run, so an up-to-date build
still yields every graph). It runs `docc convert` once per module
(`BrahmaCore BrahmaAppModel BrahmaApp BrahmaMapKit BrahmaKeychain CSandboxCheck brahma`) into
`public/api/<module-lowercase>/` for static hosting, so a module's reference is at
`/api/<module>/documentation/<module>/`. A module whose graph has no public symbols (today the
executables `BrahmaApp` and `brahma`) is skipped with a message; a missing graph fails the run.
Each output gets `api-theme/theme-settings.json` (the site's dark tokens and font stacks), every
DocC page links `/api/fonts.css` (`api-theme/fonts.css`, the site's three self-hosted faces, copied
with their woff2 files to `public/api/fonts/`), `public/api/index.html` lists the modules with their
public-symbol counts, and `scripts/gen-module-facts.mjs` writes
`src/generated/modules.json`: per module, the public-symbol count and, per area (BrahmaCore: the
first directory under `Sources/BrahmaCore/`, top-level files → `Orchestrator`; other modules: one
area), the source files and top-level types with their `/api` links.
`<ModuleFacts module="BrahmaCore" area="Work" />` renders that as a "Public API" panel. It says the
reference was not generated when the file is absent, and fails the build for an unknown module or
area. Only repo-relative paths are written; the script fails if any output contains `/Users/`,
`/private/var/` or a `file://` URL.

## Deploy (owner only)

The site is deployed to Cloudflare Pages as a static upload. Nothing in this repository deploys
automatically and no credentials are stored anywhere in it. The owner runs, from the repository root:

```
npm i -g wrangler@4.165.0
wrangler login
wrangler pages project create brahma --production-branch main     # once
scripts/site-build.sh
wrangler pages deploy site/dist --project-name brahma
```

`wrangler login` opens a browser; no token is written to the repository.

### `/api` and the 20,000-file limit

Cloudflare Pages caps a deployment at 20,000 files. The DocC API reference under `public/api/`
is large: DocC writes two files per documented symbol (a page shell and its JSON). Measured on
2026-11-20: `scripts/site-api-docs.sh` printed `api files: 16035`, and the whole `site/dist/` held
16,400 files. That figure depends on `-symbol-graph-skip-synthesized-members`; with synthesized
members (inherited `Equatable`/`Codable`/collection defaults) the same sources gave 39,879 files.
The generator fails when `public/api/` holds more than 19,000 files, leaving headroom for the rest
of the site. If that happens, deploy the API reference as a second Cloudflare Pages project. DocC's
pages load their scripts and data from `/api/<module>/...`, so the second project must serve the
reference under `/api/` too; split mode writes it to `site/.api-deploy/api/` (gitignored) with a
`_redirects` file that sends the project root to `/api/`. From the repository root:

```
wrangler pages project create brahma-api --production-branch main  # once
BRAHMA_API_SPLIT=1 scripts/site-api-docs.sh                         # writes site/.api-deploy/, removes site/public/api
wrangler pages deploy site/.api-deploy --project-name brahma-api
```

Then set `apiBase` in `site.config.ts` to the `brahma-api` project's URL followed by `/api`
(for example `https://brahma-api.pages.dev/api`, no trailing slash) and build and deploy the main site
with the split still set, so the generators do not recreate `site/public/api`:

```
BRAHMA_API_SPLIT=1 scripts/site-build.sh
wrangler pages deploy site/dist --project-name brahma
```

The sidebar's "API reference" link and every `ModuleFacts` type link are built from `apiBase`, so
they point at `<apiBase>/<module>/documentation/<module>/...` on the second project. In split mode
the cap applies to the reference alone: the generator fails above 19,990 files there.

### Domain

`astro.config.mjs` sets `site: 'https://brahma.invalid'` as a placeholder. At go-live the owner
replaces it with the real domain; it affects canonical URLs, the sitemap and social-image URLs.

## Switches that depend on things outside this directory

- **Installer tab.** The Quick start's "Install the app" tab links to a notarized release build.
  It stays hidden until a notarized release exists; the content is written so the CLI path stands
  on its own.
- **Public repository.** `repoURL` in `site.config.ts` is empty until the repository is public.
  Components that link to source, show a repository icon or offer "edit this page" are gated on it
  being non-empty; set it to the repository URL and rebuild.
- **API reference.** `apiBase` in `site.config.ts` defaults to `/api`, the path the DocC generator
  writes under `public/`. Change it only for the two-project deployment above, to
  `<brahma-api project URL>/api`.

## License

Brahma is licensed under the Apache License, Version 2.0 (see `LICENSE` and `NOTICE` at the
repository root). The site renders both at `/license/`.
