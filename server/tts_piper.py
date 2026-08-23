#!/usr/bin/env python3
"""Local neural TTS wrapper: Piper (zh_CN) -> 16 kHz mono PCM16 WAV.

Reads text from stdin, synthesizes with Piper (fully offline), resamples the
raw 22050 Hz mono PCM down to 16 kHz mono, and writes a WAV file to the path
given as argv[1]. Drop-in replacement for /usr/bin/say with the same
16k mono PCM16 contract the server already consumes.
"""
import sys
import os
import json
import wave
import subprocess
import array

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.environ.get("PIPER_MODEL", os.path.join(HERE, "hud", "tts", "zh_CN-huayan-medium.onnx"))
CONFIG = os.environ.get("PIPER_CONFIG", os.path.join(HERE, "hud", "tts", "zh_CN-huayan-medium.onnx.json"))
TARGET_SR = 16000


def model_sample_rate(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            d = json.load(f)
        return int(d.get("audio", {}).get("sample_rate", TARGET_SR))
    except Exception:
        return TARGET_SR


def resample_16k_mono(raw_bytes, src_sr):
    n = len(raw_bytes) // 2
    src = array.array("h")
    src.frombytes(raw_bytes)
    if n == 0:
        return src
    if src_sr == TARGET_SR:
        return src
    out_len = int(round(n * TARGET_SR / src_sr))
    out = array.array("h", [0]) * out_len
    for i in range(out_len):
        pos = i * src_sr / TARGET_SR
        i0 = int(pos)
        i1 = i0 + 1 if i0 + 1 < n else n - 1
        frac = pos - i0
        a = src[i0]
        b = src[i1]
        out[i] = int(a + (b - a) * frac)
    return out


def _write_empty(out_path):
    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_SR)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: tts_piper.py <output_wav>\n")
        sys.exit(2)
    out_path = sys.argv[1]
    text = sys.stdin.read().strip()
    if not text:
        _write_empty(out_path)
        return
    src_sr = model_sample_rate(CONFIG)
    proc = subprocess.run(
        [sys.executable, "-m", "piper", "--model", MODEL, "--output-raw"],
        input=text.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        sys.stderr.write("piper error: " + proc.stderr.decode("utf-8", "replace") + "\n")
        _write_empty(out_path)
        return
    resampled = resample_16k_mono(proc.stdout, src_sr)
    with wave.open(out_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(TARGET_SR)
        wf.writeframes(resampled.tobytes())


if __name__ == "__main__":
    main()
