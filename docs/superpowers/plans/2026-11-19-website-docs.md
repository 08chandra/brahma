# Brahma Website + Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A static, award-calibre public site in `site/` that takes an AI developer from "what is this?" to a running Brahma company in one page, and documents how to use Brahma and how Brahma is built — with the CLI and API references generated from the code.

**Architecture:** Astro + Starlight (dark only, restyled to the app's ops-console tokens) with custom Astro pages for Home, Quick start, 404 and a styleguide. Hand-written content lives in `site/src/content/docs/`; three generators (`scripts/site-cli-docs.sh`, `scripts/site-api-docs.sh`, `scripts/site-screenshots.sh`) turn the current code into CLI pages, a DocC API reference under `/api`, and real app screenshots at build time. `scripts/site-build.sh` runs generators → `npm ci` → `npm run build` → checks (links, forbidden strings, Lighthouse), and fails loudly on any gap.

**Tech Stack:** Node 26 / npm 11 (site only, pinned exact versions), Astro 7.4.x, @astrojs/starlight 0.43.x, @fontsource self-hosted OFL fonts, Playwright 1.65.x (screenshots, OG images, Lighthouse's Chromium), Lighthouse 13.x; Swift 6.2 toolchain + Xcode `docc` + swift-argument-parser 1.8 `--experimental-dump-help` for generators.

**Spec:** `docs/superpowers/specs/2026-11-17-website-docs-design.md` (binding) and `docs/superpowers/specs/2026-10-20-visual-design.md` (visual language). Owner direction 2026-11-19 12:10 (ledgered): "make the website look like it won a design award — use fable."

## Global Constraints

- Everything lives in `site/`, `scripts/site-*.sh` and this plan. Do NOT edit `Sources/`, `Tests/`, `Package.swift`, `Package.resolved`, `README.md`, or existing `scripts/*.sh` (Plans 4a and C build in parallel worktrees).
- Nothing private is published: no `.superpowers/` content, transcripts, ledgers, owner names/emails, Keychain or secret values, or build-machine paths (`/Users/...`). Site content names the owner only as "the owner".
- No Palantir or Anthropic branding, names-as-brand, logos or look-alike assets. Claude is referred to only as the `claude` CLI the developer already has. No claims the code does not back up; no benchmarks, logos, testimonials, "secure by default" language.
- Dark only. Tokens verbatim from the visual-design spec: `bg0 #0E1217`, `bg1 #141A21`, `bg2 #1A2129`, `bg3 #212A33`, `bg4 #2A3540`, `line #2F3A45`, `lineStrong #3D4A57`, `text0 #E6EBF0`, `text1 #A7B3BF`, `text2 #6E7C89`, `accent #2D72D2`, `accentDim #1F4F91`, running `#32A467`, ready `#4C90F0`, blocked/danger `#E76A6E`, sleeping `#6E7C89`, killed `#404854`, warning `#EC9A3C`, zebra `#1D252E`; corner radius 2–3 px; hairline 1 px borders; small uppercase tracked labels; monospace for commands, IDs and numbers; colour only where it carries meaning.
- Award bar (owner): distinctive, not template-y; self-hosted OFL-licensed fonts (characterful display face + UI sans + mono); explicit spacing/type scale; tasteful motion that honours `prefers-reduced-motion`; crafted hover/focus states; code blocks with copy buttons; keyboard-navigable with visible focus; a designed 404; OG images; Lighthouse ≥ 95 in all four categories on mobile and desktop; WCAG AA contrast; CLS = 0; no client JS on docs pages beyond Starlight's own (search, tabs).
- Generated output is never committed: `site/src/content/docs/docs/cli/`, `site/public/api/`, `site/public/screenshots/`, `site/public/og/`, `site/src/generated/`, `site/dist/`, `site/.reports/`, `site/.screenshots/`, `site/node_modules/`, `site/.astro/` are gitignored. `site/package-lock.json` IS committed.
- Pin every npm dependency to an exact version (no `^`/`~`). Use `npm ci` in scripts.
- Swift commands run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` under `timeout` (≤ 20 min). Never run the full Swift test suite in this lane.
- Never deploy, never touch a Cloudflare token, never merge or push. The owner's deploy command is documented in `site/README.md`.
- Links that need the public repo (clone URL, GitHub button, "view source") come from one config value `repoURL` in `site/site.config.ts` and render nothing while it is `""`.
- Commit after every task with trailers `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`.
- Models (owner): Fable for every implementer and every design-critique review; Opus (effort high) only for the leak/security review of Tasks 5, 6, 7 (generators that read the repo) and Opus (xhigh) for the final whole-branch review. If Fable hits a limit, pause design-critical tasks (2, 3, 4, 13) rather than downgrade; other tasks may fall back to Sonnet, ledgered.
- Implementers of Tasks 2, 3, 4 and 13 use the `hallmark` skill while designing; Task 13 also runs `design-review`. Task reports for every task that renders a page include headless screenshots at 1440×900 and 390×844 of every page it touched.

## Review Focus

Spec-implied conditions no task's happy path exercises, most likely to bite first. Each has a pinned check in the task named.

1. `repoURL` is `""` (today's state): no GitHub button, no clone URL, no "view source" link, no `href=""` anywhere; the Build-from-source tab says the code is not public yet and the License link still works (`/license`). — Task 3 (`check-forbidden.mjs` asserts no `href=""`), Task 4 (quick-start test renders with `repoURL=""`).
2. `prefers-reduced-motion: reduce`: the Home console hero shows its final frame immediately, nothing animates, no `requestAnimationFrame` loop runs. — Task 3 Playwright test with `emulateMedia({ reducedMotion: 'reduce' })`.
3. A generator's toolchain is missing or a generator fails (no Xcode, `docc` absent, `swift build` error): `scripts/site-build.sh` exits non-zero with the failing step named; it never ships a site with an empty `/api` or `/docs/cli`. — Tasks 5, 6, 7 (`set -euo pipefail`, explicit `command -v`/file checks), Task 13 (`check-generated.mjs` requires ≥ 50 CLI pages, `/api/index.html`, ≥ 6 screenshots).
4. Build-machine or private strings leak through generated output (DocC symbol graphs, dump-help, screenshots, OG): `dist/` is grepped for `/Users/`, `.superpowers`, `BRAHMA_OWNER_KEY`, email addresses, the owner's login name. — Task 13 `check-forbidden.mjs`; Tasks 5–7 run it on their own output.
5. 360–390 px viewports: install tabs, code blocks, the console hero and tables scroll inside their box; the page has no horizontal scroll (`document.documentElement.scrollWidth <= innerWidth`). — Task 13 `screenshots.mjs` asserts per page; Task 4 asserts on `/start`.

---

### Task 1: Site scaffold, config, gitignore, README with deploy command

**Files:**
- Create: `site/package.json`, `site/package-lock.json`, `site/astro.config.mjs`, `site/tsconfig.json`, `site/site.config.ts`, `site/src/content.config.ts`, `site/src/content/docs/docs/index.md`, `site/src/content/docs/internals/index.md`, `site/src/content/docs/license.md`, `site/README.md`, `site/.gitignore`, `scripts/site-build.sh`, `site/scripts/check-links.mjs`
- Modify: `.gitignore` (append `site/node_modules/`, `site/dist/`, `site/.astro/`)

**Interfaces:**
- Produces: `site/site.config.ts` exporting `export const site = { title: 'Brahma', description: string, repoURL: '' as string, apiBase: '/api' as string, license: 'Apache-2.0' }`; `npm run build`, `npm run preview`, `npm run check:links` (runs `node scripts/check-links.mjs dist`); `scripts/site-build.sh` (steps: generators from Tasks 5–7 if their scripts exist → `npm ci` → `npm run build` → `npm run check`); sidebar: one Starlight sidebar with two autogenerated groups `Using Brahma` (`docs/`) and `Inside Brahma` (`internals/`), plus a link item `API reference → /api/`.

- [ ] **Step 1: Scaffold** — `cd site && npm create astro@latest -- --template starlight --no-install --no-git .` equivalent by hand: `package.json` with exact versions (`astro 7.4.13`, `@astrojs/starlight 0.43.1`, `sharp` at the version `npm view sharp version` prints), scripts `dev`, `build`, `preview`, `check:links`, `check` (= `check:links` for now). Run `npm install` to generate the lockfile, then `npm ci` to prove it.
- [ ] **Step 2: Config** — `astro.config.mjs`: `site: 'https://brahma.example'` placeholder read from `site.config.ts`? No: Astro needs a literal; use `'https://brahma.invalid'` and a comment that the owner sets the domain at go-live. Starlight: `title`, `customCss: ['./src/styles/tokens.css']` (file created empty here, filled in Task 2), `sidebar` as in Interfaces, `pagefind: true`, `lastUpdated: false`, `credits: false`, `social` empty (repoURL-gated later), `components: {}`.
- [ ] **Step 3: License page** — `src/content/docs/license.md` with frontmatter `title: License` and body: Brahma is licensed under Apache-2.0; the full text follows; include the LICENSE text via an MDX `import license from '../../../../LICENSE?raw'` in `license.mdx` and a `<pre>` block (verify it renders the Apache header line). The NOTICE text (`Copyright 2026 The Brahma Authors`; name and logo not licensed) appears above it.
- [ ] **Step 4: Link checker** — `site/scripts/check-links.mjs <distDir>`: walk every `.html`, collect `href`/`src` starting with `/` (strip `#...` and `?...`), resolve to `dist/<path>`, `dist/<path>/index.html` or `dist/<path>.html`; print each missing target as `BROKEN <page> -> <href>`; exit 1 if any. Zero dependencies (node:fs + a regex over `href="..."` and `src="..."`).
- [ ] **Step 5: Build script** — `scripts/site-build.sh`: `set -euo pipefail; cd "$(dirname "$0")/.."`; for each of `scripts/site-screenshots.sh scripts/site-cli-docs.sh scripts/site-api-docs.sh`, run it if executable, with `echo "== $step"` before and `exit 1` naming the step on failure; then `cd site && npm ci && npm run build && npm run check`. Accept `--skip-generators` for fast content iteration (prints a warning).
- [ ] **Step 6: README** — `site/README.md`: how to build (`scripts/site-build.sh`), preview (`cd site && npm run preview`), content layout, what is generated, the owner deploy step exactly: `npm i -g wrangler@<pinned>` → `wrangler login` → `wrangler pages project create brahma --production-branch main` (once) → `wrangler pages deploy site/dist --project-name brahma`; the `/api` 20,000-file fallback (second project `brahma-api`, set `apiBase`); the Installer-tab dependency on a notarized release; the public-repo switch (`repoURL`). No token handling anywhere.
- [ ] **Step 7: Verify** — Run `cd site && npm run build && npm run check:links`. Expected: build succeeds; `check:links` prints `0 broken links` and exits 0. Run `git status` and confirm no generated or `node_modules` paths are untracked.
- [ ] **Step 8: Commit** — `git add site scripts/site-build.sh .gitignore && git commit -m "site: Astro + Starlight scaffold, link checker, build script and deploy notes"`.

---

### Task 2: Design system and visual direction (award bar)

**Files:**
- Create: `site/src/styles/tokens.css`, `site/src/styles/typography.css`, `site/src/styles/starlight.css`, `site/src/styles/motion.css`, `site/src/components/Label.astro`, `site/src/components/Panel.astro`, `site/src/components/Chip.astro`, `site/src/components/Button.astro`, `site/src/components/SiteHead.astro` (Starlight `Head` override: forces `data-theme="dark"`, `<meta name="color-scheme" content="dark">`, font preloads, OG tags from `site.config.ts`), `site/src/components/SiteFooter.astro` (Starlight `Footer` override: `Apache-2.0 → /license`, repoURL-gated GitHub link), `site/src/pages/styleguide.astro`, `site/docs/design-system.md` (≤ 80 lines: scale, fonts, rules)
- Modify: `site/astro.config.mjs` (customCss list, `components: { Head, Footer, ThemeSelect: './src/components/Empty.astro' }` to remove the light/dark toggle), `site/package.json` (fonts)

**Interfaces:**
- Produces: CSS custom properties `--bg0..--bg4 --line --line-strong --text0..--text2 --accent --accent-dim --ok --ready --danger --warn --sleep --killed --zebra`; type scale `--step--1 … --step-5` (fluid `clamp()`, base 14 px on docs, 16 px on Home); spacing scale `--s-1 … --s-9` (4 px base: 4, 8, 12, 16, 24, 32, 48, 64, 96); fonts `--font-display`, `--font-sans`, `--font-mono`; motion `--dur-fast 120ms --dur 200ms --dur-slow 600ms --ease cubic-bezier(.2,.7,.2,1)` and `.reveal` (opacity+6 px rise, staggered by `--i`, disabled under `prefers-reduced-motion`). Components: `<Label>` (10–11 px uppercase tracked `text1`), `<Panel title>` (bg2, bg3 28 px header strip, 1 px line, radius 2), `<Chip status>` (18 px, 1 px border + 15 % fill of status colour), `<Button variant="primary|ghost" href>`.
- Fonts (default pairing; the implementer may swap the display face for another OFL face with a ledgered ruling): display `@fontsource/instrument-serif 5.3.0`, sans `@fontsource-variable/inter 5.3.0`, mono `@fontsource-variable/jetbrains-mono 5.3.0`; latin subsets only; `font-display: swap` with `size-adjust` fallbacks (`@font-face` for `Inter Fallback` over Arial) so CLS stays 0.

- [ ] **Step 1: Read** the visual-design spec and `hallmark` skill; write `site/docs/design-system.md` first (fonts, scale, grid: 12-col 1200 px max on Home, Starlight's 3-col on docs, rules: colour only for meaning, no shadows, no gradients except the hero's one radial `bg1→bg0`).
- [ ] **Step 2: Tokens + typography + motion CSS** per Interfaces; Starlight restyle in `starlight.css`: map `--sl-color-*` to tokens, hairline sidebar/panel borders, uppercase tracked group labels, mono for inline code with `bg3` background, table zebra `--zebra`, 2 px radius everywhere, focus ring `2px solid var(--accent)` offset 2 px, link underline offset 3 px, Expressive Code frame restyled (bg1, line border, copy button visible on hover and on focus).
- [ ] **Step 3: Components + overrides** per Interfaces. `SiteHead` emits `<meta property="og:image" content="/og/<section>.png">` where section is the first path segment (`home|start|docs|internals|api`, default `home`); images themselves come in Task 3.
- [ ] **Step 4: Styleguide page** `/styleguide` (frontmatter-free Astro page using `StarlightPage` with `template: 'splash'`, `<meta name="robots" content="noindex">`): every token swatch with its hex, the type scale with sample headlines, the spacing scale, every component in every state (hover/focus/disabled simulated via classes), a code block, a table, a chip row.
- [ ] **Step 5: Verify** — `npm run build`; Playwright one-off (`npx playwright screenshot` is not enough for emulation, so write `site/scripts/screenshots.mjs <baseURL> <out> [paths…]` now: launches Chromium, for each path captures 1440×900 and 390×844 full-page PNGs into `<out>/<slug>-{desktop,mobile}.png`, and asserts `scrollWidth <= innerWidth`). Run it on `/styleguide` against `npm run preview`. Check contrast of `text1` on `bg2` and `text2` on `bg0` with a contrast tool in the script (`text2 #6E7C89` on `#0E1217` is ≈ 4.6:1; use `text2` only ≥ 14 px regular or 11 px uppercase bold). Put the screenshots in the task report.
- [ ] **Step 6: Commit** — `git commit -m "site: design system — tokens, type scale, fonts, Starlight restyle, components, styleguide"`.

**Review:** design-critique (Fable) against the award bar and the visual-design spec; "looks fine" is a fail; up to 5 fix rounds.

---

### Task 3: Home page, console hero, 404, OG images

**Files:**
- Create: `site/src/pages/index.astro`, `site/src/pages/404.astro`, `site/src/components/ConsoleHero.astro`, `site/src/data/hero-activity.json` (static, invented demo company data — company "Initech"-style names from `scripts/seed-demo.sh` are fine; no real handles/emails), `site/src/components/HowItWorks.astro`, `site/src/components/CapabilityCards.astro`, `site/scripts/gen-og.mjs`, `site/src/og/template.html`, `site/tests/home.spec.mjs`
- Modify: `site/package.json` (`playwright 1.65.1` devDependency, scripts `og`, `test:ui`), `site/astro.config.mjs` (nothing new unless needed)

**Interfaces:**
- Consumes: Task 2 tokens/components; screenshot `/screenshots/console.png` (Task 7; until then the page must build with the file absent — use `import.meta.glob('/public/screenshots/*.png')`-free approach: a plain `<img src="/screenshots/console.png">` wrapped in a `<Panel>`; Task 13's `check-generated.mjs` guarantees the file at full build).
- Produces: `/`, `/404`, `public/og/{home,start,docs,internals,api}.png` (1200×630, generated by `npm run og` which renders `src/og/template.html?title=…&kicker=…` in Playwright Chromium), `npm run test:ui` (Playwright tests; needs a running `npm run preview` on port 4321 — the script starts it).

- [ ] **Step 1: Write the failing tests** `site/tests/home.spec.mjs` (plain `node:test` + Playwright, no test-runner package):
  - `home has no GitHub link while repoURL is empty`: `page.locator('a[href=""]').count() === 0` and no `a` whose text matches `/github/i`.
  - `console hero honours reduced motion`: with `emulateMedia({ reducedMotion: 'reduce' })`, `[data-hero-state]` equals `"final"` within 50 ms and `window.__heroFrames` (counter the hero increments per animation tick) stays 0 after 1 s.
  - `console hero animates otherwise`: `window.__heroFrames > 5` after 1.5 s, and the hero's visible line count is ≥ 6.
  - `404 renders the designed page`: `/does-not-exist` → title contains `404`, has a link to `/` and to `/start`.
- [ ] **Step 2: Run** `npm run test:ui` → FAIL (pages missing).
- [ ] **Step 3: Home** per spec: one-line pitch (display face, e.g. "Run a company of AI agents on your Mac." — plain, no hype), two primary actions `Get started → /start` and `Build from source → /start#source`, repoURL-gated GitHub button, `<ConsoleHero>`: a `Panel` styled as the app's activity feed replaying `hero-activity.json` lines (`HH:mm:ss` mono, coloured kind glyph, `@handle`, text) with a 600 ms `bg3` flash per new line and status chips updating counts; pure CSS + ≤ 3 KB inline script, `data-hero-state` attribute, `__heroFrames` counter, static final frame under reduced motion and when JS is off (render all lines server-side, hide-then-reveal only when JS runs). Below: real screenshot panel, 4-step "how it works" strip (Install → Connect `claude` → Create a company → Give it a goal), 3–4 capability cards (Work system → `/docs/concepts/work-items/`, Safety → `/docs/safety/profiles/`, Live previews → `/docs/concepts/previews-and-hosting/`, Inside Brahma → `/internals/architecture/`). Staggered `.reveal` on first paint only.
- [ ] **Step 4: 404** — `404.astro`: mono `text2` empty-state style ("NO SUCH PAGE" label), the path echoed, links to `/`, `/start`, `/docs/`, search hint.
- [ ] **Step 5: OG** — `gen-og.mjs` renders five images from `template.html` (tokens, display face, kicker label, title, a thin status-chip row); `npm run og` writes `public/og/*.png`; `SiteHead` already references them. Add `og` to `scripts/site-build.sh` before `npm run build` (it is a generator; output gitignored).
- [ ] **Step 6: Run** `npm run build && npm run test:ui` → PASS; run `scripts/screenshots.mjs` on `/`, `/404`; put the PNGs in the report.
- [ ] **Step 7: Commit** — `git commit -m "site: home with live-feeling console hero, designed 404, OG images"`.

**Review:** design-critique (Fable) + correctness; Playwright tests must pass in the reviewer's run.

---

### Task 4: Quick start (`/start`) with verified build-from-source path

**Files:**
- Create: `site/src/pages/start.astro`, `site/src/components/InstallTabs.astro` (two tabs, `role="tablist"`, arrow-key navigation, hash-linkable `#installer` / `#source`, no JS fallback = both panels shown stacked), `site/src/content/quickstart/build.sh`, `site/src/content/quickstart/first-company.sh`, `scripts/site-quickstart-check.sh`, `site/tests/start.spec.mjs`
- Consumes: Task 2 components; Task 5 CLI pages for links (`/docs/cli/company/create/` etc. — exact slugs from Task 5 Interfaces); Task 7 screenshots `/screenshots/{inbox,backlog,map}.png` for "where to look".

**Interfaces:**
- Produces: `/start`; `scripts/site-quickstart-check.sh` (exit 0 = the documented commands work against the fake Claude).
- Single source of truth: the page renders `build.sh` and `first-company.sh` verbatim with Expressive Code (`<Code code={raw} lang="sh" title=…>`); the check script executes the same two files.

- [ ] **Step 1: Write the check first** — `scripts/site-quickstart-check.sh`: `set -euo pipefail`; temp `BRAHMA_HOME`/`BRAHMA_WORKSPACES`; `BRAHMA_OWNER_KEY_STORE=file BRAHMA_SECRET_STORE=file BRAHMA_CLAUDE=$PWD/scripts/fake-claude.sh`; `source`-free execution: `bash site/src/content/quickstart/build.sh` then `bash site/src/content/quickstart/first-company.sh` with `BRAHMA=.build/debug/brahma` exported; then run `brahma run` in the background for 20 s and assert `brahma log <company> '#general' --limit 5` contains at least one agent line (read `scripts/smoke-app.sh` for the pattern and `scripts/seed-demo.sh` for owner-init non-interactive flags); kill and clean up. Run it → FAIL (files missing).
- [ ] **Step 2: Write the two scripts** — `build.sh`: prerequisites comment (macOS 14+, Xcode command line tools / Swift 6, `claude` CLI logged in), `git clone <repoURL>` line is NOT in the file (the page prints it from `site.config.ts` only when `repoURL` is set; otherwise a sentence "The repository is not public yet"); `swift build`, `scripts/make-app.sh` optional line; `first-company.sh`: owner init (exact non-interactive form, or documented as interactive with the check script's `BRAHMA_OWNER_KEY_STORE=file` noted as test-only), `brahma company create …  --goal …`, `brahma hire … --role … --model …`, `brahma say … '#general' …`, `brahma run`. Every flag must exist in `brahma --help` output of this tree.
- [ ] **Step 3: Page** — five steps per spec: 1 Install (InstallTabs; Installer tab: "The first stable release is coming; until then build from source", a disabled-looking checksum/download placeholder is NOT shown — only the sentence and a link to `#source`; Source tab ends with "Brahma is Apache-2.0 licensed → `/license`"), 2 Connect Claude (`claude --version`, login, what Brahma needs: `brahma doctor`), 3 Create your first company, 4 Give it a goal — what to watch in the app (screenshots + what each panel shows) and in the terminal, 5 Next steps (links to concepts, safety/profiles, CLI reference). Dense-but-calm: `Label` step numbers, `Panel`s, copy buttons.
- [ ] **Step 4: Tests** `start.spec.mjs`: tabs switch with click and ArrowRight; `#source` hash selects the source tab; at 390 px `scrollWidth <= innerWidth`; no `a[href=""]`.
- [ ] **Step 5: Run** `timeout 1200 scripts/site-quickstart-check.sh` → exit 0 (record elapsed time in the report); `npm run test:ui` → PASS; screenshots of `/start` desktop+mobile in the report.
- [ ] **Step 6: Commit** — `git commit -m "site: quick start with verified build-from-source and first-company scripts"`.

**Review:** design-critique (Fable) + correctness. Reviewer re-runs the check script.

---

### Task 5: CLI reference generator

**Files:**
- Create: `scripts/site-cli-docs.sh`, `site/scripts/gen-cli.mjs`, `site/src/content/docs/docs/cli/.gitkeep`-free (directory is generated), `site/tests/cli-docs.test.mjs`
- Modify: `site/.gitignore` (`src/content/docs/docs/cli/`), `site/astro.config.mjs` sidebar (`Using Brahma` group gets a `CLI reference` autogenerated subgroup from `docs/cli`)

**Interfaces:**
- Produces: `scripts/site-cli-docs.sh` → `swift build --product brahma` (debug) → `.build/debug/brahma --experimental-dump-help > site/.reports/cli-dump.json` → `node site/scripts/gen-cli.mjs site/.reports/cli-dump.json site/src/content/docs/docs/cli`. Pages: `index.md` (table of all top-level commands with abstracts) and one `<path>.md` per command node where path = subcommand names joined by `/` (e.g. `company/create.md` → `/docs/cli/company/create/`); frontmatter `title: brahma company create`, `description: <abstract>`; sections: Usage (synopsis as code), Arguments, Options (table: flag, value, default, help), Subcommands (links). Generated files start with `<!-- generated by scripts/site-cli-docs.sh; do not edit -->`.
- Slugs later tasks link to: `/docs/cli/`, `/docs/cli/<cmd>/`, `/docs/cli/<group>/<sub>/`.

- [ ] **Step 1: Test** `cli-docs.test.mjs` (node:test) with a fixture dump (a 3-command subset JSON you capture from the real dump and commit under `site/tests/fixtures/cli-dump.json`): `gen` writes `index.md`, `company.md`, `company/create.md`; `company/create.md` contains `--goal`; no output file contains `/Users/`; every `subcommands` entry in the fixture has a file.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** `gen-cli.mjs` exporting `generate(dump, outDir): string[]` (returns written paths; CLI entry when run directly). Hidden commands (`shouldDisplay === false`) are skipped. **Step 4:** test → PASS.
- [ ] **Step 5: Script** `scripts/site-cli-docs.sh` with `set -euo pipefail`, `DEVELOPER_DIR`, `command -v swift`, `timeout 900 swift build …`, `rm -rf` the output dir first, and a final count line `cli pages: N` (fail if N < 50). Run it; run `npm run build && npm run check:links` → PASS; `grep -rl '/Users/' site/src/content/docs/docs/cli` → nothing.
- [ ] **Step 6: Commit** (fixture, test, generator, script, gitignore; NOT the generated pages) — `git commit -m "site: generated CLI reference from brahma --experimental-dump-help"`.

**Review:** Opus (high) — leak check of generator inputs/outputs, correctness, and the `/Users/` grep.

---

### Task 6: API reference generator (DocC) + module facts

**Files:**
- Create: `scripts/site-api-docs.sh`, `site/scripts/gen-module-facts.mjs`, `site/api-theme/theme-settings.json`, `site/src/components/ModuleFacts.astro`, `site/public/api/` (generated), `site/src/generated/modules.json` (generated), `site/tests/module-facts.test.mjs`
- Modify: `site/.gitignore` (`public/api/`, `src/generated/`), `site/README.md` (20,000-file rule and the measured count)

**Interfaces:**
- Produces: `scripts/site-api-docs.sh`: `swift build -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc .build/symbol-graphs` (debug; all targets via `swift build` with no `--product`), then for each module in `BrahmaCore BrahmaAppModel BrahmaApp BrahmaMapKit BrahmaKeychain CSandboxCheck brahma`: `docc convert` with an empty `.docc` catalog named for the module, `--additional-symbol-graph-dir .build/symbol-graphs`, `--transform-for-static-hosting`, `--hosting-base-path api/<module-lowercase>`, `--output-path site/public/api/<module-lowercase>`; copy `theme-settings.json` (tokens: background bg0, text text0, accent, mono font stack) into each output; write `site/public/api/index.html` (static page in the site's style listing the modules → `/api/<module>/documentation/<module>/`); `node site/scripts/gen-module-facts.mjs .build/symbol-graphs site/src/generated/modules.json`; print `api files: N` and fail if `N > 19000` unless `BRAHMA_API_SPLIT=1` (documented fallback).
- `modules.json` shape: `{ "<Module>": { "symbols": number, "byArea": { "<Area>": { "files": string[], "types": [{ "name", "kind", "path": "/api/<module>/documentation/<module>/<slug>/" }] } } } }` where Area = the first directory under `Sources/BrahmaCore/` for BrahmaCore (from each symbol's `location.uri`), top-level files map to area `Orchestrator`; for other modules one area = module name. Paths are repo-relative (strip everything through `/Sources/`).
- `<ModuleFacts module="BrahmaCore" area="Work" />` renders a "Public API" panel: symbol count, type list with `/api` links, and the file list.

- [ ] **Step 1: Test** `module-facts.test.mjs` with a small committed symbol-graph fixture (hand-trimmed 3 symbols with `location.uri` containing a `/Users/…/Sources/BrahmaCore/Work/Foo.swift` path): output has area `Work`, `files` = `["BrahmaCore/Work/Foo.swift"]`, no `/Users/` anywhere in the JSON. **Step 2:** → FAIL. **Step 3:** implement `buildFacts(graphDir, outFile)`. **Step 4:** → PASS.
- [ ] **Step 5: Script** per Interfaces (`set -euo pipefail`, `DEVELOPER_DIR`, `xcrun --find docc`, `timeout 1200`). Run it; record `api files: N` and wall time in the ledger; open `/api/brahmacore/documentation/brahmacore/` in the preview and confirm a known type (e.g. `Orchestrator`) resolves. `grep -rl '/Users/' site/public/api | head` → nothing (DocC emits relative `location`s only when `--include-source` is absent; if hits appear, strip via a `sed` pass and note it).
- [ ] **Step 6:** `npm run build && npm run check:links` → PASS. **Step 7: Commit** (scripts, theme, component, test fixture; nothing generated) — `git commit -m "site: DocC API reference under /api and module facts from symbol graphs"`.

**Review:** Opus (high) — leak check (symbol graphs carry doc comments and paths), 20k-file ruling, link integrity.

---

### Task 7: Screenshots generator

**Files:**
- Create: `scripts/site-screenshots.sh`, `site/scripts/optimize-screenshots.mjs`
- Modify: `site/.gitignore` (`public/screenshots/`)

**Interfaces:**
- Produces: `site/public/screenshots/{console,inbox,backlog,board,map,handbook,resources}.png` (names fixed; Tasks 3, 4, 8–10 link to them) plus `@2x` variants, optimised with `sharp` (max width 1600, PNG palette).
- Uses only `scripts/make-app.sh debug` + `scripts/ui-snapshot.sh <name> [select]` (fresh seeded temp home, fake Claude, never the real data home — read the script header) and copies from `.superpowers/ui/<name>.png`. Selects: `console` = default view, then `inbox backlog board map handbook resources` (check `ui-snapshot.sh`'s `case` list for the exact select words; `map` may need `BRAHMA_SNAPSHOT_COMPANY`).

- [ ] **Step 1: Script** with `set -euo pipefail`, `DEVELOPER_DIR`, `timeout 1200 scripts/make-app.sh debug` (skip when `.build/Brahma.app` is newer than `Sources/` unless `--rebuild`), loop over the seven names, fail if any PNG missing, `node site/scripts/optimize-screenshots.mjs .superpowers/ui site/public/screenshots`.
- [ ] **Step 2: Run** it; confirm seven PNGs, each < 400 KB after optimisation; view two of them and confirm only seeded demo data (company names from `seed-demo.sh`, no real paths, no owner name) is visible.
- [ ] **Step 3:** `npm run build && npm run check:links` (Home now has its real screenshot) → PASS. **Step 4: Commit** `git commit -m "site: real app screenshots from the snapshot targets (generated, not committed)"`.

**Review:** Opus (high) — the reviewer looks at every screenshot for private data; correctness of the never-real-home guarantee.

---

### Task 8: Concepts pages

**Files:**
- Create under `site/src/content/docs/docs/concepts/`: `index.md`, `companies.md`, `agents-and-roles.md`, `work-items.md`, `asks.md`, `sprints.md`, `modes-and-pacing.md`, `reviews-and-merge-queue.md`, `memory.md`, `handbook.md`, `resources.md`, `previews-and-hosting.md`, `agent-map.md`

**Interfaces:** Consumes README sections (`## Commands`, `## Work system`, `## Agent map`, `## Live…`, `## Memory, Handbook and Resources`), the specs, and CLI slugs from Task 5. Produces the slugs above (Home cards and Quick start link to `work-items`, `previews-and-hosting`).

- [ ] **Step 1:** For each page: frontmatter `title`, `description`, `sidebar: { order }`; sections `What it is` (≤ 120 words), `How it works` (mechanics from README/code, each number or limit quoted exactly as README/code states it), `In the app` (which panel; screenshot where one exists), `From the CLI` (links to `/docs/cli/...` pages), `Related`. Plain English, short sentences, no hype. Where README and code disagree, read the code (`grep -rn` in `Sources/BrahmaCore/<Area>`) and follow the code; note the discrepancy in the task report.
- [ ] **Step 2:** `npm run build && npm run check:links` → PASS (every CLI link resolves). Screenshots of two pages desktop+mobile in the report.
- [ ] **Step 3: Commit** `git commit -m "site(docs): concept pages"`.

**Review:** Fable — accuracy spot-check of three mechanics against code; tone; no private/branding violations.

---

### Task 9: Safety pages and troubleshooting

**Files:**
- Create under `site/src/content/docs/docs/safety/`: `index.md`, `profiles.md`, `sandbox.md`, `taint-and-vouch.md`, `secrets.md`, `canary.md`, `emergency-stop.md`, `backups.md`; and `site/src/content/docs/docs/troubleshooting.md`

**Interfaces:** Consumes README `## Safety`, `## Backups`, `Workspace profile limits`, `brahma doctor` output (`Sources/brahma/DoctorCommand.swift`), Task 5 slugs.

- [ ] **Step 1:** Same page shape as Task 8 plus a `What it does not do` section on every safety page (explicit limits; no guarantees language). Troubleshooting: one `###` per symptom (`claude` not found / wrong version, lock held by `brahma run`, Keychain prompt loops, sandbox denial, usage limit reached, preview port busy) with the exact doctor/CLI check and fix.
- [ ] **Step 2:** `npm run build && npm run check:links` → PASS; two page screenshots in the report. **Step 3: Commit** `git commit -m "site(docs): safety and troubleshooting pages"`.

**Review:** Fable — accuracy and "no over-claiming" check.

---

### Task 10: Guides

**Files:**
- Create under `site/src/content/docs/docs/guides/`: `index.md`, `add-an-agent.md`, `set-a-main-check.md`, `drop-files-for-agents.md`, `purge-a-resource.md`, `deploy-a-preview.md`, `run-from-the-terminal.md`, `back-up-and-restore.md`

- [ ] **Step 1:** Each guide: `Goal` (one line), `Before you start`, numbered steps with one copyable command each (flags verified against `brahma <cmd> --help` output from the built binary — run it, paste nothing you did not see), `Check it worked`, `Related`.
- [ ] **Step 2:** `npm run build && npm run check:links` → PASS; two screenshots. **Step 3: Commit** `git commit -m "site(docs): task guides"`.

**Review:** Fable — every flag verified against `--help` by the reviewer.

---

### Task 11: Internals — architecture, decisions, contributing

**Files:**
- Create: `site/src/content/docs/internals/architecture.mdx`, `site/src/components/ArchitectureDiagram.astro` (hand-authored inline SVG using tokens: engine/orchestrator → turns → MCP tools → store (GRDB) → sandbox; app model → app views; CLI; labels in the site's mono/uppercase style, `<title>`/`<desc>` for a11y), `site/src/content/docs/internals/contributing.md`, `site/src/content/docs/internals/decisions/index.md` + one page per spec: `one-orchestrator-headless-turns.md` (agent-company-design), `brahma-v2.md`, `agent-modes.md`, `collab-preview.md`, `extensions.md`, `traceability.md`, `visual-design.md`, `research-improvements.md`

- [ ] **Step 1: Architecture** (≤ 900 words): the diagram, then one paragraph per box naming the module/area and linking to its module page (Task 12 slugs: `/internals/modules/<module-lowercase>/` and `/internals/modules/brahmacore/<area-lowercase>/`) and to `/api`.
- [ ] **Step 2: Decisions**: each page `Context / Decision / Consequences / Source` (source = spec file name only). Distil; do not paste specs. Omit anything personal (owner quotes are fine only when they state product intent; never names, dates of personal events, costs paid).
- [ ] **Step 3: Contributing**: build/test commands from README, conventions (plans and specs under `docs/superpowers/`, `.superpowers/` is local and private), how to run the site build, licence paragraph: contributions are accepted under Apache-2.0 (inbound = outbound) with a link to `/license`.
- [ ] **Step 4:** `npm run build && npm run check:links` (module links will fail until Task 12 — create `internals/modules/index.md` placeholder here so the check passes; Task 12 fills it). Screenshots. **Step 5: Commit** `git commit -m "site(internals): architecture, decisions, contributing"`.

**Review:** Fable — the diagram's accuracy against `Package.swift` and `Sources/BrahmaCore` layout; privacy of the decision pages.

---

### Task 12a: Module pages — BrahmaCore areas

**Files:**
- Create: `site/src/content/docs/internals/modules/index.mdx`, `site/src/content/docs/internals/modules/brahmacore/index.mdx` and one `.mdx` per area: `access, backup, engine, extensions, git, handbook, hosting, lifecycle, mcp, memory, messaging, model, modes, org, owner, platform, preview, release, resources, safety, sandbox, scheduler, store, timers, turns, verify, work, orchestrator`

**Interfaces:** Consumes `<ModuleFacts>` (Task 6). Produces slugs `/internals/modules/brahmacore/<area>/`.

- [ ] **Step 1:** Each page: frontmatter, `Purpose` (≤ 100 words, from reading the area's file headers and type names), `Key types` (3–6, one line each, linked via ModuleFacts or explicit `/api` links), `How it connects` (which areas call it / it calls), `<ModuleFacts module="BrahmaCore" area="…" />`, repoURL-gated "View source" link (`<SourceLink path="Sources/BrahmaCore/<Area>" />` — a tiny component created here that renders nothing when `repoURL === ''`).
- [ ] **Step 2:** `npm run build && npm run check:links` → PASS. **Step 3: Commit** `git commit -m "site(internals): BrahmaCore area pages"`.

**Review:** Fable — three pages checked against the code; no `/Users/` or private content.

### Task 12b: Module pages — other targets

**Files:**
- Create under `site/src/content/docs/internals/modules/`: `brahmaappmodel.mdx`, `brahmaapp.mdx`, `brahmamapkit.mdx`, `brahmakeychain.mdx`, `csandboxcheck.mdx`, `brahma-cli.mdx`

- [ ] **Step 1:** Same shape as 12a; the CLI page links each command group to its generated page. **Step 2:** build + links → PASS. **Step 3: Commit** `git commit -m "site(internals): app, map, keychain, sandbox-check and CLI module pages"`.

**Review:** Fable.

---

### Task 13: Quality gate — forbidden-string, generated-output, screenshot and Lighthouse checks; design audit

**Files:**
- Create: `site/scripts/check-forbidden.mjs`, `site/scripts/check-generated.mjs`, `site/scripts/lighthouse.mjs`, `site/scripts/all-pages.mjs` (lists every `dist/**/index.html` path except `/api/**`)
- Modify: `site/package.json` (`lighthouse 13.6.0` devDependency; `check` = `check:links && check:forbidden && check:generated && check:ui`; `check:lighthouse` separate), `scripts/site-build.sh` (`npm run check` already; add `npm run check:lighthouse` unless `--skip-lighthouse`), `site/README.md`

**Interfaces:**
- `check-forbidden.mjs dist`: fails on any of `/Users/`, `.superpowers`, `BRAHMA_OWNER_KEY`, an email regex, and the login name from `process.env.USER` (never printed to the report, only compared) anywhere in `dist/`; and on `Palantir`, `Anthropic`, `href=""` outside `dist/api/**` (DocC pages carry doc comments verbatim; the reviewer of Task 6 reads the `/api` hits for those two words and rules on them).
- `check-generated.mjs dist`: requires ≥ 50 files under `dist/docs/cli/`, `dist/api/index.html` + `dist/api/brahmacore/documentation/brahmacore/index.html`, the seven screenshots, five OG images.
- `screenshots.mjs` (Task 2) over `all-pages.mjs` output → `site/.reports/screenshots/`, asserting no horizontal overflow at 390 px on every page.
- `npm run screenshots:final`: `screenshots.mjs` over `/`, `/start`, `/docs/concepts/companies/`, `/docs/cli/company/create/`, `/internals/modules/brahmacore/work/`, `/404` into `site/.screenshots/final/` (the owner's "show me the site" set; rerun by the driver after the final fix wave).
- `lighthouse.mjs`: runs Lighthouse (Playwright's Chromium via `CHROME_PATH`) on `/`, `/start`, `/docs/concepts/companies/`, `/docs/cli/`, `/internals/architecture/`, mobile and desktop presets; fails if any category < 95 or CLS > 0; writes JSON + a summary table to `site/.reports/lighthouse/`.

- [ ] **Step 1:** Write the three checkers and the pages lister; run `npm run check` → FAIL only where real gaps exist; fix those gaps in the owning files.
- [ ] **Step 2: Design audit** — run `design-review` on `/`, `/start`, one concept page, one module page, `/docs/cli/company/create/`, `/404` at both widths; fix spacing/hierarchy/slop findings in the theme or page files (not in generated output).
- [ ] **Step 3:** `scripts/site-build.sh` end-to-end (generators included) → exit 0; paste the Lighthouse table and the checker summaries in the report; attach desktop+mobile screenshots of `/`, `/start`, a docs page, a CLI page, a module page, `/api/` index.
- [ ] **Step 4: Commit** `git commit -m "site: quality gate — forbidden strings, generated output, overflow and Lighthouse checks"`.

**Review:** design-critique (Fable) across the whole site at the award bar + correctness of the gates.

---

## Execution notes

- Order: 1 → 2 → 7 → 3 → 5 → 6 → 4 → (8, 9, 10 may run in parallel; distinct files) → 11 → 12a → 12b → 13 → final whole-branch review (Opus xhigh: award bar, privacy, accuracy, constraints) → one fix wave → scoped re-review.
- Task 7 runs before Task 3 so the Home design review sees the real screenshot; Tasks 5 and 6 share the Mac with two other Swift build lanes — run their `swift build`s one at a time.
- Finish (driver, after the final fix wave and scoped re-review): `scripts/site-build.sh`, then `cd site && npm run preview` (URL `http://localhost:4321/`) and `npm run screenshots:final`; the final report lists the absolute paths of the twelve PNGs in `site/.screenshots/final/` and the exact preview command and URL.
- Owner steps after this plan (documented in `site/README.md`): `wrangler login` + deploy; the notarized installer release (Installer tab text/link change only); set `repoURL` when the repo is public; owner review of Home and Quick start; one real end-to-end quick start on the owner's subscription.
