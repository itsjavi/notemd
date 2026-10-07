# Public presentation: README, website, social card and intro video

Everything people see before installing NoteMD. Keep it in sync with the app: when a feature ships or the UI changes
substantially, update the affected pieces in the same task (the rule lives in [AGENTS.md](../AGENTS.md)).

| What        | Where                                               | Shows                                                      |
| ----------- | --------------------------------------------------- | ---------------------------------------------------------- |
| README      | `README.md`                                         | Pitch, feature list, screenshot table, requirements, build |
| Website     | `web/index.html`, `web/styles.css`                  | Hero, video, why, feature rows, details grid, build steps  |
| Screenshots | `web/assets/*.webp`                                 | Used by both the README and the website                    |
| Social card | `scripts/og-image.html` → `web/assets/og-image.jpg` | Hero icon, headline, intro text and the dark screenshot    |
| Intro video | `brand/intro-video/` → `web/assets/intro.mp4`       | Scenes per feature, music and SFX generated in code        |

The website deploys to https://itsjavi.com/notemd/ on every push to `main` that touches `web/`
(`.github/workflows/pages.yml`).

## What to update

| Change                                   | README          | Website                     | Screenshots              | Video                              |
| ---------------------------------------- | --------------- | --------------------------- | ------------------------ | ---------------------------------- |
| New user-facing feature                  | feature bullet  | feature row or details card | add one if it is visible | scene if headline-worthy           |
| Substantial UI change (layout, toolbar…) | if text changed | if text changed             | recapture affected shots | re-render (scenes use screenshots) |
| Feature removed or renamed               | remove / rename | remove / rename             | recapture                | remove or fix the scene            |
| Hero screenshot or tagline changed       | –               | hero                        | `screenshot-*.webp`      | re-render; also the social card    |

Never leave published copy, screenshots or video showing UI that no longer exists. If a change needs none of this,
say why in the task notes.

## Screenshots

Captured from the agents' Test build (never the user's app) with a curated demo vault, so they are reproducible:

```bash
make test-app
scripts/demo-vault.sh                     # /private/tmp/notemd-demo/Notes + files/Scratch pad.txt
open -g "build/NoteMD Test.app"
H() { open -g -a "$PWD/build/NoteMD Test.app" "notemd-test://$1"; sleep 1; }
R=repo=notemd-demo/Notes
H "ui/open-repo?path=/private/tmp/notemd-demo/Notes"
H "ui/appearance?value=light&$R"; H "ui/window-size?w=1440&h=900&$R"; H "ui/mode?value=split&$R"
H "ui/select?note=Work/Q4%20Roadmap.md&$R"
swift scripts/window-screenshot.swift "NoteMD Test" /private/tmp/shot
```

Current shots and how they were taken (window 1440×900 for the hero, 1280×800 for the rest):

| File                    | Setup                                                                             |
| ----------------------- | --------------------------------------------------------------------------------- |
| `screenshot-light/dark` | All Notes, split mode, `Work/Q4 Roadmap.md`, light and dark appearance            |
| `version-history`       | `Work/Q4 Roadmap.md`, `ui/sheet?name=history`                                     |
| `template-form`         | `Prompts/Code Review Prompt.md`, `ui/sheet?name=form`                             |
| `voice-note`            | preview mode, `Journal/Onboarding idea.md`                                        |
| `video-review`          | preview mode, `Work/Onboarding review.md`                                         |
| `text-editor`           | `ui/open-file?path=/private/tmp/notemd-demo/files/Scratch%20pad.txt`, top 1000 px |

Convert and size them like the existing files:

```bash
cwebp -q 86 -m 6 -resize 2400 0 shot.png -o web/assets/screenshot-light.webp   # hero: 2400 wide
cwebp -q 86 -m 6 -resize 1600 0 shot.png -o web/assets/version-history.webp    # others: 1600 wide
```

Gotchas:

- The script captures every Test-build window, including other recent repositories it reopened at launch. Pick the
  file whose window title and size match, or check the image.
- Hooks take their query after `?`: `ui/close-sheet?repo=…`, not `ui/close-sheet&repo=…` (silently ignored).
- Sheets are captured as their own window, already composited over the dimmed parent.
- After `ui/appearance`, select another note and back so the preview re-renders in the new appearance.
- The template form remembers the last values per template: quit the Test build and run
  `defaults delete com.itsjavi.notemd.test "templateValues:<template path>"` to show the defaults again.
- Test-build windows are never key, so traffic lights look inactive. Acceptable; a Dev-build capture by a human
  looks slightly better.

## Social card

Edit `scripts/og-image.html` and re-render with the command in its header comment (headless Chrome, 2x, then JPEG).

## Intro video

See [intro-video/README.md](intro-video/README.md): `pnpm install && pnpm render` in `brand/intro-video/`. Scenes
start on bar lines of the score (2.4 s per bar); add, remove or retime scenes in `timeline.js` and `index.html`, and
check them with `pnpm stills` before the full render. A re-render adds a new MP4 (about 7 MB) to git history, so batch
video changes rather than re-rendering for every small tweak.
