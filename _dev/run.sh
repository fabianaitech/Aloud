#!/usr/bin/env bash
# run.sh — the dev loop: rebuild the bundle, replace any running copy, relaunch.
# `open` reuses the bundle so LSUIElement/plist take effect exactly as an
# installed copy would.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

"$here/build.sh"

echo "==> replacing any running copy"
"$here/stop.sh" >/dev/null 2>&1 || true

echo "==> launching"
open "${root}/dist/Aloud.app"
