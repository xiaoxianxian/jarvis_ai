#!/usr/bin/env bash
# Full verification suite for jarvis-ai.
# Usage: scripts/jarvis-full-test.sh   (server must be running, or pass --start)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"   # repo root (script lives in server/scripts/)
cd "$REPO_ROOT" || exit 2
PASS=0; FAIL=0
ok(){ printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)); }
bad(){ printf "  ✗ %s\n" "$1"; FAIL=$((FAIL+1)); }
section(){ printf "\n== %s ==\n" "$1"; }

# optional: start a temporary server if none is listening
STARTED=0
if ! lsof -t -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  if [ "${1:-}" = "--start" ]; then
    echo "(starting server for tests...)"
    (cd server && nohup .venv/bin/python server.py >/tmp/jarvis_fulltest.log 2>&1 &)
    STARTED=1
    for i in $(seq 1 30); do lsof -t -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 1; done
  else
    echo "server not running on :8765 — run with --start"; exit 2
  fi
fi

TOKEN=$(grep '^JARVIS_HUD_TOKEN=' ~/.hermes/.env | cut -d= -f2-)
if [ -z "$TOKEN" ]; then
  bad "JARVIS_HUD_TOKEN missing from ~/.hermes/.env — auth tests would be fake-green"
fi

section "1. Static checks"
python3 -m py_compile server/server.py worker/stt_server.py worker/worker_stats.py server/scripts/ws_e2e_test.py \
  && ok "py_compile" || bad "py_compile"
