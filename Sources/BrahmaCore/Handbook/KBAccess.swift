import Foundation

/// Who may read which part of a handbook page. A page is a company doc; its page restriction and every section's markers
/// cap it through the one access engine (`MemoryAccess.level`), with no second predicate: `kbRead`, search docs, backlinks,
/// the mirror and Collab all ask here.
public enum KBAccess {
    /// The sections of `page`'s current body that `reader` may read, in order (none when the page itself is unreadable).
    public static func visibleSections(page: KBPage, reader: Reader, store: Store) throws -> [KBSection] {
        let ctx = try ReaderContext.load(store: store, companyId: page.companyId, reader: reader)
        return KBMarkdown.sections(page.body, page: page.pageRestriction).filter { canRead($0, ctx: ctx) }
    }

    public static func canRead(_ section: KBSection, ctx: ReaderContext) -> Bool {
        canRead(restrictions: section.restrictions, ctx: ctx)
    }

    /// Whether the page as a whole is readable: its page restriction only.
    public static func canReadPage(_ page: KBPage, ctx: ReaderContext) -> Bool {
        canRead(restrictions: page.pageRestriction.map { [$0] } ?? [], ctx: ctx)
    }

    static func canRead(restrictions: [Restriction], ctx: ReaderContext) -> Bool {
        MemoryAccess.level(ctx, access: .company, sensitivity: .normal, readerSet: nil, restrictions: restrictions,
                           futureHolders: false) == .full
    }
}
