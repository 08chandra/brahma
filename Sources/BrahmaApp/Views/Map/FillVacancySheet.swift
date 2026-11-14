import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The confirmation for Fill: hiring an open seat starts a new paid agent, so the map's `Fill…` only opens this sheet. It
/// shows `controller.fillPreview(handle:)`; when the seat is gone (filled, removed, or the company changed) it says so.
struct FillVacancySheet: View {
    let model: AppModel
    /// The map's cleaned vacancy id.
    let handle: String
    @State private var preview: FillPreview?
    @State private var loaded = false
    @State private var submitError: String?
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Fill vacancy")
            Group {
                if let preview {
                    confirmation(preview)
                } else if loaded {
                    VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                        Text(verbatim: "This seat is no longer open")
                            .font(BrahmaTheme.companyTitle).foregroundStyle(BrahmaTheme.text0)
                        Text(verbatim: "It was filled or removed, or the company changed.")
                            .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1)
                    }
                } else {
                    EmptyView()
                }
            }
            .padding(BrahmaTheme.spaceL)
            .frame(maxWidth: .infinity, alignment: .leading)
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                Spacer()
                if preview != nil {
                    Button("Cancel") { model.presentedSheet = nil }
                        .buttonStyle(.brahma)
                        .keyboardShortcut(.cancelAction)
                    Button("Hire") { hire() }
                        .buttonStyle(.brahmaPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(submitting)
                } else {
                    Button("Close") { model.presentedSheet = nil }
                        .buttonStyle(.brahma)
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(BrahmaTheme.spaceM)
            .background(BrahmaTheme.bg2)
        }
        .frame(width: 440)
        .background(BrahmaTheme.bg1)
        // The seat can be filled or removed while the sheet is open (a teammate's CLI, the map's own menu): re-read it.
        .task(id: handle) {
            while !Task.isCancelled {
                refresh()
                try? await AwakeTime.sleep(for: .milliseconds(500))
            }
        }
    }

    private func confirmation(_ preview: FillPreview) -> some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            Text(verbatim: "Hire @" + MapText.clean(preview.handle, max: 40) + "?")
                .font(BrahmaTheme.companyTitle).foregroundStyle(BrahmaTheme.text0)
                .lineLimit(2)
            KeyValueGrid(rows: [
                KeyValueRow(label: "Role", value: MapText.clean(preview.roleTitle, max: 60)),
                KeyValueRow(label: "Manager", value: preview.managerHandle.map { "@" + MapText.clean($0, max: 40) } ?? "Board",
                            mono: true),
                KeyValueRow(label: "Team", value: MapText.clean(preview.team, max: 40)),
                KeyValueRow(label: "Company", value: MapText.clean(preview.companyName, max: 40)),
            ])
            Text(verbatim: FillPreview.costLine)
                .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            if let submitError {
                Text(verbatim: submitError).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        let next = model.mapController?.fillPreview(handle: handle)
        if next != preview { preview = next }
        if !loaded { loaded = true }
    }

    private func hire() {
        guard !submitting else { return }
        submitting = true
        submitError = nil
        Task {
            defer { submitting = false }
            guard let controller = model.ensureMapController() else {
                submitError = "The map is not available for this company"
                return
            }
            do {
                try await controller.fillVacancy(handle: handle)
                model.presentedSheet = nil
            } catch {
                submitError = mapErrorText(error)
                refresh()
            }
        }
    }
}
