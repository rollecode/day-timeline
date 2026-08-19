import SwiftUI
import AppKit
import CoreText
import Combine

// MARK: - Settings
//
// Nothing here needs a rebuild to change. Every value falls back to the
// author's own setup, and each one can be overridden with `defaults write`,
// e.g. for an Obsidian vault whose daily notes are named 2026-08-11.md:
//
//   defaults write fi.dude.day-timeline planDirectory "~/Documents/Notes/Daily"
//   defaults write fi.dude.day-timeline planFileNameFormat "yyyy-MM-dd'.md'"
//   defaults write fi.dude.day-timeline obsidianVaultName "Notes"
//
// Use the fi.dude.day-timeline domain for the installed .app; the bare binary
// built by `swift build` reads the day-timeline domain instead.

enum Settings {
    private static let store = UserDefaults.standard

    static func string(_ key: String, default fallback: String) -> String {
        guard let value = store.string(forKey: key), !value.isEmpty else { return fallback }
        return value
    }

    static func int(_ key: String, default fallback: Int) -> Int {
        store.object(forKey: key) == nil ? fallback : store.integer(forKey: key)
    }
}

/// Directory holding the plan files. `~` is expanded.
let planDir = (Settings.string("planDirectory",
                               default: "~/Documents/Brain dump/claude-mcp-daily-plans")
    as NSString).expandingTildeInPath

/// DateFormatter pattern for a day's file name. Literal text needs single quotes.
let planFileNameFormat = Settings.string("planFileNameFormat", default: "'Plan 'd.M.yyyy'.md'")

/// Vault name for the `obsidian://open` links.
let obsidianVaultName = Settings.string("obsidianVaultName", default: "Brain dump")

/// Timezone every timestamp is resolved in. Falls back to the system zone if
/// the configured identifier is not one Foundation recognises.
let planTimeZone = TimeZone(identifier: Settings.string("timeZone", default: "Europe/Helsinki"))
    ?? .current

let dayStart = Settings.int("timelineStartHour", default: 7)
let dayEnd = Settings.int("timelineEndHour", default: 19)
let basePixelsPerMinute: CGFloat = 1.2
let zoomMin: Double = 0.5
let zoomMax: Double = 4.0
let snapMinutes = 15
let windowFrameAutosaveName = "DayTimelineWindow"
let slotWindowFrameAutosaveName = "DayTimelineSlotWindow"

// MARK: - Plan file path for a date

func planFileName(for date: Date) -> String {
    let formatter = DateFormatter()
    // POSIX locale so the pattern means the same thing under every locale.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = planTimeZone
    formatter.dateFormat = planFileNameFormat
    return formatter.string(from: date)
}

func planFilePath(for date: Date) -> String {
    "\(planDir)/\(planFileName(for: date))"
}

/// Path an `obsidian://open` link needs: everything below the vault directory.
/// Derived from planDir so the vault can live anywhere, with the bare file name
/// as the fallback when the vault name is not part of the path at all.
func vaultRelativePlanPath(for date: Date) -> String {
    let fileName = planFileName(for: date)
    let components = planDir.split(separator: "/").map(String.init)
    guard let vaultIndex = components.lastIndex(of: obsidianVaultName) else { return fileName }
    let subdirectories = components[(vaultIndex + 1)...]
    return (subdirectories + [fileName]).joined(separator: "/")
}

// MARK: - Block model

enum BlockStatus: String {
    case planned = " "
    case inProgress = ">"
    case done = "x"
    case skipped = "-"

    func cycle() -> BlockStatus {
        switch self {
        case .planned: return .inProgress
        case .inProgress: return .done
        case .done: return .skipped
        case .skipped: return .planned
        }
    }

    var token: String { rawValue }

    var color: Color {
        switch self {
        case .planned: return Color(white: 0.55)
        case .inProgress: return Color.orange
        case .done: return Color.green
        case .skipped: return Color.red.opacity(0.6)
        }
    }
}

/// Markdown comments the planner writes onto a block line to carry ids, e.g.
/// `<!-- cal:tvt2cba3s3k2k1c4amjpph9jg6_20260814T124500Z lin:UP-832 -->`.
/// They stay in the file byte-for-byte and never reach the screen: rendering,
/// meeting detection and service icons all run on the visible title, so an id
/// that happens to contain "demo" or "UP-832" cannot mislabel a block.
let metadataCommentPattern = #"<!--.*?-->"#

/// Time-slot palette, fixed rather than derived: Rolle picked these.
extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

let slotFillColor = Color(hex: 0x1d123b)
let slotTextColor = Color(hex: 0xece7f8)

/// "3h", "1h30m", "45m" - the compact form Akiflow uses under a slot name.
func compactDuration(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    if h > 0 && m > 0 { return "\(h)h\(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

/// Compiled regexes, cached by pattern. Every helper here runs inside a view
/// body - `visibleTitle`, `slotDef`, `slot`, the context menu - so recompiling
/// the pattern per call meant a fresh NSRegularExpression on every frame of a
/// drag, multiplied by every visible row.
/// The seconds digit lives here rather than on `DayState`. It changes once a
/// second, and every view observing DayState was invalidated when it did - so
/// all visible block rows rebuilt once a second, including in the middle of a
/// drag. Only the clock label observes this.
/// Memo for the three derivations that run inside view bodies: the visible title,
/// the decoration scan, and the context-menu links. Each one allocates strings and
/// runs regexes, and each was recomputed per row on every frame of a drag. Titles
/// only change on a rename or a file reload, so during a drag this hits every time.
private final class DerivedCache {
    static let shared = DerivedCache()
    private var titles: [String: String] = [:]
    private var decors: [String: BlockDecor] = [:]
    private var links: [String: [BlockLink]] = [:]
    private let lock = NSLock()

    /// Plan lines number in the dozens, so this never grows meaningfully. The cap
    /// only guards against a pathological file.
    private func trim() {
        if titles.count > 500 { titles.removeAll() }
        if decors.count > 500 { decors.removeAll() }
        if links.count > 500 { links.removeAll() }
    }

    func title(_ key: String, _ make: () -> String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let hit = titles[key] { return hit }
        let made = make(); trim(); titles[key] = made; return made
    }

    func decor(_ key: String, _ make: () -> BlockDecor) -> BlockDecor {
        lock.lock(); defer { lock.unlock() }
        if let hit = decors[key] { return hit }
        let made = make(); trim(); decors[key] = made; return made
    }

    func linkList(_ key: String, _ make: () -> [BlockLink]) -> [BlockLink] {
        lock.lock(); defer { lock.unlock() }
        if let hit = links[key] { return hit }
        let made = make(); trim(); links[key] = made; return made
    }
}

final class SecondsClock: ObservableObject {
    static let shared = SecondsClock()
    @Published var second: Int = 0
}

private final class RegexCache {
    static let shared = RegexCache()
    private var store: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = store[pattern] { return hit }
        guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
        store[pattern] = made
        return made
    }
}

func cachedRegex(_ pattern: String) -> NSRegularExpression? {
    RegexCache.shared.regex(pattern)
}

func strippingMetadataComments(_ text: String) -> String {
    guard let comments = cachedRegex(metadataCommentPattern),
          let runs = cachedRegex(#" {2,}"#) else { return text }
    let once = comments.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: "")
    return runs.stringByReplacingMatches(
        in: once, range: NSRange(once.startIndex..<once.endIndex, in: once), withTemplate: " ")
        .trimmingCharacters(in: .whitespaces)
}

/// The comments themselves, in order, so a rename can put them back.
func metadataComments(in text: String) -> String {
    guard let regex = cachedRegex(metadataCommentPattern) else { return "" }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range)
        .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        .joined(separator: " ")
}

struct Block: Identifiable, Equatable {
    /// Settable so a reload can carry the previous identity over. A fresh UUID per
    /// parse would hand SwiftUI an all-new set of rows on every file read - and the
    /// app reads on its own saves, on FSEvents and on a 2 s poll - which rebuilt the
    /// whole timeline constantly and made in-flight gestures target blocks that no
    /// longer existed, so their edits were dropped.
    var id = UUID()
    var status: BlockStatus
    var startMin: Int   // minutes since midnight
    var endMin: Int
    var title: String   // freeform text after time range, including (Source)

    /// What the timeline shows: the title without its metadata comments.
    var visibleTitle: String {
        DerivedCache.shared.title(title) { strippingMetadataComments(title) }
    }

    var durationMin: Int { endMin - startMin }

    /// The Akiflow time slot this block sits inside, from a `<!-- slot:NAME -->`
    /// marker the planner writes onto the line. Nil when the block belongs to no
    /// slot. Like every metadata comment it never reaches `visibleTitle`.
    /// When set, this block IS a time slot rather than a task: a container that
    /// collapses the blocks carrying the matching `<!-- slot:NAME -->`. Written by
    /// the planner as `<!-- slot-def:NAME -->`.
    var slotDef: String? { Block.marker(named: "slot-def", in: title) }

    var slot: String? { Block.marker(named: "slot", in: title) }

    static func marker(named key: String, in title: String) -> String? {
        guard let regex = cachedRegex("<!--\\s*\(key):(.+?)\\s*-->") else { return nil }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, range: range),
              let r = Range(match.range(at: 1), in: title) else { return nil }
        let name = String(title[r]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }


    /// What makes this the "same" block across a re-parse. Metadata ids survive
    /// time and title edits, so they are the strongest key; the visible title is
    /// the fallback for hand-written lines that carry no ids.
    var identityKey: String {
        let ids = metadataComments(in: title)
        return ids.isEmpty ? "title:\(visibleTitle)" : "ids:\(ids)"
    }

    static func == (lhs: Block, rhs: Block) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.startMin == rhs.startMin &&
        lhs.endMin == rhs.endMin &&
        lhs.title == rhs.title
    }
}

/// Pixel drag delta to a snapped minute delta.
///
/// Two things were wrong before. `Int()` truncates toward zero, so dragging up
/// and dragging down behaved differently and a two-minute dead zone straddled
/// the origin. And the live preview used raw minutes while `.onEnded` snapped to
/// `snapMinutes`, so every drag ended by jumping up to seven minutes away from
/// where the block had been sitting under the cursor. Snapping in one place, used
/// by both the preview and the commit, makes the drag show what it will do.
func snappedMinutes(_ delta: CGFloat, pxPerMin: CGFloat) -> Int {
    guard pxPerMin > 0 else { return 0 }
    let raw = Double(delta / pxPerMin)
    return Int((raw / Double(snapMinutes)).rounded()) * snapMinutes
}

