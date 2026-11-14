import Foundation

/// Cloudflare Pages through `wrangler pages`, the default provider.
///
/// UNVERIFIED (PR-14, "needs owner token"): the pin is the registry's latest 4.x at the time of writing (`npm view wrangler@4
/// version`), and every flag, the `HTTPS_PROXY` support and the output lines below were checked against that package's
/// source only. No real `pages deploy` has run under the sandbox yet, so `network` is the provisional host list; the owner's
/// probe with a throwaway token records the hosts the egress proxy saw (`Fixtures/wrangler-hosts.txt`) and fixes it.
/// The owner-run provider probe covers Vercel only, so the Cloudflare path (the default) stays unverified (final-review I5),
/// including the deploy URL's form and the subdomain Pages assigns.
public struct CloudflarePagesAdapter: HostingAdapter {
    public init() {}

    public var id: HostingProviderID { .cloudflarePages }
    public var tokenSecret: String { "CLOUDFLARE_API_TOKEN" }
    public static let version = "4.156.0"
    public var cli: String { "wrangler@\(Self.version)" }
    public var toolNetwork: [String] { ["registry.npmjs.org"] }
    /// Provisional, unverified (PR-14).
    public var network: [String] { ["api.cloudflare.com"] }

    static let accountMessage = "Cloudflare needs the account ID; finish the hosting-account task"
    static let functionsDir = "functions"

    public func validate(_ s: HostingSettings) throws {
        try HostingAdapters.validateForDeploy(s)
        guard s.accountId != nil else { throw WorkError.invalid(Self.accountMessage) }
    }

    /// wrangler's config files, refused in or above a deploy folder (`ProviderConfigCheck`, I3).
    public var providerConfigNames: [String] { ProviderConfigCheck.wranglerConfigs }

    /// The fixed environment: the account, no metrics, CI (non-interactive), and git's discovery stopped at the release
    /// root (I3). The token is added by the executor as `CLOUDFLARE_API_TOKEN`, from the vault, and never appears here or in
    /// argv.
    func env(_ i: DeployInput) -> [String: String] {
        ["CLOUDFLARE_ACCOUNT_ID": i.settings.accountId ?? "", "WRANGLER_SEND_METRICS": "false", "CI": "1",
         "GIT_CEILING_DIRECTORIES": i.gitCeiling]
    }

    func deployStep(_ i: DeployInput, directory: String, message: String) -> DeployStep {
        DeployStep(label: "deploy", argv: [i.bin("wrangler"), "pages", "deploy", directory, "--project-name", i.settings.project,
                                           "--branch", "main", "--commit-hash", i.commit, "--commit-message", message,
                                           "--commit-dirty=true"])
    }

    public func deployPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        let output = i.settings.outputDir ?? ""
        var stage = [output]
        // Pages Functions compile from `./functions` next to the upload; staged when the commit has the folder (PR-24).
        if i.functionsInCommit, output != Self.functionsDir, !output.hasPrefix(Self.functionsDir + "/") { stage.append(Self.functionsDir) }
        let create = DeployStep(label: "create project",
                                argv: [i.bin("wrangler"), "pages", "project", "create", i.settings.project, "--production-branch", "main"],
                                okIfOutputContains: "already exists")
        return try DeployPlan(steps: [create, deployStep(i, directory: output, message: "Release \(i.version)")], stageFrom: stage,
                              cwdPath: i.inRelease("upload"), network: network, tokenSecret: tokenSecret, env: env(i),
                              build: i.settings.build, outputDir: i.settings.outputDir)
    }

    /// The deploy step again, from the previous release's `upload/` when there is one, else from the placeholder site.
    public func rollbackPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        let cwd: String, directory: String, message: String
        if let previous = i.previousUpload {
            cwd = previous.path; directory = i.settings.outputDir ?? ""; message = "Release \(i.version)"
        } else {
            cwd = i.placeholderDir.path; directory = "."; message = "Placeholder"
        }
        return try DeployPlan(steps: [deployStep(i, directory: directory, message: message)], stageFrom: [], cwdPath: cwd,
                              network: network, tokenSecret: tokenSecret, env: env(i), build: i.settings.build,
                              outputDir: i.settings.outputDir)
    }

    /// The project's `pages.dev` subdomain as it may appear in a deploy URL (final-review I5): the project name, or, when
    /// that name was taken on `pages.dev`, the project name with the short suffix Pages adds (`<project>-<1–4 lowercase
    /// letters or digits>`). UNVERIFIED until a Cloudflare probe: the suffix's form is the one seen on Pages sites, not
    /// read from wrangler (it comes from Cloudflare's API). Anything else is not this project's.
    static func subdomainPattern(project: String) -> String {
        NSRegularExpression.escapedPattern(for: project) + "(?:-[a-z0-9]{1,4})?"
    }

    /// The deploy URL from wrangler's own last "Deployment complete!" line only, pinned to the configured project:
    /// `https://<8 hex>.<subdomain>.pages.dev`, the subdomain being the project's (`subdomainPattern`; M1, I5). A URL echoed
    /// anywhere else in the output (a build log, a function's bundling output) is ignored.
    public func deployURL(fromOutput: String, settings: HostingSettings) -> URL? {
        let sub = Self.subdomainPattern(project: settings.project)
        guard let pattern = try? NSRegularExpression(pattern: "https://[0-9a-f]{8}\\.\(sub)\\.pages\\.dev(?![A-Za-z0-9.-])") else {
            return nil
        }
        guard let line = fromOutput.split(whereSeparator: \.isNewline).last(where: { $0.contains("Deployment complete!") }) else {
            return nil
        }
        let text = String(line) as NSString
        guard let m = pattern.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return nil }
        return URL(string: text.substring(with: m.range))
    }

    /// The stored production URL; else the production address derived from the parsed deploy URL's host (final-review I5:
    /// `<8 hex>.<subdomain>.pages.dev` → `https://<subdomain>.pages.dev`, the subdomain still pinned to the project, never
    /// assumed from the project name, which Pages suffixes when it is taken); else nil, and the executor fails closed ("set
    /// the production URL in HOSTING").
    public func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL? {
        if let p = s.productionURL { return URL(string: p) }
        guard let host = deployURL?.host, deployURL?.scheme == "https",
              host.range(of: "^[0-9a-f]{8}\\.\(Self.subdomainPattern(project: s.project))\\.pages\\.dev$", options: .regularExpression) != nil
        else { return nil }
        return URL(string: "https://" + host.split(separator: ".").dropFirst().joined(separator: "."))
    }
}
