#!/usr/bin/env python3
"""Always-on local TTS daemon built on Kokoro — the supervisor half.

Owns the API and playback, not the model. Text comes in on /say, is split into
sentences, handed to the synth worker (synth.py) a chunk at a time, and played
through afplay from a single queue — so there is one authoritative place to
pause/stop/skip. Binds to loopback only; nothing leaves the machine.

Deliberately stdlib-only, so this process is ~24MB. torch, kokoro and the voice
model — the other ~1.2GB — live in the worker subprocess, which is started on
demand and killed after ALOUD_IDLE_TIMEOUT of silence. That is what makes an
idle engine nearly free while still being a running engine.

  POST /say     {"text": "...", "speed": 1.0}   enqueue speech (returns 202)
  POST /pause                                   suspend current + halt queue
  POST /resume                                  resume
  POST /stop                                    kill current + clear queue
  POST /skip                                    drop current clip, keep going
  POST /speed   {"speed": 1.2}                  set default speed
  POST /voice   {"voice": "am_puck"}            switch voice (400 if it won't load)
  GET  /state                                   {enabled,paused,speaking,queued,speed,voice,loaded}
  GET  /health                                  "ok"
  POST /speak   {"text": "..."}  -> audio/wav   (legacy: returns audio, no playback)

Waking the worker costs ~6s; keeping it costs ~1.2GB. Idle is the common case,
so the default trades the seconds. Either way this process keeps answering, so
"engine running" still means "will speak".

Env: ALOUD_PORT(8877) KOKORO_VOICE(af_heart) ALOUD_SPEED(1.0) KOKORO_LANG(a)
     ALOUD_IDLE_TIMEOUT(600s, 0 = keep the worker alive forever)
"""
import json
import os
import queue
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Stdlib only, on purpose. Importing torch/kokoro here would put ~800MB back into
# a process that spends almost all its life waiting — see synth.py.

PORT = int(os.environ.get("ALOUD_PORT", "8877"))
FLAG_DIR = os.path.expanduser("~/.aloud")
ENABLED_FLAG = os.path.join(FLAG_DIR, "speak.enabled")
SPEED_FLAG = os.path.join(FLAG_DIR, "speak.speed")
ENGINE_FLAG = os.path.join(FLAG_DIR, "speak.engine")
TMPDIR = tempfile.mkdtemp(prefix="aloud-")

ENGINES = ("apple", "kokoro")
DEFAULT_VOICE = {"kokoro": "af_heart", "apple": "Samantha"}
# Apple's `say` takes words per minute, not a multiplier. Its own default is
# around here, so this is what maps our 1.0x onto "normal".
APPLE_BASE_WPM = 175

# Kokoro's language codes. A voice name begins with its own code — "bf_emma" is
# British — so the voice determines the language and there is nothing separate to
# choose. `extra` names the dependency that language needs beyond what
# requirements.txt installs; None means it works out of the box.
DEFAULT_LANG = "a"
KOKORO_LANGS = {
    "a": {"name": "American English", "extra": None},
    "b": {"name": "British English", "extra": None},
    "e": {"name": "Spanish", "extra": None},
    "f": {"name": "French", "extra": None},
    "h": {"name": "Hindi", "extra": None},
    "i": {"name": "Italian", "extra": None},
    "p": {"name": "Brazilian Portuguese", "extra": None},
    "j": {"name": "Japanese", "extra": "misaki[ja]"},
    "z": {"name": "Mandarin Chinese", "extra": "misaki[zh]"},
}


