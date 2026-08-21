# Aloud

A macOS menu-bar app that reads text out loud, locally.

Select text in any app → **Services** → **Speak with Aloud**. Or speak the
clipboard from the menu bar. Nothing is sent anywhere: both engines synthesize
on your own machine, there is no API key and no cost.

<img src="_dev/icon/AppIcon-1024.png" width="128" alt="Aloud icon">

## Two engines

| | **Apple** (default) | **Kokoro** |
|---|---|---|
| Quality | Compact voices are dated; Premium/Enhanced are good | Better |
| Resident memory | none | ~1.26 GB warm, ~24 MB idle |
| First audio | ~1s | ~6s cold, ~0.7s warm |
| Setup | none — built into macOS | one script, ~330 MB model |

**Apple** drives macOS's own speech synthesis through `say`. It costs nothing at
rest: `say` is a short-lived child process and the work happens in an OS-owned
XPC service.

> macOS ships only the *compact* voices, which sound dated. The good ones —
> Premium and Enhanced — are a free manual download under **System Settings →
> Accessibility → Spoken Content → System Voice → Manage Voices**. The Voice
> menu has a **Get More Voices…** shortcut. Judge Apple's quality only after
> grabbing one.

**Kokoro** runs [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) on Apple
Silicon (MPS). Better voices, at the cost of a resident model — worth it for
long listening, overkill for a paragraph.

Each engine remembers its own voice, because `af_heart` and `Isha (Premium)`
have nothing in common and switching engine shouldn't silently switch voice.

## Install

```bash
git clone https://github.com/fabianaitech/Aloud.git
cd Aloud
./install.sh          # engine + Services. Apple's voices work immediately.
./_dev/install.sh     # optional: the menu-bar app
~/.aloud/setup.sh     # optional: the Kokoro engine (needs uv)
```

Requires macOS 13+. The menu-bar app builds with the Swift toolchain that ships
with Xcode or the Command Line Tools; it has no third-party dependencies.

Give **Speak with Aloud** a keyboard shortcut under System Settings → Keyboard →
Keyboard Shortcuts → Services. That is what turns it from a menu dive into a
reflex.

## How it works

```
Services menu ──┐  any selected text
menu-bar app ───┼─▶ control.sh ─▶ server.py  ──▶ afplay
CLI (say.sh) ───┘                 ~24 MB, always up
                                  queue + pause/stop/skip
                                       │
                          ┌────────────┴────────────┐
                          ▼                         ▼
                     `say` (Apple)            synth.py (Kokoro)
                     nothing resident         ~1.26 GB, on demand,
                                              killed after 10 min idle
```

`server.py` is the supervisor: the HTTP API on `127.0.0.1`, the playback queue,
and pause/stop/skip. It is **stdlib-only and ~24 MB**, deliberately — importing
torch here would put ~800 MB into a process that spends nearly all its life
waiting. Kokoro's weight lives in `synth.py`, a subprocess started on demand and
killed after ten idle minutes, so an idle engine is nearly free while still
being a *running* engine: it answers, and the next request transparently wakes
the worker.

Everything — the app, the Services, the CLI — goes through `control.sh`, so
there is one control surface and the settings files can't drift from the daemon.

## The menu-bar icon

The same five-bar waveform as the app icon, drawn as a monochrome template image
so macOS recolours it for light, dark and tinted menu bars. The state is carried
by the bars rather than by swapping to unrelated symbols:

| Bars | Meaning |
|------|---------|
| Flattened and dimmed | Engine not running |
| The static waveform | Idle |
| Animating as a level meter | Speaking |
| Two tall bars | Paused — reads as ⏸, same shapes |
| A spinner | Starting the engine, or waking the Kokoro worker |

The animation runs only while audio is actually playing.

## CLI

```bash
echo "hello" | ~/.aloud/say.sh     # speak stdin
pbpaste | ~/.aloud/say.sh          # speak the clipboard

~/.aloud/control.sh status
~/.aloud/control.sh engine apple   # or: kokoro
~/.aloud/control.sh voice "Zoe (Enhanced)"
~/.aloud/control.sh 1.25           # speed
~/.aloud/control.sh pause | resume | stop | skip
~/.aloud/control.sh start | restart | stop-engine
```

## Configuration

Environment variables, read when the daemon starts:

| Var | Default | Meaning |
|-----|---------|---------|
| `ALOUD_PORT` | `8877` | Daemon port (loopback only) |
| `ALOUD_ENGINE` | `apple` | Engine at first run; after that `speak.engine` wins |
| `ALOUD_SPEED` | `1.0` | Default speed (0.5–2.0) |
| `ALOUD_IDLE_TIMEOUT` | `600` | Seconds before the Kokoro worker is killed. `0` keeps it resident |
| `KOKORO_VOICE` | `af_heart` | Kokoro's boot voice (engine-specific, hence the prefix) |
| `KOKORO_LANG` | `a` | Kokoro pipeline language: `a` American, `b` British English |

Settings live in `~/.aloud/` as one-line files (`speak.engine`, `speak.speed`,
`speak.voice.apple`, `speak.voice.kokoro`, `speak.enabled`) so the shell, the
app and the daemon all read the same source of truth.

## Claude Code integration (optional)

Aloud started as a way to have [Claude Code](https://claude.com/claude-code)
read its replies aloud. That integration is preserved in
[`integrations/claude-code/`](integrations/claude-code/) — a Stop hook, a
barge-in hook and a `/speak` command — but it is entirely optional and the app
knows nothing about it.

## Uninstall

```bash
~/.aloud/stop.sh
launchctl bootout "gui/$(id -u)/com.fabianaitech.aloud.engine" 2>/dev/null   # if installed
rm -rf ~/.aloud /Applications/Aloud.app
rm -rf ~/Library/Services/"Speak with Aloud.workflow" \
       ~/Library/Services/"Stop speaking (Aloud).workflow"
/System/Library/CoreServices/pbs -flush
```

## Licence

MIT — see [LICENSE](LICENSE).

Kokoro-82M is Apache-2.0, downloaded from Hugging Face at setup time and not
redistributed here. Apple's voices are part of macOS.