// MARK: - External links

/// A destination the right-click menu can open for a block.
struct BlockLink: Identifiable {
    let label: String
    let url: URL
    var id: String { url.absoluteString }
}

/// Linear workspace slug, used to turn a `lin:UP-858` marker into a URL.
let linearWorkspace = Settings.string("linearWorkspace", default: "dude")

/// Friendly name for a host, so the menu reads "Open in Slack" rather than
/// naming a domain. Unknown hosts fall back to the bare host, which is still
/// more useful than a generic "Open link".
func linkLabel(for url: URL) -> String {
    guard let host = url.host?.lowercased() else { return "Open link" }
    let known: [(String, String)] = [
        ("todoist.com", "Todoist"),
        ("linear.app", "Linear"),
        ("slack.com", "Slack"),
        ("calendar.google.com", "Google Calendar"),
        ("betterstack.com", "Better Stack"),
        ("docs.dude.fi", "Outline"),
        ("github.com", "GitHub"),
    ]
    for (needle, name) in known where host == needle || host.hasSuffix("." + needle) {
        return "Open in \(name)"
    }
    return "Open \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)"
}

func obsidianNoteURL(_ target: String) -> URL? {
    guard let vault = obsidianVaultName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let file = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
    return URL(string: "obsidian://open?vault=\(vault)&file=\(file)")
}

/// Google's own event deep link needs an `eid` that is base64 of
/// "<event id> <calendar id>", and the planner only ever writes the event id.
/// Guessing the calendar lands on an error page, so the day view is used: one
/// click from the event and it always resolves.
func googleCalendarDayURL(for date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = planTimeZone
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return "https://calendar.google.com/calendar/u/0/r/day/\(c.year ?? 2026)/\(c.month ?? 1)/\(c.day ?? 1)"
}

extension Block {
    /// Everything this block can be opened in. The planner's id markers come
    /// first, then any markdown link or `[[wikilink]]` left in the title, so a
    /// Slack thread or a Better Stack incident is reachable without needing a
    /// marker of its own. Deduplicated by URL, because a `lin:` marker and a
    /// markdown link to the same issue are one destination, not two.
    func externalLinks(on date: Date) -> [BlockLink] {
        let dayKey = googleCalendarDayURL(for: date)
        return DerivedCache.shared.linkList("\(title)|\(dayKey)") {
            Block.buildLinks(title: title, dayURL: dayKey)
        }
    }

    private static func buildLinks(title: String, dayURL: String) -> [BlockLink] {
        var found: [BlockLink] = []
        var seen = Set<String>()

        func add(_ label: String, _ url: URL?) {
            guard let url, seen.insert(url.absoluteString).inserted else { return }
            found.append(BlockLink(label: label, url: url))
        }

        if let id = Block.marker(named: "td", in: title) {
            add("Open in Todoist", URL(string: "https://app.todoist.com/app/task/\(id)"))
        }
        if let key = Block.marker(named: "lin", in: title) {
            add("Open in Linear", URL(string: "https://linear.app/\(linearWorkspace)/issue/\(key)"))
        }
        if Block.marker(named: "cal", in: title) != nil {
            add("Open in Google Calendar", URL(string: dayURL))
        }

        for raw in Block.matches(#"\[[^\]]*\]\((https?://[^)\s]+)\)"#, in: title) {
            guard let url = URL(string: raw) else { continue }
            add(linkLabel(for: url), url)
        }

        // Bare URLs too, because a Slack thread usually gets pasted unwrapped.
        // A markdown link's target matches here as well and is dropped by the
        // dedup, so this pass never doubles an entry.
        for raw in Block.matches(#"(https?://[^\s)\]]+)"#, in: title) {
            guard let url = URL(string: raw) else { continue }
            add(linkLabel(for: url), url)
        }

        for target in Block.matches(#"\[\[([^\]|]+)"#, in: title) {
            let name = target.split(separator: "/").last.map(String.init) ?? target
            add("Open note: \(name)", obsidianNoteURL(target))
        }

        return found
    }

