# Project agent workflow

## Purpose and scope

Work autonomously on the user's requested scope, using the Backlog CLI
to plan, assign, execute, and document tasks.

When asked to work through the backlog, continue until all eligible
tasks are complete or the remaining tasks require user input.

Discussion, review, and planning requests do not automatically start
implementation.

Ask about consequential unresolved product, architecture, security,
or destructive decisions. Resolve routine implementation details
using project conventions and judgment.

## Agent identity and roster

Read agents.json at the start of each session. If the file does not
exist, create one specific for this project, based on the structure
of `agents.example.json` (no need to use it verbatim; agents and roles
can vary per project).

Each session operates under one agent nickname. The orchestrator
assigns nicknames when starting workers. A standalone session uses
defaultAgent unless the user specifies otherwise.

Agent nicknames must match backlog assignee names exactly.

Use the smallest useful number of workers. Delegate independent work
when it provides a clear benefit; handle small or tightly coupled
work directly.

The roster describes roles and permissions. It does not itself
launch workers or enforce filesystem permissions.

## Orchestration and assignment

The default agent is the orchestrator.

The orchestrator:

- Turns agreed requirements into actionable backlog tasks.
- Defines acceptance criteria, dependencies, and priorities.
- Assigns each execution task to one accountable agent.
- Starts workers with their nickname, task scope, and relevant context.
- Coordinates overlapping work, handoffs, and integration.
- Keeps the overall backlog accurate.

In a multiagent run, workers pick up eligible tasks assigned to their
nickname. Workers do not take another agent's tasks without a handoff
or reassignment by the orchestrator.

In a standalone run, the default agent may execute eligible tasks
assigned to any agent within the user's requested scope. Record the
solo takeover in the task notes; reassignment is optional.

An assignment does not override an existing active claim.

Split independently executable work into separate tasks rather than
giving multiple workers concurrent ownership of one task.

## Task execution

Before starting a task:

1. Read its description, acceptance criteria, dependencies, and notes.
2. Confirm it is within scope, unblocked, and permitted by your role.
3. Acquire its active claim.
4. Set its status to In Progress through the Backlog CLI.

While working:

- Keep implementation plans, decisions, blockers, and evidence in
  the task.
- Append progress notes without replacing another agent's notes.
- Keep changes scoped and preserve unrelated work.
- Record newly discovered work as tasks; do not silently expand scope.
- If blocked, record the reason and required next action, then
  release the claim and continue independent eligible work.

Mark a task Done only when:

- Its acceptance criteria are satisfied.
- Relevant validation has passed, with limitations documented.
- Its changes are integrated into the main working tree.
- Any required visual evidence and completion summary are recorded.
- User-facing features and substantial UI changes are reflected in the README, website and intro video (see
  "Public docs, website and intro video"), or the task notes say why they are not needed.

Writing workers update their own tasks through the CLI. Read-only
workers return findings and proposed updates to the orchestrator,
which records them.

Do not mark blocked or partially completed work Done.

## Local coordination

The backlog is the source of truth for requirements, assignments,
dependencies, progress, decisions, and completion evidence.

Use .local/coordination/ only for runtime coordination:

- sessions/<session-id>.json: nickname, mode, activity, and owned claims.
- claims/<task-id>/owner.json: owning session and working directory.
- backlog-write.lock/: short-lived lock for backlog mutations.

Acquire task claims by atomically creating their claim directory.
If it already exists, treat the task as claimed.

Create backlog-write.lock/ atomically before mutating the backlog.
Record the owning session, keep the operation brief, and release
the lock afterward.

Do not hold the backlog write lock while implementing, testing,
waiting for workers, or waiting for user input.

Release claims when work finishes, is handed off, or is blocked.
Do not reclaim claims or locks based only on their age: first confirm
the owning session has stopped or explicitly released ownership.

At session startup, reconcile existing claims with the backlog and
live workers before taking new work.

Do not duplicate task descriptions or progress histories in runtime
files. Do not delete another session's coordination state.

## Backlog repository boundary

backlog/ is ignored by the main repository and has its own local
Git repository.

Agents may update backlog content through the Backlog CLI, but must
not stage, commit, push, reset, or clean the backlog repository.

Backlog is auto-committed automatically, but a dirty backlog state
is expected and is not a blocker.

Dirty application state is also not a blocker by itself. Inspect
ownership and overlap, preserve existing changes, and continue work
that can be completed safely.

