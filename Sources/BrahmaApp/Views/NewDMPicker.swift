import SwiftUI
import BrahmaAppModel
import BrahmaCore

struct NewDMPicker: View {
    let model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        let agents = model.snapshot.agents.filter { $0.state != .killed }
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "New direct message")
            if agents.isEmpty {
                MonoEmptyState("No agents to message yet").fixedSize()
            }
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                Button {
                    model.select(.dm(handle: agent.name))
                    isPresented = false
                } label: {
                    HStack(spacing: BrahmaTheme.spaceS) {
                        MonogramAvatar(monogram: String(agent.name.prefix(2)).uppercased(),
                                       color: BrahmaTheme.roleColor(agent.role), size: 16)
                        Text(verbatim: "@" + agent.name).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                        Text(verbatim: agent.role).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text2)
                        Spacer(minLength: BrahmaTheme.spaceS)
                        Circle().fill(BrahmaTheme.statusColor(for: agent.state)).frame(width: 6, height: 6)
                    }
                }
                .buttonStyle(.plain)
                .tableRow(index: index, selected: false)
                .accessibilityLabel(Text(verbatim: "@\(agent.name) — \(agent.role)"))
            }
        }
        .frame(minWidth: 240)
        .background(BrahmaTheme.bg2)
        .preferredColorScheme(.dark)
    }
}
