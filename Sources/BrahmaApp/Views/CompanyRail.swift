import SwiftUI
import BrahmaAppModel

struct CompanyRail: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.snapshot.companies) { summary in
                        RailTile(initials: summary.initials,
                                 selected: summary.id == model.selectedCompanyId,
                                 running: summary.company.status == .running,
                                 badge: summary.badge)
                            .onTapGesture { Task { await model.selectCompany(summary.id) } }
                            .help(summary.company.name)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: summary.company.name))
                            .accessibilityAddTraits(summary.id == model.selectedCompanyId ? [.isButton, .isSelected] : .isButton)
                            .contextMenu {
                                let running = summary.company.status == .running
                                Button(running ? "Pause" : "Resume") {
                                    Task { await model.setCompanyRunning(!running, companyId: summary.id) }
                                }
                            }
                    }
                }
                .padding(.top, BrahmaTheme.spaceS)
            }
            .scrollIndicators(.never)
            Button {
                model.presentedSheet = .newCompany
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BrahmaTheme.text1)
                    .frame(width: BrahmaTheme.railTile, height: BrahmaTheme.railTile)
                    .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge)
                        .strokeBorder(BrahmaTheme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New company")
            .padding(.vertical, BrahmaTheme.spaceM)
        }
        .frame(maxHeight: .infinity)
        .background(BrahmaTheme.bg1)
    }
}
