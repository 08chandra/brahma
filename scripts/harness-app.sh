#!/bin/bash
# Sourced by the scripts that launch the app for a harness run (ui-snapshot.sh, smoke-app.sh, map-demo.sh): item 20 (FW-B2).
# A harness run never writes the owner's real `dev.brahma.app` defaults (preview navigation, CHANGES layout, window frames,
# ...): it runs a copy of .build/Brahma.app under a throwaway bundle identifier `dev.brahma.harness.<random>`, so every
# defaults write (the app's and AppKit's) lands in that domain, which `harness_app_cleanup` removes. The app refuses a
# harness launch (--smoke-test, --ui-snapshot, --map-demo, --map-bench) under any other identifier (`AppDefaults.decide`).
#
#   . scripts/harness-app.sh
#   harness_app_prepare "$TMP"     # sets HARNESS_APP (the copy's executable) and HARNESS_BUNDLE_ID
#   trap 'harness_app_cleanup; ...' EXIT

harness_app_prepare() {
  local dir="$1"
  [ -d .build/Brahma.app ] || { echo "harness-app.sh: .build/Brahma.app is missing (scripts/make-app.sh)" >&2; return 1; }
  HARNESS_BUNDLE_ID="dev.brahma.harness.$(/usr/bin/uuidgen | tr 'A-Z' 'a-z' | tr -d '-' | cut -c1-16)"
  HARNESS_BUNDLE="$dir/Brahma.app"
  rm -rf "$HARNESS_BUNDLE"
  cp -R .build/Brahma.app "$HARNESS_BUNDLE"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HARNESS_BUNDLE_ID" "$HARNESS_BUNDLE/Contents/Info.plist"
  codesign --force --sign - --identifier "$HARNESS_BUNDLE_ID" "$HARNESS_BUNDLE" >/dev/null 2>&1
  codesign --verify --strict "$HARNESS_BUNDLE"
  HARNESS_APP="$HARNESS_BUNDLE/Contents/MacOS/Brahma"
  export HARNESS_BUNDLE_ID HARNESS_APP
}

# Removes the copy's defaults domain (and its saved window state); never touches dev.brahma.app.
harness_app_cleanup() {
  case "${HARNESS_BUNDLE_ID:-}" in
    dev.brahma.harness.?*) ;;
    *) return 0 ;;
  esac
  /usr/bin/defaults delete "$HARNESS_BUNDLE_ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$HARNESS_BUNDLE_ID.plist"
  rm -rf "$HOME/Library/Saved Application State/$HARNESS_BUNDLE_ID.savedState"
}
