import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// What is waiting for the owner (PENDING), what the policy approved and only needs a look (FYI), and what was decided in
/// the last 14 days and can still be rescinded (RECENTLY DECIDED).
struct InboxView: View {
    let model: AppModel

    var body: some View {
        let rows = model.inboxRows
        Panel(title: "Inbox", padded: false, accessory: {
            MonoChip(text: "\(model.inboxCount)", color: .white, fill: model.inboxCount > 0 ? BrahmaTheme.accent : BrahmaTheme.bg4)
        }, content: {
            if rows.isEmpty {
                MonoEmptyState("Inbox is empty", detail: "Decisions and questions from your agents show up here.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
                        section("Pending", .pending, rows)
                        section("FYI", .fyi, rows)
                        section("Recently decided", .recent, rows)
                    }
                    .padding(BrahmaTheme.spaceM)
                }
            }
        })
        .padding(BrahmaTheme.spaceS)
    }

    @ViewBuilder private func section(_ title: String, _ section: InboxSection, _ rows: [InboxRow]) -> some View {
        let mine = rows.filter { $0.section == section }
        if !mine.isEmpty {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel(title, font: BrahmaTheme.panelTitle, color: BrahmaTheme.text1)
                MonoChip(text: "\(mine.count)", color: BrahmaTheme.text1)
            }
            .padding(.top, BrahmaTheme.spaceXS)
            ForEach(mine) { row in card(row) }
        }
    }

    /// A pending deploy or human task gets its live card; without one (missing release record, unreadable payload) it gets
    /// the read-only fallback (`LiveCardFallback`), never the generic card's Approve.
    @ViewBuilder private func card(_ row: InboxRow) -> some View {
        let pending = row.section == .pending
        let deploy = pending && row.kind == .deploy ? model.deployCard(for: row.id) : nil
        let task = pending && row.kind == .humanTask ? model.humanTaskCard(for: row.id) : nil
        if pending, row.kind == .grant, let card = model.accessCard(askId: row.id) {
            AccessCardView(model: model, card: card).id(card.id)
        } else if let deploy {
            DeployCardView(model: model, card: deploy).id(deploy.askId)
        } else if let task {
            HumanTaskCardView(model: model, card: task).id(task.askId)
        } else if let fallback = LiveCardFallback.for(row: row, deployCard: deploy, humanTaskCard: task) {
            LiveCardFallbackView(model: model, row: row, fallback: fallback).id(row.id)
        } else if pending, row.kind == .request, let ask = model.work.inbox.first(where: { $0.id == row.id }), FileRequests.isFileRequest(ask) {
            // Plan C C7a: an agent's file request (`details.request == "file"`): the engine's gated card with a drop zone.
            FileRequestCardView(model: model, row: row).id(row.id)
        } else if pending, row.kind == .request {
            SecretRequestCard(model: model, row: row)
        } else {
            InboxCard(model: model, row: row)
        }
    }
}

