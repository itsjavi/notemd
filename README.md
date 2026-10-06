# NoteMD

A native macOS note-taking app for plain Markdown files, with automatic git versioning.

- **Notes are files.** Pick any folder as a notes repository; open several in separate windows and switch between recent ones.
- **Organize** with folders (each can have a color and an icon) and tags (`tags:` front matter). Search across titles, tags and text, with `tag:name` / `#name` filters.
- **Versioned automatically.** Every repository is a git repository. Edits are saved as you type and committed in batches after a few seconds of inactivity (configurable), on window close, on quit and with ⌘S. Version History compares any version and restores it as a new commit. Deleted notes can be restored too.
- **GitHub Flavored Markdown** editor and live preview (tables, task lists, footnotes, alerts, autolinks), with Editor, Split and Preview modes.
- **Templates with parameters.** Add `params` to a note's front matter and use `{{name}}` placeholders (plus `{{#if}}`, `{{#unless}}`, `{{#each}}`). "Use Template" opens a form (text, long text, number, toggle, choice, multiple choice, file, folder, date, list) and gives you the result to copy or save as a note — handy for reusable AI prompts.
- **Standalone editor.** Open any `.md` or text/code file from Finder (NoteMD appears under _Open With_ without becoming the default). Non-Markdown files open in plain-text mode.

## Requirements

macOS 26 or later on Apple silicon, and `git` (Xcode Command Line Tools or Homebrew).

## Building

```bash
make app      # build/NoteMD.app
make install  # copy to /Applications
make test     # unit tests
```

See [AGENTS.md](AGENTS.md) for the project layout, build variants and test hooks.