    /// Every first capture group of `pattern` in `text`, in order.
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = cachedRegex(pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Block decoration (meeting detection + service icons)

enum ServiceIcon: String, CaseIterable {
    case teams, meet, slack, linear, todoist

    /// Official brand glyph (simple-icons, CC0). 24x24 viewBox path.
    var pathData: String {
        switch self {
        case .slack:
            return "M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z"
        case .teams:
            return "M20.625 8.127q-.55 0-1.025-.205-.475-.205-.832-.563-.358-.357-.563-.832Q18 6.053 18 5.502q0-.54.205-1.02t.563-.837q.357-.358.832-.563.474-.205 1.025-.205.54 0 1.02.205t.837.563q.358.357.563.837.205.48.205 1.02 0 .55-.205 1.025-.205.475-.563.832-.357.358-.837.563-.48.205-1.02.205zm0-3.75q-.469 0-.797.328-.328.328-.328.797 0 .469.328.797.328.328.797.328.469 0 .797-.328.328-.328.328-.797 0-.469-.328-.797-.328-.328-.797-.328zM24 10.002v5.578q0 .774-.293 1.46-.293.685-.803 1.194-.51.51-1.195.803-.686.293-1.459.293-.445 0-.908-.105-.463-.106-.85-.329-.293.95-.855 1.729-.563.78-1.319 1.336-.756.557-1.67.861-.914.305-1.898.305-1.148 0-2.162-.398-1.014-.399-1.805-1.102-.79-.703-1.312-1.664t-.674-2.086h-5.8q-.411 0-.704-.293T0 16.881V6.873q0-.41.293-.703t.703-.293h8.59q-.34-.715-.34-1.5 0-.727.275-1.365.276-.639.75-1.114.475-.474 1.114-.75.638-.275 1.365-.275t1.365.275q.639.276 1.114.75.474.475.75 1.114.275.638.275 1.365t-.275 1.365q-.276.639-.75 1.113-.475.475-1.114.75-.638.276-1.365.276-.188 0-.375-.024-.188-.023-.375-.058v1.078h10.875q.469 0 .797.328.328.328.328.797zM12.75 2.373q-.41 0-.78.158-.368.158-.638.434-.27.275-.428.639-.158.363-.158.773 0 .41.158.78.159.368.428.638.27.27.639.428.369.158.779.158.41 0 .773-.158.364-.159.64-.428.274-.27.433-.639.158-.369.158-.779 0-.41-.158-.773-.159-.364-.434-.64-.275-.275-.639-.433-.363-.158-.773-.158zM6.937 9.814h2.25V7.94H2.814v1.875h2.25v6h1.875zm10.313 7.313v-6.75H12v6.504q0 .41-.293.703t-.703.293H8.309q.152.809.556 1.5.405.691.985 1.19.58.497 1.318.779.738.281 1.582.281.926 0 1.746-.352.82-.351 1.436-.966.615-.616.966-1.43.352-.815.352-1.752zm5.25-1.547v-5.203h-3.75v6.855q.305.305.691.452.387.146.809.146.469 0 .879-.176.41-.175.715-.48.304-.305.48-.715t.176-.879Z"
        case .meet:
            return "M5.53 2.13 0 7.75h5.53zm.398 0v5.62h7.608v3.65l5.47-4.45c-.014-1.22.031-2.25-.025-3.46-.148-1.09-1.287-1.47-2.236-1.36zM23.1 4.32c-.802.295-1.358.995-2.047 1.49-2.506 2.05-4.982 4.12-7.468 6.19 3.025 2.59 6.04 5.18 9.065 7.76 1.218.671 1.428-.814 1.328-1.64v-13a.828.828 0 0 0-.877-.825zM.038 8.15v7.7h5.53v-7.7zm13.577 8.1H6.008v5.62c3.864-.006 7.737.011 11.58-.009 1.02-.07 1.618-1.12 1.468-2.07v-2.51l-5.47-4.68v3.65zm-13.577 0c.02 1.44-.041 2.88.033 4.31.162.948 1.158 1.43 2.047 1.31h3.464v-5.62z"
        case .linear:
            return "M2.886 4.18A11.982 11.982 0 0 1 11.99 0C18.624 0 24 5.376 24 12.009c0 3.64-1.62 6.903-4.18 9.105L2.887 4.18ZM1.817 5.626l16.556 16.556c-.524.33-1.075.62-1.65.866L.951 7.277c.247-.575.537-1.126.866-1.65ZM.322 9.163l14.515 14.515c-.71.172-1.443.282-2.195.322L0 11.358a12 12 0 0 1 .322-2.195Zm-.17 4.862 9.823 9.824a12.02 12.02 0 0 1-9.824-9.824Z"
        case .todoist:
            return "M21 0H3C1.35 0 0 1.35 0 3v3.858s3.854 2.24 4.098 2.38c.31.18.694.177 1.004 0 .26-.147 8.02-4.608 8.136-4.675.279-.161.58-.107.748-.01.164.097.606.348.84.48.232.134.221.502.013.622l-9.712 5.59c-.346.2-.69.204-1.048.002C3.478 10.907.998 9.463 0 8.882v2.02l4.098 2.38c.31.18.694.177 1.004 0 .26-.147 8.02-4.609 8.136-4.676.279-.16.58-.106.748-.008.164.096.606.347.84.48.232.133.221.5.013.62-.208.121-9.288 5.346-9.712 5.59-.346.2-.69.205-1.048.002C3.478 14.951.998 13.506 0 12.926v2.02l4.098 2.38c.31.18.694.177 1.004 0 .26-.147 8.02-4.609 8.136-4.676.279-.16.58-.106.748-.009.164.097.606.348.84.48.232.133.221.502.013.622l-9.712 5.59c-.346.199-.69.204-1.048.001C3.478 18.994.998 17.55 0 16.97V21c0 1.65 1.35 3 3 3h18c1.65 0 3-1.35 3-3V3c0-1.65-1.35-3-3-3z"
        }
    }

    /// Official brand color.
    var brand: Color {
        switch self {
        case .teams: return Color(red: 0x62/255.0, green: 0x64/255.0, blue: 0xA7/255.0)
        case .meet: return Color(red: 0x1A/255.0, green: 0x73/255.0, blue: 0xE8/255.0)
        case .slack: return Color(red: 0x4A/255.0, green: 0x15/255.0, blue: 0x4B/255.0)
        case .linear: return Color(red: 0x08/255.0, green: 0x09/255.0, blue: 0x0A/255.0)
        case .todoist: return Color(red: 0xE4/255.0, green: 0x43/255.0, blue: 0x32/255.0)
        }
    }

    /// Background fill opacity (normal, hovered, faded-when-done/skipped).
    /// Linear's near-black needs more weight to register on the dark window.
    var fillOpacity: (base: Double, hover: Double, faded: Double) {
        switch self {
        case .linear: return (0.60, 0.75, 0.40)
        default: return (0.32, 0.46, 0.18)
        }
    }
}

// MARK: - Minimal SVG path renderer (24x24 viewBox -> Path)

struct SVGPathShape: Shape {
    let pathData: String

    func path(in rect: CGRect) -> Path {
        let raw = SVGPathParser.path(from: pathData)
        let scale = min(rect.width, rect.height) / 24.0
        let dx = (rect.width - 24.0 * scale) / 2.0
        let dy = (rect.height - 24.0 * scale) / 2.0
        let transform = CGAffineTransform(translationX: rect.minX + dx, y: rect.minY + dy)
            .scaledBy(x: scale, y: scale)
        return raw.applying(transform)
    }
}

enum SVGPathParser {
    static func path(from d: String) -> Path {
        var path = Path()
        let scanner = Scanner(d)
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicCtrl: CGPoint?
        var lastQuadCtrl: CGPoint?
        var cmd: Character = " "

        while let token = scanner.nextToken() {
            if case let .command(c) = token {
                cmd = c
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    cur = start
                    lastCubicCtrl = nil
                    lastQuadCtrl = nil
                }
                continue
            }
            // token is a number; push it back and let the command handler read.
            scanner.pushBack(token)

            let rel = cmd.isLowercase
            func num() -> CGFloat { scanner.nextNumber() ?? 0 }
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(cmd.lowercased()) {
            case "m":
                let p = pt(num(), num())
                path.move(to: p); cur = p; start = p
                cmd = rel ? "l" : "L"
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "l":
                let p = pt(num(), num())
                path.addLine(to: p); cur = p
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "h":
                let x = num()
                let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                path.addLine(to: p); cur = p
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "v":
                let y = num()
                let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                path.addLine(to: p); cur = p
                lastCubicCtrl = nil; lastQuadCtrl = nil
            case "c":
                let c1 = pt(num(), num())
                let c2 = pt(num(), num())
                let e = pt(num(), num())
                path.addCurve(to: e, control1: c1, control2: c2)
                cur = e; lastCubicCtrl = c2; lastQuadCtrl = nil
            case "s":
                let c1 = lastCubicCtrl.map { CGPoint(x: 2*cur.x - $0.x, y: 2*cur.y - $0.y) } ?? cur
                let c2 = pt(num(), num())
                let e = pt(num(), num())
                path.addCurve(to: e, control1: c1, control2: c2)
                cur = e; lastCubicCtrl = c2; lastQuadCtrl = nil
            case "q":
                let c = pt(num(), num())
                let e = pt(num(), num())
                path.addQuadCurve(to: e, control: c)
                cur = e; lastQuadCtrl = c; lastCubicCtrl = nil
            case "t":
                let c = lastQuadCtrl.map { CGPoint(x: 2*cur.x - $0.x, y: 2*cur.y - $0.y) } ?? cur
                let e = pt(num(), num())
                path.addQuadCurve(to: e, control: c)
                cur = e; lastQuadCtrl = c; lastCubicCtrl = nil
            case "a":
                let rx = num(), ry = num(), rot = num()
                let large = num() != 0, sweep = num() != 0
                let e = pt(num(), num())
                addArc(&path, from: cur, to: e, rx: rx, ry: ry,
                       xRotDeg: rot, largeArc: large, sweep: sweep)
                cur = e; lastCubicCtrl = nil; lastQuadCtrl = nil
            default:
                break
            }
        }
        return path
    }

    /// Endpoint-to-center SVG arc conversion, approximated with cubic beziers.
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, xRotDeg: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        if rxIn == 0 || ryIn == 0 || (p0 == p1) {
            path.addLine(to: p1); return
        }
        var rx = abs(rxIn), ry = abs(ryIn)
        let phi = xRotDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        var lam = (x1p*x1p)/(rx*rx) + (y1p*y1p)/(ry*ry)
        if lam > 1 { let s = sqrt(lam); rx *= s; ry *= s; lam = 1 }
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p)
        let den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
        let co = sign * sqrt(den == 0 ? 0 : num/den)
        let cxp = co * (rx * y1p / ry)
        let cyp = co * (-ry * x1p / rx)
        let cx = cosP*cxp - sinP*cyp + (p0.x + p1.x)/2
        let cy = sinP*cxp + cosP*cyp + (p0.y + p1.y)/2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux*vx + uy*vy
            let len = sqrt((ux*ux+uy*uy)*(vx*vx+vy*vy))
            var a = acos(min(1, max(-1, len == 0 ? 1 : dot/len)))
            if ux*vy - uy*vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p-cxp)/rx, (y1p-cyp)/ry)
        var dTheta = angle((x1p-cxp)/rx, (y1p-cyp)/ry, (-x1p-cxp)/rx, (-y1p-cyp)/ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var ang = theta1
        for _ in 0..<segments {
            let cos1 = cos(ang), sin1 = sin(ang)
            let cos2 = cos(ang + delta), sin2 = sin(ang + delta)
            func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                CGPoint(x: cosP*rx*ex - sinP*ry*ey + cx,
                        y: sinP*rx*ex + cosP*ry*ey + cy)
            }
            let e2 = map(cos2, sin2)
            let c1 = map(cos1 - t*sin1, sin1 + t*cos1)
            let c2 = map(cos2 + t*sin2, sin2 - t*cos2)
            path.addCurve(to: e2, control1: c1, control2: c2)
            ang += delta
        }
    }

    enum Token { case command(Character); case number(CGFloat) }

    final class Scanner {
        private let chars: [Character]
        private var i = 0
        private var pushed: Token?

        init(_ s: String) { chars = Array(s) }

        func pushBack(_ t: Token) { pushed = t }

        func nextToken() -> Token? {
            if let p = pushed { pushed = nil; return p }
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter { i += 1; return .command(c) }
            if let n = scanNumber() { return .number(n) }
            return nil
        }

        func nextNumber() -> CGFloat? {
            if let p = pushed {
                pushed = nil
                if case let .number(v) = p { return v }
                return nil
            }
            skipSeparators()
            return scanNumber()
        }

        private func skipSeparators() {
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 }
                else { break }
            }
        }

        private func scanNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            var seenDot = false
            if i < chars.count, chars[i] == "-" || chars[i] == "+" {
                s.append(chars[i]); i += 1
            }
            while i < chars.count {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1
                } else if c == "." {
                    if seenDot { break } // second dot starts a new number
                    seenDot = true; s.append(c); i += 1
                } else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" {
                        s.append(chars[i]); i += 1
                    }
                } else {
                    break
                }
            }
            guard let v = Double(s) else { return nil }
            return CGFloat(v)
        }
    }
}

/// The official Dude mint, used to flag meeting blocks.
let meetingMint = Color(red: 0x7E/255.0, green: 0xFF/255.0, blue: 0xE1/255.0)

struct BlockDecor {
    let isMeeting: Bool
    let services: [ServiceIcon]

    /// Exactly one icon per block: first match in detection priority order
    /// (teams, meet, slack, linear, todoist).
    var primary: ServiceIcon? { services.first }

    /// Case-insensitive keywords that mark a block as a meeting.
    /// "Dude x" is matched case-sensitively as an explicit exception.
    static let meetingKeywords = [
        "daily standup", "standup", "daily", "weekly", "monthly",
        "retro", "retrospective", "planning", "grooming", "refinement",
        "sync", "1:1", "1-on-1", "google meet", "meet.google.com",
        "teams.microsoft.com", "microsoft teams", "lounas", "lunch",
        "huddle", "palaveri", "kokous", "demo", "catch-up", "catchup"
    ]

    static func compute(for title: String) -> BlockDecor {
        let lower = title.lowercased()
        var isMeeting = meetingKeywords.contains { lower.contains($0) }
        if title.contains("Dude x") { isMeeting = true } // case-sensitive exception

        var services: [ServiceIcon] = []
        if lower.contains("teams.microsoft.com") || lower.contains("microsoft teams")
            || title.range(of: #"\bteams\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            services.append(.teams)
        }
        // Slack (huddle / standup) wins over a generic Calendar/Meet link.
        if lower.contains("slack") || lower.contains("huddle") || lower.contains("standup") {
            services.append(.slack)
        }
        if lower.contains("meet.google.com") || lower.contains("google meet")
            || lower.contains("calendar") {
            services.append(.meet)
        }
        if title.range(of: #"\b[A-Z]{2,}-\d+\b"#, options: .regularExpression) != nil
            || lower.contains("linear.app") {
            services.append(.linear)
        }
        if lower.contains("todoist") {
            services.append(.todoist)
        }
        return BlockDecor(isMeeting: isMeeting, services: services)
    }
}

// MARK: - Plan file parser/writer

struct PlanFile {
    /// Parses the `## Day Planner` section. Returns blocks plus the original
    /// pre/post sections of the file so we can rewrite without touching them.
    static func parse(_ text: String) -> (preDayPlanner: String, blocks: [Block], postDayPlanner: String, dayPlannerHeader: String) {
        let lines = text.components(separatedBy: "\n")
        var idx = 0

        // Find the Day Planner heading
        var dayPlannerStart: Int?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("## day planner") {
                dayPlannerStart = i
                break
            }
        }

        guard let start = dayPlannerStart else {
            // No Day Planner section. Whole file is "pre", no blocks.
            return (text, [], "", "")
        }

        // Find the next ## heading or EOF
        var dayPlannerEnd = lines.count
        for i in (start + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                dayPlannerEnd = i
                break
            }
        }

        let pre = lines[0..<start].joined(separator: "\n")
        let header = lines[start]
        let body = Array(lines[(start + 1)..<dayPlannerEnd])
        let post = lines[dayPlannerEnd..<lines.count].joined(separator: "\n")

