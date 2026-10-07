/* global gsap */
// NoteMD intro: one paused GSAP timeline plus per-frame "dynamics" (typing, waveform, counters), all pure functions
// of time, so render.mjs can seek frame by frame. SFX cues are collected next to the motion they belong to and
// exported for audio/soundtrack.py. Scenes start on bar lines of the 100 BPM score (audio/score.py).

const BAR = 2.4;
const DURATION = 42;
const FPS = 30;

const $ = (id) => document.getElementById(id);
const tl = gsap.timeline({ paused: true, defaults: { ease: "power3.out" } });
const cues = [];
const dynamics = [];

function cue(t, name, gain = 0) {
  cues.push({ t: Math.round(t * 1000) / 1000, name, gain });
}

function enter(target, at, from = { y: 40 }, vars = {}) {
  tl.fromTo(
    target,
    { opacity: 0, ...from },
    { opacity: 1, x: 0, y: 0, scale: 1, duration: 0.7, ...vars },
    at,
  );
}

/** Types `text` into `el` from `start`, one character every `perChar` seconds, with a key tap per character. */
function typer(el, text, start, perChar, keyGain = 0) {
  [...text].forEach((ch, i) => ch !== " " && cue(start + i * perChar, "key", keyGain));
  dynamics.push((t) => {
    const n = t < start ? 0 : Math.min(text.length, Math.floor((t - start) / perChar) + 1);
    el.textContent = text.slice(0, n);
  });
  return start + text.length * perChar;
}

/** Caret shown from `from` to `to`: solid while typing (`typing` intervals), blinking otherwise. */
function caret(el, from, to, typing) {
  dynamics.push((t) => {
    const active = typing.some(([a, b]) => t >= a && t <= b + 0.1);
    const blinkOn = (t * 2.2) % 1 < 0.55;
    el.style.opacity = t >= from && t <= to && (active || blinkOn) ? 1 : 0;
  });
}

// ---------------------------------------------------------------- ambience

tl.fromTo(".glow-top", { x: -90 }, { x: 90, duration: DURATION, ease: "none" }, 0);
tl.fromTo(".glow-bottom", { x: 70 }, { x: -70, duration: DURATION, ease: "none" }, 0);
tl.fromTo("#blackout", { opacity: 1 }, { opacity: 0, duration: 0.8, ease: "none" }, 0);

// ---------------------------------------------------------------- logo (bars 0-1)

const iconShadow = "drop-shadow(0px 30px 50px rgba(0, 0, 0, 0.55))";
tl.fromTo(
  "#brandIcon",
  { opacity: 0, scale: 0.6, filter: `blur(16px) ${iconShadow}` },
  { opacity: 1, scale: 1, filter: `blur(0px) ${iconShadow}`, duration: 1.1, ease: "expo.out" },
  0.3,
);
cue(0.3, "chime");
enter("#brandName", 1.2, { y: 30 });
cue(1.2, "pop");
tl.to("#brandIcon", { y: -12, duration: 2.6, ease: "sine.inOut" }, 1.6);
tl.to("#brand", { opacity: 0, scale: 0.92, y: -60, duration: 0.5, ease: "power2.in" }, 4.25);
cue(4.3, "whoosh", -4);

// ---------------------------------------------------------------- headline (bars 2-3)

const line1End = typer($("line1"), "Markdown notes,", 4.85, 0.065);
const line2Start = line1End + 0.22;
const line2End = typer($("line2"), "versioned automatically.", line2Start, 0.052);
caret($("caret1"), 4.6, line1End + 0.12, [[4.85, line1End]]);
caret($("caret2"), line1End + 0.12, 9.0, [[line2Start, line2End]]);
enter("#status", 7.65, { y: 20, scale: 0.9 }, { duration: 0.5, ease: "back.out(2)" });
cue(7.65, "pop");
tl.to("#headline", { opacity: 0, y: -70, duration: 0.5, ease: "power2.in" }, 9.05);

