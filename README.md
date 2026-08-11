# ⏳ Day timeline

Sunsama-style vertical day timeline for macOS. Reads, renders, and writes back the same Obsidian Day Planner markdown file Obsidian itself uses, so the file stays the single source of truth.

<img width="1197" height="1152" alt="image" src="https://github.com/user-attachments/assets/7351321e-cf8d-43f4-9d72-c9e73895f9f0" />

## Build

```cmake
swift build -c release
.build/release/day-timeline
```

Requires macOS 13+ and the Swift toolchain.

## Configuration

Out of the box the app looks for `~/Documents/Brain dump/claude-mcp-daily-plans/Plan D.M.YYYY.md`, which is the author's vault. Point it at yours with `defaults write`, no rebuild needed:

```bash
defaults write fi.dude.day-timeline planDirectory "~/Documents/Notes/Daily"
defaults write fi.dude.day-timeline planFileNameFormat "yyyy-MM-dd'.md'"
defaults write fi.dude.day-timeline obsidianVaultName "Notes"
defaults write fi.dude.day-timeline timeZone "Europe/Lisbon"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `planDirectory` | `~/Documents/Brain dump/claude-mcp-daily-plans` | Folder holding the plan files. `~` is expanded. |
| `planFileNameFormat` | `'Plan 'd.M.yyyy'.md'` | `DateFormatter` pattern for one day's file. Literal text needs single quotes. |
| `obsidianVaultName` | `Brain dump` | Vault name used in `obsidian://open` links. The in-vault path is derived from `planDirectory`. |
| `timeZone` | `Europe/Helsinki` | Zone every timestamp resolves in. Falls back to the system zone if unknown. |
| `timelineStartHour` | `7` | First hour drawn. The timeline still expands to fit earlier blocks. |
| `timelineEndHour` | `19` | Last hour drawn, expanding for later blocks. |

Check what the app resolved, including whether today's file actually exists:

```bash
.build/release/day-timeline --print-config
```

Settings can also be overridden per launch without touching your preferences, which is handy for trying a vault out:

```bash
.build/release/day-timeline -planDirectory "~/Notes/Daily" -planFileNameFormat "yyyy-MM-dd'.md'"
```

Use the `fi.dude.day-timeline` domain for the installed `.app` and `day-timeline` for a binary run straight out of `.build`.

## App bundle

```yaml
Scripts/make-app.sh --install
```

Builds `dist/Day timeline.app` with the icon rendered by the binary itself (`day-timeline --export-icon <dir>` writes the iconset, `iconutil` turns it into `AppIcon.icns`), so the art never drifts from the code that draws it. `--install` moves it to `~/Applications`, replacing any running copy, and clears `dist` so Launchpad does not list the build copy too. Without the flag the bundle is left in `dist` for you to place yourself.

## Features

- Minimize, zoom and close in the title bar; menu bar with cmd+M, cmd+W, cmd+H, cmd+Q
- Vertical timeline 07:00-19:00 by default, expanding to fit blocks outside that range
- Click status circle to cycle planned → in progress → done → skipped, with completion timestamp appended automatically
- Drag block body to move, drag top or bottom edge to resize, snapping to 15 min on release
- Floating + button or cmd+N adds a new 30-min block at the next quarter hour
- Cmd+scroll, cmd+-, cmd+=, cmd+0, or the bottom-right magnifier for zoom; level persists across launches
- Right-click for status, rename, delete, open in Obsidian
- Inline markdown rendering for Linear links and similar
- FSEvents file watch with a 2 s mtime poll fallback keeps the view in sync with Obsidian and `/plan_today` edits
- Atomic save touches only the `## Day Planner` section, every other section preserved byte-for-byte

## Plan file format

```plaintext
- [ ] 10:00 - 11:00 Task name (Source)
- [>] 11:00 - 12:30 In-progress task
- [x] 12:30 - 13:00 Completed task (done 12:58)
- [-] 13:00 - 13:30 Skipped task
```
