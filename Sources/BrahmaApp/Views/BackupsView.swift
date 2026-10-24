import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// Settings › BACKUPS: when each backup last ran, the off-machine targets, the optional WAL shipping switch, and "Back up now".
struct BackupsView: View {
    let model: BackupsModel
    @State private var folder = ""
    @State private var remote = ""
    @State private var replica = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                statusPanel
                targetsPanel
                walPanel
            }
            .padding(BrahmaTheme.spaceS)
        }
        .background(BrahmaTheme.bg0)
        .task { await model.refresh() }
    }

    private var statusPanel: some View {
        Panel(title: "Backups", accessory: {
            Button { Task { await model.backUpNow() } } label: {
                Label(model.isBackingUp ? "Backing up" : "Back up now", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.brahmaPrimary)
            .disabled(model.isBackingUp)
        }, content: {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                KeyValueGrid(rows: model.statusLines.map {
                    KeyValueRow(label: $0.label, value: $0.value, mono: true,
                                valueColor: $0.value == "never" ? BrahmaTheme.text2 : BrahmaTheme.text0)
                })
                if let message = model.message, model.error == nil {
                    Text(verbatim: message).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.success)
                }
                errorLine
            }
        })
    }

    @ViewBuilder private var errorLine: some View {
        if let error = model.error {
            Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                .textSelection(.enabled)
        }
    }

    private var targetsPanel: some View {
        Panel(title: "Off-machine targets", padded: false, accessory: {
            MonoChip(text: "\(model.targets.count)", color: BrahmaTheme.text1)
        }, content: {
            VStack(alignment: .leading, spacing: 0) {
                if model.targets.isEmpty {
                    Text(verbatim: "NO TARGETS").font(BrahmaTheme.monoSmall).tracking(BrahmaTheme.labelTracking)
                        .foregroundStyle(BrahmaTheme.text2)
                        .padding(BrahmaTheme.panelPadding)
                }
                ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
                    HStack(spacing: BrahmaTheme.spaceS) {
                        Text(verbatim: "\(index + 1)").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                            .frame(width: 18, alignment: .trailing)
                        Text(verbatim: target.summary).font(BrahmaTheme.mono).foregroundStyle(BrahmaTheme.text0)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: BrahmaTheme.spaceS)
                        Button("Remove") { Task { await model.remove(number: index + 1) } }
                            .buttonStyle(.brahma)
                    }
                    .tableRow(index: index)
                }
                Hairline()
                VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                    HStack(spacing: BrahmaTheme.spaceS) {
                        TextField("Folder, e.g. /Volumes/Backup", text: $folder).brahmaField()
                        Button("Choose") { chooseFolder() }.buttonStyle(.brahma)
                        Button("Add folder") {
                            let path = folder
                            Task { await model.addFolder(path); if model.error == nil { folder = "" } }
                        }
                        .buttonStyle(.brahma).disabled(folder.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack(spacing: BrahmaTheme.spaceS) {
                        TextField("rclone crypt remote name", text: $remote).brahmaField()
                        Button("Add remote") {
                            let name = remote
                            Task { await model.addRclone(name); if model.error == nil { remote = "" } }
                        }
                        .buttonStyle(.brahma).disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(verbatim: "Folders are mirrored under <folder>/<hostname>/. Remotes must be rclone crypt: Brahma only uploads encrypted backups.")
                        .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                }
                .padding(BrahmaTheme.panelPadding)
            }
        })
    }

    private var walPanel: some View {
        Panel(title: "WAL shipping", accessory: {
            if model.walEnabled { StatusChip(label: "On", color: BrahmaTheme.running) }
        }, content: {
            VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
                Toggle(isOn: Binding(get: { model.walEnabled }, set: { on in
                    let target = replica
                    Task { await model.setWAL(enabled: on, replica: target) }
                })) {
                    Text(verbatim: "Ship the write-ahead log with Litestream").font(BrahmaTheme.body)
                        .foregroundStyle(BrahmaTheme.text0)
                }
                .toggleStyle(.switch)
                .tint(BrahmaTheme.accent)
                .disabled(model.walToggleDisabled)
                if let note = model.walNote {
                    Text(verbatim: note).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
                }
                if model.walEnabled, let current = model.walReplica {
                    KeyValueGrid(rows: [KeyValueRow(label: "Replica", value: current, mono: true)])
                } else {
                    TextField("Replica folder or URL (s3://bucket/path)", text: $replica).brahmaField()
                        .disabled(model.walToggleDisabled)
                }
                Text(verbatim: "Takes effect when Brahma next starts. Credentials come from the environment, never from here.")
                    .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
            }
        })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
