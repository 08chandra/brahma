import Testing
import Foundation
import GRDB
@testable import BrahmaCore

private func brahma(_ args: [String], home: URL, env: [String: String] = [:], stdin: String? = nil) throws
    -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe(), input = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = stdin == nil ? FileHandle.nullDevice : input
    try p.run()
    if let stdin {
        feedChildInput(input, Data(stdin.utf8))
    }
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// Plan L Task 9: human-task asks — engine templates with prefilled links, steps and paste-back fields; the owner marks one
/// done (secrets to the vault) or declines it, and the linked item carries on; `request_human_task` with its tainted-session rule.
@Suite(.scratch) struct HumanTaskTests {
    struct H {
        let store: Store
        let acme: Company, globex: Company
        let eng: Agent, pm: Agent, globexEng: Agent
        let vault = MemoryVault()
        let dir: URL?

        init(fileBacked: Bool = false) throws {
            if fileBacked {
                let d = try tempDir()
                dir = d
                store = try Store(path: d.appending(path: "brahma.db").path)
            } else {
                dir = nil
                store = try Store.inMemory()
            }
            acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            globex = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
            eng = try store.hire(companyId: acme.id, name: "eng", role: "engineer", model: "m")
            pm = try store.hire(companyId: acme.id, name: "pm", role: "pm", model: "m")
            globexEng = try store.hire(companyId: globex.id, name: "eng", role: "engineer", model: "m")
        }

        func call(_ a: Agent, _ args: [String: JSONValue]) -> (ok: Bool, text: String) {
            let tools = CompanyTools(store: store, companyId: a.companyId, agentId: a.id)
            do { return (true, try tools.call(name: "request_human_task", arguments: args)) }
            catch let e as ToolError { return (false, e.message) } catch { return (false, "\(error)") }
        }

        @discardableResult
        func item(_ company: Company? = nil, owner: Agent? = nil, status: WorkItemStatus = .ready) throws -> WorkItem {
            try store.createWorkItem(companyId: (company ?? acme).id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Take payments", checkSpec: CheckSpec(command: "true", paths: ["src"]), ownerId: owner?.id,
                status: status))
        }

        func leased(by a: Agent) throws -> WorkItem {
            let i = try item(owner: a)
            _ = try store.claimLease(itemId: i.id, agentId: a.id)
            return try fresh(i)
        }

        func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
        func fresh(_ a: Ask) throws -> Ask { try #require(try store.ask(id: a.id)) }
        func humanTasks(_ c: Company? = nil) throws -> [Ask] { try store.asks(companyId: (c ?? acme).id).filter { $0.kind == .humanTask } }
        func events(_ i: WorkItem) throws -> [WorkItemEvent] {
            try store.writer.read { db in try WorkItemEvent.filter(Column("itemId") == i.id).order(Column("id")).fetchAll(db) }
        }
        func dms(_ a: Agent) throws -> [String] { try store.pendingInbox(agentId: a.id).map { $0.1.text } }
    }

