#!/usr/bin/env bash
# Builds the curated demo vault used for the README, website and intro video screenshots (see brand/README.md).
# Usage: scripts/demo-vault.sh [dir] [clip-frame-image]
#   dir              defaults to /private/tmp/notemd-demo (Test-build hooks only accept temp folders);
#                    creates <dir>/Notes (the vault, with git history) and <dir>/files/Scratch pad.txt
#   clip-frame-image still used for the vault's demo screen recording (default: web/assets/screenshot-dark.webp)
# Extend it when a new feature needs demo content, so screenshots stay reproducible.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-/private/tmp/notemd-demo}"
FRAME="${2:-$ROOT/web/assets/screenshot-dark.webp}"
R="$DIR/Notes"
rm -rf "$R" "$DIR/files"; mkdir -p "$R"/{Work,Personal,Journal,Prompts,assets} "$DIR/files"
cd "$R"
git init -q -b main
git config user.name "Ana Rivera"; git config user.email "ana@example.com"
git lfs install --local >/dev/null
printf 'assets/** filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes

style() { printf '{\n  "color" : "%s",\n  "icon" : "%s"\n}\n' "$2" "$3" > "$1/.notemd.json"; }
style Work blue briefcase.fill
style Personal pink heart.fill
style Journal teal book.closed.fill
style Prompts amber wand.and.stars

commit() { # date message
  git add -A
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q -m "$2"
}

cat > "Personal/Lisbon trip.md" <<'EOF'
---
tags: [travel]
---
# Lisbon trip

- [x] Book flights
- [x] Apartment in Alfama
- [ ] Tram 28 early, before the crowds
- [ ] Pastéis de Belém
- [ ] Day trip to Sintra
EOF
cat > "Personal/Reading list.md" <<'EOF'
---
tags: [personal]
---
# Reading list

1. *The Design of Everyday Things*
2. *A Philosophy of Software Design*
3. *Working in Public*
EOF
cat > "Prompts/Code Review Prompt.md" <<'EOF'
---
tags: [prompts]
params:
  - name: project
    type: text
    label: Project name
    required: true
    placeholder: My App
    default: NoteMD
  - name: language
    type: choice
    options: [Swift, TypeScript, Python, Go, Rust]
  - name: focus
    type: multichoice
    label: Focus on
    options: [correctness, security, performance, readability]
    default: [correctness, security]
  - name: files
    type: list
    help: One path per line
    default: [Sources/Editor/MarkdownTextView.swift, Sources/Preview/PreviewView.swift]
  - name: strict
    type: toggle
    label: Be strict
    default: true
---
# Code review: {{project}}

Review the following {{language}} changes in **{{project}}**.

