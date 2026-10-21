import SwiftUI
import BrahmaAppModel

struct MainWindow: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch delegate.boot {
            case .success(let model):
                Shell(model: model)
            case .failure(let error):
                StartupErrorView(error: error)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { delegate.openMainWindow = { openWindow(id: "main") } }
    }
}

private struct Shell: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            CompanyRail(model: model).frame(width: 68)
            Divider()
            NavigationSplitView {
                Sidebar(model: model)
            } detail: {
                DetailView(model: model)
            }
            .navigationTitle(Text(verbatim: model.selectedCompany?.company.name ?? "Brahma"))
            .navigationSubtitle(Text(verbatim: model.selectedCompany?.counts.line ?? ""))
            .toolbar { TopBar(model: model) }
        }
        .sheet(item: $model.presentedSheet) { sheet in
            switch sheet {
            case .newCompany: NewCompanySheet(model: model)
            case .hire: HireSheetPlaceholder(model: model)
            }
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

private struct HireSheetPlaceholder: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView("Hire Agent", systemImage: "person.badge.plus")
            Button("Close") { model.presentedSheet = nil }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 420, height: 300)
    }
}
