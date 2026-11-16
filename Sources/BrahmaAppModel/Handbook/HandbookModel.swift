import Foundation
import Observation
import BrahmaCore

public enum HandbookTab: String, CaseIterable, Sendable {
    case pages, memory
}

/// The owner's Handbook (Plan ML): the page tree, a page as the owner reads it (every section, restricted ones marked), its
/// revisions, backlinks and recent changes, an owner-scope search over the handbook, and the owner-only decisions edit,
/// rollback, vouch, status and export. These call the Store directly (never `CompanyTools`). Nothing here persists what it
/// reads: search hits live in memory only, generation-counted (R-243).
@MainActor @Observable
public final class HandbookModel {
    public nonisolated static let exportNeedsEmptyFolder = "Choose an empty folder: the handbook is exported only into an empty folder."

    public let companyId: String
    public var tab: HandbookTab = .pages
    public private(set) var snapshot: HandbookSnapshot = .empty
    /// The selected page's path (as stored).
    public private(set) var selection: String?
    /// The revision shown; nil is the current one.
    public private(set) var revision: Int?
    /// The selected page as the owner reads it, at `revision`.
    public private(set) var view: KBView?
    /// The selected page's revisions, oldest first.
    public private(set) var revisions: [KBRevision] = []
    /// The handbook search (owner scope, kb docs only).
    public var query = ""
    public private(set) var searchHits: [MemoryHit] = []
    public private(set) var isSearching = false
    public private(set) var isWorking = false
    /// The last refusal or failure, verbatim (an edit conflict's text is the Store's).
    public var error: String?
    /// The MEMORY tab.
    public let memory: MemoryBrowserModel
    /// Runs after an owner decision (the app refreshes its snapshot).
    @ObservationIgnored public var afterChange: (@MainActor () async -> Void)?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let paths: BrahmaPaths
    @ObservationIgnored private let secretVault: any SecretVault
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var pageGeneration = 0
    @ObservationIgnored private var listGeneration = 0

    public init(store: Store, companyId: String, paths: BrahmaPaths, secretVault: any SecretVault) {
        self.store = store
        self.companyId = companyId
        self.paths = paths
        self.secretVault = secretVault
        self.memory = MemoryBrowserModel(store: store, companyId: companyId)
    }

    public var pages: [KBPageSummary] { snapshot.pages }
    public var tree: [HandbookNode] { snapshot.tree }
    /// RECENTLY CHANGED (20).
    public var recent: [KBPageSummary] { snapshot.recent }

    // MARK: Presentation

    /// `kb:<path> · REV <n> · @<owner> · UPDATED <yyyy-MM-dd HH:mm>`, or empty with no page.
    public var headerLine: String {
        view.map { HandbookPresentation.header($0, handles: snapshot.handles, timeZone: snapshot.timeZone) } ?? ""
    }

    public var blocks: [KBBlock] { view.map { HandbookPresentation.blocks($0.text) } ?? [] }

    /// The page-level restriction's chip, if any.
    public var pageRestrictedChip: String? {
        view?.page.pageRestriction.flatMap { HandbookPresentation.restrictedChip([$0]) }
    }

    public func revisionLabel(_ r: KBRevision) -> String {
        HandbookPresentation.revisionLabel(r, handles: snapshot.handles, timeZone: snapshot.timeZone)
    }

    public func recentLine(_ p: KBPageSummary) -> String { HandbookPresentation.recentLine(p, timeZone: snapshot.timeZone) }

    /// Edit: an owner page (never an engine-generated one), at its current revision.
    public var canEdit: Bool { view.map { $0.page.autoKind == nil } ?? false && revision == nil && !isWorking }
    /// `Roll back to this revision`: an older revision of an owner page is shown.
    public var canRollback: Bool { view.map { $0.page.autoKind == nil } ?? false && revision != nil && !isWorking }
    /// `I vouch for this page`: the page is tainted now.
    public var canVouch: Bool { view?.page.tainted == true && !isWorking }

    // MARK: Loading

    /// Reloads the lists and the selected page.
    public func reload() async {
        await refreshLists()
        if selection != nil { await loadPage() }
    }

    /// The poll's refresh while the Handbook is shown: the lists, and the selected page when it changed underneath.
    public func refresh() async {
        let before = selectedSummary
        await refreshLists()
        if let after = selectedSummary, after != before { await loadPage() }
        if tab == .memory { await memory.reload() }
    }

    private var selectedSummary: KBPageSummary? {
        guard let selection else { return nil }
        return snapshot.pages.first { $0.path.lowercased() == selection.lowercased() }
    }

    private func refreshLists() async {
        listGeneration += 1
        let gen = listGeneration
        let (store, companyId) = (self.store, self.companyId)
        do {
            let snap = try await Task.detached { try HandbookSnapshot.load(store: store, companyId: companyId) }.value
            guard gen == listGeneration else { return }
            if snap != snapshot { snapshot = snap }
        } catch {
            guard gen == listGeneration else { return }
            self.error = "Couldn't read the handbook: \(error)"
        }
    }

    /// Shows `path` (a `kb:` prefix and a `#section` are dropped) at its current revision; nil clears the selection.
    public func select(_ path: String?) async {
        guard let path else {
            pageGeneration += 1
            selection = nil; revision = nil; view = nil; revisions = []
            return
        }
        selection = HandbookPresentation.path(ofRef: path)
        revision = nil
        await loadPage()
    }