# Every voice in Kokoro-82M, by language. Hardcoded rather than read from the
# model directory so the list is answerable before anything is downloaded — the
# menu can show what you would get. The model is pinned, so this cannot drift.
KOKORO_VOICES = {
    "a": ["af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore",
          "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
          "am_michael", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
          "am_onyx", "am_puck", "am_santa"],
    "b": ["bf_emma", "bf_alice", "bf_isabella", "bf_lily",
          "bm_george", "bm_daniel", "bm_fable", "bm_lewis"],
    "e": ["ef_dora", "em_alex", "em_santa"],
    "f": ["ff_siwis"],
    "h": ["hf_alpha", "hf_beta", "hm_omega", "hm_psi"],
    "i": ["if_sara", "im_nicola"],
    "p": ["pf_dora", "pm_alex", "pm_santa"],
    "j": ["jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo"],
    "z": ["zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
          "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"],
}


def lang_of(voice):
    """A Kokoro voice's language code is its first character."""
    return voice[0] if voice and voice[0] in KOKORO_LANGS else DEFAULT_LANG


def kokoro_voices():
    """Every Kokoro voice, tagged with its language and whether that language
    needs a package we don't install by default."""
    out = []
    for code, names in KOKORO_VOICES.items():
        meta = KOKORO_LANGS[code]
        for n in names:
            out.append({"name": n, "lang": code, "language": meta["name"],
                        "gender": "female" if n[1] == "f" else "male",
                        "extra": meta["extra"]})
    return out

# Per engine, because the names have nothing in common ("af_heart" vs
# "Isha (Premium)") and switching engines should not silently mean switching to
# some other engine's idea of a voice.
def _voice_flag(engine):
    return os.path.join(FLAG_DIR, f"speak.voice.{engine}")


def _flag(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


# The flag files are what the menubar, /speak and the hooks all write, so they —
# not the boot-time env — are the source of truth on restart. Otherwise the
# daemon comes back at 1.0x while every caller is still passing 1.25x from the
# flag file, and the menubar's checkmark contradicts what you actually hear.
def _initial_engine():
    e = _flag(ENGINE_FLAG)
    if e not in ENGINES:
        e = os.environ.get("ALOUD_ENGINE", "apple")
    # Never boot into an engine that can't run. Kokoro without its venv would
    # come up looking selected and fail every request; Apple always works.
    if e == "kokoro" and not os.access(os.path.join(FLAG_DIR, ".venv", "bin", "python"), os.X_OK):
        print("[aloud] kokoro selected but not installed — falling back to apple", flush=True)
        return "apple"
    return e


def _initial_voice(engine):
    v = _flag(_voice_flag(engine))
    if v and valid_voice(engine, v):
        return v
    # Pre-split installs kept one unqualified speak.voice, always a Kokoro name.
    if engine == "kokoro":
        legacy = _flag(os.path.join(FLAG_DIR, "speak.voice"))
        if legacy and valid_voice("kokoro", legacy):
            return legacy
        return os.environ.get("KOKORO_VOICE", DEFAULT_VOICE["kokoro"])
    return DEFAULT_VOICE[engine]


def valid_voice(engine, name):
    """Cheap shape check only. Whether the voice actually *exists* is settled by
    trying to synthesize with it — see set_voice."""
    if engine == "kokoro":
        # The voice set is fixed by the pinned model, so a name that isn't in it
        # is a typo. Catching it here avoids spawning a worker — possibly in a
        # different language, a ~6s round trip — only to fail.
        return any(name in names for names in KOKORO_VOICES.values())
    # Apple names are free-form ("Isha (Premium)", "Eddy (English (UK))"). They go
    # to `say` as one argv element, never through a shell, so the only thing worth
    # refusing is something that isn't a plausible name at all.
    return bool(name) and "\n" not in name and len(name) < 128


def _initial_speed():
    try:
        return max(0.5, min(2.0, float(_flag(SPEED_FLAG))))
    except ValueError:
        return float(os.environ.get("ALOUD_SPEED", "1.0"))


ENGINE = _initial_engine()
VOICES = {e: _initial_voice(e) for e in ENGINES}
DEFAULT_SPEED = _initial_speed()

IDLE_TIMEOUT = float(os.environ.get("ALOUD_IDLE_TIMEOUT", "600"))  # 0 disables
IDLE_CHECK_EVERY = 15.0
WORKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "synth.py")
VENV_PY = os.path.join(FLAG_DIR, ".venv", "bin", "python")