// ---------------------------------------------------------------- app reveal (bars 4-5)

{
  const start = 4 * BAR;
  const caption = "#reveal .caption";
  enter(`${caption} .eyebrow`, start, { y: 30 });
  enter(`${caption} .title`, start + 0.1, { y: 30 });
  enter("#revealSub", start + 2.3, { y: 20 });
  gsap.set("#revealShot", { transformOrigin: "8% 28%" });
  tl.fromTo(
    "#revealShot",
    { opacity: 0, y: 420, rotationX: 32, scale: 0.92 },
    { opacity: 1, y: 0, rotationX: 0, scale: 1, duration: 1.4 },
    start + 0.05,
  );
  cue(start, "whoosh");
  tl.to("#revealShot", { scale: 1.14, duration: 3.0, ease: "sine.inOut" }, start + 1.4);
  enter("#revealRing", start + 2.0, { scale: 1.25 }, { duration: 0.45, ease: "back.out(2)" });
  cue(start + 2.0, "pop");
  const end = start + 2 * BAR;
  tl.to(caption, { opacity: 0, y: -30, duration: 0.42, ease: "power2.in" }, end - 0.45);
  tl.to("#revealShot", { opacity: 0, x: -260, duration: 0.42, ease: "power2.in" }, end - 0.45);
}

// ---------------------------------------------------------------- features (bars 6-11)

/** Shared feature layout: caption on the left, screenshot sliding in from the right, a slow zoom to `focus`. */
function feature(id, start, { focus, zoom, zoomAt, zoomDur }) {
  const caption = `#${id} .caption`;
  const shot = `#${id} .shot`;
  gsap.set(shot, { transformOrigin: focus });
  tl.fromTo(caption, { opacity: 0 }, { opacity: 1, duration: 0.3, ease: "none" }, start);
  tl.fromTo(
    `${caption} > *`,
    { opacity: 0, y: 36 },
    { opacity: 1, y: 0, duration: 0.6, stagger: 0.12 },
    start,
  );
  tl.fromTo(
    shot,
    { opacity: 0, x: 280, rotationY: -22, scale: 0.94 },
    { opacity: 1, x: 0, rotationY: -8, scale: 1, duration: 1.1 },
    start + 0.1,
  );
  cue(start + 0.05, "whoosh", -3);
  tl.to(shot, { rotationY: 0, scale: zoom, duration: zoomDur, ease: "sine.inOut" }, zoomAt);
  const end = start + 2 * BAR;
  tl.to(caption, { opacity: 0, y: -30, duration: 0.42, ease: "power2.in" }, end - 0.45);
  tl.to(shot, { opacity: 0, x: -200, duration: 0.42, ease: "power2.in" }, end - 0.45);
  return end;
}

// Version history: walk the versions, then light up the diff.
{
  const start = 6 * BAR;
  feature("history", start, { focus: "66% 42%", zoom: 1.3, zoomAt: start + 2.9, zoomDur: 1.6 });
  enter("#historyRow", start + 1.2, {}, { duration: 0.25 });
  cue(start + 1.2, "tick");
  [36, 45.8, 26.2].forEach((top, i) => {
    tl.to(
      "#historyRow",
      { top: `${top}%`, duration: 0.3, ease: "power2.inOut" },
      start + 1.8 + i * 0.6,
    );
    cue(start + 1.8 + i * 0.6, "tick");
  });
  enter("#historyRing", start + 3.2, { scale: 1.08 }, { duration: 0.4 });
  cue(start + 3.2, "pop");
}

