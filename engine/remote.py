"""Remote Voice — Aloud's service for the iPhone companion.

Claude's spoken responses go to the phone as clips; spoken replies come back,
are transcribed on this Mac, and are delivered into the Claude Code session
they answer.

Two listeners, deliberately separate:

  127.0.0.1:8877  server.py's control API. Unauthenticated, loopback only, and
                  never exposed: the menu bar, hooks and CLI use it. The /rv/*
                  routes here (handle_local) configure Remote Voice.
  127.0.0.1:8878  this module's remote API, bound only while Remote Voice is on.
                  Every route but pairing needs a device token. It is meant to
                  be reached through `tailscale serve` (HTTPS, tailnet only) —
                  never Funnel, never a forwarded port.

How a reply reaches a session: every Claude Code session binds an inbox socket
and exports its path and a token to hooks (CLAUDE_CODE_MESSAGING_SOCKET /
_TOKEN). The SessionStart hook (remote-hook.sh) records them here, one file per
session. Delivering a reply is one line on that socket; the session reads it
between tool calls, or starts a turn with it if idle. No second process, no
`--resume`: the reply lands in the conversation that is already open. Claude
Code presents such a message as coming from another session rather than as
typed input, so it carries none of your authority — permission prompts still
fire as usual.

Stdlib only, like server.py.
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FLAG_DIR = os.environ.get("ALOUD_DIR") or os.path.expanduser("~/.aloud")
RV_DIR = os.path.join(FLAG_DIR, "remote")
SESS_DIR = os.path.join(FLAG_DIR, "sessions")
CLIPS_DIR = os.path.join(RV_DIR, "clips")
CONFIG_PATH = os.path.join(RV_DIR, "config.json")
DEVICES_PATH = os.path.join(RV_DIR, "devices.json")
EVENTS_PATH = os.path.join(RV_DIR, "events.jsonl")
REPLIES_PATH = os.path.join(RV_DIR, "replies.json")

DESTINATIONS = ("mac", "iphone", "both")
DEFAULT_CONFIG = {"enabled": False, "destination": "both", "port": 8878}
KEEP_EVENTS = 500
KEEP_CLIPS = 100
KEEP_REPLIES = 500
PAIR_TTL = 300          # a pairing code is good for five minutes...
PAIR_ATTEMPTS = 5       # ...and five wrong guesses
CONNECTED_WINDOW = 40   # a device that polled this recently counts as connected
CONFIRM_TIMEOUT = 30    # how long to look for a delivered reply in the transcript
MAX_AUDIO = 25 * 1024 * 1024
MAX_REPLY = 8000
ID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")
TAILSCALE = ("/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale")
SERVE_CMD = "tailscale serve --bg --https=8443 http://127.0.0.1:{port}"

# Wired by init(): the daemon's own synthesis, so a clip is spoken with the
# engine, voice and speed you already chose.
_synth = None
_chunk = None
_helper = None


def log(msg):
    print(f"[aloud:remote] {msg}", flush=True)


# ---- files -------------------------------------------------------------------

def _private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


def _read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write_json(path, obj):
    """Atomic and private: these files hold token hashes and session sockets."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _now():
    return time.time()


# ---- config ------------------------------------------------------------------

_cfg_lock = threading.Lock()
_cfg = dict(DEFAULT_CONFIG)


def _load_config():
    global _cfg
    c = dict(DEFAULT_CONFIG)
    c.update(_read_json(CONFIG_PATH, {}))
    if c["destination"] not in DESTINATIONS:
        c["destination"] = "both"
    c.setdefault("log_id", secrets.token_hex(6))
    _cfg = c


def enabled():
    return bool(_cfg.get("enabled"))


def destination():
    """Where a finished response is spoken. With Remote Voice off, the Mac —
    exactly as before this feature existed."""
    return _cfg["destination"] if enabled() else "mac"


def set_config(enabled_=None, destination_=None):
    with _cfg_lock:
        if destination_ is not None:
            if destination_ not in DESTINATIONS:
                raise ValueError("destination must be mac, iphone or both")
            _cfg["destination"] = destination_
        was = enabled()
        if enabled_ is not None:
            _cfg["enabled"] = bool(enabled_)
        _write_json(CONFIG_PATH, _cfg)
    if enabled() and not was:
        start_server()
    elif was and not enabled():
        stop_server()
    log(f"enabled={enabled()} destination={_cfg['destination']}")


# ---- devices and pairing -----------------------------------------------------

_dev_lock = threading.Lock()
_devices = []                 # [{id, name, token_sha256, paired_at, tailnet_user}]
_last_seen = {}               # device id -> monotonic-ish wall time of last request
_pairing = {"code": None, "expires": 0.0, "attempts": 0}


