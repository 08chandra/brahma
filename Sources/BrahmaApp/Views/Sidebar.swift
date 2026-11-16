import SwiftUI
import BrahmaAppModel

/// `bg1` sidebar: tiny uppercase section headers, 24 pt rows, `#`/`@` glyphs in `text2`,
/// selection `bg4` with a 2 pt accent bar, unread counts as mono chips.
struct Sidebar: View {
    let model: AppModel
    @State private var conversationsExpanded = false
    @State private var newDMShown = false

    var body: some View {
        let sections = model.sidebar
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NavRow(title: "Mission Control", icon: "square.grid.2x2", item: .missionControl, model: model)
                NavRow(title: "Activity", icon: "list.bullet.rectangle", item: .activity, model: model)
                NavRow(title: "Agents", icon: "person.3", item: .agents, model: model)
                SectionHeader(title: "Work")
                NavRow(title: "Backlog", icon: "list.bullet.indent", item: .backlog, model: model)
                NavRow(title: "Board", icon: "rectangle.split.3x1", item: .board, model: model)
                NavRow(title: "Releases", icon: "shippingbox", item: .releases, model: model, count: model.openReleaseCount)
                NavRow(title: "Resources", icon: "paperclip", item: .resources, model: model)
                NavRow(title: "Inbox", icon: "tray", item: .inbox, model: model, count: model.inboxCount)
                NavRow(title: "Grants", icon: "key", item: .inboxGrants, model: model, indent: true)
                NavRow(title: "Digest", icon: "doc.text", item: .inboxDigest, model: model, indent: true)

                SectionHeader(title: "Settings")
                NavRow(title: "Company", icon: "slider.horizontal.3", item: .companySettings, model: model)
                NavRow(title: "Backups", icon: "externaldrive", item: .settingsBackups, model: model)

                if !sections.channels.isEmpty {
                    SectionHeader(title: "Channels")
                    ForEach(sections.channels) { row in
                        SidebarRowView(row: row, showCount: false, model: model)
                    }
                }
                SectionHeader(title: "Direct messages") {
                    Button { newDMShown = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(BrahmaTheme.text1)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New direct message")
                    .accessibilityLabel(Text("New direct message"))
                    .popover(isPresented: $newDMShown) { NewDMPicker(model: model, isPresented: $newDMShown) }
                }
                ForEach(sections.directMessages) { row in
                    SidebarRowView(row: row, showCount: true, model: model)
                }
                if !sections.agentConversations.isEmpty {
                    SectionHeader(title: "Agent conversations") {
                        Image(systemName: conversationsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(BrahmaTheme.text2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(BrahmaTheme.medium) { conversationsExpanded.toggle() } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(Text(conversationsExpanded ? "Expanded" : "Collapsed"))
                    if conversationsExpanded {
                        ForEach(sections.agentConversations) { row in
                            SidebarRowView(row: row, showCount: false, model: model)
                        }
                    }
                }
            }
            .padding(.vertical, BrahmaTheme.spaceS)
        }
        .scrollIndicators(.automatic)
        .background(BrahmaTheme.bg1)
    }
}

private struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 4) {
            CapsLabel(title)
            Spacer(minLength: 4)
            accessory
        }
        .padding(.leading, BrahmaTheme.spaceM)
        .padding(.trailing, BrahmaTheme.spaceS)
        .padding(.top, BrahmaTheme.spaceL)
        .padding(.bottom, BrahmaTheme.spaceXS)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// Selectable 24 pt sidebar row shell.
private struct RowShell<Content: View>: View {
    let item: SidebarItem
    let model: AppModel
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        let selected = model.sidebarSelection == item
        Button { model.select(item) } label: {
            HStack(spacing: 6) { content }
                .padding(.leading, BrahmaTheme.spaceM)
                .padding(.trailing, BrahmaTheme.spaceS)
                .frame(maxWidth: .infinity, minHeight: BrahmaTheme.rowHeight, maxHeight: BrahmaTheme.rowHeight, alignment: .leading)
                .background(selected ? BrahmaTheme.bg4 : (hovered ? BrahmaTheme.bg3 : Color.clear))
                .overlay(alignment: .leading) {
                    if selected { Rectangle().fill(BrahmaTheme.accent).frame(width: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(BrahmaTheme.fast) { hovered = inside } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NavRow: View {
    let title: String
    let icon: String
    let item: SidebarItem
    let model: AppModel
    /// An accent count chip (the Inbox); hidden at 0.
    var count = 0
    /// A sub-row (Inbox › Grants, Inbox › Digest).
    var indent = false

    var body: some View {
        let selected = model.sidebarSelection == item
        RowShell(item: item, model: model) {
            if indent { Spacer().frame(width: BrahmaTheme.spaceM) }
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(selected ? BrahmaTheme.accent : BrahmaTheme.text2)
                .frame(width: 18)
            Text(verbatim: title)
                .font(BrahmaTheme.body)
                .foregroundStyle(selected ? BrahmaTheme.text0 : BrahmaTheme.text1)
            Spacer(minLength: 4)
            if count > 0 { MonoChip(text: count > 99 ? "99+" : "\(count)", color: .white, fill: BrahmaTheme.accent) }
        }
        .accessibilityLabel(Text(verbatim: count > 0 ? "\(title), \(count) waiting" : title))
    }
}

private struct SidebarRowView: View {
    let row: SidebarRow
    let showCount: Bool
    let model: AppModel

    var body: some View {
        let selected = model.sidebarSelection == row.item
        let unread = row.unread > 0
        let (glyph, name) = Self.split(row.title)
        RowShell(item: row.item, model: model) {
            Text(verbatim: glyph)
                .font(BrahmaTheme.mono)
                .foregroundStyle(BrahmaTheme.text2)
                .frame(width: 18)
            Text(verbatim: name)
                .font(unread ? BrahmaTheme.bodyStrong : BrahmaTheme.body)
                .foregroundStyle(selected || unread ? BrahmaTheme.text0 : BrahmaTheme.text1)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showCount && unread {
                MonoChip(text: row.unread > 99 ? "99+" : "\(row.unread)", color: .white, fill: BrahmaTheme.accent)
            }
        }
        .accessibilityLabel(Text(verbatim: row.title))
    }

    /// `#general` → (`#`, `general`); `@cto` → (`@`, `cto`). Display only.
    static func split(_ title: String) -> (String, String) {
        guard let first = title.first, first == "#" || first == "@" else { return ("", title) }
        return (String(first), String(title.dropFirst()))
    }
}
