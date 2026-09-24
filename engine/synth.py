#!/usr/bin/env python3
"""Kokoro synthesis worker — the heavy half of the TTS daemon.

Everything expensive lives here: torch (~193MB), kokoro (~377MB) and the voice
model itself (~850MB). server.py holds none of it, so an idle engine is a ~22MB
supervisor instead of an 809MB Python process. The supervisor starts this on
demand and kills it after ALOUD_IDLE_TIMEOUT of silence; a wake-up costs a few
seconds, which is the whole trade.

Protocol: one JSON object per line on stdin, one per line on stdout.

  <- {"id": 1, "text": "...", "speed": 1.0, "voice": "af_heart", "out": "/tmp/x.wav"}
  -> {"id": 1, "ok": true}                     wav written to `out`
  -> {"id": 1, "ok": false, "error": "..."}

  <- {"id": 2, "check_voice": "am_puck"}       load it; don't synthesize anything
  -> {"id": 2, "ok": true|false, "error": ...}

  -> {"ready": true}                           once, after the model is loaded

Env: KOKORO_LANG(a) KOKORO_VOICE(af_heart)
"""
import json
import os
import sys

# Claim the real stdout for the protocol, then point fd 1 at stderr. torch,
# kokoro and huggingface all print chatter on import; a single stray line on
# stdout would desynchronize the protocol and hang the supervisor waiting for a
# reply it can never parse. After this, nothing but us can reach the pipe.
_out = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from huggingface_hub import try_to_load_from_cache  # noqa: E402
from kokoro import KModel, KPipeline  # noqa: E402

LANG = os.environ.get("KOKORO_LANG", "a")
SR = 24000
REPO = "hexgrad/Kokoro-82M"


def cached(filename):
    """The local path of a file already in the Hugging Face cache, or None.

    Handed to kokoro instead of a name, because given a name it asks the Hub
    whether the file changed on every load — config, model and voice, three
    requests, each allowed 10s. On a flaky network (just woken, VPN, captive
    Wi-Fi) that turned a ~5s start into 35-90s even with everything on disk.
    None falls back to kokoro's own download, so first use still works."""
    path = try_to_load_from_cache(REPO, filename)
    return path if isinstance(path, str) else None


def voice_ref(voice):
    """A voice as kokoro should load it: the cached .pt file when we have it,
    the bare name (which downloads it) when we don't."""
    return cached(f"voices/{voice}.pt") or voice


device = "mps" if torch.backends.mps.is_available() else "cpu"
print(f"[kokoro-synth] loading model on {device} ...", file=sys.stderr, flush=True)
model = KModel(repo_id=REPO, config=cached("config.json"),
               model=cached(KModel.MODEL_NAMES[REPO])).to(device).eval()
pipe = KPipeline(lang_code=LANG, repo_id=REPO, model=model)

# Warm the MPS kernels so the first real sentence isn't paying for shader
# compilation on top of everything else.
for _ in pipe("Ready.", voice=voice_ref(os.environ.get("KOKORO_VOICE", "af_heart")), speed=1.0):
    pass


def reply(obj):
    _out.write(json.dumps(obj) + "\n")


def synth(text, speed, voice):
    chunks = [a for _, _, a in pipe(text, voice=voice_ref(voice), speed=speed)]
    if not chunks:
        return np.zeros(1, dtype=np.float32)
    return np.concatenate(chunks)


reply({"ready": True})
print("[kokoro-synth] ready", file=sys.stderr, flush=True)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    rid = req.get("id")
    try:
        voice = req.get("voice") or os.environ.get("KOKORO_VOICE", "af_heart")
        if req.get("check_voice"):
            # Actually synthesize with it: loading is the only honest test that a
            # voice exists, and it is what stops a typo from muting the engine.
            synth("Voice check.", 1.0, req["check_voice"])
            reply({"id": rid, "ok": True})
            continue
        audio = synth(req.get("text") or "", float(req.get("speed") or 1.0), voice)
        sf.write(req["out"], audio, SR, format="WAV")
        reply({"id": rid, "ok": True})
    except Exception as e:  # noqa: BLE001 — never die on one bad request
        print(f"[kokoro-synth] error: {e}", file=sys.stderr, flush=True)
        reply({"id": rid, "ok": False, "error": str(e)})
