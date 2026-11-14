import Foundation
import BrahmaCore

/// A release chip's color (Global Constraints "Color tokens"): proposed `ready`; approved/building/deploying/smoking
/// `running` (pulse); deployed `success`; failed/interrupted `danger`; rejected/cancelled/rolledBack `text2`.
public enum ReleaseTone: Sendable {
    case ready, running, success, danger, muted

    public init(_ status: ReleaseStatus) {
        switch status {
        case .proposed: self = .ready
        case .approved, .building, .deploying, .smoking: self = .running
        case .deployed: self = .success
        case .failed, .interrupted: self = .danger
        case .rejected, .cancelled, .rolledBack: self = .muted
        }
    }
}

public struct ReleaseRow: Equatable, Identifiable, Sendable {
    public var id: String
    /// `R-<n>`.
    public var ref: String
    /// "release <version>" (PR-29: the engine's ref is `refs/brahma/releases/<version>`).
    public var version: String
    public var statusTitle: String
    /// sha7.
    public var commit: String
    /// The production URL, else the deploy URL, else "—" (agent-controlled: provider output).
    public var url: String
    /// The deploy smoke's status, uppercased, or "—".
    public var smoke: String
    /// "@handle".
    public var proposer: String
    /// yyyy-MM-dd HH:mm in the owner's time zone.
    public var when: String
    /// "ROLLBACK REQUESTED" | "ROLLING BACK" | "ROLLED BACK" | "ROLLBACK FAILED" | "ROLLBACK INTERRUPTED".
    public var rollbackTitle: String?
    public var status: ReleaseStatus
    /// Mirrors `Store.requestRollback`'s rule over the listed releases.
    public var canRollBack: Bool
    /// The recorded rollback commands, exactly as the owner approved them.
    public var rollbackDisplay: String
    /// The URL's host, lowercased, or "—": what the table and inspector show (links render as host + Open).
    public var urlHost: String = "—"
    /// The URL when it is https with a host; nil otherwise (Open is https only).
    public var openURL: URL?
}

public enum ReleaseRows {
    public static func make(_ r: ReleasesSnapshot, handles: [String: String], timeZone: TimeZone = .current) -> [ReleaseRow] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let anyOpen = r.releases.contains { $0.status.isOpen }
        let anyRollingBack = r.releases.contains { $0.rollbackStatus == .requested || $0.rollbackStatus == .running }
        let live = r.releases.filter { $0.status == .deployed || $0.status == .failed }.max { $0.number < $1.number }?.id
        return r.releases.map { rel in
            let can = (rel.status == .deployed || rel.status == .failed) && !anyOpen && !anyRollingBack && rel.id == live
                && !rel.rollbackPlan.steps.isEmpty
            return ReleaseRow(id: rel.id, ref: rel.ref, version: "release \(rel.version)", statusTitle: rel.status.title.uppercased(),
                              commit: rel.sha7, url: rel.productionURL ?? rel.deployURL ?? "—",
                              smoke: rel.smokeStatus?.uppercased() ?? "—", proposer: "@" + (handles[rel.proposedById] ?? rel.proposedById),
                              when: f.string(from: rel.createdAt), rollbackTitle: rel.rollbackStatus.map(rollbackTitle),
                              status: rel.status, canRollBack: can, rollbackDisplay: rel.rollbackPlan.display,
                              urlHost: host(rel.productionURL ?? rel.deployURL) ?? "—", openURL: https(rel.productionURL ?? rel.deployURL))
        }
    }

    static func host(_ s: String?) -> String? {
        guard let s, let c = URLComponents(string: s), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    static func https(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s), url.scheme?.lowercased() == "https", host(s) != nil else { return nil }
        return url
    }

    static func rollbackTitle(_ s: RollbackStatus) -> String {
        switch s {
        case .requested: "ROLLBACK REQUESTED"
        case .running: "ROLLING BACK"
        case .succeeded: "ROLLED BACK"
        case .failed: "ROLLBACK FAILED"
        case .interrupted: "ROLLBACK INTERRUPTED"
        }
    }
}

