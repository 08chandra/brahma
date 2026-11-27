import SwiftUI
import BrahmaAppModel

struct MainWindow: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch delegate.boot {
            case .success(let booted):
                Shell(model: booted.model)
            case .failure(let error):
                StartupErrorView(error: error)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(BrahmaTheme.bg0)
        .preferredColorScheme(.dark)
        .onAppear {
            delegate.openMainWindow = { openWindow(id: "main") }
            delegate.openMapWindow = { openWindow(id: AgentMapPanel.windowId) }
        }
    }
}

/// Top bar across the window; below it rail | sidebar | detail, all on solid backgrounds (no vibrancy).
private struct Shell: View {
    @Bindable var model: AppModel
    @State private var sidebarWidth: CGFloat = 220
    /// The plan-tier alert is shown once per reported mismatch; "Not now" hides it until the text changes.
    @State private var dismissedPlanAlert: String?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            HStack(spacing: 0) {
                CompanyRail(model: model).frame(width: BrahmaTheme.railWidth)
                Hairline(axis: .vertical)
                Sidebar(model: model).frame(width: sidebarWidth)
                SplitDivider(width: $sidebarWidth, range: 180...320)
                VStack(spacing: 0) {
                    EngineBanner(engine: model.engine, notice: model.startupNotice, hold: model.holdBanner,
                                 canRetryHold: model.canRetryEngine, retryHold: { Task { await model.retryEngine() } },
                                 secrets: model.secretsBanner, loadSecrets: { Task { await model.loadSecrets() } },
                                 sandbox: model.sandboxBanner, openInbox: { model.select(.inbox) },
                                 stopped: model.stopBanner, resume: { Task { await model.resumeAfterStop() } })
                    DetailView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .background(BrahmaTheme.bg0)
            }
        }
        .background(BrahmaTheme.bg0)
        .ignoresSafeArea(.container, edges: .top)
        // Plan C C7a: the ⌘K palette over any view, and the sheets the ref actions open (Share to…, Quote, Purge).
        .showPaletteHost(model: model)
        .refActionHost(model: model)
        .navigationTitle(Text(verbatim: model.selectedCompany?.company.name ?? "Brahma"))
        .sheet(item: $model.presentedSheet) { sheet in
            Group {
                switch sheet {
                case .newCompany: NewCompanySheet(model: model)
                case .hire: HireSheet(model: model)
                case .newItem: ItemEditorSheet(model: model)
                case .vacancy(let managerHandle): VacancySheet(model: model, managerHandle: managerHandle)
                case .fillVacancy(let handle): FillVacancySheet(model: model, handle: handle)
                case .mergeSettings: MergeSettingsSheet(model: model)
                }
            }
            .background(BrahmaTheme.bg1)
            .preferredColorScheme(.dark)
        }
        .alert("Confirm your Claude plan", isPresented: Binding(
            get: { model.planMismatchAlert != nil && model.planMismatchAlert != dismissedPlanAlert && model.errorMessage == nil },
            set: { if !$0 { dismissedPlanAlert = model.planMismatchAlert } }
        )) {
            Button("Use the reported plan") { Task { await model.confirmReportedPlan() } }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(verbatim: model.planMismatchAlert ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }
}
