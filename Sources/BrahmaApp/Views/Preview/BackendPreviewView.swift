import SwiftUI
import BrahmaAppModel

/// A running backend (Plan 4a Task 9a): the engine's SMOKE results as a zebra table, an "API" toggle that opens the
/// operations of the engine's OpenAPI copy, and the LOG tail (through `AnsiText`). The smoke table and the log are
/// engine-produced and always shown: `operationsNote` (the OpenAPI copy could not be read, or its parse timed out) is said
/// inside the API section only, since the copy is agent-authored and must not hide anything. Method, path, summary and log
/// text are agent-controlled (`Text(verbatim:)`).
struct BackendPreviewView: View {
    let smoke: [SmokeRow]
    let logTail: [String]
    let operations: [OpenAPIOperation]
    let operationsNote: String?
    @State private var showsAPI = false

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader("Smoke", count: smoke.count) {
                Button { withAnimation(BrahmaTheme.fast) { showsAPI.toggle() } } label: {
                    Label("API", systemImage: showsAPI ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(showsAPI ? .brahmaPrimary : .brahma)
                .fixedSize()
                .help(showsAPI ? "Hide the API operations" : "Show the API operations")
                .accessibilityLabel(Text(verbatim: showsAPI ? "Hide API operations" : "Show API operations"))
            }
            smokeTable
            if showsAPI {
                Hairline()
                sectionHeader("API", count: operations.isEmpty ? nil : operations.count) {}
                apiSection
            }
            Hairline()
            sectionHeader("Log", count: logTail.isEmpty ? nil : logTail.count) {}
            AnsiLinesView(lines: logTail, emptyTitle: "NO LOG YET", followsTail: true)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sections

    private func sectionHeader<A: View>(_ title: String, count: Int?, @ViewBuilder accessory: () -> A) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            CapsLabel(title, color: BrahmaTheme.text1)
            if let count { MonoChip(text: "\(count)", color: BrahmaTheme.text1, fill: BrahmaTheme.bg4) }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .frame(height: BrahmaTheme.panelHeaderHeight)
        .frame(maxWidth: .infinity)
        .background(BrahmaTheme.bg3)
    }

    @ViewBuilder private var smokeTable: some View {
        if smoke.isEmpty {
            MonoEmptyState("NO SMOKE CHECKS", detail: "When DevOps sets smoke checks, their results show here.")
                .frame(minHeight: 60, maxHeight: 90)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(smoke.enumerated()), id: \.offset) { index, row in
                        smokeRow(row).tableRow(index: index, height: BrahmaTheme.denseRowHeight)
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(smoke.count, 6)) * BrahmaTheme.denseRowHeight)
        }
    }

    private func smokeRow(_ row: SmokeRow) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Circle().fill(row.ok ? BrahmaTheme.success : BrahmaTheme.danger).frame(width: 6, height: 6)
            Text(verbatim: row.method).font(BrahmaTheme.monoSmall.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                .frame(width: 52, alignment: .leading)
            Text(verbatim: row.path).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text0).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if let error = row.error, !error.isEmpty {
                Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: BrahmaTheme.spaceS)
            Text(verbatim: "\(row.millis) ms").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)
                .frame(width: 64, alignment: .trailing)
            MonoChip(text: row.statusTitle, color: row.ok ? BrahmaTheme.success : BrahmaTheme.danger, fill: BrahmaTheme.bg4)
                .frame(width: 36)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var apiSection: some View {
        if let operationsNote {
            // The engine-written reason the section is empty; it stays here, never over the smoke table or the log.
            HStack(spacing: BrahmaTheme.spaceS) {
                StatusChip(label: "No operations", color: BrahmaTheme.warning)
                Text(verbatim: operationsNote).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(BrahmaTheme.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if operations.isEmpty {
            MonoEmptyState("NO OPERATIONS", detail: "The preview names no OpenAPI file, or it lists no paths.")
                .frame(minHeight: 60, maxHeight: 90)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(operations.enumerated()), id: \.offset) { index, op in
                        HStack(spacing: BrahmaTheme.spaceS) {
                            Text(verbatim: op.method).font(BrahmaTheme.monoSmall.weight(.semibold)).foregroundStyle(BrahmaTheme.ready)
                                .frame(width: 52, alignment: .leading)
                            Text(verbatim: op.path).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
                                .truncationMode(.middle)
                            if let summary = op.summary, !summary.isEmpty {
                                Text(verbatim: summary).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .tableRow(index: index, height: BrahmaTheme.denseRowHeight)
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(operations.count, 8)) * BrahmaTheme.denseRowHeight)
        }
    }
}
