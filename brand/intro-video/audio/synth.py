"""Oscillators and envelopes.

Every oscillator accepts a scalar frequency or a per-sample frequency array (for glides, vibrato and FM),
and returns a mono float64 array. Saw, square and pulse are band-limited with PolyBLEP.
"""

from __future__ import annotations

import numpy as np
from scipy import signal

from core import SR, samples

# Deterministic randomness: every generator derives its stream from an explicit seed.


def rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


# ---------------------------------------------------------------- phase


def _freq_array(freq, n: int) -> np.ndarray:
    return np.broadcast_to(np.asarray(freq, dtype=np.float64), (n,)).astype(np.float64)


def phase(freq, n: int, phase0: float = 0.0) -> tuple[np.ndarray, np.ndarray]:
    """Returns (phase in [0, 1), per-sample increment)."""
    inc = _freq_array(freq, n) / SR
    ph = np.cumsum(inc) - inc + phase0
    return np.mod(ph, 1.0), inc


def _polyblep(t: np.ndarray, dt: np.ndarray) -> np.ndarray:
    out = np.zeros_like(t)
    dt = np.maximum(dt, 1e-9)
    lo = t < dt
    x = t[lo] / dt[lo]
    out[lo] = x + x - x * x - 1.0
    hi = t > 1.0 - dt
    x = (t[hi] - 1.0) / dt[hi]
    out[hi] = x * x + x + x + 1.0
    return out


# ---------------------------------------------------------------- oscillators


def sine(freq, n: int, phase0: float = 0.0) -> np.ndarray:
    ph, _ = phase(freq, n, phase0)
    return np.sin(2 * np.pi * ph)


def saw(freq, n: int, phase0: float = 0.0) -> np.ndarray:
    t, dt = phase(freq, n, phase0)
    return 2.0 * t - 1.0 - _polyblep(t, dt)


def pulse(freq, n: int, width=0.5, phase0: float = 0.0) -> np.ndarray:
    """Band-limited pulse; width may be an array for PWM."""
    t, dt = phase(freq, n, phase0)
    w = np.clip(np.broadcast_to(np.asarray(width, dtype=np.float64), (n,)), 0.02, 0.98)
    naive = np.where(t < w, 1.0, -1.0)
    out = naive + _polyblep(t, dt) - _polyblep(np.mod(t + 1.0 - w, 1.0), dt)
    # Remove the DC component of asymmetric pulses.
    return out - (2.0 * w - 1.0)


def square(freq, n: int, phase0: float = 0.0) -> np.ndarray:
    return pulse(freq, n, 0.5, phase0)


def triangle(freq, n: int, phase0: float = 0.0) -> np.ndarray:
    t, _ = phase(freq, n, phase0 + 0.25)
    return 2.0 * np.abs(2.0 * t - 1.0) - 1.0


def fm(freq, n: int, ratio: float = 1.0, index=1.0, feedback: float = 0.0, phase0: float = 0.0) -> np.ndarray:
    """Two-operator phase modulation (DX style). index may be an envelope array."""
    fc = _freq_array(freq, n)
    mod_ph, _ = phase(fc * ratio, n)
    mod = np.sin(2 * np.pi * mod_ph)
    if feedback:
        mod = np.sin(2 * np.pi * mod_ph + feedback * mod)
    car_ph, _ = phase(fc, n, phase0)
    return np.sin(2 * np.pi * car_ph + np.asarray(index) * mod)


def supersaw(freq, n: int, voices: int = 7, detune_cents: float = 18.0, seed: int = 0) -> np.ndarray:
    r = rng(seed)
    fc = _freq_array(freq, n)
    out = np.zeros(n)
    spread = np.linspace(-1.0, 1.0, voices) if voices > 1 else np.zeros(1)
    for i, s in enumerate(spread):
        gain = 1.0 if abs(s) < 1e-9 else 0.75
        out += gain * saw(fc * 2 ** (s * detune_cents / 1200.0), n, r.random())
    return out / np.sqrt(voices)


def noise(n: int, seed: int = 0, color: str = "white") -> np.ndarray:
    r = rng(seed)
    w = r.uniform(-1.0, 1.0, n)
    if color == "white":
        return w
    if color == "pink":
        # Paul Kellet's economy pink filter (approximation, -3 dB/oct).
        b = [0.049922035, -0.095993537, 0.050612699, -0.004408786]
        a = [1.0, -2.494956002, 2.017265875, -0.522189400]
        y = signal.lfilter(b, a, w)
        return y / (np.abs(y).max() + 1e-12)
    if color == "brown":
        y = signal.lfilter([1.0], [1.0, -0.995], w)
        y -= y.mean()
        return y / (np.abs(y).max() + 1e-12)
    raise ValueError(color)


