import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The search-and-ask bar atop the preview (collab design §2.1): a full-width 28 pt field above the tab strip, removable filter
/// chips under it, the dropdown (the ANSWER card, grouped zebra rows with mono refs, the ASK row last in `accent`), and the
/// OPENED strip (Back/Forward, the OPENED chip with its background-answer badge, the waiting chips). Keys follow `ShowKey`.
///
/// It takes focus only on a click (⌘K opens the palette instead); auto-opened answers never call `makeFirstResponder`.
/// Everything shown is the model's: hits gated by the resolver, the ASK row's engine text, the chips of the owner's own query.
struct ShowBar: View {
    let model: AppModel

    private var bar: ShowBarModel { model.showBar }

    var body: some View {
        VStack(spacing: 0) {
            ShowQueryField(model: model, presentation: .bar)
                .padding(.horizontal, BrahmaTheme.spaceS)
                .padding(.vertical, BrahmaTheme.spaceXS)
            if bar.presentation == .bar, !bar.filterChips.isEmpty {
                ShowFilterChips(model: model).padding(.horizontal, BrahmaTheme.spaceS).padding(.bottom, BrahmaTheme.spaceXS)
            }
            if bar.isOpen, bar.presentation == .bar, ShowResultsList.hasResults(bar) {
                Hairline()
                ShowResultsList(model: model).frame(maxHeight: 300)
            }
            OpenedStrip(model: model)
        }
        .background(BrahmaTheme.bg2)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// The query field of the bar and the palette, with the keys (↑ ↓ ↩ ⌘↩ ⌥↩ ⎋ ⇥).
struct ShowQueryField: View {
    let model: AppModel
    let presentation: ShowPresentation
    /// The palette takes focus as it opens (⌘K); the bar never takes it by itself.
    var takesFocus = false
    @State private var text = ""
    @FocusState private var focused: Bool

    static let placeholder = "Search or ask…  ENG-142 · blocked · by @cto · this week · or a question"

    private var bar: ShowBarModel { model.showBar }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(BrahmaTheme.text2)
            if bar.isOpen, bar.presentation == presentation, bar.kind == .explain, let ref = bar.attachedRef {
                MonoChip(text: "EXPLAIN · " + OpenedRef.kindChip(for: ref), color: BrahmaTheme.accent, fill: BrahmaTheme.accent.opacity(0.15))
            }
            TextField(text: $text, prompt: Text(verbatim: Self.placeholder).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text2)) {
                Text("Search or ask")
            }
            .textFieldStyle(.plain)
            .font(BrahmaTheme.monoSmall)
            .foregroundStyle(BrahmaTheme.text0)
            .focused($focused)
            .onKeyPress(.upArrow) { act(.up) }
            .onKeyPress(.downArrow) { act(.down) }
            .onKeyPress(.tab) { act(.tab) }
            .onKeyPress(.escape) { act(.escape) }
            .onKeyPress(keys: [.return], phases: .down) { press in
                act(press.modifiers.contains(.command) ? .cmdEnter : press.modifiers.contains(.option) ? .optEnter : .enter)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    Task { await bar.update(query: "") }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(BrahmaTheme.text2)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg1))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(focused ? BrahmaTheme.accent : BrahmaTheme.lineStrong, lineWidth: 1))
        .onAppear {
            text = bar.query
            if takesFocus { focused = true }
        }
        .onChange(of: text) { _, new in
            guard new != bar.query else { return }
            if !bar.isOpen || bar.presentation != presentation { model.openShow(presentation: presentation, kind: bar.kind, attachedRef: bar.attachedRef) }
            Task { await bar.update(query: new) }
        }
        .onChange(of: bar.query) { _, new in if new != text { text = new } }
        .onChange(of: focused) { _, isFocused in
            // A click into the bar opens its dropdown (never the palette's).
            if isFocused, !bar.isOpen { model.openShow(presentation: presentation) }
        }
    }

    private func act(_ key: ShowKey) -> KeyPress.Result {
        guard bar.isOpen, bar.presentation == presentation else {
            if key == .escape { focused = false; return .handled }
            return .ignored
        }
        let action = bar.handle(key)
        if action == .close { focused = false }
        if case .open = action { focused = false }
        Task { await model.perform(action) }
        return .handled
    }
}

/// The removable filter chips the resolver read from the query (`BLOCKED`, `BY @ENG-3`, `THIS WEEK`).
struct ShowFilterChips: View {
    let model: AppModel

    var body: some View {
        FlowLayout(spacing: BrahmaTheme.spaceXS) {
            ForEach(model.showBar.filterChips, id: \.self) { chip in
                HStack(spacing: 4) {
                    Text(verbatim: chip).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text0)
                    Button { Task { await model.showBar.removeFilterChip(chip) } } label: {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(BrahmaTheme.text2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "Remove " + chip))
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 18)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg4))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
            }
        }
    }
}

/// The dropdown rows (both presentations): group headers as uppercase labels, the ANSWER card, zebra hit rows with mono refs,
/// "See all", and the ASK row (always last) in `accent`. A click selects and opens the row as Enter does.
struct ShowResultsList: View {
    let model: AppModel

    private var bar: ShowBarModel { model.showBar }

