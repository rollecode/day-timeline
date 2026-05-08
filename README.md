# 🗓️ Day timeline

Sunsama-style vertical day timeline for macOS. Reads, renders, and writes back the same Obsidian Day Planner markdown file Obsidian itself uses, so the file stays the single source of truth.

## 🛠️ Build

```bash
swift build -c release
.build/release/day-timeline
```

Requires macOS 13+ and the Swift toolchain.

## ✨ Features

- Vertical timeline 09:00-19:00, expanding to fit blocks outside that range
- Click status circle to cycle planned → in progress → done → skipped, with completion timestamp appended automatically
- Drag block body to move, drag top or bottom edge to resize, snapping to 15 min on release
- Floating + button or cmd+N adds a new 30-min block at the next quarter hour
- Cmd+scroll, cmd+-, cmd+=, cmd+0, or the bottom-right magnifier for zoom; level persists across launches
- Right-click for status, rename, delete, open in Obsidian
- Inline markdown rendering for Linear links and similar
- FSEvents file watch with a 2 s mtime poll fallback keeps the view in sync with Obsidian and `/plan_today` edits
- Atomic save touches only the `## Day Planner` section, every other section preserved byte-for-byte

## 📐 Plan file format

```plaintext
- [ ] 10:00 - 11:00 Task name (Source)
- [>] 11:00 - 12:30 In-progress task
- [x] 12:30 - 13:00 Completed task (done 12:58)
- [-] 13:00 - 13:30 Skipped task
```
