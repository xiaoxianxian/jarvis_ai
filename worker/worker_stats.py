#!/usr/bin/env python3
"""Tiny stats agent for a GPU render/worker machine.

Serves JSON at http://127.0.0.1:8767/stats for the Jarvis HUD machines panel
(set JARVIS_WORKER_BIND=0.0.0.0 to expose on the LAN).

Setup on the worker (once):
    pip install psutil
    python worker_stats.py
(Optionally register as a scheduled task / startup item.)

Requires nvidia-smi on PATH for GPU stats (ships with NVIDIA drivers).
"""
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import psutil
except ImportError:
    psutil = None

PORT = 8767
# default to loopback only; set JARVIS_WORKER_BIND=0.0.0.0 to expose on the LAN
BIND_HOST = os.environ.get("JARVIS_WORKER_BIND", "127.0.0.1")


def gpu_stats() -> dict:
    try:
        out = subprocess.check_output(
            ["nvidia-smi",
             "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            timeout=4, text=True,
        ).strip().splitlines()[0]
        util, used, total, temp = [x.strip() for x in out.split(",")]
        return {
            "gpu_util": float(util),
            "vram_used": round(float(used) / 1024, 1),
            "vram_total": round(float(total) / 1024, 1),
            "gpu_temp": int(float(temp)),
        }
    except Exception:
        return {}


def stats() -> dict:
    s = {"name": os.environ.get("JARVIS_WORKER_NAME", "GPU WORKER"), "online": True}
    if psutil:
        s["cpu"] = psutil.cpu_percent(interval=0.2)
        s["mem"] = psutil.virtual_memory().percent
    s.update(gpu_stats())
    return s


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/stats":
            self.send_response(404); self.end_headers(); return
        body = json.dumps(stats()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # quiet
        pass


if __name__ == "__main__":
    print(f"Jarvis worker stats agent on http://{BIND_HOST}:{PORT}/stats")
    HTTPServer((BIND_HOST, PORT), Handler).serve_forever()
