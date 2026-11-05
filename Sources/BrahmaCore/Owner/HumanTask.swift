import Foundation

/// The engine's human-task templates (Plan L Task 9): exact copy, links and paste-back fields written here, never by an agent.
public enum HumanTaskTemplate: String, Codable, CaseIterable, Sendable {
    case hostingAccount = "hosting-account"
    case domain
    case stripeTestKeys = "stripe-test-keys"
    case launchPost = "launch-post"
}

/// A link on a human task: always `https`, shown to the owner as its host plus an Open button.
public struct HumanTaskLink: Codable, Equatable, Sendable {
    public var title: String
    /// https only (`HumanTasks.isValidLink`).
    public var url: String

    public init(title: String, url: String) { self.title = title; self.url = url }

    /// The host the link opens (what the card and the CLI show next to it).
    public var host: String { URLComponents(string: url)?.host ?? "" }
}

/// One paste-back field. `secretEngine` and `secretTest` values go to the vault (engine-held or a test key) and are never
/// stored anywhere else; `text` and `url` values are recorded on the ask and shown to agents.
public struct HumanTaskField: Codable, Equatable, Sendable {
    public var name: String
    public var label: String
    public var kind: Kind
    public var required: Bool
    public var prefix: String?
    /// A regular expression the whole (trimmed) value must match.
    public var pattern: String?

    public enum Kind: String, Codable, Sendable { case secretEngine, secretTest, text, url }

    public init(name: String, label: String, kind: Kind, required: Bool, prefix: String? = nil, pattern: String? = nil) {
        self.name = name; self.label = label; self.kind = kind; self.required = required; self.prefix = prefix; self.pattern = pattern
    }

    public var isSecret: Bool { kind == .secretEngine || kind == .secretTest }
}

/// What the owner is asked to do, stored as JSON in the ask's `AskPayload.details`. `template` is nil for a custom task (an
/// agent's, which may only carry links and url fields).
public struct HumanTask: Codable, Equatable, Sendable {
    public var template: HumanTaskTemplate?
    public var title: String
    public var steps: [String]
    public var links: [HumanTaskLink]
    public var fields: [HumanTaskField]
    public var postText: String?

    public init(template: HumanTaskTemplate?, title: String, steps: [String], links: [HumanTaskLink], fields: [HumanTaskField],
                postText: String? = nil) {
        self.template = template; self.title = title; self.steps = steps; self.links = links; self.fields = fields
        self.postText = postText
    }

    /// The task an ask carries, or nil (not a human task, or details that do not decode).
    public static func from(_ ask: Ask) -> HumanTask? {
        guard ask.kind == .humanTask, let details = ask.payload?.details else { return nil }
        return try? JSONDecoder().decode(HumanTask.self, from: Data(details.utf8))
    }

    /// Sorted-key JSON, slashes unescaped (what `AskPayload.details` stores).
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum HumanTaskPolicy {
    public static let maxSteps = 12
    public static let maxStepChars = 300
    public static let maxLinks = 6
    public static let maxFields = 6
    public static let maxPost = 3000
    /// Shown above a custom task's fields (builder-check 11): what is typed there is visible to agents.
    public static let customFieldCaption = "Values you enter here are shown to agents. Never paste a key or password."

    // Refusals (`WorkError.invalid`), exact.
    public static let linksMessage = "links must start with https://"
    public static let customFieldsMessage = "custom human tasks can only ask for links (url fields); use a template, or request_from_owner for anything else"
    public static let capsMessage = "a human task has at most 12 steps of 300 characters, 6 links and 6 fields"
    public static let fieldNamesMessage = "field names must be UPPER_SNAKE (keys) or lower_snake"
    public static let launchPostURLMessage = "launch-post url must start with https://"
    public static let postMessage = "the post text is at most 3000 characters"
    public static let liveStripeMessage = "that's a live Stripe key; paste the test key (sk_test_…)"
    public static let domainMessage = "the domain must be a lowercase hostname like example.com"
    /// Link addresses are plain ASCII, so the host the owner sees is the host the link opens (no look-alike letters).
    public static let asciiLinkMessage = "link addresses must be plain ASCII (punycode for international domains)"
    /// A link title or field label is at most this long (longer ones are cut).
    public static let maxLabel = 100
    /// An agent's (custom) link, or a URL the owner or an agent types, is at most this long.
    public static let maxLink = 2048
    /// A link the engine builds from a template: a 3000-character post percent-encodes to at most 12 characters each (a
    /// 4-byte character), plus the url and the fixed prefix (fix round 1, I3).
    public static let maxEngineLink = maxPost * 12 + maxLink + 200
    public static let linkLengthMessage = "a link is longer than 2048 characters"
    /// What a human task's JSON (its `AskPayload.details`) may take: a full launch post and its three engine links.
    public static let maxDetails = 200_000

    /// The tainted-session rule's refusal (chief review L4).
    public static let taintedRefusal = "This session has read outside content, so request_human_task can only file a template without links; your next turn starts a fresh session where custom tasks work again."
}

public enum HumanTasks {
    // MARK: Templates

