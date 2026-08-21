#!/usr/bin/env bash
# Stop the Kokoro TTS server.
DIR="$HOME/.aloud"
pkill -f "$DIR/server.py" 2>/dev/null && echo "aloud stopped" || echo "aloud was not running"
# The supervisor SIGTERMs its worker on the way out, but reap any orphan too —
# that one holds the ~1.2GB, so a stray copy defeats the point of stopping.
pkill -f "$DIR/synth.py" 2>/dev/null && echo "aloud synth worker stopped"
rm -f "$DIR/server.pid"
