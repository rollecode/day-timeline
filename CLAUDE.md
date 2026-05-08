## Commits and code style

- Never use Claude watermark in commits (FORBIDDEN: "Co-Authored-By")
- No emojis in commits or code
- One logical change per commit
- Keep commit messages concise, present tense, sentence case
- Use sentence case for headings, no Title Case
- Never use bold text as headings, use proper heading levels
- Always add an empty line after headings

## Swift/SwiftUI code style

- 4-space indentation
- Single-file SwiftUI application at `Sources/main.swift`
- System SF fonts, never monospaced for display text
- Use computed properties for dynamic colors and layout
- Prefer SwiftUI bindings over imperative updates

## Source of truth

- The plan file at `~/Documents/Brain dump/claude-mcp-daily-plans/Plan D.M.YYYY.md` is canonical
- App may only modify the `## Day Planner` section
- Every other section in the file (Analysis, Backlog, Stale, Security, Emails, Support, Footnote) must be preserved byte-for-byte on save
- Saves go through atomic write (temp file + rename), debounced 300 ms

## Concurrency

- FSEvents watches the plan file directory
- External changes reload automatically (200 ms debounce)
- Self-triggered writes are suppressed for 500 ms to prevent bounce loops
- Helsinki timezone (Europe/Helsinki) for all timestamps

## Testing

- Test builds with `swift build -c release` before committing
- Run the binary briefly to confirm no startup crashes
