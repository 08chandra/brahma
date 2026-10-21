import SwiftUI
import BrahmaCore
import BrahmaAppModel

struct TopBar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let summary = model.selectedCompany {
                usage
                Picker("Usage mode", selection: Binding(
                    get: { summary.company.usageMode },
                    set: { mode in Task { await model.setUsageMode(mode) } }
                )) {
                    Text("Low").tag(UsageMode.low)
                    Text("Balanced").tag(UsageMode.balanced)
                    Text("Max").tag(UsageMode.max)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                let running = summary.company.status == .running
                Button {
                    Task { await model.setCompanyRunning(!running, companyId: summary.id) }
                } label: {
                    Label(running ? "Pause company" : "Run company", systemImage: running ? "pause.fill" : "play.fill")
                }
                .labelStyle(.titleAndIcon)
            }
        }
    }

    @ViewBuilder private var usage: some View {
        if let gate = model.usageGateLine {
            Label { Text(verbatim: gate) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.orange)
        } else {
            Text(verbatim: model.usageLine).foregroundStyle(.secondary)
        }
    }
}
