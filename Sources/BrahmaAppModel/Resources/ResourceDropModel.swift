import Foundation
import Observation
import BrahmaCore
#if canImport(Darwin)
import Darwin
#endif

/// The trust chip of a pending drop or a library row (collab §3.5, §4.3).
public enum TrustChip: Equatable, Sendable {
    case fromYou
    /// Agents read it as untrusted data; `reason` is the engine's (or "marked untrusted by you"), shown as the tooltip.
    case external(reason: String)

    public static let externalText =
        "EXTERNAL · agents read it as untrusted data; a session that opens it loses merge/approve tools until it starts fresh"
    public static let fromYouText = "FROM YOU"

    public var isExternal: Bool { if case .external = self { return true } else { return false } }

    public var text: String { isExternal ? Self.externalText : Self.fromYouText }

    /// The chip's button.
    public var action: String { isExternal ? "I vouch for this file" : "Mark untrusted" }

    /// What the chip's button sets.
    public var actionChoice: TrustChoice { isExternal ? .vouched : .untrusted }

    /// The chip a drop gets: the owner's choice, else what inspection detected (a link is the owner's unless marked).
    static func make(plan: DropPlan, isLink: Bool, trust: TrustChoice) -> TrustChip {
        switch trust {
        case .vouched: return .fromYou
        case .untrusted: return .external(reason: ResourceDropModel.untrustedReason)
        case .asDetected:
            guard !isLink, let tainted = plan.items.first(where: \.tainted) else { return .fromYou }
            return .external(reason: tainted.taintReason ?? "outside content")
        }
    }
}

/// One drop waiting on a composer: the inspected files (or one folder), or a link (`link`, normalized, never fetched).
public struct PendingDrop: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var plan: DropPlan
    public var trust: TrustChoice
    public var chip: TrustChip
    /// The link as it will be stored (`ResourceIntake.link`); nil for files.
    public var link: String?
    /// The owner's answer on the secret sheet (`.none` until given; only drops with findings need one).
    public var secretChoice: SecretChoice = .none

    public init(id: UUID = UUID(), plan: DropPlan, trust: TrustChoice = .asDetected, chip: TrustChip? = nil, link: String? = nil,
                secretChoice: SecretChoice = .none) {
        self.id = id; self.plan = plan; self.trust = trust; self.link = link; self.secretChoice = secretChoice
        self.chip = chip ?? TrustChip.make(plan: plan, isLink: link != nil, trust: trust)
    }

    public var hasFindings: Bool { plan.items.contains { !$0.findings.isEmpty } }
    var needsSecretChoice: Bool { hasFindings && secretChoice == .none }

    /// `LINK`, `FOLDER`, the one file's extension (`MD`, `PDF`) or `FILES`.
    public var kindLabel: String {
        if link != nil { return "LINK" }
        if plan.folderName != nil { return "FOLDER" }
        if plan.items.count == 1, let item = plan.items.first {
            return (item.ext.isEmpty ? item.fileKind : item.ext).uppercased()
        }
        return "FILES"
    }

    /// A link's host and path, the folder's name, the file's name, or `<n> files` (sanitized names: `ResourceIntake`).
    public var name: String {
        if let link { return ResourcesPresentation.linkShown(link) }
        if let folder = plan.folderName { return folder }
        if plan.items.count == 1, let item = plan.items.first { return item.displayName }
        return "\(plan.items.count) files"
    }

    /// Empty for a link; `<n> files · <size>` for a folder.
    public var sizeText: String {
        if link != nil { return "" }
        let size = ResourceText.size(plan.totalBytes)
        return plan.folderName == nil ? size : "\(plan.items.count) files · \(size)"
    }

    /// `<k> SKIPPED` when inspection left paths out (links inside a folder, `.git`, too deep), else nil.
    public var skippedNote: String? { plan.skipped.isEmpty ? nil : "\(plan.skipped.count) SKIPPED" }
}

/// Who a drop is for: the conversation's default (`Store.defaultScope`), a team, the company, or an item by key.
public enum ScopeChoice: Hashable, Sendable {
    case contextDefault
    case team(String)
    case company
    /// An item, by its key (`ENG-12`).
    case item(String)
}

