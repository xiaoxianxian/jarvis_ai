#!/bin/bash
# Generate the boot greeting audio.
# Usage: make-boot-audio.sh [Name]
#   Optional first argument is spoken in the greeting ("Good morning, <Name>.").
#   Omit it for the default "老板" (boss).
# Primary : FREE natural Chinese neural TTS via Microsoft edge-tts (tts_edge.py,
#           default voice zh-CN-YunyangNeural) -- a steady male neural voice,
#           no robotic feel.
# Fallback : if the network/edge call fails, fall back to the offline Piper voice
#           (tts_piper.py) so the greeting is always produced.
#
# Output: hud/audio/boot_{morning,afternoon,evening}.wav (16 kHz mono PCM16).
#
# IMPORTANT: pass Chinese text as literal printf args (not $variables) to
# avoid bash mojibake.
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
cd "$(dirname "$0")/.."
mkdir -p hud/audio
PY=".venv/bin/python"
EDGE="tts_edge.py"
PIPER="tts_piper.py"

gen() {
  # $1 = out path; Chinese text is read from stdin (literal printf).
  out="$1"
  "$PY" "$EDGE" "$out"
  sz=$(stat -f%z "$out" 2>/dev/null || echo 0)
  if [ "$sz" -lt 200 ]; then
    echo "  edge-tts failed (sz=$sz), falling back to Piper" >&2
    "$PY" "$PIPER" "$out"
  fi
}

NAME="${1:-老板}"

printf "系统已上线，早上好，%s。" "$NAME" | gen "hud/audio/boot_morning.wav"
printf "系统已上线，下午好，%s。" "$NAME" | gen "hud/audio/boot_afternoon.wav"
printf "系统已上线，晚上好，%s。" "$NAME" | gen "hud/audio/boot_evening.wav"
ls -la hud/audio/
