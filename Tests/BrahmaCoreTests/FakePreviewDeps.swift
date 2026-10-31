import Foundation
@testable import BrahmaCore

/// An `HTTPProbing` that answers from a script (one response per call, the last one repeated) and records every request.
final class FakeHTTPProbe: HTTPProbing, @unchecked Sendable {
    typealias Response = (status: Int?, contentType: String?, body: Data, error: String?)
    struct Request: Equatable, Sendable { var method: String; var url: URL; var body: Data? }

    private let lock = NSLock()
    private var responses: [Response]
    private var recorded: [Request] = []

    /// No response yet: every call is a connection error ("connection refused") until `responses` are given.
    init(_ responses: [Response] = []) { self.responses = responses }

    static func ok(_ status: Int = 200, body: String = "", contentType: String? = "text/html") -> Response {
        (status, contentType, Data(body.utf8), nil)
    }
    static let refused: Response = (nil, nil, Data(), "connection refused")

    var requests: [Request] { lock.withLock { recorded } }
    func answer(_ more: [Response]) { lock.withLock { responses.append(contentsOf: more) } }

    func send(method: String, url: URL, body: Data?, timeout: Duration) async -> Response {
        lock.withLock {
            recorded.append(Request(method: method, url: url, body: body))
            guard !responses.isEmpty else { return Self.refused }
            return responses.count == 1 ? responses[0] : responses.removeFirst()
        }
    }
}

/// A `ListenProbing` that reports fixed addresses for every port, and records the ports asked about.
final class FakeListenProbe: ListenProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var addresses: [String]
    private var asked: [Int] = []

    init(_ addresses: [String] = ["127.0.0.1"]) { self.addresses = addresses }

    var ports: [Int] { lock.withLock { asked } }
    func set(_ addresses: [String]) { lock.withLock { self.addresses = addresses } }

    func listenAddresses(port: Int) -> [String] { lock.withLock { asked.append(port); return addresses } }
}

extension PreviewDependencies {
    /// Fakes for every dependency (a fresh process table).
    static func fake(sandbox: FakeSandbox = FakeSandbox(), http: FakeHTTPProbe = FakeHTTPProbe([FakeHTTPProbe.ok()]),
                     listen: FakeListenProbe = FakeListenProbe()) -> PreviewDependencies {
        PreviewDependencies(sandbox: sandbox, http: http, listen: listen, processes: SpawnedProcesses())
    }
}
