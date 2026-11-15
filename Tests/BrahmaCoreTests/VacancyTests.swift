import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home (file owner-key and secret stores: never the Keychain).
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
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    let inp = Pipe()
    if stdin == nil { p.standardInput = FileHandle.nullDevice } else { p.standardInput = inp }
    try p.run()
    if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try inp.fileHandleForWriting.close() }
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// Plan 4b, Task 1b: the owner adds and removes vacancies over 3a's `orgVacancy`.
@Suite(.scratch) struct VacancyTests {
    private let software = PackCatalog.builtin.pack("software")!

    /// Acme on the Workspace profile with a seated CTO.
    private func seedAcme() throws -> (Store, Company, Agent) {
        let s = try Store.inMemory()
        let root = try tempDir()
        let c = try onWorkspaceProfile(s, try s.createCompany(name: "Acme", goal: "g", workspacesRoot: root))
        let cto = try s.hire(companyId: c.id, name: "cto", role: "cto", model: "auto")
        return (s, c, cto)
    }

    private func vacancyRow(_ s: Store, _ c: Company, _ handle: String) throws -> OrgVacancy? {
        try s.writer.read { db in
            try OrgVacancy.filter(Column("companyId") == c.id && Column("handle") == handle).fetchOne(db)
        }
    }

    @Test func addListRemove() throws {
        let (s, c, _) = try seedAcme()
        _ = try s.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "auto")
        let v = try s.addVacancy(companyId: c.id, role: "engineer", managerHandle: "cto", team: nil, note: "")
        #expect(v.handle == "eng-2"); #expect(v.managerHandle == "cto"); #expect(v.role == "engineer")
        #expect(v.filledAt == nil); #expect(v.removedAt == nil); #expect(v.note == "")
        let listed = try s.vacancies(companyId: c.id)
        #expect(listed.map(\.handle) == ["eng-2"])

