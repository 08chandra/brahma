import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// Layout B: PREVIEW and AGENT MAP side by side over ACTIVITY, with draggable 1 px dividers.
struct MissionControlView: View {
    let model: AppModel
    @State private var topHeight: CGFloat = 300
    @State private var previewWidth: CGFloat = 340

    var body: some View {
        GeometryReader { geo in
            let maxTop = max(240, geo.size.height - 140)
            let maxPreview = max(200, geo.size.width - 300)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    PreviewPlaceholder()
                        .frame(width: min(previewWidth, maxPreview))
                    SplitDivider(width: $previewWidth, range: 200...maxPreview, axis: .vertical)
                    AgentMapPlaceholder(model: model)
                        .frame(maxWidth: .infinity)
                }
                .padding(BrahmaTheme.spaceXS)
                .frame(height: min(topHeight, maxTop))
                SplitDivider(width: $topHeight, range: 240...maxTop, axis: .horizontal)
                ActivityFeedView(model: model, compact: true)
                    .frame(maxHeight: .infinity)
            }
        }
        .background(BrahmaTheme.bg0)
    }
}

struct PreviewPlaceholder: View {
    var body: some View {
        Panel(title: "Preview", accessory: {
            MonoChip(text: "PLACEHOLDER", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
        }, content: {
            Text(verbatim: "No preview yet. When the company has a running product or design artifacts, they appear here.")
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.text2)
                .multilineTextAlignment(.center)
                .padding(BrahmaTheme.spaceL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge)
                    .strokeBorder(BrahmaTheme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        })
    }
}

struct AgentMapPlaceholder: View {
    let model: AppModel

    var body: some View {
        Panel(title: "Agent map", padded: false, accessory: {
            MonoChip(text: "MAP VIEW COMING SOON", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4)
        }, content: {
            ZStack {
                GridBackground()
                if model.snapshot.agents.isEmpty {
                    VStack(spacing: BrahmaTheme.spaceM) {
                        MonoEmptyState("No agents yet.").fixedSize()
                        Button("Hire Agent") { model.presentedSheet = .hire }
                            .buttonStyle(.brahma)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: BrahmaTheme.spaceS)],
                                  alignment: .leading, spacing: BrahmaTheme.spaceS) {
                            ForEach(model.snapshot.agents, id: \.id) { agent in
                                AgentNode(agent: agent, handles: model.handles) {
                                    model.select(.agents)
                                    model.selectedAgentId = agent.id
                                }
                            }
                        }
                        .padding(BrahmaTheme.spaceM)
                    }
                }
            }
        })
    }
}

private struct AgentNode: View {
    let agent: Agent
    let handles: [String: String]
    let onTap: () -> Void

    private var color: Color {
        agent.paused && agent.state != .killed ? BrahmaTheme.sleeping : BrahmaTheme.statusColor(for: agent.state)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().strokeBorder(color, lineWidth: 2).frame(width: 9, height: 9)
                    Text(verbatim: "@" + agent.name)
                        .font(BrahmaTheme.bodyStrong)
                        .foregroundStyle(BrahmaTheme.text0)
                        .lineLimit(1)
                }
                Text(verbatim: agent.role)
                    .font(BrahmaTheme.body)
                    .foregroundStyle(BrahmaTheme.text1)
                    .lineLimit(1)
                StatusChip(label: AgentBadge.label(agent), color: color)
                let blocker = BlockerText.describe(agent.blocker, handles: handles)
                if !blocker.isEmpty {
                    Text(verbatim: blocker)
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.text2)
                        .lineLimit(1)
                }
            }
            .padding(BrahmaTheme.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg2))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(color.opacity(0.7), lineWidth: 1))
            .opacity(agent.state == .killed ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
