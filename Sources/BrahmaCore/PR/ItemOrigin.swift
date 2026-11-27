import Foundation

/// Where an imported work item came from: the `workItem.origin*` columns (`"vX5-pr"`). `(companyId, url)` is unique: one
/// issue imports once per company.
public struct ItemOrigin: Equatable, Sendable {
    /// The issue's URL (`html_url` on GitHub, `url` on Linear).
    public var url: String
    /// The author's login (GitHub) or email (Linear) as the provider reported it.
    public var author: String?
    /// Whether the author was a trusted login when the snapshot was taken; false after an edit.
    public var trusted: Bool
    /// The issue number (GitHub) or identifier (Linear).
    public var id: String?

    public init(url: String, author: String?, trusted: Bool, id: String?) {
        self.url = url
        self.author = author
        self.trusted = trusted
        self.id = id
    }
}

extension WorkItem {
    /// The item's origin, nil for one created inside Brahma.
    public var origin: ItemOrigin? {
        guard let originURL else { return nil }
        return ItemOrigin(url: originURL, author: originAuthor, trusted: originTrusted, id: originId)
    }
}
