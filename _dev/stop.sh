#!/usr/bin/env bash
# stop.sh — quit any running copy of the Aloud menubar app (the dev copy under
# dist/ and the installed one in /Applications alike). Leaves the TTS daemon
# running: this quits the front-end, not the engine. To stop the engine too:
#   ~/.aloud/control.sh stop-engine
set -euo pipefail

if pkill -f "Aloud.app/Contents/MacOS/AloudBar" 2>/dev/null; then
  echo "==> quit Aloud"
else
  echo "==> Aloud was not running"
fi
