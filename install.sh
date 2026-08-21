#!/usr/bin/env bash
# Install Aloud.
#
#   ./install.sh              engine + Services + the menu-bar app
#   ./install.sh --no-app     skip the app (Services and CLI only, no Swift needed)
#
# Installs:
#   engine/    -> ~/.aloud             the daemon, its control script and helpers
#   services/  -> ~/Library/Services   "Speak with Aloud" / "Stop speaking (Aloud)"
#   the app    -> /Applications/Aloud.app
#
# Building locally rather than shipping a .dmg is deliberate: the app is ad-hoc
# signed, not notarized, so a *downloaded* copy carries a quarantine flag and
# Gatekeeper warns about malware. A locally built one doesn't, and just runs.
#
# Re-running is safe: your Python venv, your settings (speak.*) and the logs are
# left alone; only the code is replaced.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$HOME/.aloud"

WITH_APP=1
for arg in "$@"; do
  case "$arg" in
    --no-app) WITH_APP=0 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "==> installing the engine to $DIR"
mkdir -p "$DIR"
for f in server.py synth.py control.sh say.sh start.sh stop.sh setup.sh requirements.txt aloud; do
  cp "$here/engine/$f" "$DIR/$f"
done
chmod +x "$DIR"/*.sh "$DIR/aloud"

# Put `aloud` on PATH. First writable candidate wins; no sudo, and no editing
# anyone's shell rc behind their back — if none of these are usable we say so
# and the command still works by its full path.
link_dir=""
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  if [[ -d "$d" && -w "$d" ]] || { [[ "$d" == "$HOME/.local/bin" ]] && mkdir -p "$d" 2>/dev/null; }; then
    link_dir="$d"; break
  fi
done
if [[ -n "$link_dir" ]]; then
  ln -sf "$DIR/aloud" "$link_dir/aloud"
  echo "==> linked the aloud command into $link_dir"
  case ":$PATH:" in
    *":$link_dir:"*) ;;
    *) echo "    note: $link_dir isn't on your PATH — add it, or use $DIR/aloud" ;;
  esac
else
  echo "==> couldn't link the aloud command anywhere on PATH; use $DIR/aloud"
fi

# Migrate settings from the pre-1.0 location, once, if they're there and we have
# none. Losing your voice and speed on upgrade is a small thing that feels bad.
legacy="$HOME/.claude/tts-kokoro"
if [[ -d "$legacy" && ! -e "$DIR/speak.enabled" ]]; then
  echo "==> migrating settings from $legacy"
  for f in speak.enabled speak.speed speak.engine speak.voice speak.voice.apple speak.voice.kokoro; do
    [[ -f "$legacy/$f" ]] && cp "$legacy/$f" "$DIR/$f"
  done
  echo "    (the old directory is left in place; remove it once you're happy)"
fi

echo "==> installing the Services to ~/Library/Services"
mkdir -p "$HOME/Library/Services"
for s in "Speak with Aloud" "Stop speaking (Aloud)"; do
  rm -rf "$HOME/Library/Services/${s}.workflow"
  cp -R "$here/services/${s}.workflow" "$HOME/Library/Services/"
done

# The Services menu is built from a cache that only refreshes at login; without
# this a freshly installed item stays invisible until you reboot.
if [[ -x /System/Library/CoreServices/pbs ]]; then
  echo "==> refreshing the Services menu"
  /System/Library/CoreServices/pbs -flush || true
fi

if [[ "$WITH_APP" == 1 ]]; then
  if command -v swift >/dev/null 2>&1; then
    echo "==> building and installing the menu-bar app"
    "$here/_dev/install.sh" | sed 's/^/    /'
  else
    echo "==> skipping the menu-bar app: no Swift toolchain found"
    echo "    install Xcode or the Command Line Tools (xcode-select --install),"
    echo "    then re-run ./install.sh. Everything else already works."
    WITH_APP=0
  fi
fi

cat <<EOF

Done. Apple's built-in engine works immediately — nothing else to install.

  Speak something:   aloud "hello there"
  Check the state:   aloud status
EOF

[[ "$WITH_APP" == 1 ]] && echo "  The app:           /Applications/Aloud.app (in your menu bar now)"

cat <<EOF

Worth doing once:
  * A keyboard shortcut:  System Settings -> Keyboard -> Keyboard Shortcuts ->
                          Services -> "Speak with Aloud"

Optional:
  * Better voices:        aloud setup            (Kokoro; ~330MB model, needs uv)
  * Apple's good voices:  System Settings -> Accessibility -> Spoken Content ->
                          System Voice -> Manage Voices (the shipped ones are
                          the dated compact tier)
EOF
