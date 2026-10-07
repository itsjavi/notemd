"""Melodic voices used by the music tracks.

A voice renders one note: render(freq, dur, vel, glide_from=None, art=None) -> mono or stereo array whose
length covers the note plus its release. `art` is an articulation hint: 'mute' (dead/ghost note),
'accent', 'stacc'. Renders are cached per (freq, length, vel, glide, art) because songs repeat notes a lot.
"""

from __future__ import annotations

import numpy as np

import fx
import synth
from core import SR, samples


class Voice:
    release = 0.1
    stereo = False

    def __init__(self, **params):
        self.__dict__.update(params)
        self._cache: dict = {}

    def render(self, freq: float, dur: float, vel: float, glide_from: float | None = None,
               art: str | None = None) -> np.ndarray:
        key = (round(freq, 4), samples(dur), round(vel, 3), None if glide_from is None else round(glide_from, 4), art)
        hit = self._cache.get(key)
        if hit is None:
            hit = self._render(freq, max(dur, 0.01), vel, glide_from, art)
            self._cache[key] = hit
        return hit

    def _render(self, freq, dur, vel, glide_from, art) -> np.ndarray:  # pragma: no cover - interface
        raise NotImplementedError

    @staticmethod
    def _freq(freq, n, glide_from, glide_time):
        if glide_from is not None and glide_from != freq:
            return synth.glide(glide_from, freq, n, glide_time)
        return np.full(n, freq)


class FunkBass(Voice):
    """Plucky resonant synth bass with a fast filter 'pop' and a clean sine sub. Accents open the filter."""

    release = 0.05
    cutoff = 2600.0
    q = 2.4
    tau = 0.07
    sub = 0.8
    drive_db = 7.0
    glide_time = 0.05

    def _render(self, freq, dur, vel, glide_from, art):
        if art == "mute":
            dur = min(dur, 0.045)
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time)
        t = np.arange(n) / SR
        osc = 0.55 * synth.saw(f, n) + 0.45 * synth.pulse(f, n, 0.38)
        pop = (1.6 if art == "accent" else 1.0) * vel
        fc = freq * 2.0 + 250 + self.cutoff * pop * np.exp(-t / self.tau)
        if art == "mute":
            fc = np.full(n, 700.0)
        body = fx.sweep(osc, "lp", fc, self.q)
        amp = synth.adsr(n, 0.002, 0.18, 0.55, self.release, gate=dur)
        sub = self.sub * synth.sine(f, n) * synth.adsr(n, 0.003, 0.3, 0.8, self.release, gate=dur)
        if art == "mute":
            amp = synth.exp_decay(n, 0.06)
            sub *= 0.3
        out = fx.drive(body * amp * 0.9 + sub, self.drive_db)
        return out * vel


class ReeseBass(Voice):
    """Detuned saw 'reese' with slow filter motion, heavy drive and a separate clean sub."""

    release = 0.08
    cutoff = 520.0
    detune = 0.11  # semitones
    drive_db = 11.0
    glide_time = 0.06

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time)
        d = 2 ** (self.detune / 12)
        osc = synth.saw(f * d, n, 0.0) + synth.saw(f / d, n, 0.37) + 0.5 * synth.saw(f * 2.003, n, 0.1)
        t = np.arange(n) / SR
        fc = self.cutoff * (1 + 0.6 * np.sin(2 * np.pi * 0.9 * t)) + 1400 * vel * np.exp(-t / 0.09)
        if art == "accent":
            fc = fc + 1500 * np.exp(-t / 0.15)
        body = fx.drive(fx.sweep(osc * 0.5, "lp", fc, 1.6), self.drive_db)
        body = fx.lowpass(body, 3500)
        amp = synth.adsr(n, 0.004, 0.3, 0.85, self.release, gate=dur)
        sub = synth.sine(f, n) * synth.adsr(n, 0.004, 0.2, 0.95, self.release, gate=dur)
        return (0.55 * body * amp + 0.85 * sub) * vel