        try s.removeVacancy(companyId: c.id, handle: "@Eng-2")
        #expect(try s.vacancies(companyId: c.id).isEmpty)
        #expect(try #require(try vacancyRow(s, c, "eng-2")).removedAt != nil)
        // The next add gets a new handle: the removed one stays reserved.
        let next = try s.addVacancy(companyId: c.id, role: "engineer", managerHandle: nil, team: nil, note: "")
        #expect(next.handle == "eng-3"); #expect(next.managerHandle == nil)
        #expect(try s.vacancies(companyId: c.id).map(\.handle) == ["eng-3"])
        // After the remove: 3a's fill finds no seat, and a manual hire of the handle is refused.
        #expect(throws: StoreError.notFound) { try s.fillVacancy(companyId: c.id, handle: "eng-2") }
        #expect(throws: StoreError.duplicateName) { try s.hire(companyId: c.id, name: "eng-2", role: "engineer", model: "auto") }
        #expect(try s.nextHandle(companyId: c.id, prefix: "eng") == "eng-4")
        // Removing it again: not found.
        #expect(throws: StoreError.notFound) { try s.removeVacancy(companyId: c.id, handle: "eng-2") }
    }

    @Test func validation() throws {
        let (s, c, _) = try seedAcme()
        func add(_ role: String = "engineer", manager: String? = "cto", team: String? = nil, note: String = "") throws -> OrgVacancy {
            try s.addVacancy(companyId: c.id, role: role, managerHandle: manager, team: team, note: note)
        }
        #expect(throws: WorkError.invalid("unknown role wizard")) { try add("wizard") }
        #expect(throws: WorkError.invalid("vacancy notes are at most 280 characters")) {
            try add(note: String(repeating: "x", count: 281))
        }
        _ = try add(note: String(repeating: "x", count: 280))
        #expect(throws: WorkError.invalid("team names are lowercase letters, digits, - and _")) { try add(team: "Bad Team!") }
        // Managers: another company's agent is not in this one; a killed agent is gone; an open seat is not seated.
        let globex = try onWorkspaceProfile(s, try s.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir()))
        _ = try s.hire(companyId: globex.id, name: "gx", role: "engineer", model: "auto")
        #expect(throws: WorkError.forbidden("not in your company")) { try add(manager: "gx") }
        #expect(throws: WorkError.forbidden("not in your company")) { try add(manager: "nobody") }
        let eng = try s.hire(companyId: c.id, name: "eng", role: "engineer", model: "auto")
        _ = try s.transition(agentId: eng.id, to: .killed)
        #expect(throws: WorkError.invalid("@eng is no longer with the company")) { try add(manager: "@eng") }
        let upper = try add(manager: "@CTO")
        let lower = try add(manager: "cto ")
        #expect(upper.managerHandle == "cto"); #expect(lower.managerHandle == "cto")
        #expect(throws: WorkError.invalid("@\(upper.handle) is an open seat; pick a seated manager")) { try add(manager: upper.handle) }
        // Normalization: role is trimmed and lowercased; an empty team is nil; a valid team is kept.
        let normalized = try add(" Engineer ", team: "")
        #expect(normalized.role == "engineer"); #expect(normalized.team == nil)
        #expect(try add(team: "core-2").team == "core-2")
        // Removing a filled seat conflicts; an unknown handle is not found.
        _ = try s.fillVacancy(companyId: c.id, handle: lower.handle)
        #expect(throws: WorkError.conflict("@\(lower.handle) is already filled")) { try s.removeVacancy(companyId: c.id, handle: lower.handle) }
        #expect(throws: StoreError.notFound) { try s.removeVacancy(companyId: c.id, handle: "eng-99") }
        // A company whose pack is not installed cannot add seats (checked before the role).
        try s.writer.write { db in try db.execute(sql: "UPDATE company SET packId = 'nope' WHERE id = ?", arguments: [c.id]) }
        #expect(throws: WorkError.invalid("company pack nope is not installed")) { try add("wizard") }
    }

    @Test func noteIsRedacted() throws {
        let (s, c, _) = try seedAcme()
        s.redactor.update([(name: "API_KEY", value: "sk-test-1234567890")], version: "t")
        let v = try s.addVacancy(companyId: c.id, role: "engineer", managerHandle: "cto", team: nil,
                                 note: "needs key sk-test-1234567890 for the gateway")
        #expect(v.note == "needs key [redacted API_KEY] for the gateway")
        let stored = try #require(try vacancyRow(s, c, v.handle))
        #expect(stored.note.contains("[redacted API_KEY]")); #expect(!stored.note.contains("sk-test-1234567890"))
        #expect(try s.vacancies(companyId: c.id).first?.note == stored.note)
        #expect(!(try dumpDatabase(s)).contains("sk-test-1234567890"))
        // The length check counts the raw note, before redaction.
        let long = String(repeating: "sk-test-1234567890", count: 16)   // 288 characters; 16 × "[redacted API_KEY]" is shorter
        #expect(throws: WorkError.invalid("vacancy notes are at most 280 characters")) {
            try s.addVacancy(companyId: c.id, role: "engineer", managerHandle: nil, team: nil, note: long)
        }

        // `brahma org vacancies` shows the stored (redacted) note.
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g"], home: home)
        #expect(created.status == 0, "\(created.stderr)")
        let file = try Store(path: ownerPaths(home).database.path)
        file.redactor.update([(name: "API_KEY", value: "sk-test-1234567890")], version: "t")
        let acme = try #require(try file.companies().first { $0.name == "Acme" })
        let fv = try file.addVacancy(companyId: acme.id, role: "engineer", managerHandle: "cto", team: nil, note: "key sk-test-1234567890")
        try file.close()
        let listed = try brahma(["org", "vacancies", "Acme"], home: home)
        #expect(listed.status == 0, "\(listed.stderr)")
        #expect(listed.stdout.contains(fv.handle)); #expect(listed.stdout.contains("[redacted API_KEY]"))
        #expect(!listed.stdout.contains("sk-test-1234567890"))
    }

    @Test func handlesPickedInsideTheWriteTransaction() async throws {
        let (s, c, _) = try seedAcme()
        for i in 1...3 { _ = try s.hire(companyId: c.id, name: "eng-\(i)", role: "engineer", model: "auto") }
        let handles = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<20 {
                group.addTask { try s.addVacancy(companyId: c.id, role: "engineer", managerHandle: "cto", team: nil, note: "").handle }
            }
            var out: [String] = []
            for try await h in group { out.append(h) }
            return out
        }
        #expect(handles.count == 20); #expect(Set(handles).count == 20)
        let agents = Set(try s.agents(companyId: c.id).map(\.name))
        #expect(agents.isDisjoint(with: handles))
        #expect(Set(handles) == Set((4...23).map { "eng-\($0)" }))
        #expect(try s.vacancies(companyId: c.id).count == 20)
    }

    @Test func uniqueHandleIndex() throws {
        let (s, c, _) = try seedAcme()
        let other = try onWorkspaceProfile(s, try s.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir()))
        let now = Store.now()
        func insert(_ companyId: String) throws {
            try s.writer.write { db in
                var row = OrgVacancy(id: nil, companyId: companyId, role: "engineer", handle: "eng-7", managerHandle: nil,
                                     team: nil, createdAt: now, filledAt: nil)
                try row.insert(db)
            }
        }
        try insert(c.id)
        do { try insert(c.id); Issue.record("expected a constraint error") }
        catch let error as DatabaseError { #expect(error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE) }
        try insert(other.id)
        #expect(try s.vacancies(companyId: c.id).count == 1); #expect(try s.vacancies(companyId: other.id).count == 1)
        // Every row counts for `nextHandle`, removed ones included: a removed handle is never handed out again.
        #expect(try s.nextHandle(companyId: c.id, prefix: "eng") == "eng-8")
        try s.writer.write { db in
            var row = OrgVacancy(id: nil, companyId: c.id, role: "engineer", handle: "eng-9", managerHandle: nil, team: nil,
                                 createdAt: now, filledAt: nil, note: "", removedAt: now)
            try row.insert(db)
        }
        #expect(try s.nextHandle(companyId: c.id, prefix: "eng") == "eng-10")
        #expect(try s.vacancies(companyId: c.id).map(\.handle) == ["eng-7"])
    }

    @Test func fillUsesThreeA() throws {
        let (s, c, cto) = try seedAcme()
        let v = try s.addVacancy(companyId: c.id, role: "engineer", managerHandle: "cto", team: "core", note: "n")
        let a = try s.fillVacancy(companyId: c.id, handle: v.handle)
        #expect(a.name == v.handle); #expect(a.role == "engineer"); #expect(a.managerId == cto.id); #expect(a.team == "core")
        #expect(a.model == "auto")
        let row = try #require(try vacancyRow(s, c, v.handle))
        #expect(row.filledAt != nil); #expect(row.removedAt == nil); #expect(row.note == "n")
        #expect(try s.vacancies(companyId: c.id).isEmpty)
        #expect(throws: StoreError.notFound) { try s.fillVacancy(companyId: c.id, handle: v.handle) }
        #expect(try s.members(channelId: try #require(try s.channel(companyId: c.id, name: "team-core")).id) == [a.id])
    }

    @Test func migrationRegistersAfterEveryPlanLMigration() throws {
        let names = Migrations.migrator().migrations
        #expect(names.last == "v4b-vacancy-note")
        let last = try #require(names.firstIndex(of: "vL-release-2"))
        let note = try #require(names.firstIndex(of: "v4b-vacancy-note"))
        #expect(note > last)
        #expect(names.filter { $0.hasPrefix("vL-") }.allSatisfy { names.firstIndex(of: $0)! < note })
    }

    @Test func migrationFailsClosedOnDuplicateHandles() throws {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        let migrator = Migrations.migrator()
        try migrator.migrate(queue, upTo: "v5-modes")
        try queue.write { db in
            for company in ["c1", "c1", "c2"] {
                try db.execute(sql: "INSERT INTO orgVacancy (companyId, role, handle, createdAt) VALUES (?, 'engineer', 'eng-1', ?)",
                               arguments: [company, Date()])
            }
        }
        do { try migrator.migrate(queue); Issue.record("expected the migration to fail") }
        catch { #expect("\(error)".contains("orgVacancy has duplicate handles: c1/eng-1"), "\(error)") }
        let (columnsBefore, indexesBefore, completed) = try queue.read { db in
            (try db.columns(in: "orgVacancy").map(\.name), try db.indexes(on: "orgVacancy").map(\.name), try migrator.completedMigrations(db))
        }
        #expect(!columnsBefore.contains("note")); #expect(!columnsBefore.contains("removedAt"))
        #expect(!indexesBefore.contains("orgVacancy_company_handle"))
        // The Plan L migrations ran (each its own transaction); the refused 4b migration is the first one not completed.
        #expect(completed.last == "vL-release-2")
        #expect(!completed.contains("v4b-vacancy-note"))
        // Without the duplicate the migration completes, with the unique index.
        try queue.write { db in try db.execute(sql: "DELETE FROM orgVacancy WHERE rowid = 2") }
        try migrator.migrate(queue)
        let (columnsAfter, indexesAfter) = try queue.read { db in
            (try db.columns(in: "orgVacancy").map(\.name), try db.indexes(on: "orgVacancy"))
        }
        #expect(columnsAfter.contains("note")); #expect(columnsAfter.contains("removedAt"))
        #expect(indexesAfter.contains { $0.name == "orgVacancy_company_handle" && $0.isUnique })
    }

    @Test func cliAddAndRemove() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g"], home: home)
        #expect(created.status == 0, "\(created.stderr)")
        #expect(try brahma(["org", "fill", "Acme", "qa-1"], home: home).status == 0)   // the plan's own open seat
        #expect(try brahma(["org", "vacancies", "Acme"], home: home).stdout == "(no vacancies)\n")

        let add = try brahma(["org", "vacancy", "add", "Acme", "--role", "engineer", "--manager", "@CTO", "--team", "core",
                              "--note", "needs Rust\u{1B}[2J"], home: home)
        #expect(add.status == 0, "\(add.stderr)")
        let handle = try #require(add.stdout.split(separator: " ").dropFirst().first.map { String($0.dropFirst()) })
        #expect(add.stdout == "Vacancy @\(handle) for engineer under @cto\n", "\(add.stdout)")
        #expect(handle.hasPrefix("eng-"))
        let listed = try brahma(["org", "vacancies", "Acme"], home: home)
        #expect(listed.status == 0, "\(listed.stderr)")
        #expect(listed.stdout.contains("\(handle)  engineer  manager: cto  team: core  note: needs Rust"), "\(listed.stdout)")
        #expect(!listed.stdout.contains("\u{1B}"))
        let board = try brahma(["org", "vacancy", "add", "Acme", "--role", "qa"], home: home)
        #expect(board.status == 0, "\(board.stderr)"); #expect(board.stdout.hasSuffix("for qa under @board\n"), "\(board.stdout)")
        // Refusals come back as plain CLI errors.
        let bad = try brahma(["org", "vacancy", "add", "Acme", "--role", "wizard"], home: home)
        #expect(bad.status == 1); #expect(bad.stderr.contains("unknown role wizard"))
        let open = try brahma(["org", "vacancy", "add", "Acme", "--role", "engineer", "--manager", handle], home: home)
        #expect(open.status == 1); #expect(open.stderr.contains("@\(handle) is an open seat; pick a seated manager"))

        let remove = try brahma(["org", "vacancy", "remove", "Acme", handle], home: home)
        #expect(remove.status == 0, "\(remove.stderr)"); #expect(remove.stdout == "removed vacancy @\(handle)\n")
        let qaHandle = try #require(board.stdout.split(separator: " ").dropFirst().first.map { String($0.dropFirst()) })
        #expect(try brahma(["org", "vacancy", "remove", "Acme", "@" + qaHandle], home: home).status == 0)
        #expect(try brahma(["org", "vacancies", "Acme"], home: home).stdout == "(no vacancies)\n")
        let again = try brahma(["org", "vacancy", "remove", "Acme", handle], home: home)
        #expect(again.status == 1); #expect(again.stderr.contains("no open vacancy @\(handle) in Acme"))
        let filled = try brahma(["org", "vacancy", "remove", "Acme", "qa-1"], home: home)
        #expect(filled.status == 1); #expect(filled.stderr.contains("@qa-1 is already filled"))
        #expect(try brahma(["org", "fill", "Acme", handle], home: home).status == 1)
    }

    @Test func cliRefusesInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let add = try brahma(["org", "vacancy", "add", "Acme", "--role", "engineer"], home: home, env: ["BRAHMA_AGENT_ID": "x"])
        #expect(add.status == 1); #expect(add.stdout.isEmpty)
        // The refused add wrote no row: only the plan's own seat is there.
        let file = try Store(path: ownerPaths(home).database.path)
        let acme = try #require(try file.companies().first { $0.name == "Acme" })
        #expect(try file.writer.read { db in try OrgVacancy.filter(Column("companyId") == acme.id).fetchCount(db) } == 1)
        try file.close()
        let remove = try brahma(["org", "vacancy", "remove", "Acme", "qa-1"], home: home, env: ["BRAHMA_AGENT_ID": "x"])
        #expect(remove.status == 1)
        #expect(try brahma(["org", "vacancies", "Acme"], home: home).stdout.contains("qa-1"))
    }

    /// The note is owner-only: `brahma org vacancies` still lists open seats inside an agent turn, never their notes.
    @Test func cliHidesNotesInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let secretNote = "owner-only-zebra-7731 hire before Q3"
        let add = try brahma(["org", "vacancy", "add", "Acme", "--role", "engineer", "--note", secretNote], home: home)
        #expect(add.status == 0, "\(add.stderr)")
        let handle = try #require(add.stdout.split(separator: " ").dropFirst().first.map { String($0.dropFirst()) })

        let agent = try brahma(["org", "vacancies", "Acme"], home: home, env: ["BRAHMA_AGENT_ID": "x"])
        #expect(agent.status == 0, "\(agent.stderr)")
        #expect(agent.stdout.contains("\(handle)  engineer  manager: none  team: none\n"), "\(agent.stdout)")
        #expect(agent.stdout.contains("qa-1"))
        #expect(!agent.stdout.contains("zebra-7731")); #expect(!agent.stderr.contains("zebra-7731"))
        #expect(!agent.stdout.contains("note:"))
        // Inside a turn the listing is quiet: no refusal text on stderr for a command that succeeded.
        #expect(agent.stderr.isEmpty, "\(agent.stderr)")

        let mine = try brahma(["org", "vacancies", "Acme"], home: home)
        #expect(mine.status == 0, "\(mine.stderr)")
        #expect(mine.stdout.contains("\(handle)  engineer  manager: none  team: none  note: \(secretNote)"), "\(mine.stdout)")
    }

    /// The owner's listing redacts the note again at print time: a secret set after the note was stored never prints.
    @Test func cliRedactsNotesAtPrintTime() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let add = try brahma(["org", "vacancy", "add", "Acme", "--role", "engineer", "--note", "ci token vac-secret-value-77 here"],
                             home: home)
        #expect(add.status == 0, "\(add.stderr)")
        let set = try brahma(["secret", "set", "Acme", "API_KEY"], home: home, stdin: "vac-secret-value-77\n")
        #expect(set.status == 0, "\(set.stderr)")

        let mine = try brahma(["org", "vacancies", "Acme"], home: home)
        #expect(mine.status == 0, "\(mine.stderr)")
        #expect(mine.stdout.contains("note: ci token [redacted API_KEY] here"), "\(mine.stdout)")
        #expect(!mine.stdout.contains("vac-secret-value-77")); #expect(!mine.stderr.contains("vac-secret-value-77"))
        let agent = try brahma(["org", "vacancies", "Acme"], home: home, env: ["BRAHMA_AGENT_ID": "x"])
        #expect(agent.status == 0, "\(agent.stderr)")
        #expect(!agent.stdout.contains("vac-secret-value-77")); #expect(!agent.stdout.contains("ci token"))
    }
}
