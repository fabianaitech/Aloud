# Remote Voice

Hear Claude on your iPhone, answer by voice, and have the answer land in the
Claude Code session it belongs to.

```
Claude Code session ──Stop hook──▶ Aloud daemon ──clip──▶ iPhone (plays it)
        ▲                          (your voice,              │
        │                           your engine)             │ Record → Stop
        │                                                    ▼
        └──inbox socket◀── reply ◀── transcribe on the Mac ◀── audio
```

Everything stays on your own devices.

- **Audio starts after the first sentence.** The Mac sends each sentence-sized
  piece as soon as it is synthesized, and the phone highlights the sentence
  being spoken.
- **You see your words as you speak.** The iPhone transcribes on-device (iOS
  26+), and the Mac takes over when the phone can't.
- **The conversation reads like one.** Claude's responses render as markdown,
  with code blocks and tables, and sessions show under their Claude Code names.
 The phone reaches the Mac over your
tailnet through **Tailscale Serve** (HTTPS, tailnet only). Speech is synthesized
by the engine you already use, and replies are transcribed **on the Mac,
on-device** (Apple's SpeechTranscriber, with DictationTranscriber for languages
it lacks, such as Dutch). No cloud service, no API key.

## What works today

| | Status |
|---|---|
| Responses from a **terminal** Claude Code session play on the iPhone | Verified on an iPhone 16 Pro Max over Tailscale Serve |
| Spoken reply → transcript you can edit → delivered into that session | Verified on the iPhone: recorded, transcribed on the Mac, delivered in 0.5s |
| Claude's answer to the reply plays on the phone | Tested |
| Two sessions kept apart (audio, replies, state) | Tested with two sessions |
| Reconnect without replaying clips or re-sending replies | Tested (relaunch, daemon restart, same reply id sent twice) |
| Remote Voice off / Mac unreachable / unpaired → clear state, recovers | Tested in the simulator |
| Busy session or open permission prompt → reply waits, then delivers | Tested, including a denied prompt |
| **Claude Desktop** (Code tab) sessions | **Not verified** — see below |
| Recording with the iPhone microphone | Verified on the iPhone |
| Live transcription on the iPhone, sentence clips, highlighting, redesigned app | Built and checked in the iOS 27 simulator; live transcription still to try on the device |
| Background / locked-screen playback | Still to test on the device |
| Apple Watch | Not built yet — see the plan at the end |

## How a reply reaches the session

Every Claude Code session binds an **inbox socket** and exports its path and a
per-session token to its hooks (`CLAUDE_CODE_MESSAGING_SOCKET`,
`CLAUDE_CODE_MESSAGING_TOKEN`). Aloud's `SessionStart` hook records them. A
reply is one line on that socket; an idle session starts a turn with it, and a
busy one would read it between tool calls. This is Claude Code's documented
cross-session messaging, not a second process: there is no `--resume` and no
second writer to the conversation. Aloud never routes to "the most recent
session". Every reply names a session id.

Aloud only sends into an **idle** session, one reply at a time. If Claude is
working, or waiting for you to answer a permission prompt on the Mac, the reply
stays *queued* and the phone says why. It goes out when the turn ends, including
a turn that ended because you pressed Esc or answered No: those fire no Stop
hook, so Aloud also reads the end of turn from the transcript.

States on the phone: **queued → sent → delivered**, or **failed**. *Delivered*
means the session recorded the message in its transcript. A reply is sent at
most once. If it went out but was never confirmed, it fails and says to check
the Mac, instead of retrying and risking a double instruction.

### The one thing to know

Claude Code presents a message that arrives on the inbox socket **as coming
from another session, not typed by you**. That is deliberate on Claude Code's
part. Such a message can never approve a permission prompt or change settings,
and your permission rules apply exactly as before. Aloud doesn't try to
disguise it.

