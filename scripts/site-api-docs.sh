#!/bin/bash
# API reference for the public site. Usage: scripts/site-api-docs.sh
# Builds every target (debug) with swiftc symbol-graph emission into .build/symbol-graphs
# (synthesized members such as inherited Equatable/Codable defaults are skipped: they were 60% of
# BrahmaCore's symbols and pushed the output past the deployment file cap), then
# runs `docc convert` once per Brahma module into site/public/api/<module-lowercase>/ (static
# hosting, served at /api/<module>/documentation/<module>/), copies site/api-theme/theme-settings.json
# into each, writes the /api/ index page and site/src/generated/modules.json (module facts for
# ModuleFacts.astro) with site/scripts/gen-module-facts.mjs. All output is gitignored; never commit it.
#
# The build shares .build/ with the other scripts (a separate scratch path would re-fetch the
# dependencies and their submodules over the network); changing the swiftc flags makes the next
# plain `swift build` recompile the package's own targets. Each module's
# graphs (<Module>.symbols.json plus its <Module>@*.symbols.json extension graphs) are staged
# into a directory of their own before `docc convert`, because the shared symbol-graph
# directory also holds the dependencies' graphs and DocC documents one module per archive.
#
# Fails when any generated file contains a /Users/ path, when a module-facts type link has no
# DocC page, and when site/public/api holds more than 19,000 files (Cloudflare Pages caps a
# deployment at 20,000; see site/README.md). BRAHMA_API_SPLIT=1 allows the larger output for
# the documented two-project deployment, where the API reference is deployed on its own.
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
OUT=site/public/api
FACTS=site/src/generated/modules.json
THEME=site/api-theme/theme-settings.json
LIMIT=19000

start=$(date +%s)

echo "site-api-docs: building all targets (debug) with symbol graphs"
rm -rf "$GRAPHS"
mkdir -p "$GRAPHS"
timeout 1200 swift build \
  -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc "$PWD/$GRAPHS" \
  -Xswiftc -symbol-graph-skip-synthesized-members

rm -rf "$OUT" "$STAGE"
mkdir -p "$OUT" "$STAGE"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

documented=()
for module in "${MODULES[@]}"; do
  lc=$(lower "$module")
  graphs="$STAGE/$module/graphs"
  catalog="$STAGE/$module/$module.docc"
  mkdir -p "$graphs" "$catalog"
  shopt -s nullglob
  files=("$GRAPHS/$module.symbols.json" "$GRAPHS/$module"@*.symbols.json)
  shopt -u nullglob
  if [ ! -f "$GRAPHS/$module.symbols.json" ]; then
    echo "site-api-docs: no symbol graph for $module (not a Swift module); skipped"
    continue
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
done

if [ "${#documented[@]}" -eq 0 ]; then
  echo "site-api-docs: no module was documented" >&2
  exit 1
fi

# The /api/ index: a plain static page outside Astro, using the site's token values inline.
{
  cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API reference | Brahma</title>
<meta name="description" content="DocC reference for Brahma's Swift modules.">
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #0E1217; color: #E6EBF0; font: 16px/1.6 'Inter Variable', 'Inter Fallback', Arial, sans-serif; }
  main { max-width: 40rem; margin: 0 auto; padding: 4rem 1.5rem; }
  h1 { margin: 0 0 0.5rem; font-size: 2rem; font-weight: 600; }
  p { margin: 0 0 2rem; color: #A7B3BF; }
  ul { margin: 0; padding: 0; list-style: none; border: 1px solid #2F3A45; border-radius: 2px; background: #1A2129; }
  li { border-top: 1px solid #2F3A45; }
  li:first-child { border-top: 0; }
  a { display: block; padding: 0.75rem 1rem; color: #4C90F0; font-family: 'JetBrains Mono Variable', 'JetBrains Mono Fallback', 'Courier New', monospace; text-decoration: none; }
  a:hover { background: #212A33; text-decoration: underline; }
  a:focus-visible { outline: 2px solid #2D72D2; outline-offset: -2px; }
  .back { display: inline; padding: 0; font-family: inherit; }
  .back:hover { background: none; }
</style>
</head>
<body>
<main>
<h1>API reference</h1>
<p>Generated with DocC from the public Swift interface of each module. <a class="back" href="/">Back to the site</a>.</p>
<ul>
HTML
  for module in "${documented[@]}"; do
    lc=$(lower "$module")
    printf '<li><a href="/api/%s/documentation/%s/">%s</a></li>\n' "$lc" "$lc" "$module"
  done
  cat <<'HTML'
</ul>
</main>
</body>
</html>
HTML
} > "$OUT/index.html"

node site/scripts/gen-module-facts.mjs "$GRAPHS" "$FACTS" "$OUT"

if grep -rl '/Users/' "$OUT" "$FACTS" >&2; then
  echo "site-api-docs: generated files contain a /Users/ path (listed above)" >&2
  exit 1
fi

N=$(find "$OUT" -type f | wc -l | tr -d ' ')
echo "api files: $N"
echo "site-api-docs: done in $(( $(date +%s) - start ))s"
if [ "$N" -gt "$LIMIT" ] && [ "${BRAHMA_API_SPLIT:-0}" != "1" ]; then
  echo "site-api-docs: $N files exceeds $LIMIT (Cloudflare Pages caps a deployment at 20,000)." >&2
  echo "site-api-docs: deploy the API reference as its own project (site/README.md) and rerun with BRAHMA_API_SPLIT=1" >&2
  exit 1
fi