{{#if focus}}
Pay special attention to: {{focus}}.
{{/if}}
{{#if files}}
Files to review:
{{#each files}}
- `{{.}}`
{{/each}}
{{/if}}
{{#if strict}}
Be strict: flag anything that would not pass a senior review.
{{else}}
Focus on the issues that matter most; skip nitpicks.
{{/if}}
EOF
cat > "Prompts/Release Notes Prompt.md" <<'EOF'
---
tags: [prompts]
params:
  - name: version
    type: text
    required: true
    placeholder: 1.4.0
  - name: audience
    type: choice
    options: [Users, Developers, Internal]
  - name: changes
    type: textarea
    label: Changes
---
# Release notes for {{version}}

Write release notes for **{{version}}**, aimed at {{audience}}.
Group the changes below into *New*, *Improved* and *Fixed*, one short line each:

{{changes}}
EOF
commit "2026-10-01T09:12:00" "Update 4 files"

cat > "Work/1-1 with Ana.md" <<'EOF'
---
tags: [work]
---
# 1:1 with Ana

- Sync engine is on track, perf tests next week
- Wants to pair on the conflict-resolution UI
- Follow up: conference budget for November
EOF
cat > "Work/Q4 Roadmap.md" <<'EOF'
---
tags: [work, planning]
---
# Q4 Roadmap

Ship the **sync engine**, polish onboarding and cut the release.

## Milestones

1. Sync engine beta
2. Onboarding refresh
EOF
commit "2026-10-03T10:40:00" "Update 2 files"

cat > "Work/Q4 Roadmap.md" <<'EOF'
---
tags: [work, planning]
---
# Q4 Roadmap

Ship the **sync engine**, polish onboarding and cut the release.

## Milestones

1. Sync engine beta
2. Onboarding refresh
3. Release candidate

- [x] Draft goals
- [ ] Review with the team
EOF
commit "2026-10-05T16:05:00" "Update Work/Q4 Roadmap.md"

cat > "Work/Q4 Roadmap.md" <<'EOF'
---
tags: [work, planning]
---
# Q4 Roadmap

Ship the **sync engine**, polish onboarding and cut the release.

## Milestones

1. Sync engine beta
2. Onboarding refresh
3. Release candidate

- [x] Draft goals
- [ ] Review with the team

> [!IMPORTANT]
> The beta must land before **October 30**.

| Area | Owner | Status |
| --- | --- | --- |
| Sync | Ana | Beta |
| Onboarding | Leo | Design |
| Release | Sam | Planned |
EOF
commit "2026-10-06T11:20:00" "Update Work/Q4 Roadmap.md"

# Media: a spoken voice note and a short screen-recording style clip.
say -v Samantha -o assets/voice-2026-10-07-081530.m4a --file-format=m4af --data-format=aac \
  "Idea for the onboarding: skip the empty state, and open a sample note that explains itself."
ffmpeg -loglevel error -y -loop 1 -framerate 30 -i "$FRAME" -t 6 \
  -vf "scale=1500:900:force_original_aspect_ratio=decrease,pad=1600:1000:(ow-iw)/2:(oh-ih)/2:color=0x1c1c1e,zoompan=z='min(zoom+0.0006,1.1)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=180:s=1600x1000:fps=30" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart assets/onboarding-walkthrough.mp4

cat > "Journal/Onboarding idea.md" <<'EOF'
---
tags: [ideas]
---
# Onboarding idea

+[Voice note](../assets/voice-2026-10-07-081530.m4a)

> Idea for the onboarding: skip the empty state, and open a sample note that explains itself.
EOF
cat > "Work/Onboarding review.md" <<'EOF'
---
tags: [work, design]
---
# Onboarding review

+[Walkthrough recording](../assets/onboarding-walkthrough.mp4)

- **0:04** the welcome sheet hides the *Open Folder* button
- **0:12** template picker needs a search field
- **0:21** great: the sample note renders instantly
EOF
commit "2026-10-07T08:20:00" "Update 4 files"

touch -t 202610010912 "Personal/Reading list.md" "Prompts/Release Notes Prompt.md" "Prompts/Code Review Prompt.md"
touch -t 202610020930 "Personal/Lisbon trip.md"
touch -t 202610031040 "Work/1-1 with Ana.md"
touch -t 202610070815 "Journal/Onboarding idea.md"
touch -t 202610070820 "Work/Onboarding review.md"
touch -t 202610071130 "Work/Q4 Roadmap.md"

# A loose text file for the standalone editor shot ("Goodbye, TextEdit").
cat > "$DIR/files/Scratch pad.txt" <<'EOF'
Scratch pad

Call the plumber on Thursday at 9:00
Guest Wi-Fi password is on the fridge
Flight LIS → BER, seat 14A

Gift ideas
- a good chef's knife for Sam
- the new Murakami for Leo

Shell one-liners
  git log --oneline --since="1 week ago"
  du -sh * | sort -h
EOF
echo "Demo vault: $R ($(git log --oneline | wc -l | tr -d ' ') commits); text file: $DIR/files/Scratch pad.txt"