/// The health of `main` as the smoke check last saw it.
public struct MainHealth: Equatable, Sendable {
    /// "SMOKE PASSED @abc1234" | "MAIN RED @abc1234 · BUG ACME-9" | "SMOKE NOT RUN @abc1234" | "NO SMOKE CHECK"
    /// (and "SMOKE RUNNING @abc1234" while a run at the head is queued or running).
    public var title: String
    public var tone: PreviewTone

    public init(title: String, tone: PreviewTone) { self.title = title; self.tone = tone }

    public static func make(_ r: ReleasesSnapshot, mainHead: String?) -> MainHealth {
        guard r.smokeCheck != nil else { return MainHealth(title: "NO SMOKE CHECK", tone: .idle) }
        guard let head = mainHead else { return MainHealth(title: "SMOKE NOT RUN", tone: .warn) }
        let sha7 = String(head.prefix(7))
        guard let run = r.latestMainSmoke, run.commit == head else { return MainHealth(title: "SMOKE NOT RUN @\(sha7)", tone: .warn) }
        switch run.status {
        case .passed: return MainHealth(title: "SMOKE PASSED @\(sha7)", tone: .good)
        case .failed:
            return MainHealth(title: "MAIN RED @\(sha7)" + (r.redBugKey.map { " · BUG \($0)" } ?? ""), tone: .bad)
        case .queued, .running: return MainHealth(title: "SMOKE RUNNING @\(sha7)", tone: .busy)
        default: return MainHealth(title: "SMOKE NOT RUN @\(sha7)", tone: .warn)
        }
    }
}

/// Company › Settings › HOSTING: the owner's fields. Validation is `HostingSettings.validate()` (PR-39), never a copy.
public struct HostingForm: Equatable, Sendable {
    public var provider: HostingProviderID = .default
    public var project = ""
    public var accountId = ""
    public var productionURL = ""

    public init(_ h: HostingSettings?, companySlug: String) {
        provider = h?.provider ?? .default
        project = h?.project ?? companySlug
        accountId = h?.accountId ?? ""
        productionURL = h?.productionURL ?? ""
    }

    static func nonEmpty(_ s: String) -> String? {
        let v = s.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// The first rule broken, in the core's words; nil when the form can be saved.
    public func validate() -> String? {
        let s = HostingSettings(companyId: "", provider: provider, project: project.trimmingCharacters(in: .whitespaces),
                                accountId: Self.nonEmpty(accountId), productionURL: Self.nonEmpty(productionURL), updatedAt: Date())
        do { try s.validate() } catch let e as WorkError { return e.message } catch { return "\(error)" }
        return nil
    }

    public var providerNote: String? {
        guard provider == .vercel else { return nil }
        let project = self.project.trimmingCharacters(in: .whitespaces)
        return "Vercel's free Hobby plan is for non-commercial use. " + VercelAdapter.projectNote(project: project)
    }
}

/// One chip of the PATH TO LIVE strip (Task 13): a milestone with its offset from the goal, then the totals.
public struct MilestoneChip: Equatable, Identifiable, Sendable {
    public var id: String
    /// `GOAL 0:00` | `PRD +0:52` | `LIVE +3:10` | `$14.80 · 7 TOUCHES`.
    public var title: String
    /// `success` for `live`, `ready` for the totals, `muted` for every other milestone (the color tokens).
    public var tone: ReleaseTone
}

public enum MilestoneChips {
    /// Nothing without a report; otherwise one chip per milestone, in time order, and the totals last.
    public static func make(_ report: MilestoneReport?) -> [MilestoneChip] {
        guard let report, !report.milestones.isEmpty else { return [] }
        var chips = zip(report.milestones, report.chipTitles()).map { m, title in
            MilestoneChip(id: m.name, title: title, tone: m.name == "live" ? .success : .muted)
        }
        chips.append(MilestoneChip(id: "totals", title: report.totalsTitle, tone: .ready))
        return chips
    }
}
