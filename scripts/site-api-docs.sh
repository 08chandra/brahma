#!/bin/bash
# API reference for the public site. Usage: scripts/site-api-docs.sh
# Builds every target (debug), extracts each module's public symbol graph from the built modules
# with swift-symbolgraph-extract into .build/symbol-graphs (synthesized members skipped), then
# runs `docc convert` once per Brahma module into site/public/api/<module-lowercase>/ (static
# hosting, served at /api/<module>/documentation/<module>/), copies site/api-theme/theme-settings.json
# into each, links the site's self-hosted fonts (site/api-theme/fonts.css + the three woff2 files,
# served under /api/) from every page, writes the /api/ index page and site/src/generated/modules.json
# (module facts for ModuleFacts.astro) with site/scripts/gen-module-facts.mjs. All output is
# gitignored; never commit it.
#
# The build is a plain `swift build` sharing .build/ with the other scripts, so it reuses their
# work. A module whose graph holds no public symbols (today the executables brahma and BrahmaApp)
# is skipped with a message; a missing graph fails the run. Each module's
# graphs (<Module>.symbols.json plus its <Module>@*.symbols.json extension graphs) are staged
# into a directory of their own before `docc convert`, because DocC documents one module per
# archive and would otherwise load every module's graphs.
#
# Fails when a Swift module's symbol graph is missing, when any generated file contains a
# build-machine path (/Users/, /private/var/) or a file:// URL, when a module-facts type link has
# no DocC page, and when site/public/api holds more than 19,000 files (Cloudflare Pages caps a
# deployment at 20,000; see site/README.md). BRAHMA_API_SPLIT=1 is the documented two-project
# deployment: the reference goes to site/.api-deploy/api/ (deployed as its own project, with a
# root _redirects to /api/) instead of site/public/api, and the cap applies to it alone.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

command -v swift >/dev/null || { echo "site-api-docs: swift not found on PATH" >&2; exit 1; }
command -v node >/dev/null || { echo "site-api-docs: node not found on PATH" >&2; exit 1; }
command -v timeout >/dev/null || { echo "site-api-docs: timeout not found on PATH (macOS: brew install coreutils)" >&2; exit 1; }
DOCC=$(xcrun --find docc) || { echo "site-api-docs: docc not found (xcrun --find docc)" >&2; exit 1; }

MODULES=(BrahmaCore BrahmaAppModel BrahmaApp BrahmaMapKit BrahmaKeychain CSandboxCheck brahma)
GRAPHS=.build/symbol-graphs
STAGE=.build/site-api-docs
FACTS=site/src/generated/modules.json
THEME=site/api-theme/theme-settings.json
FONTS_CSS=site/api-theme/fonts.css
FONT_DIR=site/node_modules
FONT_DISPLAY=@fontsource/instrument-serif/files/instrument-serif-latin-400-normal.woff2
FONT_SANS=@fontsource-variable/inter/files/inter-latin-wght-normal.woff2
FONT_MONO=@fontsource-variable/jetbrains-mono/files/jetbrains-mono-latin-wght-normal.woff2
for f in "$FONT_DISPLAY" "$FONT_SANS" "$FONT_MONO"; do
  [ -f "$FONT_DIR/$f" ] || { echo "site-api-docs: $FONT_DIR/$f not found (run npm ci in site/)" >&2; exit 1; }
done
if [ "${BRAHMA_API_SPLIT:-0}" = "1" ]; then
  # Two-project deployment (site/README.md): the reference is its own Cloudflare Pages project.
  # DocC's pages hard-code /api/<module>/, so the deploy directory keeps an api/ child and the
  # site's apiBase is set to <api-project-url>/api. The main build gets no public/api.
  SPLIT=1
  DEPLOY=site/.api-deploy
  OUT=$DEPLOY/api
  LIMIT=19990 # the whole Cloudflare deployment: api/ plus _redirects, under 20,000
  rm -rf site/public/api "$DEPLOY"
else
  SPLIT=0
  OUT=site/public/api
  rm -rf site/.api-deploy
  LIMIT=19000 # leaves room for the rest of the site in the same deployment
fi

start=$(date +%s)

echo "site-api-docs: building all targets (debug)"
timeout 1200 swift build
BIN=$(swift build --show-bin-path)
SDK=$(xcrun --sdk macosx --show-sdk-path)
EXTRACT=$(xcrun --find swift-symbolgraph-extract)
# The clang module maps SwiftPM passed to swiftc (CSandboxCheck's generated map, GRDB's SQLite
# system library), read from the build description it just wrote.
mapflags=()
while IFS= read -r map; do
  mapflags+=(-Xcc "-fmodule-map-file=$map")
done < <(grep -oE -- '-fmodule-map-file=[^", ]+' .build/debug.yaml | sed 's/^-fmodule-map-file=//' | sort -u)
if [ "${#mapflags[@]}" -eq 0 ]; then
  echo "site-api-docs: no -fmodule-map-file in .build/debug.yaml; cannot extract symbol graphs" >&2
  exit 1