def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def start_pairing():
    """A one-time code shown on the Mac and typed on the phone. Only its holder,
    on the tailnet, while Remote Voice is on, gets a device token."""
    with _dev_lock:
        _pairing.update(code=f"{secrets.randbelow(10**6):06d}",
                        expires=_now() + PAIR_TTL, attempts=0)
        return dict(code=_pairing["code"], expires_in=PAIR_TTL)


def pair(code, name, tailnet_user=None):
    with _dev_lock:
        p = _pairing
        if not p["code"] or _now() > p["expires"]:
            return None, "no pairing in progress — choose Pair iPhone… on the Mac"
        p["attempts"] += 1
        if not hmac.compare_digest(str(code or ""), p["code"]):
            if p["attempts"] >= PAIR_ATTEMPTS:
                p.update(code=None, expires=0.0)
                return None, "too many wrong codes — start pairing again on the Mac"
            return None, "wrong code"
        p.update(code=None, expires=0.0)
        token = secrets.token_urlsafe(32)
        dev = {"id": secrets.token_hex(6), "name": (name or "iPhone")[:60],
               "token_sha256": _hash(token), "paired_at": _now(),
               "tailnet_user": tailnet_user}
        _devices.append(dev)
        _write_json(DEVICES_PATH, _devices)
    log(f"paired device {dev['id']} ({dev['name']})")
    return {"token": token, "device_id": dev["id"]}, None


def authenticate(header):
    if not header or not header.startswith("Bearer "):
        return None
    h = _hash(header[7:].strip())
    with _dev_lock:
        for d in _devices:
            if hmac.compare_digest(h, d["token_sha256"]):
                _last_seen[d["id"]] = _now()
                return d
    return None


def revoke(device_id=None, everything=False):
    """Remove one device — or all of them, but only when asked for by name: a
    request that merely lacks an id must not wipe every pairing."""
    if not device_id and not everything:
        raise ValueError("say which device (id), or all: true")
    with _dev_lock:
        before = len(_devices)
        _devices[:] = [] if everything else [d for d in _devices if d["id"] != device_id]
        _write_json(DEVICES_PATH, _devices)
    log(f"removed {before - len(_devices)} device(s)")
    return before - len(_devices)


def devices_status():
    now = _now()
    with _dev_lock:
        return [{"id": d["id"], "name": d["name"], "paired_at": d["paired_at"],
                 "last_seen": _last_seen.get(d["id"]),
                 "connected": now - _last_seen.get(d["id"], 0) < CONNECTED_WINDOW}
                for d in _devices]


# ---- event log -------------------------------------------------------------------

class EventLog:
    """Everything the phone is told, in order, with a sequence number.

    The phone asks for "after N" and gets each event exactly once, whether it
    stayed connected or came back after a Tailscale drop or a Mac sleep. The log
    is on disk so a daemon restart keeps the numbering; `log_id` changes only if
    the log is lost, which tells the phone to start over rather than wait for a
    sequence number that will never come."""

    def __init__(self):
        self.cond = threading.Condition()
        self.events = []
        self.seq = 0
        try:
            with open(EVENTS_PATH) as f:
                for line in f.readlines()[-KEEP_EVENTS:]:
                    try:
                        self.events.append(json.loads(line))
                    except ValueError:
                        continue
        except OSError:
            pass
        if self.events:
            self.seq = self.events[-1]["seq"]

    def append(self, ev):
        with self.cond:
            self.seq += 1
            ev = dict(ev, seq=self.seq, ts=_now())
            self.events.append(ev)
            if len(self.events) > KEEP_EVENTS:
                self.events = self.events[-KEEP_EVENTS:]
                self._rewrite()
            else:
                with open(EVENTS_PATH, "a") as f:
                    f.write(json.dumps(ev) + "\n")
                os.chmod(EVENTS_PATH, 0o600)
            self.cond.notify_all()
            return ev

    def _rewrite(self):
        fd, tmp = tempfile.mkstemp(dir=RV_DIR, prefix=".tmp-")
        with os.fdopen(fd, "w") as f:
            for e in self.events:
                f.write(json.dumps(e) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, EVENTS_PATH)

    def since(self, after, session=None):
        return [e for e in self.events
                if e["seq"] > after and (session is None or e.get("session_id") == session)]

    def wait(self, after, timeout, session=None):
        deadline = _now() + timeout
        with self.cond:
            while True:
                out = self.since(after, session)
                left = deadline - _now()
                if out or left <= 0 or not enabled():
                    return out
                self.cond.wait(left)

    def wake(self):
        with self.cond:
            self.cond.notify_all()

    def has(self, typ, key, value):
        with self.cond:
            return any(e.get("type") == typ and e.get(key) == value for e in self.events)


events = None  # EventLog, created by init()


# ---- sessions --------------------------------------------------------------------

_state = {}        # session id -> "idle" | "busy" | "permission"
_titles = {}       # session id -> first prompt, for telling sessions apart


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _registration(sid):
    if not ID_RE.match(sid or ""):
        return None
    return _read_json(os.path.join(SESS_DIR, f"{sid}.json"), None)