/// The secret sheet (collab §4.5) for one pending drop whose scan found something.
public struct SecretSheetState: Equatable, Identifiable, Sendable {
    /// The pending drop it is about.
    public var id: UUID
    /// `This file looks like it contains a secret (<label>, line <n>)`, from the first finding.
    public var title: String
    /// One text file of at most `ResourcePolicy.secretFileBytes`.
    public var canStoreAsSecret: Bool
    /// Every file with a finding is text.
    public var canUploadRedacted: Bool
    /// Hidden when any finding is a value stored as a secret.
    public var showsUploadAnyway: Bool
    /// The name typed for "Store it as a secret instead".
    public var secretName = ""
    public var error: String?

    public static let storeTitle = "Store it as a secret instead"
    public static let redactedTitle = "Upload redacted"
    public static let anywayTitle = "Upload anyway"
    public static let cancelTitle = "Cancel"

    public var nameIsValid: Bool { SecretName.isValid(secretName) }

    public static func make(_ drop: PendingDrop) -> SecretSheetState? {
        let withFindings = drop.plan.items.filter { !$0.findings.isEmpty }
        guard let first = withFindings.first?.findings.first else { return nil }
        let items = drop.plan.items
        return SecretSheetState(
            id: drop.id,
            title: "This file looks like it contains a secret (\(first.label), line \(first.line))",
            canStoreAsSecret: items.count == 1 && drop.plan.folderName == nil && items[0].isText
                && items[0].bytes <= Int64(ResourcePolicy.secretFileBytes),
            canUploadRedacted: withFindings.allSatisfy(\.isText),
            showsUploadAnyway: !drop.plan.hasKnownValueFinding)
    }
}

/// The owner's drops on one composer (an owner DM, a channel, an agent's question in the Inbox, the Resources library).
/// Inspection runs off the main actor against the company's stored secret values (`app.secretVault`); one Send is one
/// message: the pending files with the owner's words in one `Store.addResources` call, or one link alone (`Store.addLink`).
/// Owner-only: the engine checks every scope and recipient again, and a refusal lands in `app.errorMessage` with nothing
/// stored.
@MainActor @Observable
public final class ResourceDropModel {
    public static let advisoryText =
        "Resource scopes, lab privacy and mirror integrity are enforced only by Brahma's tools; an agent's shell can read or change them."
    /// The hint on an Inbox question's drop zone.
    public static let inboxHint = "Drop a file to answer"
    /// What the trust chip says after "Mark untrusted" (the engine stores the same reason).
    nonisolated public static let untrustedReason = "marked untrusted by you"
    /// A link pending with files or with another link: one Send is one message.
    nonisolated public static let linkAloneRefusal = "Send a link on its own, one per message"

    nonisolated public static func advisoryKey(_ companyId: String) -> String { "advisoryAck.\(companyId)" }

    public let context: DropContext
    /// The company selected when the model was made; every drop goes to it.
    public let companyId: String?
    public var pending: [PendingDrop] = []
    public private(set) var scope: ScopeChoice = .contextDefault
    /// With an item scope: later holders of the item may read it too.
    public private(set) var futureHolders = false
    /// The scope chip (`SCOPE · @eng ONLY`), empty until resolved (`refreshScope`).
    public private(set) var scopeLabel = ""
    public var secretSheet: SecretSheetState?
    /// The advisory alert is up: the first non-company-scope drop of a company on the Workspace or Full profile.
    public var advisoryPrompt = false
    /// Inspecting a drop (`add(urls:)`).
    public private(set) var isInspecting = false
    /// Writing: a commit or a store-as-secret is in flight. A second commit meanwhile is refused (nothing twice).
    public private(set) var isCommitting = false
    /// Inspecting or committing (the views disable their buttons).
    public var isWorking: Bool { isInspecting || isCommitting }
    /// Tests only: awaited on the main actor by a commit after it has taken its drops and before anything is written.
    @ObservationIgnored var commitWillWrite: (@MainActor () async -> Void)?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let defaults: UserDefaults
    /// Pending drops that are a pasted image: the temporary PNG under `paths.tmpDir`, deleted once the drop is gone.
    @ObservationIgnored private var pasted: [UUID: URL] = [:]

    public init(app: AppModel, context: DropContext, defaults: UserDefaults) {
        self.app = app
        self.context = context
        self.defaults = defaults
        companyId = app.selectedCompanyId
    }

