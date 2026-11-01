import Foundation
@testable import BrahmaCore

/// A hosting provider for tests: "deploys" by copying the upload into `$FAKE_HOST_ROOT/<R-n>` and printing a fake URL; the
/// test serves `FAKE_HOST_ROOT` with a loopback static server, and `smokeBase` is that server. Never contacts anything. Its
/// install step is a no-op (`cli` is `fake@1`, nothing to install). Injected through the adapter lookup (PR-25), never a
/// shared registry.
struct FakeHostingAdapter: HostingAdapter {
    var id: HostingProviderID = .cloudflarePages
    var tokenSecret = "FAKE_HOST_TOKEN"
    var cli = "fake@1"
    var toolNetwork: [String] = []
    var network: [String] = []
    /// The loopback server over `FAKE_HOST_ROOT`.
    var server: URL?

    static let installIsNoOp = true

    func validate(_ s: HostingSettings) throws { try HostingAdapters.validateForDeploy(s) }

    func step(_ i: DeployInput) -> DeployStep {
        let n = i.releaseDir.lastPathComponent
        return DeployStep(label: "deploy", argv: ["/bin/sh", "-c", "cp -R . \"$FAKE_HOST_ROOT/\(n)\" && echo https://fake-\(n.lowercased()).local"])
    }

    func deployPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        return try DeployPlan(steps: [step(i)], stageFrom: [i.settings.outputDir ?? ""], cwdPath: i.inRelease("upload"),
                              network: network, tokenSecret: tokenSecret, build: i.settings.build, outputDir: i.settings.outputDir)
    }

    func rollbackPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        return try DeployPlan(steps: [step(i)], stageFrom: [], cwdPath: (i.previousUpload ?? i.placeholderDir).path,
                              network: network, tokenSecret: tokenSecret, build: i.settings.build, outputDir: i.settings.outputDir)
    }

    func deployURL(fromOutput: String, settings: HostingSettings) -> URL? {
        fromOutput.split(whereSeparator: \.isNewline).last { $0.hasPrefix("https://fake-") }.flatMap { URL(string: String($0)) }
    }

    func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL? { server }
}
