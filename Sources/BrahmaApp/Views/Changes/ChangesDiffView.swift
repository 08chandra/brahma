import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Plan C Task C7c: an item's live diff in the CHANGES tab (collab design §1.6, Codex-style), drawn only from `ChangesTabModel`:
/// the header `<KEY> · <title>` with `LIVE · UNCOMMITTED` (`running` pulse) for a verified worktree diff, `updated <n> s ago`, the
/// `ComparePicker`, UNIFIED/SPLIT (saved per company by the model), ‹ › change stops, the total and the model's chips (TAINTED with
/// its gated reason, STALE, TRUNCATED, HIDDEN CHARACTERS) plus CHANGED SINCE SHOWN; the file list (engine paths, status letters,
/// per-file counts and stat bars, the engine's summaries in `text2`, outdated-comment counts); and the `DiffPane` with comment
/// markers and the inline review gutter. A refused or unverified diff shows the model's refusal, never LIVE (Ruling C6b-2).
///
/// Live updates never steal focus and keep the view on the current change stop (`DiffPane.version`). While a live compare of a
/// leased worktree is shown, `WorktreeNudger` asks the engine for an early recompute on file events (no file is read here).
struct ChangesDiffView: View {
    let model: ChangesTabModel
    let app: AppModel
    /// The OPENED tab's live diff: the ref header carries the title and the model's chips; a compare change opens that compare's
    /// ref (history keeps the one before).
    var embedded = false
    /// Back to the board (the CHANGES tab).
    var onBoard: (() -> Void)?

