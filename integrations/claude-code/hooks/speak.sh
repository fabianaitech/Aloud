#!/usr/bin/env bash
# Speak Claude's final response aloud via Aloud (github.com/fabianaitech/Aloud).
#
# Wired from settings.json as a second Stop hook (alongside notify.sh):
#   Stop -> speak.sh stop
# Playback/queue/pause/stop all live in the daemon (server.py); this hook just
# extracts the response, cleans it, and POSTs it to /say. Always exits 0.
#
# Toggle + speed via the /speak slash command. Env: ALOUD_PORT(8877),
# ALOUD_MAX_CHARS(0 = uncapped).
set -o pipefail
mode="${1:-stop}"
ALOUD_DIR="${ALOUD_DIR:-$HOME/.aloud}"
input="$(cat)"
[ "$mode" = "stop" ] || exit 0

# Not installed → genuine no-op. Lets the shared settings.json ship
# this hook without affecting anyone who has not installed Aloud.
[ -x "$ALOUD_DIR/control.sh" ] || exit 0

# Silent unless enabled (default on).
FLAG="$ALOUD_DIR/speak.enabled"
[ "$(cat "$FLAG" 2>/dev/null || echo on)" = "on" ] || exit 0

PORT="${ALOUD_PORT:-8877}"
BASE="http://127.0.0.1:${PORT}"

# Runtime speed (set via /speak faster|slower|<number>); default 1.0.
SPEED="$(cat "$ALOUD_DIR/speak.speed" 2>/dev/null || echo 1.0)"
echo "$SPEED" | grep -qE '^[0-9]+(\.[0-9]+)?$' || SPEED=1.0

# Engine down → stay quiet. Deliberately does NOT start it: the model costs
# ~1.2GB of RAM, and a background turn is the wrong moment to decide to spend
# that. Turning "Speak responses" on is what asks (Claude Island prompts, and
# /speak on says so); stopping the engine is meant to stay stopped until you
# say otherwise. Speaking a selection still starts it on demand — that click is
# itself the answer to the question.
curl -s --max-time 1 "$BASE/health" 2>/dev/null | grep -q ok || exit 0

tp="$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)"
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# Full text of the LAST assistant message (text blocks joined). Slurps the tail
# so a message spanning multiple lines stays whole.
extract() {
  tail -n 400 "$tp" 2>/dev/null \
    | jq -R 'fromjson?' 2>/dev/null \
    | jq -s -r '
        ( map(select(.type=="assistant" and (any(.message.content[]?; .type=="text")))) | last ) as $m
        | if $m then ([ $m.message.content[]? | select(.type=="text") | .text ] | join(" ")) else "" end
      ' 2>/dev/null
}

# Stop can fire before the final message is flushed — poll until two reads agree.
prev=""; text=""
for _ in 1 2 3 4 5 6; do
  cur="$(extract)"
  if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then text="$cur"; break; fi
  prev="$cur"; sleep 0.3
done
[ -n "$text" ] || text="$prev"
[ -n "$text" ] || exit 0

# Strip markdown / code / urls so it reads naturally aloud.
clean="$(printf '%s' "$text" | perl -0777 -pe '
  s/```.*?```//gs;               # fenced code blocks (do not read code aloud)
  s/`([^`]*)`/$1/g;              # inline code
  s/\*\*([^*]*)\*\*/$1/g;        # bold
  s/\*([^*]*)\*/$1/g;           # italic
  s/^\s{0,3}#+\s*//mg;           # headers
  s/^\s*[-*]\s+/ /mg;            # bullets
  s/\[([^\]]*)\]\([^)]*\)/$1/g;  # [text](url) -> text
  s/https?:\/\/\S+//g;           # bare urls
  s/[*_>#]//g;                   # stray markdown punctuation
' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //')"

# Optional length cap. Default 0 = uncapped: read the whole response, since the
# header glyph / gear menu / `/speak stop` can silence it at any moment. Set
# ALOUD_MAX_CHARS>0 to trim back to the last sentence end within that budget
# (never mid-word), falling back to a word break, then a hard cut.
MAX="${ALOUD_MAX_CHARS:-0}"
if [ "$MAX" -gt 0 ] 2>/dev/null && [ "${#clean}" -gt "$MAX" ]; then
  clean="$(printf '%s' "$clean" | MAX="$MAX" perl -0777 -pe '
    my $m = $ENV{MAX};
    $_ = substr($_, 0, $m);
    # Prefer the last sentence end; else the last word break; else the hard cut.
    if (m/^(.*[.!?])(?:\s|$)/s)      { $_ = $1 }
    elsif (m/^(.{'"$((MAX / 2))"',})\s\S*$/s) { $_ = $1 }
  ')"
fi
[ -n "${clean// /}" ] || exit 0

# The message's own id, so Remote Voice can tell a re-fired Stop hook from a
# new response, and which session it belongs to.
event_id="$(tail -n 400 "$tp" 2>/dev/null | jq -R 'fromjson?' 2>/dev/null | jq -s -r '
  map(select(.type=="assistant" and (any(.message.content[]?; .type=="text")))) | last | .uuid // ""' 2>/dev/null)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"

# Hand off to the daemon — it chunks, synthesizes, and plays, on the Mac or the
# phone depending on Remote Voice. An older daemon without /utterance gets /say.
payload="$(jq -nc --arg t "$clean" --argjson s "$SPEED" --arg sid "$session_id" \
  --arg eid "$event_id" --arg cwd "$cwd" \
  '{text:$t, speed:$s, session_id:$sid, event_id:$eid, cwd:$cwd}')"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$BASE/utterance" \
  -H 'Content-Type: application/json' --data "$payload" 2>/dev/null)"
if [ "$code" = 404 ]; then
  curl -s --max-time 5 -X POST "$BASE/say" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg t "$clean" --argjson s "$SPEED" '{text:$t, speed:$s}')" >/dev/null 2>&1
fi
exit 0
