import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The replay timeline (agent inspector › REPLAY, item inspector › HISTORY): log-style lines (time, kind glyph, @actor,
/// text) like the activity feed, kind filter chips, the day stepper for an agent's day, and a mono pane for a turn's
/// captured transcript. Every agent-written string is `Text(verbatim:)`.
struct ReplayView: View {
    let replay: ReplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Hairline()
            chips
            Hairline()
            lines
            if let transcript = replay.transcript, let turnId = replay.transcriptTurnId {
                Hairline()
                TranscriptPane(text: transcript, turnId: turnId, truncated: replay.transcriptTruncated) { replay.closeTranscript() }
                    .frame(minHeight: 140, idealHeight: 240, maxHeight: 320)
            }
        }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            if let day = replay.day {
                Button { Task { await replay.stepDay(by: -1) } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.brahma)
                    .help("Previous day")
                    .accessibilityLabel(Text("Previous day"))
                Text(verbatim: day).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                Button { Task { await replay.stepDay(by: 1) } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.brahma)
                    .disabled(!replay.canStepForward)
                    .help("Next day")
                    .accessibilityLabel(Text("Next day"))
            } else {
                CapsLabel("Whole history", color: BrahmaTheme.text1)
            }
            Spacer(minLength: BrahmaTheme.spaceS)
            if replay.isLoading { CapsLabel("Loading…") }
            MonoChip(text: "\(replay.entries.count)", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
            Button { Task { await replay.load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.brahma)
                .help("Reload")
                .accessibilityLabel(Text("Reload"))
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.panelHeaderHeight + 4)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BrahmaTheme.spaceXS) {
                chip(nil, "ALL")
                ForEach(ReplayKind.allCases, id: \.self) { kind in chip(kind, kind.label) }
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .padding(.vertical, BrahmaTheme.spaceXS)
        }
    }

    private func chip(_ kind: ReplayKind?, _ title: String) -> some View {
        let selected = replay.kindFilter == kind
        return Button { replay.kindFilter = kind } label: {
            Text(verbatim: title)
                .font(BrahmaTheme.label)
                .tracking(BrahmaTheme.labelTracking)
                .foregroundStyle(selected ? Color.white : BrahmaTheme.text1)
                .padding(.horizontal, 6)
                .frame(height: BrahmaTheme.chipHeight)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(selected ? BrahmaTheme.accent : BrahmaTheme.bg3))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(selected ? BrahmaTheme.accent : BrahmaTheme.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var lines: some View {
        let entries = replay.entries
        if let error = replay.error, entries.isEmpty {
            Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                .padding(BrahmaTheme.spaceS)
            Spacer(minLength: 0)
        } else if entries.isEmpty {
            MonoEmptyState(replay.loaded ? (replay.day == nil ? "No history yet" : "Nothing on this day") : "Loading")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if replay.isCapped {
                            CapsLabel("Showing the newest \(Replay.maxEntries) lines").padding(.horizontal, BrahmaTheme.panelPadding)
                        }
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            ReplayRow(entry: entry, time: replay.time(entry),
                                      open: entry.kind == .transcript ? { Task { await replay.openTranscript(turnId: entry.turnId ?? "") } } : nil)
                                .id(index)
                        }
                    }
                    .padding(.vertical, BrahmaTheme.spaceXS)
                }
                .onAppear { proxy.scrollTo(entries.count - 1, anchor: .bottom) }
            }
        }
    }
}

private struct ReplayRow: View {
    let entry: ReplayEntry
    let time: String
    let open: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
            Text(verbatim: time).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
            Image(systemName: Self.symbol(entry.kind))
                .font(.system(size: 10))
                .foregroundStyle(Self.color(entry.kind))
                .frame(width: 14)
                .help(entry.kind.label)
            Text(verbatim: "@" + entry.actor).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
            Text(verbatim: entry.text)
                .font(BrahmaTheme.body)
                .foregroundStyle(BrahmaTheme.text0)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let open {
                Button("Open", action: open).buttonStyle(.brahma).controlSize(.small)
            }
        }
        .padding(.horizontal, BrahmaTheme.panelPadding)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ k: ReplayKind) -> String {
        switch k {
        case .turn: "play.circle"
        case .toolUse: "wrench.and.screwdriver"
        case .message: "bubble.left"
        case .itemEvent: "checklist"
        case .ask: "questionmark.bubble"
        case .handbook: "book.closed"
        case .memory: "brain"
        case .resource: "paperclip"
        case .transcript: "doc.plaintext"
        }
    }

    static func color(_ k: ReplayKind) -> Color {
        switch k {
        case .turn: BrahmaTheme.running
        case .toolUse: BrahmaTheme.text2
        case .message: BrahmaTheme.ready
        case .itemEvent: BrahmaTheme.accent
        case .ask: BrahmaTheme.warning
        case .handbook: BrahmaTheme.series[3]
        case .memory: BrahmaTheme.series[4]
        case .resource: BrahmaTheme.accent
        case .transcript: BrahmaTheme.text1
        }
    }
}

/// A turn's captured transcript: mono, sanitized line by line, at most `ReplayModel.transcriptLineCap` lines.
private struct TranscriptPane: View {
    let text: String
    let turnId: String
    let truncated: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Transcript \(turnId.prefix(8))") {
                HStack(spacing: BrahmaTheme.spaceS) {
                    if truncated { CapsLabel("First \(ReplayModel.transcriptLineCap) lines", color: BrahmaTheme.warning) }
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(BrahmaTheme.text1)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close transcript"))
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text.isEmpty ? "(no conversation records)" : text)
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BrahmaTheme.spaceS)
            }
            .background(BrahmaTheme.bg1)
        }
    }
}
