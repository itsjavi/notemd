"""Pattern sequencer: tempo grid with swing, step-pattern parsing, chords, voicings, grooves and arpeggios.

Step notation (one token per step, default step = a 16th note; '|' is ignored and only helps readability):

    C5        note for 1 step              C5:3      note lasting 3 steps
    -  -:2    tie: extend the previous note  .  .:4    rest
    modifiers after a note: ! accent, ? ghost/soft, ~ glide from previous note, ^ staccato, * dead/muted

Chord-relative tokens (grooves and riffs over the current chord):

    1 3 5 7 8 9 ...  chord degrees (3/5/7 follow the chord quality; others use the major scale)
    b7 #4 b3 ...     absolute alterations of the major-scale degree
    x                dead note on the root          <  >  chromatic approach to the next chord root
    a trailing ' raises one octave, , lowers one octave (e.g. 5, = fifth below the root)

Drum patterns: one char per step, X accent, x normal, o ghost, . rest.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import numpy as np

from core import SR, midi_to_freq, note_to_midi

# ---------------------------------------------------------------- music theory

CHORD_TYPES: dict[str, list[int]] = {
    "": [0, 4, 7], "maj": [0, 4, 7], "m": [0, 3, 7], "5": [0, 7],
    "6": [0, 4, 7, 9], "m6": [0, 3, 7, 9], "69": [0, 4, 7, 9, 14],
    "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10], "mmaj7": [0, 3, 7, 11],
    "9": [0, 4, 7, 10, 14], "maj9": [0, 4, 7, 11, 14], "m9": [0, 3, 7, 10, 14],
    "add9": [0, 4, 7, 14], "madd9": [0, 3, 7, 14], "11": [0, 4, 7, 10, 14, 17], "m11": [0, 3, 7, 10, 14, 17],
    "13": [0, 4, 7, 10, 14, 21], "maj7#11": [0, 4, 7, 11, 18],
    "sus2": [0, 2, 7], "sus4": [0, 5, 7], "7sus4": [0, 5, 7, 10], "9sus4": [0, 5, 7, 10, 14],
    "dim": [0, 3, 6], "dim7": [0, 3, 6, 9], "m7b5": [0, 3, 6, 10], "aug": [0, 4, 8],
    "7#9": [0, 4, 7, 10, 15], "7b9": [0, 4, 7, 10, 13],
}
_PC = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
_CHORD_RE = re.compile(r"^([A-G])([#b]?)([^/]*)(?:/([A-G][#b]?))?$")
_MAJOR = [0, 2, 4, 5, 7, 9, 11]


def _pc(name: str) -> int:
    return (_PC[name[0]] + name[1:].count("#") - name[1:].count("b")) % 12


@dataclass(frozen=True)
class Chord:
    name: str
    root: int  # pitch class
    intervals: tuple[int, ...]
    bass: int  # pitch class of the bass note (slash chords)

    @staticmethod
    def parse(name: str) -> "Chord":
        m = _CHORD_RE.match(name)
        if not m:
            raise ValueError(f"bad chord {name!r}")
        letter, acc, quality, bass = m.groups()
        if quality not in CHORD_TYPES:
            raise ValueError(f"unknown chord quality {quality!r} in {name!r}")
        root = _pc(letter + acc)
        return Chord(name, root, tuple(CHORD_TYPES[quality]), _pc(bass) if bass else root)

    def pcs(self) -> list[int]:
        return sorted({(self.root + i) % 12 for i in self.intervals})

    def degree(self, d: int, alter: int = 0) -> int:
        """Semitones above the root for chord degree d (1-based). 3/5/7 follow chord quality unless altered."""
        octave, idx = divmod(d - 1, 7)
        if alter == 0:
            ivs = [i % 12 for i in self.intervals]
            if idx == 2:  # third (or sus)
                for c in (4, 3, 5, 2):
                    if c in ivs:
                        return c + 12 * octave
            if idx == 4:  # fifth
                for c in (7, 6, 8):
                    if c in ivs:
                        return c + 12 * octave
            if idx == 6:  # seventh, default to the funky b7 when absent
                for c in (10, 11, 9):
                    if c in ivs:
                        return c + 12 * octave
                return 10 + 12 * octave
        return _MAJOR[idx] + alter + 12 * octave


def voicing(chord: Chord, center: int, spread: int = 12, drop_root: bool = False, max_notes: int = 5) -> list[int]:
    """Close voicing: each chord tone at the octave nearest `center` (midi), within +-spread."""
    tones = []
    for iv in chord.intervals[:max_notes]:
        if drop_root and iv % 12 == 0 and len(chord.intervals) >= 4:
            continue
        pc = (chord.root + iv) % 12
        base = center - ((center - pc) % 12)
        cand = min((base, base + 12), key=lambda m: abs(m - center))
        tones.append(int(np.clip(cand, center - spread, center + spread)))
    return sorted(set(tones))


# ---------------------------------------------------------------- pattern parsing

_TOKEN_RE = re.compile(r"^(.+?)(?::(\d+(?:\.\d+)?))?$")
_NOTE_TOK = re.compile(r"^([A-Ga-g][#b]?-?\d)([!?~^*]*)$")
_DEG_TOK = re.compile(r"^([b#]?)(\d+)(['\,]*)([!?~^*]*)$")


@dataclass
class Step:
    pos: float  # in steps from the pattern start
    length: float
    item: str
    mods: str = ""


def parse_steps(text: str) -> tuple[list[Step], float]:
    """Parse step notation into note steps. Returns (steps, total pattern length in steps)."""
    out: list[Step] = []
    pos = 0.0
    for tok in text.replace("|", " ").split():
        m = _TOKEN_RE.match(tok)
        item, ln = m.group(1), float(m.group(2) or 1)
        if item == "-":
            if out:
                out[-1].length += ln
        elif item == ".":
            pass
        else:
            mods = ""
            while item and item[-1] in "!?~^*" and len(item) > 1:
                mods = item[-1] + mods
                item = item[:-1]
            out.append(Step(pos, ln, item, mods))
        pos += ln
    return out, pos


def _vel_for(mods: str, vel: float) -> float:
    if "!" in mods:
        vel = min(1.0, vel * 1.18)
    if "?" in mods:
        vel *= 0.5
    return vel


# ---------------------------------------------------------------- song model


@dataclass
class Event:
    start: int
    dur: float
    midi: float = 0.0
    vel: float = 0.8
    pan: float = 0.0
    glide_from: float | None = None
    art: str | None = None
    sample: np.ndarray | None = None


@dataclass
class Track:
    name: str
    voice: object = None
    level: float | None = None  # target stem loudness (LUFS) used by the mixer
    gain_db: float = 0.0
    pan: float = 0.0
    reverb: float = 0.0
    delay: float = 0.0
    duck: float = 0.0
    width: float = 1.0
    inserts: list = field(default_factory=list)
    filter_auto: list = field(default_factory=list)  # (kind, [(sample, freq)], q)
    gain_auto: list = field(default_factory=list)  # [(sample, db)]
    sidechain_source: bool = False
    events: list[Event] = field(default_factory=list)


class Song:
    def __init__(self, name: str, bpm: float, bars: int, swing: float = 0.0, beats_per_bar: int = 4,
                 steps_per_beat: int = 4, seed: int = 0, loop: bool = True, loop_start: int = 0):
        """loop_start: bar where playback re-enters after the first pass (the intro before it plays once)."""
        self.name = name
        self.bpm = bpm
        self.bars = bars
        self.swing = swing
        self.beats_per_bar = beats_per_bar
        self.steps_per_beat = steps_per_beat
        self.steps_per_bar = beats_per_bar * steps_per_beat
        self.beat = 60.0 / bpm
        self.step = self.beat / steps_per_beat
        self.loop = loop
        self.loop_start = loop_start
        self.length = int(round(bars * beats_per_bar * self.beat * SR))
        self.tracks: dict[str, Track] = {}
        self.chord_map: list[tuple[float, Chord]] = []  # (absolute step, chord), sorted
        self.rng = np.random.default_rng(seed)
        self.sections: dict[str, int] = {}

    # ------------------------------------------------------------ time

    def abs_step(self, bar: float, step: float = 0.0) -> float:
        return bar * self.steps_per_bar + step

    def pos(self, bar: float, step: float = 0.0) -> int:
        """Sample index of (bar, step), applying swing to odd 16th steps."""
        s = self.abs_step(bar, step)
        whole = int(np.floor(s + 1e-9))
        if self.swing and whole % 2 == 1 and abs(s - whole) < 1e-9:
            s += self.swing
        return int(round(s * self.step * SR))

    def secs(self, steps: float) -> float:
        return steps * self.step

    # ------------------------------------------------------------ tracks

    def track(self, name: str, voice=None, **kw) -> Track:
        if name not in self.tracks:
            self.tracks[name] = Track(name, voice, **kw)
        return self.tracks[name]

    def add(self, track: str, bar: float, step: float, dur_steps: float, midi: float, vel: float = 0.8,
            pan: float = 0.0, glide_from: float | None = None, art: str | None = None, sample=None,
            offset: int = 0) -> None:
        start = self.pos(bar, step) + offset
        if self.loop:
            start %= self.length
        self.tracks[track].events.append(Event(start, self.secs(dur_steps), midi, vel, pan, glide_from, art, sample))

    # ------------------------------------------------------------ harmony

    def chords(self, bar: int, text: str) -> None:
        """Bars separated by '|'. Within a bar, chords split the bar evenly, or use Name:steps."""
        for i, bar_text in enumerate([b for b in text.split("|") if b.strip()]):
            toks = bar_text.split()
            explicit = [t for t in toks if ":" in t]
            each = self.steps_per_bar / len(toks)
            pos = 0.0
            for tok in toks:
                name, _, ln = tok.partition(":")
                ln_f = float(ln) if ln else (each if not explicit else self.steps_per_bar - pos)
                self.chord_map.append((self.abs_step(bar + i, pos), Chord.parse(name)))
                pos += ln_f
        self.chord_map.sort(key=lambda c: c[0])

    def _wrap_step(self, abs_step: float) -> float:
        total = self.bars * self.steps_per_bar
        return abs_step % total if self.loop else abs_step

    def chord_at(self, abs_step: float) -> Chord:
        cur = self.chord_map[0][1]
        for s, ch in self.chord_map:
            if s <= abs_step + 1e-9:
                cur = ch
            else:
                break
        return cur

    def next_chord_after(self, abs_step: float) -> Chord:
        cur = self.chord_at(abs_step)
        for s, ch in self.chord_map:
            if s > abs_step + 1e-9 and ch != cur:
                return ch
        return self.chord_map[0][1] if self.loop else cur

    # ------------------------------------------------------------ writers

    def notes(self, track: str, bar: float, text: str, vel: float = 0.8, transpose: int = 0, pan: float = 0.0,
              gate: float = 1.0, step_scale: float = 1.0) -> None:
        """Absolute-pitch melody in step notation starting at `bar`."""
        steps, _ = parse_steps(text)
        prev = None
        for st in steps:
            m = _NOTE_TOK.match(st.item + st.mods)
            if not m:
                raise ValueError(f"bad note token {st.item!r} in track {track}")
            midi = note_to_midi(m.group(1)) + transpose
            mods = m.group(2)
            ln = st.length * step_scale * (0.5 if "^" in mods else gate)
            art = "accent" if "!" in mods else ("stacc" if "^" in mods else ("mute" if "*" in mods else None))
            glide = midi_to_freq(prev) if ("~" in mods and prev is not None) else None
            self.add(track, bar, st.pos * step_scale, ln, midi, _vel_for(mods, vel), pan, glide, art)
            prev = midi

    def harmonize(self, track: str, bar: float, text: str, scale_root: str, degrees: int = -2, vel: float = 0.7,
                  pan: float = 0.0, transpose: int = 0, mode: list[int] | None = None) -> None:
        """Diatonic parallel harmony: shift each note of a melody by `degrees` scale steps (-2 = third below)."""
        mode = mode or _MAJOR
        root = _pc(scale_root)
        scale = sorted({(root + i) % 12 for i in mode})
        steps, _ = parse_steps(text)
        for st in steps:
            m = _NOTE_TOK.match(st.item + st.mods)
            midi = note_to_midi(m.group(1))
            pcs = [(midi // 12) * 12 + p + o for o in (-12, 0, 12) for p in scale]
            pcs.sort()
            # nearest scale tone at or below (chromatic notes snap down)
            idx = max(i for i, p in enumerate(pcs) if p <= midi)
            h = pcs[idx + degrees]
            # Avoid a minor-ninth rub against the chord: fall back to the nearest chord tone a third or more below.
            ch = self.chord_at(self.abs_step(bar, st.pos))
            cps = ch.pcs()
            if any((h - c) % 12 == 1 for c in cps) and h % 12 not in cps:
                h = max(m for m in range(midi - 12, midi - 2) if m % 12 in cps)
            self.add(track, bar, st.pos, st.length, h + transpose, _vel_for(m.group(2), vel), pan)

    def groove(self, track: str, bar: int, nbars: int, text: str, octave: int = 2, vel: float = 0.85,
               gate: float = 0.9, pan: float = 0.0, low: int | None = None) -> None:
        """Chord-relative line repeated over nbars, following the chord map. Roots sit in `octave`
        (MIDI octave numbering, C2 = 36), folded so that the root stays >= `low` when given."""
        steps, plen = parse_steps(text)
        total = nbars * self.steps_per_bar
        rep = 0
        prev = None
        while rep * plen < total:
            for st in steps:
                p = rep * plen + st.pos
                if p >= total:
                    break
                a = self.abs_step(bar, p)
                ch = self.chord_at(a)
                root = 12 * (octave + 1) + ch.bass
                if low is not None and root < low:
                    root += 12
                art = None
                mods = st.mods
                if st.item == "x":
                    midi, art = root, "mute"
                elif st.item in ("<", ">"):
                    nxt = self.chord_at(self._wrap_step(a + st.length))
                    target = 12 * (octave + 1) + nxt.bass
                    if low is not None and target < low:
                        target += 12
                    midi = target - 1 if st.item == "<" else target + 1
                else:
                    m = _DEG_TOK.match(st.item + mods)
                    if not m:
                        raise ValueError(f"bad groove token {st.item!r}")
                    acc, deg, octs, mods = m.groups()
                    alter = {"": 0, "b": -1, "#": 1}[acc]
                    d = int(deg)
                    if d == 1 and not alter:
                        midi = root
                    else:
                        # other degrees are relative to the chord root (which differs from the bass on slash chords)
                        midi = root - ch.bass + ch.root + ch.degree(d, alter)
                        if ch.bass != ch.root and midi < root:
                            midi += 12
                    midi += 12 * octs.count("'") - 12 * octs.count(",")
                if "*" in mods:
                    art = "mute"
                elif "!" in mods:
                    art = "accent"
                glide = midi_to_freq(prev) if ("~" in mods and prev is not None) else None
                ln = st.length * (0.5 if "^" in mods else gate)
                self.add(track, bar, p, ln, midi, _vel_for(mods, vel), pan, glide, art)
                prev = midi
            rep += 1

    def comp(self, track: str, bar: int, nbars: int, rhythm: str, center: int = 64, vel: float = 0.7,
             gate: float = 0.8, drop_root: bool = True, spread: int = 9, strum: float = 0.0,
             max_notes: int = 5) -> None:
        """Chord stabs on a rhythm (step notation with any note-ish token, e.g. 'x', or 'X' for accent)."""
        steps, plen = parse_steps(rhythm)
        total = nbars * self.steps_per_bar
        rep = 0
        while rep * plen < total:
            for st in steps:
                p = rep * plen + st.pos
                if p >= total:
                    break
                ch = self.chord_at(self.abs_step(bar, p))
                v = vel * (1.15 if st.item == "X" else (0.55 if st.item == "o" else 1.0))
                for k, m in enumerate(voicing(ch, center, spread, drop_root, max_notes)):
                    self.add(track, bar, p + k * strum, st.length * gate, m, min(v, 1.0))
            rep += 1

    def sustain_chords(self, track: str, bar: int, nbars: int, center: int = 60, vel: float = 0.6,
                       drop_root: bool = False, spread: int = 10, legato: float = 1.02, max_notes: int = 5) -> None:
        """One held voicing per chord change (pads)."""
        start, end = self.abs_step(bar), self.abs_step(bar + nbars)
        marks = [s for s, _ in self.chord_map if start <= s < end]
        if not marks or marks[0] > start:
            marks = [start] + marks
        marks.append(end)
        for a, b in zip(marks[:-1], marks[1:]):
            ch = self.chord_at(a)
            for m in voicing(ch, center, spread, drop_root, max_notes):
                self.add(track, 0, a, (b - a) * legato, m, vel)

    def arp(self, track: str, bar: int, nbars: int, rate: float = 1.0, mode: str = "up", octaves: int = 2,
            center: int = 64, vel: float = 0.6, gate: float = 0.6, accents: str = "", pan_spread: float = 0.0) -> None:
        """Arpeggiate the current chord. rate = steps per note; modes: up, down, updown, random, pingpong."""
        total = nbars * self.steps_per_bar
        p, i = 0.0, 0
        while p < total - 1e-9:
            ch = self.chord_at(self.abs_step(bar, p))
            base = voicing(ch, center, 7, False, 4)
            seq = [m + 12 * o for o in range(octaves) for m in base]
            if mode == "down":
                seq = seq[::-1]
            elif mode in ("updown", "pingpong"):
                seq = seq + seq[-2:0:-1]
            if mode == "random":
                m = seq[self.rng.integers(len(seq))]
            else:
                m = seq[i % len(seq)]
            v = vel
            if accents:
                c = accents[i % len(accents)]
                v *= {"X": 1.15, "x": 1.0, "o": 0.6, ".": 0.0}.get(c, 1.0)
            if v > 0:
                pn = pan_spread * np.sin(i * 0.9)
                self.add(track, bar, p, rate * gate, m, min(v, 1.0), pn)
            p += rate
            i += 1

    def drums(self, bar: int, nbars: int, patterns: dict[str, tuple[str, callable]], vel: float = 1.0,
              humanize: float = 0.0) -> None:
        """patterns: track -> (step string, hit factory(variant) -> array). Patterns repeat to fill nbars.
        humanize = timing jitter standard deviation in seconds."""
        total = int(nbars * self.steps_per_bar)
        for track, (pat, make) in patterns.items():
            pat = pat.replace("|", "").replace(" ", "")
            for p in range(total):
                c = pat[p % len(pat)]
                if c == ".":
                    continue
                v = vel * {"X": 1.0, "x": 0.82, "o": 0.42, "O": 0.6}[c]
                variant = int(self.rng.integers(4))
                jitter = int(self.rng.normal(0, humanize) * SR) if humanize else 0
                self.add(track, bar, p, 1, 0, v, sample=make(variant), offset=jitter)

    def hit(self, track: str, bar: float, step: float, sample: np.ndarray, vel: float = 1.0) -> None:
        self.add(track, bar, step, 1, 0, vel, sample=sample)

    # ------------------------------------------------------------ automation

    def filter_sweep(self, track: str, kind: str, points: list[tuple[float, float]], q: float = 0.707) -> None:
        """points: (bar position as float, cutoff Hz). Interpolated exponentially between points."""
        self.tracks[track].filter_auto.append((kind, [(self.pos(b), f) for b, f in points], q))

    def gain_ramp(self, track: str, points: list[tuple[float, float]]) -> None:
        """points: (bar position, dB)."""
        self.tracks[track].gain_auto.extend((self.pos(b), db) for b, db in points)

    def section(self, name: str, bar: int) -> int:
        self.sections[name] = bar
        return bar