    /// Where agents' shells are not confined (Workspace, Full), scopes are advisory: the ADVISORY chip shows.
    public var showsAdvisory: Bool {
        guard let app, let companyId,
              let profile = app.snapshot.companies.first(where: { $0.id == companyId })?.company.permissionProfile else { return false }
        return profile == .workspace || profile == .full
    }

    /// The scope chooser's teams: those of the company's live agents.
    public var teamChoices: [String] {
        guard let app else { return [] }
        return Array(Set(app.snapshot.agents.filter { $0.state != .killed }.compactMap(\.team).filter { !$0.isEmpty })).sorted()
    }

    /// The scope chooser's items: open ones, newest first, at most 30.
    public var itemChoices: [String] {
        guard let app else { return [] }
        return Array(app.snapshot.work.items.filter { $0.status != .done }.sorted { $0.createdAt > $1.createdAt }.prefix(30).map(\.key))
    }

    public var hint: String {
        if case .inbox = context { return Self.inboxHint }
        return "Drop files, folders or links"
    }

    // MARK: Scope

    /// Resolves the scope chip for the current choice.
    public func refreshScope() async {
        guard let app, let companyId else { return }
        let (store, context, scope, future) = (app.store, self.context, self.scope, self.futureHolders)
        do {
            let resolved = try await Task.detached {
                try Self.resolve(store: store, companyId: companyId, context: context, choice: scope, futureHolders: future)
            }.value
            guard scope == self.scope, future == self.futureHolders else { return }       // changed meanwhile
            scopeLabel = resolved.label
        } catch {
            app.errorMessage = Self.message(error)
        }
    }

    public func setScope(_ choice: ScopeChoice, futureHolders: Bool = false) async {
        scope = choice
        self.futureHolders = futureHolders
        await refreshScope()
    }

    // MARK: Adding

    /// Inspects `urls` (`ResourceIntake.inspect`, off the main actor) and adds what passed as one pending drop. Refusals are
    /// shown in `app.errorMessage`; a drop with secret findings opens the secret sheet. A folder is added on its own. A file
    /// from a company workspace or the data home is EXTERNAL until vouched for (`Store.agentAreas`).
    public func add(urls: [URL]) async {
        await add(urls: urls, engineWritten: false)
    }

    /// `engineWritten`: the app itself just wrote these files from the owner's own input (a pasted image under the data
    /// home's tmp folder), so where they sit says nothing about who wrote them.
    private func add(urls: [URL], engineWritten: Bool) async {
        guard !urls.isEmpty, let app, let companyId else { return }
        let (store, vault, paths) = (app.store, app.secretVault, app.paths)
        isInspecting = true
        let inspected: Result<DropPlan, any Error> = await Task.detached {
            Result {
                // Fail closed: a vault that can't be read means the scan can't be trusted, so nothing is added.
                let known = try store.knownSecretValues(companyId: companyId, vault: vault)
                let areas = engineWritten ? AgentAreas.none : try store.agentAreas(paths: paths)
                return try ResourceIntake.inspect(urls: urls, knownValues: known, agentAreas: areas)
            }
        }.value
        isInspecting = false
        let plan: DropPlan
        switch inspected {
        case .success(let p): plan = p
        case .failure(let error): app.errorMessage = Self.message(error); return
        }
        if !plan.refusals.isEmpty {
            app.errorMessage = plan.refusals.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        }
        guard !plan.items.isEmpty else { return }
        let files = pending.filter { $0.link == nil }
        if (plan.folderName != nil && !files.isEmpty) || files.contains(where: { $0.plan.folderName != nil }) {
            app.errorMessage = "A folder is added on its own; send or remove the pending files first."
            return
        }
        let drop = PendingDrop(plan: plan)
        pending.append(drop)
        if secretSheet == nil { secretSheet = SecretSheetState.make(drop) }
        if scopeLabel.isEmpty { await refreshScope() }
    }

