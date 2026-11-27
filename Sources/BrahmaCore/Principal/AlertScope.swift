import Foundation

/// The engine-wide conditions that may alert every company (spec §6.7). Each is named, and adding one is a reviewed change:
/// a condition that belongs to one company is `.company(id)`, never a broadcast (B8).
public enum GlobalAlert: String, Sendable, CaseIterable {
    /// The engine hold (network, account, CLI, disk): it pauses every company.
    case engineHold
    /// The sandbox canary of the installed Claude Code: agents in every sandboxed company wait on it.
    case sandboxCheck
    /// An engine file found unsafe where no single company owns it.
    case engineFile
    /// `brahma doctor`'s report: one Claude Code install and account serve every company.
    case doctor
    /// The secret store, shared by every company.
    case secrets
    /// The installed Claude Code itself (its settings, its init line, the models it bills, its plan): the same CLI runs
    /// every company's turns, and its alerts resolve when the doctor passes.
    case cli
}

/// Who an engine alert is for (`EngineAlerts.raise`, required): one company, or every company for a named engine-wide reason.
public enum AlertScope: Sendable, Equatable {
    case company(String)
    case allCompanies(GlobalAlert)
}

extension HoldReason {
    /// The scope of the alert a hold of this reason raises: a hold pauses the whole engine, so every company hears of it.
    /// Exhaustive, so a new hold reason gets a reviewed verdict.
    public var alertScope: AlertScope {
        switch self {
        case .network, .account, .cli, .disk: .allCompanies(.engineHold)
        }
    }
}
