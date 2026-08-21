# Claude Code integration (optional)

Aloud began as a way to have [Claude Code](https://claude.com/claude-code) read
its replies out loud. That integration lives here rather than in the app: Aloud
itself knows nothing about Claude, and none of this is needed to use it.

| File | Hook | What it does |
|------|------|--------------|
| `hooks/speak.sh` | `Stop` | Takes Claude's final reply, strips markdown and code, and sends it to Aloud |
| `hooks/speak-stop.sh` | `UserPromptSubmit` | Barge-in: stops playback when you start typing, so Claude never talks over your next question |
| `commands/speak.md` | — | A `/speak` slash command wrapping `control.sh` |

## Install

```bash
cp hooks/speak.sh hooks/speak-stop.sh ~/.claude/hooks/
cp commands/speak.md ~/.claude/commands/
chmod +x ~/.claude/hooks/speak*.sh
```

Then wire them in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/speak.sh stop" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "$HOME/.claude/hooks/speak-stop.sh" }] }
    ]
  }
}
```

Restart Claude Code so the hooks load.

## Two deliberate behaviours

**It never starts the engine for you.** If the engine is stopped, a finished
turn is simply silent. Earlier versions lazy-started it, which quietly undid a
deliberate "Stop Engine" on the very next reply — with Kokoro selected that is
~1.26 GB reappearing because of something you never saw happen. Start it from
the menu bar, or with `~/.aloud/control.sh start`.

**It is a no-op until Aloud is installed.** The hooks bail out when `~/.aloud`
isn't there, so dropping them into a shared config never forces speech on
anyone.

Toggle narration with `/speak on` / `/speak off`; the flag is
`~/.aloud/speak.enabled`. Note this only gates *Claude's replies* — speaking a
selection through the Services menu is an explicit action and works regardless.
