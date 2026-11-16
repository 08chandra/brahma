import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Search hits as dense zebra tables: MESSAGES (mono `channel · sender · HH:mm` meta line, then the text on two lines), then
/// the memory-wide groups ITEMS, ASKS, HANDBOOK, RESOURCES and MEMORY (at most five each, owner scope; mono `ref · @author ·
/// date` meta line, then the title and snippet). A tainted hit carries neither title nor snippet, only its ref and a TAINTED
/// chip. Everything shown is rendered verbatim.
struct SearchResultsView: View {
    let model: AppModel

    var body: some View {
        let query = model.search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = model.search.hits
        let groups = model.search.groups
        let total = hits.count + groups.reduce(0) { $0 + $1.hits.count }
        Panel(title: "Search results", padded: false, accessory: {
            CapsLabel(model.search.isSearching ? "searching…" : "\(total) hits", font: BrahmaTheme.monoTiny)
        }) {
            if total == 0 {
                if model.search.isSearching {
                    Color.clear
                } else {
                    VStack {
                        Text(verbatim: "Nothing matches “\(query)”.")
                            .font(BrahmaTheme.monoSmall.weight(.medium))
                            .foregroundStyle(BrahmaTheme.text2)
                            .multilineTextAlignment(.center)
                            .padding(BrahmaTheme.spaceL)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !hits.isEmpty {
                            groupHeader("Messages", count: hits.count)
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                Button { Task { await model.open(hit) } } label: { row(hit) }
                                    .buttonStyle(.plain)
                                    .tableRow(index: index, height: 46)
                                    .accessibilityElement(children: .combine)
                            }
                        }
                        ForEach(groups) { group in
                            groupHeader(group.title, count: group.hits.count)
                            ForEach(Array(group.hits.enumerated()), id: \.element.docId) { index, hit in
                                Button { Task { await model.open(memoryHit: hit) } } label: { row(hit) }
                                    .buttonStyle(.plain)
                                    .tableRow(index: index, height: 46)
                                    .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
        .padding(BrahmaTheme.spaceXS)
        .background(BrahmaTheme.bg0)
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            CapsLabel(title)
            MonoChip(text: "\(count)")
            Spacer()
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.denseRowHeight)
        .frame(maxWidth: .infinity)
        .background(BrahmaTheme.bg3)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(hit.channelTitle) · \(hit.isOwner ? "You" : "@" + hit.senderHandle) · \(TimeText.hm(hit.message.createdAt, timeZone: model.ownerTimeZone))")
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

    private func row(_ hit: MemoryHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: BrahmaTheme.spaceXS) {
                Text(verbatim: "\(hit.ref) · \(author(hit)) · \(HandbookPresentation.timestamp(hit.updatedAt, model.ownerTimeZone))")
                    .font(BrahmaTheme.monoTiny)
                    .foregroundStyle(BrahmaTheme.text2)
                    .lineLimit(1).truncationMode(.middle)
                if hit.tainted { HandbookChip(label: "TAINTED").help(Text(verbatim: hit.taintReason ?? "outside content")) }
            }
            Text(verbatim: hit.snippet.map { hit.title + " — " + $0 } ?? hit.title)
                .font(BrahmaTheme.body)
                .foregroundStyle(hit.tainted ? BrahmaTheme.text2 : BrahmaTheme.text0)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func author(_ hit: MemoryHit) -> String {
        guard let id = hit.authorId else { return "engine" }
        if id == "owner" { return "You" }
        if id == "system" { return "engine" }
        return "@" + (model.handles[id] ?? "unknown")
    }
}
