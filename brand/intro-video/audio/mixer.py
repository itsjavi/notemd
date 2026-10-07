"""Mixer: renders a Song's tracks to stems, levels them by loudness, applies sends, sidechain ducking and the
master chain, and makes loops seamless.

Seamless loops: everything is rendered on a timeline of loop length + tail. Sends (reverb/delay) run over
that extended timeline, then the tail is wrapped around and summed onto the start ("tail wrap-around"), so
what rings past the loop end is heard at the loop start exactly as in a continuous performance. Ducking
uses circular triggers and the master limiter runs in circular mode, so no processing seam remains.
"""

from __future__ import annotations

import numpy as np

import fx
from core import (SR, db_to_amp, limit, lufs_integrated, midi_to_freq, mix_into, pan, samples,
                  to_stereo)
from sequencer import Song, Track


def _interp_exp(points: list[tuple[int, float]], n: int) -> np.ndarray:
    xs = np.array([p[0] for p in points], dtype=np.float64)
    ys = np.log(np.array([p[1] for p in points], dtype=np.float64))
    return np.exp(np.interp(np.arange(n), xs, ys))


def render_track(song: Song, tr: Track, n: int, select=None) -> np.ndarray:
    buf = np.zeros((n, 2))
    for ev in tr.events:
        if select is not None and not select(ev):
            continue
        if ev.sample is not None:
            hit = ev.sample * ev.vel
        else:
            hit = tr.voice.render(midi_to_freq(ev.midi), ev.dur, ev.vel, ev.glide_from, ev.art)
        if hit.ndim == 1:
            hit = pan(hit, np.clip(ev.pan + tr.pan, -1, 1))
        elif ev.pan + tr.pan:
            p = np.clip(ev.pan + tr.pan, -1, 1)
            hit = hit * np.array([min(1.0, 1 - p), min(1.0, 1 + p)])
        mix_into(buf, hit, ev.start)
    for kind, points, q in tr.filter_auto:
        buf = fx.sweep(buf, kind, _interp_exp(points, n), q, block=64)
    for insert in tr.inserts:
        buf = to_stereo(insert(buf))
    return buf


