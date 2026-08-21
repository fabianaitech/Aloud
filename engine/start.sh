#!/usr/bin/env bash
# Start the Kokoro TTS server in the background if it isn't already running.
DIR="$HOME/.aloud"
PORT="${ALOUD_PORT:-8877}"
if curl -s --max-time 1 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q ok; then
  echo "aloud already running on :${PORT}"
  exit 0
fi
nohup "$DIR/.venv/bin/python" "$DIR/server.py" >> "$DIR/server.log" 2>&1 &
echo $! > "$DIR/server.pid"
echo "aloud starting (pid $(cat "$DIR/server.pid")); warming model on MPS ~11s ..."
