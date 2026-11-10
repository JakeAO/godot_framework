#!/usr/bin/env python3
"""Generates the prototype's placeholder WAV assets (16-bit mono PCM, 22050 Hz).

Re-run any time the audio placeholders need to be regenerated:
    python3 tools/generate_audio.py
"""

import math
import os
import struct
import wave

SR = 22050
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")


def write_wav(filename, samples):
    path = os.path.normpath(os.path.join(OUT_DIR, filename))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(
            struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples
        )
        w.writeframes(frames)
    print("wrote", path)


def tone(duration_sec, freq_fn, amp=0.5, decay=8.0, attack_sec=0.004):
    n = int(duration_sec * SR)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SR
        f = freq_fn(t)
        phase += 2.0 * math.pi * f / SR
        env = min(1.0, t / max(attack_sec, 1e-6)) * math.exp(-decay * t)
        out.append(amp * env * math.sin(phase))
    return out


def sfx_click():
    write_wav("sfx_click.wav", tone(0.08, lambda t: 880.0, amp=0.5, decay=40.0))


def sfx_success():
    write_wav(
        "sfx_success.wav",
        tone(0.30, lambda t: 660.0 + (990.0 - 660.0) * (t / 0.30), amp=0.5, decay=6.0),
    )


def sfx_fail():
    write_wav(
        "sfx_fail.wav",
        tone(0.40, lambda t: 220.0 + (110.0 - 220.0) * (t / 0.40), amp=0.5, decay=4.0),
    )


def bgm_menu():
    # 8s seamless-ish loop: 16 notes x 0.5s, C-major pentatonic arpeggio.
    note_freqs = [523.25, 659.25, 784.0, 880.0, 1046.5, 880.0, 784.0, 659.25] * 2
    note_sec = 0.5
    out = []
    for f in note_freqs:
        n = int(note_sec * SR)
        for i in range(n):
            t = i / SR
            env = math.exp(-3.0 * t) * (
                1.0 - t / note_sec
            )  # decay + fade to 0 at note end
            out.append(0.18 * env * math.sin(2.0 * math.pi * f * t))
    write_wav("bgm_menu.wav", out)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    sfx_click()
    sfx_success()
    sfx_fail()
    bgm_menu()


if __name__ == "__main__":
    main()
