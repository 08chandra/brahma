import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Log-style live feed: `HH:mm:ss` mono, kind glyph, text. Newest at the bottom; new lines flash `bg3`.
struct ActivityFeedView: View {
    let model: AppModel
    var compact: Bool
    @State private var flashId: Int64?
    /// Plan C C7a: the SHARING filter's READS toggle (each recorded read of a shared ref is a row).
    @State private var showReads = false

    var body: some View {
        let events = model.filteredActivity
        let handles = model.handles
        Panel(title: "Activity", padded: false, accessory: {
            HStack(spacing: BrahmaTheme.spaceS) {
                filterPicker
                if model.activityFilter == .sharing {
                    Segmented(options: [(false, "Shares"), (true, "+ Reads")], selection: showReads, label: "Reads") { showReads = $0 }
                }
                MonoChip(text: "\(events.count)", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
            }
        }, content: {
            if model.activityFilter == .sharing {
                SharingTable(model: model, reads: showReads)
            } else if events.isEmpty {
                MonoEmptyState("No activity yet.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(events, id: \.id) { event in
                                ActivityRow(event: event, handles: handles, flashing: event.id == flashId, timeZone: model.ownerTimeZone)
                                    .id(event.id)
                            }
                        }
                        .padding(.vertical, BrahmaTheme.spaceXS)
                    }
                    .onAppear { scrollToEnd(proxy, events) }
                    .onChange(of: events.last?.id) {
                        guard let id = events.last?.id else { return }
                        scrollToEnd(proxy, events)
                        flashId = id
                        Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            withAnimation(BrahmaTheme.fast) { if flashId == id { flashId = nil } }
                        }
                    }
                }
            }
        })
        .padding(BrahmaTheme.spaceXS)
        .background(BrahmaTheme.bg0)
    }

    @ViewBuilder private var filterPicker: some View {
        let binding = Bindable(model).activityFilter
        if compact {
            Picker("Filter", selection: binding) {
                ForEach(ActivityFilter.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        } else {
            Picker("Filter", selection: binding) {
                ForEach(ActivityFilter.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 440)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ events: [ActivityEvent]) {
        if let id = events.last?.id { proxy.scrollTo(id, anchor: .bottom) }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    let handles: [String: String]
    let flashing: Bool
    var timeZone: TimeZone = .current

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
            Text(verbatim: TimeText.hms(event.createdAt, timeZone: timeZone))
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.text2)
            Image(systemName: Self.symbol(event.kind))
                .font(.system(size: 10))
                .foregroundStyle(Self.color(event.kind))
                .frame(width: 14)
            Text(verbatim: ActivityText.line(event, handles: handles))
                .font(BrahmaTheme.body)
                .foregroundStyle(BrahmaTheme.text0)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, BrahmaTheme.panelPadding)
        .padding(.vertical, 2)
        .background(flashing ? BrahmaTheme.bg3 : Color.clear)
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ k: ActivityKind) -> String {
        switch k {
        case .message: "bubble.left"
        case .turnStarted: "play.circle"
        case .turnFinished: "flag.checkered"
        case .toolUse: "wrench.and.screwdriver"
        case .stateChanged: "arrow.triangle.swap"
        case .usage: "gauge.with.dots.needle.67percent"
        case .error: "exclamationmark.triangle"
        case .work: "checklist"
        case .approval: "checkmark.seal"
        case .preview: "play.rectangle"
        case .release: "shippingbox"
        case .resource: "paperclip"
        case .merge: "arrow.triangle.merge"
        case .share: "square.and.arrow.up"
        case .access: "lock"
        case .export: "arrow.down.doc"
        case .show: "eye"
        }
    }

    static func color(_ k: ActivityKind) -> Color {
        switch k {
        case .message: BrahmaTheme.ready
        case .turnStarted: BrahmaTheme.running
        case .turnFinished: BrahmaTheme.text1
        case .toolUse: BrahmaTheme.text2
        case .stateChanged: BrahmaTheme.series[3]
        case .usage: BrahmaTheme.warning
        case .error: BrahmaTheme.danger
        case .work: BrahmaTheme.accent
        case .approval: BrahmaTheme.warning
        case .preview: BrahmaTheme.running
        case .release: BrahmaTheme.success
        case .resource: BrahmaTheme.accent
        case .merge: BrahmaTheme.success
        case .share: BrahmaTheme.accent
        case .access: BrahmaTheme.warning
        case .export: BrahmaTheme.text1
        case .show: BrahmaTheme.accent
        }
    }
}

/// Plan C C7a: the SHARING filter as a table (collab design §4.7): WHEN, FROM, TO, REF, RESULT and SESSION, newest first, from
/// `AppModel.sharingRows` (every string gated by `SharingRows.make`); with READS, each recorded read of a shared ref too. Without
/// the stored values the model refuses and nothing is listed.
struct SharingTable: View {
    let model: AppModel
    let reads: Bool
    @State private var rows: [SharingRow] = []
    @State private var error: String?

    private static let columns: [(String, CGFloat?)] = [("When", 110), ("From", 110), ("To", 110), ("Ref", nil), ("Result", 110), ("Session", 70)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, c in
                    ColumnHeader(c.0).frame(width: c.1, alignment: .leading).frame(maxWidth: c.1 == nil ? .infinity : nil, alignment: .leading)
                }
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg3)
            Hairline()
            if let error {
                MonoEmptyState("Refused", detail: error)
            } else if rows.isEmpty {
                MonoEmptyState("No sharing yet", detail: "Shares, access decisions, exports and show requests appear here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            HStack(spacing: BrahmaTheme.spaceS) {
                                cell(row.when, 110, color: BrahmaTheme.text2)
                                cell(row.from, 110)
                                cell(row.to, 110)
                                cell(row.ref, nil)
                                cell(row.result, 110, color: BrahmaTheme.text1)
                                cell(row.session, 70, color: row.session == "tainted" ? BrahmaTheme.warning : BrahmaTheme.text2)
                            }
                            .tableRow(index: i, height: BrahmaTheme.denseRowHeight)
                        }
                    }
                }
            }
        }
        .task(id: "\(reads)|\(model.activity.last?.id ?? 0)|\(model.selectedCompanyId ?? "")") {
            do {
                let loaded = try await model.sharingRows(reads: reads)
                guard !Task.isCancelled else { return }
                rows = loaded
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                rows = []
                self.error = (error as? WorkError)?.message ?? "The stored secrets can't be read, so nothing is listed."
            }
        }
    }

    private func cell(_ text: String, _ width: CGFloat?, color: Color = BrahmaTheme.text0) -> some View {
        Text(verbatim: text)
            .font(BrahmaTheme.monoSmall)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