    /// The template's task, from engine copy. `hosting` decides the provider (the default when nil) and the project (the
    /// company's slug when nil). Unknown `args` are refused.
    public static func render(_ t: HumanTaskTemplate, company: Company, hosting: HostingSettings?, args: [String: String]) throws -> HumanTask {
        let provider = hosting?.provider ?? .default
        let project = hosting?.project ?? company.slug
        let allowed: Set<String> = switch t {
        case .hostingAccount, .stripeTestKeys: []
        case .domain: ["domain"]
        case .launchPost: ["text", "url"]
        }
        if let unknown = args.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw WorkError.invalid("\(t.rawValue) takes no argument \(Store.flat(unknown, max: 40))"
                                    + (allowed.isEmpty ? "" : " (it takes \(allowed.sorted().joined(separator: ", ")))"))
        }
        let task: HumanTask
        switch t {
        case .hostingAccount: task = hostingAccount(provider)
        case .domain: task = try domain(provider: provider, project: project, domain: args["domain"])
        case .stripeTestKeys: task = stripeTestKeys
        case .launchPost: task = try launchPost(text: args["text"], url: args["url"])
        }
        try validate(task, custom: false)
        return task
    }

    static func hostingAccount(_ provider: HostingProviderID) -> HumanTask {
        let token = HostingAdapters.adapter(provider).tokenSecret
        switch provider {
        case .cloudflarePages:
            return HumanTask(template: .hostingAccount, title: "Create a Cloudflare account and an API token", steps: [
                "Sign up or log in.",
                "Create Token → Custom token → Permissions: Account · Cloudflare Pages · Edit → Continue → Create.",
                "Copy the token into the field below. It goes to your Mac's Keychain; agents never see it.",
                "Copy your Account ID (Workers & Pages → right sidebar) into the field below.",
            ], links: [
                HumanTaskLink(title: "Sign up", url: "https://dash.cloudflare.com/sign-up"),
                HumanTaskLink(title: "API tokens", url: "https://dash.cloudflare.com/profile/api-tokens"),
            ], fields: [
                HumanTaskField(name: token, label: "Cloudflare API token", kind: .secretEngine, required: true),
                HumanTaskField(name: "account_id", label: "Account ID", kind: .text, required: true, pattern: "^[0-9a-f]{32}$"),
            ])
        case .vercel:
            // Deploys need the team or account ID too (PR-15: `VERCEL_ORG_ID`; `proposeDeploy` refuses without it), so the
            // Vercel task asks for it as the Cloudflare one does (an adaptation of the brief's token-only field list).
            return HumanTask(template: .hostingAccount, title: "Create a Vercel account and a token", steps: [
                "Sign up or log in.",
                "Account Settings → Tokens → Create Token → Create.",
                "Copy the token into the field below. It goes to your Mac's Keychain; agents never see it.",
                "Copy your Team ID (team Settings → General), or on Hobby your Vercel ID (Account Settings → General), into the field below.",
                "Vercel's free Hobby plan is for non-commercial use.",
            ], links: [
                HumanTaskLink(title: "Sign up", url: "https://vercel.com/signup"),
                HumanTaskLink(title: "Tokens", url: "https://vercel.com/account/settings/tokens"),
            ], fields: [
                HumanTaskField(name: token, label: "Vercel token", kind: .secretEngine, required: true),
                HumanTaskField(name: "account_id", label: "Team or account ID", kind: .text, required: true,
                               pattern: "^[A-Za-z0-9_-]{1,64}$"),
            ])
        }
    }

