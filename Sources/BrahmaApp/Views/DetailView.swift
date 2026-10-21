import SwiftUI
import BrahmaAppModel

struct DetailView: View {
    let model: AppModel

    var body: some View {
        if model.loaded && model.snapshot.companies.isEmpty {
            ContentUnavailableView {
                Label("Create your first company", systemImage: "building.2")
            } description: {
                Text("Give it a name and a goal; you can hire agents next.")
            } actions: {
                Button("New Company") { model.presentedSheet = .newCompany }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch model.sidebarSelection {
            case .missionControl:
                ContentUnavailableView("Mission Control", systemImage: "square.grid.2x2")
            case .activity:
                ContentUnavailableView("Activity", systemImage: "list.bullet.rectangle")
            case .agents:
                ContentUnavailableView("Agents", systemImage: "person.3")
            case .channel(let id):
                let title = model.sidebar.channels.first { $0.item == .channel(id: id) }?.title
                    ?? model.sidebar.agentConversations.first { $0.item == .channel(id: id) }?.title ?? "Channel"
                ContentUnavailableView { Label { Text(verbatim: title) } icon: { Image(systemName: "number") } }
            case .dm(let handle):
                ContentUnavailableView { Label { Text(verbatim: "@" + handle) } icon: { Image(systemName: "bubble.left") } }
            }
        }
    }
}
