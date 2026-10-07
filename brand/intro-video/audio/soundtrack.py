#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "scipy", "soundfile"]
# ///
"""Render the intro soundtrack: the score plus every SFX cue the animation exported, mixed and mastered.

    uv run audio/soundtrack.py --cues build/cues.json --duration 42 --out build/soundtrack.wav

cues.json is a list of {"t": seconds, "name": sfx id, "gain": dB (optional)}. Repeated cues rotate through the
recipe's variants. Prints loudness and peak for the music bed, each SFX and the final mix; --review writes waveform
and spectrogram PNGs (needs ffmpeg).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import numpy as np  # noqa: E402

import score  # noqa: E402
from core import (SR, db_to_amp, fade, limit, lufs_integrated, lufs_momentary_max, mix_into, peak_db,  # noqa: E402
                  remove_dc, samples, to_stereo, write_wav)
from mixer import render  # noqa: E402
from sfx import REGISTRY  # noqa: E402

MUSIC_LUFS = -19.0  # bed level before the SFX go on top
MASTER_LUFS = -16.0  # web video target (platforms normalise around -14 to -16)
CEILING_DB = -1.0


def level_sfx(x: np.ndarray, loudness: float) -> np.ndarray:
    """Stereo, DC-free, at the cue's max momentary loudness, peaks under -3 dBFS."""
    y = remove_dc(to_stereo(x))
    current = lufs_momentary_max(y)
    if current > -100:
        y = y * db_to_amp(loudness - current)
    return limit(y, -3.0, circular=False)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cues", type=Path, required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--review", type=Path)
    args = ap.parse_args()

    n = samples(args.duration)
    music = render(score.compose(), tail=4.0, target_lufs=MUSIC_LUFS, reverb_params={"room": 0.82, "damp": 0.45})
    music = fade(np.pad(music, ((0, max(0, n - len(music))), (0, 0)))[:n], 0.0, 1.2)
    print(f"music   {lufs_integrated(music):6.1f} LUFS  peak {peak_db(music):5.1f} dBFS  {len(music) / SR:5.2f} s")

    cues = json.loads(args.cues.read_text())
    rendered: dict[str, list[np.ndarray]] = {}
    used: dict[str, int] = {}
    mix = music.copy()
    for cue in sorted(cues, key=lambda c: c["t"]):
        spec = REGISTRY[cue["name"]]
        if spec.name not in rendered:
            rendered[spec.name] = [level_sfx(spec.fn(variant=v) if spec.variants > 1 else spec.fn(), spec.loudness)
                                   for v in range(spec.variants)]
            first = rendered[spec.name][0]
            print(f"sfx {spec.name:<9} {lufs_momentary_max(first):6.1f} LUFS max  {len(first) / SR:4.2f} s"
                  f"  x{spec.variants}")
        i = used.get(spec.name, 0)
        used[spec.name] = i + 1
        mix_into(mix, rendered[spec.name][i % spec.variants], samples(cue["t"]), db_to_amp(cue.get("gain", 0.0)))

    for _ in range(4):
        mix = limit(mix * db_to_amp(MASTER_LUFS - lufs_integrated(mix)), CEILING_DB, circular=False)
        if abs(lufs_integrated(mix) - MASTER_LUFS) < 0.15:
            break
    mix = fade(mix, 0.02, 0.6)
    write_wav(args.out, mix)
    counts = ", ".join(f"{k} {v}" for k, v in sorted(used.items()))
    print(f"mix     {lufs_integrated(mix):6.1f} LUFS  peak {peak_db(mix):5.1f} dBFS  cues: {counts}")

    if args.review:
        args.review.mkdir(parents=True, exist_ok=True)
        for name, graph in (("waveform", "showwavespic=s=2400x400:split_channels=1"),
                            ("spectrogram", "showspectrumpic=s=2400x600:legend=1")):
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(args.out), "-lavfi", graph,
                            str(args.review / f"{name}.png")], check=True)
        print(f"review  {args.review}/waveform.png, spectrogram.png")


if __name__ == "__main__":
    main()
