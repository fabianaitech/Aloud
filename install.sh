#!/usr/bin/env bash
# Install Aloud's speech engine and macOS Services.
#
#   ./install.sh
#
# Installs:
#   engine/    -> ~/.aloud            the daemon, its control script and helpers
#   services/  -> ~/Library/Services  "Speak with Aloud" / "Stop speaking (Aloud)"
#
# Does NOT build the menubar app — that's ./_dev/install.sh, kept separate so you
# can use the Services and the CLI without ever compiling Swift.
#
# Re-running is safe: your Python venv, your settings (speak.*) and the logs are
# left alone; only the code is replaced.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$HOME/.aloud"

echo "==> installing the engine to $DIR"
mkdir -p "$DIR"
for f in server.py synth.py control.sh say.sh start.sh stop.sh setup.sh requirements.txt; do
  cp "$here/engine/$f" "$DIR/$f"
done
chmod +x "$DIR"/*.sh

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

cat <<EOF

Done. Apple's built-in engine works immediately — nothing else to install.

  Speak something:   echo "hello" | ~/.aloud/say.sh
  Check the state:   ~/.aloud/control.sh status

Next, optionally:
  * The menubar app:      ./_dev/install.sh
  * The Kokoro engine:    ~/.aloud/setup.sh      (better voices; ~330MB model, needs uv)
  * A keyboard shortcut:  System Settings -> Keyboard -> Keyboard Shortcuts ->
                          Services -> "Speak with Aloud"
EOF
