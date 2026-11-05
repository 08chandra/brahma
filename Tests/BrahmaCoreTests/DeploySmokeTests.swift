import Foundation
import Testing
@testable import BrahmaCore

/// The deployed site's smoke check (Plan L Task 7): rounds of the hosting's smoke requests until all pass or 6 rounds ran,
/// 10 s apart (the wait is injected: these tests never sleep), no redirect followed, the expected text on `/`.
@Suite(.scratch) struct DeploySmokeTests {
    /// Records each wait instead of sleeping.
    final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Duration] = []
        var all: [Duration] { lock.withLock { waits } }
        func sleep(_ d: Duration) async { lock.withLock { waits.append(d) } }
    }

    static let base = URL(string: "https://lumen.pages.dev")!

    static func run(_ http: FakeHTTPProbe, _ requests: [SmokeRequest] = [], expectText: String? = nil, sleeps: Sleeps = Sleeps(),
                    base: URL = base) async -> (ok: Bool, results: [SmokeResult]) {
        await DeploySmoke.run(base: base, requests: requests, expectText: expectText, http: http, sleep: { await sleeps.sleep($0) })
    }

    @Test func retriesUntilPropagated() async {
        #expect(DeploySmoke.attempts == 6)
        #expect(DeploySmoke.interval == .seconds(10))
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(404), FakeHTTPProbe.ok(404), FakeHTTPProbe.ok(200, body: "<title>Lumen</title>")])
        let sleeps = Sleeps()
        let (ok, results) = await Self.run(http, sleeps: sleeps)
        #expect(ok)
        // Three rounds, two waits of the pinned interval between them.
        #expect(http.requests.count == 3)
        #expect(sleeps.all == [DeploySmoke.interval, DeploySmoke.interval])
        // No smoke requests is `GET /` (carried-forward ruling 3).
        #expect(http.requests.allSatisfy { $0.method == "GET" && $0.url.absoluteString == "https://lumen.pages.dev/" && $0.body == nil })
        // The results are the last round's.
        #expect(results.count == 1)
        #expect(results.first?.status == 200); #expect(results.first?.ok == true); #expect(results.first?.error == nil)
        #expect(results.first?.url == "https://lumen.pages.dev/"); #expect(results.first?.method == "GET")
        #expect(results.first?.bodyPrefix == "<title>Lumen</title>")
    }

    @Test func expectTextCatchesPlaceholder() async {
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "Nothing is here yet")])
        let sleeps = Sleeps()
        let (ok, results) = await Self.run(http, expectText: "Lumen", sleeps: sleeps)
        #expect(!ok)
        #expect(http.requests.count == DeploySmoke.attempts)
        #expect(sleeps.all.count == DeploySmoke.attempts - 1)
        #expect(results.count == 1)
        #expect(results.first?.status == 200); #expect(results.first?.ok == false)
        #expect(results.first?.error == "the page does not contain the expected text")
        // The text is looked for on `/` only; with no `/` request a `GET /` is added for it, so it is never unchecked.
        let other = FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "Nothing is here yet")])
        let (otherOK, otherResults) = await Self.run(other, [SmokeRequest(method: "GET", path: "/health")], expectText: "Lumen")
        #expect(!otherOK)
        #expect(otherResults.map(\.url) == ["https://lumen.pages.dev/", "https://lumen.pages.dev/health"])
        #expect(otherResults.map(\.ok) == [false, true])
        // Present: one round.
        let real = FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "<html><title>Lumen</title></html>")])
        let (realOK, _) = await Self.run(real, expectText: "Lumen")
        #expect(realOK); #expect(real.requests.count == 1)
    }

    @Test func redirectIsNotFollowed() async {
        // A 301 is the answer (the probe never follows it): not a 2xx, so it fails every round.
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(301)])
        let (ok, results) = await Self.run(http, [SmokeRequest(method: "GET", path: "/")])
        #expect(!ok)
        #expect(http.requests.count == DeploySmoke.attempts)
        #expect(http.requests.allSatisfy { $0.url.absoluteString == "https://lumen.pages.dev/" })
        #expect(results.first?.status == 301)
        #expect(results.first?.error == "expected a 2xx status, got 301")
        // `GET /old 301` expects exactly that redirect.
        let expected = FakeHTTPProbe([FakeHTTPProbe.ok(301)])
        let (redirectOK, redirectResults) = await Self.run(expected, [SmokeRequest(method: "GET", path: "/old", expectStatus: 301)])
        #expect(redirectOK)
        #expect(expected.requests.map(\.url.absoluteString) == ["https://lumen.pages.dev/old"])
        #expect(redirectResults.first?.ok == true)
        // An expected status that is not met says so.
        let wrong = FakeHTTPProbe([FakeHTTPProbe.ok(200)])
        let (wrongOK, wrongResults) = await Self.run(wrong, [SmokeRequest(method: "GET", path: "/old", expectStatus: 301)])
        #expect(!wrongOK); #expect(wrongResults.first?.error == "expected 301, got 200")
    }

    @Test func everyRequestPassesInOneRound() async {
        // Round 1: `/` passes, `/health` is refused; round 2: both pass. Every request is sent again each round, the body and
        // method as written.
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(200), FakeHTTPProbe.refused, FakeHTTPProbe.ok(200), FakeHTTPProbe.ok(201)])
        let requests = [SmokeRequest(method: "GET", path: "/"), SmokeRequest(method: "POST", path: "/health", body: "{\"a\":1}", expectStatus: 201)]
        let (ok, results) = await Self.run(http, requests)
        #expect(ok)
        #expect(http.requests.map(\.method) == ["GET", "POST", "GET", "POST"])
        #expect(http.requests[1].body == Data("{\"a\":1}".utf8))
        #expect(results.map(\.status) == [200, 201])
        // A refused connection is the request's error.
        let down = FakeHTTPProbe([FakeHTTPProbe.refused])
        let (downOK, downResults) = await Self.run(down)
        #expect(!downOK); #expect(downResults.first?.error == "connection refused"); #expect(downResults.first?.status == nil)
    }

    @Test func pathsStayOnTheSite() async {
        // The base's own path is kept; a path never moves the request to another host.
        #expect(DeploySmoke.url(base: URL(string: "https://acme.com/app/")!, path: "/health")?.absoluteString == "https://acme.com/app/health")
        #expect(DeploySmoke.url(base: Self.base, path: "/@evil.com")?.host == "lumen.pages.dev")
        #expect(DeploySmoke.url(base: Self.base, path: "//evil.com/") == nil)
        #expect(DeploySmoke.url(base: Self.base, path: "health") == nil)
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(200)])
        let (ok, results) = await Self.run(http, [SmokeRequest(method: "GET", path: "//evil.com/")])
        #expect(!ok); #expect(http.requests.isEmpty)
        #expect(results.first?.error == "the smoke path does not stay on lumen.pages.dev")
    }
}