def _alive(reg):
    sock = reg.get("sock") or ""
    m = re.search(r"/(\d+)\.sock$", sock)
    if not sock or not os.path.exists(sock):
        return False
    return _pid_alive(int(m.group(1))) if m else True


def _title(reg):
    """The session's first prompt, trimmed: two sessions in one project are told
    apart by what they were started to do."""
    sid = reg["sid"]
    if sid in _titles:
        return _titles[sid]
    title = ""
    try:
        with open(reg.get("tp") or "") as f:
            for i, line in enumerate(f):
                if i > 400:
                    break
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") != "user" or e.get("isMeta") or e.get("turnOrigin") == "peer":
                    continue
                c = (e.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
                # Skip what Claude Code writes into the user role itself: command
                # wrappers (<command-name>…) and interruption markers.
                if (isinstance(c, str) and c.strip() and not c.lstrip().startswith("<")
                        and not c.lstrip().startswith("[Request interrupted")):
                    title = re.sub(r"\s+", " ", c).strip()[:80]
                    break
    except OSError:
        return ""
    if title:
        _titles[sid] = title
    return title


CLAUDE_SESSIONS = os.path.expanduser("~/.claude/sessions")


def _claude_registry():
    """Claude Code's own list of running sessions, by session id: the name you
    see in /list-agents ("date query response", or whatever /rename set) and
    whether it is busy. Only those two fields are read; the files next to
    these (*.key) are the sessions' inbox keys and are never touched."""
    out = {}
    try:
        names = os.listdir(CLAUDE_SESSIONS)
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        j = _read_json(os.path.join(CLAUDE_SESSIONS, n), None)
        if isinstance(j, dict) and j.get("sessionId"):
            # A "derived" name is Claude Code's placeholder from the folder
            # ("projb-6e"); an "auto" one is its summary of the conversation,
            # and one without a source is what you typed in /rename.
            name = j.get("name") if j.get("nameSource") != "derived" else None
            out[j["sessionId"]] = {"name": name, "status": j.get("status")}
    return out


def sessions():
    """Registered sessions, dead ones pruned. What the phone may see: never the
    socket path or its token."""
    out = []
    try:
        names = os.listdir(SESS_DIR)
    except OSError:
        return out
    registry = _claude_registry()
    for n in names:
        if not n.endswith(".json"):
            continue
        reg = _read_json(os.path.join(SESS_DIR, n), None)
        if not reg or not reg.get("sid"):
            continue
        if not _alive(reg):
            # The session is gone without a SessionEnd (crash, closed window):
            # forget it, and with it the token file.
            if _now() - reg.get("started", 0) > 60:
                try:
                    os.remove(os.path.join(SESS_DIR, n))
                except OSError:
                    pass
            continue
        sid = reg["sid"]
        cwd = reg.get("cwd") or ""
        cc = registry.get(sid, {})
        # An unnamed session is listed under its id; that's no name to show.
        name = cc.get("name") if cc.get("name") and not sid.startswith(cc.get("name")) else None
        out.append({
            "name": name,
            "session_id": sid,
            "project": os.path.basename(cwd.rstrip("/")) or cwd,
            "cwd": cwd,
            "title": _title(reg),
            "entrypoint": reg.get("ep") or "unknown",
            "state": _state.get(sid, reg.get("state") or cc.get("status") or "idle"),
            "started": reg.get("started"),
            "can_reply": bool(reg.get("sock")),
        })
    out.sort(key=lambda s: s.get("started") or 0, reverse=True)
    return out


def _session(sid):
    return next((s for s in sessions() if s["session_id"] == sid), None)


def hook(event, sid):
    """State from the Claude Code hooks: busy on a prompt, waiting on a
    permission prompt, idle when a turn stops. Replies are only delivered to an
    idle session, so a reply never lands mid-turn or on top of a permission
    dialog."""
    if not ID_RE.match(sid or ""):
        return
    if event in ("busy", "idle", "permission"):
        if _state.get(sid) != event:
            _state[sid] = event
            if events and enabled():
                events.append({"type": "session", "session_id": sid, "state": event})
        if event == "idle":
            replies.kick()
    elif event == "end":
        _state.pop(sid, None)
        _titles.pop(sid, None)
        if events and enabled():
            events.append({"type": "session", "session_id": sid, "state": "ended"})
        replies.kick()
    elif event == "start" and events and enabled():
        events.append({"type": "session", "session_id": sid, "state": "started"})


# ---- responses and clips ---------------------------------------------------------

_clip_lock = threading.Lock()


def publish_response(text, speed, session_id=None, event_id=None, cwd=None, markdown=None):
    """A finished Claude response, for the phone: the text immediately, the
    audio as soon as it is synthesized."""
    if not enabled():
        return
    event_id = event_id if ID_RE.match(event_id or "") else str(uuid.uuid4())
    if events.has("response", "id", event_id):
        return  # the Stop hook re-fired for the same message
    reg = _registration(session_id) or {}
    cwd = cwd or reg.get("cwd") or ""
    events.append({"type": "response", "id": event_id, "session_id": session_id,
                   "project": os.path.basename(cwd.rstrip("/")) or None,
                   "text": text, "clip": None,
                   # As written, for display; `text` is what gets spoken.
                   "markdown": (markdown or "")[:100_000] or None})
    threading.Thread(target=_make_clip, args=(event_id, session_id, text, speed),
                     daemon=True).start()


def _aac(wav, out):
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", wav, out],
                   check=True, capture_output=True, timeout=120)
    os.chmod(out, 0o600)


