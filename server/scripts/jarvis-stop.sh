#!/bin/bash
# Stop the full Jarvis stack locally.
U=gui/$(id -u)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 1) API brain (hermes-managed service)
/Users/xiaota/.hermes/hermes-agent/venv/bin/hermes gateway stop 2>/dev/null || true
# 2) backend + voice (launchd)
for s in com.jarvis.voice com.jarvis.dashboard; do launchctl bootout $U/$s 2>/dev/null; done
sleep 2
# Kill only OUR processes: match server.py under this repo, not any other
# project's foo/server.py. TERM first (graceful: lets STT children exit),
# KILL only after a short grace period. Port 443 removed — too easy to hit
# an unrelated service; orphans on jarvis ports are caught below by cwd match.
pkill -TERM -f "$REPO_ROOT.*server\.py" 2>/dev/null
sleep 3
pkill -9 -f "$REPO_ROOT.*server\.py" 2>/dev/null
for port in 8642 8765 8766 9119 9443; do
  for pid in $(lsof -ti tcp:$port -sTCP:LISTEN 2>/dev/null); do
    # only kill if the listener's cwd is inside this repo (orphaned STT children etc.)
    if lsof -p "$pid" 2>/dev/null | grep -q " $REPO_ROOT"; then
      kill -9 "$pid" 2>/dev/null
    fi
  done
done
echo "stopped (ports cleared, repo-scoped)"
