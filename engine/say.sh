#!/usr/bin/env bash
# Speak arbitrary text aloud through the local Aloud speech daemon.
#
# Unlike hooks/speak.sh (which reads Claude's *responses* and stays silent
# unless speech is enabled), this is an explicit user action: it always speaks,
# and it waits for the daemon to warm up instead of skipping a turn.
#
# Text comes from the arguments, or from stdin when there are none — so it works
# either way round, whichever way Automator is configured to pass the selection.
#
#   say.sh "hello world"
#   pbpaste | say.sh
#
# Env: ALOUD_PORT (8877), ALOUD_SAY_QUIET (1 = no notifications).
set -o pipefail

# A Service is launched by pbs with a bare PATH, so Homebrew tools (jq) are not
# on it. Put the usual prefixes back before anything looks for them.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$HOME/.aloud"
PORT="${ALOUD_PORT:-8877}"
BASE="http://127.0.0.1:${PORT}"

# Services have no terminal to print to, so failures surface as notifications.
note() {
  [ "${ALOUD_SAY_QUIET:-0}" = "1" ] && return 0
  osascript -e "display notification \"$1\" with title \"Kokoro speech\"" >/dev/null 2>&1
}
die() { note "$1"; echo "$1" >&2; exit 1; }

if [ "$#" -gt 0 ]; then text="$*"; else text="$(cat)"; fi
[ -n "${text//[[:space:]]/}" ] || exit 0

# Check for the daemon, not for the Kokoro venv: the Apple engine needs no
# Python packages at all, and gating on the venv made a fresh Apple-only install
# refuse to speak.
[ -x "$DIR/start.sh" ] || die "Aloud is not installed — see github.com/fabianaitech/Aloud"

# Start the daemon on demand and wait for it (a cold start warms the model on
# MPS, ~11s). A hook can afford to skip a turn; a menu item the user just
# clicked cannot, so block instead of silently doing nothing.
if ! curl -s --max-time 1 "$BASE/health" 2>/dev/null | grep -q ok; then
  note "Starting the speech engine…"
  "$DIR/start.sh" >/dev/null 2>&1 &
  for _ in $(seq 1 40); do
    curl -s --max-time 1 "$BASE/health" 2>/dev/null | grep -q ok && break
    sleep 1
  done
  curl -s --max-time 1 "$BASE/health" 2>/dev/null | grep -q ok \
    || die "Speech engine did not start — see $DIR/server.log"
fi

# Same runtime speed the /speak command and the Island set.
SPEED="$(cat "$DIR/speak.speed" 2>/dev/null || echo 1.0)"
echo "$SPEED" | grep -qE '^[0-9]+(\.[0-9]+)?$' || SPEED=1.0

# Make it read naturally: drop markup and URLs, and repair the hard-wrapped
# hyphenation you get when selecting text out of a PDF or a narrow column.
clean="$(printf '%s' "$text" | perl -0777 -pe '
  s/```.*?```//gs;               # fenced code blocks (do not read code aloud)
  s/`([^`]*)`/$1/g;              # inline code
  s/(\w)-\n(\w)/$1$2/g;          # re-join words hyphenated across a line break
  s/\*\*([^*]*)\*\*/$1/g;        # bold
  s/\*([^*]*)\*/$1/g;            # italic
  s/^\s{0,3}#+\s*//mg;           # headers
  s/^\s*[-*]\s+/ /mg;            # bullets
  s/\[([^\]]*)\]\([^)]*\)/$1/g;  # [text](url) -> text
  s/https?:\/\/\S+//g;           # bare urls
  s/[*_>#]//g;                   # stray markdown punctuation
' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
[ -n "${clean//[[:space:]]/}" ] || exit 0

curl -s --max-time 5 -X POST "$BASE/say" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg t "$clean" --argjson s "$SPEED" '{text:$t, speed:$s}')" \
  >/dev/null 2>&1 || die "Could not reach the speech daemon on :${PORT}"
