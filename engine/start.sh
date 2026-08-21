#!/usr/bin/env bash
# Start the Aloud speech daemon in the background if it isn't already running.
DIR="$HOME/.aloud"
PORT="${ALOUD_PORT:-8877}"
if curl -s --max-time 1 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q ok; then
  echo "aloud already running on :${PORT}"
  exit 0
fi

# The supervisor is stdlib-only, so any Python 3 can run it — which is what makes
# the Apple engine need no setup at all. Prefer the Kokoro venv when it exists
# (server.py hands the worker the right interpreter either way), but never
# require it: insisting on the venv here left a fresh Apple-only install unable
# to start the daemon, which made "Apple works immediately" untrue.
if [ -x "$DIR/.venv/bin/python" ]; then
  PY="$DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"
else
  echo "aloud: no python3 found — install the Xcode Command Line Tools" >&2
  exit 1
fi

nohup "$PY" "$DIR/server.py" >> "$DIR/server.log" 2>&1 &
echo $! > "$DIR/server.pid"
echo "aloud starting (pid $(cat "$DIR/server.pid")) on :${PORT}"