class DriveBass(Voice):
    """Punchy rock-synth bass (square + saw) for driving eighth-note lines."""

    release = 0.05
    glide_time = 0.04

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time)
        t = np.arange(n) / SR
        osc = 0.5 * synth.square(f, n) + 0.5 * synth.saw(f * 1.004, n)
        fc = freq * 3 + 300 + 1800 * vel * np.exp(-t / 0.1)
        body = fx.sweep(osc, "lp", fc, 1.3)
        amp = synth.adsr(n, 0.002, 0.2, 0.7, self.release, gate=dur)
        sub = 0.7 * synth.sine(f, n) * amp
        return fx.drive(body * amp + sub, 5.0) * vel


class PulseLead(Voice):
    """Chip-meets-modern lead: PWM pulse + detuned saw pair, filter envelope, delayed vibrato."""

    release = 0.09
    bright = 1.0
    vib_depth = 16.0
    vib_rate = 5.8
    glide_time = 0.05
    width_base = 0.5

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time) * synth.vibrato(n, self.vib_rate, self.vib_depth, 0.16, 0.25)
        t = np.arange(n) / SR
        pw = self.width_base - 0.2 * (0.5 + 0.5 * synth.lfo(n, 2.3))
        osc = 0.65 * synth.pulse(f, n, pw) + 0.32 * synth.saw(f * 1.004, n, 0.2) + 0.32 * synth.saw(f * 0.996, n, 0.6)
        fc = np.minimum(freq * 2.5 + (2800 + 4200 * vel * np.exp(-t / 0.22)) * self.bright, 16000)
        body = fx.sweep(osc, "lp", fc, 0.9, block=64)
        amp = synth.adsr(n, 0.004, 0.3, 0.78, self.release, gate=dur)
        if art == "stacc":
            amp *= synth.exp_decay(n, 0.25)
        return body * amp * vel * 0.8


class SuperLead(Voice):
    """Wide supersaw hero lead with a square an octave down for body."""

    release = 0.14
    stereo = True
    glide_time = 0.06
    detune = 16.0

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time) * synth.vibrato(n, 5.4, 14.0, 0.22, 0.3)
        t = np.arange(n) / SR
        chans = []
        for c in range(2):
            o = synth.supersaw(f, n, 5, self.detune, seed=11 + c)
            o += 0.35 * synth.square(f * 0.5, n, 0.1 * c)
            fc = np.minimum(freq * 2 + 2400 + 4000 * vel * np.exp(-t / 0.3), 15000)
            chans.append(fx.sweep(o, "lp", fc, 0.8, block=64))
        amp = synth.adsr(n, 0.008, 0.35, 0.8, self.release, gate=dur)
        return np.stack(chans, axis=1) * amp[:, None] * vel * 0.7


class Brass(Voice):
    """Synth brass: detuned saws with a swelling filter; good for stabs and heroic chords."""

    release = 0.16
    stereo = True
    attack = 0.025
    swell = 0.07

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        t = np.arange(n) / SR
        f = np.full(n, freq) * synth.vibrato(n, 5.0, 8.0, 0.3, 0.4)
        chans = []
        for c in range(2):
            o = synth.saw(f * 2 ** ((-7 + 14 * c) / 1200), n, 0.3 * c) + 0.8 * synth.saw(f * 2 ** ((5 - 10 * c) / 1200), n, 0.5)
            env_f = 1 - np.exp(-t / self.swell)
            fc = freq * 1.5 + 400 + 3800 * vel * env_f * (0.7 + 0.3 * np.exp(-t / 0.4))
            chans.append(fx.sweep(o, "lp", fc, 1.1, block=64))
        amp = synth.adsr(n, self.attack, 0.25, 0.75, self.release, gate=dur)
        out = np.stack(chans, axis=1) * amp[:, None] * vel * 0.5
        return fx.drive(out, 2.0)