    /// Shows revision `number` of the selected page (nil or the current number: the current revision).
    public func show(revision number: Int?) async {
        guard selection != nil else { return }
        revision = number == view?.page.revision ? nil : number
        await loadPage()
    }

    private func loadPage() async {
        guard let selection else { return }
        pageGeneration += 1
        let gen = pageGeneration
        let (store, companyId, revision) = (self.store, self.companyId, self.revision)
        do {
            let (view, revisions) = try await Task.detached { () -> (KBView?, [KBRevision]) in
                guard let view = try store.kbRead(companyId: companyId, reader: .owner, path: selection, revision: revision) else {
                    return (nil, [])
                }
                return (view, try store.kbRevisions(companyId: companyId, path: view.page.path))
            }.value
            guard gen == pageGeneration else { return }
            self.view = view
            self.revisions = revisions
            if let view {
                self.selection = view.page.path
            } else {
                self.error = "No handbook page kb:\(selection)"
            }
        } catch let e as WorkError {
            guard gen == pageGeneration else { return }
            self.error = e.message
        } catch {
            guard gen == pageGeneration else { return }
            self.error = "Couldn't read kb:\(selection): \(error)"
        }
    }

    // MARK: Search

    /// Searches the handbook as the owner (kb docs only). A blank query clears the hits; an older run's hits are dropped.
    public func runSearch() async {
        searchGeneration += 1
        let gen = searchGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        defer { if gen == searchGeneration { isSearching = false } }
        let (store, companyId) = (self.store, self.companyId)
        do {
            let hits = try await Task.detached {
                try MemoryIndex(store: store).search(companyId: companyId, scope: .owner, query: q, sources: [.kb],
                                                     limit: MemoryPolicy.maxHits, now: Store.now())
            }.value
            guard gen == searchGeneration else { return }
            searchHits = hits
        } catch {
            guard gen == searchGeneration else { return }
            self.error = "Search failed: \(error)"
        }
    }

    // MARK: Owner decisions

    /// Owner: saves the whole page as `edit` on `baseRevision`. A conflict (or any refusal) sets `error` to the Store's text,
    /// exactly, and returns false. The text is checked against the company's stored secret values (`app.secretVault`).
    public func save(edit: String, baseRevision: Int) async -> Bool {
        guard let path = selection else { return false }
        let (store, companyId, paths, vault) = (self.store, self.companyId, self.paths, self.secretVault)
        return await decide("save kb:\(path)") {
            let known: [(name: String, value: String)]
            do {
                known = try store.knownSecretValues(companyId: companyId, vault: vault)
            } catch {
                throw WorkError.invalid("Couldn't read the company's secrets to check this edit, so it was not saved: \(error)")
            }
            _ = try store.kbWrite(companyId: companyId, by: .owner, path: path, body: edit, baseRevision: baseRevision,
                              knownValues: known, paths: paths)
        }
    }

    /// Owner: restores revision `number` as a new revision, then shows the current one.
    public func rollback(to number: Int) async -> Bool {
        guard let path = selection else { return false }
        let (store, companyId) = (self.store, self.companyId)
        return await decide("roll back kb:\(path)") { _ = try store.kbRollback(companyId: companyId, path: path, to: number) }
    }

    /// Owner: vouches for the selected page (its taint is cleared).
    public func vouch() async -> Bool {
        guard let path = selection else { return false }
        let (store, companyId) = (self.store, self.companyId)
        return await decide("vouch for kb:\(path)") { try store.kbVouch(companyId: companyId, path: path) }
    }

    /// Owner: sets the selected page's status (`deprecated` is the owner's alone).
    public func setStatus(_ status: KBStatus) async -> Bool {
        guard let path = selection else { return false }
        let (store, companyId) = (self.store, self.companyId)
        return await decide("set the status of kb:\(path)") { try store.kbSetStatus(companyId: companyId, path: path, status: status) }
    }

    /// Owner: exports every page as Markdown into `folder`, which must be empty (or not exist yet). Returns the number of
    /// files written, or the refusal.
    public func export(to folder: URL) async -> Result<Int, FormError> {
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: folder.path), !entries.isEmpty {
            return .failure(.invalid(Self.exportNeedsEmptyFolder))
        }
        let (store, companyId) = (self.store, self.companyId)
        isWorking = true
        defer { isWorking = false }
        do {
            let n = try await Task.detached { try HandbookExporter.export(store: store, companyId: companyId, to: folder, force: false) }.value
            return .success(n)
        } catch let e as WorkError {
            if case .conflict = e { return .failure(.invalid(Self.exportNeedsEmptyFolder)) }
            return .failure(.invalid(e.message))
        } catch {
            return .failure(.invalid("Couldn't export the handbook: \(error)"))
        }
    }

    /// Runs one owner decision off-main; on success the current revision is shown and the lists refresh.
    private func decide(_ what: String, _ body: @escaping @Sendable () throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            try await Task.detached { try body() }.value
        } catch let e as WorkError {
            error = e.message
            return false
        } catch {
            self.error = "Couldn't \(what): \(error)"
            return false
        }
        revision = nil
        await refreshLists()
        await loadPage()
        await afterChange?()
        return true
    }
}