    @State private var jump: String?
    @State private var listWidth: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BrahmaTheme.bg0)
        .environment(\.timeZone, app.ownerTimeZone)
        .task(id: nudgeTarget) {
            guard let target = nudgeTarget else { return }
            await WorktreeNudger.watch(target, live: app.liveChanges)
        }
        .focusedSceneValue(\.changesCommands, embedded ? nil : ChangesCommands(model: model))
    }

    private var row: BoardRowView? { model.rows.first { $0.key == model.selectedKey } }
    /// The diff was verified against the engine's sections and nothing was refused.
    private var verified: Bool { model.error == nil && model.diff != nil }
    private var showsLive: Bool { verified && model.isLive && model.snapshot?.target == "worktree" }

    /// The model's chips as drawn: never LIVE over a refused or unverified diff (the model keeps LIVE after a refused yield, R2-4);
    /// LIVE and UNCOMMITTED become the one pulsing `LIVE · UNCOMMITTED` chip; CHANGED SINCE SHOWN when set.
    private var chips: [RefChip] {
        var out = embedded ? [] : model.chips
        if !verified { out.removeAll { $0.text == "LIVE" } }
        if showsLive { out.removeAll { $0.text == "LIVE" || $0.text == "UNCOMMITTED" } }
        if model.changedSinceShown { out.append(RefChip(text: "CHANGED SINCE SHOWN", tone: .warn)) }
        return out
    }

    // MARK: Header

    /// At most three rows, so the diff keeps the pane: the title row (not in the OPENED tab, whose ref header has it), one toolbar
    /// row that scrolls sideways when the pane is narrow, and the chips (wrapping) when there are any.
    private var header: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            if !embedded {
                HStack(spacing: BrahmaTheme.spaceS) {
                    if let onBoard {
                        Button(action: onBoard) { Label("Board", systemImage: "chevron.left") }
                            .buttonStyle(.brahma)
                            .fixedSize()
                            .help("Back to the changes board")
                    }
                    if let key = model.selectedKey {
                        Text(verbatim: key).font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(BrahmaTheme.text0).fixedSize()
                        if let title = row?.title {
                            Text(verbatim: "· " + title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    if showsLive {
                        StatusChip(label: "LIVE · UNCOMMITTED", color: BrahmaTheme.running, pulse: true).fixedSize()
                    }
                    Spacer(minLength: 0)
                    updated
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    ComparePicker(compare: model.compare, revisions: model.revisions, choose: choose)
                    Segmented(options: [(DiffViewMode.unified, "Unified"), (.split, "Split")], selection: model.mode, label: "Diff layout (⌘⇧D)") {
                        model.mode = $0
                    }
                    stepper
                    if let snapshot = model.snapshot {
                        Text(verbatim: BoardRows.stats(added: snapshot.added, removed: snapshot.removed, files: snapshot.files.count))
                            .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).fixedSize()
                    }
                    if embedded { updated }
                }
                .frame(height: 24)
            }
            if !chips.isEmpty {
                FlowLayout(spacing: BrahmaTheme.spaceXS) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in RefChipView(chip: chip) }
                }
            }
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .padding(.vertical, BrahmaTheme.spaceXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
    }

    @ViewBuilder private var updated: some View {
        if let computed = model.snapshot?.computedAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(verbatim: "updated \(max(0, Int(ctx.date.timeIntervalSince(computed)))) s ago")
                    .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2).fixedSize()
            }
        }
    }

    private var stepper: some View {
        let count = model.changeStops.count
        return HStack(spacing: 2) {
            Button { model.previousChange() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.brahma)
                .help("Previous change (⌘↑)")
                .accessibilityLabel(Text("Previous change"))
            Button { model.nextChange() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.brahma)
                .help("Next change (⌘↓)")
                .accessibilityLabel(Text("Next change"))
            Text(verbatim: model.stopIndex.map { "\($0 + 1)/\(count)" } ?? "\(count) \(count == 1 ? "CHANGE" : "CHANGES")")
                .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2).padding(.leading, 2)
        }
        .disabled(count == 0)
        .fixedSize()
    }

    private func choose(_ mode: CompareMode) {
        if embedded, let key = model.selectedKey {
            Task { await app.openRef(mode.ref(key: key), origin: .owner) }
        } else {
            model.setCompare(mode)
        }
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if let error = model.error {
            // A refusal first: a refused or unverified generation never draws the previous diff, and is never LIVE.
            RefUnavailableView(caption: "NOT SHOWN", text: error)
        } else if let diff = model.diff, let snapshot = model.snapshot {
            if model.files.isEmpty {
                MonoEmptyState("NO CHANGES", detail: snapshot.target == "worktree" ? "Nothing differs in the worktree yet." : "Nothing differs between these revisions.")
            } else {
                HStack(spacing: 0) {
                    fileList(snapshot).frame(width: listWidth)
                    SplitDivider(width: $listWidth, range: 110...360)
                    DiffPane(diff: diff, mode: model.mode, stop: model.currentStop, version: snapshot.patchHash, markers: markerIndex,
                             review: reviewContext, jump: $jump)
                }
            }
        } else if model.selectedKey == nil {
            MonoEmptyState("NO CHANGE SELECTED")
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileList(_ snapshot: ChangesSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.files.enumerated()), id: \.offset) { i, file in
                    let numbers = snapshot.files.indices.contains(i) ? snapshot.files[i] : nil
                    let outdated = model.outdated[file.path] ?? 0
                    Button { if let f = file.fileIndex { jump = "file-\(f)" } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: file.status)
                                    .font(BrahmaTheme.monoTiny.weight(.bold))
                                    .foregroundStyle(Self.statusColor(file.status))
                                    .frame(width: 10)
                                Text(verbatim: file.path)
                                    .font(BrahmaTheme.monoSmall)
                                    .foregroundStyle(BrahmaTheme.text0)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            HStack(spacing: 6) {
                                DiffCounts(added: numbers?.added ?? 0, removed: numbers?.removed ?? 0)
                                StatBar(added: numbers?.added ?? 0, removed: numbers?.removed ?? 0)
                                if outdated > 0 {
                                    Text(verbatim: "\(outdated) OUTDATED")
                                        .font(BrahmaTheme.monoTiny)
                                        .foregroundStyle(BrahmaTheme.text2)
                                        .help(outdated == 1 ? "1 comment no longer matches a line" : "\(outdated) comments no longer match a line")
                                }
                            }
                            .padding(.leading, 16)
                            if let summary = file.summary {
                                Text(verbatim: summary)
                                    .font(BrahmaTheme.monoTiny)
                                    .foregroundStyle(BrahmaTheme.text2)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.leading, 16)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .tableRow(index: i, selected: file.fileIndex != nil && model.currentStop?.file == file.fileIndex,
                              height: file.summary == nil ? 40 : 54)
                    .help(Text(verbatim: file.path))
                }
            }
        }
        .background(BrahmaTheme.bg2)
    }

    /// A added `success`, D deleted `danger`, R renamed `accent`, M modified `text1`.
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "A": BrahmaTheme.success
        case "D": BrahmaTheme.danger
        case "R": BrahmaTheme.accent
        default: BrahmaTheme.text1
        }
    }

    // MARK: Review

    /// The model's markers by the diff file their engine path names (`ChangedFileRow.fileIndex`, the engine's `patchIndex`).
    private var markerIndex: DiffMarkerIndex {
        var out: DiffMarkerIndex = [:]
        for (anchor, comments) in model.markers {
            guard let f = model.files.first(where: { $0.path == anchor.path })?.fileIndex else { continue }
            out[f, default: [:]][anchor.side, default: [:]][anchor.line, default: []] += comments
        }
        return out
    }

    /// The gutter's anchor builder (`ChangesTabModel.anchor`) and post action (`AppModel.submitReview`, the owner principal's
    /// path); the refusal text shows in the popover instead of the window's alert.
    private var reviewContext: DiffReviewContext? {
        guard verified, let key = model.selectedKey else { return nil }
        let compare = model.compare
        let (model, app) = (self.model, self.app)
        return DiffReviewContext(holder: row?.agent, anchor: { f, h, i, side in model.anchor(fileIndex: f, hunk: h, index: i, side: side) },
                                 submit: { draft in
                                     let before = app.errorMessage
                                     if await app.submitReview(draft, key: key, compare: compare) { return nil }
                                     let message = app.errorMessage ?? "Couldn't post the review"
                                     app.errorMessage = before
                                     return message
                                 })
    }

    // MARK: Nudges

    /// The selected item's worktree while a live compare of it streams, for a key the engine lists as a leased worktree in place.
    private var nudgeTarget: NudgeTarget? {
        guard model.isRunning, model.compare.isLive, let key = model.selectedKey, app.selectedCompanyId == model.companyId,
              app.snapshot.preview.worktreeKeys.contains(key),
              let workspace = app.selectedCompany?.company.workspacePath, !workspace.isEmpty else { return nil }
        let path = GitWorkspace(root: URL(fileURLWithPath: workspace, isDirectory: true)).worktreePath(key: key).path
        return NudgeTarget(companyId: model.companyId, key: key, path: path)
    }
}