// Templates: type the prompt, fill the form, the placeholder becomes the value.
{
  const start = 10 * BAR;
  feature("templates", start, { focus: "62% 30%", zoom: 1.25, zoomAt: start + 2.4, zoomDur: 1.9 });
  const prefixEnd = typer($("codePrefix"), "# Code review: ", start + 0.55, 0.045, -5);
  const slotEnd = typer($("placeholder"), "{{project}}", prefixEnd + 0.02, 0.045, -5);
  caret($("caret3"), start + 0.4, start + 2.35, [[start + 0.55, slotEnd]]);
  enter("#templatesRing", start + 1.85, { scale: 1.2 }, { duration: 0.4, ease: "back.out(2)" });
  cue(start + 1.85, "pop");
  tl.to("#placeholder", { opacity: 0, duration: 0.2, ease: "none" }, start + 2.4);
  enter("#value", start + 2.4, { scale: 0.7 }, { duration: 0.45, ease: "back.out(2.5)" });
  cue(start + 2.4, "sparkle");
}

// Voice notes: record, then transcribe on-device.
{
  const start = 8 * BAR;
  const end = feature("voice", start, {
    focus: "68% 30%",
    zoom: 1.32,
    zoomAt: start + 1.2,
    zoomDur: 3.0,
  });
  const recStart = start + 0.6;
  const recEnd = start + 2.4;
  const doneAt = start + 2.9;
  enter("#recorder", recStart, { y: 40, scale: 0.95 }, { duration: 0.5, ease: "back.out(1.6)" });
  cue(recStart, "record");
  tl.to("#recorder", { opacity: 0, y: -20, duration: 0.42, ease: "power2.in" }, end - 0.45);
  enter("#voiceRing", doneAt, { scale: 1.08 }, { duration: 0.4 });
  cue(doneAt, "pop");

  const wave = $("wave");
  const bars = Array.from({ length: 30 }, () => wave.appendChild(document.createElement("span")));
  const level = (i, t) => {
    const v = Math.abs(
      Math.sin(i * 1.7 + t * 9.1) * Math.sin(i * 0.53 + t * 4.3) + 0.35 * Math.sin(t * 13 + i),
    );
    return 0.12 + 0.88 * Math.min(1, v);
  };
  dynamics.push((t) => {
    const recording = t < recEnd;
    const frozen = Math.min(t, recEnd);
    bars.forEach((bar, i) => {
      bar.style.transform = `scaleY(${level(i, frozen).toFixed(3)})`;
      bar.style.opacity = recording ? 1 : 0.45;
    });
    const secs = Math.max(
      0,
      Math.min(5, Math.floor(((frozen - recStart) / (recEnd - recStart)) * 5)),
    );
    $("recTime").textContent = `0:0${secs}`;
    $("recLabel").textContent = recording
      ? "Recording"
      : t < doneAt
        ? "Transcribing…"
        : "Transcribed on this Mac";
    $("recDot").style.background = recording ? "var(--red)" : "var(--green)";
    $("recDot").style.opacity = recording && (t * 2) % 1 > 0.6 ? 0.35 : 1;
  });
}

// ---------------------------------------------------------------- how templates work (bars 12-14)