private struct InboxCard: View {
    let model: AppModel
    let row: InboxRow
    @State private var note = ""
    @State private var answer = ""
    @State private var redirect = ""
    @State private var showRedirect = false
    @State private var confirmChanged = false
    /// C2b-carry (b): the owner confirms which of the colliding files this alert's vouch is for.
    @State private var confirmFileVouch = false
    @State private var showRescind = false
    @State private var rescindNote = ""
    @State private var busy = false
    @State private var document: Result<AttributedString, SafeMarkdownError>?
    /// A pending question from an agent takes dropped files as (part of) the answer.
    @State private var drops: ResourceDropModel?

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            header
            if !row.summary.isEmpty { verbatim(row.summary, color: BrahmaTheme.text0) }
            if let question = row.question, !question.isEmpty {
                label("Question")
                verbatim(question, color: BrahmaTheme.text0)
            }
            brief
            documentView
            fileVouchSides
            controls
        }
        .padding(BrahmaTheme.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 2) }
        .task(id: "\(row.documentPath ?? "")|\(row.documentChanged)") {
            document = row.section == .recent ? nil : model.document(for: row)
        }
        .task(id: row.canAnswer) {
            drops = row.canAnswer ? ResourceDropModel(app: model, context: .inbox(askId: row.id), defaults: model.dropDefaults) : nil
        }
        .resourceDrops(drops, enabled: row.canAnswer) { sendAnswer() }
        .alert("The document changed after it was proposed. Approve the current version?", isPresented: $confirmChanged) {
            Button("Approve") { decide(true, acknowledgeChange: true) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Vouch for the file marked THIS ALERT, not the other one?", isPresented: $confirmFileVouch) {
            Button("Vouch for this file") { run { await model.vouchFile(askId: row.id, acknowledgeAmbiguity: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "Their names show the same. Only the file this alert is about (its id and sha256 above) is vouched. "
                 + "If it is a PDF, Brahma shares only a flattened re-render of its visible pages.")
        }
    }

    // MARK: Colliding file vouch (C2b-carry (b))

    /// The files this alert's vouch could be taken for, side by side: name as shown, id, sha256, refused at.
    @ViewBuilder private var fileVouchSides: some View {
        if row.canVouchFile && row.fileVouchNeedsConfirmation {
            label("Files whose names show the same")
            HStack(alignment: .top, spacing: BrahmaTheme.spaceS) {
                ForEach(Array(row.fileVouchSides.enumerated()), id: \.offset) { _, side in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: BrahmaTheme.spaceXS) {
                            if side.isThisAlert { StatusChip(label: "This alert", color: BrahmaTheme.accent) }
                            if side.vouched { StatusChip(label: "Vouched", color: BrahmaTheme.text2) }
                        }
                        Text(verbatim: side.shown).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text0).textSelection(.enabled)
                        Text(verbatim: "id " + side.id).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text1).textSelection(.enabled)
                        Text(verbatim: "sha256 " + side.sha256).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text1).textSelection(.enabled)
                        Text(verbatim: "refused " + side.refusedAt.formatted(date: .abbreviated, time: .standard))
                            .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                    }
                    .padding(BrahmaTheme.spaceS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(side.isThisAlert ? BrahmaTheme.bg4 : BrahmaTheme.bg1)
                    .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
                    .overlay(alignment: .leading) { if side.isThisAlert { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) } }
                }
            }
        }
    }

    private var accent: Color {
        row.isReserved ? BrahmaTheme.warning : (row.section == .pending ? BrahmaTheme.accent : BrahmaTheme.line)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: row.ref).font(BrahmaTheme.mono.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                StatusChip(label: row.kindTitle, color: BrahmaTheme.ready)
                if !row.categoryLabel.isEmpty {
                    if row.isReserved { WarningChip(label: row.categoryLabel + " · reserved") }
                    else { StatusChip(label: row.categoryLabel, color: BrahmaTheme.text2) }
                } else if row.isReserved {
                    WarningChip(label: "reserved")
                }
                StatusChip(label: row.riskLabel, color: row.riskLabel.hasPrefix("High") ? BrahmaTheme.danger : BrahmaTheme.text2)
                if row.documentChanged { WarningChip(label: "Changed since proposed") }
                Spacer(minLength: 0)
            }
            Text(verbatim: row.title).font(BrahmaTheme.bodyLarge.weight(.semibold)).foregroundStyle(BrahmaTheme.text0)
                .textSelection(.enabled)
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: "from " + row.requester).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                if !row.internalLine.isEmpty {
                    Text(verbatim: "·").foregroundStyle(BrahmaTheme.text2)
                    Text(verbatim: row.internalLine).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.success)
                        .lineLimit(2)
                }
                if !row.decidedLine.isEmpty {
                    Text(verbatim: "·").foregroundStyle(BrahmaTheme.text2)
                    Text(verbatim: row.decidedLine).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                }
            }
        }
    }

    // MARK: Decision brief

    @ViewBuilder private var brief: some View {
        if let details = row.details, !details.isEmpty {
            if row.kind == .engineAlert { MonoBlock(text: details, maxHeight: 140) } else { verbatim(details, color: BrahmaTheme.text1) }
        }
        if !row.options.isEmpty {
            label("Options")
            ForEach(Array(row.options.enumerated()), id: \.offset) { _, option in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.label).font(BrahmaTheme.bodyStrong).foregroundStyle(BrahmaTheme.text0)
                    if !option.pros.isEmpty { prose("+ " + option.pros, BrahmaTheme.success) }
                    if !option.cons.isEmpty { prose("− " + option.cons, BrahmaTheme.danger) }
                    if !option.effort.isEmpty || !option.risk.isEmpty {
                        prose([option.effort.isEmpty ? nil : "effort: " + option.effort, option.risk.isEmpty ? nil : "risk: " + option.risk]
                            .compactMap { $0 }.joined(separator: " · "), BrahmaTheme.text2)
                    }
                }
                .padding(.leading, BrahmaTheme.spaceS)
            }
        }
        if let recommendation = row.recommendation, !recommendation.isEmpty {
            label("Recommendation"); verbatim(recommendation, color: BrahmaTheme.text0)
        }
        if let stakes = row.stakes, !stakes.isEmpty { label("Stakes"); verbatim(stakes, color: BrahmaTheme.text1) }
        if let reversible = row.reversibleLabel {
            Text(verbatim: reversible).font(BrahmaTheme.monoSmall)
                .foregroundStyle(reversible.hasPrefix("One way") ? BrahmaTheme.warning : BrahmaTheme.text1)
        }
        if let proposal = row.proposal, !proposal.isEmpty { label("Proposal"); verbatim(proposal, color: BrahmaTheme.text1) }
    }

    // MARK: Document

    @ViewBuilder private var documentView: some View {
        if let document {
            label("Document")
            switch document {
            case .success(let text):
                ScrollView {
                    Text(text)
                        .font(BrahmaTheme.body)
                        .foregroundStyle(BrahmaTheme.text0)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BrahmaTheme.spaceM)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: false)
                .background(BrahmaTheme.bg0)
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
            case .failure(let error):
                Text(verbatim: "Document not shown: " + error.message).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.warning)
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if row.canDecide {
            TextField("Note", text: $note, prompt: Text(verbatim: "Add a note (optional)")).brahmaField()
            if showRedirect {
                TextField("New direction", text: $redirect, prompt: Text(verbatim: "What should they do instead?"), axis: .vertical)
                    .lineLimit(1...4).brahmaField()
            }
            HStack(spacing: BrahmaTheme.spaceS) {
                Button(row.approveLabel) { if row.documentChanged { confirmChanged = true } else { decide(true) } }
                    .buttonStyle(.brahmaPrimary).disabled(busy)
                Button("Reject") { decide(false) }.buttonStyle(.brahma).disabled(busy)
                Spacer()
                if showRedirect {
                    Button("Send back") {
                        run { _ = await model.replan(askId: row.id, text: redirect) }
                    }
                    .buttonStyle(.brahma).disabled(busy || redirect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Send back with a new direction…") { showRedirect = true }.buttonStyle(.brahma)
                }
            }
        }
        if row.canAnswer {
            let hasDrops = drops.map { !$0.pending.isEmpty } ?? false
            if let drops, hasDrops { PendingDropChips(model: drops) }
            TextField("Answer", text: $answer, prompt: Text(verbatim: "Your answer"), axis: .vertical).lineLimit(1...5).brahmaField()
            HStack {
                Button("Send answer") { sendAnswer() }
                    .buttonStyle(.brahmaPrimary)
                    .disabled(busy || (!hasDrops && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if drops != nil {
                    Text(verbatim: ResourceDropModel.inboxHint.uppercased())
                        .font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                }
                Spacer()
            }
        }
        if row.canAcknowledge || row.canRescind {
            HStack(spacing: BrahmaTheme.spaceS) {
                if row.canAcknowledge {
                    Button("Acknowledge") { run { _ = await model.acknowledge(askId: row.id) } }.buttonStyle(.brahmaPrimary).disabled(busy)
                }
                if row.canVouchRestore {
                    // Plan C P2 (Ruling 26): the owner vouches for the commits the restore could not place.
                    Button("Vouch for restored commits") { run { await model.vouchRestoredCommits(askId: row.id) } }
                        .buttonStyle(.brahma).disabled(busy)
                }
                if row.canVouchFile {
                    // C2b fix round 5 (Ruling 38): the owner vouches for exactly the bytes the secret gate refused for
                    // their structure.
                    // C2b-carry (b): a file whose name collides with another refused file's vouches only after the owner
                    // confirms which file it is (the files are shown side by side above).
                    Button(row.fileVouchNeedsConfirmation ? "Vouch for this file…" : "Vouch for this file") {
                        if row.fileVouchNeedsConfirmation { confirmFileVouch = true } else { run { await model.vouchFile(askId: row.id) } }
                    }
                    .buttonStyle(.brahma).disabled(busy)
                    .help("If it is a PDF, Brahma shares only a flattened re-render of its visible pages.")
                }
                if row.canRescind {
                    Button("Rescind…") { showRescind = true }.buttonStyle(.brahma)
                        .popover(isPresented: $showRescind, arrowEdge: .bottom) { rescindPopover }
                }
                Spacer()
            }
        }
    }

    private var rescindPopover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceM) {
            CapsLabel("Rescind \(row.ref)")
            Text(verbatim: "Rescinding reverses what this ask started (for a sprint plan: cancels the sprint). Continue?")
                .font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).fixedSize(horizontal: false, vertical: true)
            TextField("Why", text: $rescindNote, prompt: Text(verbatim: "Note (required)")).brahmaField()
            HStack {
                Spacer()
                Button("Cancel") { showRescind = false }.buttonStyle(.brahma)
                Button("Rescind") {
                    showRescind = false
                    run { _ = await model.rescind(askId: row.id, note: rescindNote) }
                }
                .buttonStyle(.brahmaPrimary)
                .disabled(rescindNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 320)
        .background(BrahmaTheme.bg1)
    }

    /// With dropped files, the answer is the owner's words above the engine's file lines (`ResourceDropModel.commit`);
    /// otherwise it is the words alone.
    private func sendAnswer() {
        let text = answer
        if let drops, !drops.pending.isEmpty {
            run { if await drops.commit(message: text) { answer = "" } }
        } else {
            run { _ = await model.answer(askId: row.id, text: text) }
        }
    }

    private func decide(_ approve: Bool, acknowledgeChange: Bool = false) {
        run { _ = await model.decide(askId: row.id, approve: approve, note: note, acknowledgeChange: acknowledgeChange) }
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }

    // MARK: Text helpers (agent text is never interpreted)

    private func label(_ s: String) -> some View { CapsLabel(s).padding(.top, 2) }

    private func verbatim(_ s: String, color: Color) -> some View {
        Text(verbatim: s).font(BrahmaTheme.body).foregroundStyle(color).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prose(_ s: String, _ color: Color) -> some View {
        Text(verbatim: s).font(BrahmaTheme.body).foregroundStyle(color)
    }
}