// MARK: - Commands (⌘↓ / ⌘↑ / ⌘⇧D while the CHANGES tab shows a diff)

/// What the Go menu's change commands act on: the CHANGES tab's model, published while its diff is on screen.
struct ChangesCommands {
    let model: ChangesTabModel
}

private struct ChangesCommandsKey: FocusedValueKey {
    typealias Value = ChangesCommands
}

extension FocusedValues {
    var changesCommands: ChangesCommands? {
        get { self[ChangesCommandsKey.self] }
        set { self[ChangesCommandsKey.self] = newValue }
    }
}

/// Next/previous change and unified ⇄ split, enabled only while the CHANGES tab shows a diff (so the keys stay the text
/// fields' everywhere else).
struct ChangesMenuItems: View {
    @FocusedValue(\.changesCommands) private var changes

    var body: some View {
        Button("Next Change") { changes?.model.nextChange() }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(changes == nil)
        Button("Previous Change") { changes?.model.previousChange() }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(changes == nil)
        Button("Unified ⇄ Split") {
            guard let model = changes?.model else { return }
            model.mode = model.mode == .unified ? .split : .unified
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(changes == nil)
    }
}

/// Plan C Task C7c: the right pane of every diff (the CHANGES tab's live diff and C7a's static `DiffView`): per-file headers
/// (collapsible), hunk headers as numbers only, the model's `collapsed()` rows with fold rows that expand on click, or the
/// model's `splitRows` beside each other, every line through the model's highlighter (`highlighted()`), line numbers in `text2`,
/// added/deleted lines tinted `success`/`danger` at 15 %, comment markers (`accent` dot) and, when a review context is given, a
/// gutter "+" on the hovered line or hunk that opens the `ReviewPopover`.
///
/// Every path is the model's gated `displayPath`/`displayOldPath`; line text is `Text(verbatim:)` with hidden characters as
/// `warning` markers; nothing inside the diff text is clickable (the fold rows, the file headers and the gutter are the view's
/// own controls). The pane draws only a diff its caller verified (`ChangesTabModel.verify`, `RefBodies.verifiedDiff`).
struct DiffPane: View {
    let diff: DiffModel
    var mode: DiffViewMode = .unified
    /// The current change stop (`ChangesTabModel.currentStop`): marked with the accent bar and kept in view.
    var stop: DiffStop?
    /// Changes on every live yield (the snapshot's patch hash): the pane scrolls back to `stop` so a live update never moves the
    /// view off the current change stop.
    var version: String = ""
    /// Comment markers by file index, side (`old`/`new`) and line number (the model's `markers`).
    var markers: DiffMarkerIndex = [:]
    /// Inline review (the CHANGES tab only); nil draws no gutter "+".
    var review: DiffReviewContext?
    /// A row id to scroll to (the file list's clicks); cleared once scrolled.
    @Binding var jump: String?

