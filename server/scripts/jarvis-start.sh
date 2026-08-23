#!/bin/bash
# Start the full Jarvis stack locally.
#  - Hermes gateway (API brain, 8642)  -> managed by hermes itself
#  - Hermes serve backend (9119)       -> launchd (com.jarvis.dashboard)
#  - Voice pipeline + HUD (8765/8766)   -> launchd (com.jarvis.voice)
U=gui/$(id -u)
# 1) API brain (install first if not already a service)
/Users/xiaota/.hermes/hermes-agent/venv/bin/hermes gateway start 2>/dev/null \
  || /Users/xiaota/.hermes/hermes-agent/venv/bin/hermes gateway install 2>/dev/null \
  || true
# 2) backend + voice (idempotent: bootstrap once, then kickstart)
for s in com.jarvis.dashboard com.jarvis.voice; do
  launchctl bootstrap $U ~/Library/LaunchAgents/$s.plist 2>/dev/null || launchctl kickstart $U/$s
done
echo "started (voice server warms its STT model for ~40s)"
