### 1.3.3: 2026-08-18

* Make the whole slot clickable, not just its header
* Wrap text while renaming a block or slot
* Let a rename field grow past a short block

### 1.3.2: 2026-08-18

* Merge overlapping time slots into one
* Never lay blocks out side by side
* Make Escape actually cancel instead of beeping
* Stretch rename fields to the full block width

### 1.3.1: 2026-08-18

* Cancel edits and selection with Escape
* Clear selection by clicking empty timeline
* Give rename fields real input chrome and focus
* Wrap long block titles instead of overflowing
* Lay residual overlaps out side by side
* Absorb loose blocks into the slot they sit in

### 1.3.0: 2026-08-18

* Fold overlapping blocks into a slot automatically
* Name auto slots after their task count
* Select blocks and slots with one click
* Rename a block by double-clicking it
* Open a slot by double-clicking it
* Rename a slot from its window title

### 1.2.1: 2026-08-18

* Fill the slot window height with its timeline
* Keep slot contents out of the titlebar
* Align the ruler exactly with block edges
* Raise every small font by one point

### 1.2.0: 2026-08-18

* Open a time slot in its own window
* Close the slot window with X or Escape
* Keep block identity stable across reloads
* Stop dropping drag and resize edits
* Never reload the file mid-gesture
* Scale slot contents independently of zoom

### 1.1.0: 2026-08-18

* Add Akiflow-style collapsible time slots
* Hide member tasks until a slot is clicked
* Show task count badge and compact duration
* Drag, resize and delete slots like blocks
* Move a slot's tasks along with it

### 1.0.1: 2026-08-17

* Hide `<!-- cal: -->` id comments from blocks
* Detect meetings and icons from visible text
* Keep ids intact through a rename
* Skip mtime recording during an in-flight save

### 1.0.0: 2026-08-11

* First stable release: MIT licensed, public, and no longer tied to one person's vault
* Plan directory, file name pattern, vault name, timezone and timeline hours are all settings now, resolved from UserDefaults with the previous hardcoded values as defaults; nothing about the plan file location is baked into the binary
* Derive the in-vault path for `obsidian://open` from the plan directory instead of a hardcoded folder name
* `--print-config` prints every resolved setting and whether today's plan file exists, without opening a window
* Settings can be overridden per launch (`-planDirectory ...`) without writing to preferences
* Document all of it in the README, and correct the timeline range there from 09:00 to the actual 07:00 default

### 0.9.0: 2026-08-11

* Remember the window size and position across launches; only the very first run centers a default-sized window
* `Scripts/make-app.sh --install` puts the bundle in `~/Applications` and clears `dist`, so Launchpad stops listing the build copy next to the installed one

### 0.8.0: 2026-08-11

* Minimize button in the title bar, plus a menu bar with Minimize (cmd+M), Zoom, Close (cmd+W), Hide (cmd+H) and Quit (cmd+Q) - the app had no menu bar at all before
* Quit when the last window closes instead of leaving a windowless process behind
* App icon drawn in code (mint blocks, hour rail, red now line on a dark plate) and set as the Dock tile at launch
* `Scripts/make-app.sh` builds `dist/Day timeline.app` with an `AppIcon.icns` exported from the same drawing via `day-timeline --export-icon`

### 0.7.0: 2026-05-28

* Keep-now-centered toggle next to the + button (default on, persisted): re-centers the timeline on the red now pin every minute and when re-enabled

### 0.6.0: 2026-05-18

* Render the real brand glyph per block (Teams, Google Meet, Slack, Linear, Todoist) via embedded SVG paths, single white icon picked by detection priority
* Tint each block with its primary service brand color, opacity scaled by status; Google Meet uses Google blue (`#1A73E8`); service color is preferred over the meeting mint
* Treat blocks mentioning "Calendar" as Google Meet and standups as Slack huddles
* Pin the hour-grid line to the exact hour and clip blocks to their time-slot height so blocks line up with the grid
* Tidy block text insets and service-icon padding

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
