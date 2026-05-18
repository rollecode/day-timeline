### 0.3.1: 2026-05-11

* Window floats above other apps and follows you across spaces (`window.level = .floating`, `canJoinAllSpaces`)

### 0.5.0: 2026-05-18

* Flag meeting blocks with the official Dude mint background (`#7effe1`); keyword list is case-insensitive (daily standup, weekly, google meet, lounas, ...) with "Dude x" matched case-sensitively
* Show a brand-tinted icon on blocks that reference Microsoft Teams, Google Meet, Slack/huddle, Linear issue IDs or linear.app, and Todoist

### 0.4.0: 2026-05-11

* Float window above other apps and follow you across spaces
* Auto-scroll the timeline so the now indicator is centered when the window opens
* Enlarge the now indicator dot to 12px and the line to 2px
* Full weekday names in the header (Monday, not Mon)
* Per-second clock with HH:MM:SS, locked to a fixed-width frame so digits do not jump
* Bundle Instrument Serif and use it for the date and clock headings
* Auto-complete blocks once their end time passes, tagging them `(done HH:MM)` at the scheduled end

### 0.3.0: 2026-05-08

* Watch the plan file's own fd via FSEvents instead of the parent directory so Obsidian writes actually fire change events; re-open across atomic-write rename/delete; 2 s mtime poll as a belt-and-braces fallback
* Persist zoom level in UserDefaults across launches
* Render block titles as inline markdown via AttributedString so Linear links and similar come out as actual links
* Replace grid-tap-creates-block with a floating + button bottom-left and cmd+N shortcut; new block lands at the next quarter hour
* Move status button outside the drag region so its clicks are no longer stolen by the gesture; right-click for everything else (status, rename, delete, open in Obsidian)
* Smooth drag preview (no per-pixel jitter) with 15-min snap applied on release
* Hover effect: brighter fill and soft shadow on the focused block
* Cursor feedback: open hand on body, resize on edges, pointing hand on status circle and + button

### 0.2.0: 2026-05-08

* Cmd+scroll wheel and bottom-right magnifier buttons drive a 50%-400% zoom; cmd+0 resets, cmd+- and cmd+= shortcuts
* Free drag/move/resize with GestureState live preview and 15-min snap on release
* Single-click block opens today's plan in Obsidian via `obsidian://open`
* Append `(done HH:MM)` to a block's title when its status flips to done; strip the tag if it reverts away from done
* Drop block borders, keep only the tinted rounded fill plus a 1-pixel window-bg hairline so adjacent blocks read as separate

### 0.1.0: 2026-05-08

* Initial scaffold. SwiftUI single-file app at `Sources/main.swift`
* Reads `~/Documents/Brain dump/claude-mcp-daily-plans/Plan D.M.YYYY.md` and renders the `## Day Planner` section as a vertical timeline
* Status checkbox cycles `[ ]` → `[>]` → `[x]` → `[-]`
* Inline rename via right-click, click empty grid to add a 30-min block, right-click context menu with status/rename/delete
* FSEvents watcher reloads on external changes from Obsidian or `/plan_today`
* Atomic save preserves every section other than `## Day Planner`
