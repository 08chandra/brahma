import SwiftUI
import BrahmaAppModel

struct CompanyRail: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.snapshot.companies) { summary in
                        RailIcon(summary: summary, selected: summary.id == model.selectedCompanyId)
                            .onTapGesture { Task { await model.selectCompany(summary.id) } }
                            .help(summary.company.name)
                            .contextMenu {
                                let running = summary.company.status == .running
                                Button(running ? "Pause" : "Resume") {
                                    Task { await model.setCompanyRunning(!running, companyId: summary.id) }
                                }
                            }
                    }
                }
                .padding(.top, 12)
            }
            Button {
                model.presentedSheet = .newCompany
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .help("New company")
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}

private struct RailIcon: View {
    let summary: CompanySummary
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            Text(verbatim: summary.initials)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(summary.company.status == .running ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .offset(x: 3, y: 3)
        }
        .overlay(alignment: .topTrailing) {
            if summary.badge > 0 {
                Text(verbatim: summary.badge > 99 ? "99+" : "\(summary.badge)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 6, y: -6)
            }
        }
        .contentShape(Rectangle())
    }
}