    @State private var closedFiles: Set<Int> = []
    @State private var expanded: Set<DiffRowItem> = []
    /// The highlighted spans and the diff they were made for: spans of an older yield are never drawn over a newer one.
    @State private var cache: HighlightCache?

    struct HighlightCache {
        let diff: DiffModel
        let spans: [[[[CodeSpan]]]]
    }

    var body: some View {
        let spans = cache.flatMap { $0.diff == diff ? $0.spans : nil }
        let rows = mode == .split ? Self.splitRows(diff, expanded: expanded, closed: closedFiles)
            : Self.unifiedRows(diff, expanded: expanded, closed: closedFiles)
        let stopId = stop.map { PaneRow.lineId($0.file, $0.hunk, $0.line) }
        GeometryReader { geo in
            ScrollViewReader { proxy in
                // Unified scrolls sideways for long lines; split keeps each side half the pane and wraps its lines, so both sides
                // stay in view and nothing is clipped.
                ScrollView(mode == .split ? [.vertical] : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, spans: spans, stopId: stopId, half: max((geo.size.width - 1) / 2, 0)).id(row.id)
                        }
                    }
                    // A two-axis scroll view centers narrower content: pin the rows to the leading edge, at least the pane wide.
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
                .onChange(of: stopId) { _, id in
                    guard let id, let stop else { return }
                    closedFiles.remove(stop.file)
                    withAnimation(BrahmaTheme.fast) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: version) { _, _ in
                    // A live yield: back to the current change stop (no animation, no focus change).
                    if let stopId { proxy.scrollTo(stopId, anchor: .center) }
                }
                .onChange(of: jump) { _, target in
                    guard let target else { return }
                    if target.hasPrefix("file-"), let f = Int(target.dropFirst(5)) { closedFiles.remove(f) }
                    withAnimation(BrahmaTheme.fast) { proxy.scrollTo(target, anchor: .top) }
                    jump = nil
                }
            }
        }
        .background(BrahmaTheme.bg0)
        .task(id: diff) {
            let d = diff
            let made = await Task.detached(priority: .userInitiated) { Self.highlight(d) }.value
            guard !Task.isCancelled else { return }
            cache = HighlightCache(diff: d, spans: made)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: PaneRow, spans: [[[[CodeSpan]]]]?, stopId: String?, half: CGFloat) -> some View {
        switch row {
        case .file(let f):
            fileHeader(f, diff.files[f])
        case .hunk(let f, let h):
            hunkHeader(f, h)
        case .line(let f, let h, let i):
            let line = diff.files[f].hunks[h].lines[i]
            DiffLineView(line: line, spans: Self.lineSpans(spans, f, h, i, line), comments: comments(f, line),
                         review: review.map { ctx in ReviewTarget(context: ctx, file: f, hunk: h, index: i, side: line.kind == .del ? "old" : "new") },
                         isStop: row.id == stopId)
        case .fold(let item):
            foldRow(item)
        case .split(let f, let h, let left, let right):
            let lines = diff.files[f].hunks[h].lines
            HStack(alignment: .top, spacing: 0) {
                splitHalf(f, h, left, lines, side: "old", spans: spans, width: half)
                Hairline(axis: .vertical)
                splitHalf(f, h, right, lines, side: "new", spans: spans, width: half)
            }
            // Both sides take the taller side's height (a wrapped line), so the tints line up.
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .leading) {
                if row.id == stopId { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) }
            }
        }
    }

    @ViewBuilder
    private func splitHalf(_ f: Int, _ h: Int, _ index: Int?, _ lines: [DiffLine], side: String, spans: [[[[CodeSpan]]]]?, width: CGFloat) -> some View {
        if let index, lines.indices.contains(index) {
            let line = lines[index]
            DiffLineView(line: line, spans: Self.lineSpans(spans, f, h, index, line),
                         comments: (markers[f]?[side]?[side == "old" ? line.oldNo ?? -1 : line.newNo ?? -1]) ?? [],
                         review: review.map { ctx in ReviewTarget(context: ctx, file: f, hunk: h, index: index, side: side) },
                         numbers: side == "old" ? .old : .new, wraps: true, isStop: false)
                .frame(width: width, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            // An empty side: one blank line's height on `bg1` (never a greedy height inside the lazy stack).
            Text(verbatim: " ").font(BrahmaTheme.mono).padding(.vertical, 1)
                .frame(width: width, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(BrahmaTheme.bg1)
        }
    }

    /// The comments placed on `line` (both sides for a context line).
    private func comments(_ f: Int, _ line: DiffLine) -> [DiffComment] {
        guard let byFile = markers[f] else { return [] }
        var out: [DiffComment] = []
        if let n = line.oldNo, let c = byFile["old"]?[n] { out += c }
        if let n = line.newNo, let c = byFile["new"]?[n] { out += c }
        return out
    }

    private func fileHeader(_ f: Int, _ file: DiffFile) -> some View {
        let isClosed = closedFiles.contains(f)
        return Button {
            withAnimation(BrahmaTheme.fast) { if isClosed { closedFiles.remove(f) } else { closedFiles.insert(f) } }
        } label: {
            HStack(spacing: BrahmaTheme.spaceS) {
                Image(systemName: isClosed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(BrahmaTheme.text2)
                    .frame(width: 10)
                if let old = file.displayOldPath {
                    Text(verbatim: old).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
                    Text(verbatim: "→").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
                Text(verbatim: file.displayPath).font(BrahmaTheme.monoSmall.weight(.semibold)).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                DiffCounts(added: file.added, removed: file.removed)
                StatBar(added: file.added, removed: file.removed)
                Spacer(minLength: BrahmaTheme.spaceL)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(maxWidth: .infinity, minHeight: BrahmaTheme.rowHeight, alignment: .leading)
            .background(BrahmaTheme.bg3)
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: (isClosed ? "Expand " : "Collapse ") + file.displayPath))
    }

    private func hunkHeader(_ f: Int, _ h: Int) -> some View {
        let hunk = diff.files[f].hunks[h]
        // The hunk's review anchor is its first changed line (else its first line).
        let first = hunk.lines.firstIndex { $0.kind != .ctx } ?? 0
        let target = hunk.lines.indices.contains(first)
            ? review.map { ReviewTarget(context: $0, file: f, hunk: h, index: first, side: hunk.lines[first].kind == .del ? "old" : "new") } : nil
        return HunkHeaderRow(text: DiffAnchoring.headerRange(hunk.header) ?? "@@ -\(hunk.oldStart) +\(hunk.newStart) @@", review: target)
    }

    private func foldRow(_ item: DiffRowItem) -> some View {
        guard case .fold(_, _, _, let count) = item else { return AnyView(EmptyView()) }
        return AnyView(
            Button { withAnimation(BrahmaTheme.fast) { _ = expanded.insert(item) } } label: {
                HStack(spacing: BrahmaTheme.spaceS) {
                    Image(systemName: "arrow.up.and.down").font(.system(size: 8, weight: .bold)).foregroundStyle(BrahmaTheme.text2)
                    Text(verbatim: DiffRowItem.foldText(count)).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16 + 88)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .background(BrahmaTheme.bg2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the unchanged lines")
            .accessibilityLabel(Text(verbatim: "Expand " + DiffRowItem.foldText(count)))
        )
    }

    // MARK: Row building (the model's rows, in drawing order)

    /// Unified: every file's header, then the model's `collapsed()` items of that file with a header before each hunk.
    static func unifiedRows(_ diff: DiffModel, expanded: Set<DiffRowItem>, closed: Set<Int>) -> [PaneRow] {
        let items = diff.collapsed(context: 3, expanded: expanded)
        var byFile: [Int: [DiffRowItem]] = [:]
        for item in items {
            switch item {
            case .line(let f, _, _), .fold(let f, _, _, _): byFile[f, default: []].append(item)
            }
        }
        var out: [PaneRow] = []
        for f in diff.files.indices {
            out.append(.file(f))
            guard !closed.contains(f) else { continue }
            var lastHunk = -1
            for item in byFile[f] ?? [] {
                switch item {
                case .line(_, let h, let i):
                    if h != lastHunk { out.append(.hunk(file: f, hunk: h)); lastHunk = h }
                    out.append(.line(file: f, hunk: h, index: i))
                case .fold(_, let h, _, _):
                    if h != lastHunk { out.append(.hunk(file: f, hunk: h)); lastHunk = h }
                    out.append(.fold(item))
                }
            }
        }
        return out
    }

    /// Split: every file's header, then the model's `splitRows` with a header before each hunk; context runs the model folds
    /// (`collapsed()`) are folded here too, as one fold row.
    static func splitRows(_ diff: DiffModel, expanded: Set<DiffRowItem>, closed: Set<Int>) -> [PaneRow] {
        var folds: [Int: [Int: [(range: Range<Int>, item: DiffRowItem)]]] = [:]
        for item in diff.collapsed(context: 3, expanded: expanded) {
            if case .fold(let f, let h, let range, _) = item { folds[f, default: [:]][h, default: []].append((range, item)) }
        }
        var out: [PaneRow] = []
        for (f, file) in diff.files.enumerated() {
            out.append(.file(f))
            guard !closed.contains(f) else { continue }
            // Each side's line back to its index in the hunk (numbers are unique per side within a hunk).
            let oldIndex = file.hunks.map { hunk in
                Dictionary(hunk.lines.enumerated().compactMap { i, l in l.oldNo.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
            }
            let newIndex = file.hunks.map { hunk in
                Dictionary(hunk.lines.enumerated().compactMap { i, l in l.newNo.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
            }
            var lastHunk = -1
            for row in diff.splitRows(file: f) {
                let h = row.hunk
                guard file.hunks.indices.contains(h) else { continue }
                if h != lastHunk { out.append(.hunk(file: f, hunk: h)); lastHunk = h }
                let left = row.left?.oldNo.flatMap { oldIndex[h][$0] }
                let right = row.right?.newNo.flatMap { newIndex[h][$0] }
                if row.left?.kind == .ctx, let left, let fold = folds[f]?[h]?.first(where: { $0.range.contains(left) }) {
                    if left == fold.range.lowerBound { out.append(.fold(fold.item)) }
                    continue
                }
                out.append(.split(file: f, hunk: h, left: left, right: right))
            }
        }
        return out
    }

    // MARK: Highlighting

    static func lineSpans(_ spans: [[[[CodeSpan]]]]?, _ f: Int, _ h: Int, _ i: Int, _ line: DiffLine) -> [CodeSpan] {
        if let spans, spans.indices.contains(f), spans[f].indices.contains(h), spans[f][h].indices.contains(i) { return spans[f][h][i] }
        return InvisibleMarkers.mark(line.text).spans
    }

    /// Every file's lines through the model's highlighter (`DiffModel.highlighted`, markers included), split back per hunk; a
    /// line past the highlighter's cap keeps its markers only.
    nonisolated static func highlight(_ diff: DiffModel) -> [[[[CodeSpan]]]] {
        diff.files.indices.map { f in
            let rows = diff.highlighted(file: f)
            var next = 0
            return diff.files[f].hunks.map { hunk in
                hunk.lines.map { line -> [CodeSpan] in
                    defer { next += 1 }
                    return next < rows.count ? rows[next] : InvisibleMarkers.mark(line.text).spans
                }
            }
        }
    }
}

/// Comment markers by file index, side (`old`/`new`) and line number.
typealias DiffMarkerIndex = [Int: [String: [Int: [DiffComment]]]]

/// One drawn row of the pane.
enum PaneRow: Identifiable {
    case file(Int)
    case hunk(file: Int, hunk: Int)
    case line(file: Int, hunk: Int, index: Int)
    case fold(DiffRowItem)
    /// A split row: the left (old) and right (new) line indexes in the hunk.
    case split(file: Int, hunk: Int, left: Int?, right: Int?)

    static func lineId(_ f: Int, _ h: Int, _ i: Int) -> String { "l-\(f)-\(h)-\(i)" }

    var id: String {
        switch self {
        case .file(let f): "file-\(f)"
        case .hunk(let f, let h): "h-\(f)-\(h)"
        case .line(let f, let h, let i): Self.lineId(f, h, i)
        case .fold(let item):
            if case .fold(let f, let h, let range, _) = item { "fold-\(f)-\(h)-\(range.lowerBound)" } else { "fold" }
        // A change run's first split row carries its first deletion (else its first addition): the stop's id.
        case .split(let f, let h, let left, let right): Self.lineId(f, h, left ?? right ?? -1)
        }
    }
}

/// What the gutter "+" needs: the model's anchor builder and post action, and the line it is on.
struct DiffReviewContext {
    /// `@eng-1`, the lease holder the comment goes to (nil when the board has no row for the item).
    let holder: String?
    /// `ChangesTabModel.anchor(fileIndex:hunk:index:side:)`: the engine's display path, the header as numbers, the shown text.
    let anchor: @MainActor (_ file: Int, _ hunk: Int, _ index: Int, _ side: String) -> DiffAnchor?
    /// Posts through `AppModel.submitReview` (the owner principal's path); returns the error text, nil once posted.
    let submit: @MainActor (ReviewDraft) async -> String?
}

struct ReviewTarget {
    let context: DiffReviewContext
    let file: Int
    let hunk: Int
    let index: Int
    let side: String

    @MainActor var anchor: DiffAnchor? { context.anchor(file, hunk, index, side) }
}

/// `+3 −1` in `success`/`danger`.
struct DiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added)").foregroundStyle(BrahmaTheme.success)
            Text(verbatim: "\u{2212}\(removed)").foregroundStyle(BrahmaTheme.danger)
        }
        .font(BrahmaTheme.monoTiny)
    }
}

/// A hunk header (numbers only, `accent`), with the gutter "+" on hover when review is on.
private struct HunkHeaderRow: View {
    let text: String
    let review: ReviewTarget?
    @State private var hovered = false
    @State private var reviewing = false

    var body: some View {
        HStack(spacing: 0) {
            ReviewGutter(review: review, hovered: hovered, comments: [], reviewing: $reviewing)
            Text(verbatim: text)
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.accent)
                .padding(.horizontal, BrahmaTheme.spaceS)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .background(BrahmaTheme.accent.opacity(0.08))
        .onHover { hovered = $0 }
    }
}

/// One diff line: the gutter (comment marker or review "+"), old and/or new numbers (mono `text2`), the sign and the code;
/// added `success` 15 %, deleted `danger` 15 %.
struct DiffLineView: View {
    enum Numbers { case both, old, new }

    let line: DiffLine
    let spans: [CodeSpan]
    var comments: [DiffComment] = []
    var review: ReviewTarget?
    var numbers: Numbers = .both
    /// Split halves wrap a long line (each side is half the pane); unified keeps one line and scrolls sideways.
    var wraps = false
    var isStop = false
    @State private var hovered = false
    @State private var reviewing = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ReviewGutter(review: review, hovered: hovered, comments: comments, reviewing: $reviewing)
            if numbers != .new { number(line.oldNo) }
            if numbers != .old { number(line.newNo) }
            Text(verbatim: sign)
                .font(BrahmaTheme.mono)
                .foregroundStyle(signColor)
                .frame(width: 16)
            code
            Spacer(minLength: wraps ? 0 : BrahmaTheme.spaceL)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: wraps ? .infinity : nil, alignment: .topLeading)
        .background(tint)
        .overlay(alignment: .leading) {
            if isStop { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) }
        }
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var code: some View {
        if wraps {
            RefStyle.text(spans)
                .font(BrahmaTheme.mono)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            RefStyle.text(spans)
                .font(BrahmaTheme.mono)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(verbatim: n.map(String.init) ?? "")
            .font(BrahmaTheme.monoSmall)
            .foregroundStyle(BrahmaTheme.text2)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var sign: String {
        switch line.kind {
        case .add: "+"
        case .del: "\u{2212}"
        case .ctx: " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .add: BrahmaTheme.success
        case .del: BrahmaTheme.danger
        case .ctx: BrahmaTheme.text2
        }
    }

    private var tint: Color {
        switch line.kind {
        case .add: BrahmaTheme.success.opacity(0.15)
        case .del: BrahmaTheme.danger.opacity(0.15)
        case .ctx: .clear
        }
    }
}

/// The 16 pt gutter: an `accent` dot for a line with comments (click shows the thread), else the review "+" while hovered.
private struct ReviewGutter: View {
    let review: ReviewTarget?
    let hovered: Bool
    let comments: [DiffComment]
    @Binding var reviewing: Bool
    @State private var showingThread = false
    /// The anchor taken when "+" is clicked: a live yield while the popover is open never moves the comment to another line.
    @State private var pinned: DiffAnchor?

    var body: some View {
        ZStack {
            if !comments.isEmpty {
                Button { showingThread = true } label: {
                    Circle().fill(BrahmaTheme.accent).frame(width: 7, height: 7).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(comments.count == 1 ? "1 comment" : "\(comments.count) comments")
                .accessibilityLabel(Text(verbatim: comments.count == 1 ? "Show 1 comment" : "Show \(comments.count) comments"))
                .popover(isPresented: $showingThread, arrowEdge: .leading) { DiffThreadPopover(comments: comments) }
            } else if let review, hovered || reviewing {
                Button {
                    pinned = review.anchor
                    reviewing = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 13, height: 13)
                        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.accent))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Comment on this line")
                .accessibilityLabel(Text("Comment on this line"))
                .popover(isPresented: $reviewing, arrowEdge: .leading) {
                    ReviewPopover(anchor: pinned, holder: review.context.holder, submit: review.context.submit) { reviewing = false }
                }
            }
        }
        .frame(width: 16)
    }
}