def kokoro_available():
    """Whether the Kokoro engine can run at all — i.e. `aloud setup` has been."""
    return os.access(VENV_PY, os.X_OK)


def worker_python():
    """The interpreter that can actually import torch and kokoro.

    Deliberately not sys.executable: the supervisor is stdlib-only and will often
    be running on the system python3, which is what lets the Apple engine work
    with no setup at all. Handing that down to the worker would fail every
    import it makes."""
    return VENV_PY if kokoro_available() else sys.executable


class Worker:
    """The synthesis subprocess, started on demand and killed when idle.

    All the weight (torch, kokoro, the model) lives over there, so this process
    stays around 22MB. One worker, one request at a time — which is also what the
    old in-process model_lock enforced, KPipeline not being thread-safe.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self._id = 0
        self.last_use = time.monotonic()
        # True only while a worker is actually coming up. /state exposes it so the
        # menubar can spin: "loaded: false" alone can't tell "sleeping, nothing
        # happening" from "waking up right now", and those look very different to
        # someone waiting for their first sentence.
        self.loading = False
        # The language this worker was built for. KPipeline fixes its language at
        # construction, so changing it means a new process — see ensure_lang.
        self.lang = None

    def alive(self):
        p = self.proc
        return p is not None and p.poll() is None

    def ensure_lang(self, lang):
        """Make the next request run under `lang`, restarting the worker if the
        running one was built for a different one. Caller holds the lock."""
        if self.alive() and self.lang != lang:
            print(f"[aloud] language {self.lang} -> {lang}, restarting the worker", flush=True)
            self.kill(quiet=True)
        self.lang = lang

    def _spawn(self):
        """Start the worker and block until it reports ready. Caller holds the lock."""
        t0 = time.monotonic()
        self.loading = True
        lang = self.lang or DEFAULT_LANG
        print(f"[aloud] starting synth worker (lang={lang}) ...", flush=True)
        try:
            env = dict(os.environ, KOKORO_LANG=lang)
            self.proc = subprocess.Popen(
                [worker_python(), WORKER],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                # stderr is inherited: the worker's own logging lands in server.log.
                text=True,
                bufsize=1,
                env=env,
            )
            while True:
                line = self.proc.stdout.readline()
                if not line:  # worker died during startup
                    self.proc = None
                    raise RuntimeError("synth worker exited before becoming ready")
                try:
                    if json.loads(line).get("ready"):
                        break
                except ValueError:
                    continue
        finally:
            # Always clear it, including on the failure paths — a stuck "loading"
            # would leave the menubar spinning forever on a worker that never came.
            self.loading = False
        print(f"[aloud] synth worker ready in {time.monotonic() - t0:.1f}s", flush=True)

    def request(self, payload, lang=None):
        """Send one request and return its reply, starting the worker if needed.

        `lang` is applied under the same lock as the send, so a language switch
        can't land between the restart and the request it was meant for."""
        with self.lock:
            self.last_use = time.monotonic()
            if lang:
                self.ensure_lang(lang)
            if not self.alive():
                self._spawn()
            self._id += 1
            payload = dict(payload, id=self._id)
            try:
                self.proc.stdin.write(json.dumps(payload) + "\n")
                self.proc.stdin.flush()
                line = self.proc.stdout.readline()
            except (BrokenPipeError, ValueError) as e:
                self.kill()
                raise RuntimeError(f"synth worker died: {e}") from e
            if not line:
                self.kill()
                raise RuntimeError("synth worker died mid-request")
            self.last_use = time.monotonic()  # synthesis itself can take a while
            reply = json.loads(line)
            if not reply.get("ok"):
                raise RuntimeError(reply.get("error") or "synth failed")
            return reply

    def kill(self, quiet=False):
        """Stop the worker and hand its memory back. Safe if already stopped."""
        p, self.proc = self.proc, None
        if p is None or p.poll() is not None:
            return False
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
        if not quiet:
            print("[aloud] synth worker stopped (idle)", flush=True)
        return True


