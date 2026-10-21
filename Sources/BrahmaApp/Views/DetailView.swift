import SwiftUI
import BrahmaAppModel

struct DetailView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.loaded && model.snapshot.companies.isEmpty {
                VStack(spacing: BrahmaTheme.spaceM) {
                    MonoEmptyState("Create your first company",
                                   detail: "Give it a name and a goal; you can hire agents next.")
                        .fixedSize()
                    Button("New Company") { model.presentedSheet = .newCompany }
                        .buttonStyle(.brahmaPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.sidebarSelection {
                case .missionControl:
                    MonoEmptyState("Mission control", detail: "No panels yet")
                case .activity:
                    MonoEmptyState("Activity", detail: "No activity yet")
                case .agents:
                    MonoEmptyState("Agents", detail: "No roster yet")
                case .channel, .dm:
                    if let chat = model.chat {
                        VSplitView {
                            ChatView(chat: chat)
                                .id(chat.target)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .frame(minHeight: 200)
                            Panel(title: "Activity", padded: false) {  // Task 7
                                MonoEmptyState("No activity yet")
                            }
                            .padding(BrahmaTheme.spaceXS)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 60, idealHeight: 100, maxHeight: 200)
                            .background(BrahmaTheme.bg0)
                        }
                    }
                }
            }
        }
        .background(BrahmaTheme.bg0)
    }
}
