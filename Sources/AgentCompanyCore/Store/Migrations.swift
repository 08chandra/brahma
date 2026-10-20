import GRDB

enum Migrations {
    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "company") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("slug", .text).notNull().unique()
                t.column("goal", .text).notNull()
                t.column("workspacePath", .text).notNull()
                t.column("status", .text).notNull()
                t.column("usageMode", .text).notNull()
                t.column("priorityWeight", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "agent") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("role", .text).notNull()
                t.column("model", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("sessionStarted", .boolean).notNull()
                t.column("state", .text).notNull()
                t.column("blocker", .text)
                t.column("requestedBlocker", .text)
                t.column("paused", .boolean).notNull()
                t.column("readySince", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["companyId", "name"])
            }
            try db.create(table: "turn") { t in
                t.primaryKey("id", .text)
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("outcome", .text).notNull()
                t.column("summary", .text)
                t.column("costUSD", .double)
            }
            try db.create(index: "turn_agent_started", on: "turn", columns: ["agentId", "startedAt"])
            try db.create(table: "activityEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("agentId", .text)
                t.column("turnId", .text)
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "channel") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["companyId", "name"])
            }
            try db.create(table: "channelMember") { t in
                t.column("channelId", .text).notNull().references("channel", onDelete: .cascade)
                t.column("member", .text).notNull()
                t.primaryKey(["channelId", "member"])
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("channelId", .text).notNull().references("channel", onDelete: .cascade)
                t.column("senderId", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "message_channel_created", on: "message", columns: ["channelId", "createdAt"])
            try db.create(table: "inboxItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("messageId", .text).notNull().references("message", onDelete: .cascade)
                t.column("deliveredTurnId", .text)
            }
            try db.create(index: "inbox_agent_pending", on: "inboxItem", columns: ["agentId", "deliveredTurnId"])
            try db.create(table: "usageState") { t in
                t.primaryKey("id", .integer)
                t.column("status", .text).notNull()
                t.column("resetsAt", .datetime)
                t.column("rateLimitType", .text)
                t.column("isUsingOverage", .boolean).notNull()
                t.column("fiveHourUtilization", .double)
                t.column("sevenDayUtilization", .double)
                t.column("observedAt", .datetime).notNull()
            }
            // Messages are never edited or deleted in Plan 1, so an insert trigger keeps the index current.
            try db.execute(sql: "CREATE VIRTUAL TABLE messageFts USING fts5(text, content='message', content_rowid='rowid')")
            try db.execute(sql: """
                CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                    INSERT INTO messageFts(rowid, text) VALUES (new.rowid, new.text);
                END
                """)
        }
        return m
    }
}