worker = Worker()


_apple_voices = {"at": 0.0, "list": []}


def apple_voices():
    """Voices `say` will accept, from `say -v '?'`, with their language and quality.

    Cached briefly — the list only changes when someone downloads a voice in
    System Settings, and the menu asks for it every time it opens.
    """
    if time.monotonic() - _apple_voices["at"] < 60 and _apple_voices["list"]:
        return _apple_voices["list"]
    out = []
    try:
        raw = subprocess.run(["say", "-v", "?"], capture_output=True, text=True,
                             timeout=15).stdout
    except Exception as e:  # noqa: BLE001
        print(f"[aloud] could not list Apple voices: {e}", flush=True)
        return _apple_voices["list"]
    for line in raw.splitlines():
        # "Name  lang  # sample". The name may itself contain spaces and nested
        # parens ("Eddy (English (UK))") and is sometimes separated from the
        # locale by a single space, so anchor on the locale rather than on gaps.
        m = re.match(r"^(.*\S)\s+([a-z]{2}[-_][A-Z]{2}[^\s]*)\s+#", line)
        if not m:
            continue
        name, lang = m.group(1), m.group(2)
        quality = "default"
        if name.endswith("(Premium)"):
            quality = "premium"
        elif name.endswith("(Enhanced)"):
            quality = "enhanced"
        out.append({"name": name, "lang": lang, "quality": quality})
    if out:
        _apple_voices.update(at=time.monotonic(), list=out)
    return out


def apple_voice_exists(name):
    """`say` accepts an unknown -v and quietly uses the default voice instead,
    exiting 0 — so a trial synth proves nothing here and the list is the only
    real check."""
    return any(v["name"] == name for v in apple_voices())


def apple_synth(text, speed, path, voice=None):
    """Synthesize with macOS's built-in engine. Costs this process nothing: `say`
    is a short-lived child and the synthesis happens in an OS-owned XPC service.
    Emitting WAV keeps the output identical to the worker's, so the playback queue
    (and pause/stop/skip) needs to know nothing about which engine produced it."""
    wpm = max(90, min(400, round(APPLE_BASE_WPM * speed)))
    subprocess.run(
        ["say", "-v", voice or VOICES["apple"], "-r", str(wpm),
         "--file-format=WAVE", "--data-format=LEI16@22050", "-o", path, "--", text],
        check=True, capture_output=True, timeout=120,
    )


def synth_to_file(text, speed, path, voice=None, engine=None):
    if (engine or ENGINE) == "apple":
        apple_synth(text, speed, path, voice)
    else:
        v = voice or VOICES["kokoro"]
        # The voice decides the language on every request. A pipeline in the
        # wrong language does not fail — it mispronounces — so this is worth
        # checking each time rather than trusting set_voice to be the only path in.
        worker.request({"text": text, "speed": speed, "voice": v, "out": path},
                       lang=lang_of(v))


def idle_reaper():
    """Kill the synth worker once nothing has used it for IDLE_TIMEOUT seconds.

    Stops the *worker*, never the daemon: this process keeps answering /health
    and /state, so "engine running" still means "will speak" — it just pays a few
    seconds to wake up. Stopping the engine itself stays a deliberate act, and one
    the Stop hook deliberately can't undo.

    Never fires mid-utterance: audio already synthesized is still queued, and a
    clip that is playing means more may be coming.
    """
    if IDLE_TIMEOUT <= 0:
        return
    while True:
        time.sleep(IDLE_CHECK_EVERY)
        if not worker.alive():
            continue
        if speaking.is_set() or synth_q.qsize() or play_q.qsize():
            continue
        if time.monotonic() - worker.last_use < IDLE_TIMEOUT:
            continue
        # Take the request lock so this can't land between a caller's write and
        # its read, which would leave that request waiting on a dead pipe.
        with worker.lock:
            if not speaking.is_set() and time.monotonic() - worker.last_use >= IDLE_TIMEOUT:
                worker.kill()


