#!/usr/bin/env python3
"""Local natural Chinese TTS via Microsoft edge-tts (free neural voices).

Reads text from stdin, synthesizes with edge-tts, decodes the MP3 to a
16 kHz mono PCM16 WAV (the same contract server.py expects from
tts_piper.py), and writes it to the path given as argv[1].

No ffmpeg needed: miniaudio decodes + resamples the MP3 internally.
On any failure it writes an (empty) valid WAV and exits non-zero so the
caller (server.py) can fall back to the offline Piper voice.

Voice is configurable via EDGE_TTS_VOICE (default zh-CN-YunyangNeural, a steady male voice).
"""
import sys, os, asyncio, tempfile, wave

import miniaudio
import edge_tts

VOICE = os.environ.get("EDGE_TTS_VOICE", "zh-CN-YunyangNeural")


def _synth_mp3(text: str, mp3_path: str):
    async def run():
        comm = edge_tts.Communicate(text=text, voice=VOICE)
        await comm.save(mp3_path)
    asyncio.run(run())


def synth_to_wav(text: str, out_path: str):
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tf:
        mp3_path = tf.name
    try:
        _synth_mp3(text, mp3_path)
        with open(mp3_path, "rb") as f:
            mp3 = f.read()
        dec = miniaudio.decode(
            mp3,
            output_format=miniaudio.SampleFormat.SIGNED16,
            nchannels=1,
            sample_rate=16000,
        )
        samples = dec.samples
        if not isinstance(samples, (bytes, bytearray)):
            samples = bytes(samples)
        w = wave.open(out_path, "wb")
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(samples)
        w.close()
    finally:
        try:
            os.unlink(mp3_path)
        except OSError:
            pass


def write_empty(out_path: str):
    w = wave.open(out_path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(16000)
    w.writeframes(b"")
    w.close()


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: tts_edge.py <out.wav>\n")
        sys.exit(2)
    out_path = sys.argv[1]
    text = sys.stdin.read().strip()
    if not text:
        write_empty(out_path)
        sys.exit(0)
    try:
        synth_to_wav(text, out_path)
        sys.exit(0)
    except Exception as e:  # network/edge failure -> let caller fall back
        sys.stderr.write("edge_tts failed: %r\n" % (e,))
        try:
            write_empty(out_path)
        except Exception:
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