        var blocks: [Block] = []
        for line in body {
            if let block = parseBlockLine(line) {
                blocks.append(block)
            }
            idx += 1
        }

        return (pre, blocks, post, header)
    }

    /// Parses a single line like `- [ ] 10:00 - 11:00 Task name (Source)`.
    static func parseBlockLine(_ line: String) -> Block? {
        let pattern = #"^\s*-\s*\[([ x>\-])\]\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s+(.+)$"#
        guard let regex = cachedRegex(pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }

        func substr(_ idx: Int) -> String {
            let r = match.range(at: idx)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: line) else { return "" }
            return String(line[swiftRange])
        }

        let statusToken = substr(1)
        let h1 = Int(substr(2)) ?? 0
        let m1 = Int(substr(3)) ?? 0
        let h2 = Int(substr(4)) ?? 0
        let m2 = Int(substr(5)) ?? 0
        let title = substr(6).trimmingCharacters(in: .whitespaces)

        let status: BlockStatus
        switch statusToken {
        case " ": status = .planned
        case ">": status = .inProgress
        case "x", "X": status = .done
        case "-": status = .skipped
        default: status = .planned
        }

        return Block(status: status, startMin: h1 * 60 + m1, endMin: h2 * 60 + m2, title: title)
    }

    /// Render blocks back into Day Planner section lines. Order by startMin.
    static func renderBlocks(_ blocks: [Block]) -> String {
        let sorted = blocks.sorted { $0.startMin < $1.startMin }
        return sorted.map { block in
            let h1 = block.startMin / 60
            let m1 = block.startMin % 60
            let h2 = block.endMin / 60
            let m2 = block.endMin % 60
            let timeRange = String(format: "%02d:%02d - %02d:%02d", h1, m1, h2, m2)
            return "- [\(block.status.token)] \(timeRange) \(block.title)"
        }.joined(separator: "\n")
    }

    /// Reassemble the file, replacing only the Day Planner section.
    static func reassemble(pre: String, header: String, blocks: [Block], post: String) -> String {
        var out = ""
        out += pre
        if !pre.isEmpty && !pre.hasSuffix("\n") { out += "\n" }
        out += header
        out += "\n\n"
        out += renderBlocks(blocks)
        out += "\n\n"
        if post.hasPrefix("\n") {
            out += String(post.dropFirst())
        } else {
            out += post
        }
        return out
    }

    /// Atomic write via temp + rename.
    static func atomicWrite(path: String, content: String) throws {
        let url = URL(fileURLWithPath: path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}

// MARK: - File watcher (FSEvents via DispatchSource)

class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var watchedPath: String = ""
    var onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(path: String) {
        watchedPath = path
        rewatch()
    }

    private func rewatch() {
        stop()
        // Watch the FILE itself, not its parent directory. Editing the file's
        // contents does not change the directory's mtime, so a directory watch
        // misses Obsidian's saves. The trade-off: when an editor does atomic
        // write (write tmp + rename), our fd becomes stale on .rename / .delete
        // and we have to re-open.
        guard !watchedPath.isEmpty else { return }
        let cPath = (watchedPath as NSString).utf8String
        guard let cPath = cPath else { return }
        fd = open(cPath, O_EVTONLY)
        if fd < 0 {
            // File doesn't exist yet - retry shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.rewatch()
            }
            return
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib, .revoke],
            queue: DispatchQueue.main
        )
        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = self.source?.data ?? []
            self.onChange()
            // If the file was renamed, deleted, or revoked, re-open against the
            // path so we keep tracking the new inode.
            if event.contains(.rename) || event.contains(.delete) || event.contains(.revoke) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.rewatch()
                }
            }
        }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}

// MARK: - View model

class DayState: ObservableObject {
    @Published var blocks: [Block] = []
    @Published var dateString: String = ""
    @Published var lastError: String?
    @Published var nowMinute: Int = 0
    @Published var zoom: Double = {
        let saved = UserDefaults.standard.double(forKey: "day-timeline.zoom")
        return (saved >= zoomMin && saved <= zoomMax) ? saved : 1.0
    }()

    var pixelsPerMinute: CGFloat { basePixelsPerMinute * CGFloat(zoom) }

    private var pre: String = ""
    private var post: String = ""
    private var header: String = "## Day Planner"
    private let watcher: FileWatcher
    private var saveDebounceTimer: Timer?
    private var clockTimer: Timer?
    private var mtimeTimer: Timer?
    private var lastMtime: Date?
    private(set) var date: Date = Date()
    private var savingNow: Bool = false
    /// Set while a drag or resize is in flight. Reloading under a live gesture
    /// resets its @GestureState and yanks the block out from under it.
    var isInteracting: Bool = false
    /// The slot currently opened in its own window, if any. Members are never
    /// drawn inline in the main timeline: they overlapped the slot's own label and
    /// were unreadable, and a slot three hours tall has no room for them anyway.
    @Published var openSlotName: String? = nil
    /// Single click selects; double click acts. Selection is view state but lives
    /// here so a slot and its blocks cannot disagree about what is selected.
    @Published var selectedBlockId: UUID? = nil
    /// The slot popup's edit state lives here rather than in the view, so the
    /// Escape monitor can cancel an edit instead of closing the whole window.
    @Published var slotRenamingBlockId: UUID? = nil
    @Published var slotRenamingText: String = ""
    @Published var slotTitleEditing: Bool = false

    var slotWindowIsEditing: Bool { slotRenamingBlockId != nil || slotTitleEditing }

    func clearSlotEditing() {
        slotRenamingBlockId = nil
        slotRenamingText = ""
        slotTitleEditing = false
    }
    private var lastAutoCompleteCheckMinute: Int = Int.min

    init() {
        self.watcher = FileWatcher(onChange: {})
        self.watcher.onChange = { [weak self] in self?.handleExternalChange() }
        loadToday()
        startClock()
        startMtimePoll()
    }

