import Foundation

/// Cloudflare Pages through `wrangler pages`, the default provider.
///
/// UNVERIFIED (PR-14, "needs owner token"): the pin is the registry's latest 4.x at the time of writing (`npm view wrangler@4
/// version`), and every flag, the `HTTPS_PROXY` support and the output lines below were checked against that package's
/// source only. No real `pages deploy` has run under the sandbox yet, so `network` is the provisional host list; the owner's
/// probe with a throwaway token records the hosts the egress proxy saw (`Fixtures/wrangler-hosts.txt`) and fixes it.
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

    /// The fixed environment: the account, no metrics, CI (non-interactive). The token is added by the executor as
    /// `CLOUDFLARE_API_TOKEN`, from the vault, and never appears here or in argv.
    func env(_ s: HostingSettings) -> [String: String] {
        ["CLOUDFLARE_ACCOUNT_ID": s.accountId ?? "", "WRANGLER_SEND_METRICS": "false", "CI": "1"]
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
                              cwdPath: i.inRelease("upload"), network: network, tokenSecret: tokenSecret, env: env(i.settings),
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
                              network: network, tokenSecret: tokenSecret, env: env(i.settings), build: i.settings.build,
                              outputDir: i.settings.outputDir)
    }

    /// The last `https://<8 hex>.<subdomain>.pages.dev` in the output whose subdomain is the project's (`<project>` or
    /// `<project>-<suffix>`, when the name was taken): deploy output may echo other text.
    public func deployURL(fromOutput: String, settings: HostingSettings) -> URL? {
        let pattern = try? NSRegularExpression(pattern: "https://[0-9a-f]{8}\\.([a-z0-9-]+)\\.pages\\.dev")
        let text = fromOutput as NSString
        let matches = pattern?.matches(in: fromOutput, range: NSRange(location: 0, length: text.length)) ?? []
        for m in matches.reversed() {
            let sub = text.substring(with: m.range(at: 1))
            guard sub == settings.project || sub.hasPrefix(settings.project + "-") else { continue }
            return URL(string: text.substring(with: m.range))
        }
        return nil
    }

    /// The stored production URL, else `https://<subdomain>.pages.dev` from the deploy URL.
    public func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL? {
        if let p = s.productionURL { return URL(string: p) }
        guard let host = deployURL?.host, host.hasSuffix(".pages.dev") else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return URL(string: "https://\(parts[1]).pages.dev")
    }
}