    /// Saves a pasted image as `paths.tmpDir/paste-<uuid>.png` (0600, in the 0700 tmp dir) and adds it.
    public func addPasteboardImage(_ png: Data) async {
        guard let app else { return }
        let url: URL
        do {
            let dir = try app.paths.ensureTmpDir()
            url = dir.appending(path: "paste-\(UUID().uuidString.lowercased()).png")
            try Self.writePrivate(png, to: url)
        } catch {
            app.errorMessage = "Couldn't save the pasted image: \(error)"
            return
        }
        let before = Set(pending.map(\.id))
        await add(urls: [url], engineWritten: true)
        if let added = pending.first(where: { !before.contains($0.id) }) {
            pasted[added.id] = url
        } else {
            Self.discard(url)
        }
    }

    /// Adds a link (http or https only; user and password removed). It is never fetched.
    public func addLink(_ s: String) {
        do {
            pending.append(PendingDrop(plan: DropPlan(), link: try ResourceIntake.link(s)))
        } catch {
            app?.errorMessage = Self.message(error)
            return
        }
        if scopeLabel.isEmpty { Task { await refreshScope() } }
    }

    public func remove(_ id: UUID) {
        pending.removeAll { $0.id == id }
        if secretSheet?.id == id { secretSheet = nil }
        if let url = pasted.removeValue(forKey: id) { Self.discard(url) }
    }