In practice Claude acts on ordinary requests ("run the tests", "answer with
X"). But it may occasionally ask you to confirm a request it finds unusual.
When that happens, its answer comes back to your phone like any other
response, and you can confirm by replying. In one early test, Claude (Haiku)
reacted to the message by contacting another of the user's sessions to ask
about it. With the current neutral wording of the relay, that didn't happen
again, but it is possible behaviour, not a bug in Aloud.

If you want replies to count as your own typed input, that needs an
**Aloud-managed session** (Aloud starts `claude` and writes to its stdin). That
is not built. See *Follow-ups*.

### Claude Desktop

Hooks run and sessions register only where Claude Code exports the inbox
socket. The terminal CLI does (`CLAUDE_CODE_ENTRYPOINT=cli`, verified). For the
Desktop app's Code tab this is **not verified**. To check, turn Remote Voice on,
start a *new* Desktop Code session, and look at the phone's session picker. A
session labelled *Claude Desktop* means it registered. Registered but *listen
only* means it has no inbox socket. Missing means Desktop doesn't run the hooks.

## Setup

### 1. The Mac

1. Install or update Aloud from this repo: `./install.sh`.
2. Wire the hooks into `~/.claude/settings.json`. See
   [integrations/claude-code](../integrations/claude-code/README.md). Restart
   Claude Code sessions so they load.
3. Aloud menu → **Remote Voice** → **Remote Voice Enabled**. It is off by
   default; off means the service isn't even listening.
4. Choose **Play Responses On**: Mac, iPhone, or Mac and iPhone.

### 2. Tailscale

You need Tailscale running on both the Mac and the iPhone, signed in to the
same tailnet.

1. Start Tailscale on the Mac. It was stopped when this was built.
2. Enable **HTTPS certificates** for your tailnet, once: Tailscale admin
   console → DNS → HTTPS Certificates.
3. Aloud menu → Remote Voice → **Copy Tailscale Serve Command**, and run it in
   Terminal:

   ```bash
   tailscale serve --bg --https=8443 http://127.0.0.1:8878
   ```

   This publishes Aloud's remote port to **your tailnet only**, as
   `https://<your-mac>.<tailnet>.ts.net:8443`. It survives reboots (`--bg`).
   Undo with `tailscale serve --https=8443 off`.

   The CLI is inside the app: `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
   if `tailscale` isn't on your PATH.
4. **Never** use `tailscale funnel` for this, and don't forward the port on
   your router. Funnel would put it on the public internet.

The menu shows *Reachable at https://…* once Serve points at Aloud.

### 3. The iPhone app (Xcode, no App Store)

1. Open `ios/AloudRemote.xcodeproj` in Xcode.
2. Target **AloudRemote** → Signing & Capabilities → Team: **Fabian Afatsawo
   (Personal Team)**, already set. Change the bundle id if Xcode says it's
   taken.
3. Connect the iPhone by cable, or over Wi-Fi once paired. Choose it as the run
   destination and press Run.
4. On the phone, the first time:
   - **Developer Mode**: Settings → Privacy & Security → Developer Mode → On,
     then restart the phone.
   - **Trust the developer**: Settings → General → VPN & Device Management → your
     Apple ID → Trust.
5. **The seven-day limit.** A free Personal Team signs apps for seven days.
   After that the app won't open until you build and run it from Xcode again.
   Your pairing survives a reinstall only if you don't delete the app. A paid
   developer account signs for a year.

### 4. Pair

1. Mac: Aloud menu → Remote Voice → **Pair iPhone…**. This shows the server
   address and a six-digit code, valid for five minutes and one device.
2. iPhone: open **Aloud Remote**, enter the address and code, and tap Pair.
   The token goes into the iPhone's Keychain (this device only). The Mac stores
   only its hash, in `~/.aloud/remote/devices.json` (0600).

Remove a phone from the Mac side at any time: Remote Voice → the device →
**Remove This Device**. The phone then shows that it was removed.

## Using it

- The header shows the session you're talking to, under its Claude Code name
  (the automatic one, or whatever you set with `/rename`). It also shows where
  the session runs (Terminal, Desktop, VS Code) and whether it's ready, working
  or waiting for a permission answer. Tap it to switch; sessions with new
  responses show a count.
- Keep the app open. New responses from the selected session play
  automatically, sentence by sentence, with the spoken sentence highlighted.
  Tap a response, or its expand button, for the full text with code blocks.
  Play, pause and replay sit under each response.
- **Reply** pauses playback first, so the microphone never hears Claude. Your
  words appear as you speak. **Stop**, edit the text if needed, then send. The
  keyboard button skips the microphone.
- Transcription: on the iPhone when it has the language's speech model (a
  system download, not part of the app), otherwise on the Mac. The language is
  set under Settings → Replies (default: the phone's language).

## Security

- Two listeners. `127.0.0.1:8877` is the existing control API: unauthenticated,
  loopback only, never exposed. `127.0.0.1:8878` is the remote API: it only
  listens while Remote Voice is on, every route but pairing needs a device
  token, and it's reached only through Tailscale Serve.
- Turning Remote Voice off closes 8878. A phone that was listening gets
  *Remote Voice is off* at once.
- Pairing codes are single-use, expire after five minutes, and allow five
  wrong guesses.
- Session registrations (`~/.aloud/sessions/*.json`) hold each session's inbox
  socket path and token. They are 0600 in a 0700 directory, and are deleted at
  session end or when the session is found dead. On macOS the socket already
  accepts any process of your user, so the token adds nothing an attacker on
  your account wouldn't have.

## Background and locked screen

Foreground is the supported mode. A clip that's already playing keeps playing
when the screen locks, because the app declares background audio. New events
are **not** fetched while the app is suspended: iOS gives no guarantee to an
idle app, and Aloud doesn't use silent-audio keep-alive tricks. Test on your
phone what happens when you lock mid-clip and when you come back. The app
catches up from where it left off, but it only auto-plays clips from the last
three minutes.

## Troubleshooting

| Phone says | Meaning |
|---|---|
| Can't find the Mac — is Tailscale connected? | DNS for `*.ts.net` failed: Tailscale is off on the phone |
| The Mac isn't answering | Mac asleep, Tailscale off on the Mac, or Serve not set up |
| The Mac is reachable, but Aloud isn't answering | Serve works, but the Aloud engine isn't running |
| Remote Voice is off on the Mac | Turn it on in the menu |
| This iPhone was removed on the Mac | Settings → Unpair, then pair again |
| Reply *queued — the session is busy* | It goes out when Claude's turn ends |
| Reply *queued — needs a permission answer* | Answer the prompt on the Mac |
| Reply *failed — session never recorded it* | It may or may not have arrived. Check the Mac before sending again |

## Apple Watch — plan (phase 2)

Not built. The approach to try first, once the iPhone loop is proven on your
phone:

1. **iPhone-mediated.** A watchOS app talks to the iPhone app over
   WatchConnectivity (`sendMessage` while both are reachable,
   `transferFile` for clips), with no network code of its own. The iPhone
   stays the only paired device.
2. **Short clips.** Aloud already produces AAC. For the watch, a trimmed first
   sentence or two, with "more on iPhone".
3. **Push-to-talk.** Record on the watch (`AVAudioRecorder` works on watchOS),
   hand the file to the iPhone, and reuse the same transcribe → edit → send
   path. Editing on the watch is limited, so offer *Send* and *Discard*.
4. **Verify on real hardware** (Series 10): speaker playback volume, the mic,
   whether the iPhone app must be in the foreground for WatchConnectivity to
   deliver in time, and background limits on the watch.

A watch connecting to the Mac directly (Wi-Fi or LTE through Tailscale) is the
fallback if WatchConnectivity latency is too high. It needs its own pairing, and
the watch has no Tailscale app of its own.

## Follow-ups (not blocking)

- **Aloud-managed session** (`claude` with stream-json input, driven by Aloud),
  for replies that should count as your typed input. Its permission prompts
  would need relaying to the phone.
- Verify Claude Desktop registration, as described above.
- Relay permission prompts to the phone. Today it only says one is waiting.
- `aloud remote on|off|pair` in the CLI.
- Sent-reply history on the phone is in memory only.