def _duration(wav):
    with wave.open(wav) as w:
        return w.getnframes() / float(w.getframerate())


def _make_clip(event_id, session_id, text, speed):
    """Synthesize with the engine you use on the Mac, one sentence-sized chunk
    at a time, and hand each to the phone as soon as it exists (`clip_part`):
    playback starts after the first sentence, not after the whole response.
    Then one AAC file of the lot (`clip`), for replay. AAC because a minute of
    speech is ~0.5MB instead of 2.6MB of WAV over the tailnet."""
    with _clip_lock:
        parts = []
        segments = []          # what each part says, and for how long: the phone
        try:                   # highlights the sentence being spoken
            for i, chunk in enumerate(_chunk(text)):
                p = os.path.join(CLIPS_DIR, f".{event_id}-{i}.wav")
                _synth(chunk, speed, p)
                parts.append(p)
                name = f"{event_id}-p{i}.m4a"
                _aac(p, os.path.join(CLIPS_DIR, name))
                seg = {"text": chunk, "duration": round(_duration(p), 3)}
                segments.append(seg)
                events.append({"type": "clip_part", "event_id": event_id, "session_id": session_id,
                               "index": i, "clip": name, **seg})
            if not parts:
                raise RuntimeError("nothing to speak")
            wav = os.path.join(CLIPS_DIR, f".{event_id}.wav")
            _concat(parts, wav)
            parts.append(wav)
            _aac(wav, os.path.join(CLIPS_DIR, f"{event_id}.m4a"))
            events.append({"type": "clip", "event_id": event_id, "session_id": session_id,
                           "clip": f"{event_id}.m4a", "duration": round(_duration(wav), 2),
                           "parts": len(parts) - 1, "segments": segments})
        except Exception as e:  # noqa: BLE001 — the text already arrived; say the audio failed
            log(f"clip {event_id} failed: {e}")
            events.append({"type": "clip", "event_id": event_id, "session_id": session_id,
                           "clip": None, "error": str(e)[:200]})
        finally:
            for p in parts:
                try:
                    os.remove(p)
                except OSError:
                    pass
            _prune_clips()


def _concat(parts, out):
    with wave.open(parts[0]) as first:
        params = first.getparams()
    with wave.open(out, "wb") as w:
        w.setparams(params)
        for p in parts:
            with wave.open(p) as r:
                if r.getparams()[:3] != params[:3]:
                    raise RuntimeError("chunks came back in different audio formats")
                w.writeframes(r.readframes(r.getnframes()))


def _prune_clips():
    """Keep the last KEEP_CLIPS full clips. Per-sentence parts only matter
    while a response is being heard, so they go after an hour."""
    try:
        names = os.listdir(CLIPS_DIR)
    except OSError:
        return
    now = _now()
    full, stale = [], []
    for n in names:
        if not n.endswith(".m4a"):
            continue
        p = os.path.join(CLIPS_DIR, n)
        try:
            mtime = os.path.getmtime(p)
        except OSError:
            continue
        if re.search(r"-p\d+\.m4a$", n):
            if now - mtime > 3600:
                stale.append(p)
        else:
            full.append((mtime, p))
    full.sort()
    for p in stale + [p for _, p in full[:-KEEP_CLIPS]]:
        try:
            os.remove(p)
        except OSError:
            pass


# ---- replies ---------------------------------------------------------------------

# Your words first, then one footnote. Without it Claude takes the message for
# another Claude session's and tries to answer that session with SendMessage
# (it has no sender address, so it guesses — and may message an unrelated
# session). A longer explanation of how the reply travelled had the opposite
# problem: Claude narrated it back. So the footnote says only what Claude needs:
# who is speaking, that there is nobody to message back, and to just answer.
# It claims no authority; Claude Code's own framing and permissions still apply.
REPLY_FOOTNOTE = ("(Spoken on the iPhone paired with this Mac and relayed by Aloud; may "
                  "contain transcription errors. There is no Claude session to message back: "
                  "answer here, directly, without commenting on how it arrived.)")


