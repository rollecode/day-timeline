# Day timeline

Sunsama-style vertical day timeline for macOS. Single source of truth is the
Obsidian Day Planner markdown file - this app reads, renders, and writes back
to the same file Obsidian uses.

## What it does (v0.1)

- Reads today's plan file at `~/Documents/Brain dump/claude-mcp-daily-plans/Plan D.M.YYYY.md`
- Renders the `## Day Planner` section as a vertical timeline (09:00-19:00, expanding to fit blocks outside that range)
- Click the status glyph to cycle planned -> in progress -> done -> skipped
- Double-click a block to rename inline
- Click an empty area on the grid to add a new 30-min block
- Right-click a block to set status, rename, or delete
- Watches the plan file via FSEvents - external changes (Obsidian, /plan_today) reload automatically
- Writes back atomically (.tmp + rename), only touching the `## Day Planner` section. Every other section preserved byte-for-byte.

## What it does not do yet

- Drag to move or resize blocks (status, rename, delete only for now)
- Google Calendar overlay for real meetings
- Dayflow overlay for actual time spent
- focus-timer in-progress highlight
- Multi-day view

## Build and run

```
cd ~/Projects/day-timeline
swift build -c release
.build/release/day-timeline
```

Requires macOS 13+ and the Swift toolchain.

## Plan file format

Lines parsed from the `## Day Planner` section:

```
- [ ] 10:00 - 11:00 Task name (Source)
- [>] 11:00 - 12:30 In-progress task
- [x] 12:30 - 13:00 Completed task
- [-] 13:00 - 13:30 Skipped task
```

Status tokens: `[ ]` planned, `[>]` in progress, `[x]` done, `[-]` skipped.
Times are HH:MM 24h. Anything after the time range is freeform task text
including any `(Source)` tag and Markdown links.

The parser is lenient: lines that don't match the pattern are ignored
rather than rejecting the whole file. The writer only touches the
Day Planner section.

## Conflict handling

- App watches the plan file directory via FSEvents.
- External changes reload automatically (200 ms debounce).
- App writes are debounced 300 ms, then atomic.
- A short suppression window after our own write prevents bouncing.
