import SwiftUI
import AppKit
import CoreText

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

func strippingMetadataComments(_ text: String) -> String {
    text.replacingOccurrences(of: metadataCommentPattern, with: "", options: .regularExpression)
        .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// The comments themselves, in order, so a rename can put them back.
func metadataComments(in text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: metadataCommentPattern) else { return "" }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range)
        .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        .joined(separator: " ")
}

struct Block: Identifiable, Equatable {
    let id = UUID()
    var status: BlockStatus
    var startMin: Int   // minutes since midnight
    var endMin: Int
    var title: String   // freeform text after time range, including (Source)

    /// What the timeline shows: the title without its metadata comments.
    var visibleTitle: String { strippingMetadataComments(title) }

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
        guard let regex = try? NSRegularExpression(pattern: "<!--\\s*\(key):(.+?)\\s*-->") else { return nil }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, range: range),
              let r = Range(match.range(at: 1), in: title) else { return nil }
        let name = String(title[r]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }


    static func == (lhs: Block, rhs: Block) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.startMin == rhs.startMin &&
        lhs.endMin == rhs.endMin &&
        lhs.title == rhs.title
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
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
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
    @Published var nowSecond: Int = 0
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
        guard let idx = blocks.firstIndex(of: block) else { return }
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
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return title }
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
        self.blocks = parsed.blocks
        self.lastError = nil
        self.lastAutoCompleteCheckMinute = Int.min
        autoCompleteElapsed()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mtime = attrs[.modificationDate] as? Date {
            self.lastMtime = mtime
        }
    }

    private func handleExternalChange() {
        // If we triggered the change ourselves, ignore.
        if savingNow { return }
        // Debounce: wait 200ms in case multiple events fire
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.loadFromDisk()
        }
    }

    func cycleStatus(_ block: Block) {
        guard let idx = blocks.firstIndex(of: block) else { return }
        let newStatus = blocks[idx].status.cycle()
        blocks[idx].status = newStatus
        blocks[idx].title = applyDoneTag(blocks[idx].title, status: newStatus)
        scheduleSave()
    }

    func updateTitle(_ block: Block, newTitle: String) {
        guard let idx = blocks.firstIndex(of: block) else { return }
        if blocks[idx].title != newTitle {
            blocks[idx].title = newTitle
            scheduleSave()
        }
    }

    func updateTime(_ block: Block, newStartMin: Int, newEndMin: Int) {
        guard let idx = blocks.firstIndex(of: block) else { return }
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
    func moveSlot(_ slot: Block, byMinutes delta: Int) {
        guard let name = slot.slotDef, delta != 0 else { return }
        for idx in blocks.indices where blocks[idx].slot == name && blocks[idx].slotDef == nil {
            blocks[idx].startMin = max(0, blocks[idx].startMin + delta)
            blocks[idx].endMin = max(0, blocks[idx].endMin + delta)
        }
        guard let sIdx = blocks.firstIndex(of: slot) else { return }
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
        nowSecond = comps.second ?? 0
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
    @State private var expandedSlots: Set<String> = []
    @State private var renamingBlockId: UUID?
    @State private var renamingText: String = ""
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
    }

    private var addBlockButton: some View {
        Button(action: {
            let now = state.nowMinute
            let snap = ((now / snapMinutes) + 1) * snapMinutes
            let start = max(dayStartMin, min(dayEndMin - 30, snap))
            state.addBlock(at: start)
        }) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
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
                .font(.system(size: 13, weight: .medium))
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
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("-", modifiers: .command)

            Divider().frame(height: 16)

            Button(action: { state.setZoom(1.0) }) {
                Text("\(Int(state.zoom * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0", modifiers: .command)

            Divider().frame(height: 16)

            Button(action: { state.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
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
            Text(timeWithSecondsStr(state.nowMinute, state.nowSecond))
                .font(.custom("Instrument Serif", size: 20))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .trailing)
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
                        .font(.system(size: 10))
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

    /// Blocks that belong to a collapsed slot are not drawn at all; the slot row
    /// stands in for them. Expanding a slot reveals its members, inset inside it.
    private var slotDefs: [Block] { state.blocks.filter { $0.slotDef != nil } }

    private func members(of slotName: String) -> [Block] {
        state.blocks.filter { $0.slot == slotName && $0.slotDef == nil }
            .sorted { $0.startMin < $1.startMin }
    }

    /// Every slot name that actually has a defining row, so a stray `slot:`
    /// marker with no container still renders as an ordinary block.
    private var definedSlotNames: Set<String> { Set(slotDefs.compactMap { $0.slotDef }) }

    private var looseBlocks: [Block] {
        state.blocks.filter { block in
            guard block.slotDef == nil else { return false }
            guard let slot = block.slot, definedSlotNames.contains(slot) else { return true }
            return expandedSlots.contains(slot)
        }
    }

    private var blocksLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slotDefs) { slot in
                SlotRow(
                    block: slot,
                    memberCount: members(of: slot.slotDef ?? "").count,
                    isExpanded: expandedSlots.contains(slot.slotDef ?? ""),
                    state: state,
                    dayStartMin: dayStartMin,
                    onToggle: { toggleSlot(slot.slotDef ?? "") }
                )
            }
            ForEach(looseBlocks) { block in
                blockView(block)
                    .padding(.leading, isInsideExpandedSlot(block) ? 18 : 0)
            }
        }
        .padding(.leading, 56) // leave hour-label gutter
    }

    private func isInsideExpandedSlot(_ block: Block) -> Bool {
        guard let slot = block.slot else { return false }
        return definedSlotNames.contains(slot) && expandedSlots.contains(slot)
    }

    private func toggleSlot(_ name: String) {
        guard !name.isEmpty else { return }
        if expandedSlots.contains(name) {
            expandedSlots.remove(name)
        } else {
            expandedSlots.insert(name)
        }
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

    @GestureState private var moveDelta: CGFloat = 0
    @GestureState private var topResizeDelta: CGFloat = 0
    @GestureState private var bottomResizeDelta: CGFloat = 0
    @State private var isHovered: Bool = false

    private var pxPerMin: CGFloat { state.pixelsPerMinute }

    private var liveStartMin: Int {
        block.startMin + Int((moveDelta + topResizeDelta) / pxPerMin)
    }

    private var liveEndMin: Int {
        block.endMin + Int((moveDelta + bottomResizeDelta) / pxPerMin)
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
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: 0, y: topOffset)
        .padding(.trailing, 12)
        .contextMenu {
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

    private var decor: BlockDecor { BlockDecor.compute(for: block.visibleTitle) }

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

    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.10 : 0), radius: isHovered ? 4 : 0, x: 0, y: 1)
    }

    private var statusButton: some View {
        Button(action: { state.cycleStatus(block) }) {
            Text(checkboxGlyph(block.status))
                .font(.system(size: 12, weight: .bold))
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
                .font(.system(size: 12))
                .foregroundColor(textColor(for: block.status))
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
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($moveDelta) { value, gestureState, _ in
                    gestureState = value.translation.height
                }
                .onEnded { value in
                    let dy = value.translation.height
                    if abs(dy) < 4 { return } // pure click, ignore (right-click for menu)
                    let rawMin = Int(dy / pxPerMin)
                    let snapped = Int((Double(rawMin) / Double(snapMinutes)).rounded()) * snapMinutes
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
        HStack(spacing: 8) {
            Text(checkboxGlyph(block.status))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(block.status.color)
                .frame(width: 18, height: 18)
                .padding(.leading, 6)

            TextField("Task", text: $renamingText, onCommit: commitRename)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .onSubmit(commitRename)
            .onExitCommand {
                renamingBlockId = nil
            }

            Spacer()
        }
        .frame(height: height, alignment: .top)
    }

    /// The field only ever holds visible text, so the block's metadata comments
    /// are appended back before the title is written to the file.
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
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating(top ? $topResizeDelta : $bottomResizeDelta) { value, gestureState, _ in
                        gestureState = value.translation.height
                    }
                    .onEnded { value in
                        let dyMin = Int(value.translation.height / pxPerMin)
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

extension DayState {
    func titleWithoutDoneTag(_ title: String) -> String {
        let pattern = #"\s*\(done \d{1,2}:\d{2}\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return title }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.stringByReplacingMatches(in: title, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
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
    private var liveStartMin: Int { block.startMin + Int((moveDelta + topResizeDelta) / pxPerMin) }
    private var liveEndMin: Int { block.endMin + Int((moveDelta + bottomResizeDelta) / pxPerMin) }
    private var topOffset: CGFloat { CGFloat(liveStartMin - dayStartMin) * pxPerMin }
    private var height: CGFloat { max(24, CGFloat(liveEndMin - liveStartMin) * pxPerMin) }
    private var name: String { block.slotDef ?? block.visibleTitle }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(slotFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(slotTextColor.opacity(isHovered ? 0.28 : 0.14), lineWidth: 1)
                )

            header

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
            Divider()
            Button("Delete slot", role: .destructive) { state.deleteBlock(block) }
        }
    }

    /// Count badge, then the name, then the compact duration underneath.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 6) {
                Text("\(memberCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(slotFillColor)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(slotTextColor.opacity(0.92))
                    )
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(slotTextColor)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isExpanded {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(slotTextColor.opacity(0.6))
                }
            }
            Text(compactDuration(max(0, liveEndMin - liveStartMin)))
                .font(.system(size: 10))
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
        .onTapGesture { onToggle() }
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($moveDelta) { value, gestureState, _ in
                    gestureState = value.translation.height
                }
                .onEnded { value in
                    let dy = value.translation.height
                    if abs(dy) < 4 { return } // a click is an expand, not a move
                    let rawMin = Int(dy / pxPerMin)
                    let snapped = Int((Double(rawMin) / Double(snapMinutes)).rounded()) * snapMinutes
                    state.moveSlot(block, byMinutes: snapped)
                }
        )
    }

    @ViewBuilder
    private func resizeHandle(top: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.0001))
            .frame(height: 6)
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating(top ? $topResizeDelta : $bottomResizeDelta) { value, gestureState, _ in
                        gestureState = value.translation.height
                    }
                    .onEnded { value in
                        let dyMin = Int(value.translation.height / pxPerMin)
                        if top {
                            state.updateTime(block, newStartMin: block.startMin + dyMin, newEndMin: block.endMin)
                        } else {
                            state.updateTime(block, newStartMin: block.startMin, newEndMin: block.endMin + dyMin)
                        }
                    }
            )
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

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let state = DayState()
    private var scrollMonitor: Any?

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
