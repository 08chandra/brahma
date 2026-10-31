import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The Inbox card of a `grant` ask: `ACCESS REQUEST · A-<n>`, a risk chip, the KIND / VALUE / REQUESTED BY / ITEM / REASON
/// grid, the SCOPE and DURATION segments (defaults from the agent's proposal) and `Approve` / `Deny…`. This is THE approve
/// path for an access ask: the owner picks the scope and duration, and `Store.approveAccess` writes the grant.
struct AccessCardView: View {
    let model: AppModel
    let card: AccessCard
    @State private var scope: GrantScope
    @State private var duration: GrantDuration
    @State private var note = ""
    @State private var reason = ""
    @State private var showDeny = false
    @State private var busy = false

    init(model: AppModel, card: AccessCard) {
        self.model = model
        self.card = card
        _scope = State(initialValue: card.scope)
        _duration = State(initialValue: card.duration)
    }

    private var riskColor: Color {
        switch card.risk {
        case .low: BrahmaTheme.success
        case .medium: BrahmaTheme.warning
        case .high: BrahmaTheme.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Access request · \(card.ref)", font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
                StatusChip(label: card.riskLabel, color: riskColor)
                if card.isWildcard { WarningChip(label: "Wildcard: every subdomain") }
                Spacer(minLength: 0)
            }
            KeyValueGrid(rows: rows)
            Hairline()
            HStack(spacing: BrahmaTheme.spaceL) {
                HStack(spacing: BrahmaTheme.spaceS) {
                    CapsLabel("Scope")
                    Segmented(options: card.availableScopes.map { ($0, $0.rawValue) }, selection: scope, label: "Scope") { scope = $0 }
                }
                HStack(spacing: BrahmaTheme.spaceS) {
                    CapsLabel("Duration")
                    Segmented(options: GrantDuration.allCases.map { ($0, $0.rawValue) }, selection: duration, label: "Duration") { duration = $0 }
                }
                Spacer(minLength: 0)
            }
            Text(verbatim: card.sentence(scope: scope, duration: duration))
                .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.access.cardErrors[card.id] {
                Text(verbatim: error).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger).textSelection(.enabled)
            }
            TextField("Note", text: $note, prompt: Text(verbatim: "Add a note (optional)")).brahmaField()
            HStack(spacing: BrahmaTheme.spaceS) {
                Button("Approve") { run { await model.access.approve(askId: card.id, scope: scope, duration: duration, note: note) } }
                    .buttonStyle(.brahmaPrimary).disabled(busy)
                Button("Deny…") { showDeny = true }.buttonStyle(.brahma).disabled(busy)
                    .popover(isPresented: $showDeny, arrowEdge: .bottom) { denyPopover }
                Spacer()
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) }
    }

    private var rows: [KeyValueRow] {
        var rows = [KeyValueRow(label: "Kind", value: card.kind.rawValue, mono: true),
                    KeyValueRow(label: "Value", value: card.value, mono: true),
                    KeyValueRow(label: "Requested by", value: card.requester, mono: true)]
        if let item = card.itemKey { rows.append(KeyValueRow(label: "Item", value: item, mono: true)) }
        rows.append(KeyValueRow(label: "Reason", value: card.reason.isEmpty ? "—" : card.reason,
                                valueColor: card.reason.isEmpty ? BrahmaTheme.text2 : BrahmaTheme.text0))
        return rows
    }

    private var denyPopover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel("Deny \(card.ref)")
            Text(verbatim: "The agent reads your reason and keeps working without the access.")
                .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).fixedSize(horizontal: false, vertical: true)
            TextField("Why", text: $reason, prompt: Text(verbatim: "Reason (required)")).brahmaField()
            HStack {
                Spacer()
                Button("Cancel") { showDeny = false }.buttonStyle(.brahma)
                Button("Deny") {
                    showDeny = false
                    run { await model.access.deny(askId: card.id, reason: reason) }
                }
                .buttonStyle(.brahmaPrimary)
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 320)
        .background(BrahmaTheme.bg1)
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }
}

/// The Inbox card of a secret `request` ask (Task 4-wire's `request_secret`): the ask as the agent wrote it and `Provide…`,
/// which opens the secret sheet; the value goes to the vault through `AppModel.provideSecret`.
struct SecretRequestCard: View {
    let model: AppModel
    let row: InboxRow
    @State private var showSheet = false
    @State private var reason = ""
    @State private var showDeny = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Secret request · \(row.ref)", font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
                StatusChip(label: row.riskLabel, color: riskColor)
                WarningChip(label: "reserved")
                Spacer(minLength: 0)
            }
            Text(verbatim: row.title).font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0).textSelection(.enabled)
            Text(verbatim: "from " + row.requester).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
            if !row.summary.isEmpty {
                Text(verbatim: row.summary).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let details = row.details, !details.isEmpty {
                Text(verbatim: details).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text1).textSelection(.enabled)
            }
            Text(verbatim: "The value goes to Brahma's vault, never to the agent's chat. Test keys reach the agent's environment on its next turn; other keys stay with the engine.")
                .font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: BrahmaTheme.spaceS) {
                Button("Provide…") { showSheet = true }.buttonStyle(.brahmaPrimary).disabled(busy)
                Button("Deny…") { showDeny = true }.buttonStyle(.brahma).disabled(busy)
                    .popover(isPresented: $showDeny, arrowEdge: .bottom) { denyPopover }
                Spacer()
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(BrahmaTheme.warning).frame(width: 2) }
        .sheet(isPresented: $showSheet) {
            SecretSheet(title: "Provide the secret for \(row.ref)", initialName: Self.secretName(in: row.title)) { form in
                await model.provideSecret(askId: row.id, form: form)
            }
            .background(BrahmaTheme.bg1)
            .preferredColorScheme(.dark)
        }
    }

    /// `success` low, `warning` medium, `danger` high, from the ask's risk.
    private var riskColor: Color {
        if row.riskLabel.hasPrefix("High") { return BrahmaTheme.danger }
        if row.riskLabel.hasPrefix("Medium") { return BrahmaTheme.warning }
        return BrahmaTheme.success
    }

    /// The first token of the title that is a valid secret name ("secret STRIPE_KEY for INITE-2" → STRIPE_KEY).
    static func secretName(in title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).map(String.init).first { SecretName.isValid($0) } ?? ""
    }

    private var denyPopover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel("Deny \(row.ref)")
            TextField("Why", text: $reason, prompt: Text(verbatim: "Reason (required)")).brahmaField()
            HStack {
                Spacer()
                Button("Cancel") { showDeny = false }.buttonStyle(.brahma)
                Button("Deny") {
                    showDeny = false
                    busy = true
                    Task { _ = await model.decide(askId: row.id, approve: false, note: reason); busy = false }
                }
                .buttonStyle(.brahmaPrimary)
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 320)
        .background(BrahmaTheme.bg1)
    }
}
