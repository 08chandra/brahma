import Foundation
import BrahmaCore

/// The owner's add-vacancy sheet. `validate` mirrors `Store.addVacancy`'s checks so the sheet can say what is wrong before
/// writing; the Store checks again. There is no fallback pack: a company whose pack is not installed cannot add seats.
public struct VacancyForm: Equatable, Sendable {
    public var role = ""
    /// Nil: under the Board.
    public var managerHandle: String?
    public var team = ""
    public var note = ""

    /// The same rule `Store.addVacancy` (and 3a's `joinOrgChannels`) apply to a team name.
    static let teamPattern = "^[a-z0-9][a-z0-9_-]{0,63}$"

    public init(role: String = "", managerHandle: String? = nil, team: String = "", note: String = "") {
        self.role = role; self.managerHandle = managerHandle; self.team = team; self.note = note
    }

    public func validate(pack: IndustryPack?, packId: String) -> String? {
        guard let pack else { return "company pack \(packId) is not installed" }
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !role.isEmpty else { return "Pick a role" }
        guard pack.role(role) != nil else { return "unknown role \(role)" }
        let team = team.trimmingCharacters(in: .whitespacesAndNewlines)
        if !team.isEmpty, team.range(of: Self.teamPattern, options: .regularExpression) == nil {
            return "Team names are lowercase letters, digits, - and _"
        }
        // Counted before redaction, as the Store counts it.
        if note.count > Store.vacancyNoteLimit { return "Notes are at most \(Store.vacancyNoteLimit) characters" }
        return nil
    }
}
