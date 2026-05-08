import SwiftUI
import AppKit

// MARK: - Constants

let planDir = "\(NSHomeDirectory())/Documents/Brain dump/claude-mcp-daily-plans"
let helsinkiTZ = TimeZone(identifier: "Europe/Helsinki")!

let dayStart = 9   // 09:00
let dayEnd = 19    // 19:00
let pixelsPerMinute: CGFloat = 1.2
let snapMinutes = 15

// MARK: - Plan file path for a date

func planFilePath(for date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = helsinkiTZ
    let comps = cal.dateComponents([.day, .month, .year], from: date)
    let d = comps.day ?? 0
    let m = comps.month ?? 0
    let y = comps.year ?? 0
    return "\(planDir)/Plan \(d).\(m).\(y).md"
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

struct Block: Identifiable, Equatable {
    let id = UUID()
    var status: BlockStatus
    var startMin: Int   // minutes since midnight
    var endMin: Int
    var title: String   // freeform text after time range, including (Source)

    var durationMin: Int { endMin - startMin }

    static func == (lhs: Block, rhs: Block) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.startMin == rhs.startMin &&
        lhs.endMin == rhs.endMin &&
        lhs.title == rhs.title
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
    var onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(path: String) {
        stop()
        let directoryPath = (path as NSString).deletingLastPathComponent
        fd = open(directoryPath, O_EVTONLY)
        if fd < 0 { return }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: DispatchQueue.main
        )
        source?.setEventHandler { [weak self] in
            self?.onChange()
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

    private var pre: String = ""
    private var post: String = ""
    private var header: String = "## Day Planner"
    private let watcher: FileWatcher
    private var saveDebounceTimer: Timer?
    private var clockTimer: Timer?
    private(set) var date: Date = Date()
    private var savingNow: Bool = false

    init() {
        self.watcher = FileWatcher(onChange: {})
        self.watcher.onChange = { [weak self] in self?.handleExternalChange() }
        loadToday()
        startClock()
    }

    func setStatus(_ block: Block, _ status: BlockStatus) {
        guard let idx = blocks.firstIndex(of: block) else { return }
        if blocks[idx].status != status {
            blocks[idx].status = status
            scheduleSave()
        }
    }

    deinit {
        watcher.stop()
        clockTimer?.invalidate()
    }

    func loadToday() {
        date = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = helsinkiTZ
        let comps = cal.dateComponents([.day, .month, .year, .weekday], from: date)
        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
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
        blocks[idx].status = blocks[idx].status.cycle()
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
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.savingNow = false
        }
    }

    private func startClock() {
        updateNow()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateNow()
        }
    }

    private func updateNow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = helsinkiTZ
        let comps = cal.dateComponents([.hour, .minute], from: Date())
        nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }
}

// MARK: - Views

struct DayTimelineView: View {
    @ObservedObject var state: DayState
    @State private var renamingBlockId: UUID?
    @State private var renamingText: String = ""

    private var dayStartMin: Int {
        let earliest = state.blocks.map(\.startMin).min() ?? (dayStart * 60)
        return min(dayStart * 60, earliest)
    }

    private var dayEndMin: Int {
        let latest = state.blocks.map(\.endMin).max() ?? (dayEnd * 60)
        return max(dayEnd * 60, latest)
    }

    private var totalHeight: CGFloat {
        CGFloat(dayEndMin - dayStartMin) * pixelsPerMinute
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourGrid
                    blocksLayer
                    nowIndicator
                }
                .frame(height: totalHeight)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text(state.dateString)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(timeStr(state.nowMinute))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var hourGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stride(from: dayStartMin, through: dayEndMin, by: 60)), id: \.self) { m in
                HStack(spacing: 0) {
                    Text(timeStr(m))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .padding(.trailing, 6)
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 1)
                }
                .frame(height: 60 * pixelsPerMinute, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    // Only treat as a tap if user did not drag
                    if abs(value.translation.height) < 4 && abs(value.translation.width) < 4 {
                        let minute = dayStartMin + Int(value.location.y / pixelsPerMinute)
                        state.addBlock(at: minute)
                    }
                }
        )
    }

    private var blocksLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.blocks) { block in
                blockView(block)
            }
        }
        .padding(.leading, 56) // leave hour-label gutter
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        let topOffset = CGFloat(block.startMin - dayStartMin) * pixelsPerMinute
        let height = max(20, CGFloat(block.durationMin) * pixelsPerMinute)
        HStack(spacing: 8) {
            Button(action: { state.cycleStatus(block) }) {
                Text(checkboxGlyph(block.status))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(block.status.color)
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(0.0001))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)

            if renamingBlockId == block.id {
                TextField("Task", text: $renamingText, onCommit: {
                    state.updateTitle(block, newTitle: renamingText)
                    renamingBlockId = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    state.updateTitle(block, newTitle: renamingText)
                    renamingBlockId = nil
                }
            } else {
                Text(blockLabel(block))
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .foregroundColor(textColor(for: block.status))
                    .onTapGesture(count: 2) {
                        renamingText = block.title
                        renamingBlockId = block.id
                    }
            }
            Spacer()
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(block.status.color.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(block.status.color.opacity(0.5), lineWidth: 1)
                )
        )
        .offset(x: 0, y: topOffset)
        .padding(.trailing, 12)
        .contextMenu {
            Button("Mark planned") { setStatus(block, .planned) }
            Button("Mark in progress") { setStatus(block, .inProgress) }
            Button("Mark done") { setStatus(block, .done) }
            Button("Mark skipped") { setStatus(block, .skipped) }
            Divider()
            Button("Rename") {
                renamingText = block.title
                renamingBlockId = block.id
            }
            Button("Delete", role: .destructive) {
                state.deleteBlock(block)
            }
        }
    }

    private func setStatus(_ block: Block, _ status: BlockStatus) {
        state.setStatus(block, status)
    }

    @ViewBuilder
    private var nowIndicator: some View {
        if state.nowMinute >= dayStartMin && state.nowMinute <= dayEndMin {
            let y = CGFloat(state.nowMinute - dayStartMin) * pixelsPerMinute
            HStack(spacing: 0) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(Color.red)
                    .frame(height: 1)
            }
            .padding(.leading, 50)
            .offset(y: y)
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

    private func blockLabel(_ block: Block) -> String {
        let h1 = block.startMin / 60
        let m1 = block.startMin % 60
        let h2 = block.endMin / 60
        let m2 = block.endMin % 60
        return String(format: "%02d:%02d-%02d:%02d  %@", h1, m1, h2, m2, block.title)
    }

    private func timeStr(_ min: Int) -> String {
        String(format: "%02d:%02d", min / 60, min % 60)
    }
}

// MARK: - App + window

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let state = DayState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = DayTimelineView(state: state)
        let hosting = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Day timeline"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
