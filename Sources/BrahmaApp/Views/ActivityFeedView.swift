import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Log-style live feed: `HH:mm:ss` mono, kind glyph, text. Newest at the bottom; new lines flash `bg3`.
struct ActivityFeedView: View {
    let model: AppModel
    var compact: Bool
    @State private var flashId: Int64?

    var body: some View {
        let events = model.filteredActivity
        let handles = model.handles
        Panel(title: "Activity", padded: false, accessory: {
            HStack(spacing: BrahmaTheme.spaceS) {
                filterPicker
                MonoChip(text: "\(events.count)", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
            }
        }, content: {
            if events.isEmpty {
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
            .frame(width: 380)
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
