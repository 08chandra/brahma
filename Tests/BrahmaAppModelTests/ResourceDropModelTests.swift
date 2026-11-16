import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// Plan ML Task 7: drops on the owner's composers (DM, channel, Inbox question, library), their scope and trust chips, the
/// secret sheet and the advisory alert. Every vault is a `MemoryVault` (the test `AppModel`); the defaults are a fresh suite.
@MainActor @Suite(.scratch) struct ResourceDropModelTests {
    /// Acme (Workspace profile): ceo, cto, eng (blocked on the owner); Globex empty. A fresh defaults suite, removed at the end.
    final class W {
        let app: AppModel, store: Store, paths: BrahmaPaths, company: Company, eng: Agent, cto: Agent
        let suite = "brahma-test-drops-\(UUID().uuidString)"
        let defaults: UserDefaults
        let drops: URL

        @MainActor init() async throws {
            let (store, paths) = try makeHome()
            let (acme, _, cto, eng) = try seedAcme(store, paths)
            self.store = store; self.paths = paths; company = acme; self.eng = eng; self.cto = cto
            app = AppModel(store: store, paths: paths)
            defaults = try #require(UserDefaults(suiteName: suite))
            app.dropDefaults = defaults
            drops = try tempDir().appending(path: "Drops", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
            await app.load()
        }

        deinit { UserDefaults().removePersistentDomain(forName: suite) }

        func file(_ name: String, _ text: String) throws -> URL {
            let url = drops.appending(path: name)
            try Data(text.utf8).write(to: url)
            return url
        }

        func pdf(_ name: String) throws -> URL {
            let url = drops.appending(path: name)
            try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8).write(to: url)
            return url
        }

        /// The owner already said "Add anyway" to the advisory for Acme.
        func ackAdvisory() { defaults.set(true, forKey: "advisoryAck.\(company.id)") }

        @MainActor func model(_ context: DropContext) -> ResourceDropModel {
            ResourceDropModel(app: app, context: context, defaults: defaults)
        }

        func rows() throws -> [Resource] { try store.resources(companyId: company.id, reader: .owner, includePurged: true) }
    }

    static let awsLine = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n"

    @Test func testAppModelUsesMemoryVault() async throws {
        let w = try await W()
        #expect(w.app.secretVault is MemoryVault)
    }

    @Test func defaultScopePerContext() async throws {
        let w = try await W()
        let library = w.model(.library)
        await library.refreshScope()
        #expect(library.scopeLabel == "SCOPE · COMPANY")

        let dm = w.model(.dm(handle: "eng"))
        await dm.refreshScope()
        #expect(dm.scopeLabel == "SCOPE · @eng ONLY")

        let general = try #require(try w.store.channel(companyId: w.company.id, name: "general"))
        let members = try #require(try w.store.readerSet(for: .channel(general.id), companyId: w.company.id))
        let channel = w.model(.channel(name: "general"))
        await channel.refreshScope()
        #expect(channel.scopeLabel == "SCOPE · #general MEMBERS (\(members.count))")

        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner,
                                              draft: WorkItemDraft(type: .task, title: "Notes", ownerId: w.eng.id))
        let people = try #require(try w.store.readerSet(for: .item(item.id), companyId: w.company.id))
        let card = w.model(.item(id: item.id))
        await card.refreshScope()
        #expect(card.scopeLabel == "SCOPE · \(item.key) PEOPLE (\(people.count))")
        await card.setScope(.contextDefault, futureHolders: true)
        #expect(card.scopeLabel == "SCOPE · \(item.key) PEOPLE (\(people.count)) + FUTURE HOLDERS")

