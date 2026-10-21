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
            case .channel, .dm:
                if let chat = model.chat {
                    VSplitView {
                        ChatView(chat: chat)
                            .id(chat.target)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: 200)
                        ContentUnavailableView("Activity", systemImage: "list.bullet.rectangle")  // Task 7
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 60, idealHeight: 100, maxHeight: 200)
                    }
                }
            }
        }
    }
}
