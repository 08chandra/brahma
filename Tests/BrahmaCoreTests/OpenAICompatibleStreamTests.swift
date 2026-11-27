import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Task 10: `OpenAICompatibleStream`, the state machine from Chat Completions SSE chunks to Messages stream events —
/// tool calls accumulated by index, usage only from the final chunk (Ruling X1-37), every bound enforced (Review Focus 3),
/// and the event order `claude` requires (inventory (d)).
@Suite(.scratch, .serialized) struct OpenAICompatibleStreamTests {
    static let fixtures = ["stream-text", "stream-tool-call", "stream-interleaved", "stream-no-usage"]

    /// An SSE body of `data:` lines, ended by `[DONE]` unless `done` is false.
    static func sse(_ chunks: [String], done: Bool = true) -> Data {
        Data((chunks.map { "data: \($0)\n\n" }.joined() + (done ? "data: [DONE]\n\n" : "")).utf8)
    }

    /// Feeds `body` in `size`-byte chunks, then its end.
    static func run(_ body: Data, chunk size: Int = 7) -> (events: [CanonicalStreamEvent], stream: OpenAICompatibleStream) {
        var stream = OpenAICompatibleStream()
        var events: [CanonicalStreamEvent] = []
        var offset = 0
        while offset < body.count, !stream.isEnded {
            events += stream.feed(body.subdata(in: offset..<min(body.count, offset + size)), redact: OpenAIFixture.redact)
            offset += size
        }
        events += stream.end(redact: OpenAIFixture.redact)
        return (events, stream)
    }

    /// What a client reads from the events.
    struct Reading: Equatable {
        var text = ""
        var tools: [Tool] = []
        var stopReason: String?
        var usage: GatewayUsage?
        var errors: [String] = []

        struct Tool: Equatable {
            var id: String
            var name: String
            var input: String
        }
    }

    static func read(_ events: [CanonicalStreamEvent]) -> Reading {
        var r = Reading()
        for event in events {
            switch event {
            case .contentBlockStart(_, let block) where block.objectValue?["type"] == .string("tool_use"):
                r.tools.append(.init(id: block.objectValue?["id"]?.stringValue ?? "", name: block.objectValue?["name"]?.stringValue ?? "", input: ""))
            case .contentBlockDelta(_, let delta):
                if let text = delta.objectValue?["text"]?.stringValue { r.text += text }
                if let json = delta.objectValue?["partial_json"]?.stringValue, !r.tools.isEmpty { r.tools[r.tools.count - 1].input += json }
            case .messageDelta(let stop, let usage):
                r.stopReason = stop
                r.usage = usage
            case .error(let type, let message):
                r.errors.append("\(type): \(message)")
            default:
                break
            }
        }
        return r
    }

    /// Why `events` break `message_start (content_block_start delta* content_block_stop)* message_delta message_stop` (block
    /// indices 0, 1, 2… in order), or nil.
    static func orderingViolation(_ events: [CanonicalStreamEvent]) -> String? {
        guard case .messageStart = events.first else { return "the first event is not message_start" }
        var i = 1
        var expected = 0
        while i < events.count, case .contentBlockStart(let index, _) = events[i] {
            guard index == expected else { return "block \(index) where \(expected) was due" }
            i += 1
            while i < events.count, case .contentBlockDelta(let d, _) = events[i] {
                guard d == index else { return "a delta for block \(d) inside block \(index)" }
                i += 1
            }
            guard i < events.count, case .contentBlockStop(let s) = events[i], s == index else { return "block \(index) is not stopped next" }
            i += 1
            expected += 1
        }
        guard i < events.count, case .messageDelta = events[i] else { return "no message_delta after the blocks" }
        guard i + 1 < events.count, case .messageStop = events[i + 1] else { return "no message_stop after message_delta" }
        return i + 2 == events.count ? nil : "events after message_stop"
    }