fi
incflags=()
for inc in Sources/*/include; do
  [ -d "$inc" ] && incflags+=(-Xcc -I -Xcc "$PWD/$inc")
done

# Symbol graphs are extracted from the built modules on every run, independent of whether
# `swift build` recompiled anything (swiftc's -emit-symbol-graph only writes for targets it
# rebuilds). Synthesized members (inherited Equatable/Codable/collection defaults) are skipped:
# they were 60% of BrahmaCore's symbols and pushed the output past the deployment file cap.
rm -rf "$GRAPHS"
mkdir -p "$GRAPHS"
for module in "${MODULES[@]}"; do
  if ! timeout 300 "$EXTRACT" -module-name "$module" \
    -target "$(uname -m)-apple-macosx14.0" -sdk "$SDK" \
    -I "$BIN/Modules" "${mapflags[@]}" ${incflags[@]+"${incflags[@]}"} \
    -module-cache-path "$BIN/ModuleCache" \
    -minimum-access-level public -skip-synthesized-members \
    -output-dir "$GRAPHS" >"$STAGE.extract.log" 2>&1; then
    cat "$STAGE.extract.log" >&2
    echo "site-api-docs: swift-symbolgraph-extract failed for $module" >&2
    exit 1
  fi
done
rm -f "$STAGE.extract.log"

rm -rf "$OUT" "$STAGE"
mkdir -p "$OUT" "$STAGE"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

documented=()
symbols=() # public symbol count per documented module, same order (bash 3.2: no associative arrays)
for module in "${MODULES[@]}"; do
  lc=$(lower "$module")
  graphs="$STAGE/$module/graphs"
  catalog="$STAGE/$module/$module.docc"
  mkdir -p "$graphs" "$catalog"
  shopt -s nullglob
  files=("$GRAPHS/$module.symbols.json" "$GRAPHS/$module"@*.symbols.json)
  shopt -u nullglob
  if [ ! -f "$GRAPHS/$module.symbols.json" ]; then
    echo "site-api-docs: no symbol graph for $module" >&2
    exit 1
  fi
  count=$(node -e 'let n = 0; for (const f of process.argv.slice(1)) n += (JSON.parse(require("fs").readFileSync(f, "utf8")).symbols ?? []).length; console.log(n)' "${files[@]}")
  if [ "$count" -eq 0 ]; then
    echo "site-api-docs: $module has no public symbols; skipped"
    continue
  fi
  cp "${files[@]}" "$graphs/"
  echo "site-api-docs: docc convert $module ($count symbols) -> $OUT/$lc"
  t0=$(date +%s)
  timeout 600 "$DOCC" convert "$catalog" \
    --fallback-display-name "$module" \
    --fallback-bundle-identifier "brahma.$lc" \
    --additional-symbol-graph-dir "$graphs" \
    --transform-for-static-hosting \
    --hosting-base-path "api/$lc" \
    --output-path "$OUT/$lc" \
    --diagnostic-level error
  cp "$THEME" "$OUT/$lc/theme-settings.json"
  echo "site-api-docs: $module: $(find "$OUT/$lc" -type f | wc -l | tr -d ' ') files in $(( $(date +%s) - t0 ))s"
  documented+=("$module")
  symbols+=("$count")
done

if [ "${#documented[@]}" -eq 0 ]; then
  echo "site-api-docs: no module was documented" >&2
  exit 1
fi

# The site's fonts for every DocC page: theme-settings.json names the families, this declares
# them. One stylesheet and three woff2 files under /api/, linked from each page's <head>
# (DocC's static hosting writes one index.html per page, so every copy gets the link).
mkdir -p "$OUT/fonts"
cp "$FONTS_CSS" "$OUT/fonts.css"
cp "$FONT_DIR/$FONT_DISPLAY" "$OUT/fonts/display.woff2"
cp "$FONT_DIR/$FONT_SANS" "$OUT/fonts/sans.woff2"
cp "$FONT_DIR/$FONT_MONO" "$OUT/fonts/mono.woff2"
find "$OUT" -name '*.html' -print0 | xargs -0 sed -i '' 's#</head>#<link rel="stylesheet" href="/api/fonts.css"></head>#'

# The /api/ index: a plain static page outside Astro in the site's own language (tokens inline,
# the display serif for the title, mono module names and symbol counts in hairline rows).
{
  cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0E1217">
<title>API reference | Brahma</title>
<meta name="description" content="DocC reference for Brahma's Swift modules.">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="preload" as="font" type="font/woff2" href="/api/fonts/sans.woff2" crossorigin>
<link rel="preload" as="font" type="font/woff2" href="/api/fonts/display.woff2" crossorigin>
<link rel="preload" as="font" type="font/woff2" href="/api/fonts/mono.woff2" crossorigin>
<link rel="stylesheet" href="/api/fonts.css">
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; background: #0E1217; color: #E6EBF0; font: 16px/1.6 'Inter Variable', 'Inter Fallback', Arial, sans-serif; -webkit-font-smoothing: antialiased; }
  main { max-width: 46rem; margin: 0 auto; padding: 4rem 1.5rem 3rem; }
  .kicker { margin: 0 0 1rem; font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: #A7B3BF; }
  h1 { margin: 0 0 0.75rem; font-family: 'Instrument Serif', 'Instrument Serif Fallback', Georgia, serif; font-weight: 400; font-size: clamp(2rem, 1.6rem + 2vw, 3rem); line-height: 1.04; letter-spacing: -0.012em; }
  .lede { margin: 0 0 2rem; max-width: 58ch; font-size: 1.2rem; line-height: 1.5; color: #A7B3BF; }
  ul { margin: 0; padding: 0; list-style: none; border: 1px solid #2F3A45; border-radius: 2px; background: #1A2129; }
  li { border-top: 1px solid #2F3A45; }
  li:first-child { border-top: 0; }
  li a { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; min-height: 2.75rem; padding: 0.625rem 1rem; color: #E6EBF0; text-decoration: none; font-family: 'JetBrains Mono Variable', 'JetBrains Mono Fallback', 'Courier New', monospace; font-size: 0.875rem; transition: background-color 120ms cubic-bezier(.2,.7,.2,1); }
  li a:hover { background: #212A33; }
  li a:focus-visible { outline: 2px solid #2D72D2; outline-offset: -2px; }
  .name { color: #4C90F0; text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 3px; text-decoration-color: rgb(76 144 240 / 0.45); }
  li a:hover .name { color: #E6EBF0; text-decoration-color: #4C90F0; }
  .count { font-size: 0.75rem; color: #A7B3BF; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .colophon { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.5rem; margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #2F3A45; font-family: 'JetBrains Mono Variable', 'JetBrains Mono Fallback', 'Courier New', monospace; font-size: 0.75rem; color: #A7B3BF; }
  .colophon .brand { font-family: 'Inter Variable', 'Inter Fallback', Arial, sans-serif; font-size: 0.6875rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; }
  .colophon .sep { color: #6E7C89; }
  .colophon .pair { display: inline-flex; gap: 0.5rem; align-items: baseline; white-space: nowrap; } /* a separator never orphans at a line end */
  .colophon a { color: #A7B3BF; text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 3px; text-decoration-color: #3D4A57; }
  .colophon a:hover { color: #E6EBF0; text-decoration-color: #4C90F0; }
  a:focus-visible { outline: 2px solid #2D72D2; outline-offset: 2px; border-radius: 2px; }
  @media (pointer: coarse) { .colophon a { display: inline-block; padding-block: 0.6875rem; margin-block: -0.6875rem; } }
</style>
</head>
<body>
<main>
<p class="kicker">Inside Brahma · Swift modules</p>
<h1>API reference</h1>
<p class="lede">Every public symbol of each module, generated with DocC from the Swift interface of this build.</p>
<ul>
HTML
  for i in "${!documented[@]}"; do
    module=${documented[$i]}
    lc=$(lower "$module")
    printf '<li><a href="/api/%s/documentation/%s/"><span class="name">%s</span><span class="count">%s public symbols</span></a></li>\n' "$lc" "$lc" "$module" "${symbols[$i]}"
  done
  echo '</ul>'
  echo '<footer class="colophon"><span class="brand">Brahma</span>'
  if [ "$SPLIT" = "1" ]; then
    # Its own origin: no site-relative links.
    echo '<span class="pair"><span class="sep" aria-hidden="true">·</span><span>Apache-2.0</span></span>'
  else
    echo '<span class="pair"><span class="sep" aria-hidden="true">·</span><a href="/license/">Apache-2.0</a></span><span class="pair"><span class="sep" aria-hidden="true">·</span><a href="/">Back to the site</a></span><span class="pair"><span class="sep" aria-hidden="true">·</span><a href="/internals/">Inside Brahma</a></span>'
  fi
  cat <<'HTML'
</footer>
</main>
</body>
</html>
HTML
} > "$OUT/index.html"

node site/scripts/gen-module-facts.mjs "$GRAPHS" "$FACTS" "$OUT"

if grep -rlE '/Users/|file://|/private/var/' "$OUT" "$FACTS" >&2; then
  echo "site-api-docs: generated files contain a build-machine path or file:// URL (listed above)" >&2
  exit 1
fi

N=$(find "$OUT" -type f | wc -l | tr -d ' ')
echo "api files: $N"
echo "site-api-docs: done in $(( $(date +%s) - start ))s"
if [ "$N" -gt "$LIMIT" ]; then
  echo "site-api-docs: $N files exceeds $LIMIT (Cloudflare Pages caps a deployment at 20,000)." >&2
  if [ "$SPLIT" = "1" ]; then
    echo "site-api-docs: the reference alone is over the cap even as its own project" >&2
  else
    echo "site-api-docs: deploy the API reference as its own project (site/README.md) and rerun with BRAHMA_API_SPLIT=1" >&2
  fi
  exit 1
fi
if [ "$SPLIT" = "1" ]; then
  # The project root has no page of its own; send it to the index.
  printf '/ /api/ 302\n' > "$DEPLOY/_redirects"
  echo "site-api-docs: split mode: deploy $DEPLOY as its own project and set apiBase to <its URL>/api (site/README.md)"
fi
