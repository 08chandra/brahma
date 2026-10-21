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
            } else if !model.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResultsView(model: model)
            } else {
                switch model.sidebarSelection {
                case .missionControl:
                    MissionControlView(model: model)
                case .activity:
                    ActivityFeedView(model: model, compact: false)
                case .agents:
                    VSplitView {
                        AgentsView(model: model)
                            .frame(minHeight: 200)
                        ActivityFeedView(model: model, compact: true)
                            .frame(minHeight: 60, idealHeight: 140, maxHeight: 260)
                    }
                case .channel, .dm:
                    if let chat = model.chat {
                        VSplitView {
                            ChatView(chat: chat, highlightedId: Bindable(model).highlightedMessageId)
                                .id(chat.target)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .frame(minHeight: 200)
                            ActivityFeedView(model: model, compact: true)
                                .frame(minHeight: 60, idealHeight: 140, maxHeight: 260)
                        }
                    }
                }
            }
        }
        .background(BrahmaTheme.bg0)
    }
}
