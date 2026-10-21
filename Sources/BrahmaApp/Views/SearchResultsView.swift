import SwiftUI
import BrahmaAppModel

/// Search hits as a dense zebra table: mono `channel · sender · HH:mm` meta line, then the text on two lines.
struct SearchResultsView: View {
    let model: AppModel

    var body: some View {
        let query = model.search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = model.search.hits
        Panel(title: "Search results", padded: false, accessory: {
            CapsLabel(model.search.isSearching ? "searching…" : "\(hits.count) hits", font: BrahmaTheme.monoTiny)
        }) {
            if hits.isEmpty {
                if model.search.isSearching {
                    Color.clear
                } else {
                    VStack {
                        Text(verbatim: "No messages match “\(query)”.")
                            .font(BrahmaTheme.monoSmall.weight(.medium))
                            .foregroundStyle(BrahmaTheme.text2)
                            .multilineTextAlignment(.center)
                            .padding(BrahmaTheme.spaceL)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            Button { Task { await model.open(hit) } } label: { row(hit) }
                                .buttonStyle(.plain)
                                .tableRow(index: index, height: 46)
                                .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .padding(BrahmaTheme.spaceXS)
        .background(BrahmaTheme.bg0)
    }

    private func row(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(hit.channelTitle) · \(hit.isOwner ? "You" : "@" + hit.senderHandle) · \(TimeText.hm(hit.message.createdAt))")
                .font(BrahmaTheme.monoTiny)
                .foregroundStyle(BrahmaTheme.text2)
                .lineLimit(1)
            Text(verbatim: hit.message.text)
                .font(BrahmaTheme.body)
                .foregroundStyle(BrahmaTheme.text0)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
