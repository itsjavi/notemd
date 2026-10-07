"""Sound effects for the NoteMD intro. Each recipe returns a raw mono or stereo array; soundtrack.py levels it to its
loudness (max momentary LUFS) and places it at the cue times the animation exports.

Register a cue with @sfx(id, loudness, variants=1, notes=""). With variants > 1 the recipe receives variant=0..N-1 and
soundtrack.py rotates through them on repeated cues (round-robin), so typing never repeats the exact same click.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

import fx
import synth
from core import SR, mix_into, pan, samples
from style import STYLE


@dataclass
class SfxSpec:
    name: str
    fn: callable
    loudness: float
    variants: int
    notes: str


REGISTRY: dict[str, SfxSpec] = {}


def sfx(name: str, loudness: float = -18.0, variants: int = 1, notes: str = ""):
    def deco(fn):
        REGISTRY[name] = SfxSpec(name, fn, loudness, variants, notes)
        return fn

    return deco


# ---------------------------------------------------------------- building blocks


def _env(n: int, attack: float, t60: float) -> np.ndarray:
    """Exponential decay that is forced to exactly zero over the last 4 ms (no truncation clicks)."""
    env = synth.exp_decay(n, t60, attack)
    k = min(n, samples(0.004))
    env[n - k :] *= np.linspace(1.0, 0.0, k)
    return env


def _sweep_noise(dur: float, f0: float, f1: float, q: float = 1.5, seed: int = 0, kind: str = "bp",
                 color: str = "white") -> np.ndarray:
    """Noise through a filter swept exponentially from f0 to f1 (unshaped; multiply by an envelope)."""
    n = samples(dur)
    return fx.sweep(synth.noise(n, seed, color), kind, f0 * (f1 / f0) ** np.linspace(0, 1, n), q)


def _place(total: float, parts: list[tuple[float, np.ndarray, float]]) -> np.ndarray:
    """Stereo canvas with (time, signal, pan) parts; stereo parts ignore pan."""
    buf = np.zeros((samples(total), 2))
    for at, sig, p in parts:
        mix_into(buf, sig if sig.ndim == 2 else pan(sig, p), samples(at))
    return buf


def _glass(freq: float, dur: float, t60: float, index: float = 1.2, ratio: float = 3.0) -> np.ndarray:
    """Soft FM glass tone: the bright partials fade much faster than the body."""
    n = samples(dur)
    t = np.arange(n) / SR
    idx = index * np.exp(-t / 0.08) + 0.15
    return synth.fm(freq, n, ratio, idx) * _env(n, 0.002, t60)


# ---------------------------------------------------------------- cues


@sfx("chime", -17, notes="Icon reveal: glass dyad on the home key's root and fifth, with a soft shimmer tail.")
def chime():
    root = _glass(STYLE.tone(1, 6), 2.6, 2.2)
    fifth = _glass(STYLE.tone(5, 6), 2.6, 1.8, index=0.9)
    octave = _glass(STYLE.tone(8, 6), 2.4, 1.4, index=0.6, ratio=2.0) * 0.5
    air = _sweep_noise(1.2, 6000, 9000, q=4.0, seed=3) * _env(samples(1.2), 0.15, 0.9) * 0.05
    body = _place(2.8, [(0.0, root, -0.2), (0.035, fifth, 0.2), (0.07, octave, 0.0), (0.0, air, 0.0)])
    return STYLE.finish(fx.lowpass(body, STYLE.cutoff(9000)))


@sfx("pop", -21, variants=3, notes="Soft UI pop when a label, chip or card appears.")
def pop(variant: int = 0):
    n = samples(0.12)
    f = synth.pitch_drop(STYLE.hz(980 + 60 * variant), STYLE.hz(520), n, 0.05)
    body = synth.sine(f, n) * _env(n, 0.001, 0.09)
    click = fx.highpass(synth.noise(samples(0.006), 11 + variant), 3000) * np.linspace(1, 0, samples(0.006)) * 0.25
    return STYLE.finish(_place(0.13, [(0.0, body, 0.0), (0.0, click, 0.0)]))


@sfx("key", -24, variants=6, notes="Keyboard tap while text is typed; round-robin, slight random pan.")
def key(variant: int = 0):
    r = np.random.default_rng(100 + variant)
    n = samples(0.05)
    click = fx.bandpass(synth.noise(n, 200 + variant), STYLE.cutoff(2600 * (0.85 + 0.3 * r.random())), 1.2)
    click = click * _env(n, 0.0005, 0.025)
    thump = synth.sine(STYLE.hz(170 + 30 * r.random()), n) * _env(n, 0.001, 0.035) * 0.35
    return STYLE.finish(_place(0.055, [(0.0, click + thump, (r.random() - 0.5) * 0.3)]))


@sfx("whoosh", -22, variants=2, notes="Soft air movement for scene transitions; variant 1 sweeps the other way.")
def whoosh(variant: int = 0):
    dur = 0.7
    n = samples(dur)
    f0, f1 = (350, 2800) if variant == 0 else (2400, 300)
    air = _sweep_noise(dur, f0, f1, q=0.9, seed=40 + variant, color="pink")
    shape = np.sin(np.pi * np.linspace(0, 1, n)) ** 2.2
    motion = np.linspace(-0.6, 0.6, n) * (1 if variant == 0 else -1)
    return STYLE.finish(fx.lowpass(pan(air * shape, motion), STYLE.cutoff(5000)))


@sfx("tick", -22, variants=5, notes="Glass tick on a scale degree for list items and highlights; step up the variants.")
def tick(variant: int = 0):
    degree = (1, 3, 5, 6, 8)[variant % 5]
    tone = _glass(STYLE.tone(degree, 6), 0.35, 0.22, index=0.8, ratio=4.0)
    return STYLE.finish(_place(0.36, [(0.0, tone, 0.15 * (variant - 2))]))


@sfx("sparkle", -20, notes="A placeholder turns into its value: quick rising glass arpeggio.")
def sparkle():
    parts = []
    for i, degree in enumerate((3, 5, 8, 10)):
        parts.append((0.045 * i, _glass(STYLE.tone(degree, 6), 0.7, 0.5, index=0.7, ratio=3.5) * (1 - 0.12 * i),
                      -0.3 + 0.2 * i))
    return STYLE.finish(_place(0.9, parts))


@sfx("record", -21, notes="Recorder starts: two soft sine blips a fifth apart.")
def record():
    a = synth.sine(STYLE.tone(5, 5), samples(0.09)) * _env(samples(0.09), 0.003, 0.08)
    b = synth.sine(STYLE.tone(9, 5), samples(0.14)) * _env(samples(0.14), 0.003, 0.12)
    return STYLE.finish(_place(0.25, [(0.0, a, 0.0), (0.09, b, 0.0)]))


@sfx("click", -21, notes="Play button press: tight trackpad click.")
def click():
    n = samples(0.03)
    body = fx.bandpass(synth.noise(n, 77), 1800, 2.0) * _env(n, 0.0003, 0.012)
    low = synth.sine(STYLE.hz(240), n) * _env(n, 0.0005, 0.02) * 0.5
    return STYLE.finish(_place(0.035, [(0.0, body + low, 0.0)]))


@sfx("scribble", -21, notes="A pen strikes a word through: grainy noise with a fast stroke rhythm.")
def scribble():
    dur = 0.42
    n = samples(dur)
    grain = fx.bandpass(synth.noise(n, 91, "pink"), STYLE.cutoff(2200), 0.8)
    strokes = 0.55 + 0.45 * np.sin(2 * np.pi * 9.0 * np.arange(n) / SR) ** 2
    shape = np.minimum(1.0, np.arange(n) / samples(0.03)) * _env(n, 0.001, dur * 1.6)
    return STYLE.finish(pan(grain * strokes * shape, np.linspace(-0.3, 0.3, n)))
