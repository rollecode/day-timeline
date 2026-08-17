## Identity

This is the day-timeline app, a sibling to focus-timer. SwiftUI single-file menu bar / window app at `Sources/main.swift` that mirrors the Obsidian Day Planner timeline visually and writes edits back to the same markdown file.

## Source of truth

The plan file is canonical. Its location defaults to `~/Documents/Brain dump/claude-mcp-daily-plans/Plan D.M.YYYY.md` and is resolved through the `Settings` enum at the top of `Sources/main.swift`, so never hardcode a path anywhere else; see the Configuration section in `README.md` for the keys. The app may only modify the `## Day Planner` section; every other section in the file (Analysis, Backlog, Stale, Security, Emails, Support, Footnote, etc.) must be preserved byte-for-byte on save. The Obsidian Day Planner plugin reads the same file, and `/plan_today` writes to it - the three editors agree on the format and never reformat each other's sections.

`/plan_today` tags block lines with markdown comments carrying ids, e.g. `<!-- cal:tvt2cba3s3k2k1c4amjpph9jg6_20260814T124500Z lin:UP-832 -->`. They are part of the title and round-trip through saves untouched, including through a rename. Nothing user-facing may render them: display, meeting detection and service icons all run on `Block.visibleTitle`, never on `title`.

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

Test builds with `swift build -c release` before committing. Verify behaviour headlessly with `--print-config` rather than opening the window; launching the app puts a floating window on top of whatever Rolle is doing.

## Shipping

Every change ends installed and ready to use, not just committed:

1. `swift build -c release`
2. Changelog entry, commit, push
3. `gh release create vX.Y.Z`
4. `Scripts/make-app.sh --install` so `~/Applications/Day timeline.app` is the version just released
5. Log it in the life changelog at `~/Documents/Brain dump/CHANGELOG.md` under today's entry, as `* Release [day-timeline](https://github.com/rollecode/day-timeline) X.Y.Z`

Relaunch the app afterwards only if it was running before the install; the script kills the running copy to replace it.
