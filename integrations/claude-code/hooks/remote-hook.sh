#!/usr/bin/env bash
# Remote Voice session registry and state (github.com/fabianaitech/Aloud).
#
#   SessionStart      -> remote-hook.sh start       register the session
#   UserPromptSubmit  -> remote-hook.sh busy
#   Notification      -> remote-hook.sh permission  (matcher: permission_prompt)
#   Stop              -> remote-hook.sh idle
#   SessionEnd        -> remote-hook.sh end         forget it
#
# A reply from the phone is delivered through the session's own inbox socket,
# which Claude Code exports to hooks as CLAUDE_CODE_MESSAGING_SOCKET with a
# per-session token. Registering writes those to ~/.aloud/sessions/<id>.json,
# private to you (0600 in a 0700 directory), and SessionEnd deletes it.
#
# A no-op until Remote Voice is set up (~/.aloud/remote exists). Always exits 0.
event="${1:-}"
DIR="${ALOUD_DIR:-$HOME/.aloud}"
[ -d "$DIR/remote" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)"
case "$sid" in ""|*[!A-Za-z0-9-]*) exit 0 ;; esac

SESS="$DIR/sessions"
umask 077
mkdir -p "$SESS" && chmod 700 "$SESS"
f="$SESS/$sid.json"
now="$(date +%s)"

case "$event" in
  start)
    # Without an inbox socket (bare mode, messaging off) the session can still
    # be listened to, but can't take replies; the phone shows that.
    jq -n --arg sid "$sid" --arg sock "${CLAUDE_CODE_MESSAGING_SOCKET:-}" \
      --arg tok "${CLAUDE_CODE_MESSAGING_TOKEN:-}" --arg ep "${CLAUDE_CODE_ENTRYPOINT:-unknown}" \
      --arg cwd "$(printf '%s' "$input" | jq -r '.cwd // ""')" \
      --arg tp "$(printf '%s' "$input" | jq -r '.transcript_path // ""')" \
      --argjson now "$now" \
      '{sid:$sid, sock:$sock, tok:$tok, ep:$ep, cwd:$cwd, tp:$tp, started:$now, state:"idle"}' \
      > "$f.tmp" && mv "$f.tmp" "$f" ;;
  busy|idle|permission)
    [ -f "$f" ] || exit 0
    jq --arg s "$event" --argjson now "$now" '.state=$s | .state_at=$now' "$f" > "$f.tmp" \
      && mv "$f.tmp" "$f" ;;
  end)
    rm -f "$f" ;;
  *) exit 0 ;;
esac

# Tell a running daemon at once (it also reads the files, so a daemon that is
# down loses nothing).
curl -s --max-time 1 -X POST "http://127.0.0.1:${ALOUD_PORT:-8877}/rv/hook" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg e "$event" --arg s "$sid" '{event:$e, session_id:$s}')" >/dev/null 2>&1
exit 0
