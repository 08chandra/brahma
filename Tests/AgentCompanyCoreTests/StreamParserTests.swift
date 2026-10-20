import Foundation
import Testing
@testable import AgentCompanyCore

private let sessionId = "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0"

private func fixtureLines(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
}

@Suite struct StreamParserTests {
    @Test func parsesInitLine() throws {
        let lines = try fixtureLines("stream-success")
        #expect(StreamParser.parse(line: lines[0]) == .initialized(sessionId: sessionId, model: "claude-haiku-5-5"))
    }

    @Test func parsesAssistantText() throws {
        let lines = try fixtureLines("stream-success")
        #expect(StreamParser.parse(line: lines[1]) == .assistantText("ok"))
    }

    @Test func parsesRateLimitEvent() throws {
        let lines = try fixtureLines("stream-success")
        let event = try #require(StreamParser.parse(line: lines[2], now: Date(timeIntervalSince1970: 0)))
        guard case .rateLimit(let info) = event else {
            Issue.record("expected .rateLimit, got \(event)")
            return
        }
        #expect(info.status == "allowed")
        #expect(info.resetsAt == Date(timeIntervalSince1970: 1792522800))
        #expect(info.rateLimitType == "five_hour")
        #expect(info.isUsingOverage == false)
        #expect(info.fiveHourUtilization == 0.38)
        #expect(info.sevenDayUtilization == 0.12)
        #expect(info.observedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func parsesSuccessfulResult() throws {
        let lines = try fixtureLines("stream-success")
        let event = try #require(StreamParser.parse(line: lines[3]))
        guard case .result(let result) = event else {
            Issue.record("expected .result, got \(event)")
            return
        }
        #expect(result.isError == false)
        #expect(result.subtype == "success")
        #expect(result.text == "ok")
        #expect(result.costUSD == 0.00098121)
        #expect(result.apiErrorStatus == nil)
        #expect(result.sessionId == sessionId)
    }

    @Test func parsesRateLimitedRun() throws {
        let lines = try fixtureLines("stream-ratelimited")
        guard case .rateLimit(let info) = try #require(StreamParser.parse(line: lines[1])) else {
            Issue.record("expected .rateLimit")
            return
        }
        #expect(info.status == "rejected")
        #expect(info.fiveHourUtilization == 1.0)

        guard case .result(let result) = try #require(StreamParser.parse(line: lines[2])) else {
            Issue.record("expected .result")
            return
        }
        #expect(result.isError == true)
        #expect(result.apiErrorStatus == 429)
        #expect(result.text == "usage limit reached")
    }

    @Test func blankAndNonJSONLinesReturnNil() {
        #expect(StreamParser.parse(line: "") == nil)
        #expect(StreamParser.parse(line: "not json") == nil)
    }

    @Test func unknownTypeIsOther() {
        #expect(StreamParser.parse(line: #"{"type":"hook_started"}"#) == .other(type: "hook_started"))
    }

    @Test func nonInitSystemSubtypeIsOther() {
        #expect(StreamParser.parse(line: #"{"type":"system","subtype":"hook_started"}"#) == .other(type: "system"))
    }

    @Test func toolUseBlockWinsOverText() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"posting"},{"type":"tool_use","name":"mcp__company__post_message","input":{}}]}}"#
        #expect(StreamParser.parse(line: line) == .toolUse(name: "mcp__company__post_message"))
    }

    @Test func concatenatesTextBlocks() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}"#
        #expect(StreamParser.parse(line: line) == .assistantText("ab"))
    }
}