    /// A tool call whose arguments arrive one byte per delta (and the body itself one byte per chunk) becomes one `tool_use`
    /// with exactly the input sent — a 20-digit integer and a long decimal included.
    @Test func toolCallSplitAcrossChunks() {
        let arguments = #"{"path":"a b.txt","n":12345678901234567890,"r":0.1234567890123456789012345678901,"u":"é😀"}"#
        var chunks = [#"{"id":"c1","model":"gpt-5.5","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"Read","arguments":""}}]}}]}"#]
        for scalar in arguments.unicodeScalars {
            let piece = String(String.UnicodeScalarView([scalar]))
            let escaped = piece.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            chunks.append(#"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\#(escaped)"}}]}}]}"#)
        }
        chunks.append(#"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#)
        chunks.append(#"{"id":"c1","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":9}}"#)
        for size in [1, 3, 4096] {
            let (events, stream) = Self.run(Self.sse(chunks), chunk: size)
            let r = Self.read(events)
            #expect(r.tools == [.init(id: "call_1", name: "Read", input: arguments)], "chunk \(size): \(r.tools)")
            #expect(r.stopReason == "tool_use" && r.errors.isEmpty)
            #expect(Self.orderingViolation(events) == nil)
            #expect(stream.outcome == UsageOutcome(usage: GatewayUsage(inputTokens: 7, outputTokens: 9, cacheReadTokens: 0, cacheWriteTokens: 0),
                                                   complete: true))
        }
    }

    /// Two calls whose deltas interleave become two `tool_use` blocks, in the order the calls began, each with its own input.
    @Test func interleavedToolCalls() throws {
        let (events, stream) = Self.run(try OpenAIFixture.data("stream-interleaved", "sse"))
        let r = Self.read(events)
        #expect(r.tools == [.init(id: "call_a", name: "Read", input: #"{"file_path":"a.txt"}"#),
                            .init(id: "call_b", name: "Grep", input: #"{"pattern":"TODO","n":12345678901234567890}"#)])
        #expect(r.stopReason == "tool_use" && r.text.isEmpty)
        #expect(Self.orderingViolation(events) == nil)
        // The usage rode on the finish chunk: final.
        #expect(stream.outcome.complete && stream.outcome.usage?.inputTokens == 90)
    }

    /// The final usage chunk (after the finish reason) is the usage, final after `[DONE]`: cached prompt tokens are cache
    /// reads. Usage seen only before the finish reason, or a stream cut after it, is not final.
    @Test func usageFromFinalChunk() throws {
        let (events, stream) = Self.run(try OpenAIFixture.data("stream-text", "sse"))
        let usage = GatewayUsage(inputTokens: 30, outputTokens: 3, cacheReadTokens: 20, cacheWriteTokens: 0)
        #expect(Self.read(events) == Reading(text: "Hello.", stopReason: "end_turn", usage: usage))
        #expect(stream.outcome == UsageOutcome(usage: usage, complete: true))

        let early = Self.sse([#"{"choices":[{"index":0,"delta":{"content":"x"}}],"usage":{"prompt_tokens":5,"completion_tokens":1}}"#,
                              #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#])
        let (_, earlyStream) = Self.run(early)
        #expect(earlyStream.outcome == UsageOutcome(usage: GatewayUsage(inputTokens: 5, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0),
                                                    complete: false), "usage before the finish reason is not the terminal report")

        // Cut after the usage chunk but before [DONE] (the reader stops): not ended, so not final.
        var cut = OpenAICompatibleStream()
        let body = try OpenAIFixture.text("stream-text", "sse")
        _ = cut.feed(Data(body.replacingOccurrences(of: "data: [DONE]\n\n", with: "").utf8), redact: OpenAIFixture.redact)
        #expect(cut.outcome.usage == usage && !cut.outcome.complete)
        // …while the body's own end, after the finish reason and usage, is a normal end.
        #expect(cut.end(redact: OpenAIFixture.redact).last == .messageStop && cut.outcome.complete)
    }

    /// No usage chunk: the usage is nil (the meter charges the estimate); the client still gets a whole, ordered stream.
    @Test func noUsageIsNil() throws {
        let (events, stream) = Self.run(try OpenAIFixture.data("stream-no-usage", "sse"))
        #expect(stream.outcome == UsageOutcome(usage: nil, complete: false))
        #expect(Self.read(events).text == "Hi." && Self.orderingViolation(events) == nil)
        #expect(Self.read(events).usage == OpenAICompatibleStream.zeroUsage, "claude sees zero counts, never a negative or missing one")
    }

    /// Review Focus 3: a hostile or broken provider stream ends the reply with an `error` event, holds bounded memory (checked
    /// through the bound counters, not RSS), stops being read, and leaves no final usage (the meter charges the estimate).
    @Test func hostileStreamsAreBounded() {
        #expect(OpenAICompatibleStream.maxLineBytes == 1 << 20 && OpenAICompatibleStream.maxToolArgumentBytes == 4 << 20
                    && OpenAICompatibleStream.maxStreamBytes == 64 << 20)
        func feed(_ stream: inout OpenAICompatibleStream, _ chunk: Data, times: Int) -> (events: [CanonicalStreamEvent], fed: Int) {
            var events: [CanonicalStreamEvent] = []
            var fed = 0
            for _ in 0..<times where !stream.isEnded {
                events += stream.feed(chunk, redact: OpenAIFixture.redact)
                fed += chunk.count
            }
            return (events, fed)
        }
        // Values are copied out before each expectation: a failure must never render a stream holding megabytes.
        func assertEnded(_ stream: OpenAICompatibleStream, _ events: [CanonicalStreamEvent], _ message: String, _ label: String) {
            let ended = stream.isEnded, final = stream.outcome.complete, last = events.last
            #expect(ended, "\(label)")
            #expect(last == .error(type: "overloaded_error", message: message) || last == .error(type: "api_error", message: message),
                    "\(label): \(String(describing: last))")
            #expect(!final, "\(label)")
        }

        // A 50 MB event: refused at 1 MiB, never buffered beyond it, and not read further.
        var big = OpenAICompatibleStream()
        let head = big.feed(Data(#"data: {"choices":[{"index":0,"delta":{"content":""#.utf8), redact: OpenAIFixture.redact)
        let (bigEvents, bigFed) = feed(&big, Data(repeating: UInt8(ascii: "a"), count: 64 << 10), times: (50 << 20) >> 16)
        assertEnded(big, head + bigEvents, "Brahma: provider stream exceeded 1 MiB per line", "50 MB event")
        let bigPeak = big.peakBufferedBytes
        #expect(bigPeak <= OpenAICompatibleStream.maxLineBytes && bigFed <= OpenAICompatibleStream.maxLineBytes + (64 << 10), "peak \(bigPeak), fed \(bigFed)")

        // Tool-call arguments past 4 MiB, in lines each under 1 MiB.
        var args = OpenAICompatibleStream()
        let piece = String(repeating: "a", count: 512 << 10)
        let line = Self.sse([#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"x","arguments":"\#(piece)"}}]}}]}"#], done: false)
        let (argEvents, _) = feed(&args, line, times: 20)
        assertEnded(args, argEvents, "Brahma: provider stream exceeded 4 MiB of tool-call arguments", "arguments")
        let argsPeak = args.peakBufferedBytes, argsHeld = args.toolBytes
        #expect(argsPeak <= OpenAICompatibleStream.maxToolArgumentBytes + OpenAICompatibleStream.maxLineBytes, "peak \(argsPeak)")
        #expect(argsHeld == 0, "what was held is dropped")

        // More tool calls than allowed.
        var many = OpenAICompatibleStream()
        let calls = (0...OpenAICompatibleStream.maxToolCalls).map { #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":\#($0),"function":{"name":"x"}}]}}]}"# }
        let manyEvents = many.feed(Self.sse(calls, done: false), redact: OpenAIFixture.redact)
        assertEnded(many, manyEvents, "Brahma: provider stream exceeded \(OpenAICompatibleStream.maxToolCalls) tool calls", "tool calls")

        // A stream that never ends sends keep-alives for ever: cut at 64 MiB in all, each line well under 1 MiB.
        var endless = OpenAICompatibleStream()
        let comments = Data(String(repeating: ":" + String(repeating: "x", count: (64 << 10) - 2) + "\n", count: 16).utf8)
        let (endlessEvents, endlessFed) = feed(&endless, comments, times: 100)
        assertEnded(endless, endlessEvents, "Brahma: provider stream exceeded 64 MiB", "endless")
        let endlessPeak = endless.peakBufferedBytes
        #expect(endlessFed == OpenAICompatibleStream.maxStreamBytes + comments.count && endlessPeak < 64 << 10, "fed \(endlessFed), peak \(endlessPeak)")

        // Invalid UTF-8 inside a chunk, a chunk that is not JSON, a repeated key: malformed.
        var invalidUTF8 = Data(#"data: {"choices":[{"index":0,"delta":{"content":""#.utf8)
        invalidUTF8.append(contentsOf: [0xff, 0xfe])
        invalidUTF8.append(contentsOf: Array("\"}}]}\n\n".utf8))
        let malformedLines: [String] = ["data: {not json}", #"data: {"choices":[],"choices":[]}"#, #"data: {"choices":{"index":0}}"#,
                                        #"data: {"choices":[{"index":0,"delta":{"content":7}}]}"#, "data: [1]"]
        let badBodies: [Data] = [invalidUTF8] + malformedLines.map { Data(($0 + "\n").utf8) }
        for bad in badBodies {
            var s = OpenAICompatibleStream()
            let events = s.feed(bad, redact: OpenAIFixture.redact)
            assertEnded(s, events, "Brahma: the provider stream is malformed", String(decoding: bad.prefix(40), as: UTF8.self))
        }

        // A usage claiming −5 or 10¹² tokens (or a fraction, or cache reads above the prompt): no usage at all, so the meter
        // charges the estimate; the client sees zero counts.
        for usage in [#"{"prompt_tokens":-5,"completion_tokens":1}"#, #"{"prompt_tokens":1000000000000,"completion_tokens":1}"#,
                      #"{"prompt_tokens":5,"completion_tokens":1.5}"#, #"{"prompt_tokens":5,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":6}}"#,
                      #"{"prompt_tokens":"5","completion_tokens":1}"#, #"{"completion_tokens":1}"#] {
            let (events, stream) = Self.run(Self.sse([#"{"choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"stop"}]}"#,
                                                      #"{"choices":[],"usage":\#(usage)}"#]))
            let outcome = stream.outcome
            #expect(outcome == .none, "\(usage)")
            #expect(Self.read(events).usage == OpenAICompatibleStream.zeroUsage && Self.orderingViolation(events) == nil, "\(usage)")
        }

        // [DONE] before any content, or the body ending before a finish reason: an error, no usage.
        for body in [Self.sse([]), Self.sse([#"{"choices":[{"index":0,"delta":{"content":"half"}}]}"#], done: false),
                     Self.sse([#"{"choices":[{"index":0,"delta":{"content":"half"}}]}"#])] {
            let (events, stream) = Self.run(body)
            #expect(events.last == .error(type: "api_error", message: "Brahma: the provider stream ended before its finish reason"))
            let final = stream.outcome.complete
            #expect(!final)
        }
        #expect(Self.run(Self.sse([])).events == [.error(type: "api_error", message: "Brahma: the provider stream ended before its finish reason")])

        // A provider error chunk mid-stream is relayed as an error, redacted.
        let (errorEvents, _) = Self.run(Self.sse([#"{"choices":[{"index":0,"delta":{"content":"x"}}]}"#,
                                                  #"{"error":{"message":"bad key \#(OpenAIFixture.key)","type":"auth"}}"#]))
        #expect(errorEvents.last == .error(type: "api_error", message: "Brahma: the provider stream failed: auth: bad key [redacted]"))

        // Nothing is read once the stream has ended.
        var after = OpenAICompatibleStream()
        _ = after.feed(Self.sse([]), redact: OpenAIFixture.redact)
        let afterEnded = after.isEnded
        #expect(afterEnded && after.feed(Data("data: {}\n".utf8), redact: OpenAIFixture.redact).isEmpty && after.end(redact: OpenAIFixture.redact).isEmpty && after.fail().isEmpty)
    }

    /// The adapter stops reading a hostile stream at its bound and drops the upstream body (the transfer is cancelled).
    @Test func adapterStopsReadingAtABound() async throws {
        let rig = try ReplyRig()
        let feed = UpstreamFeed()
        let start = #"data: {"choices":[{"index":0,"delta":{"content":""#
        feed.send(start)
        let filler = String(repeating: "a", count: 256 << 10)
        for _ in 0..<8 { feed.send(filler) }
        let outcome = try await OpenAICompatibleAdapter().translate(status: 200, headers: ["content-type": "text/event-stream"], body: feed.stream,
                                                                     streamed: true, into: rig.reply, redact: OpenAIFixture.redact)
        #expect(outcome == .none)
        rig.finish()
        let response = try await rig.peer.readResponse()
        #expect(response.status == 200 && response.text == String(decoding: CanonicalStreamEvent.error(
            type: "overloaded_error", message: "Brahma: provider stream exceeded 1 MiB per line").sse(), as: UTF8.self))
    }

    /// A stream that never ends is left when the task is cancelled (the gateway's cut), with no final usage.
    @Test func neverEndingStreamStopsWhenCancelled() async throws {
        let rig = try ReplyRig()
        let feed = UpstreamFeed()
        feed.send("data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"}}]}\n\n")
        let reply = rig.reply
        let task = Task {
            try await OpenAICompatibleAdapter().translate(status: 200, headers: ["content-type": "text/event-stream"], body: feed.stream,
                                                          streamed: true, into: reply, redact: OpenAIFixture.redact)
        }
        let head = try await rig.peer.readHead()
        #expect(head.status == 200)
        task.cancel()
        #expect(try await task.value == .none)
        rig.finish()
    }

    /// The upstream fails midway: the reply ends with an `error` event, and the usage is not final.
    @Test func upstreamFailureMidStreamEndsWithError() async throws {
        let rig = try ReplyRig()
        let feed = UpstreamFeed()
        feed.send("data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}\n\n")
        // The chunk is read first, then the failure (a stream delivers what it buffered before it throws).
        feed.fail()
        let outcome = try await OpenAICompatibleAdapter().translate(status: 200, headers: ["content-type": "text/event-stream"], body: feed.stream,
                                                                     streamed: true, into: rig.reply, redact: OpenAIFixture.redact)
        #expect(outcome.complete == false && outcome.usage?.inputTokens == 3)
        rig.finish()
        let response = try await rig.peer.readResponse()
        #expect(response.text.hasSuffix(String(decoding: CanonicalStreamEvent.error(type: "api_error", message: "Brahma: the provider stream failed").sse(),
                                               as: UTF8.self)), "\(response.text)")
    }

    /// For every stream fixture, fed whole, one byte at a time or in 7-byte chunks: `message_start (content_block_start
    /// delta* content_block_stop)* message_delta message_stop` (X1-0). The checker itself rejects a broken order.
    @Test func streamEventsSatisfyClaudeOrdering() throws {
        for name in Self.fixtures {
            let body = try OpenAIFixture.data(name, "sse")
            for size in [1, 7, body.count] {
                let (events, _) = Self.run(body, chunk: size)
                #expect(Self.orderingViolation(events) == nil, "\(name) / \(size): \(Self.orderingViolation(events) ?? "")")
            }
        }
        let textThenTools = Self.sse([#"{"choices":[{"index":0,"delta":{"content":"a"}}]}"#,
                                      #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"t","function":{"name":"x","arguments":"{}"}}]}}]}"#,
                                      #"{"choices":[{"index":0,"delta":{"content":"b"}}]}"#,
                                      #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#])
        let (mixed, _) = Self.run(textThenTools)
        #expect(Self.orderingViolation(mixed) == nil)
        #expect(Self.read(mixed).text == "ab" && Self.read(mixed).tools.count == 1)

        let start = CanonicalStreamEvent.messageStart(id: "m", model: "m", usage: OpenAICompatibleStream.zeroUsage)
        let text = JSONValue.object(["type": .string("text"), "text": .string("")])
        for broken: [CanonicalStreamEvent] in [
            [.messageDelta(stopReason: "end_turn", usage: nil), .messageStop],
            [start, .contentBlockStart(index: 0, block: text), .messageDelta(stopReason: "end_turn", usage: nil), .messageStop],
            [start, .contentBlockStart(index: 1, block: text), .contentBlockStop(index: 1), .messageDelta(stopReason: nil, usage: nil), .messageStop],
            [start, .contentBlockStart(index: 0, block: text), .contentBlockStart(index: 1, block: text), .contentBlockStop(index: 0),
             .contentBlockStop(index: 1), .messageDelta(stopReason: nil, usage: nil), .messageStop],
            [start, .messageDelta(stopReason: nil, usage: nil)],
            [start, .messageDelta(stopReason: nil, usage: nil), .messageStop, .messageStop],
        ] {
            #expect(Self.orderingViolation(broken) != nil, "\(broken)")
        }
    }

    /// Stream goldens: what the client reads for the text and tool-call fixtures, byte for byte.
    @Test func streamGoldens() async throws {
        for name in ["stream-text", "stream-tool-call"] {
            let (outcome, error, response) = try await OpenAICompatibleAdapterTests.respond(try OpenAIFixture.data(name, "sse"),
                                                                                             contentType: "text/event-stream", streamed: true)
            #expect(error == nil && outcome?.complete == true, "\(name)")
            #expect(response?.head.headers["content-type"] == "text/event-stream")
            let expected = try OpenAIFixture.text("\(name).expected", "sse")
            #expect(response?.text == expected, "\(name):\n\(response?.text ?? "")")
        }
    }
}