    private func startMtimePoll() {
        mtimeTimer?.invalidate()
        mtimeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkMtime()
        }
    }

    private func checkMtime() {
        let path = planFilePath(for: date)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if let last = lastMtime, mtime == last { return }
        // Debounce against our own writes. Bail BEFORE recording the mtime:
        // recording it first marks the change as seen, so an external edit that
        // lands mid-save is skipped here and then looks unchanged on every later
        // poll. The edit is lost until something else touches the file.
        if savingNow { return }
        if isInteracting { return }
        lastMtime = mtime
        loadFromDisk()
    }

    // MARK: zoom

    func zoomIn() { setZoom(zoom * 1.2) }
    func zoomOut() { setZoom(zoom / 1.2) }
    func zoomBy(delta: Double) {
        // delta in arbitrary units; 1 unit ~= 8% change
        let factor = pow(1.08, delta)
        setZoom(zoom * factor)
    }
    func setZoom(_ value: Double) {
        zoom = min(max(value, zoomMin), zoomMax)
        UserDefaults.standard.set(zoom, forKey: "day-timeline.zoom")
    }

    // MARK: status changes with (done HH:MM) tagging

    func setStatus(_ block: Block, _ status: BlockStatus) {
        guard let idx = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        if blocks[idx].status == status { return }
        blocks[idx].status = status
        blocks[idx].title = applyDoneTag(blocks[idx].title, status: status)
        scheduleSave()
    }

    private func applyDoneTag(_ title: String, status: BlockStatus, at minute: Int? = nil) -> String {
        let stripped = stripDoneTag(title)
        if status == .done {
            let m = minute ?? nowMinute
            let nowStr = String(format: "%02d:%02d", m / 60, m % 60)
            return "\(stripped) (done \(nowStr))"
        }
        return stripped
    }

    private func stripDoneTag(_ title: String) -> String {
        let pattern = #"\s*\(done \d{1,2}:\d{2}\)\s*$"#
        guard let regex = cachedRegex(pattern) else { return title }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    deinit {
        watcher.stop()
        clockTimer?.invalidate()
        mtimeTimer?.invalidate()
    }

    func loadToday() {
        date = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = planTimeZone
        let comps = cal.dateComponents([.day, .month, .year, .weekday], from: date)
        let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekdayName = dayNames[comps.weekday ?? 1]
        dateString = "\(weekdayName) \(comps.day ?? 0).\(comps.month ?? 0).\(comps.year ?? 0)"
        loadFromDisk()
        watcher.watch(path: planFilePath(for: date))
    }

    private func loadFromDisk() {
        let path = planFilePath(for: date)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            blocks = []
            pre = ""
            post = ""
            lastError = "No plan file for today: \(path)"
            return
        }
        let parsed = PlanFile.parse(text)
        self.pre = parsed.preDayPlanner
        self.post = parsed.postDayPlanner
        self.header = parsed.dayPlannerHeader.isEmpty ? "## Day Planner" : parsed.dayPlannerHeader
        self.blocks = Self.carryingIds(from: self.blocks, onto: parsed.blocks)
        self.lastError = nil
        self.lastAutoCompleteCheckMinute = Int.min
        autoCompleteElapsed()
        autoGroupOverlaps()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mtime = attrs[.modificationDate] as? Date {
            self.lastMtime = mtime
        }
    }

    /// Re-use the previous identity for any block the re-parse produced a
    /// counterpart for, so SwiftUI diffs rows instead of replacing them all.
    private static func carryingIds(from old: [Block], onto new: [Block]) -> [Block] {
        guard !old.isEmpty else { return new }
        var pool: [String: [UUID]] = [:]
        for block in old { pool[block.identityKey, default: []].append(block.id) }
        return new.map { block in
            var copy = block
            if var queue = pool[block.identityKey], let reused = queue.first {
                queue.removeFirst()
                pool[block.identityKey] = queue
                copy.id = reused
            }
            return copy
        }
    }

    private func handleExternalChange() {
        // If we triggered the change ourselves, ignore.
        if savingNow { return }
        if isInteracting { return }
        // Debounce: wait 200ms in case multiple events fire
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.loadFromDisk()
        }
    }

    func cycleStatus(_ block: Block) {
        guard let idx = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let newStatus = blocks[idx].status.cycle()
        blocks[idx].status = newStatus
        blocks[idx].title = applyDoneTag(blocks[idx].title, status: newStatus)
        scheduleSave()
    }

    func updateTitle(_ block: Block, newTitle: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        if blocks[idx].title != newTitle {
            blocks[idx].title = newTitle
            scheduleSave()
        }
    }

    func updateTime(_ block: Block, newStartMin: Int, newEndMin: Int) {
        guard let idx = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let snappedStart = snap(newStartMin)
        let snappedEnd = max(snappedStart + snapMinutes, snap(newEndMin))
        if blocks[idx].startMin != snappedStart || blocks[idx].endMin != snappedEnd {
            blocks[idx].startMin = snappedStart
            blocks[idx].endMin = snappedEnd
            scheduleSave()
        }
    }

    /// Dragging a slot moves everything inside it, the way Akiflow does. Resizing
    /// does not: stretching a container must not stretch the tasks it holds.
    /// Blocks whose times overlap are unreadable stacked on one another, so any
    /// cluster of them is folded into a slot automatically. Only ungrouped,
    /// non-slot blocks are considered, which makes this idempotent and leaves
    /// hand-made slots and renamed auto slots alone.
    func autoGroupOverlaps() {
        mergeOverlappingSlots()
        absorbIntoExistingSlots()
        let loose = blocks.enumerated()
            .filter { $0.element.slotDef == nil && $0.element.slot == nil }
            .sorted { $0.element.startMin < $1.element.startMin }
        guard loose.count > 1 else { return }

        var clusters: [[Int]] = []
        var current: [Int] = [loose[0].offset]
        var clusterEnd = loose[0].element.endMin
        for entry in loose.dropFirst() {
            if entry.element.startMin < clusterEnd {
                current.append(entry.offset)
                clusterEnd = max(clusterEnd, entry.element.endMin)
            } else {
                clusters.append(current)
                current = [entry.offset]
                clusterEnd = entry.element.endMin
            }
        }
        clusters.append(current)

        var created = false
        for cluster in clusters where cluster.count > 1 {
            let starts = cluster.map { blocks[$0].startMin }
            let ends = cluster.map { blocks[$0].endMin }
            let name = uniqueAutoSlotName(count: cluster.count)
            for idx in cluster {
                blocks[idx].title += " <!-- slot:\(name) -->"
            }
            var slot = Block(status: .planned,
                             startMin: starts.min() ?? 0,
                             endMin: ends.max() ?? 0,
                             title: "\(name) <!-- slot-def:\(name) --> <!-- slot-auto -->")
            slot.id = UUID()
            blocks.append(slot)
            created = true
        }
        if created { scheduleSave() }
    }

    /// Two slots covering the same minutes is not a thing that exists. A time slot
    /// is a container for a stretch of the day, so overlapping slots are one slot
    /// that got split in two. The earlier one keeps its name and swallows the other.
    private func mergeOverlappingSlots() {
        var didMerge = true
        var passes = 0
        while didMerge && passes < 20 {
            didMerge = false
            passes += 1
            let slots = blocks.enumerated()
                .filter { $0.element.slotDef != nil }
                .sorted { $0.element.startMin < $1.element.startMin }
            guard slots.count > 1 else { break }
            outer: for i in 0..<(slots.count - 1) {
                for j in (i + 1)..<slots.count {
                    let a = slots[i], b = slots[j]
                    guard a.element.startMin < b.element.endMin,
                          a.element.endMin > b.element.startMin,
                          let keep = a.element.slotDef,
                          let drop = b.element.slotDef else { continue }
                    blocks[a.offset].startMin = min(a.element.startMin, b.element.startMin)
                    blocks[a.offset].endMin = max(a.element.endMin, b.element.endMin)
                    for idx in blocks.indices where blocks[idx].slot == drop {
                        blocks[idx].title = blocks[idx].title
                            .replacingOccurrences(of: "<!-- slot:\(drop) -->", with: "<!-- slot:\(keep) -->")
                    }
                    let dropId = b.element.id
                    blocks.removeAll { $0.id == dropId }
                    didMerge = true
                    break outer
                }
            }
            if didMerge { scheduleSave() }
        }
    }

    /// A block sitting inside an existing slot's span belongs to that slot. Without
    /// this, auto-grouping built a second slot over the same hour and the two
    /// containers overlapped each other, which looked far worse than the original
    /// stacked blocks.
    private func absorbIntoExistingSlots() {
        let slotRanges: [(String, Int, Int)] = blocks.compactMap {
            guard let name = $0.slotDef else { return nil }
            return (name, $0.startMin, $0.endMin)
        }
        guard !slotRanges.isEmpty else { return }
        var changed = false
        for idx in blocks.indices {
            guard blocks[idx].slotDef == nil, blocks[idx].slot == nil else { continue }
            let s = blocks[idx].startMin, e = blocks[idx].endMin
            if let hit = slotRanges.first(where: { s < $0.2 && e > $0.1 }) {
                blocks[idx].title += " <!-- slot:\(hit.0) -->"
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    /// "3 tasks", or "3 tasks 2" when a slot by that name already exists.
    private func uniqueAutoSlotName(count: Int) -> String {
        let base = "\(count) tasks"
        let taken = Set(blocks.compactMap { $0.slotDef })
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Sequences a slot's members so none overlap. Order and durations are kept;
    /// a block that would start before the previous one ends is pushed down to
    /// meet it. The slot grows if the cascade runs past its end.
    /// Returns how many blocks moved, so the popup can say it happened rather
    /// than silently rewriting the plan.
    @discardableResult
    func cascadeOverlaps(inSlot name: String) -> Int {
        let ordered = blocks.enumerated()
            .filter { $0.element.slot == name && $0.element.slotDef == nil }
            .sorted {
                $0.element.startMin != $1.element.startMin
                    ? $0.element.startMin < $1.element.startMin
                    : $0.element.endMin < $1.element.endMin
            }
        guard ordered.count > 1 else { return 0 }

        var moved = 0
        var cursor = ordered[0].element.endMin
        for entry in ordered.dropFirst() {
            let idx = entry.offset
            if blocks[idx].startMin < cursor {
                let duration = max(snapMinutes, blocks[idx].endMin - blocks[idx].startMin)
                blocks[idx].startMin = cursor
                blocks[idx].endMin = cursor + duration
                moved += 1
            }
            cursor = max(cursor, blocks[idx].endMin)
        }
        if moved > 0 {
            if let sIdx = blocks.firstIndex(where: { $0.slotDef == name }), blocks[sIdx].endMin < cursor {
                blocks[sIdx].endMin = cursor
            }
            scheduleSave()
        }
        return moved
    }

    /// Renaming a slot has to move its members too, or they orphan.
    func renameSlot(from old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != old else { return }
        for idx in blocks.indices {
            if blocks[idx].slotDef == old {
                blocks[idx].title = blocks[idx].title
                    .replacingOccurrences(of: "<!-- slot-def:\(old) -->", with: "<!-- slot-def:\(trimmed) -->")
                let visible = strippingMetadataComments(blocks[idx].title)
                if visible == old {
                    blocks[idx].title = blocks[idx].title.replacingOccurrences(of: old, with: trimmed, options: [], range: blocks[idx].title.range(of: old))
                }
            }
            if blocks[idx].slot == old {
                blocks[idx].title = blocks[idx].title
                    .replacingOccurrences(of: "<!-- slot:\(old) -->", with: "<!-- slot:\(trimmed) -->")
            }
        }
        if openSlotName == old { openSlotName = trimmed }
        scheduleSave()
    }

    func members(ofSlot name: String) -> [Block] {
        blocks.filter { $0.slot == name && $0.slotDef == nil }
            .sorted { $0.startMin < $1.startMin }
    }

    func slotBlock(named name: String) -> Block? {
        blocks.first { $0.slotDef == name }
    }

    func moveSlot(_ slot: Block, byMinutes delta: Int) {
        guard let name = slot.slotDef, delta != 0 else { return }
        for idx in blocks.indices where blocks[idx].slot == name && blocks[idx].slotDef == nil {
            blocks[idx].startMin = max(0, blocks[idx].startMin + delta)
            blocks[idx].endMin = max(0, blocks[idx].endMin + delta)
        }
        guard let sIdx = blocks.firstIndex(where: { $0.id == slot.id }) else { return }
        blocks[sIdx].startMin = max(0, blocks[sIdx].startMin + delta)
        blocks[sIdx].endMin = max(0, blocks[sIdx].endMin + delta)
        scheduleSave()
    }

    func addBlock(at startMin: Int) {
        let snapped = snap(startMin)
        let block = Block(status: .planned, startMin: snapped, endMin: snapped + 30, title: "New block")
        blocks.append(block)
        scheduleSave()
    }

    func deleteBlock(_ block: Block) {
        blocks.removeAll { $0.id == block.id }
        scheduleSave()
    }

    private func snap(_ min: Int) -> Int {
        let snapped = Int(round(Double(min) / Double(snapMinutes))) * snapMinutes
        return max(0, snapped)
    }

    private func scheduleSave() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.saveToDisk()
        }
    }

    private func saveToDisk() {
        let path = planFilePath(for: date)
        let content = PlanFile.reassemble(pre: pre, header: header, blocks: blocks, post: post)
        savingNow = true
        do {
            try PlanFile.atomicWrite(path: path, content: content)
            lastError = nil
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                self.lastMtime = mtime
            }
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.savingNow = false
        }
    }

    private func startClock() {
        updateNow()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateNow()
        }
    }

    private func updateNow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = planTimeZone
        let comps = cal.dateComponents([.hour, .minute, .second], from: Date())
        nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        SecondsClock.shared.second = comps.second ?? 0
        autoCompleteElapsed()
    }

    private func autoCompleteElapsed() {
        var changed = false
        for i in blocks.indices {
            let b = blocks[i]
            guard b.status == .planned || b.status == .inProgress else { continue }
            if b.endMin > lastAutoCompleteCheckMinute && b.endMin <= nowMinute {
                blocks[i].status = .done
                blocks[i].title = applyDoneTag(b.title, status: .done, at: b.endMin)
                changed = true
            }
        }
        lastAutoCompleteCheckMinute = nowMinute
        if changed { scheduleSave() }
    }
}

// MARK: - Views

struct DayTimelineView: View {
    @ObservedObject var state: DayState
    @State private var renamingBlockId: UUID?
    @State private var renamingText: String = ""
    @State private var escapeMonitor: Any?
    @AppStorage("day-timeline.followNow") private var followNow: Bool = true

