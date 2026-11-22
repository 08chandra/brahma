import Foundation
import BrahmaCore

/// The office easter egg (Plan 4c, spec §4): the unlock routes feed `OfficeUnlock` on map time; the unlock is the owner's,
/// stored in `defaults` under `officeUnlockedKey`, and a synthetic (demo) controller may unlock too (same owner; it still
/// never writes to a store).
extension MapController {
    /// Unlocks the office for this owner: persists the flag, switches to the office and starts the reveal chip. A no-op once
    /// unlocked (the owner's later mode choice stands).
    public func unlockOffice() {
        guard !officeUnlocked else { return }
        officeUnlocked = true
        defaults.set(true, forKey: Self.officeUnlockedKey)
        mode = .office
        officeRevealAt = mapNow()
    }

    /// A key typed while the map has keyboard focus.
    public func officeKey(_ c: Character) {
        guard !officeUnlocked else { return }
        if officeUnlock.key(c, at: mapNow()) { unlockOffice() }
    }

    /// A left click on the Board card (the Board room door in the office).
    public func officeBoardClick() {
        guard !officeUnlocked else { return }
        if officeUnlock.boardClick(at: mapNow()) { unlockOffice() }
    }

    /// Any other click on the map: breaks a run of Board clicks.
    public func officeOtherClick() {
        guard !officeUnlocked else { return }
        officeUnlock.otherClick()
    }

    // MARK: Item facets (spec §6.2)

    /// Owner id → the phase of that owner's newest active item (`newest`, as `inputs(for:)` picks it).
    static func itemPhases(_ work: WorkSnapshot, newest: [String: WorkItem]) -> [String: MapItemPhase] {
        newest.mapValues { MapItemPhase.of(status: $0.status, mergeState: $0.mergeState, run: work.latestRuns[$0.id]?.status) }
    }

    /// The reviewers of items in review whose owner and reviewer are both `living`. (`DottedLinks.reviewers` cannot serve:
    /// it includes items in progress and carries no status.)
    static func reviewing(_ work: WorkSnapshot, living: Set<String>) -> Set<String> {
        var ids = Set<String>()
        for item in work.items where item.status == .inReview {
            guard let owner = item.ownerId, let reviewer = item.reviewerId, living.contains(owner), living.contains(reviewer)
            else { continue }
            ids.insert(reviewer)
        }
        return ids
    }
}
