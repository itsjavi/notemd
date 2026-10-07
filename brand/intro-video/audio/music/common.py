"""Shared drum kits, mixer track presets and arrangement helpers (fills, rolls, crashes, risers, jingles)."""

from __future__ import annotations

import drums
from core import SR, fade, samples
from mixer import render
from sequencer import Song

TOMS = {"hi": 210.0, "mid": 155.0, "low": 108.0, "floor": 80.0}


def kit(kick_tone: float = 52.0, kick_decay: float = 0.32, snare_tone: float = 190.0) -> dict:
    """Modern synth kit. Each entry maps a round-robin variant index to a hit."""
    return {
        "kick": lambda v: drums.kick(kick_tone, 190.0, kick_decay, variant=v),
        "snare": lambda v: drums.snare(snare_tone, variant=v),
        "clap": lambda v: drums.clap(variant=v),
        "hat": lambda v: drums.hat(False, variant=v),
        "ohat": lambda v: drums.hat(True, variant=v),
        "ride": lambda v: drums.ride(variant=v),
        "shaker": lambda v: drums.shaker(variant=v),
        "rim": lambda v: drums.rim(variant=v),
    }


def chip_kit() -> dict:
    """8-bit console kit (triangle kick, noise snare/hats)."""
    return {
        "kick": lambda v: drums.chip_kick(variant=v),
        "snare": lambda v: drums.chip_snare(variant=v),
        "hat": lambda v: drums.chip_hat(False, variant=v),
        "ohat": lambda v: drums.chip_hat(True, variant=v),
    }


def drum_tracks(song: Song, levels: dict | None = None, dry: bool = False) -> None:
    """Create drum tracks with sensible stem levels (LUFS) and sends. dry=True drops reverb (chip music)."""
    lv = {"kick": -16.5, "snare": -19.0, "clap": -25.0, "hat": -27.0, "ohat": -29.0, "ride": -29.0, "shaker": -31.0,
          "rim": -28.0, "tom": -21.0, "crash": -27.0, "fx": -27.0, "impact": -24.0}
    lv.update(levels or {})
    rv = 0.0 if dry else 1.0
    song.track("kick", level=lv["kick"], sidechain_source=True)
    song.track("snare", level=lv["snare"], reverb=0.14 * rv)
    song.track("clap", level=lv["clap"], reverb=0.22 * rv, pan=0.1)
    song.track("hat", level=lv["hat"], pan=0.25)
    song.track("ohat", level=lv["ohat"], pan=0.25, reverb=0.05 * rv)
    song.track("ride", level=lv["ride"], pan=-0.3, reverb=0.05 * rv)
    song.track("shaker", level=lv["shaker"], pan=-0.4)
    song.track("rim", level=lv["rim"], pan=-0.2, reverb=0.1 * rv)
    song.track("tom", level=lv["tom"], reverb=0.15 * rv)
    song.track("crash", level=lv["crash"], reverb=0.1 * rv)
    song.track("fx", level=lv["fx"], reverb=0.2 * rv)
    song.track("impact", level=lv["impact"], reverb=0.2 * rv)


def beat(song: Song, bar: int, nbars: int, k: dict, pats: dict[str, str], vel: float = 1.0, humanize: float = 0.002,
         fill: dict[str, str] | None = None) -> None:
    """Main pattern over nbars; when `fill` is given, the last bar uses the fill patterns instead
    (tracks missing from the fill fall silent in that bar)."""
    main_bars = nbars - (1 if fill else 0)
    if main_bars > 0:
        song.drums(bar, main_bars, {t: (p, k[t]) for t, p in pats.items()}, vel, humanize)
    if fill:
        song.drums(bar + main_bars, 1, {t: (p, k[t]) for t, p in fill.items() if t in k}, vel, humanize)
        if "tom" in fill:
            tom_fill(song, bar + main_bars, fill["tom"], vel)


def tom_fill(song: Song, bar: int, pattern: str, vel: float = 1.0) -> None:
    """Tom pattern: h/m/l/f per step (uppercase = accent), '.' rest."""
    for i, c in enumerate(pattern.replace(" ", "").replace("|", "")):
        if c == ".":
            continue
        name = {"h": "hi", "m": "mid", "l": "low", "f": "floor"}[c.lower()]
        song.hit("tom", bar, i, drums.tom(TOMS[name], variant=i % 4), vel * (1.0 if c.isupper() else 0.75))


def crash(song: Song, bar: float, vel: float = 0.9, step: float = 0.0) -> None:
    song.hit("crash", bar, step, drums.crash(variant=int(bar) % 4), vel)


def snare_roll(song: Song, bar: int, nbars: int, v0: float = 0.25, v1: float = 1.0, double_last: bool = True) -> None:
    """16th-note snare build with a crescendo; the final bar doubles to 32nds."""
    total = nbars * song.steps_per_bar
    for s in range(total):
        v = v0 + (v1 - v0) * (s / max(1, total - 1)) ** 1.5
        song.hit("snare", bar, s, drums.snare(variant=s % 4), v)
        if double_last and s >= total - song.steps_per_bar:
            song.hit("snare", bar, s + 0.5, drums.snare(variant=(s + 1) % 4), v * 0.8)


def riser(song: Song, end_bar: float, nbars: float, vel: float = 0.9, seed: int = 0, tonal: float | None = None) -> None:
    dur = nbars * song.beats_per_bar * song.beat
    song.hit("fx", end_bar - nbars, 0, drums.riser(dur, seed=seed, tonal=tonal), vel)


def impact(song: Song, bar: float, vel: float = 0.9) -> None:
    song.hit("impact", bar, 0, drums.impact(), vel)


def loop_meta(song: Song, notes: str) -> dict:
    """Manifest metadata for a looping track. Engines that support loop offsets play [0, end) once and then loop
    [loop_offset, end)."""
    off = song.pos(song.loop_start)
    return {"loop": True, "bpm": song.bpm, "bars": song.bars, "sections": song.sections,
            "loop_start_bar": song.loop_start, "loop_offset_samples": off, "loop_offset_s": round(off / SR, 6),
            "notes": notes}


class Track:
    """Looping music module wrapper: build() -> (audio, metadata)."""

    def __init__(self, compose, notes: str, tail: float = 4.0, target_lufs: float = -14.0,
                 reverb_params: dict | None = None):
        self.compose, self.notes, self.tail = compose, notes, tail
        self.target_lufs, self.reverb_params = target_lufs, reverb_params

    def build(self):
        s = self.compose()
        audio = render(s, tail=self.tail, target_lufs=self.target_lufs, reverb_params=self.reverb_params)
        return audio, loop_meta(s, self.notes)


class Jingle:
    """One-shot cue: renders the song, cuts it to `length` seconds and fades the ring-out."""

    def __init__(self, compose, length: float, notes: str, fade_out: float = 0.8, target_lufs: float = -14.0):
        self.compose, self.length, self.notes = compose, length, notes
        self.fade_out, self.target_lufs = fade_out, target_lufs

    def build(self):
        s = self.compose()
        audio = render(s, tail=2.5, target_lufs=self.target_lufs, reverb_params={"room": 0.8, "damp": 0.4})
        audio = fade(audio[: samples(self.length)], 0.0, self.fade_out)
        return audio, {"loop": False, "bpm": s.bpm, "bars": s.bars, "notes": self.notes}