def set_voice(name, engine=None):
    """Switch the current engine's voice. Proves the voice actually works (with a
    throwaway synth) before committing to it — an unknown name would otherwise blow
    up on the next real request, leaving the daemon alive but permanently mute."""
    engine = engine or ENGINE
    if not valid_voice(engine, name):
        return False
    if name == VOICES[engine]:
        return True
    previous_lang = worker.lang
    try:
        if engine == "apple":
            if not apple_voice_exists(name):
                raise RuntimeError("no such voice — see `say -v '?'`")
        else:
            # The voice carries its language, and KPipeline fixes that at
            # construction, so a cross-language switch means a new worker. Passing
            # the language here means the check runs under the pipeline that will
            # actually speak this voice.
            worker.request({"check_voice": name}, lang=lang_of(name))
    except Exception as e:  # noqa: BLE001 — any failure means "keep the old voice"
        # Missing language extras surface here as an import error from the
        # worker. Say which package, rather than leaving a bare traceback in a
        # log the user will never read.
        if engine == "kokoro":
            # Put the language back, so the next request doesn't inherit a
            # pipeline built for a voice we just refused.
            with worker.lock:
                worker.ensure_lang(previous_lang or lang_of(VOICES["kokoro"]))
            extra = KOKORO_LANGS.get(lang_of(name), {}).get("extra")
            if extra:
                print(f"[aloud] {KOKORO_LANGS[lang_of(name)]['name']} needs an extra package: "
                      f"~/.aloud/.venv/bin/python -m pip install '{extra}'", flush=True)
        print(f"[aloud] voice '{name}' rejected: {e}", flush=True)
        return False
    VOICES[engine] = name
    print(f"[aloud] {engine} voice -> {name}", flush=True)
    return True


def set_engine(name):
    """Switch engine. Leaving Kokoro kills its worker: the whole reason to be on
    Apple is that nothing of ours stays resident, which a parked 1.26GB worker
    would quietly undo."""
    global ENGINE
    if name not in ENGINES:
        return False
    if name == ENGINE:
        return True
    # Refuse rather than accept and then be mute: without the venv the worker
    # cannot import torch, and every later request would fail one at a time with
    # no hint that the real answer is "run `aloud setup`".
    if name == "kokoro" and not kokoro_available():
        print("[aloud] kokoro not installed — run `aloud setup`", flush=True)
        return False
    ENGINE = name
    print(f"[aloud] engine -> {name}", flush=True)
    if name != "kokoro":
        with worker.lock:
            worker.kill(quiet=True)
    return True


def chunk_text(text, target=140):
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    parts = re.findall(r".*?[.!?](?:\s|$)|.+$", text)
    out, buf = [], ""
    for p in parts:
        buf += p
        if len(buf) >= target:
            out.append(buf.strip())
            buf = ""
    if buf.strip():
        out.append(buf.strip())
    return out


# ---- playback engine -------------------------------------------------------
# Two queues: synth_q (text -> wav, prefetch) feeds play_q (wav -> afplay).
# A generation counter invalidates in-flight work on /stop.
state_lock = threading.Lock()
synth_q = queue.Queue()
play_q = queue.Queue()
resume_evt = threading.Event()
resume_evt.set()  # set == not paused (gate between clips)
speaking = threading.Event()
_gen = 0
_paused = False
_default_speed = DEFAULT_SPEED
_current = {"proc": None, "path": None}


def _drain(q, unlink=False):
    try:
        while True:
            item = q.get_nowait()
            if unlink:
                try:
                    os.remove(item[1])
                except OSError:
                    pass
    except queue.Empty:
        pass


