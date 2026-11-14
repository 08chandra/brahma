import Foundation

/// Vercel through the `vercel` CLI (builder-check 9).
///
/// The project is chosen by `VERCEL_ORG_ID` + `VERCEL_PROJECT_ID` in the environment for deploy and rollback alike, never by
/// `vercel link` (PR-15), so no `.vercel/` folder is ever written or read (the stager skips a repo's dot folders). The token
/// is `VERCEL_TOKEN`, in the environment only, never argv.
///
/// UNVERIFIED (PR-14, "needs owner token"): the pin is the registry's latest at the time of writing (`npm view vercel
/// version`); the flags and environment names were checked against that package's source only. `VERCEL_PROJECT_ID` carries
/// the project name (the CLI resolves projects by id or name). `network` is provisional until the owner's probe.
///
/// Final-review I6: the deploy never creates the project (the owner does: `projectNote`, the hosting-account task); after
/// a `vercel rollback`, Vercel may stop auto-assigning production to later `--prod` deploys until a `vercel promote`
/// (unverified; the probe does not exercise a deploy → rollback → deploy cycle, and says so).
public struct VercelAdapter: HostingAdapter {
    public init() {}

    public var id: HostingProviderID { .vercel }
    public var tokenSecret: String { "VERCEL_TOKEN" }
    public static let version = "65.9.0"
    public var cli: String { "vercel@\(Self.version)" }
    public var toolNetwork: [String] { ["registry.npmjs.org"] }
    /// Provisional, unverified (PR-14).
    public var network: [String] { ["api.vercel.com", "vercel.com"] }

    /// Shown wherever the owner picks Vercel.
    public static let hobbyNote = "Vercel's free Hobby plan is for non-commercial use only; a commercial site needs a Pro plan."

    static let accountMessage = "Vercel needs the team or account ID; finish the hosting-account task"

    /// Final-review I6a: a deploy never creates the project (`VERCEL_PROJECT_ID` names it; `vercel deploy` likely fails
    /// "Project not found" without it, unverified until the probe deploys to a project it did not create). Shown with the
    /// hosting (CLI, app) and in the hosting-account task.
    public static func projectNote(project: String) -> String {
        "Vercel deploys never create the project: create \(project) first (Add New… → Project in the Vercel dashboard, or `vercel project add \(project)`)."
    }

    public func validate(_ s: HostingSettings) throws {
        try HostingAdapters.validateForDeploy(s)
        guard s.accountId != nil else { throw WorkError.invalid(Self.accountMessage) }
    }

    /// Nothing beyond `ProviderConfigCheck.boundedNames` (the `.vercel` project link and `.git`, up to the release root; I3).
    public var providerConfigNames: [String] { [] }

    /// The fixed environment (PR-3, PR-15): the account and project, no telemetry, CI, and git's discovery stopped at the
    /// release root (I3). `VERCEL_TOKEN` is added by the executor.
    func env(_ i: DeployInput) -> [String: String] {
        ["VERCEL_ORG_ID": i.settings.accountId ?? "", "VERCEL_PROJECT_ID": i.settings.project, "VERCEL_TELEMETRY_DISABLED": "1",
         "CI": "1", "GIT_CEILING_DIRECTORIES": i.gitCeiling]
    }

    func deployStep(_ i: DeployInput) -> DeployStep {
        DeployStep(label: "deploy", argv: [i.bin("vercel"), "deploy", "--prod", "--yes"])
    }

