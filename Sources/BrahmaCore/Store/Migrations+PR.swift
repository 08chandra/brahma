import GRDB

extension Migrations {
    /// Plan X8 migrations: registered after every earlier plan's, in landing order. Never edit an earlier one.
    static func registerPlanX8(_ m: inout DatabaseMigrator) {
        m.registerMigration("vX5-pr") { db in
            // How approved items reach `main` (`LandingMode`) and whether the engine may merge a mergeable PR itself. Both are
            // setter-owned (`Store.setLanding`); `updateCompany` keeps the stored values.
            try db.alter(table: "company") { t in
                t.add(column: "landing", .text).notNull().defaults(to: LandingMode.local.rawValue)
                t.add(column: "engineMerge", .boolean).notNull().defaults(to: false)
            }
            // One row per item: the pushed commit, the PR and where the landing is (`PRLanding`).
            try db.execute(sql: """
                CREATE TABLE prLanding (
                    itemId TEXT PRIMARY KEY NOT NULL REFERENCES workItem(id) ON DELETE CASCADE,
                    companyId TEXT NOT NULL REFERENCES company(id) ON DELETE CASCADE,
                    branch TEXT NOT NULL,
                    pushedSHA TEXT NOT NULL,
                    prNumber INTEGER,
                    prURL TEXT,
                    state TEXT NOT NULL,
                    lastPolled DATETIME,
                    lastError TEXT,
                    mergedSHA TEXT,
                    updatedAt DATETIME NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX prLanding_company ON prLanding(companyId, state)")
            // The owner's trusted provider logins (`TrustedLogin`).
            try db.execute(sql: """
                CREATE TABLE trustedLogin (
                    companyId TEXT NOT NULL REFERENCES company(id) ON DELETE CASCADE,
                    login TEXT NOT NULL,
                    addedBy TEXT NOT NULL,
                    addedAt DATETIME NOT NULL,
                    PRIMARY KEY (companyId, login)
                )
                """)
            // At most one issue source per provider and company (`IssueLink`).
            try db.execute(sql: """
                CREATE TABLE issueLink (
                    companyId TEXT NOT NULL REFERENCES company(id) ON DELETE CASCADE,
                    provider TEXT NOT NULL,
                    target TEXT NOT NULL,
                    label TEXT,
                    cursor TEXT,
                    lastPolled DATETIME,
                    PRIMARY KEY (companyId, provider)
                )
                """)
            // Where an imported item came from (`ItemOrigin`); an issue imports once per company.
            try db.alter(table: "workItem") { t in
                t.add(column: "originURL", .text)
                t.add(column: "originAuthor", .text)
                t.add(column: "originTrusted", .boolean).notNull().defaults(to: false)
                t.add(column: "originId", .text)
            }
            try db.execute(sql: "CREATE UNIQUE INDEX workItem_origin ON workItem(companyId, originURL) WHERE originURL IS NOT NULL")
        }
        // Task 3 (Ruling 26): the owner card for a GitHub action the gate asked about, and its one-shot approval
        // (`PRActionApproval`): one per (company, item, action, sha).
        m.registerMigration("vX5-pr-2") { db in
            try db.execute(sql: """
                CREATE TABLE prActionApproval (
                    askId TEXT PRIMARY KEY NOT NULL REFERENCES ask(id) ON DELETE CASCADE,
                    companyId TEXT NOT NULL REFERENCES company(id) ON DELETE CASCADE,
                    itemId TEXT NOT NULL REFERENCES workItem(id) ON DELETE CASCADE,
                    action TEXT NOT NULL,
                    sha TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    approvedAt DATETIME,
                    consumedAt DATETIME,
                    createdAt DATETIME NOT NULL
                )
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX prActionApproval_tuple ON prActionApproval(companyId, itemId, action, sha)")
        }
        // Task 3 fix round 1: the approval is bound to exactly what the owner saw (Rulings X8-21, 29: `digest` of the canonical
        // request), and a landing remembers the digest of the PR content it sent (Ruling 28: only that PR is ever adopted).
        m.registerMigration("vX5-pr-3") { db in
            try db.alter(table: "prActionApproval") { t in t.add(column: "digest", .text).notNull().defaults(to: "") }
            try db.alter(table: "prLanding") { t in t.add(column: "openDigest", .text) }
        }
    }
}