class Replies:
    """Spoken replies on their way into a session.

    queued -> sent -> delivered, or failed. The reply id comes from the phone,
    so a retry after a dropped connection finds the reply it already sent
    instead of submitting the instruction twice. A reply is sent at most once:
    once bytes reached the session nothing re-sends it, even if confirmation
    never comes — that case fails loudly and leaves re-sending to you."""

    def __init__(self):
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.items = {r["id"]: r for r in _read_json(REPLIES_PATH, [])}
        # A reply caught mid-flight by a restart may or may not have arrived.
        stale = [r for r in self.items.values() if r["status"] == "sent"]
        for r in stale:
            self._set(r, "failed", "Aloud restarted before delivery was confirmed — "
                                   "check the session on your Mac", save=False)
        if stale:
            self._save()
        threading.Thread(target=self._run, daemon=True).start()

    def _save(self):
        keep = sorted(self.items.values(), key=lambda r: r["created"])[-KEEP_REPLIES:]
        self.items = {r["id"]: r for r in keep}
        _write_json(REPLIES_PATH, keep)

    def _set(self, r, status, error=None, detail=None, save=True):
        r.update(status=status, error=error, detail=detail, updated=_now())
        if save:
            self._save()
        if events and enabled():
            events.append({"type": "reply", "reply_id": r["id"], "session_id": r["session_id"],
                           "status": status, "error": error, "detail": detail,
                           "text": r["text"], "created": r["created"]})

    def public(self, r):
        return {k: r.get(k) for k in ("id", "session_id", "text", "status", "error",
                                      "detail", "created", "updated", "in_reply_to")}

    def submit(self, reply_id, session_id, text, in_reply_to=None, device=None):
        text = (text or "").strip()
        if not ID_RE.match(reply_id or ""):
            raise ValueError("reply_id must be 8-64 letters, digits or dashes")
        if not text or len(text) > MAX_REPLY:
            raise ValueError(f"reply text must be 1-{MAX_REPLY} characters")
        with self.lock:
            if reply_id in self.items:        # a retry: same reply, not a new one
                return self.public(self.items[reply_id])
            r = {"id": reply_id, "session_id": session_id, "text": text,
                 "in_reply_to": in_reply_to, "device": (device or {}).get("id"),
                 "created": _now(), "status": "queued"}
            self.items[reply_id] = r
            s = _session(session_id)
            if not s:
                self._set(r, "failed", "that session isn't running any more")
            elif not s["can_reply"]:
                self._set(r, "failed", "this session can't receive replies")
            else:
                self._set(r, "queued")
        self.kick()
        return self.public(r)

    def get(self, reply_id):
        with self.lock:
            r = self.items.get(reply_id)
            return self.public(r) if r else None

    def kick(self):
        self.wake.set()

    def _run(self):
        while True:
            self.wake.wait(2.0)
            self.wake.clear()
            try:
                self._pump()
            except Exception as e:  # noqa: BLE001 — never let delivery die
                log(f"delivery loop error: {e}")

    def _pump(self):
        with self.lock:
            pending = sorted((r for r in self.items.values() if r["status"] == "queued"),
                             key=lambda r: r["created"])
            in_flight = {r["session_id"] for r in self.items.values() if r["status"] == "sent"}
        live = {s["session_id"]: s for s in sessions()}
        for r in pending:
            sid = r["session_id"]
            s = live.get(sid)
            if not s:
                with self.lock:
                    self._set(r, "failed", "that session ended before the reply could be delivered")
                continue
            # One writer per conversation, one reply at a time, and only into an
            # idle session: a busy turn or an open permission prompt waits.
            if sid in in_flight:
                continue
            state = s["state"]
            if state != "idle" and _turn_ended((_registration(sid) or {}).get("tp")):
                hook("idle", sid)
                state = "idle"
            if state != "idle":
                why = ("waiting — the session needs a permission answer on your Mac"
                       if state == "permission" else "waiting — the session is busy")
                if r.get("detail") != why:
                    with self.lock:
                        self._set(r, "queued", detail=why)
                continue
            self._deliver(r)
            in_flight.add(sid)

    def _deliver(self, r):
        reg = _registration(r["session_id"]) or {}
        marker = f"[aloud-reply {r['id']}]"
        body = f"{r['text']}\n\n{REPLY_FOOTNOTE} {marker}"
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(3)
                s.connect(reg["sock"])
                s.sendall((json.dumps({"type": "auth", "token": reg.get("tok", "")}) + "\n").encode())
                s.sendall((json.dumps({"type": "user", "message": {"role": "user", "content": body}})
                           + "\n").encode())
        except Exception as e:  # noqa: BLE001 — nothing was delivered, so it is safe to say so
            with self.lock:
                self._set(r, "failed", f"couldn't reach the session: {e}")
            return
        hook("busy", r["session_id"])    # it is about to start a turn with this
        with self.lock:
            self._set(r, "sent", detail="sent — waiting for the session to pick it up")
        threading.Thread(target=self._confirm, args=(r, reg.get("tp"), marker), daemon=True).start()

    def _confirm(self, r, transcript, marker):
        """Delivered means the session recorded it: the transcript gains a turn
        carrying this reply's marker."""
        deadline = _now() + CONFIRM_TIMEOUT
        while _now() < deadline:
            if transcript and _transcript_has(transcript, marker):
                with self.lock:
                    self._set(r, "delivered")
                return
            time.sleep(0.5)
        with self.lock:
            self._set(r, "failed", "sent, but the session never recorded it — check it on "
                                   "your Mac before sending again")


