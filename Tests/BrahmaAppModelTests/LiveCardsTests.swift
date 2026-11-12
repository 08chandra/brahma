import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct LiveCardsTests {
    static let hostile = "**pwn** <img src=x> [click](https://evil.example) \u{1B}[31m"

    static func ask(_ kind: AskKind, title: String = "t", summary: String = "why", requester: String = "a1",
                    payload: AskPayload?, itemId: String? = nil) -> Ask {
        let json = """
            {"id":"ask1","companyId":"c","number":7,"kind":"\(kind.rawValue)","risk":"high","requesterId":"\(requester)",
             "title":"","summary":"","status":"pendingOwner","createdActive":0,"statusSinceActive":0,
             "createdAt":0,"updatedAt":0,"fyi":false,"remindCount":0,"decisionClass":"taste"}
            """
        var a = try! JSONDecoder().decode(Ask.self, from: Data(json.utf8))
        a.title = title; a.summary = summary; a.payload = payload; a.itemId = itemId
        return a
    }

    static func taskAsk(_ task: HumanTask, requester: String = "a1", itemId: String? = nil, summary: String = "why") throws -> Ask {
        ask(.humanTask, title: task.title, summary: summary, requester: requester,
            payload: AskPayload(details: try task.json()), itemId: itemId)
    }

    static let stripe = HumanTask(template: .stripeTestKeys, title: "Create Stripe test API keys", steps: ["Stay in Test mode"],
                                  links: [HumanTaskLink(title: "Test API keys", url: "https://dashboard.stripe.com/test/apikeys")],
                                  fields: [HumanTaskField(name: "STRIPE_TEST_SECRET_KEY", label: "Test secret key", kind: .secretTest,
                                                          required: true, prefix: "sk_test_"),
                                           HumanTaskField(name: "account_id", label: "Account ID", kind: .text, required: false,
                                                          pattern: "^[0-9a-f]{4}$")])

    @Test func deployCardShowsExactCommands() throws {
        let proposal = "Build (sandboxed, no token): npm run build → dist\nDeploy (engine, token $CLOUDFLARE_API_TOKEN from Keychain), in order:\n  wrangler pages deploy dist"
        let a = Self.ask(.deploy, title: "Deploy 0.1.0 to Cloudflare Pages at 1111111", payload: AskPayload(proposal: proposal))
        let r = try ReleaseFixtures.release(1, .proposed)
        let health = MainHealth(title: "SMOKE PASSED @1111111", tone: .good)
        let card = try #require(DeployCard.make(ask: a, release: r, health: health, handles: ["a1": "devops-1"]))
        #expect(card.commands == proposal)
        #expect(card.ref == "A-7" && card.askId == "ask1")
        #expect(card.version == "release 0.1.0" && card.commit == "1111111" && card.provider == "Cloudflare Pages")
        #expect(card.proposer == "@devops-1")
        #expect(card.mainHealth == health && card.smokeLine == "SMOKE PASSED @1111111")
        #expect(DeployCard.make(ask: Self.ask(.other, payload: nil), release: r, health: health, handles: [:]) == nil)
    }

    @Test func humanTaskCardLinksShowHost() throws {
        let card = try #require(HumanTaskCard.make(ask: try Self.taskAsk(Self.stripe, itemId: "i1"), handles: ["a1": "eng-1"],
                                                  itemKeys: ["i1": "ACME-4"]))
        #expect(card.links.map(\.host) == ["dashboard.stripe.com"])
        #expect(card.requester == "@eng-1" && card.itemKey == "ACME-4" && card.ref == "A-7")
        #expect(card.caption == nil)
        let system = try #require(HumanTaskCard.make(ask: try Self.taskAsk(Self.stripe, requester: "system"), handles: [:], itemKeys: [:]))
        #expect(system.requester == "system")
        #expect(HumanTaskCard.make(ask: Self.ask(.deploy, payload: nil), handles: [:], itemKeys: [:]) == nil)
    }

    @Test func customTaskCardHasCaption() throws {
        let custom = HumanTask(template: nil, title: "Point the DNS", steps: ["Open the registrar"],
                               links: [HumanTaskLink(title: "Registrar", url: "https://registrar.example/dns")],
                               fields: [HumanTaskField(name: "dns_url", label: "Record URL", kind: .url, required: false)])
        let card = try #require(HumanTaskCard.make(ask: try Self.taskAsk(custom), handles: [:], itemKeys: [:]))
        #expect(card.caption == HumanTaskPolicy.customFieldCaption)
    }

    @Test func formValidation() throws {
        let card = try #require(HumanTaskCard.make(ask: try Self.taskAsk(Self.stripe), handles: [:], itemKeys: [:]))
        var form = HumanTaskForm(values: [:])
        #expect(form.validate(card) == "Test secret key is required")
        form.values["STRIPE_TEST_SECRET_KEY"] = "pk_test_1"
        #expect(form.validate(card) == "Test secret key must start with sk_test_")
        form.values["STRIPE_TEST_SECRET_KEY"] = "sk_live_1"
        #expect(form.validate(card) == HumanTaskPolicy.liveStripeMessage)
        form.values["STRIPE_TEST_SECRET_KEY"] = "sk_test_1"
        form.values["account_id"] = "zz"
        #expect(form.validate(card) == "Account ID doesn't look right")
        form.values["account_id"] = "ab12"
        #expect(form.validate(card) == nil)
    }

    @Test func agentTextKeptVerbatim() throws {
        let custom = HumanTask(template: nil, title: Self.hostile, steps: [Self.hostile],
                               links: [HumanTaskLink(title: Self.hostile, url: "https://registrar.example/dns")], fields: [],
                               postText: Self.hostile)
        let card = try #require(HumanTaskCard.make(ask: try Self.taskAsk(custom, summary: Self.hostile), handles: [:], itemKeys: [:]))
        #expect(card.title == Self.hostile && card.steps == [Self.hostile] && card.links[0].title == Self.hostile)
        #expect(card.reason == Self.hostile && card.postText == Self.hostile)
        let deploy = Self.ask(.deploy, title: Self.hostile, payload: AskPayload(proposal: Self.hostile))
        let d = try #require(DeployCard.make(ask: deploy, release: try ReleaseFixtures.release(1, .proposed),
                                             health: MainHealth(title: "NO SMOKE CHECK", tone: .idle), handles: [:]))
        #expect(d.title == Self.hostile && d.commands == Self.hostile)
    }

    // MARK: Fix round 1 (I3, M1)

    static func pendingRow(_ a: Ask) throws -> InboxRow {
        var w = WorkSnapshot()
        w.inbox = [a]
        return try #require(InboxRows.make(w, handles: [:]).first { $0.id == a.id && $0.section == .pending })
    }

    @Test func deployWithoutReleaseRecordIsReadOnly() throws {
        let deploy = Self.ask(.deploy, title: "Deploy 0.1.0", payload: AskPayload(proposal: "wrangler pages deploy dist"))
        let row = try Self.pendingRow(deploy)
        let card = try #require(DeployCard.make(ask: deploy, release: try ReleaseFixtures.release(1, .proposed),
                                                health: MainHealth(title: "NO SMOKE CHECK", tone: .idle), handles: [:]))
        #expect(LiveCardFallback.for(row: row, deployCard: card, humanTaskCard: nil) == nil)
        let fallback = try #require(LiveCardFallback.for(row: row, deployCard: nil, humanTaskCard: nil))
        #expect(fallback == .deployUnavailable)
        #expect(fallback.title(ref: row.ref) == "DEPLOY · A-7: release record unavailable")
        #expect(fallback.canApprove == false && fallback.canReject && !fallback.canDecline)
    }

    @Test func unreadableHumanTaskCanStillBeDeclined() throws {
        let broken = Self.ask(.humanTask, payload: AskPayload(details: "{not json"))
        #expect(HumanTaskCard.make(ask: broken, handles: [:], itemKeys: [:]) == nil)
        let row = try Self.pendingRow(broken)
        let fallback = try #require(LiveCardFallback.for(row: row, deployCard: nil, humanTaskCard: nil))
        #expect(fallback == .humanTaskUnreadable)
        #expect(fallback.title(ref: row.ref) == "HUMAN TASK · A-7: task details unreadable")
        #expect(fallback.canDecline && !fallback.canApprove && !fallback.canReject)
        let good = try #require(HumanTaskCard.make(ask: try Self.taskAsk(Self.stripe), handles: [:], itemKeys: [:]))
        #expect(LiveCardFallback.for(row: try Self.pendingRow(try Self.taskAsk(Self.stripe)), deployCard: nil, humanTaskCard: good) == nil)
        // Other kinds keep the generic card.
        #expect(LiveCardFallback.for(row: try Self.pendingRow(Self.ask(.other, payload: nil)), deployCard: nil, humanTaskCard: nil) == nil)
    }

    @Test func formTakesSecretsOutOfViewState() throws {
        let card = try #require(HumanTaskCard.make(ask: try Self.taskAsk(Self.stripe), handles: [:], itemKeys: [:]))
        var values = ["STRIPE_TEST_SECRET_KEY": "sk_test_1", "account_id": "ab12", "blank": ""]
        let form = HumanTaskForm.make(card, values: &values, editedPost: "ignored")
        #expect(form.values == ["STRIPE_TEST_SECRET_KEY": "sk_test_1", "account_id": "ab12"])
        #expect(form.editedPost == nil)  // the card has no post text
        #expect(values["STRIPE_TEST_SECRET_KEY"] == nil)
        #expect(values["account_id"] == "ab12")
        // A failing form clears the secret just the same.
        var bad = ["STRIPE_TEST_SECRET_KEY": "pk_test_1"]
        let rejected = HumanTaskForm.make(card, values: &bad, editedPost: nil)
        #expect(rejected.validate(card) == "Test secret key must start with sk_test_")
        #expect(bad.isEmpty)
        let post = HumanTask(template: nil, title: "Post it", steps: ["Post"], links: [], fields: [], postText: "hello")
        let postCard = try #require(HumanTaskCard.make(ask: try Self.taskAsk(post), handles: [:], itemKeys: [:]))
        var none: [String: String] = [:]
        #expect(HumanTaskForm.make(postCard, values: &none, editedPost: "hello, edited").editedPost == "hello, edited")
    }
}
