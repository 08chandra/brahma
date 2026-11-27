import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// An agent's "now" (collab design §1.3): who it is (handle, role, state chip, the item it holds), its live diff, its turn
/// stream, its last 30 activity lines, today's usage share, the owner's open requests to it and the taint of its session, with
/// the actions DM, Request a file and Ask to explain. Every string is the model's gated final text, drawn verbatim.
struct AgentNowView: View {
    let model: AppModel
    let now: AgentNowModel
    @State private var requestingFile = false

    private var handle: String { String(now.handle.drop { $0 == "@" }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                header
                if let tainted = now.taintedBy {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(BrahmaTheme.warning)
                        Text(verbatim: tainted).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                    }
                }
                actions
                section("Live diff") {
                    if let diff = now.liveDiff {
                        DiffView(diff: diff, live: true, uncommitted: true, updatedText: "updated just now")
                            .frame(height: 260)
                            .overlay(Rectangle().strokeBorder(BrahmaTheme.line, lineWidth: 1))
                    } else {
                        Text(verbatim: now.item == nil ? "NO ITEM IN HAND" : "NO CHANGES YET")
                            .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    }
                }
                section("Turn") {
                    TurnStreamView(stream: now.stream)
                        .frame(height: 220)
                }
                section("Activity") {
                    if now.activity.isEmpty {
                        Text(verbatim: "NO ACTIVITY YET").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(now.activity.enumerated()), id: \.offset) { i, line in
                                Text(verbatim: line)
                                    .font(BrahmaTheme.monoSmall)
                                    .foregroundStyle(BrahmaTheme.text1)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .tableRow(index: i, height: BrahmaTheme.denseRowHeight)
                            }
                        }
                    }
                }
                section("Usage") {
                    Text(verbatim: now.usageShare.uppercased()).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                }
                section("Open requests") {
                    if now.openRequests.isEmpty {
                        Text(verbatim: "NONE").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    } else {
                        ForEach(Array(now.openRequests.enumerated()), id: \.offset) { _, q in
                            Text(verbatim: q).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).lineLimit(2)
                        }
                    }
                }
            }
            .padding(BrahmaTheme.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrahmaTheme.bg0)
        .sheet(isPresented: $requestingFile) {
            RequestFileSheet(model: model, handle: handle, item: now.item)
                .background(BrahmaTheme.bg1)
                .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
            Text(verbatim: now.handle).font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
            Text(verbatim: now.role).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).lineLimit(1)
            StatusChip(label: now.state, color: stateColor, pulse: now.state.hasPrefix("running"))
            if let item = now.item {
                MonoChip(text: item, color: BrahmaTheme.text0, fill: BrahmaTheme.bg4).help("The item it holds")
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Button { model.select(.dm(handle: handle)) } label: { Label("DM", systemImage: "bubble.left") }
                .buttonStyle(.brahma)
            Button { requestingFile = true } label: { Label("Request a file", systemImage: "doc.badge.arrow.up") }
                .buttonStyle(.brahma)
            Button {
                RefActions.askToExplain(model: model, ref: WorkRef(kind: .agent, id: handle))
            } label: { Label("Ask to explain", systemImage: "questionmark.bubble") }
                .buttonStyle(.brahma)
            Spacer(minLength: 0)
        }
    }

    private var stateColor: Color {
        let s = now.state.lowercased()
        if s.hasPrefix("running") { return BrahmaTheme.running }
        if s == "ready" { return BrahmaTheme.ready }
        if s == "blocked" { return BrahmaTheme.blocked }
        if s == "killed" { return BrahmaTheme.killed }
        return BrahmaTheme.sleeping
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceXS) {
            CapsLabel(title, font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
            content()
        }
    }
}