def _turn_ended(path):
    """Whether the session's last turn is over, from its transcript: Claude Code
    closes every turn with a `turn_duration` entry. This catches the turns the
    Stop hook never hears about — answering No to a permission prompt, or
    pressing Esc, ends the turn as an interruption, and no Stop hook fires."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 128 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except (OSError, TypeError):
        return False
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") in ("user", "assistant"):
            return False
        if e.get("type") == "system":
            return e.get("subtype") == "turn_duration"
    return False


def _transcript_has(path, marker):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 512 * 1024))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return False
    return json.dumps(marker)[1:-1] in tail


replies = None  # Replies, created by init()


# ---- transcription ---------------------------------------------------------------

def transcribe(audio, locale=None):
    helper = _helper() if _helper else None
    if not helper:
        raise RuntimeError("transcription needs the aloud-apple helper — install the app")
    if locale and not re.match(r"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", locale):
        locale = None
    fd, path = tempfile.mkstemp(suffix=".m4a", dir=RV_DIR)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(audio)
        t0 = time.monotonic()
        out = subprocess.run([helper, "transcribe", path] + ([locale] if locale else []),
                             capture_output=True, text=True, timeout=120)
        log(f"transcribed {len(audio)} bytes ({locale or 'default'}) in {time.monotonic() - t0:.1f}s, "
            f"exit {out.returncode}")
        try:
            res = json.loads(out.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise RuntimeError(out.stderr.strip()[:200] or "transcription failed")
        if not res.get("ok"):
            raise RuntimeError(res.get("error") or "transcription failed")
        return {"text": res.get("text", ""), "locale": res.get("locale")}
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


# ---- tailscale -------------------------------------------------------------------

_ts_cache = {"at": 0.0, "value": None}


def _tailscale(*args):
    for binary in TAILSCALE:
        try:
            out = subprocess.run([binary, *args], capture_output=True, text=True, timeout=4)
        except (OSError, subprocess.TimeoutExpired):
            continue
        return out.stdout
    return None


def tailscale_status():
    """Whether the phone can reach us: Tailscale up, and `tailscale serve`
    proxying to our port. Read-only — Aloud never changes Tailscale config."""
    if _now() - _ts_cache["at"] < 10 and _ts_cache["value"]:
        return _ts_cache["value"]
    port = _cfg["port"]
    st = {"installed": False, "running": False, "dns_name": None, "serve_url": None,
          "serve_command": SERVE_CMD.format(port=port)}
    raw = _tailscale("status", "--json")
    if raw is not None:
        st["installed"] = True
        try:
            j = json.loads(raw)
            st["running"] = j.get("BackendState") == "Running"
            st["dns_name"] = ((j.get("Self") or {}).get("DNSName") or "").rstrip(".") or None
        except ValueError:
            pass
    if st["running"]:
        try:
            serve = json.loads(_tailscale("serve", "status", "--json") or "{}")
        except ValueError:
            serve = {}
        for hostport, web in (serve.get("Web") or {}).items():
            for handler in (web.get("Handlers") or {}).values():
                if re.search(rf"(127\.0\.0\.1|localhost):{port}\b", handler.get("Proxy") or ""):
                    host = hostport[:-4] if hostport.endswith(":443") else hostport
                    st["serve_url"] = f"https://{host}"
    _ts_cache.update(at=_now(), value=st)
    return st


def set_serve(on):
    """Share (or stop sharing) the remote port on the tailnet — the same as
    running SERVE_CMD, but from the menu. Tailnet only; never Funnel.

    The first time on a tailnet, Tailscale asks for consent in the browser and
    the command waits until it's given. Its link is returned right away, the
    command left to finish on its own; the menu shows the result once it has.
    Tailscale keeps the setting (--bg): across disconnects, restarts, reboots."""
    port = _cfg["port"]
    args = (["serve", "--bg", "--https=8443", f"http://127.0.0.1:{port}"] if on
            else ["serve", "--https=8443", "off"])
    binary = next((b for b in TAILSCALE if b.startswith("/") and os.access(b, os.X_OK)), "tailscale")
    try:
        proc = subprocess.Popen([binary, *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except OSError as e:
        return {"ok": False, "error": f"couldn't run Tailscale: {e}"}
    found = {"url": None}
    seen = threading.Event()
    lines = []

    def read():
        for line in proc.stdout:
            lines.append(line.rstrip())
            m = re.search(r"https://login\.tailscale\.com/\S+", line)
            if m and not found["url"]:
                found["url"] = m.group(0)
                seen.set()
        proc.wait()
        _ts_cache["at"] = 0.0            # the next status reads the new state
        seen.set()
        log(f"tailscale {' '.join(args)} -> exit {proc.returncode}")

    threading.Thread(target=read, daemon=True).start()
    seen.wait(15)
    if found["url"]:
        return {"ok": True, "consent_url": found["url"]}
    if proc.poll() is None:
        return {"ok": True, "pending": True}
    if proc.returncode != 0:
        return {"ok": False, "error": ("\n".join(lines[-3:]) or "Tailscale refused")[:300]}
    return {"ok": True}


def request_allowed(headers, tailnet=False):
    """Refuse what a web browser could send us. Both ports listen on loopback,
    and a page you visit can still reach loopback: a cross-site POST, or — with
    DNS rebinding — a page that reads our answers, pairs itself, and sends
    "replies" into your Claude sessions. So: no browser Origin at all (the
    app, the hooks, the CLI and the iPhone app never send one), and the request
    must be addressed to this machine by name — localhost, or, on the remote
    port, this Mac's Tailscale name, as Tailscale Serve passes it on."""
    if headers.get("Origin"):
        return False
    host = (headers.get("Host") or "").strip().lower()
    if host.startswith("["):                      # [::1]:8877
        name = host[1:host.find("]")] if "]" in host else host
    else:
        name = host.rsplit(":", 1)[0] if ":" in host else host
    if name in ("127.0.0.1", "localhost", "::1"):
        return True
    if tailnet:
        mine = (tailscale_status().get("dns_name") or "").lower()
        return bool(mine) and name == mine
    return False


