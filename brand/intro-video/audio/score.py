"""NoteMD intro score: warm electronic, 100 BPM, D major, 17 bars (40.8 s) plus ring-out. Original material.

One bar is 2.4 s, so every scene of the animation starts on a bar line (see ../timeline.js):

  bars 0-1   logo         pad swell and held keys (IV -> V)
  bars 2-3   headline     keys comping, round bass, shaker and rim
  bars 4-11  features     full groove, mallet motif (bars 4-7), variation with arpeggio (bars 8-11)
  bars 12-13 video review counter-melody on bells, open hats
  bar 14     goodbye      breakdown: drums out, riser into the resolution
  bars 15-16 outro        tonic sting (crash, bell arpeggio), held chord
"""

from __future__ import annotations

import numpy as np

import fx
import instruments as I
import synth
from core import SR, samples
from music import common as C
from sequencer import Song

BPM = 100
BARS = 17


class Mallet(I.Voice):
    """Kalimba-like lead: sine body, a quickly fading triangle octave and a faint bright partial."""

    release = 0.25

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release + 0.6)
        t = np.arange(n) / SR
        body = (synth.sine(freq, n) + 0.35 * synth.triangle(freq * 2, n) * np.exp(-t / 0.12)
                + 0.12 * synth.sine(freq * 4.01, n) * np.exp(-t / 0.05))
        amp = synth.exp_decay(n, 1.1, attack=0.004) * synth.adsr(n, 0.004, 0.2, 1.0, self.release, gate=dur)
        return fx.lowpass(body, 5000) * amp * vel * 0.6


class WarmKeys(I.EPiano):
    """Darker, rounder electric piano: lower FM brightness and a gentle low-pass."""

    bright = 0.55
    release = 0.3

    def _render(self, freq, dur, vel, glide_from, art):
        return fx.lowpass(super()._render(freq, dur, vel, glide_from, art), 3200)


class RoundBass(I.Voice):
    """Soft round bass: sine fundamental with a little low-passed saw for definition."""

    release = 0.08

    def _render(self, freq, dur, vel, glide_from, art):
        n = samples(dur + self.release)
        t = np.arange(n) / SR
        grit = fx.sweep(synth.saw(freq, n), "lp", 260 + freq + 500 * np.exp(-t / 0.08), 0.9)
        amp = synth.adsr(n, 0.008, 0.25, 0.85, self.release, gate=dur)
        return (synth.sine(freq, n) + 0.3 * grit) * amp * vel * 0.8


MOTIF = """
A5:3 F#5 E5:2 F#5:2 . . A5:2 B5:4 |
A5:6 F#5:2 . . D5:2 E5:4 |
B5:3 A5 F#5:2 A5:2 . . D6:2 C#6:4 |
"""
MOTIF_END = "B5:4 A5:4 E5:4 C#5:4 |"
VARIATION_END = "E6:4 D6:2 C#6:2 B5:4 A5:4 |"
COUNTER = "F#6:4 E6:4 D6:4 A5:4 | B5:6 A5:2 F#5:8 |"
STING = "A5:2 D6:2 F#6:2 A6:10 |"

GROOVE = {
    "kick": "X.....x...X.....",
    "snare": "....X.......X...",
    "rim": "..........o.....",
    "hat": "x.o.x.o.x.o.x.oo",
}


