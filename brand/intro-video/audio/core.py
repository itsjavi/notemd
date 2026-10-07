"""Shared constants and helpers: sample rate, pitch math, loudness metering, limiting and file output.

Array convention used across the toolkit: mono signals are float64 arrays of shape (n,), stereo signals
are shape (n, 2). Full scale is 1.0.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.ndimage import minimum_filter1d, uniform_filter1d

SR = 44100

_NOTE_PC = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
_NOTE_RE = re.compile(r"([A-Ga-g])([#b]*)(-?\d+)$")


# ---------------------------------------------------------------- pitch and units


def note_to_midi(name: str) -> int:
    """'C4' -> 60, 'F#5' -> 78, 'Bb3' -> 58."""
    m = _NOTE_RE.match(name.strip())
    if not m:
        raise ValueError(f"bad note name: {name!r}")
    letter, acc, octave = m.groups()
    pc = _NOTE_PC[letter.upper()] + acc.count("#") - acc.count("b")
    return 12 * (int(octave) + 1) + pc


def midi_to_freq(m: float) -> float:
    return 440.0 * 2.0 ** ((m - 69.0) / 12.0)


def note_freq(name: str) -> float:
    return midi_to_freq(note_to_midi(name))


def db_to_amp(db: float) -> float:
    return 10.0 ** (db / 20.0)


def amp_to_db(a: float) -> float:
    return 20.0 * np.log10(max(float(a), 1e-12))


def samples(seconds: float) -> int:
    return int(round(seconds * SR))


def time_axis(n: int) -> np.ndarray:
    return np.arange(n) / SR


# ---------------------------------------------------------------- channel helpers


def to_stereo(x: np.ndarray) -> np.ndarray:
    return x if x.ndim == 2 else np.stack([x, x], axis=1)


def to_mono(x: np.ndarray) -> np.ndarray:
    return x if x.ndim == 1 else x.mean(axis=1)


def pan(x: np.ndarray, position: float | np.ndarray) -> np.ndarray:
    """Constant-power pan of a mono signal. position -1 (left) .. 1 (right); centre keeps unity gain."""
    angle = (np.clip(position, -1.0, 1.0) + 1.0) * np.pi / 4.0
    gl = np.cos(angle) * np.sqrt(2.0)
    gr = np.sin(angle) * np.sqrt(2.0)
    return np.stack([x * gl, x * gr], axis=1)


def mix_into(dest: np.ndarray, src: np.ndarray, start: int, gain: float = 1.0) -> None:
    """Add src into dest at sample offset start (clipped to dest bounds). Shapes must agree on channels."""
    if start >= len(dest) or len(src) == 0:
        return
    s0 = max(0, -start)
    d0 = max(0, start)
    n = min(len(src) - s0, len(dest) - d0)
    if n > 0:
        dest[d0 : d0 + n] += src[s0 : s0 + n] * gain


def fit_length(x: np.ndarray, n: int) -> np.ndarray:
    if len(x) >= n:
        return x[:n]
    pad = [(0, n - len(x))] + [(0, 0)] * (x.ndim - 1)
    return np.pad(x, pad)


def fade(x: np.ndarray, fade_in: float = 0.0, fade_out: float = 0.0) -> np.ndarray:
    y = x.copy()
    for secs, rising in ((fade_in, True), (fade_out, False)):
        k = min(samples(secs), len(y))
        if k <= 0:
            continue
        ramp = np.sin(np.linspace(0.0, np.pi / 2, k)) ** 2
        if not rising:
            ramp = ramp[::-1]
            sl = slice(len(y) - k, len(y))
        else:
            sl = slice(0, k)
        y[sl] *= ramp if y.ndim == 1 else ramp[:, None]
    return y


def remove_dc(x: np.ndarray, cutoff: float = 12.0) -> np.ndarray:
    b, a = signal.butter(1, cutoff / (SR / 2), btype="highpass")
    return signal.lfilter(b, a, x, axis=0)


def trim_silence(x: np.ndarray, threshold_db: float = -70.0, keep: float = 0.01) -> np.ndarray:
    level = np.abs(x) if x.ndim == 1 else np.abs(x).max(axis=1)
    idx = np.nonzero(level > db_to_amp(threshold_db))[0]
    if len(idx) == 0:
        return x[: samples(keep)]
    return x[: min(len(x), idx[-1] + samples(keep))]


# ---------------------------------------------------------------- loudness (ITU-R BS.1770-4)


def _k_weighting_coeffs():
    # Stage 1: high shelf (+4 dB at high frequencies), stage 2: RLB high-pass. Same design as pyloudnorm.
    g, q, fc = 4.0, 1.0 / np.sqrt(2.0), 1500.0
    a_ = 10 ** (g / 40.0)
    w0 = 2.0 * np.pi * fc / SR
    alpha = np.sin(w0) / (2.0 * q)
    cw = np.cos(w0)
    sa = np.sqrt(a_)
    b1 = [a_ * ((a_ + 1) + (a_ - 1) * cw + 2 * sa * alpha), -2 * a_ * ((a_ - 1) + (a_ + 1) * cw),
          a_ * ((a_ + 1) + (a_ - 1) * cw - 2 * sa * alpha)]
    a1 = [(a_ + 1) - (a_ - 1) * cw + 2 * sa * alpha, 2 * ((a_ - 1) - (a_ + 1) * cw),
          (a_ + 1) - (a_ - 1) * cw - 2 * sa * alpha]
    q2, fc2 = 0.5, 38.0
    w0 = 2.0 * np.pi * fc2 / SR
    alpha = np.sin(w0) / (2.0 * q2)
    cw = np.cos(w0)
    b2 = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
    a2 = [1 + alpha, -2 * cw, 1 - alpha]
    return (np.array(b1) / a1[0], np.array(a1) / a1[0]), (np.array(b2) / a2[0], np.array(a2) / a2[0])


_KW = _k_weighting_coeffs()


def _block_loudness(x: np.ndarray, block: float, hop: float) -> np.ndarray:
    """Per-block loudness (LUFS) of K-weighted signal. Mono input is measured as dual mono (as heard in game)."""
    x = to_stereo(x)
    (b1, a1), (b2, a2) = _KW
    y = signal.lfilter(b2, a2, signal.lfilter(b1, a1, x, axis=0), axis=0)
    nb, nh = samples(block), max(1, samples(hop))
    if len(y) < nb:
        y = fit_length(y, nb)
    cs = np.concatenate([np.zeros((1, 2)), np.cumsum(y**2, axis=0)])
    starts = np.arange(0, len(y) - nb + 1, nh)
    z = ((cs[starts + nb] - cs[starts]) / nb).sum(axis=1)
    return -0.691 + 10.0 * np.log10(z + 1e-20)


def lufs_integrated(x: np.ndarray) -> float:
    lb = _block_loudness(x, 0.4, 0.1)
    z = 10 ** ((lb + 0.691) / 10.0)
    keep = lb > -70.0
    if not keep.any():
        return -120.0
    rel = -0.691 + 10 * np.log10(z[keep].mean()) - 10.0
    keep &= lb > rel
    return float(-0.691 + 10 * np.log10(z[keep].mean()))


def lufs_momentary_max(x: np.ndarray) -> float:
    return float(_block_loudness(x, 0.4, 0.01).max())


def peak_db(x: np.ndarray) -> float:
    return amp_to_db(np.abs(x).max())


# ---------------------------------------------------------------- dynamics


def limit(x: np.ndarray, ceiling_db: float = -1.0, smooth_ms: float = 6.0, hold_ms: float = 25.0,
          circular: bool = False) -> np.ndarray:
    """Offline look-ahead peak limiter. Gain never exceeds what keeps samples under the ceiling.

    The gain curve is a running minimum (look-ahead + hold) smoothed by two box filters, so the ramp starts
    before each peak and recovers smoothly after it. circular=True treats the signal as a seamless loop.
    """
    ceiling = db_to_amp(ceiling_db)
    level = np.abs(x) if x.ndim == 1 else np.abs(x).max(axis=1)
    g_req = np.minimum(1.0, ceiling / np.maximum(level, 1e-12))
    s = max(2, samples(smooth_ms / 1000.0))
    h = samples(hold_ms / 1000.0)
    mode = "wrap" if circular else "nearest"
    # Window covering [n - s - h, n + s]: two smoothing passes of width s each can then never lift a sample
    # above its own requirement.
    size = 2 * s + h + 1
    g = minimum_filter1d(g_req, size=size, origin=(h // 2), mode=mode)
    g = uniform_filter1d(g, size=s, mode=mode)
    g = uniform_filter1d(g, size=s, mode=mode)
    y = x * (g if x.ndim == 1 else g[:, None])
    # Safety for float rounding: hard ceiling.
    return np.clip(y, -ceiling, ceiling)


def soft_clip(x: np.ndarray, drive_db: float = 0.0) -> np.ndarray:
    k = db_to_amp(drive_db)
    return np.tanh(x * k) / np.tanh(k) if k != 1.0 else np.tanh(x)


def normalize_peak(x: np.ndarray, target_db: float = -1.0) -> np.ndarray:
    p = np.abs(x).max()
    return x if p == 0 else x * (db_to_amp(target_db) / p)


def normalize_loudness(x: np.ndarray, target_lufs: float, measure=lufs_integrated) -> np.ndarray:
    current = measure(x)
    if current < -100:
        return x
    return x * db_to_amp(target_lufs - current)


# ---------------------------------------------------------------- output


def write_ogg(path: Path, x: np.ndarray, quality: float = 0.6, title: str = "",
              artist: str = "procedural (tools/audio)") -> None:
    """Encode float audio to OGG Vorbis. Uses libsndfile (soundfile) with libvorbis; falls back to ffmpeg."""
    path.parent.mkdir(parents=True, exist_ok=True)
    x = np.clip(x, -1.0, 1.0).astype(np.float32)
    try:
        import soundfile as sf

        with sf.SoundFile(str(path), "w", samplerate=SR, channels=1 if x.ndim == 1 else 2,
                          format="OGG", subtype="VORBIS", compression_level=1.0 - quality) as f:
            if title:
                f.title = title
            f.artist = artist
            # libsndfile's Vorbis encoder crashes on very large single writes; feed it in blocks.
            for i in range(0, len(x), 4096):
                f.write(np.ascontiguousarray(x[i : i + 4096]))
        return
    except ImportError:
        pass
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("OGG encoding needs the soundfile package or ffmpeg on PATH")
    ch = 1 if x.ndim == 1 else 2
    cmd = [ffmpeg, "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", str(ch), "-i", "pipe:0",
           "-c:a", "vorbis", "-strict", "experimental", "-q:a", str(round(quality * 10)), str(path)]
    subprocess.run(cmd, input=x.tobytes(), check=True)


def write_wav(path: Path, x: np.ndarray) -> None:
    from scipy.io import wavfile

    path.parent.mkdir(parents=True, exist_ok=True)
    wavfile.write(str(path), SR, np.clip(x, -1, 1).astype(np.float32))
