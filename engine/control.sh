#!/usr/bin/env bash
# Control Claude Code speech (Kokoro TTS). Used by the /speak slash command and
# by the Claude Island menubar. on/off/speed live in flag files (fast, work even
# if the daemon is down); pause/resume/stop/skip talk to the daemon.
#
# Usage: control.sh [on|off|toggle|faster|slower|reset|status|voice <name>|
#                    engine <apple|kokoro>|clipboard|pause|resume|stop|skip|
#                    start|restart|stop-engine|<number e.g. 1.3>]
DIR="$HOME/.aloud"
FLAG="$DIR/speak.enabled"
SPEEDF="$DIR/speak.speed"
ENGINEF="$DIR/speak.engine"
PORT="${ALOUD_PORT:-8877}"
BASE="http://127.0.0.1:${PORT}"

arg="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
speed="$(cat "$SPEEDF" 2>/dev/null || echo 1.0)"
echo "$speed" | grep -qE '^[0-9]+(\.[0-9]+)?$' || speed=1.0

up() { curl -s --max-time 1 "$BASE/health" 2>/dev/null | grep -q ok; }

# Nothing starts the engine behind your back any more, so turning speech on while
# it is stopped has to say so — otherwise you tick the box and get silence with no
# explanation. The GUI equivalent is Claude Island's "Start the speech engine?" prompt.
engine_hint() {
  up || echo "   …but the engine is stopped, so nothing will be spoken. Start it with: /speak start"
}

clamp() { awk -v v="$1" 'BEGIN{ if(v<0.5)v=0.5; if(v>2.0)v=2.0; printf "%.2f", v }'; }
bump()  { awk -v s="$speed" -v d="$1" 'BEGIN{ printf "%.2f", s+d }'; }
post()  { curl -s --max-time 3 -X POST "$BASE/$1" >/dev/null 2>&1; }
setspeed() { curl -s --max-time 3 -X POST "$BASE/speed" -H 'Content-Type: application/json' --data "{\"speed\":${speed}}" >/dev/null 2>&1; }