    private var dayStartMin: Int {
        let earliest = state.blocks.map(\.startMin).min() ?? (dayStart * 60)
        return min(dayStart * 60, earliest)
    }

    private var dayEndMin: Int {
        let latest = state.blocks.map(\.endMin).max() ?? (dayEnd * 60)
        return max(dayEnd * 60, latest)
    }

    private var pxPerMin: CGFloat { state.pixelsPerMinute }

    private var totalHeight: CGFloat {
        CGFloat(dayEndMin - dayStartMin) * pxPerMin
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            hourGrid
                            // Behind the blocks: a click that hits nothing clears
                            // selection and any in-flight rename.
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { clearInteraction() }
                            blocksLayer
                            nowIndicator
                            nowAnchor
                        }
                        .frame(height: totalHeight)
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(nil) {
                                proxy.scrollTo("now-anchor", anchor: .center)
                            }
                        }
                    }
                    .onChange(of: state.nowMinute) { _ in
                        guard followNow else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("now-anchor", anchor: .center)
                        }
                    }
                    .onChange(of: followNow) { enabled in
                        guard enabled else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("now-anchor", anchor: .center)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                addBlockButton
                followToggle
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            zoomControls
                .padding(12)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { installEscapeMonitor() }
        .onDisappear {
            if let m = escapeMonitor { NSEvent.removeMonitor(m) }
            escapeMonitor = nil
        }
    }

    /// SwiftUI's .onExitCommand does not reach a focused TextField, so Escape fell
    /// through to AppKit unhandled and produced the error beep. Returning nil from
    /// a local monitor both handles the key and swallows the beep.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event } // 53 = Escape
            // The slot window carries the slot's name as its title, which is how we
            // tell the two windows apart from a single app-wide monitor.
            if let open = state.openSlotName, NSApp.keyWindow?.title == open {
                // Escape cancels the edit first; only a second press closes the window.
                if state.slotWindowIsEditing {
                    state.clearSlotEditing()
                    NSApp.keyWindow?.makeFirstResponder(nil)
                } else {
                    state.openSlotName = nil
                }
                return nil
            }
            let wasActive = renamingBlockId != nil || state.selectedBlockId != nil
            clearInteraction()
            NSApp.keyWindow?.makeFirstResponder(nil)
            return wasActive ? nil : event
        }
    }

    private var addBlockButton: some View {
        Button(action: {
            let now = state.nowMinute
            let snap = ((now / snapMinutes) + 1) * snapMinutes
            let start = max(dayStartMin, min(dayEndMin - 30, snap))
            state.addBlock(at: start)
        }) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.92))
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
        .keyboardShortcut("n", modifiers: .command)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var followToggle: some View {
        Button(action: { followNow.toggle() }) {
            Image(systemName: followNow ? "scope" : "arrow.up.and.down")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.92))
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
        .help(followNow ? "Keep now centered: on" : "Keep now centered: off")
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button(action: { state.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("-", modifiers: .command)

            Divider().frame(height: 16)

            Button(action: { state.setZoom(1.0) }) {
                Text("\(Int(state.zoom * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0", modifiers: .command)

            Divider().frame(height: 16)

            Button(action: { state.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("=", modifiers: .command)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.92))
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.dateString)
                .font(.custom("Instrument Serif", size: 22))
            Spacer()
            ClockLabel(minute: state.nowMinute)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func timeWithSecondsStr(_ minute: Int, _ second: Int) -> String {
        String(format: "%02d:%02d:%02d", minute / 60, minute % 60, second)
    }

    private var hourGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stride(from: dayStartMin, through: dayEndMin, by: 60)), id: \.self) { m in
                HStack(alignment: .top, spacing: 0) {
                    Text(timeStr(m))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .padding(.trailing, 6)
                        .offset(y: -5) // center label on the line, keep line at the exact hour
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 1)
                }
                .frame(height: 60 * pxPerMin, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Slot members never render in the main timeline. The slot row stands in for
    /// them and opens them in a dedicated window instead.
    private var slotDefs: [Block] { state.blocks.filter { $0.slotDef != nil } }

    private var definedSlotNames: Set<String> { Set(slotDefs.compactMap { $0.slotDef }) }

    private var looseBlocks: [Block] {
        state.blocks.filter { block in
            guard block.slotDef == nil else { return true == false }
            if let slot = block.slot, definedSlotNames.contains(slot) { return false }
            return true
        }
    }

    private var blocksLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slotDefs) { slot in
                SlotRow(
                    block: slot,
                    memberCount: state.members(ofSlot: slot.slotDef ?? "").count,
                    isExpanded: state.openSlotName == slot.slotDef,
                    state: state,
                    dayStartMin: dayStartMin,
                    onToggle: { toggleSlot(slot.slotDef ?? "") }
                )
            }
            ForEach(looseBlocks) { block in
                blockView(block)
            }
        }
        .padding(.leading, 56) // leave hour-label gutter
    }

    /// Esc and clicks on empty space both land here.
    private func clearInteraction() {
        renamingBlockId = nil
        renamingText = ""
        state.selectedBlockId = nil
    }

    private func toggleSlot(_ name: String) {
        guard !name.isEmpty else { return }
        state.openSlotName = (state.openSlotName == name) ? nil : name
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        BlockRow(
            block: block,
            state: state,
            dayStartMin: dayStartMin,
            renamingBlockId: $renamingBlockId,
            renamingText: $renamingText
        )
    }

    private func setStatus(_ block: Block, _ status: BlockStatus) {
        state.setStatus(block, status)
    }

    private var nowAnchor: some View {
        let clamped = max(dayStartMin, min(dayEndMin, state.nowMinute))
        let y = CGFloat(clamped - dayStartMin) * pxPerMin
        return VStack(spacing: 0) {
            Color.clear.frame(height: y)
            Color.clear
                .frame(width: 1, height: 1)
                .id("now-anchor")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var nowIndicator: some View {
        if state.nowMinute >= dayStartMin && state.nowMinute <= dayEndMin {
            let y = CGFloat(state.nowMinute - dayStartMin) * pxPerMin
            HStack(spacing: 0) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                Rectangle()
                    .fill(Color.red)
                    .frame(height: 2)
            }
            .padding(.leading, 48)
            .offset(y: y - 5)
        }
    }

    private func timeStr(_ min: Int) -> String {
        String(format: "%02d:%02d", min / 60, min % 60)
    }
}

// MARK: - Block row with drag/resize/Obsidian deep link

struct BlockRow: View {
    let block: Block
    let state: DayState
    let dayStartMin: Int
    @Binding var renamingBlockId: UUID?
    @Binding var renamingText: String
    /// Set by the slot detail window, which uses a fixed legible scale instead of
    /// the main timeline's zoom.
    var pxPerMinOverride: CGFloat? = nil

    @GestureState private var moveDelta: CGFloat = 0
    @GestureState private var topResizeDelta: CGFloat = 0
    @GestureState private var bottomResizeDelta: CGFloat = 0
    @State private var isHovered: Bool = false
    @FocusState private var fieldFocused: Bool

    private var pxPerMin: CGFloat { pxPerMinOverride ?? state.pixelsPerMinute }

    private var liveStartMin: Int {
        block.startMin + snappedMinutes(moveDelta + topResizeDelta, pxPerMin: pxPerMin)
    }

    private var liveEndMin: Int {
        block.endMin + snappedMinutes(moveDelta + bottomResizeDelta, pxPerMin: pxPerMin)
    }

    private var topOffset: CGFloat {
        CGFloat(liveStartMin - dayStartMin) * pxPerMin
    }