def synth_worker():
    while True:
        g, text, sp = synth_q.get()
        with state_lock:
            if g != _gen:
                continue
        fd, path = tempfile.mkstemp(suffix=".wav", dir=TMPDIR)
        os.close(fd)
        try:
            synth_to_file(text, sp, path)
        except Exception as e:  # noqa: BLE001
            try:
                os.remove(path)
            except OSError:
                pass
            print(f"[aloud] synth error: {e}", flush=True)
            continue
        with state_lock:
            if g != _gen:
                try:
                    os.remove(path)
                except OSError:
                    pass
                continue
        play_q.put((g, path))


def play_worker():
    global _current
    while True:
        g, path = play_q.get()
        with state_lock:
            stale = g != _gen
        if stale:
            try:
                os.remove(path)
            except OSError:
                pass
            continue
        resume_evt.wait()  # block here while paused between clips
        with state_lock:
            if g != _gen:
                try:
                    os.remove(path)
                except OSError:
                    pass
                continue
        try:
            proc = subprocess.Popen(["afplay", path])
        except Exception as e:  # noqa: BLE001
            print(f"[aloud] afplay error: {e}", flush=True)
            try:
                os.remove(path)
            except OSError:
                pass
            continue
        with state_lock:
            _current = {"proc": proc, "path": path}
        speaking.set()
        proc.wait()
        speaking.clear()
        with state_lock:
            _current = {"proc": None, "path": None}
        try:
            os.remove(path)
        except OSError:
            pass


def enqueue(text, speed):
    for c in chunk_text(text):
        synth_q.put((_gen, c, speed))


def pause():
    global _paused
    with state_lock:
        _paused = True
        proc = _current["proc"]
    resume_evt.clear()
    if proc:
        try:
            os.kill(proc.pid, signal.SIGSTOP)
        except ProcessLookupError:
            pass