case "$arg" in
  ""|toggle)
    cur="$(cat "$FLAG" 2>/dev/null || echo on)"
    if [ "$cur" = on ]; then printf off >"$FLAG"; post stop; echo "🔇 Claude speech is now OFF"
    else printf on >"$FLAG"; echo "🔊 Claude speech is now ON"; engine_hint; fi ;;
  on)  printf on  >"$FLAG"; echo "🔊 Claude speech is now ON"; engine_hint ;;
  off) printf off >"$FLAG"; post stop; echo "🔇 Claude speech is now OFF" ;;
  # Every speed change writes the flag AND tells the daemon, so /state (what the
  # menubar checkmark reads) can't disagree with the file the hooks read.
  faster) speed="$(clamp "$(bump 0.15)")";  printf '%s' "$speed" >"$SPEEDF"; setspeed; echo "⏩ Speech speed: ${speed}x" ;;
  slower) speed="$(clamp "$(bump -0.15)")"; printf '%s' "$speed" >"$SPEEDF"; setspeed; echo "⏪ Speech speed: ${speed}x" ;;
  reset)  speed=1.0; printf '%s' "$speed" >"$SPEEDF"; setspeed; echo "↺ Speech speed reset to 1.0x" ;;
  pause)  post pause;  echo "⏸ Paused" ;;
  resume|play) post resume; echo "▶️ Resumed" ;;
  stop)   post stop;   echo "⏹ Stopped (queue cleared)" ;;
  skip|next) post skip; echo "⏭ Skipped current line" ;;
  start)   "$DIR/start.sh" ;;
  restart) "$DIR/stop.sh" >/dev/null 2>&1; "$DIR/start.sh" ;;
  # "stop" silences playback; shutting the daemon down (and freeing the model)
  # is a separate, deliberate action.
  stop-engine) "$DIR/stop.sh" ;;
  engine)
    eng="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$eng" in
      apple|kokoro) ;;
      *) echo "Usage: control.sh engine <apple|kokoro>"; exit 1 ;;
    esac
    # A refusal (400) and an unreachable daemon are different answers: the first
    # means "no", the second means "not yet". Writing the flag on a refusal would
    # persist a choice the daemon just rejected, and boot into it next time.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$BASE/engine" \
              -H 'Content-Type: application/json' --data "{\"engine\":\"${eng}\"}" 2>/dev/null)"
    case "$code" in
      200)    printf '%s' "$eng" >"$ENGINEF"; echo "🎛 Engine set to ${eng}" ;;
      ""|000) printf '%s' "$eng" >"$ENGINEF"
              echo "🎛 Engine set to ${eng} (takes effect when the engine starts)" ;;
      *)      if [ "$eng" = kokoro ] && [ ! -x "$DIR/.venv/bin/python" ]; then
                echo "The Kokoro engine isn't installed. Run: aloud setup"
              else
                echo "Engine '${eng}' was refused — keeping the current one."
              fi
              exit 1 ;;
    esac ;;
  voice)
    # The daemon validates by actually synthesizing with the voice, so a typo is
    # refused rather than silently muting on the next request. Apple voice names
    # are free-form and case-sensitive ("Isha (Premium)"), so unlike Kokoro's
    # they must be passed through exactly as given.
    cur_engine="$(cat "$ENGINEF" 2>/dev/null || echo apple)"
    if [ "$cur_engine" = kokoro ]; then
      name="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
    else
      name="${2:-}"
    fi
    [ -n "$name" ] || { echo "Usage: control.sh voice <name>   e.g. af_heart (kokoro), Samantha (apple)"; exit 1; }
    # Built with jq, not string interpolation: Apple names carry spaces and
    # parentheses, and one stray quote would produce invalid JSON.
    voicef="$DIR/speak.voice.$cur_engine"
    # Generous, because the daemon proves the voice by synthesizing with it, and
    # for Kokoro that can mean starting a worker (~12s cold) or restarting one in
    # another language (~6s). At 20s a cold first switch timed out, and a timeout
    # is indistinguishable from an unreachable daemon — so it was reported as
    # "takes effect when the engine starts" while the switch actually succeeded
    # moments later.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 -X POST "$BASE/voice" \
              -H 'Content-Type: application/json' \
              --data "$(jq -nc --arg v "$name" '{voice:$v}')" 2>/dev/null)"
    case "$code" in
      200) printf '%s' "$name" >"$voicef"; echo "🗣 Voice set to ${name}" ;;
      ""|000)
        # No HTTP code: either the daemon isn't there, or we gave up waiting.
        # Only the first justifies claiming the setting will apply later.
        if up; then
          echo "Timed out waiting for the engine to confirm '${name}'."
          echo "Check with: aloud status"
          exit 1
        fi
        printf '%s' "$name" >"$voicef"
        echo "🗣 Voice set to ${name} (takes effect when the engine starts)" ;;
      *)   echo "Voice '${name}' was rejected — keeping the current one."; exit 1 ;;
    esac ;;
  clipboard) pbpaste | "$DIR/say.sh" ;;
  status)
    st="$(cat "$FLAG" 2>/dev/null || echo on)"
    st="$(printf '%s' "$st" | tr '[:lower:]' '[:upper:]')"
    js="$(curl -s --max-time 2 "$BASE/state" 2>/dev/null)"
    if [ -n "$js" ]; then
      extra="$(printf '%s' "$js" | jq -r '
        " — " + (.engine // "kokoro") + "/" + (.voice // "?")
        + ", " + (if .paused then "PAUSED" elif .speaking then "speaking" else "idle" end)
        + ", " + (.queued|tostring) + " queued"
        + (if .loading then ", loading the model…"
           elif .loaded == false then ", model unloaded (idle)"
           else "" end)' 2>/dev/null)"
    else
      extra=" — daemon not running"
    fi
    echo "Speech is ${st}, speed ${speed}x${extra}" ;;
  *)
    n="${arg%x}"
    if printf '%s' "$n" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
      speed="$(clamp "$n")"; printf '%s' "$speed" >"$SPEEDF"; setspeed; echo "🎚 Speech speed set to ${speed}x"
    else
      echo "Unknown option '$arg'. Use: on off toggle faster slower reset status start restart stop-engine pause resume stop skip clipboard 'voice <name>' 'engine <apple|kokoro>', or a number like 1.3"
    fi ;;
esac