    private var height: CGFloat {
        max(20, CGFloat(liveEndMin - liveStartMin) * pxPerMin)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            if renamingBlockId == block.id {
                renameField
            } else {
                titleArea
            }

            // Status button overlay - sits OUTSIDE the drag zone so its
            // clicks are not stolen by the body gesture.
            statusButton
                .padding(.leading, 8)
                .padding(.top, 6)

            // Resize handles
            resizeHandle(top: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            resizeHandle(top: false)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .offset(y: max(0, height - 6))
        }
        .frame(height: height, alignment: .top)
        .modifier(ConditionalClip(active: !isRenaming))
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: 0, y: topOffset)
        .padding(.trailing, 12)
        .contextMenu {
            ForEach(block.externalLinks(on: state.date)) { link in
                Button(link.label) { NSWorkspace.shared.open(link.url) }
            }
            Button("Open in Obsidian") { openInObsidian() }
            Divider()
            Button("Mark planned") { state.setStatus(block, .planned) }
            Button("Mark in progress") { state.setStatus(block, .inProgress) }
            Button("Mark done") { state.setStatus(block, .done) }
            Button("Mark skipped") { state.setStatus(block, .skipped) }
            Divider()
            Button("Rename") {
                renamingText = strippingMetadataComments(state.titleWithoutDoneTag(block.title))
                renamingBlockId = block.id
            }
            Button("Delete", role: .destructive) {
                state.deleteBlock(block)
            }
        }
    }

    private var decor: BlockDecor {
        let key = block.visibleTitle
        return DerivedCache.shared.decor(key) { BlockDecor.compute(for: key) }
    }

    private var fillColor: Color {
        let faded = block.status == .done || block.status == .skipped
        if let svc = decor.primary {
            let o = svc.fillOpacity
            return svc.brand.opacity(faded ? o.faded : (isHovered ? o.hover : o.base))
        }
        if decor.isMeeting {
            return meetingMint.opacity(faded ? 0.30 : (isHovered ? 0.62 : 0.45))
        }
        return block.status.color.opacity(isHovered ? 0.32 : 0.20)
    }

    private var isSelected: Bool { state.selectedBlockId == block.id }
    private var isRenaming: Bool { renamingBlockId == block.id }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color(NSColor.windowBackgroundColor),
                            lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.10 : 0), radius: isHovered ? 4 : 0, x: 0, y: 1)
    }

    private var statusButton: some View {
        Button(action: { state.cycleStatus(block) }) {
            Text(checkboxGlyph(block.status))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(block.status.color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var titleArea: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer().frame(width: 24) // gutter for status button overlay
            blockLabelView()
                .font(.system(size: 13))
                .foregroundColor(textColor(for: block.status))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 6)
            serviceIcon
        }
        .padding(.top, 7)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
        .frame(height: height, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        // Double before single, or SwiftUI swallows the double.
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { state.selectedBlockId = block.id }
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($moveDelta) { value, gestureState, _ in
                    gestureState = value.translation.height
                    state.isInteracting = true
                }
                .onEnded { value in
                    state.isInteracting = false
                    let dy = value.translation.height
                    if abs(dy) < 4 { return } // pure click, ignore (right-click for menu)
                    let snapped = snappedMinutes(dy, pxPerMin: pxPerMin)
                    let newStart = block.startMin + snapped
                    let newEnd = block.endMin + snapped
                    state.updateTime(block, newStartMin: newStart, newEndMin: newEnd)
                }
        )
    }

    @ViewBuilder
    private var serviceIcon: some View {
        if let svc = decor.primary {
            SVGPathShape(pathData: svc.pathData)
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(.trailing, 2)
                .padding(.top, 2)
        }
    }

    private var renameField: some View {
        // No status glyph here: statusButton is overlaid on top of this view by the
        // body, so drawing one produced two checkboxes side by side. The spacer
        // reserves the same gutter titleArea uses, so the text does not jump.
        HStack(alignment: .top, spacing: 8) {
            Spacer().frame(width: 24)

            TextField("Task", text: $renamingText, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(Color(NSColor.textColor))
            .focused($fieldFocused)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(NSColor.textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .onSubmit(commitRename)
            .onAppear { fieldFocused = true }
        }
        .padding(.top, 4)
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The field only ever holds visible text, so the block's metadata comments
    /// are appended back before the title is written to the file.
    private func beginRename() {
        state.selectedBlockId = block.id
        renamingText = strippingMetadataComments(state.titleWithoutDoneTag(block.title))
        renamingBlockId = block.id
    }

    private func cancelRename() {
        renamingBlockId = nil
        renamingText = ""
        fieldFocused = false
    }

    private func commitRename() {
        let metadata = metadataComments(in: block.title)
        let edited = renamingText.trimmingCharacters(in: .whitespaces)
        let newTitle = metadata.isEmpty ? edited : "\(edited) \(metadata)"
        state.updateTitle(block, newTitle: newTitle)
        renamingBlockId = nil
    }

    @ViewBuilder
    private func resizeHandle(top: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.0001))
            .frame(height: 6)
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .allowsHitTesting(moveDelta == 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating(top ? $topResizeDelta : $bottomResizeDelta) { value, gestureState, _ in
                        gestureState = value.translation.height
                        state.isInteracting = true
                    }
                    .onEnded { value in
                        state.isInteracting = false
                        let dyMin = snappedMinutes(value.translation.height, pxPerMin: pxPerMin)
                        if top {
                            let newStart = block.startMin + dyMin
                            state.updateTime(block, newStartMin: newStart, newEndMin: block.endMin)
                        } else {
                            let newEnd = block.endMin + dyMin
                            state.updateTime(block, newStartMin: block.startMin, newEndMin: newEnd)
                        }
                    }
            )
    }

    private func openInObsidian() {
        let relPath = vaultRelativePlanPath(for: state.date)
        guard let encodedVault = obsidianVaultName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedFile = relPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return
        }
        let urlString = "obsidian://open?vault=\(encodedVault)&file=\(encodedFile)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkboxGlyph(_ status: BlockStatus) -> String {
        switch status {
        case .planned: return "○"
        case .inProgress: return "◐"
        case .done: return "●"
        case .skipped: return "✕"
        }
    }

    private func textColor(for status: BlockStatus) -> Color {
        switch status {
        case .done: return Color.secondary
        case .skipped: return Color.secondary
        default: return Color.primary
        }
    }

    private func blockLabelView() -> Text {
        Text(composedAttributedLabel())
    }

    private func composedAttributedLabel() -> AttributedString {
        let h1 = liveStartMin / 60
        let m1 = liveStartMin % 60
        let h2 = liveEndMin / 60
        let m2 = liveEndMin % 60
        let timePrefix = String(format: "%02d:%02d-%02d:%02d  ", h1, m1, h2, m2)
        var prefixAttr = AttributedString(timePrefix)
        prefixAttr.foregroundColor = NSColor.secondaryLabelColor
        let visible = block.visibleTitle
        let titleAttr = (try? AttributedString(markdown: visible,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(visible)
        return prefixAttr + titleAttr
    }
}

/// Isolated so the once-a-second tick repaints this label and nothing else.
private struct ClockLabel: View {
    let minute: Int
    @ObservedObject private var clock = SecondsClock.shared

    var body: some View {
        Text(String(format: "%02d:%02d:%02d", minute / 60, minute % 60, clock.second))
            .font(.custom("Instrument Serif", size: 20))
            .foregroundColor(.secondary)
            .frame(width: 110, alignment: .trailing)
    }
}

extension DayState {
    func titleWithoutDoneTag(_ title: String) -> String {
        let pattern = #"\s*\(done \d{1,2}:\d{2}\)\s*$"#
        guard let regex = cachedRegex(pattern) else { return title }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// `.clipped()` takes no condition, and a block being renamed must not clip its
/// grown text field.
struct ConditionalClip: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.clipped() } else { content }
    }
}

// MARK: - Time slot row (Akiflow-style collapsed container)

/// A time slot: a container block that hides the tasks inside it until clicked.
/// It drags, resizes and persists exactly like an ordinary block, because it IS
/// one - a line in the Day Planner carrying a `<!-- slot-def:NAME -->` marker.
struct SlotRow: View {
    let block: Block
    let memberCount: Int
    let isExpanded: Bool
    let state: DayState
    let dayStartMin: Int
    let onToggle: () -> Void

    @GestureState private var moveDelta: CGFloat = 0
    @GestureState private var topResizeDelta: CGFloat = 0
    @GestureState private var bottomResizeDelta: CGFloat = 0
    @State private var isHovered: Bool = false

    private var pxPerMin: CGFloat { state.pixelsPerMinute }
    private var liveStartMin: Int { block.startMin + snappedMinutes(moveDelta + topResizeDelta, pxPerMin: pxPerMin) }
    private var liveEndMin: Int { block.endMin + snappedMinutes(moveDelta + bottomResizeDelta, pxPerMin: pxPerMin) }
    private var topOffset: CGFloat { CGFloat(liveStartMin - dayStartMin) * pxPerMin }
    private var height: CGFloat { max(24, CGFloat(liveEndMin - liveStartMin) * pxPerMin) }
    private var name: String { block.slotDef ?? block.visibleTitle }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(slotFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.selectedBlockId == block.id
                                ? Color.accentColor
                                : slotTextColor.opacity(isHovered ? 0.28 : 0.14),
                                lineWidth: state.selectedBlockId == block.id ? 2 : 1)
                )

            header

            // The whole slot is the hit target. Hanging the gestures off the header
            // left everything below it dead, so a double click in the empty body of
            // a three-hour slot did nothing at all.
            interactionLayer

            resizeHandle(top: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            resizeHandle(top: false)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .offset(y: max(0, height - 6))
        }
        .frame(height: height, alignment: .top)
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: 0, y: topOffset)
        .padding(.trailing, 12)
        .contextMenu {
            Button(isExpanded ? "Collapse slot" : "Expand slot") { onToggle() }
            ForEach(block.externalLinks(on: state.date)) { link in
                Button(link.label) { NSWorkspace.shared.open(link.url) }
            }
            Divider()
            Button("Delete slot", role: .destructive) { state.deleteBlock(block) }
        }
    }

    private var interactionLayer: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture(count: 2) { onToggle() }
            .onTapGesture { state.selectedBlockId = block.id }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($moveDelta) { value, gestureState, _ in
                        gestureState = value.translation.height
                        state.isInteracting = true
                    }
                    .onEnded { value in
                        state.isInteracting = false
                        let dy = value.translation.height
                        if abs(dy) < 4 { return } // a click selects, a double click opens
                        let rawMin = Int(dy / pxPerMin)
                        let snapped = Int((Double(rawMin) / Double(snapMinutes)).rounded()) * snapMinutes
                        state.moveSlot(block, byMinutes: snapped)
                    }
            )
    }

    /// Count badge, then the name, then the compact duration underneath.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 6) {
                Text("\(memberCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(slotFillColor)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(slotTextColor.opacity(0.92))
                    )
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(slotTextColor)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isExpanded {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(slotTextColor.opacity(0.6))
                }
            }
            Text(compactDuration(max(0, liveEndMin - liveStartMin)))
                .font(.system(size: 11))
                .foregroundColor(slotTextColor.opacity(0.55))
                .padding(.leading, 21)
        }
        .padding(.top, 5)
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
    }

    @ViewBuilder
    private func resizeHandle(top: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.0001))
            .frame(height: 6)
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            .allowsHitTesting(moveDelta == 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating(top ? $topResizeDelta : $bottomResizeDelta) { value, gestureState, _ in
                        gestureState = value.translation.height
                        state.isInteracting = true
                    }
                    .onEnded { value in
                        state.isInteracting = false
                        let dyMin = snappedMinutes(value.translation.height, pxPerMin: pxPerMin)
                        if top {
                            state.updateTime(block, newStartMin: block.startMin + dyMin, newEndMin: block.endMin)
                        } else {
                            state.updateTime(block, newStartMin: block.startMin, newEndMin: block.endMin + dyMin)
                        }
                    }
            )
    }
}

// MARK: - Slot detail window

/// The contents of one time slot, isolated in its own window so there is room to
/// read and reorganise. It reads the same DayState as the main timeline, so every
/// edit here lands in the plan file and shows up there immediately, and vice versa.
struct SlotDetailView: View {
    @ObservedObject var state: DayState
    let slotName: String

    @State private var titleDraft: String = ""
    @FocusState private var titleFocused: Bool
    @State private var cascadedCount: Int = 0

    private var editingTitle: Bool {
        get { state.slotTitleEditing }
        nonmutating set { state.slotTitleEditing = newValue }
    }

    private var slot: Block? { state.slotBlock(named: slotName) }
    private var memberBlocks: [Block] { state.members(ofSlot: slotName) }

