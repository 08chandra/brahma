import Foundation
import BrahmaCore

extension AppModel {
    public var releaseRows: [ReleaseRow] { ReleaseRows.make(snapshot.releases, handles: handles, timeZone: ownerTimeZone) }

    public var mainHealth: MainHealth { MainHealth.make(snapshot.releases, mainHead: snapshot.releases.mainHead) }

    /// The Releases sidebar chip: open releases.
    public var openReleaseCount: Int { snapshot.releases.openCount }

    /// Owner: roll back the live release (`Store.requestRollback`; the engine runs the recorded commands).
    public func rollback(releaseRef: String) async {
        guard let companyId = selectedCompanyId else { return }
        await ownerWrite("roll back") { store in try store.requestRollback(companyId: companyId, releaseRef: releaseRef, by: .owner) }
    }

    /// Owner: run the smoke check on `main` now.
    public func runMainSmoke() async {
        guard let companyId = selectedCompanyId else { return }
        await ownerWrite("run the smoke check") { store in try store.requestManualSmoke(companyId: companyId, by: .owner) }
    }

    public func saveHosting(_ form: HostingForm) async {
        guard let companyId = selectedCompanyId else { return }
        if let message = form.validate() { errorMessage = message; return }
        let f = form
        await ownerWrite("save hosting") { store in
            try store.setHosting(companyId: companyId, by: .owner, provider: f.provider, project: f.project, accountId: f.accountId,
                                 productionURL: f.productionURL)
        }
    }

    // MARK: Deploy asks (ownerDecide only)

    public func deployCard(for askId: String) -> DeployCard? {
        guard let ask = snapshot.work.inbox.first(where: { $0.id == askId }), ask.kind == .deploy else { return nil }
        return DeployCard.make(ask: ask, release: snapshot.deployReleases[askId], health: mainHealth, handles: handles)
    }

    public func approveDeploy(askId: String) async { await decide(askId: askId, approve: true) }

    public func rejectDeploy(askId: String, note: String) async { await decide(askId: askId, approve: false, note: note) }

    // MARK: Human tasks (completeHumanTask / declineHumanTask only)

    public func humanTaskCard(for askId: String) -> HumanTaskCard? {
        guard let ask = snapshot.work.inbox.first(where: { $0.id == askId }), ask.kind == .humanTask else { return nil }
        let keys = Dictionary(snapshot.work.items.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        return HumanTaskCard.make(ask: ask, handles: handles, itemKeys: keys)
    }

    /// Secrets go to the owner's vault (`ownerSecretVault`); without one nothing is stored.
    public func completeHumanTask(askId: String, form: HumanTaskForm) async {
        guard let companyId = selectedCompanyId else { return }
        if let card = humanTaskCard(for: askId), let message = form.validate(card) { errorMessage = message; return }
        guard let vault = ownerSecretVault else {
            errorMessage = "No secrets vault is available in this app, so nothing was stored."
            return
        }
        let values = form.values
        await ownerWrite("complete the task") { store in
            try store.completeHumanTask(companyId: companyId, askId: askId, values: values, vault: vault)
        }
    }

    public func declineHumanTask(askId: String, note: String) async {
        guard let companyId = selectedCompanyId else { return }
        await ownerWrite("decline the task") { store in try store.declineHumanTask(companyId: companyId, askId: askId, note: note) }
    }
}
