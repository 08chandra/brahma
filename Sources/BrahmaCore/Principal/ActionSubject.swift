import Foundation

/// What one action is about, as `PrincipalResolver.resolve` takes it (spec §6.2.3): each case names the engine record whose
/// subjects (whose bytes are interpreted, whose code runs) the action touches. Never who asked for it.
///
/// The rows of the actions whose caller holds the record its command comes from (checks, merge runs, previews, main smokes,
/// release builds) are not here: those callers use `PrincipalResolver.resolve(holding:)` (S6-c1, S6-c2). Their id-based
/// form is `IdSubject`, internal to this module.
public enum ActionSubject: Sendable {
    /// C live diff, `wt:` refs, `isDirty` on item worktrees
    case worktree(companyId: String, key: String)
    /// 4a `publish_artifact` (nil = owner)
    case publish(companyId: String, agentId: String?)
    /// C2a text extraction of a stored file
    case vaultBlob(companyId: String, provenance: Provenance)
    /// 5-lite extension import and validation
    case extensionBundle(source: String)
    /// canary, doctor
    case engine
}

/// The id-based rows of the held-record actions (S6 fix round 3, M-2): resolved by id, not from the record whose command
/// runs, so for tests (`@testable`) and diagnostics only. Internal, so no other module can resolve one (the compiler enforces
/// it); inside this module `SafetyLint`'s `idSubject` zero rule bans a `resolve(` of one.
enum IdSubject: Sendable {
    /// submit / merge check (3a)
    case verificationRun(runId: String)
    /// 4a merge-queue check (kinds main, item, mainAtBase)
    case mergeRun(runId: String)
    /// L/4a preview start, smoke, demo
    case preview(surfaceId: String)
    /// L release smoke check (`company.smokeCheckSetById`)
    case mainSmoke(companyId: String)
    /// L release tool run (`proposedById`)
    case release(releaseId: String)
}