def resume():
    global _paused
    with state_lock:
        _paused = False
        proc = _current["proc"]
    if proc:
        try:
            os.kill(proc.pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
    resume_evt.set()


def stop():
    global _gen, _paused
    with state_lock:
        _gen += 1
        proc = _current["proc"]
        _paused = False
    _drain(synth_q)
    _drain(play_q, unlink=True)
    resume_evt.set()
    if proc:
        try:
            os.kill(proc.pid, signal.SIGCONT)  # in case it was paused
        except ProcessLookupError:
            pass
        try:
            proc.kill()
        except ProcessLookupError:
            pass


def skip():
    with state_lock:
        proc = _current["proc"]
    if proc:
        try:
            os.kill(proc.pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
        try:
            proc.kill()
        except ProcessLookupError:
            pass


def state():
    enabled = True
    try:
        with open(ENABLED_FLAG) as f:
            enabled = f.read().strip() != "off"
    except OSError:
        pass
    return {
        "enabled": enabled,
        "paused": _paused,
        "speaking": speaking.is_set(),
        "queued": synth_q.qsize() + play_q.qsize(),
        "speed": _default_speed,
        "engine": ENGINE,
        "voice": VOICES[ENGINE],
        "voices": dict(VOICES),   # so a menu can tick the right one per engine
        # Kokoro's language, derived from its voice — there is nothing separate
        # to set. Reported so a UI can show "British English" next to bf_emma.
        "lang": lang_of(VOICES["kokoro"]) if ENGINE == "kokoro" else None,
        "language": (KOKORO_LANGS[lang_of(VOICES["kokoro"])]["name"]
                     if ENGINE == "kokoro" else None),
        # False once the idle reaper has stopped the synth worker. The daemon is
        # still up and will speak — the next request just pays the wake-up first.
        # "loaded" means ready to synthesize, not merely spawned — a worker that is
        # still importing torch can't speak yet, and callers use this to decide
        # whether the next sentence is instant. Apple has nothing to load, so it is
        # always ready and never loading.
        "loaded": True if ENGINE == "apple" else (worker.alive() and not worker.loading),
        "loading": False if ENGINE == "apple" else worker.loading,
        "idle_timeout": IDLE_TIMEOUT,
    }


threading.Thread(target=synth_worker, daemon=True).start()
threading.Thread(target=play_worker, daemon=True).start()
threading.Thread(target=idle_reaper, daemon=True).start()


def _warm():
    """Bring the Kokoro worker up in the background so the first sentence is
    instant. Off the main thread: the HTTP port should be answering immediately,
    not after the model finishes loading — the menubar polls /state to decide the
    engine is up, and a slow boot used to look like a failed start.

    Only for Kokoro. Apple has nothing to warm, and starting a 1.26GB worker for
    an engine you aren't using is precisely the cost this engine avoids."""
    if ENGINE != "kokoro":
        return
    try:
        worker.request({"text": "Kokoro is ready.", "speed": DEFAULT_SPEED,
                        "voice": VOICES["kokoro"], "out": os.path.join(TMPDIR, "warm.wav")})
    except Exception as e:  # noqa: BLE001
        print(f"[aloud] warm-up failed: {e}", flush=True)


threading.Thread(target=_warm, daemon=True).start()

_idle = f"{IDLE_TIMEOUT:.0f}s idle unload" if IDLE_TIMEOUT > 0 else "idle unload off"
print(f"[aloud] ready on 127.0.0.1:{PORT} (engine={ENGINE}, "
      f"voice={VOICES[ENGINE]}, speed={DEFAULT_SPEED}, {_idle})", flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa: BLE001
            return {}

    def do_GET(self):
        if self.path.startswith("/health"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        elif self.path.startswith("/voices"):
            # Apple's list is whatever is installed, so it has to be discovered.
            # Kokoro's is fixed and the menubar ships it.
            self._json(200, {"apple": apple_voices(), "kokoro": kokoro_voices()})
        elif self.path.startswith("/state"):
            self._json(200, state())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global _default_speed
        p = self.path
        if p.startswith("/say"):
            d = self._body()
            text = (d.get("text") or "").strip()
            speed = float(d.get("speed") or _default_speed)
            if text:
                enqueue(text, speed)
            self._json(202, {"queued": True})
        elif p.startswith("/pause"):
            pause()
            self._json(200, state())
        elif p.startswith("/resume"):
            resume()
            self._json(200, state())
        elif p.startswith("/stop"):
            stop()
            self._json(200, state())
        elif p.startswith("/skip"):
            skip()
            self._json(200, state())
        elif p.startswith("/speed"):
            d = self._body()
            try:
                _default_speed = max(0.5, min(2.0, float(d.get("speed"))))
            except (TypeError, ValueError):
                pass
            self._json(200, state())
        elif p.startswith("/voice"):
            d = self._body()
            ok = set_voice((d.get("voice") or "").strip(), d.get("engine"))
            self._json(200 if ok else 400, state())
        elif p.startswith("/engine"):
            d = self._body()
            ok = set_engine((d.get("engine") or "").strip().lower())
            self._json(200 if ok else 400, state())
        elif p.startswith("/speak"):  # legacy: synth only, return wav
            d = self._body()
            text = (d.get("text") or "").strip()
            if not text:
                self.send_response(400)
                self.end_headers()
                return
            # The worker writes the wav; this process never touches soundfile.
            fd, path = tempfile.mkstemp(suffix=".wav", dir=TMPDIR)
            os.close(fd)
            try:
                synth_to_file(text, float(d.get("speed") or _default_speed), path)
                with open(path, "rb") as f:
                    payload = f.read()
            except Exception as e:  # noqa: BLE001
                print(f"[aloud] /speak error: {e}", flush=True)
                self.send_response(500)
                self.end_headers()
                return
            finally:
                try:
                    os.remove(path)
                except OSError:
                    pass
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_response(404)
            self.end_headers()


def _shutdown(signum, frame):
    """Take the worker down with us. It is a child process holding ~1.2GB; an
    orphan of it would keep that memory and go on answering nothing."""
    worker.kill(quiet=True)
    os._exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
