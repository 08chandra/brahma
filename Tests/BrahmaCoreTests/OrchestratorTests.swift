import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite struct OrchestratorTests {
    @Test func ownerMessageRunsAgentAndSleepsAfter() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        _ = try w.router.post(companyId: c.id, channel: "general", from: .owner, text: "@ceo kick off", now: w.clock.now)
        #expect(try w.agent(ceo).state == .ready)
        try await w.cycle()
        let turns = try w.turns(ceo)
        #expect(turns.count == 1)
        #expect(turns.first?.outcome == .succeeded)
        #expect(turns.first?.summary == "done")
        #expect(turns.first?.costUSD == 0.01)
        #expect(try w.pending(ceo) == 0)
        let after = try w.agent(ceo)
        #expect(after.state == .sleeping)
        #expect(after.sessionStarted)
        #expect(await w.orchestrator.runningCount() == 0)
        let prompt = try #require(w.fake.requests.first?.prompt)
        #expect(prompt.contains("#general @owner: @ceo kick off"))
        let kinds = try w.store.events(afterId: 0).filter { $0.turnId == turns[0].id }.map(\.kind)
        #expect(kinds.first == .turnStarted)
        #expect(kinds.last == .turnFinished)
        let finished = try w.store.events(afterId: 0).last { $0.kind == .turnFinished }
        #expect(finished?.text.contains("succeeded") == true)
    }

    @Test func turnTokenIsInTheMCPConfigOnly() async throws {
        final class Box: @unchecked Sendable {
            private let lock = NSLock(); private var _token: String?; private var _validDuring = false; private var _mode: Int?
            func set(token: String, valid: Bool, mode: Int?) { lock.withLock { _token = token; _validDuring = valid; _mode = mode } }
            var token: String? { lock.withLock { _token } }
            var validDuring: Bool { lock.withLock { _validDuring } }
            var mode: Int? { lock.withLock { _mode } }
        }
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let box = Box(); let store = w.store
        w.fake.script("ceo", .init(sideEffect: { req in
            let data = try Data(contentsOf: URL(fileURLWithPath: req.mcpConfigPath))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let server = try #require((json["mcpServers"] as? [String: Any])?["company"] as? [String: Any])
            let token = try #require((server["env"] as? [String: String])?["BRAHMA_TURN_TOKEN"])
            let mode = try FileManager.default.attributesOfItem(atPath: req.mcpConfigPath)[.posixPermissions] as? Int
            box.set(token: token, valid: store.verifyTurnCredential(token: token, companyId: req.company.id, agentId: req.agent.id),
                    mode: mode)
        }))
        try w.dm(c, ceo); try await w.cycle()
        let token = try #require(box.token)
        #expect(token.count == 64)
        #expect(box.validDuring, "the engine-issued token verifies against the DB while the turn runs")
        #expect(box.mode == 0o600)
        let req = try #require(w.fake.requests.first)
        #expect(!req.environment.values.contains { $0.contains(token) })
        #expect(!ClaudeCommand.arguments(for: req).contains { $0.contains(token) })
        let childEnv = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, extra: req.environment, purpose: .claude)
        #expect(!childEnv.values.contains { $0.contains(token) })
        #expect(!(w.store.verifyTurnCredential(token: token, companyId: c.id, agentId: ceo.id)), "ended turn")
    }

    @Test func firstTurnSendsRolePromptThenResumes() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        try w.dm(c, ceo); try await w.cycle()
        try w.dm(c, ceo); try await w.cycle()
        let reqs = w.fake.requests
        #expect(reqs.count == 2)
        #expect(reqs[0].appendSystemPrompt?.contains("You are @ceo") == true)
        #expect(ClaudeCommand.arguments(for: reqs[0]).contains("--session-id"))
        #expect(reqs[1].appendSystemPrompt == reqs[0].appendSystemPrompt)
        #expect(reqs[0].environment["BRAHMA_AGENT_ID"] == reqs[0].agent.id)
        #expect(ClaudeCommand.arguments(for: reqs[1]).contains("--resume"))
        #expect(reqs[1].workingDirectory == c.workspacePath)
        #expect(FileManager.default.fileExists(atPath: reqs[1].mcpConfigPath))
    }

    @Test func toolPostDuringTurnWakesRecipient() async throws {
        let w = try World(); let c = try w.company("Acme")
        let ceo = try w.hire(c, "ceo"); let cto = try w.hire(c, "cto")
        let router = w.router; let now = w.clock.now
        w.fake.script("ceo", .init(sideEffect: { _ in
            _ = try router.post(companyId: c.id, channel: "general", from: .agent(ceo.id), text: "@cto build it", now: now)
        }))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.turns(cto).isEmpty)
        #expect(try w.agent(cto).state == .ready)
        try await w.cycle()
        #expect(try w.turns(cto).map(\.outcome) == [.succeeded])
        #expect(try w.agent(cto).state == .sleeping)
    }

    @Test func messageDuringTurnIsNotLost() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let router = w.router; let now = w.clock.now
        w.fake.script("ceo", .init(sideEffect: { _ in
            _ = try router.sendDM(companyId: c.id, from: .owner, to: "ceo", text: "one more thing", now: now)
        }))
        try w.dm(c, ceo, "first")
        try await w.cycle()
        #expect(try w.agent(ceo).state == .ready)
        let pending = try w.store.pendingInbox(agentId: ceo.id)
        #expect(pending.map(\.1.text) == ["one more thing"])
        try await w.cycle()
        #expect(w.fake.requests.last?.prompt.contains("one more thing") == true)
        #expect(try w.pending(ceo) == 0)
    }

    @Test func requestedBlockerAppliedAtTurnEnd() async throws {
        let w = try World(); let c = try w.company("Acme")
        let ceo = try w.hire(c, "ceo"); let cto = try w.hire(c, "cto")
        let tools = CompanyTools(store: w.store, companyId: c.id, agentId: ceo.id, diagnostics: { _ in })
        w.fake.script("ceo", .init(sideEffect: { _ in
            _ = try tools.call(name: "set_blocked", arguments: ["on": .string("@cto"), "reason": .string("need spec")])
        }))
        try w.dm(c, ceo)
        try await w.cycle()
        let blocked = try w.agent(ceo)
        #expect(blocked.state == .blocked)
        #expect(blocked.blocker == .agent(cto.id))
        #expect(blocked.requestedBlocker == nil)
        _ = try w.router.sendDM(companyId: c.id, from: .agent(cto.id), to: "ceo", text: "spec attached", now: w.clock.now)
        #expect(try w.agent(ceo).state == .ready)
    }

    @Test func blockerReplyDuringTurnWakesAtTurnEnd() async throws {
        let w = try World(); let c = try w.company("Acme")
        let ceo = try w.hire(c, "ceo"); let cto = try w.hire(c, "cto")
        let tools = CompanyTools(store: w.store, companyId: c.id, agentId: ceo.id, diagnostics: { _ in })
        let router = w.router; let now = w.clock.now
        w.fake.script("ceo", .init(sideEffect: { _ in
            _ = try tools.call(name: "set_blocked", arguments: ["on": .string("@cto"), "reason": .string("need spec")])
            _ = try router.sendDM(companyId: c.id, from: .agent(cto.id), to: "ceo", text: "spec attached", now: now)
        }))
        try w.dm(c, ceo)
        try await w.cycle()
        let after = try w.agent(ceo)
        #expect(after.state == .ready)
        #expect(after.requestedBlocker == nil)
    }

    @Test func failedTurnBacksOff() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        w.fake.script("ceo", .init(events: [], error: FakeError(description: "boom")), .init(events: [], error: FakeError(description: "boom")))
        try w.dm(c, ceo)
        try await w.cycle()
        var a = try w.agent(ceo)
        #expect(a.state == .blocked)
        #expect(a.blocker == .retry(until: w.clock.now.addingTimeInterval(30), failures: 1))
        #expect(a.consecutiveFailures == 1)
        #expect(try w.pending(ceo) == 1)
        #expect(try w.turns(ceo).last?.outcome == .failed)
        #expect(try w.turns(ceo).last?.summary?.contains("boom") == true)

        w.clock.advance(29)
        try await w.cycle()
        #expect(try w.turns(ceo).count == 1)

        w.clock.advance(1)
        try await w.cycle()
        a = try w.agent(ceo)
        #expect(try w.turns(ceo).count == 2)
        #expect(a.blocker == .retry(until: w.clock.now.addingTimeInterval(60), failures: 2))
        #expect(try w.pending(ceo) == 1)

        w.clock.advance(60)
        try await w.cycle()
        a = try w.agent(ceo)
        #expect(a.state == .sleeping)
        #expect(a.consecutiveFailures == 0)
        #expect(try w.pending(ceo) == 0)
    }

    @Test func backoffIsCappedAtThirtyMinutes() async throws {
        let w = try World(); let c = try w.company("Acme"); var ceo = try w.hire(c, "ceo")
        ceo.consecutiveFailures = 9
        try w.store.save(ceo)
        w.fake.script("ceo", .init(events: [], error: FakeError(description: "boom")))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.agent(ceo).blocker == .retry(until: w.clock.now.addingTimeInterval(30 * 60), failures: 10))
    }

    @Test func missingResultIsFailure() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        w.fake.script("ceo", .init(events: [.initialized(sessionId: ceo.sessionId, model: "sonnet")]))
        try w.dm(c, ceo)
        try await w.cycle()
        let a = try w.agent(ceo)
        #expect(a.state == .blocked)
        #expect(a.blocker == .retry(until: w.clock.now.addingTimeInterval(30), failures: 1))
        #expect(try w.turns(ceo).map(\.outcome) == [.failed])
        #expect(try w.pending(ceo) == 1)
    }

    @Test func errorResultIsFailure() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        w.fake.script("ceo", .init(events: [.result(TurnResult(isError: true, subtype: "error_during_execution",
                                                                 text: "tool crashed", costUSD: nil, apiErrorStatus: 400,
                                                                 sessionId: ceo.sessionId))]))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.agent(ceo).blocker == .retry(until: w.clock.now.addingTimeInterval(30), failures: 1))
        #expect(try w.turns(ceo).first?.summary == "tool crashed")
    }

    /// A wall-clock kill while the rate limit is active is a usage limit (held to the reset, not counted against the agent).
    @Test func wallClockKillWhileRateLimitedIsUsageLimited() async throws {
        let w = try World()
        let c = try w.company("Acme")
        let a = try w.hire(c, "ceo")
        let t = w.clock.now
        let rejected = RateLimitInfo(status: "rejected", resetsAt: t.addingTimeInterval(7200), rateLimitType: "five_hour",
                                     isUsingOverage: false, fiveHourUtilization: 1.0, sevenDayUtilization: 0.5, observedAt: t)
        w.fake.script("ceo", .init(events: [.initialized(sessionId: a.sessionId, model: "sonnet"), .rateLimit(rejected)],
                                   error: TurnError.timedOut))
        try w.dm(c, a)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.usageLimited])
        #expect(try w.agent(a).blocker == .usageLimit(until: t.addingTimeInterval(7200)))
        #expect(try w.agent(a).consecutiveFailures == 0)
        #expect(try w.pending(a) == 1)
    }

    /// A timed-out turn is never a success, even with an early non-error result (background work still pending).
    @Test func wallClockKillAfterEarlySuccessWhileRateLimitedIsUsageLimited() async throws {
        let w = try World()
        let c = try w.company("Acme")
        let a = try w.hire(c, "ceo")
        let t = w.clock.now
        let rejected = RateLimitInfo(status: "rejected", resetsAt: t.addingTimeInterval(7200), rateLimitType: "five_hour",
                                     isUsingOverage: false, fiveHourUtilization: 1.0, sevenDayUtilization: 0.5, observedAt: t)
        w.fake.script("ceo", .init(events: [
            .initialized(sessionId: a.sessionId, model: "sonnet"), .rateLimit(rejected),
            .result(TurnResult(isError: false, subtype: "success", text: "started", costUSD: 0.01, apiErrorStatus: nil,
                               sessionId: a.sessionId)),
        ], error: TurnError.timedOut))
        try w.dm(c, a)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.usageLimited])
        #expect(try w.agent(a).blocker == .usageLimit(until: t.addingTimeInterval(7200)))
        #expect(try w.agent(a).consecutiveFailures == 0)
        #expect(try w.pending(a) == 1)
    }

    /// Same with an HTTP 429 on the early result and no rate-limit event: usage-limited, and the gate closes.
    @Test func wallClockKillAfterEarlyResultWith429IsUsageLimited() async throws {
        let w = try World()
        let c = try w.company("Acme")
        let a = try w.hire(c, "ceo")
        w.fake.script("ceo", .init(events: [
            .initialized(sessionId: a.sessionId, model: "sonnet"),
            .result(TurnResult(isError: false, subtype: "success", text: "started", costUSD: 0.01, apiErrorStatus: 429,
                               sessionId: a.sessionId)),
        ], error: TurnError.timedOut))
        try w.dm(c, a)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.usageLimited])
        #expect(try w.agent(a).consecutiveFailures == 0)
        #expect(try w.pending(a) == 1)
    }

    /// A timeout with no rate limit in play stays a plain failure with the normal backoff.
    @Test func wallClockKillAloneIsAFailure() async throws {
        let w = try World()
        let c = try w.company("Acme")
        let a = try w.hire(c, "ceo")
        w.fake.script("ceo", .init(events: [.initialized(sessionId: a.sessionId, model: "sonnet")], error: TurnError.timedOut))
        try w.dm(c, a)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.failed])
        #expect(try w.agent(a).consecutiveFailures == 1)
        guard case .retry? = try w.agent(a).blocker else { Issue.record("expected a retry backoff"); return }
    }

    @Test func usageLimitBlocksEveryone() async throws {
        let w = try World()
        let c1 = try w.company("Acme"); let c2 = try w.company("Beta")
        let a = try w.hire(c1, "ceo"); let b = try w.hire(c2, "ceo")
        let t = w.clock.now
        let rejected = RateLimitInfo(status: "rejected", resetsAt: t.addingTimeInterval(7200), rateLimitType: "five_hour",
                                     isUsingOverage: false, fiveHourUtilization: 1.0, sevenDayUtilization: 0.5, observedAt: t)
        w.fake.script("ceo", .init(events: [
            .initialized(sessionId: a.sessionId, model: "sonnet"),
            .rateLimit(rejected),
            .result(TurnResult(isError: true, subtype: "error_during_execution", text: "usage limit reached",
                               costUSD: nil, apiErrorStatus: 429, sessionId: a.sessionId)),
        ]))
        try w.dm(c1, a)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.usageLimited])
        #expect(try w.agent(a).blocker == .usageLimit(until: t.addingTimeInterval(7200)))
        #expect(try w.pending(a) == 1)
        #expect(try w.agent(a).consecutiveFailures == 0)

        try w.dm(c2, b)
        try await w.cycle()
        #expect(try w.turns(b).isEmpty)
        #expect(try w.agent(b).state == .blocked)
        #expect(try w.agent(b).blocker == .usageLimit(until: t.addingTimeInterval(7200)))
        #expect(try w.store.events(afterId: 0, companyId: c2.id).contains { $0.kind == .usage })

        w.clock.advance(7201)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.usageLimited, .succeeded])
        #expect(try w.turns(b).map(\.outcome) == [.succeeded])
        #expect(try w.pending(a) == 0)
        #expect(try w.pending(b) == 0)
    }

    @Test(arguments: [("allowed_warning", false), ("allowed_warning", true), ("rejected", false), ("rejected", true)])
    func successfulTurnThatHitsLimitStillCounts(status: String, messageMidTurn: Bool) async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let t = w.clock.now
        let info = RateLimitInfo(status: status, resetsAt: t.addingTimeInterval(7200), rateLimitType: "five_hour",
                                 isUsingOverage: false, fiveHourUtilization: 0.99, sevenDayUtilization: 0.5, observedAt: t)
        let router = w.router
        w.fake.script("ceo", .init(events: [
            .initialized(sessionId: ceo.sessionId, model: "sonnet"),
            .rateLimit(info),
            .result(TurnResult(isError: false, subtype: "success", text: "done", costUSD: 0.01, apiErrorStatus: nil,
                               sessionId: ceo.sessionId)),
        ], sideEffect: { _ in
            if messageMidTurn { _ = try router.sendDM(companyId: c.id, from: .owner, to: "ceo", text: "more", now: t) }
        }))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.turns(ceo).map(\.outcome) == [.succeeded])
        #expect(try w.pending(ceo) == (messageMidTurn ? 1 : 0))
        let a = try w.agent(ceo)
        #expect(a.consecutiveFailures == 0)
        if messageMidTurn && status == "rejected" {
            #expect(a.state == .blocked)
            #expect(a.blocker == .usageLimit(until: t.addingTimeInterval(7200)))
        } else if messageMidTurn {
            // A warning is not a limit: no usage hold.
            #expect(a.state == .ready)
        } else {
            #expect(a.state == .sleeping)
        }
    }

    @Test func successResultThenStreamErrorStillSucceeds() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        w.fake.script("ceo", .init(error: FakeError(description: "exit 1 after result")))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.turns(ceo).map(\.outcome) == [.succeeded])
        #expect(try w.pending(ceo) == 0)
        #expect(try w.agent(ceo).state == .sleeping)
    }

    @Test func staleResetsAtStillWaitsFifteenMinutes() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let t = w.clock.now
        let stale = RateLimitInfo(status: "rejected", resetsAt: t.addingTimeInterval(-60), rateLimitType: "five_hour",
                                  isUsingOverage: false, fiveHourUtilization: 1.0, sevenDayUtilization: 0.5, observedAt: t)
        w.fake.script("ceo", .init(events: [
            .rateLimit(stale),
            .result(TurnResult(isError: true, subtype: "error_during_execution", text: "usage limit reached",
                               costUSD: nil, apiErrorStatus: 429, sessionId: ceo.sessionId)),
        ]))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.agent(ceo).blocker == .usageLimit(until: t.addingTimeInterval(15 * 60)))
        w.clock.advance(1)
        try await w.cycle()
        #expect(try w.turns(ceo).count == 1)
        #expect(try w.agent(ceo).state == .blocked)
        w.clock.advance(15 * 60)
        try await w.cycle()
        #expect(try w.turns(ceo).map(\.outcome) == [.usageLimited, .succeeded])
    }

    @Test func futureResetsAtSoonerThanFallbackIsUsed() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let t = w.clock.now
        let soon = RateLimitInfo(status: "rejected", resetsAt: t.addingTimeInterval(5 * 60), rateLimitType: "five_hour",
                                 isUsingOverage: false, fiveHourUtilization: 1.0, sevenDayUtilization: 0.5, observedAt: t)
        w.fake.script("ceo", .init(events: [
            .rateLimit(soon),
            .result(TurnResult(isError: true, subtype: "error_during_execution", text: "usage limit reached",
                               costUSD: nil, apiErrorStatus: 429, sessionId: ceo.sessionId)),
        ]))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.agent(ceo).blocker == .usageLimit(until: t.addingTimeInterval(5 * 60)))
        w.clock.advance(5 * 60)
        try await w.cycle()
        #expect(try w.turns(ceo).map(\.outcome) == [.usageLimited, .succeeded])
    }

    @Test func http429WithoutRateLimitEventClosesGateForEveryone() async throws {
        let w = try World()
        let c1 = try w.company("Acme"); let c2 = try w.company("Beta")
        let a = try w.hire(c1, "ceo"); let b = try w.hire(c2, "ceo")
        w.fake.script("ceo", .init(events: [
            .result(TurnResult(isError: true, subtype: "error_during_execution", text: "429",
                               costUSD: nil, apiErrorStatus: 429, sessionId: a.sessionId)),
        ]))
        try w.dm(c1, a)
        try await w.cycle()
        let until = w.clock.now.addingTimeInterval(15 * 60)
        #expect(try w.agent(a).blocker == .usageLimit(until: until))
        try w.dm(c2, b)
        try await w.cycle()
        #expect(try w.agent(b).blocker == .usageLimit(until: until))
    }

    @Test func unknownRateLimitStatusIsNotSaved() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let garbled = RateLimitInfo(status: "unknown", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                    fiveHourUtilization: nil, sevenDayUtilization: nil, observedAt: w.clock.now)
        w.fake.script("ceo", .init(events: [.rateLimit(garbled)] + [
            .result(TurnResult(isError: false, subtype: "success", text: "ok", costUSD: nil, apiErrorStatus: nil,
                               sessionId: ceo.sessionId)),
        ]))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.store.latestRateLimit() == nil)
        #expect(try w.turns(ceo).map(\.outcome) == [.succeeded])
        #expect(try w.agent(ceo).state == .sleeping)
    }

    @Test func highUtilizationStopsLowButNotMax() async throws {
        let w = try World()
        let low = try w.company("Lowco", mode: .low); let max = try w.company("Maxco", mode: .max)
        let a = try w.hire(low, "ceo"); let b = try w.hire(max, "ceo")
        let t = w.clock.now
        try w.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: t.addingTimeInterval(3600), rateLimitType: "five_hour",
                                                isUsingOverage: false, fiveHourUtilization: 0.85, sevenDayUtilization: 0.2,
                                                observedAt: t))
        try w.dm(low, a); try w.dm(max, b)
        try await w.cycle()
        #expect(try w.turns(a).isEmpty)
        #expect(try w.agent(a).blocker == .usageLimit(until: t.addingTimeInterval(3600)))
        #expect(try w.turns(b).map(\.outcome) == [.succeeded])
    }

    @Test func sevenDayWarningStopsNobody() async throws {
        let w = try World()
        let low = try w.company("Lowco", mode: .low), bal = try w.company("Balco", mode: .balanced)
        let max = try w.company("Maxco", mode: .max)
        let a = try w.hire(low, "ceo"), b = try w.hire(bal, "ceo"), m = try w.hire(max, "ceo")
        let t = w.clock.now
        let warning = RateLimitInfo(status: "allowed_warning", resetsAt: t.addingTimeInterval(3 * 86400), rateLimitType: "seven_day",
                                    isUsingOverage: false, fiveHourUtilization: 0.3, sevenDayUtilization: 0.4, observedAt: t,
                                    fiveHourResetsAt: t.addingTimeInterval(7200), sevenDayResetsAt: t.addingTimeInterval(3 * 86400))
        let router = w.router
        w.fake.script("ceo", .init(events: [
            .initialized(sessionId: a.sessionId, model: "sonnet"),
            .rateLimit(warning),
            .result(TurnResult(isError: false, subtype: "success", text: "done", costUSD: 0.01, apiErrorStatus: nil,
                               sessionId: a.sessionId)),
        ], sideEffect: { _ in _ = try router.sendDM(companyId: low.id, from: .owner, to: "ceo", text: "more", now: t) }))
        try w.dm(low, a)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.succeeded])
        #expect(try w.agent(a).state == .ready, "a warning must not set a usage hold")
        #expect(try w.store.latestRateLimit()?.status == "allowed_warning")
        try w.dm(bal, b); try w.dm(max, m)
        try await w.cycle()
        for x in [a, b, m] {
            #expect(try w.turns(x).last?.outcome == .succeeded)
            #expect(try w.agent(x).state == .sleeping)
        }
        #expect(try w.turns(a).count == 2)
    }

    @Test func lowModeThresholdWaitsForFiveHourResetNotSevenDay() async throws {
        let w = try World()
        let low = try w.company("Lowco", mode: .low); let a = try w.hire(low, "ceo")
        let t = w.clock.now
        try w.store.saveRateLimit(RateLimitInfo(status: "allowed_warning", resetsAt: t.addingTimeInterval(3 * 86400),
                                                rateLimitType: "seven_day", isUsingOverage: false, fiveHourUtilization: 0.85,
                                                sevenDayUtilization: 0.5, observedAt: t,
                                                fiveHourResetsAt: t.addingTimeInterval(7200),
                                                sevenDayResetsAt: t.addingTimeInterval(3 * 86400)))
        try w.dm(low, a)
        try await w.cycle()
        #expect(try w.turns(a).isEmpty)
        #expect(try w.agent(a).blocker == .usageLimit(until: t.addingTimeInterval(7200)))
        w.clock.advance(7200)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.succeeded])
    }

    /// Review focus 3: a limit hit while several turns are in flight lets the others finish, starts nothing new
    /// anywhere until the reset, then resumes.
    @Test func limitHitMidFlightLetsOtherTurnsFinish() async throws {
        let w = try World()
        let c1 = try w.company("Acme", mode: .max); let c2 = try w.company("Beta", mode: .max)
        let a = try w.hire(c1, "alice"); let b = try w.hire(c1, "bob"); let c = try w.hire(c2, "carol")
        let t = w.clock.now
        let rejected = RateLimitInfo(status: "rejected", resetsAt: t.addingTimeInterval(3600), rateLimitType: "five_hour",
                                     isUsingOverage: false, fiveHourUtilization: 1.0, sevenDayUtilization: 0.4, observedAt: t,
                                     fiveHourResetsAt: t.addingTimeInterval(3600))
        w.fake.script("alice", .init(events: [
            .initialized(sessionId: a.sessionId, model: "sonnet"),
            .rateLimit(rejected),
            .result(TurnResult(isError: true, subtype: "error_during_execution", text: "usage limit reached",
                               costUSD: nil, apiErrorStatus: 429, sessionId: a.sessionId)),
        ], delay: .milliseconds(20)))
        w.fake.script("bob", .init(delay: .milliseconds(600)))
        try w.dm(c1, a); try w.dm(c1, b)
        await w.orchestrator.tick()
        #expect(await w.orchestrator.runningCount() == 2)

        let deadline = ContinuousClock.now + .seconds(5)
        while try w.turns(a).first?.outcome == .inProgress, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try w.turns(a).map(\.outcome) == [.usageLimited])
        #expect(try w.turns(b).map(\.outcome) == [.inProgress], "bob must still be mid-turn for this test to mean anything")

        // Gate closed while bob is still running: nothing new starts, in either company.
        try w.dm(c2, c)
        await w.orchestrator.tick()
        #expect(await w.orchestrator.runningCount() == 1)
        #expect(try w.turns(c).isEmpty)
        #expect(try w.agent(c).blocker == .usageLimit(until: t.addingTimeInterval(3600)))

        try await w.orchestrator.waitUntilIdle(timeout: .seconds(5))
        #expect(try w.turns(b).map(\.outcome) == [.succeeded])
        #expect(try w.pending(b) == 0, "bob's items are delivered")
        #expect(try w.agent(b).state == .sleeping)

        try w.dm(c1, b)
        try await w.cycle()
        #expect(try w.turns(b).count == 1)
        #expect(try w.agent(b).blocker == .usageLimit(until: t.addingTimeInterval(3600)))
        #expect(try w.turns(a).count == 1)

        w.clock.advance(3600)
        try await w.cycle()
        #expect(try w.turns(a).map(\.outcome) == [.usageLimited, .succeeded])
        #expect(try w.turns(b).map(\.outcome) == [.succeeded, .succeeded])
        #expect(try w.turns(c).map(\.outcome) == [.succeeded])
    }

    @Test(arguments: [true, false])
    func lostSessionStartsFreshNextTurn(viaResult: Bool) async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        try w.dm(c, ceo); try await w.cycle()
        #expect(try w.agent(ceo).sessionStarted)
        let message = "No conversation found with session ID: \(ceo.sessionId)"
        if viaResult {
            w.fake.script("ceo", .init(events: [.result(TurnResult(isError: true, subtype: "error_during_execution",
                                                                     text: message, costUSD: 0, apiErrorStatus: nil,
                                                                     sessionId: ceo.sessionId))]))
        } else {
            w.fake.script("ceo", .init(events: [], error: TurnError.exitedWithoutResult(code: 1, stderrTail: message + "\n")))
        }
        try w.dm(c, ceo); try await w.cycle()
        let after = try w.agent(ceo)
        #expect(try w.turns(ceo).last?.outcome == .failed)
        #expect(!after.sessionStarted)
        #expect(after.sessionId != ceo.sessionId)
        #expect(try w.pending(ceo) == 1)

        w.clock.advance(30)
        try await w.cycle()
        let req = try #require(w.fake.requests.last)
        let args = ClaudeCommand.arguments(for: req)
        #expect(args.contains("--session-id")); #expect(!args.contains("--resume"))
        #expect(args.contains(after.sessionId))
        #expect(req.appendSystemPrompt?.contains("You are @ceo") == true)
        #expect(try w.agent(ceo).sessionStarted)
        #expect(try w.pending(ceo) == 0)
    }

    @Test func ordinaryFailureKeepsSession() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        try w.dm(c, ceo); try await w.cycle()
        w.fake.script("ceo", .init(events: [], error: FakeError(description: "boom")))
        try w.dm(c, ceo); try await w.cycle()
        let after = try w.agent(ceo)
        #expect(after.sessionStarted); #expect(after.sessionId == ceo.sessionId)
    }

    @Test func killingTheBlockerReleasesWaiters() async throws {
        let w = try World(); let c = try w.company("Acme")
        let ceo = try w.hire(c, "ceo"); let cto = try w.hire(c, "cto")
        let tools = CompanyTools(store: w.store, companyId: c.id, agentId: ceo.id, diagnostics: { _ in })
        w.fake.script("ceo", .init(sideEffect: { _ in
            _ = try tools.call(name: "set_blocked", arguments: ["on": .string("@cto"), "reason": .string("need spec")])
        }))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.agent(ceo).blocker == .agent(cto.id))
        try w.store.transition(agentId: cto.id, to: .killed)
        #expect(try w.agent(ceo).state == .ready)
        #expect(try w.agent(ceo).blocker == nil)
        try await w.cycle()
        #expect(try w.turns(ceo).count == 2)
    }

    @Test func killingTheBlockerMidTurnDropsTheRequest() async throws {
        let w = try World(); let c = try w.company("Acme")
        let ceo = try w.hire(c, "ceo"); let cto = try w.hire(c, "cto")
        let tools = CompanyTools(store: w.store, companyId: c.id, agentId: ceo.id, diagnostics: { _ in })
        let store = w.store
        w.fake.script("ceo", .init(sideEffect: { _ in
            _ = try tools.call(name: "set_blocked", arguments: ["on": .string("@cto"), "reason": .string("need spec")])
            _ = try store.transition(agentId: cto.id, to: .killed)
        }))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.agent(ceo).state == .sleeping)
        #expect(try w.agent(ceo).blocker == nil)
    }

    @Test func turnBudgetBlocksChatterbox() async throws {
        let w = try World(config: World.config(turnBudget: 3)); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let t0 = w.clock.now
        for _ in 0..<3 {
            try w.dm(c, ceo)
            try await w.cycle()
            w.clock.advance(60)
        }
        #expect(try w.turns(ceo).count == 3)
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.turns(ceo).count == 3)
        let a = try w.agent(ceo)
        #expect(a.state == .blocked)
        #expect(a.blocker == .turnBudget(until: t0.addingTimeInterval(3600)))
        #expect(try w.pending(ceo) == 1)

        w.clock.advance(3600)
        try await w.cycle()
        #expect(try w.turns(ceo).count == 4)
    }

    @Test func crashRecoveryRequeues() async throws {
        let dir = try tempDir(); let path = dir.appending(path: "brahma.sqlite").path
        let first = try World(store: Store(path: path))
        let c = try first.company("Acme"); let ceo = try first.hire(c, "ceo")
        try first.dm(c, ceo)
        _ = try first.store.transition(agentId: ceo.id, to: .running)
        let stale = try first.store.startTurn(agentId: ceo.id, now: first.clock.now.addingTimeInterval(-60))

        let w = try World(store: Store(path: path))
        try await w.orchestrator.start()
        #expect(try w.agent(ceo).state == .ready)
        #expect(try w.pending(ceo) == 1)
        #expect(try w.turns(ceo).first { $0.id == stale.id }?.outcome == .interrupted)
        try await w.cycle()
        #expect(try w.turns(ceo).map(\.outcome) == [.interrupted, .succeeded])
        #expect(try w.pending(ceo) == 0)
        #expect(try w.agent(ceo).state == .sleeping)
    }

    @Test func pausedMidTurnSleepsAtTurnEnd() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let store = w.store; let router = w.router; let now = w.clock.now
        w.fake.script("ceo", .init(sideEffect: { _ in
            try store.writer.write { db in
                guard var me = try Agent.fetchOne(db, key: ceo.id) else { return }
                me.paused = true
                try me.update(db, columns: ["paused"])
            }
            _ = try router.sendDM(companyId: c.id, from: .owner, to: "ceo", text: "mid-turn", now: now)
        }))
        try w.dm(c, ceo, "first")
        try await w.cycle()
        let a = try w.agent(ceo)
        #expect(a.state == .sleeping)
        #expect(a.paused)
        #expect(try w.turns(ceo).map(\.outcome) == [.succeeded])
        #expect(try w.store.pendingInbox(agentId: ceo.id).map(\.1.text) == ["mid-turn"])
    }

    @Test func killedMidTurnStaysKilled() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let store = w.store
        w.fake.script("ceo", .init(sideEffect: { _ in _ = try store.transition(agentId: ceo.id, to: .killed) }))
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(try w.agent(ceo).state == .killed)
        #expect(try w.turns(ceo).map(\.outcome) == [.succeeded])
    }

    @Test func capsHonoredUnderLoad() async throws {
        let w = try World(config: World.config(hardCap: 3)); let c = try w.company("Acme", mode: .max)
        var agents: [Agent] = []
        for i in 0..<10 { agents.append(try w.hire(c, "eng\(i)", role: "engineer")) }
        w.fake.defaultScript = .init(delay: .milliseconds(200))
        _ = try w.router.post(companyId: c.id, channel: "general", from: .owner, text: "@here all hands", now: w.clock.now)
        let deadline = ContinuousClock.now + .seconds(10)
        while try agents.contains(where: { try w.turns($0).first?.outcome != .succeeded }), ContinuousClock.now < deadline {
            await w.orchestrator.tick()
            #expect(await w.orchestrator.runningCount() <= 3)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(5))
        #expect(w.fake.maxConcurrent == 3)
        #expect(w.fake.requests.count == 10)
        for a in agents { #expect(try w.turns(a).map(\.outcome) == [.succeeded]) }
    }

    @Test func waitUntilIdleTimesOut() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        w.fake.script("ceo", .init(delay: .milliseconds(300)))
        try w.dm(c, ceo)
        await w.orchestrator.tick()
        #expect(await w.orchestrator.runningCount() == 1)
        await #expect(throws: OrchestratorError.self) { try await w.orchestrator.waitUntilIdle(timeout: .milliseconds(50)) }
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(5))
        #expect(await w.orchestrator.runningCount() == 0)
    }

    // MARK: Work notices

    private func ownedItem(_ w: World, _ c: Company, _ owner: Agent) throws -> WorkItem {
        try w.store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Do it", ownerId: owner.id),
                                   now: w.clock.now)
    }

    private func notice(_ w: World, _ item: WorkItem, _ kind: WorkEventKind, text: String = "x") throws {
        try w.store.writer.write { db in
            _ = try w.store.recordItemEvent(db: db, item: item, actor: "system", kind: kind, text: text, now: w.clock.now)
        }
    }

    @Test func noticeIsDeliveredOnSuccessOnly() async throws {
        let w = try World(); let c = try w.company("Acme"); let eng = try w.hire(c, "eng", role: "engineer")
        let item = try ownedItem(w, c, eng)
        try notice(w, item, .changesRequested, text: "tighten\nthe parser")
        #expect(try w.agent(eng).state == .ready)
        w.fake.script("eng", .init(events: [], error: FakeError(description: "boom")))
        try await w.cycle()
        #expect(try w.agent(eng).state == .blocked, "the failed turn backs off")
        #expect(try w.store.pendingNotices(agentId: eng.id).count == 2, "a failed turn delivers nothing")
        let first = try #require(w.fake.requests.first?.prompt)
        // The actionable notice comes first, then the FYI.
        #expect(first.hasPrefix("Work updates (2):\n- ACME-1 changesRequested by @system: tighten the parser"))
        #expect(first.contains("\n- ACME-1 created by @owner: created task \"Do it\", assigned to @eng"))
        #expect(!first.contains("nothing new"))
        w.clock.advance(30)
        try await w.cycle()
        #expect(w.fake.requests.count == 2); #expect(w.fake.requests[1].prompt == first, "the retry carries the same notices")
        #expect(try w.store.pendingNotices(agentId: eng.id).isEmpty)
        #expect(try w.agent(eng).state == .sleeping)
        let delivered = try await w.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT deliveredTurnId FROM workNotice WHERE agentId = ?", arguments: [eng.id])
        }
        #expect(delivered == [try w.turns(eng).last?.id])
    }

    @Test func noticesRideAlongWithInboxItems() async throws {
        let w = try World(); let c = try w.company("Acme"); let eng = try w.hire(c, "eng", role: "engineer")
        let item = try ownedItem(w, c, eng)
        try notice(w, item, .leaseClaimed)
        #expect(try w.agent(eng).state == .sleeping, "an FYI notice does not wake")
        try w.dm(c, eng, "status?")
        try await w.cycle()
        let prompt = try #require(w.fake.requests.first?.prompt)
        #expect(prompt.hasPrefix("New since your last turn (1 items):"))
        #expect(prompt.contains("\n\nWork updates (2):\n"))
        #expect(try w.store.pendingNotices(agentId: eng.id).isEmpty)
    }

    @Test func pendingNoticeKeepsAgentReady() async throws {
        let w = try World(); let c = try w.company("Acme"); let eng = try w.hire(c, "eng", role: "engineer")
        let item = try ownedItem(w, c, eng)
        let store = w.store, now = w.clock.now
        try w.dm(c, eng)
        // An actionable notice arriving mid-turn: the agent stays ready for another turn.
        w.fake.script("eng", .init(sideEffect: { _ in
            try store.writer.write { db in
                _ = try store.recordItemEvent(db: db, item: item, actor: "system", kind: .verificationFailed, text: "check failed", now: now)
            }
        }))
        try await w.cycle()
        #expect(try w.agent(eng).state == .ready)
        #expect(try w.store.pendingNotices(agentId: eng.id).map(\.event.kind) == [.verificationFailed])
        try await w.cycle()
        #expect(try w.agent(eng).state == .sleeping)
        #expect(w.fake.requests.count == 2); #expect(w.fake.requests[1].prompt.contains("verificationFailed by @system: check failed"))
        // An FYI notice arriving mid-turn does not.
        w.fake.script("eng", .init(sideEffect: { _ in
            try store.writer.write { db in
                _ = try store.recordItemEvent(db: db, item: item, actor: "system", kind: .leaseClaimed, text: "claimed", now: now)
            }
        }))
        try w.dm(c, eng)
        try await w.cycle()
        #expect(try w.agent(eng).state == .sleeping)
        #expect(try w.store.pendingNotices(agentId: eng.id).map(\.event.kind) == [.leaseClaimed], "left for the next turn")
    }

    @Test func debouncedLeadNoticeWakesOnTick() async throws {
        let w = try World(); let c = try w.company("Acme"); let mgr = try w.hire(c, "mgr", role: "manager")
        let item = try ownedItem(w, c, mgr)
        try w.store.advanceActive(companyId: c.id, by: 1000)
        try notice(w, item, .changesRequested)
        try await w.cycle()
        #expect(try w.agent(mgr).state == .sleeping); #expect(w.fake.requests.count == 1)
        try w.store.advanceActive(companyId: c.id, by: 100)
        try notice(w, item, .changesRequested)
        #expect(try w.agent(mgr).state == .sleeping)
        try await w.cycle()
        #expect(w.fake.requests.count == 1, "not due yet")
        try w.store.advanceActive(companyId: c.id, by: 500)
        try await w.cycle()
        #expect(w.fake.requests.count == 2, "the tick woke the lead when the debounce ended")
        #expect(try w.agent(mgr).state == .sleeping); #expect(try w.store.pendingNotices(agentId: mgr.id).isEmpty)
    }
}
