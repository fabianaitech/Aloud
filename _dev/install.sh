#!/usr/bin/env bash
# install.sh — the canonical LOCAL production install. Builds Aloud, quits any
# running copy, installs the bundle to /Applications, clears quarantine, and
# launches it. Run from anywhere.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

app_name="Aloud"
src="dist/${app_name}.app"
dest="/Applications/${app_name}.app"

echo "==> building"
"$here/build.sh"

echo "==> quitting any running copy"
"$here/stop.sh" >/dev/null 2>&1 || true
sleep 1

echo "==> installing to ${dest}"
rm -rf "$dest"
cp -R "$src" "$dest"

# Clear the quarantine attribute — a no-op on a locally-built app, but essential after a
# download so Gatekeeper doesn't block this ad-hoc-signed (non-notarized) bundle.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

echo "==> launching"
open "$dest"

cat <<EOF

Aloud is installed:
  ${dest}

Next steps:
  * Enable "Launch at Login" from the menubar menu.
  * Apple's engine works right away. For Kokoro's better voices, run
    ~/.aloud/setup.sh once (builds the venv, downloads the model).
  * Give "Speak with Aloud" a keyboard shortcut: System Settings → Keyboard →
    Keyboard Shortcuts → Services (the menu's "Selection Shortcut…" opens it).
EOF
