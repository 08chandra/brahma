import Foundation

/// What GitHub says about a pull request, as it goes back to the item's owner agent when a check fails or a reviewer asks for
/// changes (Plan X8 Task 4; spec §8.5.1 step 4, §9.4). The stand-in for S's `ToolOutput`/`Untrusted` (Ruling 2): a PR-local
/// message of parts, each either owner-trusted text (a review by a login on the owner's list, with that login) or
/// `ExternalText`. Check output is always EXTERNAL (machine text, written by whatever runs the check — often a workflow the
/// agent itself changed). Every part is redacted — the redactor's known values and `SecretScan`'s token patterns — before the
/// whole is capped at `cap` bytes. Any EXTERNAL part makes the message EXTERNAL: the agent session that reads it is tainted
/// with `taintSource(number:)` (`Store.relayedTaint`, at the turn's launch).
public enum PRFeedback {
    /// 16 KiB of part text, all parts together, cut on a character boundary with an engine line saying how much was left out.
    public static let cap = 16 * 1024
    /// Check conclusions that bring the item back.
    public static let failingConclusions: Set<String> = ["failure", "timed_out", "cancelled", "action_required"]
    /// Longest check name or login shown in a part's source.
    static let maxName = 100

    public struct Message: Equatable, Sendable {
        public enum Part: Equatable, Sendable {
            /// A review body by a login on the owner's trust list (as GitHub reported the login).
            case trusted(login: String, text: String)
            /// Check output, or a review by anyone else.
            case external(ExternalText)

            var text: String {
                switch self {
                case .trusted(_, let text): text
                case .external(let e): e.text
                }
            }

            func with(text: String) -> Part {
                switch self {
                case .trusted(let login, _): .trusted(login: login, text: text)
                case .external(let e): .external(ExternalText(text: text, source: e.source))
                }
            }
        }

        public var parts: [Part]
        /// Bytes of redacted part text the cap left out (0: nothing was cut).
        public var omittedBytes: Int

        public init(parts: [Part], omittedBytes: Int = 0) { self.parts = parts; self.omittedBytes = omittedBytes }

        /// Some part is EXTERNAL: whoever reads the message reads outside content.
        public var isExternal: Bool {
            parts.contains { if case .external = $0 { true } else { false } }
        }

        /// The message as the agent reads it: every part behind an engine line naming its source and standing, its text quoted
        /// line by line (`    | `); EXTERNAL parts as `UntrustedBlock`s. The cut, if any, is the last (engine) line.
        public var text: String {
            var out: [String] = []
            for part in parts {
                switch part {
                case .trusted(let login, let text):
                    out.append("Review by @\(login), a login the owner trusts:")
                    out.append(contentsOf: PRFeedback.quoted(text))
                case .external(let e):
                    out.append(UntrustedBlock.render(source: e.source, text: e.text, maxLines: Int.max))
                }
            }
            if omittedBytes > 0 {
                out.append("[cut by Brahma: \(omittedBytes) more bytes of GitHub feedback not shown (cap \(PRFeedback.cap) bytes)]")
            }
            return out.joined(separator: "\n")
        }
    }

    /// The feedback for the failing `checks` and the `reviews` to bring back, in that order. Throws
    /// `SecretError.secretsNotLoaded` while the redactor has not completed a load (fail closed: nothing unredacted goes out).
    public static func make(checks: [GitHubCheckRun], reviews: [GitHubReview], trust: TrustList, redactor: Redactor) throws -> Message {
        guard redactor.hasLoaded else { throw SecretError.secretsNotLoaded }
        func redacted(_ text: String) -> String {
            ContentScan.redact(text: redactor.apply(text), findings: [], knownValues: [])
        }
        var all: [Message.Part] = []
        for check in checks {
            let output = [check.title, check.summary, check.text].filter { !$0.isEmpty }.joined(separator: "\n")
            let name = redacted(shownName(check.name)), outcome = shownName(check.conclusion ?? check.status)
            all.append(.external(ExternalText(text: redacted(output), source: "GitHub check \"\(name)\" (\(outcome))")))
        }
        for review in reviews {
            let login = shownName(review.user.login)
            if trust.isTrusted(login: review.user.login) {
                all.append(.trusted(login: login, text: redacted(review.body)))
            } else {
                all.append(.external(ExternalText(text: redacted(review.body),
                                                  source: "GitHub review by @\(login) (\(shownName(review.state)))")))
            }
        }
        // The cap, after redaction: a secret straddling the cut was replaced whole before it.
        var budget = cap, omitted = 0
        var kept: [Message.Part] = []
        for part in all {
            let bytes = part.text.utf8.count
            if bytes <= budget {
                kept.append(part)
                budget -= bytes
            } else if budget > 0 {
                let cut = prefix(part.text, utf8Bytes: budget)
                kept.append(part.with(text: cut))
                omitted += bytes - cut.utf8.count
                budget = 0
            } else {
                omitted += bytes
            }
        }
        return Message(parts: kept, omittedBytes: omitted)
    }

    // MARK: Delivery

    /// The taint source of PR #`number`'s feedback, and the first line of the item event that carries it.
    public static func taintSource(number: Int) -> String { "github: PR #\(number) feedback" }

    /// The `prFeedback` item event's text: the engine's source line, then the message.
    static func eventText(number: Int, message: Message) -> String {
        taintSource(number: number) + "\n" + message.text
    }

    /// The source line of a `prFeedback` event's text (only the engine writes that kind), or nil when the first line is not one.
    static func taintSource(ofEventText text: String) -> String? {
        let first = String(text.prefix { $0 != "\n" })
        guard first.range(of: #"^github: PR #[1-9][0-9]{0,9} feedback$"#, options: .regularExpression) != nil else { return nil }
        return first
    }

    // MARK: Text

    /// A name GitHub (or a workflow) chose, on one line (no control or bidi characters), without double quotes, at most
    /// `maxName` characters.
    static func shownName(_ name: String) -> String {
        ReviewDigest.flat(name.replacingOccurrences(of: "\"", with: "'"), max: maxName)
    }

    /// `text` line by line behind `    | ` (control characters but tabs shown as spaces), as `UntrustedBlock` quotes.
    static func quoted(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            "    | " + String(String.UnicodeScalarView(line.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) && $0 != "\t" ? " " : $0
            }))
        }
    }

    /// The longest prefix of `text` that is whole characters and at most `n` UTF-8 bytes.
    static func prefix(_ text: String, utf8Bytes n: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard used + size <= n else { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
