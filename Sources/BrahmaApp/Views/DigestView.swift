import SwiftUI
import BrahmaAppModel

/// Inbox › DIGEST: the latest daily digest (rendered through `SafeMarkdown`) and `Build now`.
struct DigestView: View {
    let model: DigestModel

    var body: some View {
        Panel(title: "Digest", padded: false, accessory: {
            HStack(spacing: BrahmaTheme.spaceM) {
                if let period = model.periodLine {
                    Text(verbatim: period.uppercased()).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
                }
                Button { Task { await model.buildNow() } } label: {
                    Label(model.isBuilding ? "Building" : "Build now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.brahma)
                .disabled(model.isBuilding)
            }
        }, content: {
            Group {
                if let rendered = model.rendered {
                    ScrollView {
                        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                            Text(rendered)
                                .font(BrahmaTheme.body)
                                .foregroundStyle(BrahmaTheme.text0)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let error = model.error {
                                Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                            }
                        }
                        .padding(BrahmaTheme.spaceM)
                    }
                } else {
                    MonoEmptyState("No digest yet", detail: model.error
                                   ?? "Brahma writes one each morning at the digest time (Company › Settings). Build now makes one for the last day.")
                }
            }
        })
        .padding(BrahmaTheme.spaceS)
        .background(BrahmaTheme.bg0)
        .task(id: model.companyId) { await model.reload() }
    }
}
