#!/bin/bash
# Stop the full Jarvis stack locally.
U=gui/$(id -u)
# 1) API brain (hermes-managed service)
/Users/xiaota/.hermes/hermes-agent/venv/bin/hermes gateway stop 2>/dev/null || true
# 2) backend + voice (launchd)
for s in com.jarvis.voice com.jarvis.dashboard; do launchctl bootout $U/$s 2>/dev/null; done
sleep 2
# kill anything still holding our ports (catches orphaned STT children whose
# cmdline doesn't contain "server.py")
for port in 443 8642 8765 8766 9119 9443; do
  lsof -ti tcp:$port -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null
done
pkill -9 -if "server\.py" 2>/dev/null
echo "stopped (ports cleared)"