    static func hasResults(_ bar: ShowBarModel) -> Bool {
        !bar.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bar.error != nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = bar.error {
                        Text(verbatim: error)
                            .font(BrahmaTheme.monoSmall)
                            .foregroundStyle(BrahmaTheme.danger)
                            .padding(BrahmaTheme.spaceS)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(bar.rows.enumerated()), id: \.offset) { i, row in
                        rowView(row, index: i).id(i)
                    }
                }
            }
            .onChange(of: bar.selection) { _, s in proxy.scrollTo(s) }
        }
        .background(BrahmaTheme.bg2)
    }

    @ViewBuilder private func rowView(_ row: ShowRow, index i: Int) -> some View {
        let selected = i == bar.selection
        switch row {
        case .header(let title):
            CapsLabel(title)
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .background(BrahmaTheme.bg3)
        case .answer(let answer):
            FactCardView(answer: answer, timeZone: model.ownerTimeZone, compact: true) { ref in
                bar.close()
                RefActions.openInPreview(model: model, ref: ref)
            }
            .padding(BrahmaTheme.spaceXS)
            .background(selected ? BrahmaTheme.bg4 : Color.clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) } }
            .contentShape(Rectangle())
            .onTapGesture { choose(i) }
        case .hit(let hit):
            Button { choose(i) } label: { hitRow(hit) }
                .buttonStyle(.plain)
                .tableRow(index: i, selected: selected, height: BrahmaTheme.denseRowHeight)
                .opacity(hit.inlineOnly ? 0.6 : 1)
                .help(Text(verbatim: hit.snippet ?? hit.subtitle))
        case .seeAll(let n):
            Button { choose(i) } label: {
                Text(verbatim: "See all \(n) message results").font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.text1)
            }
            .buttonStyle(.plain)
            .tableRow(index: i, selected: selected, height: BrahmaTheme.denseRowHeight)
        case .ask(let text):
            Button { choose(i) } label: {
                HStack(spacing: BrahmaTheme.spaceS) {
                    Image(systemName: "arrow.turn.down.left").font(.system(size: 9, weight: .bold))
                    Text(verbatim: text).font(BrahmaTheme.monoSmall.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: BrahmaTheme.spaceS)
                    Text(verbatim: "⇥ WHO · ⌘↩ ASK").font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2)
                }
                .foregroundStyle(BrahmaTheme.accent)
                .padding(.horizontal, BrahmaTheme.spaceS)
                .frame(maxWidth: .infinity, minHeight: BrahmaTheme.rowHeight, alignment: .leading)
                .background(BrahmaTheme.accent.opacity(selected ? 0.22 : 0.1))
                .overlay(alignment: .leading) { if selected { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func hitRow(_ hit: ShowHit) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            Text(verbatim: OpenedRef.kindChip(for: hit.ref))
                .font(BrahmaTheme.monoTiny)
                .foregroundStyle(BrahmaTheme.text2)
                .frame(width: 62, alignment: .leading)
            Text(verbatim: RefStyle.shownCanonical(hit.ref))
                .font(BrahmaTheme.monoSmall)
                .foregroundStyle(BrahmaTheme.text1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            Text(verbatim: hit.title).font(BrahmaTheme.body).foregroundStyle(BrahmaTheme.text0).lineLimit(1)
            if !hit.subtitle.isEmpty {
                Text(verbatim: hit.subtitle).font(BrahmaTheme.monoTiny).foregroundStyle(BrahmaTheme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func choose(_ i: Int) {
        bar.selection = i
        let action = bar.handle(.enter)
        Task { await model.perform(action) }
    }
}

/// Back / Forward (⌘[ ⌘]), the OPENED chip (`accent`; a badge counts answers opened in the background), and the owner's
/// waiting chips with their cancel "×".
struct OpenedStrip: View {
    let model: AppModel

    var body: some View {
        let nav = model.previewNav
        if nav.opened != nil || !nav.back.isEmpty || !model.waitingChips.isEmpty {
            HStack(spacing: BrahmaTheme.spaceXS) {
                navButton("chevron.left", "Back (⌘[)", enabled: !nav.back.isEmpty) { Task { await model.goBack() } }
                navButton("chevron.right", "Forward (⌘])", enabled: !nav.forward.isEmpty) { Task { await model.goForward() } }
                if let opened = nav.opened {
                    Button {
                        model.selectPreviewTab(PreviewTabID.ref)
                        model.sawOpened()
                    } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: "OPENED · " + opened.kindChip).font(BrahmaTheme.label).tracking(BrahmaTheme.labelTracking)
                            Text(verbatim: opened.title).font(BrahmaTheme.monoTiny).lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundStyle(BrahmaTheme.accent)
                        .padding(.horizontal, 6)
                        .frame(height: BrahmaTheme.chipHeight)
                        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.accent.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.accent, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 260, alignment: .leading)
                    .help("Show the opened ref")
                    if model.autoOpenBadge > 0 {
                        MonoChip(text: "\(model.autoOpenBadge) NEW", color: .white, fill: BrahmaTheme.accent)
                            .help("Answers opened in the background")
                    }
                }
                ForEach(model.waitingChips) { chip in
                    WaitingChipView(chip: chip) { Task { await model.cancelShowRequest(chip.requestId) } }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .padding(.bottom, BrahmaTheme.spaceXS)
        }
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? BrahmaTheme.text0 : BrahmaTheme.text2)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg3))
                .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}