bash -n server/scripts/*.sh && ok "bash -n" || bad "bash -n"
python3 -c "import yaml,sys; yaml.safe_load(open('server/config/server.example.yaml'))" \
  && ok "yaml parse" || bad "yaml parse"

section "2. Service health"
# -f: any HTTP error status (500/404/502) must fail, not just connection errors.
# :9443 root is expected to answer 401 (auth-gated dashboard proxy) — that IS healthy;
# section 3 asserts the 401 explicitly. Here we only require "TLS listener alive".
c=$(curl -sk -m 3 -o /dev/null -w '%{http_code}' https://127.0.0.1:9443/)
case "$c" in 200|401) ok "dash proxy :9443";; *) bad "dash proxy :9443 -> $c";; esac
c=$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/)
[ "$c" = "200" ] && ok "dashboard :9119" || bad "dashboard :9119 -> $c"
curl -sf -m 5 http://127.0.0.1:8642/health | grep -q ok && ok "hermes api :8642" || bad "hermes api :8642"

section "3. Auth matrix"
c=$(curl -sk -o /dev/null -w '%{http_code}' -X POST https://127.0.0.1:8766/api/chat -H 'Content-Type: application/json' -d '{}')
[ "$c" = "401" ] && ok "chat without token -> 401" || bad "chat without token -> $c"
c=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8766/api/usage)
[ "$c" = "200" ] && ok "public /api/usage -> 200" || bad "public /api/usage -> $c"
c=$(curl -sk -o /dev/null -w '%{http_code}' -H "X-Jarvis-Token: $TOKEN" https://127.0.0.1:8766/api/hermes/v1/skills)
[ "$c" = "200" ] && ok "hermes proxy with token -> 200" || bad "hermes proxy with token -> $c"
c=$(curl -sk --path-as-is -o /dev/null -w '%{http_code}' -H "X-Jarvis-Token: $TOKEN" "https://127.0.0.1:8766/api/hermes/api/sessions/x/../../../admin/messages")
[ "$c" = "403" ] && ok "path traversal blocked -> 403" || bad "path traversal -> $c"
c=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:9443/)
[ "$c" = "401" ] && ok "dashboard proxy without token -> 401" || bad "dashboard proxy noauth -> $c"
hdr=$(curl -sk -D- -o /dev/null -H "Cookie: jarvis_token=$TOKEN" https://127.0.0.1:9443/ | grep -ci 'frame-ancestors')
[ "$hdr" -ge 1 ] && ok "CSP frame-ancestors present" || bad "CSP frame-ancestors missing"

section "4. WebSocket auth + negative events"
# Single scored run (the old unscored duplicate was pure drift risk).
if [ -z "$TOKEN" ]; then
  bad "WS-LOOPBACK (skipped: no token)"; bad "WS-TOKEN-OK (skipped)"; bad "WS-BAD-TOKEN (skipped)"
  bad "WS-MALFORMED (skipped)"; bad "WS-STOP-BEFORE-START (skipped)"
else
while read -r name res; do
  case "$name" in
    WS-BAD-TOKEN) [ "$res" = blocked ] && ok "$name" || bad "$name=$res";;
    *) [ "$res" = ok ] && ok "$name" || bad "$name=$res";;
  esac
done < <(server/.venv/bin/python - <<'EOF' 2>/dev/null || echo "WS-SUITE crash fail"
import asyncio, sys, json, os
sys.path.insert(0,'server'); import websockets
TOK=[l.split('=',1)[1] for l in open(os.path.expanduser('~/.hermes/.env')) if l.startswith('JARVIS_HUD_TOKEN=')][0]
async def main():
    async def conn(url, headers=None):
        try:
            async with websockets.connect(url, additional_headers=headers or {}, open_timeout=5) as ws:
                await asyncio.wait_for(ws.recv(), timeout=5); return True
        except Exception: return False
    print('WS-LOOPBACK', 'ok' if await conn('ws://127.0.0.1:8765/ws') else 'fail')
    print('WS-TOKEN-OK', 'ok' if await conn(f'ws://127.0.0.1:8765/ws?token={TOK}', {'Origin':'https://jarvis.local'}) else 'fail')
    print('WS-BAD-TOKEN', 'blocked' if not await conn('ws://127.0.0.1:8765/ws?token=wrong', {'Origin':'https://jarvis.local'}) else 'LEAK')
    async with websockets.connect('ws://127.0.0.1:8765/ws') as ws:
        await ws.recv(); await ws.send('{broken')
        ev=json.loads(await asyncio.wait_for(ws.recv(), timeout=5)); print('WS-MALFORMED', 'ok' if ev.get('type')=='error' else 'fail')
        await ws.send(json.dumps({'type':'stop'}))
        ev=json.loads(await asyncio.wait_for(ws.recv(), timeout=5)); print('WS-STOP-BEFORE-START', 'ok' if ev.get('type')=='error' else 'fail')
asyncio.run(main())
EOF
)
fi

section "5. HUD assets"
for f in "" assets/jarvis-character.png models/helmet.glb vendor/three.module.js; do
  c=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:8766/hud/$f")
  [ "$c" = "200" ] && ok "hud/$f" || bad "hud/$f -> $c"
done

section "6. End-to-end voice turn (STT→Hermes→TTS)"
# use the real /usr/bin/say — ~/.local/bin/say is a JARVIS guard stub that no-ops
/usr/bin/say -o /tmp/jarvis_smoke.wav --data-format=LEI16@16000 "你好，请只回复两个字：收到" 2>/dev/null
if server/.venv/bin/python server/scripts/ws_e2e_test.py /tmp/jarvis_smoke.wav jarvis-debug >/tmp/jarvis_e2e.out 2>&1; then
  ok "e2e voice turn (see /tmp/jarvis_e2e.out)"
  grep -m1 'RESPONSE:' /tmp/jarvis_e2e.out | head -c 120; echo
else
  bad "e2e voice turn failed"
  tail -5 /tmp/jarvis_e2e.out
fi

section "RESULT"
echo "PASS=$PASS FAIL=$FAIL"
[ "$STARTED" = 1 ] && kill $(lsof -t -iTCP:8765 -sTCP:LISTEN) 2>/dev/null && echo "(temp server stopped)"
[ "$FAIL" = 0 ]
