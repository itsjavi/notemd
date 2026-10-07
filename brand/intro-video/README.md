# NoteMD intro video

A 42-second product intro, built and rendered entirely from code: motion graphics in HTML/CSS driven by one paused
[GSAP](https://gsap.com) timeline, warm electronic music and UI sound effects synthesized in Python, synced through a
shared cue list.

```bash
pnpm install
pnpm render   # -> ../../web/assets/intro.mp4 and intro-poster.jpg
pnpm stills   # PNG stills of key moments -> build/stills/ (quick layout checks)
```

Needs Google Chrome (or `CHROME_PATH`), `ffmpeg` and [`uv`](https://docs.astral.sh/uv/) (it installs numpy, scipy and
soundfile for the audio scripts on first run).

## How it works

| File                  | Role                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------ |
| `index.html`          | The 1920×1080 stage: logo, headline, feature scenes and outro, using the screenshots in `web/assets/`. |
| `stage.css`           | Layout and look, in the website's dark palette. No CSS animations.                                     |
| `timeline.js`         | The GSAP timeline, per-frame dynamics (typing, waveform, counters) and the SFX cue list.               |
| `render.mjs`          | Seeks the page frame by frame in headless Chrome, encodes with ffmpeg, renders the audio, muxes.       |
| `audio/score.py`      | The score: 100 BPM, D major, one scene per bar line (a bar is 2.4 s).                                  |
| `audio/sfx.py`        | Sound effect recipes (chime, pop, key taps, whoosh, ticks, sparkle, record, click).                    |
| `audio/style.py`      | The sonic identity every SFX reads from: key, sources, brightness, room.                               |
| `audio/soundtrack.py` | Renders the score, places every cue from `build/cues.json`, masters to -16 LUFS.                       |

Rendering is deterministic: every animated value is a function of time, so `video.seek(t)` always draws the same
frame and the sound effects land on the exact frames that trigger them. To retime something, move it in
`timeline.js`; its cue moves with it. To change the music, edit `audio/score.py` and keep scene starts on bar lines.

`build/` holds intermediates (silent video, cues, soundtrack WAV, waveform and spectrogram PNGs) and is not committed.

## Credits

Music and sound effects are procedurally generated (no samples) with a small synthesis toolkit vendored in `audio/`:
PolyBLEP oscillators (Välimäki et al.), RBJ Audio EQ Cookbook biquads, Freeverb (Jezar, public domain), ITU-R
BS.1770-4 loudness metering, Chowning FM synthesis and Paul Kellet's pink-noise filter.