class EPiano(Voice):
    """FM electric piano (tine + body) for funky comping. Stereo tremolo-free, slight detune between sides."""

    release = 0.12
    stereo = True
    bright = 1.0

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        t = np.arange(n) / SR
        idx = (1.6 * vel * self.bright) * np.exp(-t / 0.35) + 0.25
        chans = []
        for c, det in enumerate((-3.0, 3.0)):
            ff = freq * 2 ** (det / 1200)
            body = synth.fm(ff, n, 1.0, idx)
            tine = synth.fm(ff, n, 14.0, 0.8 * vel) * np.exp(-t / 0.04) * 0.22
            chans.append(body + tine)
        amp = synth.adsr(n, 0.002, 0.9, 0.3, self.release, gate=dur)
        return np.stack(chans, axis=1) * amp[:, None] * vel * 0.6


class Pad(Voice):
    """Warm supersaw pad, slow attack, wide."""

    release = 0.7
    stereo = True
    attack = 0.25
    cutoff = 2200.0

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        chans = []
        for c in range(2):
            o = synth.supersaw(freq, n, 5, 22.0, seed=31 + c)
            chans.append(fx.lowpass(o, self.cutoff, 0.6, order=2))
        amp = synth.adsr(n, self.attack, 0.6, 0.85, self.release, gate=dur, curve=3.0)
        return np.stack(chans, axis=1) * amp[:, None] * vel * 0.5


class Bell(Voice):
    """FM bell / glockenspiel for countermelodies and sparkle."""

    release = 0.6
    ratio = 3.5
    decay = 0.9

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(max(dur, 0.1) + self.release)
        t = np.arange(n) / SR
        idx = 2.2 * vel * np.exp(-t / 0.25) + 0.3
        o = synth.fm(freq, n, self.ratio, idx) + 0.3 * synth.sine(freq * 2, n) * np.exp(-t / 0.3)
        amp = synth.exp_decay(n, self.decay, attack=0.001)
        gate = samples(dur)
        if gate < n:
            amp[gate:] *= np.exp(-(np.arange(n - gate)) / max(1, samples(self.release / 4)))
        return o * amp * vel * 0.6


class Pluck(Voice):
    """Short pulse pluck for arpeggios."""

    release = 0.06
    width_ = 0.3
    decay = 0.18
    bright = 3500.0

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release + 0.1)
        t = np.arange(n) / SR
        o = synth.pulse(freq, n, self.width_) + 0.4 * synth.saw(freq * 2.002, n)
        fc = freq * 2 + self.bright * vel * np.exp(-t / 0.05) + 400
        body = fx.sweep(o, "lp", fc, 1.4)
        amp = synth.exp_decay(n, self.decay * 3) * synth.adsr(n, 0.001, 0.05, 1.0, self.release, gate=dur)
        return body * amp * vel * 0.6


class Stab(Voice):
    """Aggressive saw stack stab (boss)."""

    release = 0.08
    stereo = True

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        t = np.arange(n) / SR
        chans = []
        for c in range(2):
            o = synth.supersaw(freq, n, 3, 20, seed=51 + c) + 0.4 * synth.square(freq / 2, n)
            fc = 600 + 6000 * vel * np.exp(-t / 0.08)
            chans.append(fx.drive(fx.sweep(o, "lp", fc, 2.0), 8.0))
        amp = synth.adsr(n, 0.002, 0.12, 0.5, self.release, gate=dur)
        return np.stack(chans, axis=1) * amp[:, None] * vel * 0.4


class GuitarMute(Voice):
    """Karplus-Strong funk guitar 'chicken scratch' (muted, percussive)."""

    release = 0.03
    damp = 0.45
    feedback = 0.985

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release + 0.02)
        lp_delay = self.damp / (1 - self.damp)
        d = max(2, int(round(SR / freq - lp_delay - 0.5)))
        exc = np.zeros(n)
        burst = fx.lowpass(synth.noise(d, seed=int(freq * 10) % 9973), 5000 * vel + 1500)
        exc[:d] = burst
        y = fx.comb(exc, d, self.feedback if art != "mute" else 0.8, self.damp)
        amp = synth.adsr(n, 0.001, 0.05, 0.6 if art != "mute" else 0.0, self.release, gate=dur)
        y = fx.highpass(y * amp, 180)
        return y * vel * 1.2


