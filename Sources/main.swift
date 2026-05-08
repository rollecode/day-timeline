import SwiftUI
import AppKit

// MARK: - Constants

let planDir = "\(NSHomeDirectory())/Documents/Brain dump/claude-mcp-daily-plans"
let helsinkiTZ = TimeZone(identifier: "Europe/Helsinki")!

let dayStart = 9   // 09:00
let dayEnd = 19    // 19:00
let basePixelsPerMinute: CGFloat = 1.2
let zoomMin: Double = 0.5
let zoomMax: Double = 4.0
let snapMinutes = 15
let obsidianVaultName = "Brain dump"

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
        lastMtime = mtime
        // Debounce against our own writes
        if savingNow { return }
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

    private func applyDoneTag(_ title: String, status: BlockStatus) -> String {
        let stripped = stripDoneTag(title)
        if status == .done {
            let nowStr = String(format: "%02d:%02d", nowMinute / 60, nowMinute % 60)
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

    private var pxPerMin: CGFloat { state.pixelsPerMinute }

    private var totalHeight: CGFloat {
        CGFloat(dayEndMin - dayStartMin) * pxPerMin
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
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
            addBlockButton
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
                .frame(height: 60 * pxPerMin, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var nowIndicator: some View {
        if state.nowMinute >= dayStartMin && state.nowMinute <= dayEndMin {
            let y = CGFloat(state.nowMinute - dayStartMin) * pxPerMin
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
                .padding(.leading, 6)
                .padding(.top, 4)

            // Resize handles
            resizeHandle(top: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            resizeHandle(top: false)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .offset(y: max(0, height - 6))
        }
        .frame(height: height, alignment: .top)
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
                renamingText = state.titleWithoutDoneTag(block.title)
                renamingBlockId = block.id
            }
            Button("Delete", role: .destructive) {
                state.deleteBlock(block)
            }
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(block.status.color.opacity(isHovered ? 0.32 : 0.20))
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
        HStack(spacing: 8) {
            Spacer().frame(width: 26) // gutter for status button overlay
            blockLabelView()
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundColor(textColor(for: block.status))
            Spacer()
        }
        .frame(height: height, alignment: .top)
        .padding(.leading, 6)
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

    private var renameField: some View {
        HStack(spacing: 8) {
            Text(checkboxGlyph(block.status))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(block.status.color)
                .frame(width: 18, height: 18)
                .padding(.leading, 6)

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
            .onExitCommand {
                renamingBlockId = nil
            }

            Spacer()
        }
        .frame(height: height, alignment: .top)
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
        let path = planFilePath(for: state.date)
        let fileName = (path as NSString).lastPathComponent
        let relPath = "claude-mcp-daily-plans/\(fileName)"
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
        let titleAttr = (try? AttributedString(markdown: block.title,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(block.title)
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

// MARK: - App + window

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let state = DayState()
    private var scrollMonitor: Any?

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
        installScrollMonitor()
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
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