        let ask = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.cto.id), title: "Data", question: "Which file?")
        let inbox = w.model(.inbox(askId: ask.id))
        await inbox.refreshScope()
        #expect(inbox.scopeLabel == "SCOPE · @cto ONLY")
        #expect(inbox.hint == "Drop a file to answer")

        // The chooser: a team, the company, an item by key.
        await dm.setScope(.team("payments"))
        #expect(dm.scopeLabel == "SCOPE · TEAM payments")
        await dm.setScope(.company)
        #expect(dm.scopeLabel == "SCOPE · COMPANY")
        await library.setScope(.item(item.key))
        #expect(library.scopeLabel == "SCOPE · \(item.key) PEOPLE (\(people.count))")
    }

    @Test func trustChipCopyExact() async throws {
        let w = try await W()
        #expect(TrustChip.external(reason: "x").text
                == "EXTERNAL · agents read it as untrusted data; a session that opens it loses merge/approve tools until it starts fresh")
        #expect(TrustChip.external(reason: "x").action == "I vouch for this file")
        #expect(TrustChip.fromYou.text == "FROM YOU")
        #expect(TrustChip.fromYou.action == "Mark untrusted")

        let m = w.model(.library)
        await m.add(urls: [try w.file("notes.md", "# notes\n")])
        await m.add(urls: [try w.pdf("report.pdf")])
        #expect(m.pending.count == 2)
        #expect(m.pending[0].chip == .fromYou)
        #expect(m.pending[0].name == "notes.md")
        #expect(m.pending[0].kindLabel == "MD")
        #expect(m.pending[0].sizeText == "8 B")
        #expect(m.pending[1].chip == .external(reason: "PDF from outside (document type)"))
        m.addLink("https://user:pw@example.com/docs/page?q=1")
        #expect(m.pending.count == 3)
        #expect(m.pending[2].chip == .fromYou)
        #expect(m.pending[2].kindLabel == "LINK")
        #expect(m.pending[2].name == "example.com/docs/page")
        #expect(m.pending[2].link == "https://example.com/docs/page?q=1")
    }

    @Test func vouchFlipsChip() async throws {
        let w = try await W()
        let m = w.model(.library)
        await m.add(urls: [try w.pdf("report.pdf")])
        let id = try #require(m.pending.first?.id)
        #expect(m.pending[0].chip == .external(reason: "PDF from outside (document type)"))
        m.setTrust(id, .vouched)
        #expect(m.pending[0].chip == .fromYou)
        m.setTrust(id, .untrusted)
        #expect(m.pending[0].chip == .external(reason: "marked untrusted by you"))
        m.setTrust(id, .vouched)
        #expect(await m.commit(message: ""))
        let row = try #require(try w.rows().first)
        #expect(!row.tainted)
        #expect(row.vouchedAt != nil)
        #expect(m.pending.isEmpty)
    }

    @Test func secretSheetHidesUploadAnywayForKnownValue() async throws {
        let w = try await W()
        try w.store.setSecret(companyId: w.company.id, name: "DEPLOY_TOKEN", value: "tok-zebra-quokka-991", isTest: false,
                              vault: w.app.secretVault)
        let m = w.model(.library)
        await m.add(urls: [try w.file("config.env.txt", "name = demo\ntoken = tok-zebra-quokka-991\n")])
        let sheet = try #require(m.secretSheet)
        #expect(sheet.title == "This file looks like it contains a secret (stored secret DEPLOY_TOKEN, line 2)")
        #expect(!sheet.showsUploadAnyway)
        #expect(sheet.canUploadRedacted)
        #expect(sheet.canStoreAsSecret)
        // Upload anyway is refused even if asked for.
        await m.resolveSecret(.uploadAnyway)
        #expect(m.secretSheet != nil)
        #expect(await m.commit(message: "") == false)
        #expect(try w.rows().isEmpty)
        // Upload redacted: the stored copy holds no value.
        await m.resolveSecret(.uploadRedacted)
        #expect(m.secretSheet == nil)
        #expect(await m.commit(message: ""))
        let row = try #require(try w.rows().first)
        #expect(row.secretScan == .redacted)
        let bytes = try w.store.readResource(companyId: w.company.id, number: row.number, contentVault: ContentVault(paths: w.paths))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("tok-zebra-quokka-991"))

        // A pattern finding alone may be uploaded as is (flagged).
        let p = w.model(.library)
        await p.add(urls: [try w.file("aws.txt", Self.awsLine)])
        #expect(p.secretSheet?.showsUploadAnyway == true)
        #expect(p.secretSheet?.title.hasPrefix("This file looks like it contains a secret (") == true)
        await p.resolveSecret(.uploadAnyway)
        #expect(await p.commit(message: ""))
        #expect(try w.rows().last?.secretScan == .flagged)
    }

    @Test func storeAsSecretNeedsValidName() async throws {
        let w = try await W()
        let m = w.model(.library)
        await m.add(urls: [try w.file("aws.txt", Self.awsLine)])
        #expect(m.secretSheet?.canStoreAsSecret == true)
        await m.resolveSecret(.storeAsSecret(name: "not valid"))
        #expect(m.secretSheet?.error != nil)
        #expect(m.pending.count == 1)
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)

        await m.resolveSecret(.storeAsSecret(name: "AWS_KEY"))
        #expect(m.secretSheet == nil)
        #expect(m.pending.isEmpty)
        #expect(try w.app.secretVault.value(companyId: w.company.id, name: "AWS_KEY") == Self.awsLine)
        #expect(try w.rows().isEmpty)

        // Two files can't be stored as one secret.
        let two = w.model(.library)
        await two.add(urls: [try w.file("a.txt", Self.awsLine), try w.file("b.txt", "plain\n")])
        #expect(two.secretSheet?.canStoreAsSecret == false)
        // Cancel drops the pending drop.
        await two.resolveSecret(.none)
        #expect(two.secretSheet == nil)
        #expect(two.pending.isEmpty)
    }

    @Test func pasteImageWritesPNGToHomeTmp() async throws {
        let w = try await W()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00,
                        0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x3A, 0x7E, 0x9B, 0x55, 0x00, 0x00, 0x00,
                        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x48, 0xAF, 0xA4,
                        0x71, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        let m = w.model(.library)
        await m.addPasteboardImage(png)
        let drop = try #require(m.pending.first)
        #expect(drop.name.hasPrefix("paste-") && drop.name.hasSuffix(".png"))
        #expect(drop.chip == .fromYou)
        let pasted = try FileManager.default.contentsOfDirectory(atPath: w.paths.tmpDir.path).filter { $0.hasPrefix("paste-") }
        #expect(pasted == [drop.name])
        let attrs = try FileManager.default.attributesOfItem(atPath: w.paths.tmpDir.appending(path: drop.name).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: w.paths.tmpDir.path)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try Data(contentsOf: w.paths.tmpDir.appending(path: drop.name)) == png)
        // Removing the pending paste deletes its temporary file.
        m.remove(drop.id)
        #expect(m.pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: w.paths.tmpDir.appending(path: drop.name).path))
    }

    @Test func advisoryOnWorkspaceProfileConfirmsOnce() async throws {
        let w = try await W()
        let m = w.model(.dm(handle: "eng"))
        #expect(m.showsAdvisory)
        #expect(ResourceDropModel.advisoryText
                == "Resource scopes, lab privacy and mirror integrity are enforced only by Brahma's tools; an agent's shell can read or change them.")
        await m.add(urls: [try w.file("notes.md", "# notes\n")])
        // The first non-company-scope drop asks first; nothing is added.
        #expect(await m.commit(message: "") == false)
        #expect(m.advisoryPrompt)
        #expect(try w.rows().isEmpty)
        #expect(m.pending.count == 1)
        m.acknowledgeAdvisory()
        #expect(!m.advisoryPrompt)
        #expect(w.defaults.bool(forKey: "advisoryAck.\(w.company.id)"))
        #expect(await m.commit(message: ""))
        #expect(try w.rows().count == 1)
        // Once per company: the next drop (another model, same defaults) goes straight through.
        let again = w.model(.dm(handle: "eng"))
        await again.add(urls: [try w.file("more.md", "# more\n")])
        #expect(await again.commit(message: ""))
        #expect(!again.advisoryPrompt)
        #expect(try w.rows().count == 2)

        // A company-scope drop never asks, and a sandboxed company shows no chip.
        let fresh = try await W()
        let library = fresh.model(.library)
        await library.add(urls: [try fresh.file("a.md", "a\n")])
        #expect(await library.commit(message: ""))
        #expect(!library.advisoryPrompt)
        try fresh.store.updateSandbox(companyId: fresh.company.id, SandboxPatch(profile: .sandboxed), userHome: try tempDir())
        await fresh.app.tick(forceSnapshot: true)
        #expect(!fresh.model(.dm(handle: "eng")).showsAdvisory)
    }

    @Test func sendWithDropsPostsOneMessage() async throws {
        let w = try await W()
        w.ackAdvisory()
        w.app.select(.dm(handle: "eng"))
        let chat = try #require(w.app.chat)
        await chat.refresh()
        let drops = try #require(chat.drops)
        #expect(drops.context == .dm(handle: "eng"))
        await drops.add(urls: [try w.file("notes.md", "# notes\n")])
        chat.draft = "see the notes"
        #expect(await chat.send())
        let dm = try #require(try w.store.channel(companyId: w.company.id, name: "dm:eng:owner"))
        let messages = try w.store.messages(channelId: dm.id, limit: 50)
        #expect(messages.count == 1)
        let text = try #require(messages.first?.text)
        #expect(text.hasPrefix("see the notes\n[file F-1 · \"notes.md\" · "))
        #expect(chat.draft.isEmpty)
        #expect(drops.pending.isEmpty)
        #expect(chat.messages.count == 1)
        // Without drops, an empty draft sends nothing.
        #expect(await chat.send() == false)
    }

    @Test func severalDropsKeepTheirTrustInOneMessage() async throws {
        let w = try await W()
        w.ackAdvisory()
        let m = w.model(.dm(handle: "eng"))
        await m.add(urls: [try w.pdf("report.pdf")])
        await m.add(urls: [try w.file("notes.md", "# notes\n")])
        m.addLink("https://example.com/spec")
        m.setTrust(m.pending[0].id, .vouched)
        m.setTrust(m.pending[1].id, .untrusted)
        // A folder goes on its own.
        let folder = w.drops.appending(path: "docs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: folder.appending(path: "a.md"))
        await m.add(urls: [folder])
        #expect(m.pending.count == 3)
        #expect(w.app.errorMessage == "A folder is added on its own; send or remove the pending files first.")

        #expect(await m.commit(message: "three things"))
        let rows = try w.rows()
        #expect(rows.map(\.ref) == ["F-1", "F-2", "F-3"])
        #expect(!rows[0].tainted)
        #expect(rows[1].tainted && rows[1].taintReason == "marked untrusted by you")
        #expect(rows[2].kind == .link && !rows[2].tainted)
        // The owner's words go once, with the files; the link is announced by its ref.
        let dm = try #require(try w.store.channel(companyId: w.company.id, name: "dm:eng:owner"))
        let texts = try w.store.messages(channelId: dm.id, limit: 10).map(\.text)
        #expect(texts.count == 2)
        #expect(texts[0].hasPrefix("three things\n[file F-1 · "))
        #expect(texts[1] == "[link F-3]")
        #expect(m.pending.isEmpty)
    }

    @Test func inboxDropAnswersAsk() async throws {
        let w = try await W()
        w.ackAdvisory()
        let ask = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.cto.id), title: "Data", question: "Which file?")
        let m = w.model(.inbox(askId: ask.id))
        await m.add(urls: [try w.file("data.csv", "a,b\n1,2\n")])
        #expect(await m.commit(message: "here you go"))
        let answered = try #require(try w.store.ask(id: ask.id))
        #expect(answered.status == .answered)
        #expect(answered.ownerAnswer?.hasPrefix("here you go\n[file F-1 · \"data.csv\" · ") == true)
        let row = try #require(try w.rows().first)
        #expect(row.scope == .agent(w.cto.id))
        #expect(row.askId == ask.id)
    }

    @Test func refusalsShownNotCommitted() async throws {
        let w = try await W()
        w.ackAdvisory()
        // Refused at inspection: shown, never pending.
        let m = w.model(.dm(handle: "eng"))
        await m.add(urls: [try w.file("tool.exe", "MZ")])
        #expect(m.pending.isEmpty)
        #expect(w.app.errorMessage?.contains("tool.exe: executables can't be added as resources") == true)
        w.app.errorMessage = nil

        // Refused at commit: the scope doesn't let @eng read it. Nothing is stored or posted; the drop stays pending.
        await m.add(urls: [try w.file("notes.md", "# notes\n")])
        await m.setScope(.team("payments"))
        #expect(await m.commit(message: "for you") == false)
        #expect(w.app.errorMessage == "@eng can't all read this; change the scope or drop it in a DM")
        #expect(try w.rows().isEmpty)
        #expect(try w.store.channel(companyId: w.company.id, name: "dm:eng:owner").map { try w.store.messages(channelId: $0.id, limit: 5) }?.isEmpty ?? true)
        #expect(m.pending.count == 1)

        // A link that isn't http(s) is refused the same way.
        m.addLink("file:///etc/passwd")
        #expect(m.pending.count == 1)
        #expect(w.app.errorMessage == "only http and https links can be added")
    }
}
