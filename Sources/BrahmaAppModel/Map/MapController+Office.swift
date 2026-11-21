import Foundation

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
}
