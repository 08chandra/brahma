import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Agent roster (dense table) with a right-hand inspector while an agent is selected.
struct AgentsView: View {
    @Bindable var model: AppModel
    @State private var sortKey: SortKey = .agent
    @State private var ascending = true

    enum SortKey { case agent, role, model, state, lastTurn }

    private var agents: [Agent] {
        let list = model.snapshot.agents
        let sorted = list.sorted { a, b in
            switch sortKey {
            case .agent: return a.name < b.name
            case .role: return (a.role, a.name) < (b.role, b.name)
            case .model: return (a.model, a.name) < (b.model, b.name)
            case .state: return (AgentBadge.label(a), a.name) < (AgentBadge.label(b), b.name)
            case .lastTurn:
                let ta = model.snapshot.lastTurns[a.id]?.startedAt ?? .distantPast
                let tb = model.snapshot.lastTurns[b.id]?.startedAt ?? .distantPast
                return (ta, a.name) < (tb, b.name)
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    var body: some View {
        HStack(spacing: 0) {
            Panel(title: "Agents", padded: false, accessory: {
                Button { model.presentedSheet = .hire } label: { Label("Hire Agent", systemImage: "person.badge.plus") }
                    .buttonStyle(.brahma)
            }, content: { roster })
            if let id = model.selectedAgentId, let detail = model.detail(agentId: id) {
                Hairline(axis: .vertical)
                AgentInspector(model: model, detail: detail)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(BrahmaTheme.bg2)
            }
        }
        .padding(BrahmaTheme.spaceS)
    }

    private func header(_ title: String, _ key: SortKey) -> some View {
        ColumnHeader(title, sorted: sortKey == key ? ascending : nil) {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = true }
        }
    }

    @ViewBuilder private var roster: some View {
        if model.snapshot.agents.isEmpty {
            MonoEmptyState("No agents yet", detail: "Hire the first agent to get started.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    header("Agent", .agent).frame(width: 110, alignment: .leading)
                    header("Role", .role).frame(width: 90, alignment: .leading)
                    header("Model", .model).frame(width: 70, alignment: .leading)
                    header("State", .state).frame(width: 110, alignment: .leading)
                    ColumnHeader("Note").frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                    header("Last turn", .lastTurn).frame(width: 90, alignment: .leading)
                }
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(height: BrahmaTheme.rowHeight)
                .background(BrahmaTheme.bg3)
                .overlay(alignment: .bottom) { Hairline() }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                            row(agent)
                                .tableRow(index: index, selected: agent.id == model.selectedAgentId)
                                .onTapGesture { model.selectedAgentId = agent.id }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ a: Agent) -> some View {
        let turn = model.snapshot.lastTurns[a.id]
        let killed = a.state == .killed
        return HStack(spacing: BrahmaTheme.spaceS) {
            Text(verbatim: "@" + a.name)
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(killed ? BrahmaTheme.text2 : BrahmaTheme.text0)
                .strikethrough(killed)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            Text(verbatim: a.role).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                .lineLimit(1).frame(width: 90, alignment: .leading)
            Text(verbatim: a.model).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                .lineLimit(1).frame(width: 70, alignment: .leading)
            StateTag(agent: a).frame(width: 110, alignment: .leading)
            Text(verbatim: BlockerText.describe(a.blocker, handles: model.handles))
                .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                .lineLimit(1)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            Text(verbatim: turn.map { TimeText.hm($0.endedAt ?? $0.startedAt) } ?? "—")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                .frame(width: 90, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Colored dot plus the `AgentBadge` label.
private struct StateTag: View {
    let agent: Agent

    var body: some View {
        let color = BrahmaTheme.statusColor(for: agent.state)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: AgentBadge.label(agent))
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(agent.state == .killed ? BrahmaTheme.text2 : color)
                .lineLimit(1)
        }
    }
}

private struct AgentInspector: View {
    let model: AppModel
    let detail: AgentDetail
    @State private var confirmKill = false

    var body: some View {
        let a = detail.agent
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Inspector")
            ScrollView {
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                    HStack(spacing: BrahmaTheme.spaceS) {
                        MonogramAvatar(monogram: String(a.name.prefix(2)).uppercased(), color: BrahmaTheme.roleColor(a.role))
                        Text(verbatim: "@" + a.name)
                            .font(BrahmaTheme.mono.weight(.semibold))
                            .foregroundStyle(BrahmaTheme.text0)
                            .strikethrough(a.state == .killed)
                            .lineLimit(1)
                    }
                    KeyValueGrid(rows: [
                        KeyValueRow(label: "Role", value: a.role),
                        KeyValueRow(label: "Model", value: a.model, mono: true),
                        KeyValueRow(label: "State", value: detail.stateLabel, mono: true,
                                    valueColor: BrahmaTheme.statusColor(for: a.state)),
                    ] + (detail.blockerText.isEmpty ? [] : [KeyValueRow(label: "Blocker", value: detail.blockerText)]))
                    Hairline()
                    CapsLabel("Last turn")
                    Text(verbatim: detail.lastTurnLine).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                    if let summary = detail.lastTurnSummary, !summary.isEmpty {
                        Text(verbatim: summary)
                            .font(BrahmaTheme.body)
                            .foregroundStyle(BrahmaTheme.text0)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                    Hairline()
                    if a.state == .killed {
                        Text(verbatim: "Killed — history kept.").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                    }
                    HStack(spacing: BrahmaTheme.spaceS) {
                        Button("Message") { model.openDM(handle: a.name) }.buttonStyle(.brahmaPrimary)
                        Button("Pause") { Task { await model.setAgentPaused(a.id, true) } }
                            .buttonStyle(.brahma).disabled(!detail.canPause)
                        Button("Wake") { Task { await model.setAgentPaused(a.id, false) } }
                            .buttonStyle(.brahma).disabled(!detail.canWake)
                        Button("Kill…") { confirmKill = true }
                            .buttonStyle(.brahma).disabled(!detail.canKill)
                    }
                }
                .padding(BrahmaTheme.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(Text(verbatim: "Kill @\(a.name)?"), isPresented: $confirmKill, titleVisibility: .visible) {
            Button(role: .destructive) { Task { await model.kill(agentId: a.id) } } label: {
                Text(verbatim: "Kill @\(a.name)")
            }
        } message: {
            Text(verbatim: "@\(a.name) stops for good. Its history is kept. This can't be undone.")
        }
    }
}