// Three steps left to right: the template source, the form it generates, the prompt you copy.
{
  const start = 12 * BAR;
  const end = 15 * BAR;
  enter("#explainerCaption .eyebrow", start, { y: 30 });
  enter("#explainerCaption .title", start + 0.1, { y: 30 });
  cue(start, "whoosh", -3);

  // 1. The template appears line by line.
  enter("#step1", start + 0.3);
  tl.fromTo(
    "#step1 .code-line",
    { opacity: 0, x: -14 },
    { opacity: 1, x: 0, duration: 0.25, stagger: 0.09 },
    start + 0.55,
  );
  document
    .querySelectorAll("#step1 .code-line")
    .forEach((_, i) => cue(start + 0.55 + i * 0.09, "key", -6));

  // 2. The form: pick a language, type the files, flip the toggle.
  tl.fromTo(
    "#arrow1",
    { scaleX: 0 },
    { scaleX: 1, duration: 0.3, ease: "power2.out" },
    start + 1.95,
  );
  enter("#step2", start + 2.05);
  cue(start + 2.05, "pop", -3);
  const languageAt = start + 2.5;
  tl.fromTo(
    "#formLanguage",
    { scale: 1.1 },
    { scale: 1, duration: 0.3, immediateRender: false },
    languageAt,
  );
  cue(languageAt, "tick");
  const filesStart = start + 2.75;
  const filesEnd = typer(
    $("formFiles"),
    "Sources/Editor.swift\nSources/Preview.swift",
    filesStart,
    0.028,
    -8,
  );
  caret($("caret4"), filesStart - 0.1, filesEnd + 0.15, [[filesStart, filesEnd]]);
  const toggleAt = start + 4.1;
  tl.to("#formKnob", { x: 32, duration: 0.25, ease: "power2.inOut" }, toggleAt);
  tl.to("#formSwitch", { backgroundColor: "#2c9a93", duration: 0.25, ease: "none" }, toggleAt);
  cue(toggleAt, "tick");

  // 3. The prompt fills in with the values, then gets copied.
  tl.fromTo(
    "#arrow2",
    { scaleX: 0 },
    { scaleX: 1, duration: 0.3, ease: "power2.out" },
    start + 4.3,
  );
  enter("#step3", start + 4.4);
  cue(start + 4.4, "pop", -3);
  ["#out1", "#out2", "#out3", "#out4"].forEach((line, i) => {
    enter(line, start + 4.7 + i * 0.25, { x: -14, y: 0 }, { duration: 0.3 });
    cue(start + 4.7 + i * 0.25, "tick");
  });
  const copyAt = start + 5.95;
  tl.to("#copyButton", { scale: 0.92, duration: 0.08, ease: "power1.in" }, copyAt);
  tl.to("#copyButton", { scale: 1, duration: 0.3, ease: "back.out(3)" }, copyAt + 0.08);
  tl.to("#copyButton", { backgroundColor: "#3fb950", duration: 0.2, ease: "none" }, copyAt + 0.05);
  cue(copyAt, "click");
  cue(copyAt + 0.05, "sparkle", -2);

  dynamics.push((t) => {
    const picked = t >= languageAt;
    $("formLanguageValue").textContent = picked ? "Swift" : "Choose…";
    $("formLanguage").style.color = picked ? "var(--text)" : "var(--muted)";
    $("copyLabel").textContent = t >= copyAt + 0.05 ? "Copied ✓" : "Copy";
  });

  tl.to(
    ["#explainerCaption", "#explainer .steps"],
    { opacity: 0, y: -30, duration: 0.42, ease: "power2.in" },
    end - 0.45,
  );
}

// ---------------------------------------------------------------- outro (bars 15-16)

{
  const start = 15 * BAR;
  tl.fromTo(
    "#outroIcon",
    { opacity: 0, scale: 0.5, filter: `blur(14px) ${iconShadow}` },
    { opacity: 1, scale: 1, filter: `blur(0px) ${iconShadow}`, duration: 1.0, ease: "expo.out" },
    start,
  );
  cue(start, "chime");
  enter("#outroName", start + 0.55, { y: 30 });
  cue(start + 0.55, "pop");
  enter("#outroTagline", start + 0.9, { y: 24 });
  enter("#outroMeta", start + 1.5, { y: 24 });
  cue(start + 1.5, "pop", -2);
  tl.to("#blackout", { opacity: 1, duration: 1.0, ease: "none" }, DURATION - 1.0);
}

// ---------------------------------------------------------------- API for render.mjs

const images = [...document.images].map((img) => img.decode().catch(() => {}));

window.video = {
  fps: FPS,
  duration: DURATION,
  cues: cues.sort((a, b) => a.t - b.t),
  ready: Promise.all([document.fonts.ready, ...images]).then(() => true),
  seek(t) {
    tl.seek(t);
    for (const update of dynamics) update(t);
  },
};
window.video.seek(0);