# ---- remote HTTP API ---------------------------------------------------------------

_server = None
_server_lock = threading.Lock()


class RemoteHandler(BaseHTTPRequestHandler):
    server_version = "AloudRemote/1"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def _error(self, code, error, message):
        self._json(code, {"error": error, "message": message})

    def _body(self, limit):
        n = int(self.headers.get("Content-Length") or 0)
        if n > limit:
            raise ValueError("body too large")
        return self.rfile.read(n) if n else b""

    def _auth(self):
        """Remote Voice off answers every request with 503 and nothing else, so
        turning it off cuts a paired phone off at once."""
        if not enabled():
            self._error(503, "remote_voice_off", "Remote Voice is turned off on the Mac")
            return None
        dev = authenticate(self.headers.get("Authorization"))
        if not dev:
            self._error(401, "unauthorized", "this device isn't paired, or was removed")
        return dev

    def _refused(self):
        if request_allowed(self.headers, tailnet=True):
            return False
        log(f"refused {self.command} {urlparse(self.path).path} "
            f"(host {self.headers.get('Host')!r}, origin {'yes' if self.headers.get('Origin') else 'no'})")
        self._error(403, "forbidden", "not from this Mac or its tailnet name")
        return True

    def do_GET(self):
        if self._refused():
            return
        u = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(u.query).items()}
        dev = self._auth()
        if not dev:
            return
        if u.path == "/v1/status":
            self._json(200, {"mac": mac_name(), "enabled": True,
                             "destination": _cfg["destination"], "seq": events.seq,
                             "log_id": _cfg["log_id"], "device": {"id": dev["id"], "name": dev["name"]}})
        elif u.path == "/v1/sessions":
            self._json(200, {"sessions": sessions()})
        elif u.path == "/v1/events":
            try:
                after = int(q.get("after", 0))
                wait = max(0.0, min(30.0, float(q.get("wait", 25))))
            except ValueError:
                return self._error(400, "bad_request", "after and wait must be numbers")
            reset = after > events.seq or (q.get("log_id") not in (None, "", _cfg["log_id"]))
            if reset:
                after = 0
            out = events.wait(after, wait, q.get("session") or None)
            if not enabled():
                return self._error(503, "remote_voice_off", "Remote Voice is turned off on the Mac")
            self._json(200, {"events": out, "seq": events.seq, "log_id": _cfg["log_id"], "reset": reset})
        elif u.path.startswith("/v1/clips/"):
            name = os.path.basename(u.path)
            path = os.path.join(CLIPS_DIR, name)
            if not re.match(r"^[A-Za-z0-9-]{8,64}\.m4a$", name) or not os.path.isfile(path):
                return self._error(404, "not_found", "no such clip (it may have been pruned)")
            with open(path, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "private, max-age=86400")
            self.end_headers()
            self.wfile.write(data)
        elif u.path.startswith("/v1/replies/"):
            r = replies.get(os.path.basename(u.path))
            self._json(200, r) if r else self._error(404, "not_found", "no such reply")
        else:
            self._error(404, "not_found", "no such endpoint")

    def do_POST(self):
        if self._refused():
            return
        u = urlparse(self.path)
        if u.path == "/v1/pair":
            if not enabled():
                return self._error(503, "remote_voice_off", "Remote Voice is turned off on the Mac")
            try:
                d = json.loads(self._body(4096) or b"{}")
            except ValueError:
                return self._error(400, "bad_request", "expected JSON")
            res, err = pair(d.get("code"), d.get("name"), self.headers.get("Tailscale-User-Login"))
            return self._json(200, res) if res else self._error(403, "pairing_failed", err)
        dev = self._auth()
        if not dev:
            return
        if u.path == "/v1/transcribe":
            try:
                audio = self._body(MAX_AUDIO)
            except ValueError:
                return self._error(413, "too_large", "recording is too long")
            if not audio:
                return self._error(400, "bad_request", "no audio")
            try:
                self._json(200, transcribe(audio, self.headers.get("X-Locale")))
            except Exception as e:  # noqa: BLE001
                self._error(500, "transcription_failed", str(e)[:300])
        elif u.path == "/v1/replies":
            try:
                d = json.loads(self._body(64 * 1024) or b"{}")
                r = replies.submit(d.get("reply_id"), d.get("session_id"), d.get("text"),
                                   d.get("in_reply_to"), dev)
            except ValueError as e:
                return self._error(400, "bad_request", str(e))
            self._json(202, r)
        else:
            self._error(404, "not_found", "no such endpoint")