class SubSine(Voice):
    release = 0.04

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, 0.05)
        return synth.sine(f, n) * synth.adsr(n, 0.004, 0.1, 1.0, self.release, gate=dur) * vel


class DeepBass(Voice):
    """Deep, round night bass: clean sine sub plus a low-passed saw/square with a soft pluck."""

    release = 0.07
    cutoff = 380.0
    glide_time = 0.05

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time)
        t = np.arange(n) / SR
        body = synth.saw(f, n) + 0.5 * synth.square(f * 1.003, n, 0.3)
        fc = self.cutoff + freq + 900 * vel * np.exp(-t / 0.1) * (1.6 if art == "accent" else 1.0)
        body = fx.drive(fx.sweep(body * 0.5, "lp", fc, 1.3), 4.0)
        amp = synth.adsr(n, 0.004, 0.3, 0.8, self.release, gate=dur)
        sub = synth.sine(f, n) * synth.adsr(n, 0.005, 0.2, 0.95, self.release, gate=dur)
        return (0.9 * sub + 0.5 * body * amp) * vel


class Choir(Voice):
    """Synthetic 'aah' choir: detuned saws through three vowel formants, slow swell, wide."""

    release = 0.6
    stereo = True
    attack = 0.3
    formants = ((700.0, 1.0, 5.0), (1220.0, 0.5, 7.0), (2600.0, 0.25, 9.0))

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = np.full(n, freq) * synth.vibrato(n, 5.2, 12.0, 0.2, 0.5)
        chans = []
        for c in range(2):
            src = synth.supersaw(f, n, 5, 14.0, seed=71 + c)
            out = sum(fx.bandpass(src, fc, q) * g for fc, g, q in self.formants)
            chans.append(out + 0.15 * fx.lowpass(src, 500))
        amp = synth.adsr(n, self.attack, 0.5, 0.9, self.release, gate=dur, curve=3.0)
        return np.stack(chans, axis=1) * amp[:, None] * vel * 0.9


# ---------------------------------------------------------------- 8-bit console voices
#
# Chip voices stay unfiltered and dry on purpose: the character comes from fixed pulse duties, 4-bit volume steps
# and quantised waveforms. Give their tracks no reverb (or very little) and use echo tracks instead of delay sends.


class ChipPulse(Voice):
    """NES-style pulse: fixed duty (0.125 thin, 0.25 classic, 0.5 hollow), 16-step volume envelope, optional
    vibrato. 'stacc' notes decay quickly; 'accent' starts at full volume."""

    release = 0.02
    duty = 0.25
    decay = 0.35
    sustain = 0.55
    vib_depth = 0.0
    glide_time = 0.04

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time)
        if self.vib_depth:
            f = f * synth.vibrato(n, 6.0, self.vib_depth, 0.2, 0.15)
        osc = synth.pulse(f, n, self.duty)
        sus = 0.15 if art == "stacc" else self.sustain
        env = synth.adsr(n, 0.001, self.decay * (0.4 if art == "stacc" else 1.0), sus, self.release, gate=dur, curve=3.0)
        env = np.round(env * min(1.0, vel * (1.15 if art == "accent" else 1.0)) * 15) / 15
        return osc * env * 0.5


class ChipTriangle(Voice):
    """NES-style triangle bass: 16-level quantised triangle with no volume control (on/off only), so `vel` only
    decides whether it sounds. A 2 ms ramp at both ends avoids clicks."""

    release = 0.002
    glide_time = 0.03

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        f = self._freq(freq, n, glide_from, self.glide_time)
        tri = np.round(synth.triangle(f, n) * 7.5) / 7.5
        if art == "mute":
            dur = min(dur, 0.04)
        env = synth.adsr(n, 0.002, 0.01, 1.0, 0.002, gate=dur)
        return tri * env * (0.8 if vel > 0.05 else 0.0)