    static func domain(provider: HostingProviderID, project: String, domain raw: String?) throws -> HumanTask {
        var domain: String?
        if let raw {
            let d = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty {
                guard isHostname(d) else { throw WorkError.invalid(HumanTaskPolicy.domainMessage) }
                domain = d
            }
        }
        let title = "Buy or connect the domain \(domain ?? "for your product")"
        let d = domain ?? "your domain"
        let field = HumanTaskField(name: "domain", label: "Domain", kind: .text, required: true, pattern: hostnamePattern)
        switch provider {
        case .cloudflarePages:
            return HumanTask(template: .domain, title: title, steps: [
                "Buy \(d) (or add a domain you own to Cloudflare)",
                "Workers & Pages → \(project) → Custom domains → Set up a domain → \(d)",
                "If your DNS is elsewhere, add: CNAME www → \(project).pages.dev",
            ], links: [
                HumanTaskLink(title: "Register a domain", url: "https://dash.cloudflare.com/?to=/:account/domains/register"),
                HumanTaskLink(title: "Custom domains", url: "https://dash.cloudflare.com/?to=/:account/pages/view/\(project)/domains"),
            ], fields: [field])
        case .vercel:
            return HumanTask(template: .domain, title: title, steps: [
                "Buy \(d) from any registrar (or use a domain you own)",
                "Vercel → \(project) → Settings → Domains → Add → \(d)",
                "At your DNS provider, add: A @ 76.76.21.21",
                "At your DNS provider, add: CNAME www cname.vercel-dns.com",
            ], links: [HumanTaskLink(title: "Vercel dashboard", url: "https://vercel.com/dashboard")], fields: [field])
        }
    }

    static let stripeTestKeys = HumanTask(template: .stripeTestKeys, title: "Create Stripe test API keys", steps: [
        "Stay in Test mode",
        "Reveal the test secret key and copy it below",
        "Copy the publishable key below",
    ], links: [
        HumanTaskLink(title: "Sign up", url: "https://dashboard.stripe.com/register"),
        HumanTaskLink(title: "Test API keys", url: "https://dashboard.stripe.com/test/apikeys"),
    ], fields: [
        HumanTaskField(name: "STRIPE_TEST_SECRET_KEY", label: "Test secret key", kind: .secretTest, required: true, prefix: "sk_test_"),
        HumanTaskField(name: "STRIPE_TEST_PUBLISHABLE_KEY", label: "Test publishable key", kind: .secretTest, required: true,
                       prefix: "pk_test_"),
    ])