def compose() -> Song:
    s = Song("notemd_intro", BPM, BARS, swing=0.08, loop=False, seed=26)
    k = C.kit(kick_tone=50.0, kick_decay=0.3, snare_tone=220.0)
    C.drum_tracks(s, {"kick": -19.0, "snare": -22.0, "hat": -29.0, "ohat": -31.0, "shaker": -31.0, "rim": -28.0,
                      "crash": -27.0, "fx": -28.0, "impact": -26.0})
    s.track("pad", I.Pad(attack=0.9, cutoff=1300.0), level=-24.0, reverb=0.35, width=1.4, duck=0.3)
    s.track("keys", WarmKeys(), level=-21.0, reverb=0.25, delay=0.12, duck=0.15)
    s.track("bass", RoundBass(), level=-18.0, duck=0.25)
    s.track("lead", Mallet(), level=-19.0, reverb=0.3, delay=0.22, pan=0.1)
    s.track("bell", I.Bell(decay=1.4), level=-23.0, reverb=0.4, delay=0.25, pan=-0.15)
    s.track("arp", I.Pluck(decay=0.22, bright=1500.0), level=-28.0, reverb=0.3, delay=0.3, pan=-0.2, duck=0.2)

    s.chords(0, "Gmaj9 | A6:8 Asus4:8 |")
    s.chords(2, "Dmaj9 | Bm9 |")
    for bar in (4, 8):
        s.chords(bar, "Dmaj9 | Bm9 | Gmaj9 | Asus4:8 A:8 |")
    s.chords(12, "Dmaj9 | Bm9 | Gmaj9:8 Asus4:4 A:4 | Dmaj9 | Dmaj9 |")
    for name, bar in (("logo", 0), ("headline", 2), ("features", 4), ("variation", 8), ("review", 12),
                      ("breakdown", 14), ("outro", 15)):
        s.section(name, bar)

    # Pad throughout, opening up during the logo.
    s.sustain_chords("pad", 0, 17, center=60, vel=0.6)
    s.filter_sweep("pad", "lp", [(0, 500.0), (2, 2400.0), (14, 2400.0), (15, 1200.0), (17, 700.0)])

    # Keys: held chords in the intro, lo-fi comping from the headline on, held again at the end.
    s.comp("keys", 0, 2, "X:16", center=62, vel=0.5, gate=1.0)
    s.comp("keys", 2, 12, ". . X:3 . . x:2 . . x:4 .", center=64, vel=0.6, gate=0.9)
    s.comp("keys", 14, 1, "X:8 x:4 x:4", center=62, vel=0.5, gate=1.0)
    s.comp("keys", 15, 2, "X:16", center=64, vel=0.55, gate=1.0)

    # Bass: whole notes for the headline, a gentle groove for the features, the tonic to close.
    s.groove("bass", 2, 2, "1:16", octave=2, vel=0.7, low=33)
    s.groove("bass", 4, 10, "1:6 . . 5:4 . . 8:2", octave=2, vel=0.8, low=33)
    s.groove("bass", 14, 1, "1:8 1:4 1:4", octave=2, vel=0.7, low=33)
    s.groove("bass", 15, 2, "1:16", octave=2, vel=0.8, low=33)

    # Melody: motif, variation with arpeggio, counter-melody, sting.
    s.notes("lead", 4, MOTIF + MOTIF_END, vel=0.75)
    s.notes("lead", 8, MOTIF + VARIATION_END, vel=0.8)
    s.arp("arp", 8, 6, rate=2, mode="pingpong", octaves=2, center=69, vel=0.45, accents="Xoxo", pan_spread=0.5)
    s.notes("bell", 12, COUNTER, vel=0.7)
    s.notes("bell", 15, STING, vel=0.85)

    # Drums: shaker and rim for the headline, the groove for the features, nothing in the breakdown.
    C.beat(s, 2, 2, k, {"shaker": "o.o.o.o.o.o.o.o.", "rim": "....x.......x..."}, vel=0.8)
    C.beat(s, 4, 8, k, GROOVE)
    C.beat(s, 12, 2, k, {**GROOVE, "ohat": "..O...O...O...O."})
    C.riser(s, 4, 1, vel=0.5, seed=4)
    C.riser(s, 15, 1, vel=0.6, seed=15)
    C.crash(s, 4, 0.5)
    C.crash(s, 15, 0.7)
    C.impact(s, 15, 0.5)
    s.drums(15, 1, {"kick": ("X...............", k["kick"])})
    return s
