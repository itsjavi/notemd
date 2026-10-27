# Changelog

Notable changes in each NoteMD release, written from its commit messages by `scripts/changelog.sh`.

## 0.1.0 (2026-10-15)

### Features

- hidden folders, secret notes and a solid sidebar option (8d8b2d1)
- **core:** age v1 X25519 encryption with CryptoKit (c3dbcf0)
- **sidebar:** collapsible Folders and Tags sections, remembered (99918d1)
- **templates:** convert notes to templates and back, in place or as a copy (2cb7202)
- **storage:** keep notes in files/ and add incognito notes (a157e64)
- **editor:** find and replace (e7e411a)
- **assets:** reference index, paperclip popover and Assets view (bb2af66)
- **editor:** line numbers and invisible characters (8324678)
- **documents:** HTML preview with Editor, Split and Preview modes (9e2cceb)
- **notes:** context menus for empty note-list space; empty Recently Deleted (0b5966a)
- **templates:** value comparisons and #elseif in conditions, syntax guide popover (68cf02d)
- notes only, with Markdown import and a Share menu extension (954ded6)
- attachments, media embeds, voice notes and transcription (d7e1159)
- tabs or spaces indentation setting; fix slow quit (38638b6)
- NoteMD native Markdown notes app with automatic git versioning (65fec90)

### Fixes

- **documents:** centre the first standalone document window (65539ce)
- **storage:** only move NoteMD's own folders into files/ (891ed32)
- **notes:** right-click menus for empty note-list space and sidebar items (288c4a8)
- **templates:** Return inserts a line break in list and long text fields (da5498f)
- crash creating new files through SafeFileWriter (first .gitattributes write) (1cb319d)
- open any text file, route Finder opens, reopen recent repository at launch (b268909)
- brighter dark-mode app icon; compile icon with absolute paths (68fab44)