    /// Builder-check 11: the url is validated `https` with a host before anything is built from it, and every query value
    /// goes through `percentEncode`.
    static func launchPost(text raw: String?, url rawURL: String?) throws -> HumanTask {
        let text = Store.stripControls(raw ?? "", keepNewlines: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkError.invalid("launch-post needs the post text (args.text)") }
        guard text.count <= HumanTaskPolicy.maxPost else { throw WorkError.invalid(HumanTaskPolicy.postMessage) }
        var url: String?
        if let rawURL, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let u = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidLink(u) else { throw WorkError.invalid(HumanTaskPolicy.launchPostURLMessage) }
            url = u
        }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        var links = [HumanTaskLink(title: "Post on X", url: "https://x.com/intent/post?text=" + percentEncode(url.map { text + " " + $0 } ?? text))]
        if let url {
            links.append(HumanTaskLink(title: "Share on LinkedIn", url: "https://www.linkedin.com/sharing/share-offsite/?url=" + percentEncode(url)))
            links.append(HumanTaskLink(title: "Submit to Hacker News",
                                       url: "https://news.ycombinator.com/submitlink?u=" + percentEncode(url) + "&t=" + percentEncode(firstLine)))
        }
        return HumanTask(template: .launchPost, title: "Approve and post the launch announcement", steps: [
            "Edit the text if you like",
            "Open a link and post it from your own account",
            "Paste the post's URL below (optional)",
        ], links: links, fields: [HumanTaskField(name: "posted_url", label: "Post URL", kind: .url, required: false)], postText: text)
    }

    /// What the engine says the template is for (the ask's summary when the engine files it).
    public static func defaultReason(_ t: HumanTaskTemplate, provider: HostingProviderID) -> String {
        switch t {
        case .hostingAccount: "Deploys to \(provider.title) need an account and an API token."
        case .domain: "The product needs its own domain."
        case .stripeTestKeys: "Payments are built against Stripe's test mode."
        case .launchPost: "The launch announcement is ready to post."
        }
    }

    // MARK: Custom tasks

    /// An agent's own task: steps, https links and url fields only (builder-check 11). Titles, steps, link titles and labels
    /// are flattened to one line; empty steps are dropped.
    public static func custom(title: String, steps: [String], links: [HumanTaskLink], fields: [HumanTaskField]) throws -> HumanTask {
        let cleanTitle = Store.flat(title, max: Int.max)
        guard !cleanTitle.isEmpty else { throw WorkError.invalid("a human task needs a title") }
        let cleanSteps = steps.map { Store.flat($0, max: Int.max) }.filter { !$0.isEmpty }
        let cleanLinks = links.map { l in
            HumanTaskLink(title: Store.flat(l.title, max: HumanTaskPolicy.maxLabel), url: l.url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let cleanFields = fields.map { f -> HumanTaskField in
            var f = f
            f.name = f.name.trimmingCharacters(in: .whitespaces)
            let label = Store.flat(f.label, max: HumanTaskPolicy.maxLabel)
            f.label = label.isEmpty ? f.name : label
            return f
        }
        let task = HumanTask(template: nil, title: cleanTitle, steps: cleanSteps, links: cleanLinks, fields: cleanFields)
        try validate(task, custom: true)
        return task
    }

    /// The rules every task meets, template or custom (a custom one's fields are url only).
    public static func validate(_ task: HumanTask, custom: Bool) throws {
        guard task.steps.count <= HumanTaskPolicy.maxSteps, task.steps.allSatisfy({ $0.count <= HumanTaskPolicy.maxStepChars }),
              task.links.count <= HumanTaskPolicy.maxLinks, task.fields.count <= HumanTaskPolicy.maxFields else {
            throw WorkError.invalid(HumanTaskPolicy.capsMessage)
        }
        for link in task.links {
            guard link.url.lowercased().hasPrefix("https://") else { throw WorkError.invalid(HumanTaskPolicy.linksMessage) }
            guard link.url.unicodeScalars.allSatisfy(\.isASCII) else { throw WorkError.invalid(HumanTaskPolicy.asciiLinkMessage) }
            // Engine links (a template's) carry an encoded post and get their own cap; an agent's keep the usual one.
            let cap = custom ? HumanTaskPolicy.maxLink : HumanTaskPolicy.maxEngineLink
            guard link.url.count <= cap else {
                throw WorkError.invalid(custom ? HumanTaskPolicy.linkLengthMessage : "a link is longer than \(cap) characters")
            }
            guard isValidLink(link.url, maxLength: cap) else { throw WorkError.invalid(HumanTaskPolicy.linksMessage) }
            guard !link.title.isEmpty else { throw WorkError.invalid("a link needs a title") }
        }
        if custom, task.fields.contains(where: { $0.kind != .url }) { throw WorkError.invalid(HumanTaskPolicy.customFieldsMessage) }
        var names = Set<String>()
        for f in task.fields {
            guard isFieldName(f.name) else { throw WorkError.invalid(HumanTaskPolicy.fieldNamesMessage) }
            guard names.insert(f.name).inserted else { throw WorkError.invalid("field names must be unique") }
            if f.isSecret { guard SecretName.isValid(f.name) else { throw WorkError.invalid(HumanTaskPolicy.fieldNamesMessage) } }
        }
        if let post = task.postText { guard post.count <= HumanTaskPolicy.maxPost else { throw WorkError.invalid(HumanTaskPolicy.postMessage) } }
    }

    // MARK: Helpers

    /// RFC 3986 unreserved characters (`A–Z a–z 0–9 - . _ ~`) stay; every other UTF-8 byte becomes `%XX` (upper-case hex).
    public static func percentEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: out.unicodeScalars.append(Unicode.Scalar(b))
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// `https://<host>…`, plain ASCII, with a host and no user or password, no spaces or control characters.
    public static func isValidLink(_ s: String, maxLength: Int = HumanTaskPolicy.maxLink) -> Bool {
        guard s.count <= maxLength, s.unicodeScalars.allSatisfy(\.isASCII), s.lowercased().hasPrefix("https://"),
              !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }),
              let c = URLComponents(string: s), c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil else { return false }
        return true
    }

    /// `UPPER_SNAKE` (a key's name, `SecretName`-shaped) or `lower_snake`.
    public static func isFieldName(_ s: String) -> Bool {
        s.range(of: "^([A-Z][A-Z0-9_]{1,63}|[a-z][a-z0-9_]{0,63})$", options: .regularExpression) != nil
    }

    /// A lowercase DNS hostname with at least two labels.
    static let hostnamePattern = "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"

    public static func isHostname(_ s: String) -> Bool {
        s.count <= 253 && s.range(of: hostnamePattern, options: .regularExpression) != nil && s.contains(where: \.isLetter)
    }

    /// Whether the whole of `value` matches `pattern`.
    static func matches(_ value: String, pattern: String) -> Bool {
        guard let r = value.range(of: pattern, options: .regularExpression) else { return false }
        return r == value.startIndex..<value.endIndex
    }
}
