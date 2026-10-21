import SwiftUI
import BrahmaAppModel

struct Sidebar: View {
    let model: AppModel
    @State private var conversationsExpanded = false
    @State private var newDMShown = false

    var body: some View {
        let sections = model.sidebar
        List(selection: Binding<SidebarItem?>(
            get: { model.sidebarSelection },
            set: { if let item = $0 { model.select(item) } }
        )) {
            Label("Mission Control", systemImage: "square.grid.2x2").tag(SidebarItem.missionControl)
            Label("Activity", systemImage: "list.bullet.rectangle").tag(SidebarItem.activity)
            Label("Agents", systemImage: "person.3").tag(SidebarItem.agents)

            if !sections.channels.isEmpty {
                Section("Channels") {
                    ForEach(sections.channels) { row in
                        SidebarRowView(row: row, showCount: false)
                    }
                }
            }
            Section {
                ForEach(sections.directMessages) { row in
                    SidebarRowView(row: row, showCount: true)
                }
            } header: {
                HStack {
                    Text("Direct messages")
                    Spacer()
                    Button { newDMShown = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New direct message")
                        .popover(isPresented: $newDMShown) { NewDMPicker(model: model, isPresented: $newDMShown) }
                }
            }
            if !sections.agentConversations.isEmpty {
                Section("Agent conversations", isExpanded: $conversationsExpanded) {
                    ForEach(sections.agentConversations) { row in
                        SidebarRowView(row: row, showCount: false)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }
}

private struct SidebarRowView: View {
    let row: SidebarRow
    let showCount: Bool

    var body: some View {
        HStack {
            Text(verbatim: row.title)
                .fontWeight(row.unread > 0 ? .bold : .regular)
                .lineLimit(1)
            Spacer()
            if showCount && row.unread > 0 {
                Text(verbatim: "\(row.unread)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .tag(row.item)
    }
}