    /// The whole export (`["."]`, through the stager's dotfile rules) is uploaded from `releaseDir/upload`. The deploy URL the
    /// CLI prints is confirmed with the deploy's own token before the engine stores it (`vercel inspect <url>`, the Task 7
    /// ruling): a URL alone cannot tell this project from a foreign one named `<project>-<9 letters or digits>`.
    public func deployPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        return try DeployPlan(steps: [deployStep(i)], stageFrom: ["."], cwdPath: i.inRelease("upload"), network: network,
                              tokenSecret: tokenSecret, env: env(i), build: i.settings.build, outputDir: i.settings.outputDir,
                              verify: [i.bin("vercel"), "inspect", DeployPlan.deployURLPlaceholder])
    }

    /// `vercel inspect` names the deployment's project on a `name <project>` line of its General section; the deployment is
    /// this project's only when that line names exactly `settings.project` (also the `VERCEL_PROJECT_ID` the deploy used).
    ///
    /// UNVERIFIED until the owner's provider probe (PR-14): the line layout was read from the vercel 65.9.0 package, not seen
    /// against a real deployment. Anything else (no such line, another name, two different names) fails closed.
    public func verifiesDeployment(output: String, settings: HostingSettings) -> Bool {
        let names = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count == 2, words[0] == "name" else { return nil }
            return String(words[1])
        }
        return !names.isEmpty && names.allSatisfy { $0 == settings.project }
    }

    /// `vercel inspect <previous deploy URL>` (the target confirmed to be this project's with the token, before anything is
    /// rolled back to it: `DeployStep.verifyLabel`, the Task 7 check), then `vercel rollback <that URL> --yes`, both from an
    /// empty `releaseDir/rollback`; else, when there is no previous release at all, the placeholder deployed. A previous
    /// release with no recorded deploy URL (`previousUpload` set: `Store.rollbackInput` sets it whenever there is one) never
    /// falls back to the placeholder (Task 8 fix M1): the plan has no steps, which `requestRollback` and the executor refuse
    /// ("roll back from the provider dashboard"), and the deploy ask says so.
    public func rollbackPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        if i.previousDeployURL == nil, i.previousUpload != nil {
            return try DeployPlan(steps: [], stageFrom: [], cwdPath: i.inRelease("rollback"), network: network, tokenSecret: tokenSecret,
                                  env: env(i), build: i.settings.build, outputDir: i.settings.outputDir)
        }
        if let previous = i.previousDeployURL {
            guard Self.isDeployURL(previous, project: i.settings.project) else { throw WorkError.invalid("the previous deploy URL is not a vercel.app URL") }
            return try DeployPlan(steps: [DeployStep(label: DeployStep.verifyLabel, argv: [i.bin("vercel"), "inspect", previous]),
                                          DeployStep(label: "rollback", argv: [i.bin("vercel"), "rollback", previous, "--yes"])],
                                  stageFrom: [], cwdPath: i.inRelease("rollback"), network: network, tokenSecret: tokenSecret,
                                  env: env(i), build: i.settings.build, outputDir: i.settings.outputDir)
        }
        return try DeployPlan(steps: [deployStep(i)], stageFrom: [], cwdPath: i.placeholderDir.path, network: network,
                              tokenSecret: tokenSecret, env: env(i), build: i.settings.build, outputDir: i.settings.outputDir)
    }

    static func isDeployURL(_ s: String) -> Bool {
        s.range(of: "^https://[a-z0-9][a-z0-9-]*\\.vercel\\.app$", options: .regularExpression) != nil
    }

    /// A per-deploy URL of this project, matched whole (C2): `https://<project>-<9 lowercase letters or digits>-<scope>.vercel.app`,
    /// with the project regex-escaped and the hash segment fixed-length right after it, so a foreign project such as
    /// `acme-evil` never passes for `acme` through its own `-evil-…` segments.
    ///
    /// UNVERIFIED until the owner's provider probe (PR-14): the URL is generated by Vercel's API, not by the CLI (the vercel
    /// 65.9.0 package only prints what the API returns), so the 9-character hash is Vercel's documented and observed format,
    /// not one read from the CLI source. A foreign project named `<project>-<9 letters or digits>` is indistinguishable by
    /// the URL alone; the executor verifies the deployment's project with the token before trusting it (Task 7 ruling).
    static func isDeployURL(_ s: String, project: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: project)
        return s.range(of: "^https://\(escaped)-[a-z0-9]{9}-[a-z0-9-]+\\.vercel\\.app/?$", options: .regularExpression) != nil
    }

    /// From the deploy step's stdout only (M2), never merged or streamed build logs: the last "Production: <url>" line, else
    /// the last line that is exactly a URL. Either way a per-deploy URL of the configured project, never the alias.
    public func deployURL(fromOutput: String, settings: HostingSettings) -> URL? {
        let lines = fromOutput.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() {
            guard let r = line.range(of: "Production: ") else { continue }
            let url = line[r.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            if Self.isDeployURL(url, project: settings.project) { return URL(string: url) }
        }
        for line in lines.reversed() where Self.isDeployURL(line, project: settings.project) { return URL(string: line) }
        return nil
    }

    /// The owner's production URL; else the deploy URL the executor verified with the token (`vercel inspect`, the Task 7
    /// ruling: it passes only a verified one); else nil (fail closed: "set the production URL in HOSTING"). Never a guessed
    /// `https://<project>.vercel.app` (final-review I6b): when that name is taken Vercel gives the project another alias, and
    /// the guess would smoke someone else's site. A per-deploy URL may sit behind Vercel's deployment protection (a 401),
    /// so the owner sets the production URL for a protected project.
    public func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL? {
        if let p = s.productionURL { return URL(string: p) }
        return deployURL
    }

    /// Final-fix2 R2: a release is smoked only at the owner's production URL. Vercel's per-deploy URLs sit behind its
    /// deployment protection by default (likely a 401 or a login page), so a release with none recorded is refused before
    /// anything deploys rather than failing its smoke after the deploy. (The probe and a rollback still use `smokeBase`.)
    public var productionURLRequired: String? {
        "set the production URL in HOSTING before deploying to Vercel (its per-deploy URLs sit behind deployment protection)"
    }
}