    static func message(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    static let stripeValues = ["STRIPE_TEST_SECRET_KEY": "sk_test_51abcdefghijklmnop", "STRIPE_TEST_PUBLISHABLE_KEY": "pk_test_51qrstuvwxyz0123"]
    static let accountId = "0123456789abcdef0123456789abcdef"

    // MARK: Templates

    @Test func templatesRenderExactLinksAndFields() throws {
        let h = try H()
        let cf = try HumanTasks.render(.hostingAccount, company: h.acme, hosting: nil, args: [:])
        #expect(cf.template == .hostingAccount)
        #expect(cf.title == "Create a Cloudflare account and an API token")
        #expect(cf.links == [HumanTaskLink(title: "Sign up", url: "https://dash.cloudflare.com/sign-up"),
                             HumanTaskLink(title: "API tokens", url: "https://dash.cloudflare.com/profile/api-tokens")])
        #expect(cf.links.map(\.host) == ["dash.cloudflare.com", "dash.cloudflare.com"])
        #expect(cf.steps == [
            "Sign up or log in.",
            "Create Token → Custom token → Permissions: Account · Cloudflare Pages · Edit → Continue → Create.",
            "Copy the token into the field below. It goes to your Mac's Keychain; agents never see it.",
            "Copy your Account ID (Workers & Pages → right sidebar) into the field below.",
        ])
        #expect(cf.fields.map(\.name) == ["CLOUDFLARE_API_TOKEN", "account_id"])
        #expect(cf.fields.map(\.kind) == [.secretEngine, .text])
        #expect(cf.fields.allSatisfy { $0.required })
        #expect(cf.fields[1].pattern == "^[0-9a-f]{32}$")
        #expect(cf.fields[0].name == HostingAdapters.adapter(.cloudflarePages).tokenSecret)

        let vercelHosting = HostingSettings(companyId: h.acme.id, provider: .vercel, project: "lumen", updatedAt: Date())
        let v = try HumanTasks.render(.hostingAccount, company: h.acme, hosting: vercelHosting, args: [:])
        #expect(v.title == "Create a Vercel account and a token")
        #expect(v.links.map(\.url) == ["https://vercel.com/signup", "https://vercel.com/account/settings/tokens"])
        #expect(v.fields.first == HumanTaskField(name: "VERCEL_TOKEN", label: "Vercel token", kind: .secretEngine, required: true))
        #expect(v.steps.contains("Vercel's free Hobby plan is for non-commercial use."))
        // Final-review I6a: deploys never create the Vercel project; the owner does, with the configured name.
        #expect(v.steps.contains("Create a Vercel project named lumen (Add New… → Project in the dashboard, or `vercel project add lumen`). Deploys use it and never create it."),
                "\(v.steps)")
        #expect(VercelAdapter.projectNote(project: "lumen")
                == "Vercel deploys never create the project: create lumen first (Add New… → Project in the Vercel dashboard, or `vercel project add lumen`).")
        #expect(v.fields.map(\.name) == ["VERCEL_TOKEN", "account_id"], "deploys need VERCEL_ORG_ID (PR-15)")

        let stripe = try HumanTasks.render(.stripeTestKeys, company: h.acme, hosting: nil, args: [:])
        #expect(stripe.title == "Create Stripe test API keys")
        #expect(stripe.links.map(\.url) == ["https://dashboard.stripe.com/register", "https://dashboard.stripe.com/test/apikeys"])
        #expect(stripe.steps == ["Stay in Test mode", "Reveal the test secret key and copy it below", "Copy the publishable key below"])
        #expect(stripe.fields.map(\.name) == ["STRIPE_TEST_SECRET_KEY", "STRIPE_TEST_PUBLISHABLE_KEY"])
        #expect(stripe.fields.map(\.kind) == [.secretTest, .secretTest])
        #expect(stripe.fields.map(\.prefix) == ["sk_test_", "pk_test_"])

        let cfHosting = HostingSettings(companyId: h.acme.id, project: "lumen", updatedAt: Date())
        let d = try HumanTasks.render(.domain, company: h.acme, hosting: cfHosting, args: ["domain": "lumen.app"])
        #expect(d.title == "Buy or connect the domain lumen.app")
        #expect(d.links == [HumanTaskLink(title: "Register a domain", url: "https://dash.cloudflare.com/?to=/:account/domains/register"),
                            HumanTaskLink(title: "Custom domains", url: "https://dash.cloudflare.com/?to=/:account/pages/view/lumen/domains")])
        #expect(d.steps == ["Buy lumen.app (or add a domain you own to Cloudflare)",
                            "Workers & Pages → lumen → Custom domains → Set up a domain → lumen.app",
                            "If your DNS is elsewhere, add: CNAME www → lumen.pages.dev"])
        #expect(d.fields.map(\.name) == ["domain"]); #expect(d.fields[0].kind == .text); #expect(d.fields[0].required)
        let general = try HumanTasks.render(.domain, company: h.acme, hosting: nil, args: [:])
        #expect(general.title == "Buy or connect the domain for your product")
        #expect(general.links[1].url == "https://dash.cloudflare.com/?to=/:account/pages/view/\(h.acme.slug)/domains")
        let vd = try HumanTasks.render(.domain, company: h.acme, hosting: vercelHosting, args: ["domain": "lumen.app"])
        #expect(vd.steps.contains { $0.hasSuffix("A @ 76.76.21.21") })
        #expect(vd.steps.contains { $0.hasSuffix("CNAME www cname.vercel-dns.com") })
        #expect(Self.message { try HumanTasks.render(.domain, company: h.acme, hosting: nil, args: ["domain": "Evil.COM/x"]) }
                == HumanTaskPolicy.domainMessage)
        #expect(Self.message { try HumanTasks.render(.stripeTestKeys, company: h.acme, hosting: nil, args: ["url": "https://x.dev"]) }
                == "stripe-test-keys takes no argument url")
    }

    @Test func launchPostLinksEncoded() throws {
        let h = try H()
        let t = try HumanTasks.render(.launchPost, company: h.acme, hosting: nil,
                                      args: ["text": "Hi & welcome #1\nnew line", "url": "https://lumen.pages.dev/?a=1&b=2"])
        #expect(t.title == "Approve and post the launch announcement")
        #expect(t.links.map(\.title) == ["Post on X", "Share on LinkedIn", "Submit to Hacker News"])
        #expect(t.links.map(\.host) == ["x.com", "www.linkedin.com", "news.ycombinator.com"])
        let x = t.links[0].url
        #expect(x.hasPrefix("https://x.com/intent/post?text="))
        for enc in ["%26", "%23", "%0A", "%3F", "%3D", "%2F", "%3A", "%20"] { #expect(x.contains(enc), "\(enc)") }
        #expect(!x.contains("&"), "no raw & inside the one query value")
        #expect(!x.dropFirst("https://x.com/intent/post?".count).contains("#"))
        #expect(x == "https://x.com/intent/post?text=Hi%20%26%20welcome%20%231%0Anew%20line%20https%3A%2F%2Flumen.pages.dev%2F%3Fa%3D1%26b%3D2")
        #expect(t.links[1].url == "https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Flumen.pages.dev%2F%3Fa%3D1%26b%3D2")
        let hn = t.links[2].url
        #expect(hn == "https://news.ycombinator.com/submitlink?u=https%3A%2F%2Flumen.pages.dev%2F%3Fa%3D1%26b%3D2&t=Hi%20%26%20welcome%20%231")
        #expect(hn.filter { $0 == "&" }.count == 1, "only the separator between u and t")
        #expect(t.postText == "Hi & welcome #1\nnew line")
        #expect(t.steps == ["Edit the text if you like", "Open a link and post it from your own account", "Paste the post's URL below (optional)"])
        #expect(t.fields == [HumanTaskField(name: "posted_url", label: "Post URL", kind: .url, required: false)])
        // Without a url: only the X link.
        let bare = try HumanTasks.render(.launchPost, company: h.acme, hosting: nil, args: ["text": "Launch!"])
        #expect(bare.links.map(\.url) == ["https://x.com/intent/post?text=Launch%21"])
        // Builder-check 11: the url must be https with a host before any link is built from it.
        for bad in ["javascript:alert(1)", "http://x", "https://", "https://user:pw@evil.com/", "https://evil.com/ x", "ftp://x.com"] {
            #expect(Self.message { try HumanTasks.render(.launchPost, company: h.acme, hosting: nil, args: ["text": "Hi", "url": bad]) }
                    == "launch-post url must start with https://", "\(bad)")
        }
        #expect(Self.message { try HumanTasks.render(.launchPost, company: h.acme, hosting: nil, args: ["text": String(repeating: "a", count: 3001)]) }
                == HumanTaskPolicy.postMessage)
        #expect(HumanTasks.percentEncode("aZ09-._~ é/+") == "aZ09-._~%20%C3%A9%2F%2B")
    }

    /// Fix round 1, I3: the pinned 3000 characters are reachable whatever the text encodes to; an agent's link keeps 2048.
    @Test func launchPostTakesFullLengthPost() throws {
        let h = try H()
        let phrase = "Café ☕ launch day, ünïcode & spaces! "
        var text = String(repeating: phrase, count: 3000 / phrase.count + 1)
        text = String(text.prefix(3000))
        #expect(text.count == 3000)
        let (ask, _) = try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .launchPost,
                                                    args: ["text": text, "url": "https://lumen.pages.dev/"], reason: "launch")
        let task = try #require(HumanTask.from(ask))
        #expect(task.postText == text)
        #expect(task.links.count == 3); #expect(task.links[0].url.count > 2048)
        let emoji = String(repeating: "🚀", count: 3000)
        let (rocket, deduped) = try h.store.requestHumanTask(companyId: h.globex.id, by: h.globexEng.id, template: .launchPost,
                                                             args: ["text": emoji, "url": "https://globex.pages.dev/"], reason: "launch")
        #expect(!deduped); #expect(HumanTask.from(rocket)?.postText == emoji)
        let long = "https://docs.example.com/" + String(repeating: "a", count: 2100)
        #expect(Self.message { try HumanTasks.custom(title: "Read", steps: [], links: [HumanTaskLink(title: "Docs", url: long)], fields: []) }
                == "a link is longer than 2048 characters")
        let emojiTask = try HumanTasks.render(.launchPost, company: h.acme, hosting: nil, args: ["text": emoji, "url": "https://lumen.pages.dev/"])
        #expect(emojiTask.links[0].url.count > 30_000)
    }

    // MARK: Custom tasks

    @Test func customTaskCannotRequestSecrets() throws {
        let link = [HumanTaskLink(title: "Docs", url: "https://docs.example.com/")]
        for kind in [HumanTaskField.Kind.secretEngine, .secretTest, .text] {
            let field = HumanTaskField(name: kind == .text ? "password" : "API_KEY", label: "Paste it", kind: kind, required: true)
            #expect(Self.message { try HumanTasks.custom(title: "Connect it", steps: [], links: link, fields: [field]) }
                    == "custom human tasks can only ask for links (url fields); use a template, or request_from_owner for anything else", "\(kind)")
        }
        // The tool never builds anything but url fields, whatever an agent passes.
        let h = try H()
        let filed = h.call(h.eng, ["title": .string("Connect analytics"), "reason": .string("metrics"),
                                   "fields": .array([.object(["name": .string("STRIPE_SECRET_KEY"), "label": .string("Key"), "kind": .string("secretEngine")])])])
        #expect(filed.ok, "\(filed.text)")
        let filedAsk = try #require(try h.humanTasks().first)
        let task = try #require(HumanTask.from(filedAsk))
        #expect(task.fields.map(\.kind) == [.url])
        // Completing it: a key is not a URL.
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: try h.humanTasks()[0].id,
                                                             values: ["STRIPE_SECRET_KEY": "sk_test_abc"], vault: h.vault) }
                == "Key must start with https://")
    }

    @Test func customTaskFieldsAreURLOnly() throws {
        let h = try H()
        let ok = h.call(h.eng, [
            "title": .string("Enable GitHub Pages"), "reason": .string("docs site"),
            "steps": .array([.string("Open the repo settings"), .string("  "), .string("Pages → Source: main")]),
            "links": .array([.object(["title": .string("Pages settings"), "url": .string("https://github.com/acme/site/settings/pages")])]),
            "fields": .array([.object(["name": .string("site_url"), "label": .string("Site URL"), "required": .bool(true)])]),
        ])
        #expect(ok.ok, "\(ok.text)")
        let ask = try #require(try h.humanTasks().first)
        #expect(ok.text == "Requested \(ask.ref) (Enable GitHub Pages). The owner will do it; you'll get a notice when it's done.")
        let task = try #require(HumanTask.from(ask))
        #expect(task.template == nil); #expect(task.steps == ["Open the repo settings", "Pages → Source: main"])
        #expect(task.fields == [HumanTaskField(name: "site_url", label: "Site URL", kind: .url, required: true)])
        #expect(task.links.map(\.host) == ["github.com"])
        #expect(HumanTaskPolicy.customFieldCaption == "Values you enter here are shown to agents. Never paste a key or password.")
        // A url field takes https only, and its value is what the agent is told.
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id, values: ["site_url": "http://acme.dev"], vault: h.vault) }
                == "Site URL must start with https://")
        try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id, values: ["site_url": " https://acme.github.io/site "], vault: h.vault)
        #expect(try h.fresh(ask).ownerAnswer == #"{"site_url":"https://acme.github.io/site"}"#)
        // Fix round 1, I1: the @system DM carries refs only, never the agent's title or an owner-entered value.
        let doneDM = try #require(try h.dms(h.eng).first { $0.hasPrefix("\(ask.ref) is done") })
        #expect(doneDM == "\(ask.ref) is done. See the Inbox.")
        #expect(!doneDM.contains("GitHub Pages")); #expect(!doneDM.contains("acme.github.io"))
        // Caps and field names.
        let many = (1...13).map { "step \($0)" }
        #expect(Self.message { try HumanTasks.custom(title: "x", steps: many, links: [], fields: []) } == HumanTaskPolicy.capsMessage)
        #expect(Self.message { try HumanTasks.custom(title: "x", steps: [String(repeating: "s", count: 301)], links: [], fields: []) } == HumanTaskPolicy.capsMessage)
        let sevenLinks = (1...7).map { HumanTaskLink(title: "l\($0)", url: "https://a.dev/\($0)") }
        #expect(Self.message { try HumanTasks.custom(title: "x", steps: [], links: sevenLinks, fields: []) } == HumanTaskPolicy.capsMessage)
        let sevenFields = (1...7).map { HumanTaskField(name: "f\($0)", label: "F", kind: .url, required: false) }
        #expect(Self.message { try HumanTasks.custom(title: "x", steps: [], links: [], fields: sevenFields) } == HumanTaskPolicy.capsMessage)
        for bad in ["Site-URL", "siteUrl", "1x", "", "x y"] {
            #expect(Self.message { try HumanTasks.custom(title: "x", steps: [], links: [], fields: [HumanTaskField(name: bad, label: "L", kind: .url, required: false)]) }
                    == "field names must be UPPER_SNAKE (keys) or lower_snake", "\(bad)")
        }
    }

    @Test func nonHTTPSLinkRefused() throws {
        for bad in ["http://evil.example/login", "javascript:alert(1)", "HTTP://x.com", "https://user@evil.com/", "data:text/html,hi", "//x.com"] {
            #expect(Self.message { try HumanTasks.custom(title: "Log in", steps: [], links: [HumanTaskLink(title: "Login", url: bad)], fields: []) }
                    == "links must start with https://", "\(bad)")
        }
        #expect(Self.message { try HumanTasks.custom(title: "Log in", steps: [], links: [HumanTaskLink(title: "Login", url: "https://pаypal.com/")], fields: []) }
                == HumanTaskPolicy.asciiLinkMessage, "a Cyrillic look-alike host is refused")
        let h = try H()
        let viaTool = h.call(h.eng, ["title": .string("Log in"), "reason": .string("r"),
                                     "links": .array([.object(["title": .string("Login"), "url": .string("http://evil.example/")])])])
        #expect(!viaTool.ok); #expect(viaTool.text == "links must start with https://")
        #expect(try h.humanTasks().isEmpty)
    }

    // MARK: The linked item

    @Test func requestBlocksAndDoneUnblocksItem() throws {
        let h = try H()
        let item = try h.leased(by: h.eng)
        #expect(item.status == .inProgress)
        let r = h.call(h.eng, ["template": .string("stripe-test-keys"), "item": .string(item.key.lowercased()), "reason": .string("checkout needs test keys")])
        #expect(r.ok, "\(r.text)")
        let ask = try #require(try h.humanTasks().first)
        #expect(r.text == "Requested \(ask.ref) (Create Stripe test API keys). The owner will do it; you'll get a notice when it's done.")
        #expect(ask.kind == .humanTask); #expect(ask.risk == .low); #expect(ask.status == .pendingOwner)
        #expect(ask.requesterId == h.eng.id); #expect(ask.itemId == item.id); #expect(ask.summary == "checkout needs test keys")
        #expect(ask.title == "Create Stripe test API keys"); #expect(HumanTask.from(ask)?.template == .stripeTestKeys)
        let blocked = try h.fresh(item)
        #expect(blocked.status == .blocked); #expect(blocked.blockedAskId == ask.id); #expect(blocked.blockedAskBy == h.eng.id)
        #expect(blocked.statusBeforeBlock == .inProgress)
        #expect(try h.store.lease(itemId: item.id)?.agentId == h.eng.id, "the lease stays")

        try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id, values: Self.stripeValues, vault: h.vault)
        let done = try h.fresh(ask)
        #expect(done.status == .answered); #expect(done.ownerDecidedAt != nil); #expect(done.decidedBy == "owner")
        #expect(done.ownerAnswer == #"{"STRIPE_TEST_PUBLISHABLE_KEY":"saved","STRIPE_TEST_SECRET_KEY":"saved"}"#)
        let back = try h.fresh(item)
        #expect(back.status == .inProgress); #expect(back.blockedAskId == nil); #expect(back.blockedAskBy == nil)
        #expect(back.statusBeforeBlock == nil); #expect(back.blockedReason == nil)
        let event = try #require(try h.events(item).last)
        #expect(event.kind == .humanTaskDone); #expect(event.text == "\(ask.ref) done by the owner: Create Stripe test API keys")
        #expect(event.actorId == "owner")
        let notice = try #require(try h.store.pendingNotices(agentId: h.eng.id).first { $0.event.kind == .humanTaskDone })
        #expect(notice.notice.wakes, "the assignee is woken")
        #expect(try h.vault.value(companyId: h.acme.id, name: "STRIPE_TEST_SECRET_KEY") == Self.stripeValues["STRIPE_TEST_SECRET_KEY"])
        #expect(try h.store.secrets(companyId: h.acme.id).allSatisfy { $0.isTest })
        let dm = try #require(try h.dms(h.eng).first { $0.hasPrefix("\(ask.ref) is done") })
        #expect(dm == "\(ask.ref) is done (\(item.key)). See the Inbox.")
        #expect(!dm.contains("Create Stripe")); #expect(!dm.contains("sk_test_51")); #expect(!dm.contains("pk_test_51"))
        // Done once.
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id, values: Self.stripeValues, vault: h.vault) }
                == "\(ask.ref) is already answered")
    }

    @Test func doneWithoutLeaseReturnsToReady() throws {
        let h = try H()
        let held = try h.leased(by: h.eng)
        _ = try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .stripeTestKeys, itemId: held.id, reason: "r")
        // The lease went while the item waited.
        try h.store.writer.write { db in try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [held.id]) }
        let ask = try #require(try h.humanTasks().first)
        try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id, values: Self.stripeValues, vault: h.vault)
        #expect(try h.fresh(held).status == .ready)
        // An assigned (not held) ready item goes back to ready; another agent's item is never blocked.
        let assigned = try h.item(owner: h.eng)
        let others = try h.item(owner: h.pm)
        let (domain, _) = try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .domain, itemId: assigned.id, reason: "r")
        #expect(try h.fresh(assigned).status == .blocked); #expect(try h.fresh(assigned).statusBeforeBlock == .ready)
        let (_, deduped) = try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .domain, itemId: others.id, reason: "r")
        #expect(deduped); #expect(try h.fresh(others).status == .ready, "not the requester's item")
        try h.store.completeHumanTask(companyId: h.acme.id, askId: domain.id, values: ["domain": "lumen.app"], vault: h.vault)
        #expect(try h.fresh(assigned).status == .ready)
        #expect(try h.store.hosting(companyId: h.acme.id)?.customDomain == "lumen.app", "done sets the custom domain")
    }

    /// Fix round 1, I4: an item a holder blocked on the task itself (`update_work_item blockedOnAsk`) goes back in progress
    /// with its lease; a stale `statusBeforeBlock` never survives another unblock.
    @Test func blockedOnAskItemRestoredWithLease() throws {
        let h = try H()
        let item = try h.leased(by: h.eng)
        let task = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .hostingAccount)
        _ = try h.store.updateWorkItem(id: item.id, by: .agent(h.eng.id),
                                       patch: WorkItemPatch(status: .blocked, blockedReason: "needs the hosting token", blockedOnAsk: task.id))
        let blocked = try h.fresh(item)
        #expect(blocked.status == .blocked); #expect(blocked.blockedAskId == task.id); #expect(blocked.statusBeforeBlock == .inProgress)
        try h.store.completeHumanTask(companyId: h.acme.id, askId: task.id,
                                      values: ["CLOUDFLARE_API_TOKEN": "tok-abcdef123456", "account_id": Self.accountId], vault: h.vault)
        let back = try h.fresh(item)
        #expect(back.status == .inProgress); #expect(try h.store.lease(itemId: item.id)?.agentId == h.eng.id)
        #expect(back.statusBeforeBlock == nil)
        // No recorded status but a live lease: in progress (never ready with a lease).
        let h2 = try H()
        let other = try h2.leased(by: h2.eng)
        let stripe = try h2.store.fileTemplateTask(companyId: h2.acme.id, requesterId: "system", template: .stripeTestKeys)
        try h2.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'blocked', blockedAskId = ?, statusBeforeBlock = NULL WHERE id = ?",
                           arguments: [stripe.id, other.id])
        }
        try h2.store.declineHumanTask(companyId: h2.acme.id, askId: stripe.id, note: "")
        #expect(try h2.fresh(other).status == .inProgress)
        // A human-task block cleared another way (the holder unblocks it) leaves no stale status behind.
        let third = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .domain)
        _ = try h.store.updateWorkItem(id: item.id, by: .agent(h.eng.id), patch: WorkItemPatch(status: .blocked, blockedReason: "x", blockedOnAsk: third.id))
        #expect(try h.fresh(item).statusBeforeBlock == .inProgress)
        _ = try h.store.updateWorkItem(id: item.id, by: .agent(h.eng.id), patch: WorkItemPatch(status: .inProgress))
        #expect(try h.fresh(item).statusBeforeBlock == nil); #expect(try h.fresh(item).blockedAskId == nil)
    }

    // MARK: Paste-back

    @Test func pasteIsTrimmedAndVaulted() throws {
        let h = try H(fileBacked: true)
        let token = "tok123456789"
        let ask = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .hostingAccount)
        #expect(ask.requesterId == "system"); #expect(ask.status == .pendingOwner)
        try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id,
                                      values: ["CLOUDFLARE_API_TOKEN": token + "\n", "account_id": "  \(Self.accountId) "], vault: h.vault)
        #expect(try h.vault.value(companyId: h.acme.id, name: "CLOUDFLARE_API_TOKEN") == token)
        #expect(try h.store.secrets(companyId: h.acme.id).map(\.name) == ["CLOUDFLARE_API_TOKEN"])
        #expect(try h.store.secrets(companyId: h.acme.id).first?.isTest == false, "engine-held")
        let done = try h.fresh(ask)
        #expect(done.ownerAnswer == #"{"CLOUDFLARE_API_TOKEN":"saved","account_id":"0123456789abcdef0123456789abcdef"}"#)
        #expect(try h.store.hosting(companyId: h.acme.id)?.accountId == Self.accountId)
        // The value is nowhere in the database: no row, no file page.
        #expect(!(try dumpDatabase(h.store)).contains(token))
        let dir = try #require(h.dir)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix("brahma.db") {
            let bytes = try Data(contentsOf: dir.appending(path: name))
            #expect(bytes.range(of: Data(token.utf8)) == nil, "\(name)")
        }
        // A key pasted into a field agents see is refused.
        let stripe = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .stripeTestKeys)
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: stripe.id,
                                                             values: ["STRIPE_TEST_SECRET_KEY": "sk_test_ab cd", "STRIPE_TEST_PUBLISHABLE_KEY": "pk_test_x"],
                                                             vault: h.vault) } == "Test secret key doesn't look right")
    }

    @Test func liveStripeKeyRefused() throws {
        let h = try H()
        let ask = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .stripeTestKeys)
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id,
                                                             values: ["STRIPE_TEST_SECRET_KEY": "sk_live_51abcdef", "STRIPE_TEST_PUBLISHABLE_KEY": "pk_test_1"],
                                                             vault: h.vault) } == "that's a live Stripe key; paste the test key (sk_test_…)")
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id,
                                                             values: ["STRIPE_TEST_SECRET_KEY": "sk_test_1", "STRIPE_TEST_PUBLISHABLE_KEY": "pk_live_1"],
                                                             vault: h.vault) } == "Test publishable key must start with pk_test_")
        #expect(try h.fresh(ask).status == .pendingOwner)
        #expect(try h.vault.value(companyId: h.acme.id, name: "STRIPE_TEST_SECRET_KEY") == nil)
        #expect(try h.store.secrets(companyId: h.acme.id).isEmpty)
    }

    @Test func doneNeedsRequiredFields() throws {
        let h = try H()
        let ask = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .hostingAccount)
        func complete(_ v: [String: String]) -> String? {
            Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id, values: v, vault: h.vault) }
        }
        #expect(complete(["account_id": Self.accountId]) == "Cloudflare API token is required")
        #expect(complete(["CLOUDFLARE_API_TOKEN": "tok-abcdef123", "account_id": "  "]) == "Account ID is required")
        #expect(complete(["CLOUDFLARE_API_TOKEN": "tok-abcdef123", "account_id": "ABC"]) == "Account ID doesn't look right")
        #expect(complete(["CLOUDFLARE_API_TOKEN": "tok-abcdef123", "account_id": Self.accountId, "EXTRA": "x"]) == "EXTRA is not a field of this task")
        #expect(complete(["CLOUDFLARE_API_TOKEN": "tok-abcdef123", "account_id": "tok-abcdef123"]) != nil)
        #expect(try h.fresh(ask).status == .pendingOwner)
        #expect(try h.vault.value(companyId: h.acme.id, name: "CLOUDFLARE_API_TOKEN") == nil, "nothing saved on a refusal")
        #expect(try h.store.hosting(companyId: h.acme.id)?.accountId == nil)
        // Another company's ask is not found.
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.globex.id, askId: ask.id, values: [:], vault: h.vault) } == "no such ask")
    }

    @Test func declineRestoresItemWithNote() throws {
        let h = try H()
        let item = try h.leased(by: h.eng)
        let (ask, _) = try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .domain, args: ["domain": "lumen.app"],
                                                    itemId: item.id, reason: "a real domain")
        #expect(try h.fresh(item).status == .blocked)
        try h.store.declineHumanTask(companyId: h.acme.id, askId: ask.id, note: "use the pages.dev address for now")
        let declined = try h.fresh(ask)
        #expect(declined.status == .rejected); #expect(declined.ownerNote == "use the pages.dev address for now")
        let back = try h.fresh(item)
        #expect(back.status == .inProgress); #expect(back.blockedAskId == nil); #expect(back.statusBeforeBlock == nil)
        let event = try #require(try h.events(item).last)
        #expect(event.kind == .humanTaskDeclined)
        #expect(event.text == "\(ask.ref) declined by the owner: Buy or connect the domain lumen.app — use the pages.dev address for now")
        #expect(try h.store.pendingNotices(agentId: h.eng.id).contains { $0.event.kind == .humanTaskDeclined && $0.notice.wakes })
        #expect(try h.dms(h.eng).contains { $0.contains("\(ask.ref) rejected by the owner: use the pages.dev address for now") })
        #expect(Self.message { try h.store.declineHumanTask(companyId: h.acme.id, askId: ask.id, note: "") } == "\(ask.ref) is already rejected")
    }

    // MARK: Filing rules

    @Test func dedupeAndQuota() throws {
        let h = try H()
        let first = h.call(h.eng, ["template": .string("stripe-test-keys"), "reason": .string("r")])
        let ask = try #require(try h.humanTasks().first)
        #expect(first.ok)
        #expect(h.call(h.eng, ["template": .string("stripe-test-keys"), "reason": .string("again")]).text == "Already requested as \(ask.ref).")
        #expect(h.call(h.pm, ["template": .string("stripe-test-keys"), "reason": .string("me too")]).text == "Already requested as \(ask.ref).")
        let custom = h.call(h.eng, ["title": .string("Enable Pages"), "reason": .string("r")])
        #expect(custom.ok)
        #expect(h.call(h.eng, ["title": .string("enable pages"), "reason": .string("r")]).text.hasPrefix("Already requested as A-"))
        #expect(try h.humanTasks().count == 2)
        // The engine's filing dedupes too (inside its write), and charges no agent quota.
        let e1 = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .hostingAccount)
        let e2 = try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .hostingAccount)
        #expect(e1.id == e2.id)
        // The 5-lite ask quota (3 open per agent) applies in the write that files the ask.
        #expect(h.call(h.eng, ["template": .string("domain"), "reason": .string("r")]).ok)
        let fourth = h.call(h.eng, ["template": .string("launch-post"), "args": .object(["text": .string("Hi")]), "reason": .string("r")])
        #expect(!fourth.ok); #expect(fourth.text == AskQuota.refusal)
        // Unknown template.
        #expect(h.call(h.pm, ["template": .string("bank-account"), "reason": .string("r")]).text
                == "unknown template bank-account; use hosting-account, domain, stripe-test-keys or launch-post")
        #expect(h.call(h.pm, ["template": .string("domain"), "title": .string("x"), "reason": .string("r")]).text
                == "a template task takes only args, item and reason")
    }

    @Test func alwaysNeedsOwnerAndOwnerDecideRefused() throws {
        let h = try H()
        var c = h.acme
        c.autonomy = .auto
        try h.store.updateCompany(c)
        _ = try h.store.hire(companyId: h.acme.id, name: "ceo", role: "ceo", model: "m")
        let (ask, _) = try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .stripeTestKeys, reason: "r")
        #expect(ask.status == .pendingOwner); #expect(ask.internalApproverId == nil); #expect(!ask.fyi)
        for preset in AutonomyPreset.allCases {
            #expect(AutonomyPolicy.ownerRole(kind: .humanTask, risk: .low, category: nil, preset: preset, pack: nil) == .approve, "\(preset)")
        }
        #expect(AskKind.humanTask.title == "Human task"); #expect(AskKind.humanTask.isReservedKind)
        for approve in [true, false] {
            #expect(Self.message { try h.store.ownerDecide(askId: ask.id, approve: approve) } == "\(ask.ref) is a human task; mark it done or decline it")
        }
        do { _ = try h.store.ownerDecide(askId: ask.id, approve: true); Issue.record("approved") }
        catch let e as WorkError { #expect(e == .conflict("\(ask.ref) is a human task; mark it done or decline it")) }
        #expect(Self.message { try h.store.ownerReplan(askId: ask.id, text: "do it differently") } == "\(ask.ref) is a human task; mark it done or decline it")
        #expect(try h.fresh(ask).status == .pendingOwner)
        // No agent tool decides it either: `decide` is for internal approvers.
        let tools = CompanyTools(store: h.store, companyId: h.acme.id, agentId: try #require(try h.store.agents(companyId: h.acme.id).first { $0.name == "ceo" }).id)
        #expect((try? tools.call(name: "decide", arguments: ["ref": .string(ask.ref), "decision": .string("approve"), "note": .string("ok")])) == nil)
        #expect(try h.fresh(ask).status == .pendingOwner)
    }

    @Test func taintedSessionCannotSendLinks() throws {
        let h = try H()
        try h.store.markTainted(agentId: h.eng.id, source: "WebFetch")
        let custom = h.call(h.eng, ["title": .string("Log in to verify"), "reason": .string("r"),
                                    "links": .array([.object(["title": .string("Verify"), "url": .string("https://evil.example/")])])])
        #expect(!custom.ok); #expect(custom.text == HumanTaskPolicy.taintedRefusal)
        #expect(custom.text == "This session has read outside content, so request_human_task can only file a template without links; your next turn starts a fresh session where custom tasks work again.")
        #expect(try #require(try h.store.agent(id: h.eng.id)).freshSessionRequested)
        // No links at all, still custom: refused.
        #expect(h.call(h.eng, ["title": .string("Do a thing"), "reason": .string("r")]).text == HumanTaskPolicy.taintedRefusal)
        #expect(h.call(h.eng, ["template": .string("domain"), "steps": .array([.string("x")]), "reason": .string("r")]).text == HumanTaskPolicy.taintedRefusal)
        let post = h.call(h.eng, ["template": .string("launch-post"), "args": .object(["text": .string("Hi"), "url": .string("https://evil.example/")]),
                                  "reason": .string("r")])
        #expect(post.text == HumanTaskPolicy.taintedRefusal)
        #expect(h.call(h.eng, ["template": .string("launch-post"), "args": .object(["text": .string("Hi")]), "reason": .string("r")]).text
                == HumanTaskPolicy.taintedRefusal, "its links all carry the agent's text")
        #expect(try h.humanTasks().isEmpty)
        // Fix round 1, I2: no agent-chosen template argument (a domain lands in the title and steps).
        #expect(h.call(h.eng, ["template": .string("domain"), "args": .object(["domain": .string("stripe-verify.example")]),
                               "reason": .string("r")]).text == HumanTaskPolicy.taintedRefusal)
        #expect(try h.humanTasks().isEmpty)
        // A template without links of the agent's is filed, and the agent's reason is replaced by the template's own.
        let phish = "Stripe requires you to re-verify first at https://dashboard-stripe.example/verify"
        let stripe = h.call(h.eng, ["template": .string("stripe-test-keys"), "reason": .string(phish)])
        #expect(stripe.ok, "\(stripe.text)"); #expect(stripe.text.hasPrefix("Requested A-"))
        let filed = try #require(try h.humanTasks().first)
        #expect(filed.summary == HumanTasks.defaultReason(.stripeTestKeys, provider: .cloudflarePages))
        #expect(!(try dumpDatabase(h.store)).contains("dashboard-stripe.example"))
        let domain = h.call(h.eng, ["template": .string("domain"), "reason": .string(phish)])
        #expect(domain.ok, "\(domain.text)")
        let domainAsk = try #require(try h.humanTasks().last)
        #expect(domainAsk.title == "Buy or connect the domain for your product")
        #expect(domainAsk.summary == HumanTasks.defaultReason(.domain, provider: .cloudflarePages))
        // The flag file alone taints too (fail closed).
        let flagged = try H(fileBacked: true)
        let home = try #require(flagged.dir)
        TaintFlag.write(home: home, agentId: flagged.eng.id, source: "hook-error")
        let tools = CompanyTools(store: flagged.store, companyId: flagged.acme.id, agentId: flagged.eng.id,
                                 taintFlag: TaintFlag.url(home: home, agentId: flagged.eng.id))
        do { _ = try tools.call(name: "request_human_task", arguments: ["title": .string("x"), "reason": .string("r")]); Issue.record("filed") }
        catch let e as ToolError { #expect(e.message == HumanTaskPolicy.taintedRefusal) }
    }

    @Test func crossCompanyItemRefused() throws {
        let h = try H()
        let theirs = try h.item(h.globex, owner: h.globexEng)
        #expect(Self.message { try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .stripeTestKeys, itemId: theirs.id, reason: "r") }
                == "not in your company")
        #expect(Self.message { try h.store.fileTemplateTask(companyId: h.acme.id, requesterId: "system", template: .domain, itemId: theirs.id) }
                == "not in your company")
        #expect(Self.message { try h.store.requestHumanTask(companyId: h.acme.id, by: h.globexEng.id, template: .stripeTestKeys, reason: "r") }
                == "not in your company")
        // Through the tool the other company's key is simply not found.
        let viaTool = h.call(h.eng, ["template": .string("stripe-test-keys"), "item": .string(theirs.key), "reason": .string("r")])
        #expect(!viaTool.ok); #expect(viaTool.text == "no such work item \(theirs.key)")
        #expect(try h.humanTasks().isEmpty)
        #expect(try h.fresh(theirs).status == .ready)
        // The owner paths take the company the ask belongs to.
        let ask = try h.store.fileTemplateTask(companyId: h.globex.id, requesterId: "system", template: .stripeTestKeys)
        #expect(Self.message { try h.store.declineHumanTask(companyId: h.acme.id, askId: ask.id, note: "") } == "no such ask")
        #expect(Self.message { try h.store.completeHumanTask(companyId: h.acme.id, askId: ask.id, values: Self.stripeValues, vault: h.vault) } == "no such ask")
    }

    /// Task 13 (controller ruling, carried from Task 9): the requester sees its own answered human tasks in the turn digest —
    /// engine-written refs and `field = "value"` for text and url fields, `saved (in the vault)` for secret ones; never a secret
    /// value, never another agent's or another company's tasks.
    @Test func answeredTasksReadByRequesterOnly() throws {
        let h = try H()
        let paths = BrahmaPaths(home: try tempDir(), workspaces: try tempDir())
        // eng: a custom task with a url field and a template with secret fields; pm: its own custom task; globex: a template.
        let site = h.call(h.eng, ["title": .string("Connect the \u{1B}[31mstatus page"), "reason": .string("r"),
                                  "fields": .array([.object(["name": .string("site_url"), "label": .string("Site URL"), "kind": .string("url")])])])
        #expect(site.ok, "\(site.text)")
        let stripe = h.call(h.eng, ["template": .string("stripe-test-keys"), "reason": .string("payments")])
        #expect(stripe.ok, "\(stripe.text)")
        let theirs = h.call(h.pm, ["title": .string("Share the deck"), "reason": .string("r"),
                                   "fields": .array([.object(["name": .string("deck_url"), "label": .string("Deck"), "kind": .string("url")])])])
        #expect(theirs.ok, "\(theirs.text)")
        let globex = try h.store.fileTemplateTask(companyId: h.globex.id, requesterId: h.globexEng.id, template: .stripeTestKeys)
        let tasks = try h.humanTasks()
        let siteAsk = try #require(tasks.first { HumanTask.from($0)?.template == nil && $0.requesterId == h.eng.id })
        let stripeAsk = try #require(tasks.first { HumanTask.from($0)?.template == .stripeTestKeys })
        let deckAsk = try #require(tasks.first { $0.requesterId == h.pm.id })

        // Nothing is shown while they are pending.
        var ctx = try TurnContext.load(store: h.store, paths: paths, agent: h.eng, company: h.acme)
        #expect(ctx.answeredTasks.isEmpty)
        #expect(!TurnDigest.render(ctx, agent: h.eng, company: h.acme).contains("Done human tasks"))

        let secret = "sk_test_51HyperSecretValue0000000000", publishable = "pk_test_51PublicValue00000000000000"
        try h.store.completeHumanTask(companyId: h.acme.id, askId: siteAsk.id, values: ["site_url": "https://status.acme.dev/"], vault: h.vault)
        try h.store.completeHumanTask(companyId: h.acme.id, askId: stripeAsk.id,
                                      values: ["STRIPE_TEST_SECRET_KEY": secret, "STRIPE_TEST_PUBLISHABLE_KEY": publishable], vault: h.vault)
        try h.store.completeHumanTask(companyId: h.acme.id, askId: deckAsk.id, values: ["deck_url": "https://docs.acme.dev/deck"], vault: h.vault)
        try h.store.completeHumanTask(companyId: h.globex.id, askId: globex.id, values: Self.stripeValues, vault: h.vault)

        ctx = try TurnContext.load(store: h.store, paths: paths, agent: h.eng, company: h.acme)
        #expect(ctx.answeredTasks.map(\.id) == [stripeAsk.id, siteAsk.id], "the requester's own, newest first")
        let text = TurnDigest.render(ctx, agent: h.eng, company: h.acme)
        #expect(text.contains("Done human tasks (the owner's answers):"), "\(text)")
        #expect(text.contains("- \(siteAsk.ref) · Connect the [31mstatus page · site_url = \"https://status.acme.dev/\""), "\(text)")
        #expect(text.contains("- \(stripeAsk.ref) · stripe-test-keys · STRIPE_TEST_SECRET_KEY = saved (in the vault) · STRIPE_TEST_PUBLISHABLE_KEY = saved (in the vault)"), "\(text)")
        #expect(!text.contains(secret) && !text.contains(publishable) && !text.contains("\u{1B}"))
        #expect(!text.contains("deck_url") && !text.contains(deckAsk.ref), "another agent's task is invisible")
        // The other agent sees only its own; the other company's agent sees only its own.
        let pmText = TurnDigest.render(try TurnContext.load(store: h.store, paths: paths, agent: h.pm, company: h.acme), agent: h.pm, company: h.acme)
        #expect(pmText.contains("deck_url = \"https://docs.acme.dev/deck\"") && !pmText.contains("site_url"), "\(pmText)")
        let globexCtx = try TurnContext.load(store: h.store, paths: paths, agent: h.globexEng, company: h.globex)
        #expect(globexCtx.answeredTasks.map(\.id) == [globex.id])
        // A declined task is not an answer; the store query refuses another company's requester.
        let declined = try h.store.requestHumanTask(companyId: h.acme.id, by: h.eng.id, template: .domain, reason: "r").ask
        try h.store.declineHumanTask(companyId: h.acme.id, askId: declined.id, note: "later")
        #expect(try h.store.answeredHumanTasks(companyId: h.acme.id, requesterId: h.eng.id, limit: 10).map(\.id) == [stripeAsk.id, siteAsk.id])
        #expect(try h.store.answeredHumanTasks(companyId: h.acme.id, requesterId: h.globexEng.id, limit: 10).isEmpty)
        // The secret never reached the database in clear.
        #expect(!(try dumpDatabase(h.store)).contains(secret))
    }

    // MARK: CLI

    @Test func taskCLI() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home)
        #expect(created.status == 0, "\(created.stderr)")
        let ask: Ask = try {
            let store = try Store(path: ownerPaths(home).database.path)
            let company = try #require(try store.companies().first)
            _ = try store.fileTemplateTask(companyId: company.id, requesterId: "system", template: .stripeTestKeys)
            return try store.fileTemplateTask(companyId: company.id, requesterId: "system", template: .hostingAccount)
        }()
        #expect(ask.ref == "A-2")
        let list = try brahma(["task", "Acme"], home: home)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(list.stdout.contains("A-1  Create Stripe test API keys  @system  -"))
        #expect(list.stdout.contains("A-2  Create a Cloudflare account and an API token  @system  -"))
        let show = try brahma(["task", "show", "Acme", "A-2"], home: home)
        #expect(show.status == 0, "\(show.stderr)")
        #expect(show.stdout.contains("API tokens — dash.cloudflare.com  https://dash.cloudflare.com/profile/api-tokens"))
        #expect(show.stdout.contains("CLOUDFLARE_API_TOKEN (secretEngine, required)"))
        // Owner-write: refused in an agent's shell; a secret is never taken from argv.
        let inAgent = try brahma(["task", "done", "Acme", "A-2", "--secret", "CLOUDFLARE_API_TOKEN", "--field", "account_id=\(Self.accountId)"],
                                 home: home, env: ["BRAHMA_AGENT_ID": "a1"], stdin: "cf-token-123456789\n")
        #expect(inAgent.status == 1); #expect(inAgent.stderr.contains("owner commands can't run inside an agent turn"))
        let argv = try brahma(["task", "done", "Acme", "A-2", "--field", "CLOUDFLARE_API_TOKEN=cf-token-123456789"], home: home)
        #expect(argv.status != 0); #expect(argv.stderr.contains("CLOUDFLARE_API_TOKEN is a secret: pass --secret CLOUDFLARE_API_TOKEN"))
        let done = try brahma(["task", "done", "Acme", "A-2", "--secret", "CLOUDFLARE_API_TOKEN", "--field", "account_id=\(Self.accountId)"],
                              home: home, stdin: "cf-token-123456789\n")
        #expect(done.status == 0, "\(done.stderr)")
        #expect(done.stdout.contains("A-2 done: Create a Cloudflare account and an API token"))
        #expect(done.stdout.contains("saved to the vault: CLOUDFLARE_API_TOKEN")); #expect(!done.stdout.contains("cf-token-123456789"))
        let store = try Store(path: ownerPaths(home).database.path)
        let after = try #require(try store.ask(id: ask.id))
        #expect(after.status == .answered)
        #expect(try store.hosting(companyId: after.companyId)?.accountId == Self.accountId)
        let secrets = try brahma(["secret", "list", "Acme"], home: home)
        #expect(secrets.stdout.contains("CLOUDFLARE_API_TOKEN  engine-held"))
        let decline = try brahma(["task", "decline", "Acme", "A-1", "--note", "later"], home: home)
        #expect(decline.status == 0, "\(decline.stderr)")
        #expect(try store.ask(companyId: after.companyId, ref: "A-1")?.status == .rejected)
        let approve = try brahma(["approve", "Acme", "A-1"], home: home)
        #expect(approve.status != 0)
    }
}
