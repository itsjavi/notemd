"""Drum synthesis: kick, snare, clap, hats, ride, crash, toms, shaker, plus transition FX (riser, impact).

Each function returns a mono (or stereo for cymbals) hit at full level; `vel` scales brightness a little as
well as amplitude so ghost notes sound softer rather than just quieter. Results are cached per parameter
set and round-robin variant, which keeps long renders fast and gives subtle hit-to-hit variation.
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np

import fx
import synth
from core import SR, samples, to_stereo


def _variant_seed(name: str, variant: int) -> int:
    return (sum(map(ord, name)) * 7919 + variant * 104729) % (2**31)


@lru_cache(maxsize=None)
def kick(tone: float = 52.0, punch: float = 190.0, decay: float = 0.32, click: float = 0.35, drive_db: float = 6.0,
         sweep_tau: float = 0.028, variant: int = 0) -> np.ndarray:
    n = samples(decay * 1.6 + 0.05)
    f = synth.pitch_drop(punch, tone, n, sweep_tau)
    body = synth.sine(f, n) * synth.exp_decay(n, decay * 1.5, attack=0.0006)
    # second harmonic layer for small speakers
    body += 0.18 * synth.sine(f * 2, n) * synth.exp_decay(n, decay * 0.5)
    nz = synth.noise(n, _variant_seed("kick", variant))
    clk = fx.highpass(nz, 2500) * synth.exp_decay(n, 0.012) * click
    clk += click * 0.6 * synth.sine(1800, n) * synth.exp_decay(n, 0.008)
    out = fx.drive(body + clk, drive_db)
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def snare(tone: float = 190.0, snappy: float = 0.8, decay: float = 0.2, crack: float = 1.0, variant: int = 0) -> np.ndarray:
    n = samples(decay * 2 + 0.05)
    f = synth.pitch_drop(tone * 1.35, tone, n, 0.012)
    body = 0.9 * synth.sine(f, n) * synth.exp_decay(n, 0.12)
    body += 0.45 * synth.sine(f * 1.78, n) * synth.exp_decay(n, 0.07)
    nz = synth.noise(n, _variant_seed("snare", variant))
    wires = fx.bandpass(nz, 5200, 0.6) + 0.5 * fx.highpass(nz, 7000)
    wires = wires * synth.exp_decay(n, decay) * snappy * 2.2
    transient = fx.bandpass(nz, 2200, 1.2) * synth.exp_decay(n, 0.008) * crack * 2.0
    out = fx.drive(body + wires + transient, 4.0)
    out = fx.highpass(out, 90)
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def clap(decay: float = 0.22, tone: float = 1300.0, variant: int = 0) -> np.ndarray:
    n = samples(decay * 2 + 0.06)
    nz = synth.noise(n, _variant_seed("clap", variant))
    t = np.arange(n) / SR
    env = np.zeros(n)
    for i, off in enumerate((0.0, 0.011, 0.023, 0.031)):
        k = t >= off
        env[k] = np.maximum(env[k], (0.85 if i < 3 else 1.0) * np.exp(-(t[k] - off) / (0.006 if i < 3 else decay / 5)))
    out = fx.bandpass(nz, tone, 0.9) * 1.5 + fx.highpass(nz, 3000) * 0.3
    out = out * env
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def hat(open_: bool = False, decay: float | None = None, tone: float = 1.0, variant: int = 0) -> np.ndarray:
    d = decay if decay is not None else (0.32 if open_ else 0.045)
    n = samples(d * 1.8 + 0.02)
    seed = _variant_seed("hat", variant)
    metal = synth.metallic(n, 1.6 * tone, seed)
    nz = synth.noise(n, seed + 1)
    src = fx.bandpass(metal, 9500 * tone, 0.7) * 1.2 + fx.highpass(nz, 8000) * 0.7
    src = fx.highpass(src, 6500, order=2)
    env = synth.exp_decay(n, d, attack=0.0004)
    out = src * env
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def ride(decay: float = 0.9, variant: int = 0) -> np.ndarray:
    n = samples(decay + 0.1)
    seed = _variant_seed("ride", variant)
    metal = synth.metallic(n, 2.3, seed)
    bell = sum(synth.sine(f, n) * w for f, w in ((3120, 0.3), (4710, 0.18), (6530, 0.1)))
    nz = synth.noise(n, seed + 3)
    src = fx.bandpass(metal, 7000, 0.9) + bell * synth.exp_decay(n, 0.35) + 0.4 * fx.highpass(nz, 9000)
    out = fx.highpass(src, 3000) * synth.exp_decay(n, decay, attack=0.0005)
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def crash(decay: float = 1.8, variant: int = 0) -> np.ndarray:
    n = samples(decay + 0.2)
    seed = _variant_seed("crash", variant)
    chans = []
    for c in range(2):
        nz = synth.noise(n, seed + c * 17)
        metal = synth.metallic(n, 2.9 + 0.07 * c, seed + c)
        src = fx.highpass(nz, 4500) * 0.8 + fx.bandpass(metal, 8000, 0.6) * 0.6
        src += fx.bandpass(nz, 1500, 1.0) * 0.25 * synth.exp_decay(n, 0.15)
        env = synth.exp_decay(n, decay, attack=0.001) * (0.6 + 0.4 * synth.exp_decay(n, 0.08))
        chans.append(fx.lowpass(src, 13000) * env)
    out = np.stack(chans, axis=1)
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def tom(freq: float = 110.0, decay: float = 0.35, variant: int = 0) -> np.ndarray:
    n = samples(decay * 1.5 + 0.05)
    f = synth.pitch_drop(freq * 1.6, freq, n, 0.04)
    body = synth.sine(f, n) + 0.25 * synth.sine(f * 1.5, n) * synth.exp_decay(n, decay * 0.4)
    body *= synth.exp_decay(n, decay, attack=0.0008)
    nz = synth.noise(n, _variant_seed("tom", variant))
    hit = fx.bandpass(nz, freq * 6, 1.0) * synth.exp_decay(n, 0.02) * 0.6
    out = fx.drive(body + hit, 4.0)
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def shaker(decay: float = 0.06, variant: int = 0) -> np.ndarray:
    n = samples(decay * 2.5)
    nz = synth.noise(n, _variant_seed("shaker", variant))
    t = np.arange(n) / SR
    env = (1 - np.exp(-t / 0.012)) * np.exp(-t / (decay / 2.5))
    out = fx.bandpass(nz, 7500, 1.2) * env
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def rim(freq: float = 1700.0, variant: int = 0) -> np.ndarray:
    n = samples(0.06)
    nz = synth.noise(n, _variant_seed("rim", variant))
    out = synth.triangle(freq, n) * synth.exp_decay(n, 0.03) + fx.bandpass(nz, 3500, 2) * synth.exp_decay(n, 0.01)
    return out / np.abs(out).max()


# ---------------------------------------------------------------- 8-bit console drums


@lru_cache(maxsize=None)
def chip_noise(decay: float = 0.08, rate: float = 22000.0, metallic: bool = False, variant: int = 0) -> np.ndarray:
    """NES-style noise channel hit: +-1 sample-and-hold noise clocked at `rate` Hz with a 16-step decay.
    Low rates sound like snares/explosions, high rates like hats. metallic=True repeats a 93-step pattern
    (the console's 'short mode' buzz)."""
    n = samples(decay * 2 + 0.01)
    r = synth.rng(_variant_seed("chip_noise", variant))
    hold = max(1, int(round(SR / rate)))
    count = n // hold + 2
    src = np.tile(r.choice([-1.0, 1.0], 93), count // 93 + 1)[:count] if metallic else r.choice([-1.0, 1.0], count)
    src = np.repeat(src, hold)[:n]
    env = np.round(synth.exp_decay(n, decay, attack=0.0005) * 15) / 15
    return src * env


@lru_cache(maxsize=None)
def chip_kick(punch: float = 220.0, tone: float = 55.0, decay: float = 0.12, variant: int = 0) -> np.ndarray:
    """Triangle-channel kick: fast quantised pitch drop."""
    n = samples(decay + 0.01)
    f = synth.pitch_drop(punch, tone, n, 0.02)
    tri = np.round(synth.triangle(f, n) * 7.5) / 7.5
    return tri * np.clip(1 - np.arange(n) / n, 0, 1) ** 0.5


@lru_cache(maxsize=None)
def chip_snare(variant: int = 0) -> np.ndarray:
    n = samples(0.14)
    body = chip_kick(400, 180, 0.05, variant)
    out = chip_noise(0.07, 9000.0, False, variant)[:n].copy()
    out[: len(body)] += 0.6 * body[: min(len(body), n)]
    return out / np.abs(out).max()


@lru_cache(maxsize=None)
def chip_hat(open_: bool = False, variant: int = 0) -> np.ndarray:
    return chip_noise(0.12 if open_ else 0.025, 40000.0, False, variant)


# ---------------------------------------------------------------- transitions


def riser(duration: float, f0: float = 300.0, f1: float = 9000.0, seed: int = 0, tonal: float | None = None) -> np.ndarray:
    """Noise sweep that builds into a section. Stereo, returns full-level peak."""
    n = samples(duration)
    t = np.arange(n) / n
    cutoff = f0 * (f1 / f0) ** (t**1.5)
    chans = []
    for c in range(2):
        nz = synth.noise(n, seed + c)
        chans.append(fx.sweep(nz, "bp", cutoff, 2.5))
    out = np.stack(chans, axis=1)
    if tonal:
        f = tonal * 2 ** (2.0 * t**1.3)
        out += 0.25 * to_stereo(synth.supersaw(f, n, 5, 25, seed))
    out *= ((t**2) * (1 - np.exp(-(1 - t) * 60)))[:, None]
    return out / (np.abs(out).max() + 1e-12)


def downlifter(duration: float = 1.5, seed: int = 0) -> np.ndarray:
    n = samples(duration)
    t = np.arange(n) / n
    cutoff = 8000 * (200 / 8000) ** t
    chans = [fx.sweep(synth.noise(n, seed + c), "bp", cutoff, 1.5) for c in range(2)]
    out = np.stack(chans, axis=1) * ((1 - t) ** 2)[:, None]
    return out / (np.abs(out).max() + 1e-12)


def impact(decay: float = 1.2, seed: int = 0) -> np.ndarray:
    """Sub boom + crash-like noise for section downbeats."""
    n = samples(decay + 0.1)
    f = synth.pitch_drop(120, 38, n, 0.08)
    sub = synth.sine(f, n) * synth.exp_decay(n, decay)
    nz = fx.lowpass(synth.noise(n, seed), 3000) * synth.exp_decay(n, decay * 0.4)
    out = to_stereo(fx.drive(sub + 0.3 * nz, 3.0))
    return out / np.abs(out).max()
