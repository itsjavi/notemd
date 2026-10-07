"""Effects: biquad filters (static and swept), distortion, bitcrush, delay, reverb, chorus, ducking, stereo.

All effects take mono (n,) or stereo (n, 2) arrays unless noted. Feedback structures (combs, delays,
reverb) run block-wise with numpy so long tracks render quickly without per-sample Python loops.
"""

from __future__ import annotations

import numpy as np
from scipy import signal

from core import SR, samples, to_stereo, pan as pan_mono

# ---------------------------------------------------------------- biquads (RBJ cookbook)


def biquad(kind: str, freq: float, q: float = 0.707, gain_db: float = 0.0) -> tuple[np.ndarray, np.ndarray]:
    freq = float(np.clip(freq, 10.0, SR * 0.49))
    w0 = 2 * np.pi * freq / SR
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / (2 * max(q, 1e-3))
    a_ = 10 ** (gain_db / 40)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "bp":  # constant 0 dB peak gain
        b = [alpha, 0.0, -alpha]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "notch":
        b = [1.0, -2 * cw, 1.0]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "peak":
        b = [1 + alpha * a_, -2 * cw, 1 - alpha * a_]
        a = [1 + alpha / a_, -2 * cw, 1 - alpha / a_]
    elif kind in ("lowshelf", "highshelf"):
        sa = 2 * np.sqrt(a_) * alpha
        if kind == "lowshelf":
            b = [a_ * ((a_ + 1) - (a_ - 1) * cw + sa), 2 * a_ * ((a_ - 1) - (a_ + 1) * cw),
                 a_ * ((a_ + 1) - (a_ - 1) * cw - sa)]
            a = [(a_ + 1) + (a_ - 1) * cw + sa, -2 * ((a_ - 1) + (a_ + 1) * cw), (a_ + 1) + (a_ - 1) * cw - sa]
        else:
            b = [a_ * ((a_ + 1) + (a_ - 1) * cw + sa), -2 * a_ * ((a_ - 1) + (a_ + 1) * cw),
                 a_ * ((a_ + 1) + (a_ - 1) * cw - sa)]
            a = [(a_ + 1) - (a_ - 1) * cw + sa, 2 * ((a_ - 1) - (a_ + 1) * cw), (a_ + 1) - (a_ - 1) * cw - sa]
    else:
        raise ValueError(kind)
    b, a = np.array(b), np.array(a)
    return b / a[0], a / a[0]


def filt(x: np.ndarray, kind: str, freq: float, q: float = 0.707, gain_db: float = 0.0, order: int = 1) -> np.ndarray:
    """Static biquad; order>1 cascades identical sections for steeper slopes."""
    b, a = biquad(kind, freq, q, gain_db)
    y = x
    for _ in range(order):
        y = signal.lfilter(b, a, y, axis=0)
    return y


def lowpass(x, freq, q=0.707, order=1):
    return filt(x, "lp", freq, q, order=order)


def highpass(x, freq, q=0.707, order=1):
    return filt(x, "hp", freq, q, order=order)


def bandpass(x, freq, q=1.0, order=1):
    return filt(x, "bp", freq, q, order=order)


def eq(x, kind, freq, gain_db, q=0.707):
    return filt(x, kind, freq, q, gain_db)


def sweep(x: np.ndarray, kind: str, freq, q=0.707, block: int = 32) -> np.ndarray:
    """Time-varying biquad. freq (and q) may be per-sample arrays; coefficients update every `block` samples."""
    n = len(x)
    f = np.broadcast_to(np.asarray(freq, dtype=np.float64), (n,))
    qa = np.broadcast_to(np.asarray(q, dtype=np.float64), (n,))
    y = np.empty_like(x, dtype=np.float64)
    zi = np.zeros((2,) + x.shape[1:])
    for s in range(0, n, block):
        e = min(n, s + block)
        m = (s + e) // 2
        b, a = biquad(kind, f[m], qa[m])
        y[s:e], zi = signal.lfilter(b, a, x[s:e], axis=0, zi=zi)
    return y


def one_pole_lp(x: np.ndarray, freq: float) -> np.ndarray:
    c = np.exp(-2 * np.pi * freq / SR)
    return signal.lfilter([1 - c], [1, -c], x, axis=0)