def start_server():
    global _server
    with _server_lock:
        if _server:
            return
        port = _cfg["port"]
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", port), RemoteHandler)
        except OSError as e:
            log(f"could not listen on 127.0.0.1:{port}: {e}")
            return
        srv.daemon_threads = True
        _server = srv
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"listening on 127.0.0.1:{port}")


def stop_server():
    global _server
    with _server_lock:
        srv, _server = _server, None
    if events:
        events.wake()           # long polls return at once, with a 503
    if srv:
        srv.shutdown()
        srv.server_close()
        log("stopped listening")


# ---- the daemon's side -------------------------------------------------------------

_mac_name = None


def mac_name():
    """The name you gave the Mac ("Fabian's MacBook Pro"), not its hostname."""
    global _mac_name
    if _mac_name is None:
        try:
            _mac_name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True,
                                       text=True, timeout=3).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            _mac_name = ""
        _mac_name = _mac_name or socket.gethostname()
    return _mac_name


def status():
    with _dev_lock:
        pairing = ({"code": _pairing["code"], "expires_in": int(_pairing["expires"] - _now())}
                   if _pairing["code"] and _now() < _pairing["expires"] else None)
    return {"enabled": enabled(), "destination": _cfg["destination"], "port": _cfg["port"],
            "listening": _server is not None, "devices": devices_status(), "pairing": pairing,
            "sessions": sessions(), "tailscale": tailscale_status()}


def handle_local(method, path, body):
    """The /rv/* routes on the daemon's loopback control port. Returns (code, obj)."""
    try:
        d = json.loads(body or b"{}") if method == "POST" else {}
    except ValueError:
        return 400, {"error": "expected JSON"}
    if method == "GET" and path == "/rv/status":
        return 200, status()
    if method == "POST" and path == "/rv/config":
        try:
            set_config(d.get("enabled"), d.get("destination"))
        except ValueError as e:
            return 400, {"error": str(e)}
        return 200, status()
    if method == "POST" and path == "/rv/pair":
        if not enabled():
            return 409, {"error": "turn Remote Voice on first"}
        return 200, start_pairing()
    if method == "POST" and path == "/rv/serve":
        res = set_serve(d.get("on") is not False)
        return (200 if res.get("ok") else 500), res
    if method == "POST" and path == "/rv/revoke":
        try:
            return 200, {"removed": revoke(d.get("id"), d.get("all") is True)}
        except ValueError as e:
            return 400, {"error": str(e)}
    if method == "POST" and path == "/rv/hook":
        hook(d.get("event"), d.get("session_id"))
        return 200, {"ok": True}
    return 404, {"error": "no such route"}


def init(synth_to_file, chunk_text, apple_helper):
    global _synth, _chunk, _helper, events, replies, _devices
    _synth, _chunk, _helper = synth_to_file, chunk_text, apple_helper
    for d in (RV_DIR, CLIPS_DIR, SESS_DIR):
        _private_dir(d)
    _load_config()
    _write_json(CONFIG_PATH, _cfg)
    _devices = _read_json(DEVICES_PATH, [])
    events = EventLog()
    replies = Replies()
    if enabled():
        start_server()