    private var slotStart: Int { slot?.startMin ?? 0 }
    private var slotEnd: Int { slot?.endMin ?? 0 }
    private var spanMin: Int { max(1, slotEnd - slotStart) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(slotTextColor.opacity(0.12))
            if cascadedCount > 0 { cascadeNotice }
            if memberBlocks.isEmpty {
                emptyState
            } else {
                // Back to a real timeline: drag, resize, rename and the Obsidian
                // deep link all live on BlockRow and were lost in the list version.
                // Overlap is prevented by cascading on open rather than by changing
                // how blocks are drawn.
                GeometryReader { geo in
                    let usable = max(60, geo.size.height - 24)
                    let scale = usable / CGFloat(spanMin)
                    ZStack(alignment: .topLeading) {
                        grid(scale: scale)
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.clearSlotEditing()
                                state.selectedBlockId = nil
                            }
                        ForEach(memberBlocks) { block in
                            BlockRow(
                                block: block,
                                state: state,
                                dayStartMin: slotStart,
                                renamingBlockId: $state.slotRenamingBlockId,
                                renamingText: $state.slotRenamingText,
                                pxPerMinOverride: scale
                            )
                        }
                        .padding(.leading, 52)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(slotFillColor)
        .onAppear { cascadedCount = state.cascadeOverlaps(inSlot: slotName) }
        .onExitCommand {
            if editingTitle { cancelTitle() } else { state.openSlotName = nil }
        }
    }

    /// Moving someone's blocks without telling them is not acceptable, so say it.
    private var cascadeNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 10, weight: .bold))
            Text("\(cascadedCount) overlapping \(cascadedCount == 1 ? "block" : "blocks") moved down to clear the conflict")
                .font(.system(size: 11))
            Spacer(minLength: 0)
            Button("Dismiss") { cascadedCount = 0 }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(slotFillColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.85))
    }

    /// Half-hour ruler, absolutely positioned so a line lands exactly where a
    /// block edge at the same minute does.
    private func grid(scale: CGFloat) -> some View {
        let step = spanMin <= 90 ? 15 : 30
        let marks = Array(stride(from: slotStart, through: slotEnd, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { m in
                HStack(alignment: .center, spacing: 0) {
                    Text(timeStr(m))
                        .font(.system(size: 10))
                        .foregroundColor(slotTextColor.opacity(m % 60 == 0 ? 0.55 : 0.32))
                        .frame(width: 44, alignment: .trailing)
                        .padding(.trailing, 6)
                    Rectangle()
                        .fill(slotTextColor.opacity(m % 60 == 0 ? 0.16 : 0.08))
                        .frame(height: 1)
                }
                .offset(y: CGFloat(m - slotStart) * scale - 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(memberBlocks.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(slotFillColor)
                .frame(minWidth: 18, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(slotTextColor.opacity(0.92)))
            VStack(alignment: .leading, spacing: 1) {
                if editingTitle {
                    TextField("Slot name", text: $titleDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(NSColor.textColor))
                        .focused($titleFocused)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.textBackgroundColor))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1.5))
                        )
                        .frame(maxWidth: .infinity)
                        .onSubmit(commitTitle)
                        .onAppear { titleFocused = true }
                } else {
                    // One click to rename: an auto-named slot is called "3 tasks"
                    // and wants a real name as soon as it is opened.
                    Text(slotName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(slotTextColor)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { NSCursor.iBeam.set() } else { NSCursor.arrow.set() }
                        }
                        .onTapGesture {
                            titleDraft = slotName
                            editingTitle = true
                        }
                }
                Text("\(timeStr(slotStart)) - \(timeStr(slotEnd)) · \(compactDuration(spanMin))")
                    .font(.system(size: 11))
                    .foregroundColor(slotTextColor.opacity(0.55))
            }
            Spacer(minLength: 8)
            Button(action: { state.openSlotName = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(slotTextColor.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Nothing in this slot yet.")
                .font(.system(size: 13))
                .foregroundColor(slotTextColor.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commitTitle() {
        state.renameSlot(from: slotName, to: titleDraft)
        editingTitle = false
        titleFocused = false
    }

    private func cancelTitle() {
        editingTitle = false
        titleDraft = ""
        titleFocused = false
    }

    private func timeStr(_ min: Int) -> String {
        String(format: "%02d:%02d", min / 60, min % 60)
    }
}

// MARK: - App icon

/// The Dock icon, drawn in code so the runtime tile and the `.icns` baked by
/// `Scripts/make-app.sh` come from one source of truth.
enum AppIcon {
    static func image(side: CGFloat) -> NSImage {
        let pixels = Int(side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels,
                                         pixelsHigh: pixels,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(side: side)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// Writes the PNG family `iconutil` expects in an `.iconset` directory.
    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                guard let rep = image(side: CGFloat(size * scale)).representations.first as? NSBitmapImageRep,
                      let data = rep.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: directory.appendingPathComponent(name))
            }
        }
    }

    /// A mini timeline on a dark plate: hour rail, three blocks, the red now line.
    private static func draw(side: CGFloat) {
        let unit = side / 1024
        func p(_ value: CGFloat) -> CGFloat { value * unit }
        // Design coordinates run top-down; AppKit's origin is bottom-left.
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: p(x), y: side - p(y + h), width: p(w), height: p(h))
        }
        func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: rect, xRadius: p(radius), yRadius: p(radius))
        }

        let plate = rounded(box(92, 92, 840, 840), 188)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -p(12))
        shadow.shadowBlurRadius = p(28)
        shadow.set()
        NSColor.black.setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()

        let plateTop = NSColor(srgbRed: 0x2B/255.0, green: 0x2B/255.0, blue: 0x31/255.0, alpha: 1)
        let plateBottom = NSColor(srgbRed: 0x0E/255.0, green: 0x0E/255.0, blue: 0x11/255.0, alpha: 1)
        NSGradient(colors: [plateTop, plateBottom])?.draw(in: plate, angle: -90)

        NSGraphicsContext.saveGraphicsState()
        plate.addClip()

        let mint = NSColor(srgbRed: 0x7E/255.0, green: 0xFF/255.0, blue: 0xE1/255.0, alpha: 1)

        NSColor.white.withAlphaComponent(0.16).setFill()
        rounded(box(242, 196, 8, 632), 4).fill()

        mint.withAlphaComponent(0.95).setFill()
        rounded(box(320, 196, 512, 168), 44).fill()

        NSColor.white.withAlphaComponent(0.26).setFill()
        rounded(box(320, 396, 512, 232), 44).fill()

        mint.withAlphaComponent(0.45).setFill()
        rounded(box(320, 660, 512, 168), 44).fill()

        NSColor.systemRed.setFill()
        rounded(box(214, 514, 652, 12), 6).fill()
        NSBezierPath(ovalIn: box(216, 490, 60, 60)).fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - App + window

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let state = DayState()
    private var scrollMonitor: Any?
    private var slotWindow: NSWindow?
    private var slotCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        NSApp.applicationIconImage = AppIcon.image(side: 512)
        installMainMenu()
        let view = DayTimelineView(state: state)
        let hosting = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Day timeline"
        window.contentView = hosting
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Remember where and how big the window was; center only on first run.
        window.setFrameAutosaveName(windowFrameAutosaveName)
        if !window.setFrameUsingName(windowFrameAutosaveName) {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installScrollMonitor()
        // One window at a time, driven by state so the timeline, the slot row and
        // the window itself never disagree about what is open.
        slotCancellable = state.$openSlotName
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] name in
                self?.syncSlotWindow(to: name)
            }
    }

    private func syncSlotWindow(to name: String?) {
        guard let name else {
            slotWindow?.orderOut(nil)
            slotWindow = nil
            return
        }
        let hosting = NSHostingView(rootView: SlotDetailView(state: state, slotName: name))
        if let existing = slotWindow {
            existing.title = name
            existing.contentView = hosting
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = name
        win.backgroundColor = NSColor(srgbRed: 0x1d/255.0, green: 0x12/255.0, blue: 0x3b/255.0, alpha: 1)
        win.contentView = hosting
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.setFrameAutosaveName(slotWindowFrameAutosaveName)
        if !win.setFrameUsingName(slotWindowFrameAutosaveName) {
            // Sit beside the main window rather than on top of it.
            var origin = window.frame.origin
            origin.x += window.frame.width + 12
            win.setFrameOrigin(origin)
        }
        slotWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    /// Closing the window with its own control must clear the state too, or the
    /// slot row would keep claiming it is open.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === slotWindow else { return }
        slotWindow = nil
        if state.openSlotName != nil { state.openSlotName = nil }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        window?.saveFrame(usingName: windowFrameAutosaveName)
    }

    /// Minimal menu bar: the app had none, so cmd+M, cmd+W and cmd+Q did nothing.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Day timeline",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide others",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Day timeline",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Without an Edit menu, macOS never registers cmd+C/X/V/A at all: those
        // shortcuts are dispatched through these first-responder menu items, so
        // copy and paste were dead everywhere in the app, text fields included.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")),
                         keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select all",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func registerBundledFonts() {
        let names = ["InstrumentSerif-Regular", "InstrumentSerif-Italic"]
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.contains(.command) {
                let delta = Double(event.scrollingDeltaY)
                self.state.zoomBy(delta: delta * 0.5)
                return nil
            }
            return event
        }
    }
}

let app = NSApplication.shared

// Headless hook for Scripts/make-app.sh: render the iconset, then exit.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--export-icon") {
    let target = CommandLine.arguments.count > flagIndex + 1
        ? CommandLine.arguments[flagIndex + 1]
        : "AppIcon.iconset"
    do {
        try AppIcon.exportIconset(to: URL(fileURLWithPath: target))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Icon export failed: \(error)\n".utf8))
        exit(1)
    }
}

// Print the resolved settings and exit, so a misconfigured path can be checked
// without opening a window.
if CommandLine.arguments.contains("--print-config") {
    let planPath = planFilePath(for: Date())
    let exists = FileManager.default.fileExists(atPath: planPath) ? "found" : "missing"
    print("""
    domain             \(Bundle.main.bundleIdentifier ?? "day-timeline")
    planDirectory      \(planDir)
    planFileNameFormat \(planFileNameFormat)
    obsidianVaultName  \(obsidianVaultName)
    timeZone           \(planTimeZone.identifier)
    timelineStartHour  \(dayStart)
    timelineEndHour    \(dayEnd)
    today's plan file  \(planPath) (\(exists))
    obsidian link      obsidian://open?vault=\(obsidianVaultName)&file=\(vaultRelativePlanPath(for: Date()))
    """)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