# ---------------------------------------------------------------- non-linear


def drive(x: np.ndarray, amount_db: float = 6.0, asym: float = 0.0, mix: float = 1.0) -> np.ndarray:
    """tanh saturation, level-compensated so peaks near 1.0 stay near 1.0. asym adds even harmonics."""
    k = 10 ** (amount_db / 20)
    y = np.tanh(k * (x + asym)) - np.tanh(k * asym)
    y /= np.tanh(k) if k > 0 else 1.0
    return mix * y + (1 - mix) * x


def fold(x: np.ndarray, amount: float = 2.0) -> np.ndarray:
    """Sine wavefolder."""
    return np.sin(np.pi / 2 * amount * x)


def bitcrush(x: np.ndarray, bits: float = 8.0, rate: float | None = None) -> np.ndarray:
    y = x
    if rate and rate < SR:
        step = SR / rate
        idx = (np.floor(np.arange(len(x)) / step) * step).astype(int)
        y = y[np.minimum(idx, len(x) - 1)]
    levels = 2 ** (bits - 1)
    return np.round(y * levels) / levels


# ---------------------------------------------------------------- feedback structures


def comb(x: np.ndarray, delay: int, feedback: float, damp: float = 0.0) -> np.ndarray:
    """Feedback comb y[n] = x[n-D] + g * lp(y)[n-D], lp = one-pole with coefficient `damp` (Freeverb style).
    Output is the delayed signal (pure echoes, the dry input is not included). Mono only."""
    n = len(x)
    d = max(1, int(delay))
    v = np.empty(n)
    zi = np.zeros(1)
    lb, la = [1.0 - damp], [1.0, -damp]
    for s in range(0, n, d):
        e = min(n, s + d)
        if s == 0:
            v[s:e] = x[s:e]
            continue
        prev = v[s - d : e - d]
        lp, zi = signal.lfilter(lb, la, prev, zi=zi)
        v[s:e] = x[s:e] + feedback * lp
    return np.concatenate([np.zeros(d), v])[:n]


def allpass(x: np.ndarray, delay: int, g: float = 0.5) -> np.ndarray:
    """Freeverb allpass: out = buf[n-D] - x[n]; buf[n] = x[n] + g * buf[n-D]."""
    return comb(x, delay, g) - x


def delay(x: np.ndarray, time: float, feedback: float = 0.35, mix: float = 0.25, damp: float = 0.3,
          pingpong: bool = True, width: float = 0.8) -> np.ndarray:
    """Tempo delay returning stereo dry+wet. Ping-pong alternates echoes between the sides."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    d = samples(time)
    st = to_stereo(x)
    if not pingpong:
        wet = comb(mono, d, feedback, damp)
        return st + mix * to_stereo(wet)
    # Echo k (k>=1) lands at k*d with gain feedback^(k-1); odd echoes left, even echoes right.
    odd = comb(mono, 2 * d, feedback**2, damp)  # echoes at 2d, 4d... of x -> shift back by d for odd taps
    odd = np.concatenate([odd[d:], np.zeros(d)])
    even = feedback * comb(mono, 2 * d, feedback**2, damp)
    l = odd * (0.5 + width / 2) + even * (0.5 - width / 2)
    r = even * (0.5 + width / 2) + odd * (0.5 - width / 2)
    return st + mix * np.stack([l, r], axis=1)


_FV_COMBS = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
_FV_ALLPASS = [556, 441, 341, 225]


def reverb(x: np.ndarray, room: float = 0.75, damp: float = 0.4, wet: float = 0.3, dry: float = 1.0,
           width: float = 1.0, predelay: float = 0.012, lowcut: float = 200.0, highcut: float = 9000.0) -> np.ndarray:
    """Freeverb (Schroeder-Moorer) stereo reverb. room 0..1 maps to comb feedback 0.7..0.98."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    src = highpass(lowpass(mono, highcut), lowcut) * 0.06
    pd = samples(predelay)
    if pd:
        src = np.concatenate([np.zeros(pd), src])[: len(mono)]
    fb = 0.7 + 0.28 * np.clip(room, 0.0, 1.0)
    outs = []
    scale = SR / 44100.0
    for spread in (0, 23):
        acc = np.zeros(len(mono))
        for c in _FV_COMBS:
            acc += comb(src, int((c + spread) * scale), fb, damp)
        for a in _FV_ALLPASS:
            acc = allpass(acc, int((a + spread) * scale), 0.5)
        outs.append(acc)
    w1 = wet * (width / 2 + 0.5)
    w2 = wet * ((1 - width) / 2)
    l = outs[0] * w1 + outs[1] * w2
    r = outs[1] * w1 + outs[0] * w2
    return dry * to_stereo(x) + np.stack([l, r], axis=1)