def metallic(n: int, base: float = 1.0, seed: int = 0) -> np.ndarray:
    """Six detuned square waves at inharmonic ratios (808-style cymbal source)."""
    freqs = np.array([205.3, 304.4, 369.6, 522.7, 540.0, 800.0]) * base
    r = rng(seed)
    return sum(square(f, n, r.random()) for f in freqs) / 6.0


# ---------------------------------------------------------------- envelopes


def adsr(n: int, attack: float = 0.005, decay: float = 0.1, sustain: float = 0.7, release: float = 0.1,
         gate: float | None = None, curve: float = 4.0) -> np.ndarray:
    """ADSR with exponential decay/release. gate = held time in seconds (default: n minus release)."""
    a = max(1, samples(attack))
    gate_n = samples(gate) if gate is not None else max(a, n - samples(release))
    t = np.arange(n, dtype=np.float64)
    env = np.empty(n)
    # attack: slightly convex ramp
    att = np.minimum(t / a, 1.0)
    env[:] = 1.0 - (1.0 - att) ** 2
    d = max(1, samples(decay))
    after = t >= a
    env[after] = sustain + (1.0 - sustain) * np.exp(-curve * (t[after] - a) / d)
    # value reached at gate end
    gi = min(gate_n, n - 1)
    level = env[gi] if n else 0.0
    if gate_n < n:
        r = max(1, samples(release))
        tt = t[gate_n:] - gate_n
        env[gate_n:] = level * np.exp(-curve * tt / r)
        # force exact zero at the end of the release window to avoid residual steps
        env[gate_n:] *= np.clip(1.0 - tt / (r * 1.5), 0.0, 1.0) ** 0.5
    return env


def exp_decay(n: int, t60: float, attack: float = 0.001) -> np.ndarray:
    """Exponential decay reaching -60 dB after t60 seconds, with a short linear attack."""
    t = np.arange(n) / SR
    env = np.exp(-6.9078 * t / max(t60, 1e-4))
    a = max(1, samples(attack))
    env[:a] *= np.linspace(0.0, 1.0, a, endpoint=False) if a > 1 else 1.0
    return env


def glide(f0: float, f1: float, n: int, time: float, curve: str = "exp") -> np.ndarray:
    """Frequency array moving from f0 to f1 over `time` seconds, then holding f1."""
    k = max(1, min(n, samples(time)))
    x = np.linspace(0.0, 1.0, k)
    if curve == "exp":
        seg = f0 * (f1 / f0) ** x
    else:
        seg = f0 + (f1 - f0) * x
    return np.concatenate([seg, np.full(n - k, f1)])


def pitch_drop(f_start: float, f_end: float, n: int, tau: float) -> np.ndarray:
    """Exponential approach from f_start to f_end with time constant tau (kick/tom bodies)."""
    t = np.arange(n) / SR
    return f_end + (f_start - f_end) * np.exp(-t / tau)


def vibrato(n: int, rate: float = 5.5, depth_cents: float = 15.0, delay: float = 0.15,
            fade_time: float = 0.2) -> np.ndarray:
    """Pitch multiplier array with a delayed, faded-in vibrato."""
    t = np.arange(n) / SR
    amt = np.clip((t - delay) / max(fade_time, 1e-3), 0.0, 1.0)
    return 2 ** (amt * depth_cents * np.sin(2 * np.pi * rate * t) / 1200.0)


def lfo(n: int, rate: float, shape: str = "sine", phase0: float = 0.0) -> np.ndarray:
    t = np.arange(n) / SR * rate + phase0
    if shape == "sine":
        return np.sin(2 * np.pi * t)
    if shape == "tri":
        return 2 * np.abs(2 * np.mod(t, 1.0) - 1) - 1
    if shape == "square":
        return np.where(np.mod(t, 1.0) < 0.5, 1.0, -1.0)
    if shape == "saw":
        return 2 * np.mod(t, 1.0) - 1
    raise ValueError(shape)


def line(points: list[tuple[float, float]], n: int, curve: str = "lin") -> np.ndarray:
    """Breakpoint envelope: points are (time_seconds, value). curve='exp' interpolates in log domain."""
    t = np.arange(n) / SR
    xs = np.array([p[0] for p in points])
    ys = np.array([p[1] for p in points], dtype=np.float64)
    if curve == "exp":
        return np.exp(np.interp(t, xs, np.log(np.maximum(ys, 1e-9))))
    return np.interp(t, xs, ys)
