## Identity

This is the day-timeline app, a sibling to focus-timer. SwiftUI single-file menu bar / window app at `Sources/main.swift` that mirrors the Obsidian Day Planner timeline visually and writes edits back to the same markdown file.

## Source of truth

The plan file is canonical. Its location defaults to `~/Documents/Brain dump/claude-mcp-daily-plans/Plan D.M.YYYY.md` and is resolved through the `Settings` enum at the top of `Sources/main.swift`, so never hardcode a path anywhere else; see the Configuration section in `README.md` for the keys. The app may only modify the `## Day Planner` section; every other section in the file (Analysis, Backlog, Stale, Security, Emails, Support, Footnote, etc.) must be preserved byte-for-byte on save. The Obsidian Day Planner plugin reads the same file, and `/plan_today` writes to it - the three editors agree on the format and never reformat each other's sections.

## Concurrency

- FSEvents watches the plan file's own fd, not its parent directory; the parent's mtime does not change on content edits
- The watcher re-opens the fd on rename or delete so Obsidian's atomic-write pattern doesn't strand us on a deleted inode
- A 2 s mtime poll runs alongside as a belt-and-braces fallback
- Saves are debounced 300 ms then atomic (write `.tmp` + rename), and a 500 ms suppression window prevents bouncing on our own writes
- Helsinki timezone (Europe/Helsinki) for all timestamps

## Code style

- 4-space indentation
- Single-file SwiftUI application
- System SF fonts, never monospaced for display text
- Computed properties for derived layout values (`pxPerMin`, `liveStartMin`, `topOffset`, `height`)
- Prefer SwiftUI bindings and gestures over imperative AppKit when possible

## Commits

- Never use the Claude watermark in commits (FORBIDDEN: `Co-Authored-By`)
- No emojis in commits
- One logical change per commit, present tense, sentence case
- Keep messages concise

## Testing

Test builds with `swift build -c release` before committing. Run the binary briefly to confirm no startup crashes.
