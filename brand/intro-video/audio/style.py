"""NoteMD intro sonic identity: warm, soft, close. D major (the score's home key), glass-and-paper UI sounds
built from sines, FM and filtered noise, slightly dark, a small shared room. Every SFX recipe reads from STYLE."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

import fx
from core import midi_to_freq, note_to_midi

MAJOR = (0, 2, 4, 5, 7, 9, 11)
MINOR = (0, 2, 3, 5, 7, 8, 10)
DORIAN = (0, 2, 3, 5, 7, 9, 10)
LYDIAN = (0, 2, 4, 6, 7, 9, 11)
MAJOR_PENTATONIC = (0, 2, 4, 7, 9)
MINOR_PENTATONIC = (0, 3, 5, 7, 10)


@dataclass(frozen=True)
class Style:
    key: str = "C"  # home key root (shared with the music); reward/UI pitches come from tone()
    scale: tuple = MAJOR
    # Free-text palette decisions that recipes must follow (record the same words in the audio direction):
    sources: tuple = ("sine", "pulse", "noise")  # oscillator families: sine, pulse, saw, fm, supersaw, noise, karplus, chip
    material: str = "synthetic"  # transient character: glass, wood, metal, paper, water, stone, digital, organic...
    brightness: float = 1.0  # scales filter cutoffs: 0.5 dark/muffled .. 1.5 bright/close
    grit: float = 0.0  # 0 clean .. 1 crushed: saturation, then bit reduction above 0.5
    space: dict = field(default_factory=lambda: {"room": 0.4, "wet": 0.0})  # shared SFX room; wet 0 = dry
    width: float = 1.0  # stereo width of stereo SFX (0 mono .. 1.5 wide)
    pitch_bias: float = 0.0  # semitones added to every tuned SFX: lower = heavier/bigger, higher = smaller/cuter

    def tone(self, degree: int, octave: int = 5) -> float:
        """Frequency of a 1-based scale degree in the home key (degree 8 = next octave's root)."""
        d = degree - 1
        root = note_to_midi(f"{self.key}{octave}")
        midi = root + self.scale[d % len(self.scale)] + 12 * (d // len(self.scale))
        return midi_to_freq(midi + self.pitch_bias)

    def hz(self, freq: float) -> float:
        """Apply pitch_bias to an untuned frequency (sweeps, thumps)."""
        return freq * 2 ** (self.pitch_bias / 12)

    def cutoff(self, freq) -> np.ndarray | float:
        return np.clip(np.asarray(freq) * self.brightness, 40.0, 18000.0)

    def finish(self, x: np.ndarray) -> np.ndarray:
        """The signature chain shared by every SFX: call it at the end of each recipe."""
        y = x
        if self.grit > 0:
            y = fx.drive(y, 12.0 * self.grit)
        if self.grit > 0.5:
            y = fx.bitcrush(y, 12.0 - 12.0 * (self.grit - 0.5))
        if self.brightness < 1.0:
            y = fx.lowpass(y, 18000.0 * self.brightness)
        if self.space.get("wet", 0) > 0:
            y = fx.reverb(y, room=self.space.get("room", 0.4), wet=self.space["wet"], dry=1.0)
        if y.ndim == 2 and self.width != 1.0:
            y = fx.width(y, self.width)
        return y


STYLE = Style(
    key="D",
    scale=MAJOR,
    sources=("sine", "fm", "noise"),
    material="glass and paper",
    brightness=0.85,
    grit=0.0,
    space={"room": 0.55, "wet": 0.12},
    width=1.1,
    pitch_bias=0.0,
)
