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
                t.column("consecutiveFailures", .integer).notNull().defaults(to: 0)
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
            // `brahma run` and the event feeds page by (companyId, id).
            try db.create(index: "activityEvent_company_id", on: "activityEvent", columns: ["companyId", "id"])
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
                t.column("fiveHourResetsAt", .datetime)
                t.column("sevenDayResetsAt", .datetime)
            }
            // Messages are never edited or deleted in Plan 1, so an insert trigger keeps the index current.
            try db.execute(sql: "CREATE VIRTUAL TABLE messageFts USING fts5(text, content='message', content_rowid='rowid')")
            try db.execute(sql: """
                CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                    INSERT INTO messageFts(rowid, text) VALUES (new.rowid, new.text);
                END
                """)
        }
        m.registerMigration("v2-owner-read") { db in
            try db.create(table: "ownerReadMark") { t in
                t.primaryKey("channelId", .text).references("channel", onDelete: .cascade)
                t.column("lastReadAt", .datetime).notNull()
            }
        }
        m.registerMigration("v3-org") { db in
            try db.alter(table: "company") { t in
                t.add(column: "packId", .text).notNull().defaults(to: "software")
                t.add(column: "packVersion", .integer).notNull().defaults(to: 1)
            }
            try db.alter(table: "agent") { t in
                t.add(column: "managerId", .text).references("agent", onDelete: .setNull)
                t.add(column: "team", .text)
                t.add(column: "trustLevel", .text).notNull().defaults(to: "T1")
            }
            try db.create(table: "orgVacancy") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("handle", .text).notNull()
                t.column("managerHandle", .text)
                t.column("team", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("filledAt", .datetime)
            }
            try db.create(index: "orgVacancy_company", on: "orgVacancy", columns: ["companyId", "filledAt"])
        }
        m.registerMigration("v3-wake") { db in
            try db.alter(table: "inboxItem") { t in
                t.add(column: "wakes", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "broadcastLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("senderId", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "broadcastLog_sender_created", on: "broadcastLog", columns: ["senderId", "createdAt"])
        }
        m.registerMigration("v3-engine") { db in
            try db.create(table: "engineProbe") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("report", .text).notNull()
                t.column("checkedAt", .datetime).notNull()
            }
        }
        m.registerMigration("v3-mcp-auth") { db in
            try db.create(table: "turnCredential") { t in
                t.primaryKey("turnId", .text).references("turn", onDelete: .cascade)
                t.column("companyId", .text).notNull()
                t.column("agentId", .text).notNull()
                t.column("kind", .text).notNull().defaults(to: "work")
                t.column("itemId", .text)
                t.column("tokenHash", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "turnCredential_hash", on: "turnCredential", columns: ["tokenHash"])
        }
        m.registerMigration("v3-clock") { db in
            try db.create(table: "companyActivity") { t in
                t.primaryKey("companyId", .text).references("company", onDelete: .cascade)
                t.column("activeSeconds", .double).notNull().defaults(to: 0)
                t.column("lastAccruedAt", .datetime)
            }
            try db.create(table: "ownerSettings") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("timeZone", .text).notNull()
                t.column("planTier", .text).notNull().defaults(to: "max5x")
                t.column("weeklyShare", .double).notNull().defaults(to: 0.7)
                t.column("pctPerDollar", .double)
                // Calibration baseline: the last weekly-utilization snapshot and the cost accumulated since.
                t.column("calibUtil", .double)
                t.column("calibResetsAt", .datetime)
                t.column("calibCost", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "engineHold") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("reason", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("since", .datetime).notNull()
                t.column("nextProbeAt", .datetime)
            }
            try db.alter(table: "turn") { t in t.add(column: "infra", .boolean).notNull().defaults(to: false) }
            try db.alter(table: "company") { t in t.add(column: "ownerReserve", .double) }
            try db.alter(table: "agent") { t in t.add(column: "consecutiveInfraFailures", .integer).notNull().defaults(to: 0) }
        }
        m.registerMigration("v3-clock-calibration") { db in
            // Windowed calibration state (JSON) and the five-hour estimate; the v3-clock calibration columns are unused.
            try db.alter(table: "ownerSettings") { t in
                t.add(column: "calibration", .text)
                t.add(column: "pctPerDollar5h", .double)
            }
        }
        m.registerMigration("v3-work") { db in
            try db.create(table: "workItem") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("acceptanceCriteria", .text).notNull().defaults(to: "")
                t.column("checkSpec", .text)
                t.column("checkRevision", .integer).notNull().defaults(to: 0)
                t.column("reviewFlags", .text).notNull().defaults(to: "[]")
                t.column("status", .text).notNull()
                t.column("blockedReason", .text)
                t.column("blockedSinceActive", .double)
                t.column("priority", .integer).notNull().defaults(to: 2)
                t.column("points", .integer)
                t.column("tier", .text).notNull().defaults(to: "m")
                t.column("authorId", .text).notNull()
                t.column("ownerId", .text)
                t.column("reviewerId", .text)
                t.column("team", .text)
                t.column("parentId", .text).references("workItem", onDelete: .setNull)
                t.column("sprintId", .text)
                t.column("linkedBranch", .text)
                t.column("notes", .text)
                t.column("everStarted", .boolean).notNull().defaults(to: false)
                t.column("firstClaimedAt", .datetime)
                t.column("firstClaimedActive", .double)
                t.column("verifiedRevision", .integer)
                t.column("verifiedCommit", .text)
                t.column("reviewRound", .integer).notNull().defaults(to: 0)
                t.column("reviewedRound", .integer).notNull().defaults(to: 0)
                t.column("submitSummary", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("doneAt", .datetime)
                // Work modes (W3): intensity, the engine-raised floor and boost, and who confirmed the spec.
                t.column("intensity", .text).notNull().defaults(to: "auto")
                t.column("rungFloor", .integer).notNull().defaults(to: 0)
                t.column("budgetBoostLE", .double).notNull().defaults(to: 0)
                t.column("specConfirmedBy", .text)
                t.uniqueKey(["companyId", "key"])
            }
            try db.create(index: "workItem_company_status", on: "workItem", columns: ["companyId", "status"])
            try db.create(table: "workItemDependency") { t in
                t.column("itemId", .text).notNull().references("workItem", onDelete: .cascade)
                t.column("dependsOnId", .text).notNull().references("workItem", onDelete: .cascade)
                t.column("linkedBy", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["itemId", "dependsOnId"])
            }
            try db.create(index: "workItemDependency_on", on: "workItemDependency", columns: ["dependsOnId"])
            try db.create(table: "workItemEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("itemId", .text).notNull().references("workItem", onDelete: .cascade)
                t.column("actorId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("createdActive", .double).notNull()
            }
            try db.create(index: "workItemEvent_item", on: "workItemEvent", columns: ["itemId", "id"])
            try db.create(table: "workNotice") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("eventId", .integer).notNull().references("workItemEvent", onDelete: .cascade)
                t.column("deliveredTurnId", .text)
                t.column("wakes", .boolean).notNull().defaults(to: false)
                t.column("wakeAfterActive", .double)
            }
            try db.create(index: "workNotice_agent_pending", on: "workNotice", columns: ["agentId", "deliveredTurnId"])
            try db.alter(table: "agent") { t in t.add(column: "lastNoticeWakeActive", .double) }
        }
        m.registerMigration("v3-leases") { db in
            try db.create(table: "workLease") { t in
                t.primaryKey("itemId", .text).references("workItem", onDelete: .cascade)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("acquiredAt", .datetime).notNull()
                t.column("expiresActive", .double).notNull()
            }
            try db.create(index: "workLease_agent", on: "workLease", columns: ["agentId"])
            try db.alter(table: "workItem") { t in t.add(column: "touchPaths", .text).notNull().defaults(to: "[]") }
            // Owner-editable hot paths (JSON globs); NULL means `WorkPolicy.defaultHotPaths`.
            try db.alter(table: "ownerSettings") { t in t.add(column: "hotPaths", .text) }
        }
        m.registerMigration("v3-verify") { db in
            try db.create(table: "verificationRun") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("itemId", .text).notNull().references("workItem", onDelete: .cascade)
                t.column("checkRevision", .integer).notNull()
                t.column("scriptHash", .text).notNull().defaults(to: "")
                t.column("commit", .text).notNull()
                t.column("command", .text).notNull()
                t.column("workingDirectory", .text).notNull().defaults(to: "")
                t.column("timeoutSeconds", .integer).notNull()
                t.column("purpose", .text).notNull()
                t.column("attempt", .integer).notNull().defaults(to: 1)
                t.column("status", .text).notNull()
                t.column("flaky", .boolean).notNull().defaults(to: false)
                t.column("exitCode", .integer)
                t.column("outputPath", .text)
                t.column("outputTail", .text)
                t.column("requestedBy", .text)
                t.column("notBeforeActive", .double)
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
            }
            try db.create(index: "verificationRun_item", on: "verificationRun", columns: ["itemId"])
            try db.create(index: "verificationRun_status", on: "verificationRun", columns: ["status"])
            try db.create(table: "checkSnapshot") { t in
                t.column("itemId", .text).notNull().references("workItem", onDelete: .cascade)
                t.column("checkRevision", .integer).notNull()
                t.column("dir", .text).notNull()
                t.column("manifest", .text).notNull()
                t.primaryKey(["itemId", "checkRevision"])
            }
        }
        return m
    }
}
