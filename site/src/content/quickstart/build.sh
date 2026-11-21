# Needs macOS 14 or later, Swift 6 (Xcode or its command line tools)
# and the claude CLI on your PATH, logged in to your plan.
# Run from the root of your Brahma checkout.

swift build

# The CLI is now .build/debug/brahma. Put it on your PATH for this shell:
export PATH="$PWD/.build/debug:$PATH"

# Optional: the Mac app, built to .build/Brahma.app (a release build).
# scripts/make-app.sh
