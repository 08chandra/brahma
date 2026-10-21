import SwiftUI
import BrahmaAppModel
import BrahmaCore

struct NewDMPicker: View {
    let model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        let agents = model.snapshot.agents.filter { $0.state != .killed }
        VStack(alignment: .leading, spacing: 0) {
            if agents.isEmpty {
                Text(verbatim: "No agents to message yet.").foregroundStyle(.secondary).padding(12)
            }
            ForEach(agents, id: \.id) { agent in
                Button {
                    model.select(.dm(handle: agent.name))
                    isPresented = false
                } label: {
                    Text(verbatim: "@\(agent.name) — \(agent.role)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220)
    }
}
