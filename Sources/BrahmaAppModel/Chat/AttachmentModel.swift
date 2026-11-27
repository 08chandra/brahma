import Foundation
import BrahmaCore

/// What a chat card previews (collab design §3.5): six highlighted lines, a diff stat, a thumbnail or poster (the view makes
/// them out of process), an item's key and holder, a run's exit, an agent's state, or nothing.
public enum CardPreview: Equatable, Sendable {
    case code([[CodeSpan]])
    case diffStat(added: Int, removed: Int, files: Int)
    case thumbnail(URL)
    case poster(URL)
    case item(key: String, status: String, holder: String?)
    case run(exit: Int?, duration: String, lastFailing: String?)
    case agent(state: String)
    case none
}

/// A rich card for a ref in chat: a kind chip, the engine title, mono meta, a preview and chips. A locked ref is a kind chip
/// alone (`title` empty, `meta` "locked · ask the owner"; design §4.2: locked chips carry no title). Owner chips show engine
/// titles; ids appear only in Copy ref and the tooltip.
public struct AttachmentCard: Equatable, Sendable {
    public var kindChip: String
    public var title: String
    public var meta: String
    public var preview: CardPreview
    public var chips: [RefChip]
    public var locked: Bool
    /// C7a: the ref the card opens (in chat's inspector) and its context menu acts on, without agent-written parameters
    /// (`OpenedRef.stripped`); nil for a locked card, which opens nothing.
    public var ref: WorkRef?

    public init(kindChip: String, title: String, meta: String, preview: CardPreview, chips: [RefChip], locked: Bool, ref: WorkRef? = nil) {
        self.kindChip = kindChip; self.title = title; self.meta = meta; self.preview = preview; self.chips = chips; self.locked = locked
        self.ref = ref
    }
}

public enum AttachmentCards {
    /// A file card shows at most this many highlighted lines (Global Constraints "Cards").
    public static let previewLines = 6
    public static let lockedMeta = "locked · ask the owner"

    /// The card for `r`. Synchronous: callers run it off the main actor. A card's file preview reads the bytes through
    /// `Store.renderRef` without recording a read (`via: nil`); every string is gated as its final display string.
    public static func make(_ r: ResolvedRef, store: Store, context ctx: RefRenderContext) throws -> AttachmentCard {
        let kindChip = OpenedRef.kindChip(for: r.ref)
        guard r.visibility == .full, r.state != .purged else {
            let meta = r.state == .purged && r.visibility == .full ? "purged" : lockedMeta
            return AttachmentCard(kindChip: kindChip, title: "", meta: meta, preview: .none, chips: [], locked: true)
        }
        let gate = GlobalSearch.TextGate(knownValues: ctx.knownValues)
        let title = RefBodies.askTitle(for: r.ref, store: store, companyId: ctx.companyId, knownValues: ctx.knownValues)
            ?? gate.final(r.title, max: SafeTitle.max).flatMap { $0.isEmpty ? nil : $0 } ?? gate.final(r.ref.canonical, max: SafeTitle.max) ?? kindChip
        let meta = gate.final(r.subtitle, max: SafeTitle.max) ?? ""
        var chips: [RefChip] = []
        func chip(_ text: String, _ tone: PreviewTone) {
            if let shown = gate.final(text, max: SafeTitle.max), !shown.isEmpty { chips.append(RefChip(text: shown, tone: tone)) }
        }
        if r.tainted { chip("TAINTED · \(r.taintReason ?? "outside content")", .warn) }
        if (r.ref.kind == .file || r.ref.kind == .diff), r.ref.isWorktree { chip("UNCOMMITTED", .warn) }
        if r.state == .redacted { chip("REDACTED", .warn) }
        var preview: CardPreview = .none
        switch r.ref.kind {
        case .file, .resource:
            preview = (try? filePreview(r, store: store, ctx: ctx)) ?? .none
        case .diff, .commit:
            if let render = try? store.renderRef(companyId: ctx.companyId, ref: r.ref, knownValues: ctx.knownValues, paths: ctx.paths,
                                                  archives: ctx.archives, via: nil, now: ctx.now, owner: ctx.owner), let text = render.text {
                // C7a fix round 1 (I-1): counts only from a parse the engine's reading of the same text agrees with.
                if let m = RefBodies.verifiedDiff(patch: RefBodies.redacted(text, knownValues: ctx.knownValues),
                                                  gate: GlobalSearch.TextGate(knownValues: ctx.knownValues)) {
                    preview = .diffStat(added: m.added, removed: m.removed, files: m.files.count)
                }
            }
        case .item:
            let parts = r.subtitle.split(separator: " · ").map(String.init)
            let status = gate.final(parts.first ?? "", max: 40) ?? ""
            let holder = parts.dropFirst().first.flatMap { gate.final($0, max: 80) }
            preview = .item(key: r.ref.id, status: status, holder: holder)
        case .run:
            let parts = r.subtitle.split(separator: " · ").map(String.init)
            let exit = parts.first { $0.hasPrefix("exit ") }.flatMap { Int($0.dropFirst(5)) }
            preview = .run(exit: exit, duration: "", lastFailing: nil)
        case .agent:
            preview = .agent(state: gate.final(r.subtitle.split(separator: " · ").last.map(String.init) ?? "", max: 40) ?? "")
        default:
            break
        }
        return AttachmentCard(kindChip: kindChip, title: title, meta: meta, preview: preview, chips: chips, locked: false, ref: OpenedRef.stripped(r.ref))
    }

    /// The first `previewLines` highlighted lines of a text file (from the ref's range when it has one); a thumbnail for an
    /// image; nothing for other binaries.
    static func filePreview(_ r: ResolvedRef, store: Store, ctx: RefRenderContext) throws -> CardPreview {
        let render = try store.renderRef(companyId: ctx.companyId, ref: r.ref, knownValues: ctx.knownValues, paths: ctx.paths,
                                         archives: ctx.archives, via: nil, now: ctx.now, owner: ctx.owner)
        let ext = render.ext.lowercased()
        let kind = ArtifactKind.from(ext: ext)
        let binary = render.data.prefix(OpenRefLimits.binarySniffBytes).contains(0)
        if !binary, kind == nil || kind == .code || kind == .text {
            let text = RefBodies.redacted(String(decoding: render.data.prefix(RefBodies.maxTextBytes), as: UTF8.self), knownValues: ctx.knownValues)
            var lines = CodeHighlighter.splitLines(RefBodies.cutLines(text))
            if lines.last == "" { lines.removeLast() }
            let start = max(0, (r.ref.range?.start ?? 1) - 1)
            let window = Array(lines.dropFirst(min(start, lines.count)).prefix(previewLines))
            let language = CodeLanguage.detect(path: r.ref.kind == .file ? r.ref.id : "x.\(ext)")
            return .code(CodeHighlighter.highlight(window.joined(separator: "\n"), language: language))
        }
        if kind == .image {
            let dir = ctx.tempRoot.appending(path: "card-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = dir.appending(path: RefBodies.fileName(for: r.ref, ext: ext))
            try render.data.write(to: url, options: [.withoutOverwriting])
            return .thumbnail(url)
        }
        if kind == .video { return .none }
        return .none
    }
}
