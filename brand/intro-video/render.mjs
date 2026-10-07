// Renders the intro: seeks the page frame by frame in headless Chrome, pipes the frames into ffmpeg, renders the
// soundtrack from the exported SFX cues, then muxes the result into web/assets.
//
//   node render.mjs                      full render -> ../../web/assets/intro.mp4 + intro-poster.jpg
//   node render.mjs --stills 1.2,12.6    PNG stills of those seconds -> build/stills/ (fast layout checks)
//
// Needs Google Chrome (or CHROME_PATH), ffmpeg and uv on PATH.

import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import puppeteer from "puppeteer-core";

const HERE = dirname(fileURLToPath(import.meta.url));
const BUILD = resolve(HERE, "build");
const ASSETS = resolve(HERE, "../../web/assets");
const CHROME =
  process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const POSTER_AT = 12.6; // app reveal with its caption
const WIDTH = 1920;
const HEIGHT = 1080;

function run(cmd, args, options = {}) {
  const child = spawn(cmd, args, { stdio: ["pipe", "inherit", "inherit"], ...options });
  const done = once(child, "exit").then(([code]) => {
    if (code !== 0) throw new Error(`${cmd} exited with ${code}`);
  });
  return { child, done };
}

async function openStage() {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ["--hide-scrollbars", "--force-color-profile=srgb", "--allow-file-access-from-files"],
    defaultViewport: { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1 },
  });
  const page = await browser.newPage();
  page.on("pageerror", (error) => console.error("page error:", error.message));
  await page.goto(pathToFileURL(resolve(HERE, "index.html")).href, { waitUntil: "load" });
  await page.evaluate(() => window.video.ready);
  const meta = await page.evaluate(() => ({
    fps: video.fps,
    duration: video.duration,
    cues: video.cues,
  }));
  return { browser, page, meta };
}

async function frame(page, t) {
  await page.evaluate((time) => window.video.seek(time), t);
  return page.screenshot({
    type: "png",
    optimizeForSpeed: true,
    clip: { x: 0, y: 0, width: WIDTH, height: HEIGHT },
  });
}

async function stills(times) {
  const { browser, page } = await openStage();
  await mkdir(resolve(BUILD, "stills"), { recursive: true });
  for (const t of times) {
    const file = resolve(BUILD, "stills", `t${t.toFixed(1).padStart(4, "0")}.png`);
    await writeFile(file, await frame(page, t));
    console.log(file);
  }
  await browser.close();
}

async function render() {
  await mkdir(BUILD, { recursive: true });
  const { browser, page, meta } = await openStage();
  const cuesFile = resolve(BUILD, "cues.json");
  await writeFile(cuesFile, JSON.stringify(meta.cues, null, 2));

  const silent = resolve(BUILD, "video.mp4");
  const encoder = run("ffmpeg", [
    "-loglevel",
    "error",
    "-y",
    "-f",
    "image2pipe",
    "-framerate",
    String(meta.fps),
    "-i",
    "-",
    "-c:v",
    "libx264",
    "-preset",
    "slow",
    "-crf",
    "20",
    "-pix_fmt",
    "yuv420p",
    "-movflags",
    "+faststart",
    silent,
  ]);
  const total = Math.round(meta.duration * meta.fps);
  const posterFrame = Math.round(POSTER_AT * meta.fps);
  const started = Date.now();
  for (let i = 0; i < total; i++) {
    const png = await frame(page, i / meta.fps);
    if (i === posterFrame) await writeFile(resolve(BUILD, "poster.png"), png);
    if (!encoder.child.stdin.write(png)) await once(encoder.child.stdin, "drain");
    if (i % meta.fps === 0)
      process.stdout.write(
        `\rframes ${i}/${total}  ${((Date.now() - started) / 1000).toFixed(0)}s`,
      );
  }
  encoder.child.stdin.end();
  await encoder.done;
  await browser.close();
  console.log(`\rframes ${total}/${total}  ${((Date.now() - started) / 1000).toFixed(0)}s`);

  const soundtrack = resolve(BUILD, "soundtrack.wav");
  await run("uv", [
    "run",
    resolve(HERE, "audio/soundtrack.py"),
    "--cues",
    cuesFile,
    "--duration",
    String(meta.duration),
    "--out",
    soundtrack,
    "--review",
    resolve(BUILD, "review"),
  ]).done;

  await mkdir(ASSETS, { recursive: true });
  await run("ffmpeg", [
    "-loglevel",
    "error",
    "-y",
    "-i",
    silent,
    "-i",
    soundtrack,
    "-map",
    "0:v",
    "-map",
    "1:a",
    "-c:v",
    "copy",
    "-c:a",
    "aac",
    "-b:a",
    "160k",
    "-shortest",
    "-movflags",
    "+faststart",
    resolve(ASSETS, "intro.mp4"),
  ]).done;
  await run("ffmpeg", [
    "-loglevel",
    "error",
    "-y",
    "-i",
    resolve(BUILD, "poster.png"),
    "-q:v",
    "3",
    resolve(ASSETS, "intro-poster.jpg"),
  ]).done;
  console.log(`wrote ${resolve(ASSETS, "intro.mp4")} and intro-poster.jpg`);
}

const stillsArg = process.argv.indexOf("--stills");
if (stillsArg > 0) await stills(process.argv[stillsArg + 1].split(",").map(Number));
else await render();