def chorus(x: np.ndarray, rate: float = 0.8, depth_ms: float = 3.0, base_ms: float = 12.0, mix: float = 0.5,
           voices: int = 2) -> np.ndarray:
    """Stereo chorus via modulated fractional delay (vectorised interpolation)."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    n = len(mono)
    t = np.arange(n)
    st = to_stereo(x).copy()
    for v in range(voices):
        for ch, ph in ((0, 0.0), (1, 0.25)):
            mod = np.sin(2 * np.pi * (rate * (1 + 0.13 * v) * t / SR + ph + v / voices))
            dl = (base_ms + depth_ms * (1 + mod) / 2) * SR / 1000
            st[:, ch] += mix / voices * np.interp(t - dl, t, mono, left=0.0)
    return st


def flanger(x: np.ndarray, rate: float = 0.3, depth_ms: float = 2.5, feedback_mix: float = 0.6) -> np.ndarray:
    mono = x if x.ndim == 1 else x.mean(axis=1)
    n = len(mono)
    t = np.arange(n)
    dl = (0.3 + depth_ms * (1 + np.sin(2 * np.pi * rate * t / SR)) / 2) * SR / 1000
    return mono + feedback_mix * np.interp(t - dl, t, mono, left=0.0)


# ---------------------------------------------------------------- dynamics and stereo


def duck_envelope(n: int, triggers: list[int], depth: float = 0.5, attack: float = 0.004,
                  release: float = 0.16, period: int | None = None) -> np.ndarray:
    """Sidechain-style gain curve: dips by `depth` at each trigger sample and recovers over `release`.
    With period set, triggers repeat circularly (for seamless loops)."""
    env = np.ones(n)
    a = max(1, samples(attack))
    r = samples(release)
    shape = np.concatenate([np.linspace(0, 1, a, endpoint=False), np.ones(1),
                            1 - (1 - np.linspace(1, 0, r)) ** 2])  # quick dip, eased recovery
    curve = 1.0 - depth * shape
    trig = list(triggers)
    if period:
        trig = trig + [t - period for t in triggers] + [t + period for t in triggers]
    for t0 in trig:
        s = t0 - a
        lo, hi = max(0, s), min(n, s + len(curve))
        if hi > lo:
            env[lo:hi] = np.minimum(env[lo:hi], curve[lo - s : hi - s])
    return env


def width(x: np.ndarray, amount: float = 1.0) -> np.ndarray:
    """Mid/side width: 0 = mono, 1 = unchanged, >1 wider."""
    st = to_stereo(x)
    mid = st.mean(axis=1)
    side = (st[:, 0] - st[:, 1]) / 2 * amount
    return np.stack([mid + side, mid - side], axis=1)


def haas(x: np.ndarray, ms: float = 12.0, side: int = 1) -> np.ndarray:
    mono = x if x.ndim == 1 else x.mean(axis=1)
    d = samples(ms / 1000)
    delayed = np.concatenate([np.zeros(d), mono])[: len(mono)]
    return np.stack([mono, delayed] if side > 0 else [delayed, mono], axis=1)


def autopan(x: np.ndarray, rate: float = 1.0, depth: float = 0.6, phase0: float = 0.0) -> np.ndarray:
    mono = x if x.ndim == 1 else x.mean(axis=1)
    pos = depth * np.sin(2 * np.pi * (rate * np.arange(len(mono)) / SR + phase0))
    return pan_mono(mono, pos)


def tremolo(x: np.ndarray, rate: float, depth: float = 0.5) -> np.ndarray:
    m = 1 - depth * (0.5 + 0.5 * np.sin(2 * np.pi * rate * np.arange(len(x)) / SR))
    return x * (m if x.ndim == 1 else m[:, None])
