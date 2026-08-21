#!/usr/bin/env bash
# One-time setup for the optional Kokoro engine (Apple Silicon / MPS).
#
#   ~/.aloud/setup.sh                 # venv + deps + warm + enable
#   ~/.aloud/setup.sh --launch-agent  # also run the daemon at login
#
# Idempotent — safe to re-run. Requires uv (https://docs.astral.sh/uv/) and,
# for best pronunciation, Homebrew's espeak-ng. The Kokoro voice model (~330MB)
# downloads from Hugging Face on first run.
set -euo pipefail
DIR="$HOME/.aloud"
PORT="${ALOUD_PORT:-8877}"
cd "$DIR"

# 1. espeak-ng — Kokoro's grapheme-to-phoneme fallback for out-of-dictionary words.
if ! command -v espeak-ng >/dev/null 2>&1 && ! brew list espeak-ng >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "==> installing espeak-ng via Homebrew"
    brew install espeak-ng
  else
    echo "warning: Homebrew not found — install espeak-ng manually for best pronunciation" >&2
  fi
fi

# 2. Python venv + dependencies (uv).
if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv not found. Install it first:" >&2
  echo "         curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi
if [ ! -x "$DIR/.venv/bin/python" ]; then
  echo "==> creating venv (Python 3.13)"
  uv venv --python 3.13
fi
echo "==> installing dependencies"
uv pip install -r "$DIR/requirements.txt"

# 3. Enable speech + default speed (opt-in flags the hook/daemon read).
[ -f "$DIR/speak.enabled" ] || printf 'on'  > "$DIR/speak.enabled"
[ -f "$DIR/speak.speed" ]   || printf '1.0' > "$DIR/speak.speed"

# 4. (Re)start the daemon — via a LaunchAgent for login persistence, else manually.
if [ "${1:-}" = "--launch-agent" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.fabianaitech.aloud.engine.plist"
  echo "==> installing LaunchAgent → $PLIST"
  "$DIR/stop.sh" >/dev/null 2>&1 || true
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.fabianaitech.aloud.engine</string>
  <key>ProgramArguments</key><array>
    <string>$DIR/.venv/bin/python</string><string>$DIR/server.py</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>ALOUD_PORT</key><string>$PORT</string>
    <key>KOKORO_VOICE</key><string>af_heart</string>
    <key>HF_HUB_DISABLE_TELEMETRY</key><string>1</string>
    <key>TOKENIZERS_PARALLELISM</key><string>false</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/server.log</string>
  <key>StandardErrorPath</key><string>$DIR/server.log</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
  launchctl bootout "gui/$(id -u)/com.fabianaitech.aloud.engine" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
else
  echo "==> starting daemon (first run downloads the model ~330MB)"
  "$DIR/start.sh"
fi

# 5. Wait for the model to warm.
for _ in $(seq 1 60); do
  if curl -s --max-time 1 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q ok; then
    echo "==> daemon healthy on :${PORT}"
    break
  fi
  sleep 1
done

cat <<EOF

✅ Kokoro TTS is set up.
   • Restart Claude Code so the Stop / UserPromptSubmit hooks load.
   • Control it with the /speak command (on off faster slower stop status)
     or from the Claude Island header glyph / gear menu.
   • Not using a LaunchAgent? The Stop hook lazy-starts the daemon on demand.
EOF
