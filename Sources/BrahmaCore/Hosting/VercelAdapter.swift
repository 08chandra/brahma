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

    public func validate(_ s: HostingSettings) throws {
        try HostingAdapters.validateForDeploy(s)
        guard s.accountId != nil else { throw WorkError.invalid(Self.accountMessage) }
    }

    /// The fixed environment (PR-3, PR-15): the account and project, no telemetry, CI. `VERCEL_TOKEN` is added by the executor.
    func env(_ s: HostingSettings) -> [String: String] {
        ["VERCEL_ORG_ID": s.accountId ?? "", "VERCEL_PROJECT_ID": s.project, "VERCEL_TELEMETRY_DISABLED": "1", "CI": "1"]
    }

    func deployStep(_ i: DeployInput) -> DeployStep {
        DeployStep(label: "deploy", argv: [i.bin("vercel"), "deploy", "--prod", "--yes"])
    }

    /// The whole export (`["."]`, through the stager's dotfile rules) is uploaded from `releaseDir/upload`.
    public func deployPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        return try DeployPlan(steps: [deployStep(i)], stageFrom: ["."], cwdPath: i.inRelease("upload"), network: network,
                              tokenSecret: tokenSecret, env: env(i.settings), build: i.settings.build, outputDir: i.settings.outputDir)
    }

    /// `vercel rollback <previous deploy URL> --yes` from an empty `releaseDir/rollback`, else the placeholder deployed.
    public func rollbackPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        if let previous = i.previousDeployURL {
            guard Self.isDeployURL(previous) else { throw WorkError.invalid("the previous deploy URL is not a vercel.app URL") }
            return try DeployPlan(steps: [DeployStep(label: "rollback", argv: [i.bin("vercel"), "rollback", previous, "--yes"])],
                                  stageFrom: [], cwdPath: i.inRelease("rollback"), network: network, tokenSecret: tokenSecret,
                                  env: env(i.settings), build: i.settings.build, outputDir: i.settings.outputDir)
        }
        return try DeployPlan(steps: [deployStep(i)], stageFrom: [], cwdPath: i.placeholderDir.path, network: network,
                              tokenSecret: tokenSecret, env: env(i.settings), build: i.settings.build, outputDir: i.settings.outputDir)
    }

    static func isDeployURL(_ s: String) -> Bool {
        s.range(of: "^https://[a-z0-9][a-z0-9-]*\\.vercel\\.app$", options: .regularExpression) != nil
    }

    /// The last output line that is exactly a `https://….vercel.app` URL (the CLI prints the deployment's URL alone on its
    /// last stdout line), other than the production alias.
    public func deployURL(fromOutput: String, settings: HostingSettings) -> URL? {
        let alias = "https://\(settings.project).vercel.app"
        for line in fromOutput.split(whereSeparator: \.isNewline).reversed() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if Self.isDeployURL(s), s != alias { return URL(string: s) }
        }
        return nil
    }

    /// Always the production alias (the stored production URL, else `https://<project>.vercel.app`), never the per-deploy
    /// URL, which Vercel's deployment protection may put behind a login.
    public func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL? {
        URL(string: s.productionURL ?? "https://\(s.project).vercel.app")
    }
}
