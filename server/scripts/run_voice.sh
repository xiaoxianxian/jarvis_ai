#!/bin/bash
# Launch wrapper for the Jarvis voice pipeline.
# Force a UTF-8 locale so the offline `say` TTS can speak Chinese (launchd's
# default C locale makes `say` reject multibyte text).
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
# Pin the Chinese answer voice to a steady male neural voice. Without this the
# code defaults to the same voice, but pinning it removes any ambiguity and
# guarantees answers never silently drift to a female voice.
export EDGE_TTS_VOICE=zh-CN-YunyangNeural
# Waits (briefly) for the Hermes gateway (API brain) on 8642 so the first
# voice turn never falls back to basic mode just because boot ordering raced.
# Uses absolute paths only — no cd — so it works from launchd on the internal disk.
for i in $(seq 1 60); do
  if curl -sf -m 2 http://127.0.0.1:8642/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
# exec so launchd tracks the python process (correct KeepAlive behaviour)
exec /Users/xiaota/jarvis-ai/server/.venv/bin/python /Users/xiaota/jarvis-ai/server/server.py