    public func setTrust(_ id: UUID, _ choice: TrustChoice) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].trust = choice
        pending[i].chip = TrustChip.make(plan: pending[i].plan, isLink: pending[i].link != nil, trust: choice)
    }

    // MARK: The secret sheet

    /// The owner's answer on the secret sheet: `.none` is Cancel (the drop is removed); `.uploadRedacted` and `.uploadAnyway`
    /// are kept for the commit; `.storeAsSecret(name)` stores the file through `app.secretVault` now (no resource is added).
    public func resolveSecret(_ choice: SecretChoice) async {
        guard var sheet = secretSheet else { return }
        guard let index = pending.firstIndex(where: { $0.id == sheet.id }) else { secretSheet = nil; return }
        switch choice {
        case .none:
            remove(sheet.id)
        case .uploadRedacted:
            guard sheet.canUploadRedacted else {
                sheet.error = "Only text files can be uploaded redacted."
                secretSheet = sheet
                return
            }
            pending[index].secretChoice = .uploadRedacted
            secretSheet = nil
        case .uploadAnyway:
            guard sheet.showsUploadAnyway else {
                sheet.error = "This file holds a value stored as a secret; upload a redacted copy or store it as a secret."
                secretSheet = sheet
                return
            }
            pending[index].secretChoice = .uploadAnyway
            secretSheet = nil
        case .storeAsSecret(let name):
            guard sheet.canStoreAsSecret else {
                sheet.error = "Only one text file of up to 64 KB can be stored as a secret."
                secretSheet = sheet
                return
            }
            guard SecretName.isValid(name) else {
                sheet.error = "A secret name is 2–64 characters of A–Z, 0–9 and _, starting with a letter."
                secretSheet = sheet
                return
            }
            guard let app, let companyId, !isCommitting else { return }
            let (store, vault, paths, plan, context) = (app.store, app.secretVault, app.paths, pending[index].plan, self.context)
            isCommitting = true
            let stored: Result<Void, any Error> = await Task.detached {
                Result {
                    let known = try store.knownSecretValues(companyId: companyId, vault: vault)
                    try store.addResources(companyId: companyId, plan: plan,
                                           drop: ResourceDrop(context: context, secretChoice: .storeAsSecret(name: name)),
                                           contentVault: ContentVault(paths: paths), secretVault: vault, knownValues: known, paths: paths)
                }
            }.value
            isCommitting = false
            if case .failure(let error) = stored {
                sheet.error = Self.message(error)
                secretSheet = sheet
                return
            }
            remove(sheet.id)
            await app.tick(forceSnapshot: true)
        }
        if secretSheet == nil, let next = pending.first(where: \.needsSecretChoice) { secretSheet = SecretSheetState.make(next) }
    }

    // MARK: The advisory

    /// "Add anyway" on the advisory alert: remembered for this company (`advisoryAck.<companyId>`).
    public func acknowledgeAdvisory() {
        if let companyId { defaults.set(true, forKey: Self.advisoryKey(companyId)) }
        advisoryPrompt = false
    }

    // MARK: Commit

    /// One Send is one message: the pending files in one `Store.addResources` call (`secretVault: app.secretVault`), or one
    /// link (`Store.addLink`), with `message` (the owner's words, above the engine's lines) in the drop's context. False, with
    /// nothing stored, when a commit is already in flight, when a link is pending with files or with another link
    /// (`linkAloneRefusal`), when a secret finding has no answer yet (the sheet opens), when the advisory has not been
    /// acknowledged (`advisoryPrompt`), or when the engine refuses (`app.errorMessage`). Only a successful commit clears the
    /// drops it took; anything added meanwhile stays pending.
    @discardableResult
    public func commit(message: String) async -> Bool {
        guard let app, let companyId, !pending.isEmpty, !isCommitting else { return false }
        let files = pending.filter { $0.link == nil }
        let links = pending.filter { $0.link != nil }
        // Each call posts its own message (an Inbox answer can be given once): a link never rides with anything else.
        guard links.isEmpty || (links.count == 1 && files.isEmpty) else {
            app.errorMessage = Self.linkAloneRefusal
            return false
        }
        if let unresolved = pending.first(where: \.needsSecretChoice) {
            secretSheet = SecretSheetState.make(unresolved)
            return false
        }
        let merged: MergedDrop?
        do { merged = try Self.merge(files) } catch {
            app.errorMessage = Self.message(error)
            return false
        }
        let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let (store, vault, paths, context) = (app.store, app.secretVault, app.paths, self.context)
        let (scope, future) = (self.scope, self.futureHolders)
        let acked = defaults.bool(forKey: Self.advisoryKey(companyId))
        isCommitting = true
        await commitWillWrite?()
        let result = await Task.detached {
            Self.commitOffMain(store: store, vault: vault, paths: paths, companyId: companyId, context: context, scope: scope,
                               futureHolders: future, acked: acked, files: merged, fileIds: files.map(\.id), link: links.first,
                               words: words.isEmpty ? nil : words)
        }.value
        isCommitting = false
        if result.needsAdvisory {
            advisoryPrompt = true
            return false
        }
        if let error = result.error {
            app.errorMessage = error
            return false
        }
        for id in result.committed { remove(id) }
        await app.tick(forceSnapshot: true)
        return true
    }

    struct MergedDrop: Sendable {
        var plan: DropPlan
        var trust: TrustChoice
        var secret: SecretChoice
    }

    struct CommitResult: Sendable {
        var needsAdvisory = false
        var committed: [UUID] = []
        var error: String?
    }

    /// The pending file drops as one plan. When their trust choices differ, each file carries its own (marked untrusted →
    /// external, vouched → the owner's) and the call adds them as detected. Every drop with findings must have the same
    /// answer: one call has one secret choice.
    nonisolated static func merge(_ drops: [PendingDrop]) throws -> MergedDrop? {
        guard let first = drops.first else { return nil }
        if drops.count == 1 { return MergedDrop(plan: first.plan, trust: first.trust, secret: first.secretChoice) }
        guard !drops.contains(where: { $0.plan.folderName != nil }) else {
            throw ResourceError.invalid("A folder is added on its own; send it first.")
        }
        var choices: [SecretChoice] = []
        for d in drops where d.hasFindings && !choices.contains(d.secretChoice) { choices.append(d.secretChoice) }
        guard choices.count <= 1 else {
            throw ResourceError.invalid("Send the redacted files and the files uploaded as is separately.")
        }
        let uniform = drops.allSatisfy { $0.trust == first.trust }
        var plan = DropPlan()
        for d in drops {
            for var item in d.plan.items {
                if !uniform {
                    switch d.trust {
                    case .untrusted:
                        item.provenance = .external("owner-marked"); item.tainted = true; item.taintReason = untrustedReason
                    case .vouched:
                        item.provenance = .owner; item.tainted = false; item.taintReason = nil
                    case .asDetected:
                        break
                    }
                }
                plan.items.append(item)
            }
            plan.skipped += d.plan.skipped
        }
        plan.totalBytes = plan.items.reduce(0) { $0 + $1.bytes }
        plan.hasKnownValueFinding = plan.items.contains { $0.findings.contains(where: \.isKnownValue) }
        plan.hasPatternFinding = plan.items.contains { $0.findings.contains { !$0.isKnownValue } }
        return MergedDrop(plan: plan, trust: uniform ? first.trust : .asDetected, secret: choices.first ?? .none)
    }

    nonisolated static func commitOffMain(store: Store, vault: any SecretVault, paths: BrahmaPaths, companyId: String,
                                          context: DropContext, scope: ScopeChoice, futureHolders: Bool, acked: Bool,
                                          files: MergedDrop?, fileIds: [UUID], link: PendingDrop?, words: String?) -> CommitResult {
        var result = CommitResult()
        do {
            let resolved = try resolve(store: store, companyId: companyId, context: context, choice: scope, futureHolders: futureHolders)
            let profile = try store.company(id: companyId)?.permissionProfile
            if resolved.access != .company, !acked, profile == .workspace || profile == .full {
                result.needsAdvisory = true
                return result
            }
            let content = ContentVault(paths: paths)
            func drop(trust: TrustChoice, secret: SecretChoice) -> ResourceDrop {
                ResourceDrop(context: context, scope: resolved.access, readerSet: resolved.readerSet,
                             futureHolders: resolved.futureHolders, trust: trust, secretChoice: secret, message: words)
            }
            // Exactly one call, so exactly one message (`commit` lets a link through only on its own).
            if let files {
                let known = try store.knownSecretValues(companyId: companyId, vault: vault)
                // Plan C Task C6: through C5's `ownerDrop` (the same `addResources`, with the file-request rules).
                try store.ownerDrop(companyId: companyId, context: context, plan: files.plan, drop: drop(trust: files.trust, secret: files.secret),
                                    contentVault: content, secretVault: vault, knownValues: known, paths: paths)
                result.committed = fileIds
            } else if let link, let url = link.link {
                try store.addLink(companyId: companyId, url: url, drop: drop(trust: link.trust, secret: .none), contentVault: content)
                result.committed = [link.id]
            }
        } catch {
            result.error = message(error)
        }
        return result
    }

    // MARK: Helpers

    struct ResolvedScope: Sendable {
        var access: AccessClass
        var readerSet: Set<String>?
        var futureHolders: Bool
        var label: String
    }

    nonisolated static func resolve(store: Store, companyId: String, context: DropContext, choice: ScopeChoice,
                                    futureHolders: Bool) throws -> ResolvedScope {
        let access: AccessClass
        let readers: Set<String>?
        switch choice {
        case .contextDefault:
            (access, readers) = try store.defaultScope(for: context, companyId: companyId)
        case .company:
            (access, readers) = (.company, nil)
        case .team(let t):
            (access, readers) = (.team(t), nil)
        case .item(let key):
            guard let item = try store.workItem(companyId: companyId, key: key.uppercased()) else {
                throw ResourceError.notFound("no work item \(key.prefix(40))")
            }
            access = .item(item.id)
            readers = try store.readerSet(for: access, companyId: companyId)
        }
        var future = false
        if case .item = access { future = futureHolders }
        let name: String
        switch access {
        case .agent(let id): name = try store.agent(id: id).flatMap { $0.companyId == companyId ? $0.name : nil } ?? id
        case .channel(let id), .dm(let id): name = try store.channels(companyId: companyId).first { $0.id == id }?.name ?? id
        case .item(let id): name = try store.workItem(id: id).flatMap { $0.companyId == companyId ? $0.key : nil } ?? id
        case .team(let t), .role(let t): name = t
        case .company, .ownerOnly: name = ""
        }
        return ResolvedScope(access: access, readerSet: readers, futureHolders: future,
                             label: ResourcesPresentation.scopeChip(access, name: name, readers: readers?.count ?? 0, futureHolders: future))
    }

    nonisolated static func message(_ error: any Error) -> String {
        switch error {
        case let e as ResourceError: e.message
        case let e as WorkError: e.message
        default: "\(error)"
        }
    }

    /// Creates `url` (never an existing file or a link) as 0600 and writes `data` to it.
    nonisolated static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += n
            }
        }
    }

    /// Removes a pasted image's temporary file. A failure leaves a file in the data home's tmp dir, which holds only the
    /// owner's own paste: reported on stderr, never fatal.
    nonisolated static func discard(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch {
            FileHandle.standardError.write(Data("brahma: could not remove the pasted image \(url.lastPathComponent): \(error)\n".utf8))
        }
    }
}
