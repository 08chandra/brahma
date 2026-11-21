# Brahma site design system

The app's ops-console language on the web: dark only, dense, hairline panels, mono numbers,
colour only for meaning. What makes it designed rather than themed is one typographic
contrast — a narrow roman serif for titles over instrument chrome set in a UI sans and an
engineering mono — plus a strict 4 px rhythm.

## Fonts (self-hosted, Latin subsets, OFL-1.1, `font-display: swap`)

| Role | Face | Package | Use |
| --- | --- | --- | --- |
| `--font-display` | Instrument Serif 400 (roman only, never italic) | `@fontsource/instrument-serif` | h1/h2, hero, section titles; sizes ≥ `--step-2` only |
| `--font-sans` | Inter Variable 400–600 | `@fontsource-variable/inter` | body, UI, uppercase labels |
| `--font-mono` | JetBrains Mono Variable 400–500 | `@fontsource-variable/jetbrains-mono` | commands, IDs, numbers, code, timestamps |

Instrument Serif was kept over the hallmark pass's alternatives (Newsreader, Fraunces): its
narrow, high-contrast letters sit closest to a mono's rhythm and read as engraved on an
instrument, not as a magazine. Titles only. Fallback faces (`Inter Fallback` → Arial,
`Instrument Serif Fallback` → Georgia, `JetBrains Mono Fallback` → Courier New) carry
`size-adjust`/`ascent-override`/`descent-override` measured in Chromium, so the swap shifts
no layout (CLS 0). The three above-the-fold woff2 files are preloaded in `SiteHead`. The generated
API reference (`/api`, DocC, outside Astro) gets the same faces from `api-theme/fonts.css`, which
`scripts/site-api-docs.sh` links from every page.

## Type scale (`--step--1 … --step-5`, ratio ≈ 1.25, fluid at the top)

Base `--step-0` is 14 px on docs, 16 px on hero pages (`[data-has-hero]`). `--step--1` 12 px · `--step-0` base · `--step-1` 1.2 × base · `--step-2` 20→24 px ·
`--step-3` 24→32 px · `--step-4` 32→48 px · `--step-5` 44→80 px. Dense UI text (buttons, the console feed, card bodies) uses `--text-ui` (13 px). Labels use `--text-label`
(11 px, uppercase, tracking 0.08em, weight 600) and chips `--text-chip` (10 px).
Line heights: display 1.02–1.1, headings 1.2, docs body 1.6, Home body 1.55. Numbers are
always `font-variant-numeric: tabular-nums`.

## Spacing (`--s-1 … --s-9`, 4 px base)

4 · 8 · 12 · 16 · 24 · 32 · 48 · 64 · 96. Component internals use s-1…s-4, panels s-3/s-4,
section gaps on docs s-6, Home sections s-8/s-9. Corner radius is 2 px everywhere
(`--radius`); hairlines are 1 px `--line`, emphasised ones `--line-strong`.

## Grid

Home: 12 columns, 1200 px max (`--grid-max`), 24 px gutter, 24 px page padding (16 below
48 em). Docs: Starlight's 3-column frame — 16 rem sidebar, 46 rem content, right TOC — under
a 48 px header. Titles sit on the left column; nothing is centred.

## Colour rules

Tokens are verbatim from the visual-design spec (`tokens.css`). Chrome is grey; `--accent`
marks selection, focus and the primary button only; status colours mark status only.
No shadows. No gradients except one radial `bg1 → bg0` behind the Home hero. The Home hero,
the 404 and the OG cards sit on the agent-map grid from the visual spec (`--grid-line`
#18202A, 1 px lines every 24 px; a 1.14:1 texture — text crossing a line keeps AA: text1
7.70:1, link 5.13:1, text2 3.84:1 for its large-text use). `--series-violet` (#C774E8, charts/series 4) colours only the console's state-change
glyph, as in the app. Links are
`--text-link` (#4C90F0, the one blue that passes AA on every surface) with a 1 px underline
offset 3 px. Primary buttons use white text on `--accent` (4.72:1); hover darkens the fill to
`accent` 85 % over `bg0` (white 5.85:1) — lightening it would drop white text to 3.69:1.

### Measured WCAG contrast (`node` one-off, sRGB relative luminance)

| fg \ bg | bg0 #0E1217 | bg1 #141A21 | bg2 #1A2129 | bg3 #212A33 | bg4 #2A3540 |
| --- | --- | --- | --- | --- | --- |
| text0 #E6EBF0 | 15.66 | 14.60 | 13.53 | 12.13 | 10.41 |
| text1 #A7B3BF | 8.81 | 8.21 | 7.61 | 6.82 | 5.85 |
| text2 #6E7C89 | 4.39 | 4.09 | 3.79 | 3.40 | 2.92 |
| text-link #4C90F0 | 5.87 | 5.46 | 5.07 | 4.54 | 3.90 |
| accent #2D72D2 | 3.98 | 3.71 | 3.44 | 3.08 | 2.65 |

Rules that follow: `text0`/`text1` are fine everywhere at any size. `text2` is below the
4.5:1 AA threshold on every surface, so **it is never a text colour**: use it only for
non-text marks (ticks, glyphs, icon strokes, separators, the `aria-hidden` `$` prompt, the
docs' heading-anchor icon), disabled states, and large text ≥ 24 px regular / 18.66 px bold
(the 3:1 threshold, met on bg0–bg3). `accent` is a UI colour (≥ 3:1 for focus rings, borders,
fills), never a text colour; text on accent is white.

## Motion

`--dur-fast` 120 ms (hover), `--dur` 200 ms (state and the `.reveal`), `--dur-slow` 600 ms (only the
console's new-line flash, a hold-then-fade the visual spec fixes at 600 ms), one
easing `--ease: cubic-bezier(.2,.7,.2,1)`. Only `opacity`/`transform` animate. `.reveal`
fades and rises 6 px, staggered 60 ms by `--i`; the running chip's dot pulses. Everything
stops under `prefers-reduced-motion: reduce`. Focus rings never animate.

## Components

`<Label>` 11 px uppercase tracked `text1` (no text2 tone) · `<Panel title>` bg2, 28 px bg3 header strip,
1 px line, radius 2 · `<Chip status>` 18 px, 1 px status border + 15 % fill, 6 px dot,
`text0` label · `<Button variant="primary|ghost" href>` 32 px (sm 26; 44 / 40 on coarse
pointers, where every control is ≥ 40 px), radius 2. Every control has hover, focus-visible
(2 px accent ring, offset 2 px), active, disabled; see `/styleguide`. Screen-reader-only text
uses Starlight's `.sr-only` (no local copies). On coarse pointers an inline link grows its
target with `padding-block` taken back by a negative `margin-block`, so rows keep their height.

## Titles

The root page alone puts the name first (`Brahma · The governed local AI org`); every other page
is Starlight's `<page> | Brahma`.