Application commits remain subject to agents.json permissions and
the existing Git and staged-change rules.

If agents have all finished their work and there are still files
pending to be committed, the default/main agent may do so into
proper commits, before starting any other agents again.

## Shared work and worktrees

Avoid overlapping edits between workers in the same working tree.
The orchestrator assigns distinct file ownership or serializes
conflicting work.

Use worktrees when isolation provides a clear benefit. Record the
working directory in the task claim.

Before closing a worktree, integrate and verify its needed changes
in the main working tree. Remove it only after confirming no needed
work remains.

## Scratch space

Use .local/agents/<nickname>/<session-id>/ for session scratch work.

.local/coordination/ is operational state, not disposable scratch.
Preserve .local/data/ and .local/keep/ if they exist.

canWrite: false still permits an agent to write its own scratch and
session coordination state, but not source files or backlog content.

## Visual progress

For UI work, send screenshots in chat after important visual changes
and at completion.

When requesting a consequential UI decision, show the current result
with a disposable screenshot when practical.

Store final representative screenshots in `backlog/assets/` and link
them from the relevant task. Keep intermediate captures in scratch.

## Files that LLMs and Agents should not use as context

Any file matching these patterns, should not be used as context:

- ./**/*.prompt.txt
- ./**/*.prompt.md

## Other things to keep in mind

From time to time, please format docs and other code via `npx -y oxfmt .`
before comitting if you are only the agent running.

## NoteMD project

Native macOS 26 note-taking app and standalone Markdown/text editor (SwiftUI + AppKit, Swift 6, SwiftPM).
Decisions live in `backlog/decisions/` (platform, storage format, git versioning, rendering).

### Commands

| Command                           | What it does                                                             |
| --------------------------------- | ------------------------------------------------------------------------ |
| `swift build` / `make build`      | Debug build of all targets                                               |
| `swift test` / `make test`        | Core unit tests (Swift Testing)                                          |
| `make app`                        | Release `build/NoteMD.app` (ad-hoc signed unless `SIGN_IDENTITY` is set) |
| `make dev` / `make run`           | Debug `build/NoteMD Dev.app` (own bundle id and defaults)                |
| `make test-app` / `make run-test` | Background agent build `build/NoteMD Test.app`                           |
| `make install`                    | Quits the installed copy and installs the release build to /Applications |
| `make icon`                       | Redraws `Resources/AppIcon.icon` from `scripts/make-icon.swift`          |

### Layout

