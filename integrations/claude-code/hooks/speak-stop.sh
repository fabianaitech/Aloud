#!/usr/bin/env bash
# Barge-in: stop any in-progress speech the instant a new prompt is submitted.
# Wired from settings.json as a UserPromptSubmit hook. Always exits 0.
# No-op if the TTS venv isn't installed (safe to ship in shared settings.json).
[ -x "$HOME/.aloud/.venv/bin/python" ] || exit 0
PORT="${ALOUD_PORT:-8877}"
curl -s --max-time 1 -X POST "http://127.0.0.1:${PORT}/stop" >/dev/null 2>&1
exit 0
