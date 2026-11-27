import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// An engine-composed fact answer (`what's blocked`, `sprint:3`; collab design §2.3): a small panel whose title strip is the
/// answer's title (the engine's gated text, drawn as it is) with `as of HH:mm` in mono `text2`, one row per line with chips for
/// its refs (a click opens the ref), and the engine's empty text as a mono empty state. Line text is the resolver's gated final
/// string; a ref chip shows the ref's kind only (its canonical is not a gated display string here), and opens the ref.
struct FactCardView: View {
    let answer: FactAnswer
    var timeZone: TimeZone = .current
    var compact = false
    var open: ((WorkRef) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BrahmaTheme.spaceS) {
                Text(verbatim: answer.title)
                    .font(BrahmaTheme.panelTitle)
                    .tracking(BrahmaTheme.labelTracking)
                    .foregroundStyle(BrahmaTheme.text1)
                    .lineLimit(1)
                Spacer(minLength: BrahmaTheme.spaceS)
                Text(verbatim: "as of " + TimeText.hm(answer.asOf, timeZone: timeZone))
                    .font(BrahmaTheme.monoTiny)
                    .foregroundStyle(BrahmaTheme.text2)
            }
            .padding(.horizontal, BrahmaTheme.panelPadding)
            .frame(height: compact ? BrahmaTheme.denseRowHeight : BrahmaTheme.panelHeaderHeight)
            .background(BrahmaTheme.bg3)
            .overlay(alignment: .bottom) { Hairline() }
            if answer.lines.isEmpty {
                Text(verbatim: answer.emptyText ?? "Nothing to show.")
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.text2)
                    .padding(BrahmaTheme.spaceS)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(answer.lines.enumerated()), id: \.offset) { i, line in
                    HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
                        Text(verbatim: line.text)
                            .font(BrahmaTheme.body)
                            .foregroundStyle(BrahmaTheme.text0)
                            .lineLimit(compact ? 1 : 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(line.refs.enumerated()), id: \.offset) { _, ref in
                            RefLinkChip(label: OpenedRef.kindChip(for: ref)) { open?(ref) }
                        }
                    }
                    .tableRow(index: i, height: compact ? BrahmaTheme.denseRowHeight : BrahmaTheme.rowHeight)
                }
            }
        }
        .background(BrahmaTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: BrahmaTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.line, lineWidth: 1))
    }
}

/// A small mono chip that opens a ref (an engine label: a kind, `[2] FILE`). Never a link.
struct RefLinkChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(verbatim: label)
                Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold))
            }
            .font(BrahmaTheme.monoTiny)
            .foregroundStyle(BrahmaTheme.accent)
            .padding(.horizontal, 5)
            .frame(minHeight: 16)
            .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.accentDim, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: "Open " + label))
    }
}

/// A `show` answer's note split into claims (collab design §2.4), each followed by the chips of the refs it cites; when the
/// citations don't hold, an `UNVERIFIED` chip and `These sentences cite no source:` with the uncited sentences. The note is
/// agent-written and gated by the model (withheld whole when it held a value): `Text(verbatim:)` with markers.
struct AnswerClaimsView: View {
    let claims: [Claim]
    let refs: [WorkRef]
    /// The agent's per-ref notes, gated by the model (impersonation flagged, a value withholds the note).
    var refNotes: [String?] = []
    let verified: Bool
    /// `Concierge` or `@handle`.
    let by: String
    var open: ((WorkRef) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            HStack(spacing: BrahmaTheme.spaceS) {
                CapsLabel("Answer")
                Text(verbatim: "from " + by).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
                if !verified { WarningChip(label: "Unverified") }
                Spacer(minLength: 0)
            }
            ForEach(Array(cited.enumerated()), id: \.offset) { _, claim in
                VStack(alignment: .leading, spacing: 3) {
                    RefStyle.marked(claim.text).font(BrahmaTheme.bodyLarge).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !claim.cites.isEmpty {
                        HStack(spacing: BrahmaTheme.spaceXS) {
                            ForEach(Array(claim.cites.enumerated()), id: \.offset) { _, n in
                                if refs.indices.contains(n - 1) {
                                    RefLinkChip(label: "[\(n)] " + OpenedRef.kindChip(for: refs[n - 1])) { open?(refs[n - 1]) }
                                }
                            }
                        }
                    }
                }
            }
            if !verified, !uncited.isEmpty {
                Text(verbatim: "These sentences cite no source:")
                    .font(BrahmaTheme.monoSmall)
                    .foregroundStyle(BrahmaTheme.warning)
                ForEach(Array(uncited.enumerated()), id: \.offset) { _, claim in
                    RefStyle.marked(claim.text, color: BrahmaTheme.text1).font(BrahmaTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, BrahmaTheme.spaceS)
                        .overlay(alignment: .leading) { Rectangle().fill(BrahmaTheme.warning).frame(width: 2) }
                }
            }
            if !refs.isEmpty {
                Hairline()
                CapsLabel("Sources")
                ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                    HStack(alignment: .firstTextBaseline, spacing: BrahmaTheme.spaceS) {
                        RefLinkChip(label: "[\(i + 1)] " + OpenedRef.kindChip(for: ref)) { open?(ref) }
                        if refNotes.indices.contains(i), let note = refNotes[i] {
                            RefStyle.marked(note, color: BrahmaTheme.text1).font(BrahmaTheme.body).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// Claims with a valid citation (or every claim when the answer verified).
    private var cited: [Claim] { verified ? claims : claims.filter { !$0.cites.isEmpty } }
    private var uncited: [Claim] { claims.filter { $0.cites.isEmpty } }
}