| Path                                                                                        | Contents                                                                                          |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `Sources/NoteMDCore/Notes`                                                                  | Front matter (Yams, raw-entry preserving), notes, folders + `.notemd.json`, scanner, search       |
| `Sources/NoteMDCore/Templates`                                                              | Template parameters and the `{{…}}` renderer                                                      |
| `Sources/NoteMDCore/Markdown`                                                               | cmark-gfm HTML rendering (GFM extensions, alerts, front matter table)                             |
| `Sources/NoteMDCore/Git`, `Diff`                                                            | git subprocess client, auto-committer, commit messages, line diff                                 |
| `Sources/NoteMD/App`                                                                        | App entry, delegate, window manager, settings, variants                                           |
| `Sources/NoteMD/Repository`                                                                 | Per-window `RepositoryStore`, open-note `NoteEditor`, FSEvents watcher                            |
| `Sources/NoteMD/Views`, `Editor`, `Preview`, `Folders`, `Templates`, `History`, `Documents` | UI                                                                                                |
| `Sources/NoteMD/Attachments`, `Voice`                                                       | Drop/paste importer (assets/ copy or link), voice recorder, on-device transcription               |
| `Sources/NoteMD/Debug`                                                                      | URL scheme handler; DEBUG-only test hooks                                                         |
| `Resources/`                                                                                | Info.plist, privacy manifest, `AppIcon.icon`                                                      |
| `scripts/`                                                                                  | `build-app.sh`, `make-icon.swift`, `window-screenshot.swift`, `demo-vault.sh`, `og-image.html`    |
| `web/`, `.github/workflows/pages.yml`                                                       | Website (https://itsjavi.com/notemd/) and its GitHub Pages deployment                             |
| `brand/`                                                                                    | Screenshot/social-card recipes (`brand/README.md`) and the generated intro video (`intro-video/`) |
| `skills/create-reusable-prompt/`                                                            | Agent skill for writing template notes, and the front matter JSON Schema (keep in sync with Core) |

### Public docs, website and intro video

The README, the website and the intro video are part of the product. Any task that adds a user-facing feature,
removes or renames one, or substantially changes the UI must update them in the same task:

- `README.md`: the feature list, and the screenshot table when it shows changed UI.
- `web/index.html`: the feature rows or details grid, and the screenshots in `web/assets/` (shared with the README).
- `brand/intro-video/`: add or fix a scene when the feature is headline-worthy or a scene becomes inaccurate, then
  re-render (`pnpm render`). Re-render after screenshot changes, since scenes use them.
- `scripts/og-image.html`: re-render the social card when the hero screenshot or tagline changes.

Follow `brand/README.md` for what to update, the demo vault (`scripts/demo-vault.sh`) and the capture recipe. Never
leave published copy, screenshots or video showing UI that no longer exists.

When planning, the orchestrator adds this acceptance criterion to every feature or UI task: "README, website and
intro video updated, or the notes say why not". Send the updated screenshots or video in chat like any other visual
change.

### Builds

| Build       | Bundle id                 | Scheme           | Who uses it                                            |
| ----------- | ------------------------- | ---------------- | ------------------------------------------------------ |
| NoteMD      | `com.itsjavi.notemd`      | `notemd://`      | The user. Agents never launch or install it            |
| NoteMD Dev  | `com.itsjavi.notemd.dev`  | `notemd-dev://`  | Developer debug runs                                   |
| NoteMD Test | `com.itsjavi.notemd.test` | `notemd-test://` | Agents: `LSUIElement`, never activates or steals focus |

### Driving the Test build

Launch with `open -g "build/NoteMD Test.app"` and send hooks with
`open -g -a "$PWD/build/NoteMD Test.app" "notemd-test://<verb>?<query>"`. Add `repo=<path suffix>` to target a window.
Hooks run only in the Test variant and only against repositories under `/private/tmp` or `/private/var/folders`;
note paths must be plain repository-relative paths.

- `ui/create-repo?path=` (seeds example notes), `ui/open-repo?path=`, `ui/open-file?path=`, `ui/welcome`
- `ui/sidebar?item=all|templates|deleted` or `folder=`/`tag=`, `ui/select?note=`, `ui/search?q=`, `ui/mode?value=edit|split|preview`
- `ui/new-note?title=&body=`, `ui/type?text=`, `ui/tags?value=a,b`, `ui/folder-style?path=&icon=&color=`
- `ui/sheet?name=history|form|params|rename|folder-new|folder-edit&path=`, `ui/close-sheet`
- `ui/move?note=&folder=`, `ui/move-folder?path=&parent=`, `ui/rename?note=&name=`, `ui/trash?note=`, `ui/restore-deleted?path=`,
  `ui/remove-deleted?path=|all=1` (hides Recently Deleted entries). The background Test build can commit a minute late:
  wait for `git log` before relying on history
- `ui/editor-command?name=tab|backtab|newline|text&text=&select=end|all[&target=document]`, `ui/settings`
- `ui/sheet-key?index=&text=&key=return|cmd-return` (types into the index-th multi-line box of the open sheet, then
  routes the key like AppKit: default buttons first). Avoid it in the Use Template form, where a stray Return copies.
- `ui/attachment-mode?value=ask|copy|link`, `ui/drop-files?paths=a,b`, `ui/paste-file?path=`, `ui/paste-image?path=`
  (absolute temp paths; `select=end`, `target=document`), `ui/service-note?text=&file=`, `ui/lfs-check`
- `ui/voice-start?from=<clip>|seconds=` (recorder with the microphone replaced by that clip), `ui/voice-stop`, `ui/voice-cancel`,
  `ui/transcribe?src=<link destination>&lang=en-US`, `ui/sheet?name=transcribe|recorder&src=`
- `ui/commit-now`, `ui/restore?path=&rev=`, `ui/window-size?w=&h=`, `ui/appearance?value=dark|light`
- `ui/document-active-content?value=0|1` (the HTML preview's Scripts and Remote Content toggle, first document)
- `debug/state?out=/private/tmp/state.txt` writes a `key: value` state dump

Capture windows without activating the app: `swift scripts/window-screenshot.swift "NoteMD Test" /private/tmp/shot`.
An open sheet blocks quitting (standard AppKit): close sheets before `quit`, or `pkill` the Test build.
Real clicks, drags, Finder "Open With" and menu shortcuts still need a human check in the Dev build.