def render(song: Song, tail: float = 4.0, target_lufs: float = -14.0, ceiling_db: float = -1.5,
           reverb_params: dict | None = None, delay_time: float | None = None, delay_feedback: float = 0.35,
           stems_out: dict | None = None) -> np.ndarray:
    """Render a song to a mastered stereo array.

    Looping songs with song.loop_start > 0 are rendered in two parts: the intro (events before the loop
    start, played once) and the loop body (events after it). The body is made circular (its tail wraps onto
    its own start) so the jump from the file end back to the loop offset is exact; the intro's last 40 ms
    crossfade into the body's ending, so the one-time intro-to-body transition is click-free too.
    """
    L = song.length
    n = L + samples(tail)
    o = song.pos(song.loop_start) if song.loop else 0
    parts = {"body": lambda ev: ev.start >= o}
    if o:
        parts["intro"] = lambda ev: ev.start < o

    kicks = {p: [] for p in parts}
    for tr in song.tracks.values():
        if tr.sidechain_source:
            for ev in tr.events:
                if ev.vel <= 0.5:
                    continue
                if ev.start >= o:
                    kicks["body"].append(ev.start)
                if o:
                    kicks["intro"].append(ev.start)
    period = (L - o) if song.loop else None

    mix = {p: np.zeros((n, 2)) for p in parts}
    rev_send = {p: np.zeros((n, 2)) for p in parts}
    dly_send = {p: np.zeros((n, 2)) for p in parts}
    for tr in song.tracks.values():
        if not tr.events:
            continue
        bufs = {p: render_track(song, tr, n, sel) for p, sel in parts.items()}
        gain = db_to_amp(tr.gain_db)
        if tr.level is not None:
            cur = lufs_integrated(sum(bufs.values()))
            if cur > -100:
                gain *= db_to_amp(tr.level - cur)
        auto = None
        if tr.gain_auto:
            pts = sorted(tr.gain_auto)
            auto = (10 ** (np.interp(np.arange(n), [p[0] for p in pts], [p[1] for p in pts]) / 20))[:, None]
        for p, buf in bufs.items():
            buf *= gain
            if auto is not None:
                buf *= auto
            if tr.duck and kicks[p]:
                buf *= fx.duck_envelope(n, kicks[p], tr.duck, period=period if p == "body" else None)[:, None]
            if tr.width != 1.0:
                buf = fx.width(buf, tr.width)
            mix[p] += buf
            if tr.reverb:
                rev_send[p] += buf * tr.reverb
            if tr.delay:
                dly_send[p] += buf * tr.delay
            if stems_out is not None:
                stems_out[tr.name] = stems_out.get(tr.name, 0) + buf

    rp = {"room": 0.8, "damp": 0.45, "width": 1.0}
    rp.update(reverb_params or {})
    for p in parts:
        if dly_send[p].any():
            dt = delay_time or song.beat * 0.75
            echoes = fx.delay(dly_send[p], dt, delay_feedback, mix=1.0, damp=0.35) - dly_send[p]
            echoes = fx.highpass(echoes, 300)
            mix[p] += echoes
            rev_send[p] += echoes * 0.3
        if rev_send[p].any():
            mix[p] += fx.reverb(rev_send[p], wet=1.0, dry=0.0, **rp)

    if not song.loop:
        return master(mix["body"], target_lufs, ceiling_db, circular=False)
    body = mix["body"][o:L].copy()
    tail_n = n - L
    body[:tail_n] += mix["body"][L:]
    full = np.concatenate([mix["intro"][:o], body]) if o else body
    return master(full, target_lufs, ceiling_db, circular=True, loop_start=o)


def _circular_filter(x: np.ndarray, func, pad: int) -> np.ndarray:
    pad = min(pad, len(x))
    padded = np.concatenate([x[-pad:], x, x[:pad]])
    return func(padded)[pad:-pad]


def _loop_aware(x: np.ndarray, o: int, circ, lin) -> np.ndarray:
    """Apply a process to a file that plays [0, end) once and then loops [o, end): the body is processed
    circularly, the intro linearly with 2 s of the body appended so look-ahead/filters see what follows."""
    body = circ(x[o:])
    if not o:
        return body
    pad = min(len(body), samples(2.0))
    intro = lin(np.concatenate([x[:o], body[:pad]]))[:o]
    return np.concatenate([intro, body])


def master(mix: np.ndarray, target_lufs: float, ceiling_db: float, circular: bool, loop_start: int = 0) -> np.ndarray:
    """Clean-up EQ, loudness normalisation and look-ahead limiting (iterated so the result lands on target)."""

    def clean(x):
        x = fx.highpass(x, 28, order=2)
        return fx.eq(x, "highshelf", 10000, -1.5)

    o = loop_start
    if circular:
        mix = _loop_aware(mix, o, lambda b: _circular_filter(b, clean, samples(2.0)), clean)
    else:
        mix = clean(mix)
    for _ in range(4):
        cur = lufs_integrated(mix)
        mix = mix * db_to_amp(target_lufs - cur)
        if circular:
            mix = _loop_aware(mix, o, lambda b: limit(b, ceiling_db, circular=True),
                              lambda x: limit(x, ceiling_db, circular=False))
        else:
            mix = limit(mix, ceiling_db, circular=False)
        if abs(lufs_integrated(mix) - target_lufs) < 0.15:
            break
    if circular and o:
        # One-time intro -> body transition: blend the intro's last 40 ms into the body's ending, which is
        # by construction continuous with the body's first sample.
        k = min(samples(0.04), o)
        w = np.linspace(0.0, 1.0, k)[:, None]
        mix[o - k : o] = mix[o - k : o] * (1 - w) + mix[-k:] * w
    return mix
