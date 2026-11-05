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
        m.registerMigration("v3-verify-2") { db in
            // Main's head (the merge base) when the item's branch was first claimed: the engine's own record of where the
            // work started, used to detect weakened tests and as the source of check-script baselines.
            try db.alter(table: "workItem") { t in t.add(column: "baseCommit", .text) }
        }
        m.registerMigration("v3-turn-context") { db in
            try db.alter(table: "turn") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "work")
                t.add(column: "itemId", .text)
            }
            try db.alter(table: "workItem") { t in
                t.add(column: "reviewAttempts", .integer).notNull().defaults(to: 0)
                t.add(column: "mergeState", .text).notNull().defaults(to: "none")
                t.add(column: "mergedCommit", .text)
            }
            try db.alter(table: "company") { t in t.add(column: "mainCommit", .text) }
        }
        m.registerMigration("v3-merge-safety") { db in
            // Merge safety (9b): per in-progress item, the merge base it was last measured at, when `main` first moved past it
            // (company-active seconds) and whether the freshness notice for that base was sent.
            try db.create(table: "branchFreshness") { t in
                t.primaryKey("itemId", .text).references("workItem", onDelete: .cascade)
                t.column("mergeBase", .text).notNull()
                t.column("behindSinceActive", .double).notNull()
                t.column("notified", .boolean).notNull().defaults(to: false)
            }
            // Per approved item: whether its merge is running (its holder is locked out meanwhile) and how many merge
            // attempts in a row failed (after `Store.maxMergeFailures` it goes back to the holder).
            try db.create(table: "itemMerge") { t in
                t.primaryKey("itemId", .text).references("workItem", onDelete: .cascade)
                t.column("running", .boolean).notNull().defaults(to: false)
                t.column("failures", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
            }
            // The head the engine is about to move main to (crash recovery of the exact main guard).
            try db.alter(table: "company") { t in t.add(column: "pendingMainCommit", .text) }
        }
        m.registerMigration("v3-review-audit") { db in
            // Risk-tiered review (9c): auto-approved items, the company's count of auto-merges (every 4th is sampled), when the
            // last batched audit went out (company-active seconds), and the authors whose changes always get a full review.
            try db.alter(table: "workItem") { t in t.add(column: "autoApproved", .boolean).notNull().defaults(to: false) }
            try db.alter(table: "company") { t in
                t.add(column: "autoMergeCount", .integer).notNull().defaults(to: 0)
                t.add(column: "lastAuditActive", .double).notNull().defaults(to: 0)
            }
            try db.alter(table: "agent") { t in t.add(column: "fullReview", .boolean).notNull().defaults(to: false) }
            // One sampled auto-merge: what landed (base → merged commit, both engine-recorded), who wrote it, and the audit.
            // `auditorId`/`auditTurnId`: the batch it is in and the audit turn that may record its verdict.
            try db.create(table: "reviewAudit") { t in
                t.primaryKey("itemId", .text).references("workItem", onDelete: .cascade)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("sampledActive", .double).notNull()
                t.column("auditedAt", .datetime)
                t.column("verdict", .text)
                t.column("notes", .text)
                t.column("authorId", .text)
                t.column("baseCommit", .text)
                t.column("mergedCommit", .text)
                t.column("auditorId", .text)
                t.column("auditTurnId", .text)
                t.column("batchedActive", .double)
            }
            try db.create(index: "reviewAudit_company", on: "reviewAudit", columns: ["companyId", "auditedAt"], ifNotExists: true)
        }
        m.registerMigration("v3-review-audit-2") { db in
            // Who set an item's tier and its check ("<id>:<role kind>", like specConfirmedBy): auto-merge trusts only the
            // engine, the owner or a lead who is not the item's implementer. NULL (older items) never qualifies.
            try db.alter(table: "workItem") { t in
                t.add(column: "tierSetBy", .text)
                t.add(column: "checkSpecSetBy", .text)
            }
            // The owner's switch and allowed directories for auto-merge (NULL paths: the pack's, else the default list).
            try db.alter(table: "ownerSettings") { t in
                t.add(column: "autoMerge", .boolean).notNull().defaults(to: true)
                t.add(column: "autoMergePaths", .text)
            }
            // Every auto-merge is audited, routed as soon as it lands (company.lastAuditActive from "v3-review-audit" is no
            // longer read): who may not audit it (assignee, submitter, besides the author), retries of an
            // audit that ended without a verdict, a deferral when its diff could not be produced, the owner escalation, and
            // the follow-up item a failed audit opened.
            try db.alter(table: "reviewAudit") { t in
                t.add(column: "assigneeId", .text)
                t.add(column: "submitterId", .text)
                t.add(column: "attempts", .integer).notNull().defaults(to: 0)
                t.add(column: "deferredUntilActive", .double)
                t.add(column: "escalated", .boolean).notNull().defaults(to: false)
                t.add(column: "followUpId", .text)
            }
        }
        m.registerMigration("v3-review-audit-3") { db in
            // The company's own auto-merge switch: off for every company until the owner switches it on.
            try db.alter(table: "company") { t in t.add(column: "autoMergeSmall", .boolean).notNull().defaults(to: false) }
        }
        m.registerMigration("v3-sessions") { db in
            // One session per (agent, item); a turn in another working directory starts a fresh one. `lastTurnId` points at the
            // session's newest turn: its end time is the warm rule, its token columns (Task 14) the size rule.
            try db.create(table: "agentSession") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("itemId", .text).notNull().references("workItem", onDelete: .cascade)
                t.column("sessionId", .text).notNull()
                t.column("started", .boolean).notNull().defaults(to: false)
                t.column("cwd", .text)
                t.column("sessionModel", .text)
                t.column("sessionTools", .text)
                t.column("lastEndedAt", .datetime)
                t.column("lastTurnId", .text)
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["agentId", "itemId"])
            }
            try db.create(table: "handoff") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("itemId", .text).notNull().references("workItem", onDelete: .cascade)
                t.column("authorId", .text).notNull()
                t.column("toAgentId", .text)
                t.column("path", .text).notNull()
                t.column("auto", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "handoff_item", on: "handoff", columns: ["itemId", "createdAt"])
            // The base session's cwd, model, tool set and last turn (JSON; the session id and started flag stay on the agent).
            try db.alter(table: "agent") { t in t.add(column: "sessionMeta", .text) }
            // `sessionResetReason` may already exist when the budgets migration ran first on a merged database.
            let existing = Set(try db.columns(in: "turn").map(\.name))
            try db.alter(table: "turn") { t in
                if !existing.contains("sessionResetReason") { t.add(column: "sessionResetReason", .text) }
                t.add(column: "reportedStatus", .text)
                t.add(column: "cacheBreak", .text)
            }
        }
        m.registerMigration("v3-asks") { db in
            try db.alter(table: "company") { t in t.add(column: "autonomy", .text).notNull().defaults(to: "important") }
            try db.alter(table: "agent") { t in t.add(column: "pausedActive", .double) }
            try db.create(table: "ask") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("category", .text)
                t.column("risk", .text).notNull()
                t.column("requesterId", .text).notNull()
                t.column("itemId", .text)
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("payload", .text)
                t.column("detailsHash", .text)
                t.column("proposedGrant", .text)
                t.column("status", .text).notNull()
                t.column("internalApproverId", .text)
                t.column("internalNote", .text)
                t.column("internalDecidedAt", .datetime)
                t.column("ownerNote", .text)
                t.column("ownerAnswer", .text)
                t.column("ownerDecidedAt", .datetime)
                t.column("decidedBy", .text)
                t.column("fyi", .boolean).notNull().defaults(to: false)
                t.column("acknowledgedAt", .datetime)
                t.column("subjectId", .text)
                t.column("supersedesId", .text)
                t.column("escalatedAt", .datetime)
                t.column("rescindedAt", .datetime)
                t.column("createdActive", .double).notNull().defaults(to: 0)
                t.column("statusSinceActive", .double).notNull().defaults(to: 0)
                t.column("expiresActive", .double)
                t.column("remindCount", .integer).notNull().defaults(to: 0)
                t.column("notifiedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // Decision brief: a repeat proposal with the same requestId returns the existing ask.
                t.column("requestId", .text)
                t.column("decisionClass", .text).notNull().defaults(to: "taste")
                t.uniqueKey(["companyId", "number"])
            }
            try db.create(index: "ask_company_status", on: "ask", columns: ["companyId", "status"])
            // Assignee requests for a stronger work mode (W6): dedupe by requestId and rate limiting.
            try db.create(table: "modeRequest") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("itemId", .text).notNull()
                t.column("agentId", .text).notNull()
                t.column("requestId", .text)
                t.column("mode", .text).notNull()
                t.column("turnId", .text)
                t.column("createdActive", .double).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "modeRequest_item", on: "modeRequest", columns: ["itemId", "id"])
        }
        m.registerMigration("v3-liveness") { db in
            // The acting CEO: set when the CEO (or the root executive) leaves, pending the owner's confirmation.
            try db.alter(table: "agent") { t in t.add(column: "actingRole", .text) }
            try db.create(table: "orgIssue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("kind", .text).notNull()   // overSpan | noRoot
                t.column("agentId", .text)
                t.column("detail", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("resolvedAt", .datetime)
            }
            try db.create(table: "deadlock") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("signature", .text).notNull()
                t.column("members", .text).notNull()
                t.column("detectedActive", .double).notNull()
                t.column("escalatedTo", .text)
                t.column("ownerEscalated", .boolean).notNull().defaults(to: false)
                t.column("resolvedAt", .datetime)
            }
            try db.create(table: "agingNotice") { t in
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("subject", .text).notNull()
                t.column("level", .integer).notNull()
                t.primaryKey(["companyId", "subject"])
            }
        }
        m.registerMigration("v3-sprints") { db in
            try db.alter(table: "company") { t in t.add(column: "cadence", .text).notNull().defaults(to: "sprint") }
            try db.create(table: "sprint") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("team", .text)
                t.column("goal", .text).notNull().defaults(to: "")
                t.column("cadence", .text).notNull().defaults(to: "sprint")
                t.column("status", .text).notNull()
                t.column("milestoneItemId", .text)
                t.column("askId", .text)
                t.column("timeboxDays", .integer).notNull().defaults(to: 5)
                t.column("timeboxTurns", .integer).notNull().defaults(to: 200)
                t.column("startedActive", .double)
                t.column("lastStandupActive", .double)
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("closedAt", .datetime)
                t.column("summary", .text)
                t.column("leadId", .text)
                t.uniqueKey(["companyId", "number"])
            }
            try db.create(index: "sprint_company_status", on: "sprint", columns: ["companyId", "status"])
            try db.create(index: "sprint_ask", on: "sprint", columns: ["askId"])
            try db.create(index: "workItem_sprint", on: "workItem", columns: ["sprintId"], ifNotExists: true)
        }
        m.registerMigration("v3-budgets") { db in
            // Registered after "v3-sprints". "v3-turn-context" (Task 9) and
            // "v3-sessions" (Task 10) add `kind`, `itemId` and `sessionResetReason` first, so each add is conditional.
            let existing = Set(try db.columns(in: "turn").map(\.name))
            func add(_ name: String, _ type: Database.ColumnType, notNull fallback: DatabaseValueConvertible? = nil) throws {
                guard !existing.contains(name) else { return }
                try db.alter(table: "turn") { t in
                    if let d = fallback { t.add(column: name, type).notNull().defaults(to: d) } else { t.add(column: name, type) }
                }
            }
            try add("kind", .text, notNull: "work")
            try add("itemId", .text)
            try add("sessionResetReason", .text)
            try add("sessionId", .text)
            try add("sessionTotalUSD", .double)
            for column in ["inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens"] { try add(column, .integer, notNull: 0) }
            try add("toolSignature", .text)
            try add("mode", .text)
            try add("rung", .integer)
            try add("effort", .text)
            try add("modeReason", .text)
            try add("stopReason", .text)
            try add("subagentsSpawned", .integer, notNull: 0)
            try add("workflowAgents", .integer, notNull: 0)
            try add("costLE", .double)
            try db.create(index: "turn_item", on: "turn", columns: ["itemId"], ifNotExists: true)
            try db.create(index: "turn_session", on: "turn", columns: ["sessionId"], ifNotExists: true)
            // Why the engine stopped work on an item: budget, no-progress, loop, failed-checks or timebox. Cleared at the next claim.
            try db.alter(table: "workItem") { t in t.add(column: "stopReason", .text) }
        }
        m.registerMigration("v3-budgets-models") { db in
            // Task 14a fix round 1: the models a turn's result billed, for the per-session model audit.
            try db.alter(table: "turn") { t in t.add(column: "modelsUsed", .text) }
        }
        m.registerMigration("v3-facts") { db in
            // Task 14b: the watchdog's counter, the failed-check loop guard and the per-item outcome facts.
            try db.alter(table: "agent") { t in t.add(column: "turnsWithoutProgress", .integer).notNull().defaults(to: 0) }
            try db.alter(table: "workItem") { t in t.add(column: "failedChecksSinceClaim", .integer).notNull().defaults(to: 0) }
            try db.create(table: "itemFact") { t in
                t.column("itemId", .text).primaryKey().references("workItem", onDelete: .cascade)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("tier", .text).notNull()
                t.column("ownerId", .text)
                t.column("reviewerId", .text)
                t.column("firstPass", .boolean).notNull()
                for c in ["verificationRuns", "failedRuns", "flakyRuns", "inconclusiveRuns", "reworkRounds", "reviewRejections",
                          "turnsUsed", "tokensUsed", "tierMaxTurns", "tierMaxTokens", "blockedActiveSeconds", "mergeConflicts"] {
                    t.column(c, .integer).notNull().defaults(to: 0)
                }
                t.column("cycleActiveSeconds", .integer)
                t.column("checkAuthorId", .text)
                t.column("checkAuthorRole", .text)
                t.column("costLE", .double).notNull().defaults(to: 0)
                t.column("tierMaxCostLE", .double).notNull().defaults(to: 0)
                t.column("reviewCostLE", .double).notNull().defaults(to: 0)
                t.column("autoMerged", .boolean).notNull().defaults(to: false)
                t.column("audited", .boolean).notNull().defaults(to: false)
                t.column("auditVerdict", .text)
                t.column("rungAtPass", .integer)
                t.column("modesUsed", .text)
                t.column("completedAt", .datetime).notNull()
            }
            try db.create(index: "itemFact_company", on: "itemFact", columns: ["companyId", "completedAt"])
        }
        m.registerMigration("v3-mode-quotas") { db in
            // Task 14c fix round 1: a work or plan turn's MCP quotas are recorded on its credential when it is issued, and the
            // counts live here per turn, shared by every `brahma mcp` process of the turn.
            try db.alter(table: "turnCredential") { t in t.add(column: "quotas", .text) }
            try db.create(table: "turnQuotaUsage") { t in
                t.column("turnId", .text).notNull().references("turn", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("used", .integer).notNull().defaults(to: 0)
                t.primaryKey(["turnId", "kind"])
            }
        }
        registerPlan5(&m)
        return m
    }

    /// Task 12 fix 1 (`v5-restore`): one row per restore (`nonce`, also in the restore marker; `consumedAt` once the engine has
    /// taken it up) and, per company, the `mainCommit` the restored database recorded: the only head a restore may re-adopt.
    /// `IF NOT EXISTS`: a restore writes these into a snapshot of any older schema before the migrator next runs on it.
    static func createRestoreTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS restoreEvent (
                nonce TEXT PRIMARY KEY NOT NULL,
                snapshot TEXT NOT NULL,
                restoredAt DATETIME NOT NULL,
                notes TEXT NOT NULL DEFAULT '',
                consumedAt DATETIME
            );
            CREATE TABLE IF NOT EXISTS restoreMain (
                nonce TEXT NOT NULL REFERENCES restoreEvent(nonce) ON DELETE CASCADE,
                companyId TEXT NOT NULL REFERENCES company(id) ON DELETE CASCADE,
                mainCommit TEXT,
                PRIMARY KEY (nonce, companyId)
            );
            """)
    }

    /// Plan 5-lite migrations, in the plan's order (v5-sandbox, v5-owner-guard, v5-secrets, v5-extensions, v5-timers,
    /// v5-notices, v5-notices-2, v5-push, ...). Called once at the end of `migrator()`, after every 3a migration.
    static func registerPlan5(_ m: inout DatabaseMigrator) {
        m.registerMigration("v5-sandbox") { db in
            try db.alter(table: "company") { t in
                t.add(column: "permissionProfile", .text).notNull().defaults(to: "sandboxed")
                // JSON: role id → profile.
                t.add(column: "roleProfiles", .text).notNull().defaults(to: "{}")
                // JSON arrays of domain patterns / paths.
                t.add(column: "allowedDomains", .text).notNull().defaults(to: "[]")
                t.add(column: "webDomains", .text).notNull().defaults(to: "[]")
                t.add(column: "allowLocalBinding", .boolean).notNull().defaults(to: true)
                t.add(column: "toolchainReadPaths", .text).notNull().defaults(to: "[]")
            }
        }
        m.registerMigration("v5-owner-guard") { db in
            // Task 3: the process of each turn (an owner command whose ancestor is a running turn is refused), and the sandbox
            // canary's passes, keyed by the CLI build, the settings shape and the macOS version.
            try db.alter(table: "turn") { t in t.add(column: "pid", .integer) }
            try db.create(table: "sandboxCanary") { t in
                t.column("cliFingerprint", .text).notNull()
                t.column("settingsShape", .text).notNull()
                t.column("osVersion", .text).notNull()
                t.column("cliVersion", .text)
                t.column("passedAt", .datetime).notNull()
                t.column("detail", .text)
                t.primaryKey(["cliFingerprint", "settingsShape", "osVersion"])
            }
        }
        m.registerMigration("v5-secrets") { db in
            // Names and flags only; values live in the Keychain (or another SecretVault), never here.
            try db.create(table: "secret") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("isTest", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime)
                t.uniqueKey(["companyId", "name"])
            }
            try db.create(table: "secretUse") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("secretName", .text).notNull()
                t.column("itemId", .text)
                t.column("grantedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
        }
        m.registerMigration("v5-secrets-2") { db in
            // The item branch's head as the engine last recorded it (at claim, after each of the holder's turns, after an
            // engine rebase): `submit_for_review` refuses a branch that is not a fast-forward of it (Task 4-wire, scan (a)).
            try db.alter(table: "workItem") { t in
                t.add(column: "leaseHeadCommit", .text)
                // Set when the branch head at the start of a holder turn was not the recorded head (a move outside the holder's
                // turns): `submit_for_review` is refused until a manager or the owner re-adopts the branch (`readopt_branch`).
                t.add(column: "branchMoved", .boolean).notNull().defaults(to: false)
                // Who held the lease when the branch was flagged (nil: nobody did): `readopt_branch` is refused to that agent
                // and needs its direct manager (or an executive, or the owner), whoever holds the item later.
                t.add(column: "branchMovedHolderId", .text)
            }
        }
        m.registerMigration("v5-restore") { db in
            try createRestoreTables(db)
        }
        m.registerMigration("v5-extensions") { db in
            // Verified packages by tree hash. publisher/source/treeSha256 come from the installer's fetch path, never the package.
            try db.create(table: "extensionPackage") { t in
                t.primaryKey("hash", .text)
                t.column("id", .text).notNull()
                t.column("version", .text).notNull()
                t.column("publisher", .text).notNull()
                t.column("sourceType", .text).notNull()
                t.column("sourceUrl", .text)
                t.column("sourceSha", .text)
                t.column("treeSha256", .text).notNull()
                // The plugin parts alone (what the workspace mounts and the compiler rehashes).
                t.column("pluginTreeSha256", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
                t.column("lintFacts", .text)   // JSON
                t.column("notices", .text)     // JSON
            }
            try db.create(table: "companyExtension") { t in
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("hash", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("installedAskId", .text)
                t.column("installedAt", .datetime).notNull()
                t.primaryKey(["companyId", "id"])
            }
            try db.create(table: "extensionBinding") { t in
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("scope", .text).notNull()   // role|agent
                t.column("target", .text).notNull()
                t.column("op", .text).notNull()      // add|remove
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "extensionEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("extId", .text).notNull()
                t.column("kind", .text).notNull()    // staged|installed|declined|mountBlocked|tamper|try|removed
                t.column("detail", .text)
                t.column("createdAt", .datetime).notNull()
            }
            // The frozen mount set of a session; a different set on the next turn forces a fresh session.
            try db.alter(table: "agentSession") { t in t.add(column: "mountSetHash", .text) }
            // A reason waiting for the agent's next turn (`Store.forceFreshSession`).
            try db.alter(table: "agent") { t in t.add(column: "pendingSessionReset", .text) }
        }
        m.registerMigration("v5-extensions-2") { db in
            // Task 5a fix round 1. B-I1: publisher and source per company (copied at approve from the approved payload). M3: the
            // sidecar as parsed at propose. B-I3: a fresh-session reason that keeps the turn counted (unlike `sessionResetReason`).
            try db.alter(table: "companyExtension") { t in
                t.add(column: "publisher", .text).notNull().defaults(to: "")
                t.add(column: "sourceType", .text).notNull().defaults(to: "")
                t.add(column: "sourceUrl", .text)
                t.add(column: "sourceSha", .text)
            }
            // Rows installed before this migration take the facts their package row held when they were approved (the shared row
            // was only relabeled by a later proposal, which this round stops); otherwise they would never mount again.
            try db.execute(sql: """
                UPDATE companyExtension SET
                  publisher = COALESCE((SELECT publisher FROM extensionPackage p WHERE p.hash = companyExtension.hash), ''),
                  sourceType = COALESCE((SELECT sourceType FROM extensionPackage p WHERE p.hash = companyExtension.hash), ''),
                  sourceUrl = (SELECT sourceUrl FROM extensionPackage p WHERE p.hash = companyExtension.hash),
                  sourceSha = (SELECT sourceSha FROM extensionPackage p WHERE p.hash = companyExtension.hash)
                """)
            try db.alter(table: "extensionPackage") { t in t.add(column: "sidecar", .text) }
            try db.alter(table: "turn") { t in t.add(column: "freshSessionReason", .text) }
            // m-4: turns recorded before this migration with the old marker are counted work turns.
            try db.execute(sql: "UPDATE turn SET freshSessionReason = sessionResetReason, sessionResetReason = NULL WHERE sessionResetReason = 'mounts changed'")
        }
        m.registerMigration("v5-timers") { db in
            try db.create(table: "timer") { t in
                t.primaryKey("id", .text)
                // Nil for engine-wide timers (backups).
                t.column("companyId", .text).references("company", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("action", .text).notNull()
                t.column("schedule", .text).notNull()
                t.column("nextFireAt", .datetime).notNull()
                t.column("lastFiredAt", .datetime)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["companyId", "name"])
            }
            // UNIQUE(companyId, name) does not constrain engine-wide rows (NULLs are distinct).
            try db.execute(sql: "CREATE UNIQUE INDEX timer_scope_name ON timer(IFNULL(companyId, ''), name)")
            try db.create(index: "timer_due", on: "timer", columns: ["enabled", "nextFireAt"])
        }
        m.registerMigration("v5-notices") { db in
            try db.create(table: "ownerNotice") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).references("company", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("urgency", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("deliveredAt", .datetime)
            }
            try db.create(index: "ownerNotice_undelivered", on: "ownerNotice", columns: ["deliveredAt", "id"])
            try db.execute(sql: """
                CREATE TABLE ownerPrefs(
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    notificationsEnabled BOOLEAN NOT NULL DEFAULT 1,
                    quietEnabled BOOLEAN NOT NULL DEFAULT 1,
                    quietStart TEXT NOT NULL DEFAULT '22:00',
                    quietEnd TEXT NOT NULL DEFAULT '08:00',
                    digestTime TEXT NOT NULL DEFAULT '08:00',
                    preventSleep BOOLEAN NOT NULL DEFAULT 1)
                """)
            try db.execute(sql: "INSERT INTO ownerPrefs(id) VALUES (1)")
        }
        m.registerMigration("v5-notices-2") { db in
            // The engine-set link from a blocked item to the ask it waits for (and who linked it), so notice urgency never
            // comes from reason text. Agents carry theirs on `Blocker.owner(askId:)` inside the JSON blocker column.
            try db.alter(table: "workItem") { t in
                t.add(column: "blockedAskId", .text)
                t.add(column: "blockedAskBy", .text)
            }
        }
        m.registerMigration("v5-push") { db in
            // Phone alerts (Task 7b). The provider's credentials are NOT here: they live in the SecretVault under owner-level
            // accounts ("owner:NTFY_TOKEN", "owner:PUSHOVER_APP_TOKEN", "owner:PUSHOVER_USER_KEY").
            try db.alter(table: "ownerPrefs") { t in
                t.add(column: "pushProvider", .text)
                t.add(column: "pushServer", .text).notNull().defaults(to: "https://ntfy.sh")
                t.add(column: "pushTopic", .text)
                t.add(column: "pushDetail", .text).notNull().defaults(to: "counts")
            }
            try db.alter(table: "ask") { t in t.add(column: "pushedAt", .datetime) }
            try db.alter(table: "ownerNotice") { t in t.add(column: "pushedAt", .datetime) }
            try db.create(table: "pushLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sentAt", .datetime).notNull()
                t.column("ok", .boolean).notNull()
                t.column("status", .integer)
                // Engine text only (urgent, normal, cap, test, or an error class), never a payload.
                t.column("detail", .text)
            }
            try db.create(index: "pushLog_sentAt", on: "pushLog", columns: ["sentAt"])
        }
        m.registerMigration("v5-push-2") { db in
            // Bumped when a push credential changes, so the engine's cached channel (and its one vault read) is redone then.
            try db.alter(table: "ownerPrefs") { t in t.add(column: "pushCredentialsVersion", .integer).notNull().defaults(to: 0) }
        }
        m.registerMigration("v5-stop") { db in
            // The owner's emergency stop (Task 7c): at most one row; while it exists nothing runs, in any company.
            try db.execute(sql: """
                CREATE TABLE engineStop (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    since DATETIME NOT NULL,
                    "by" TEXT NOT NULL,
                    note TEXT
                )
                """)
        }
        m.registerMigration("v5-digests") { db in
            try db.create(table: "ownerDigest") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("periodStart", .datetime).notNull()
                t.column("periodEnd", .datetime).notNull()
                t.column("markdown", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "ownerDigest_company", on: "ownerDigest", columns: ["companyId", "periodEnd"])
        }
        m.registerMigration("v5-grants") { db in
            // The grant ledger (Task 9). `grant` is an SQL keyword: raw SQL quotes it.
            try db.create(table: "grant") { t in
                t.primaryKey("id", .text)
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("number", .integer).notNull()
                t.column("askId", .text)
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("scopeRef", .text)
                t.column("requesterId", .text)
                t.column("duration", .text).notNull()
                t.column("sprintId", .text)
                t.column("expiresActive", .double)
                t.column("usesLeft", .integer)
                t.column("approvedBy", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("revokedAt", .datetime)
                t.column("revokedBy", .text)
                t.column("lastUsedAt", .datetime)
                t.column("useCount", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["companyId", "number"])
            }
            try db.create(table: "accessPreset") { t in
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("presetId", .text).notNull()
                t.column("enabled", .boolean).notNull()
                t.primaryKey(["companyId", "presetId"])
            }
            // Refused `request_access` calls: the owner's view of why, and the agent's refusal budget.
            try db.create(table: "accessRefusal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("companyId", .text).notNull().references("company", onDelete: .cascade)
                t.column("agentId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("createdActive", .double).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "accessRefusal_agent", on: "accessRefusal", columns: ["agentId", "createdActive"])
        }
        m.registerMigration("v5-taint") { db in
            // Task 10: a turn that read outside content (when, and from what); the agent's session-wide taint and the fresh
            // session a refused high-risk call asked for; the router's flag on a message (`impersonation`).
            try db.alter(table: "turn") { t in
                t.add(column: "taintedAt", .datetime)
                t.add(column: "taintSource", .text)
            }
            try db.alter(table: "agent") { t in
                t.add(column: "sessionTainted", .boolean).notNull().defaults(to: false)
                t.add(column: "freshSessionRequested", .boolean).notNull().defaults(to: false)
                // B-M12 (5a): the session scope a pending fresh-session reason belongs to ('' = the base session, else the item
                // id); only a turn in that scope takes the reason. NULL: recorded before this migration (any scope).
                t.add(column: "pendingSessionResetScope", .text)
            }
            try db.alter(table: "message") { t in t.add(column: "flag", .text) }
            // Lab provenance (for Task 10b): every commit of an agent's lab, with the taint state of the turn that first saw it.
            try db.create(table: "labCommit") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("sha", .text).notNull()
                t.column("turnId", .text)
                t.column("tainted", .boolean).notNull()
                t.column("recordedAt", .datetime).notNull()
                t.primaryKey(["agentId", "sha"])
            }
            // Hook gates passed per CLI build (`V-1`: PostToolUse fires for sub-agent and workflow-agent calls). Until V-1 is
            // recorded for the running CLI, a turn that can fan out is tainted at launch.
            try db.create(table: "hookGate") { t in
                t.column("gate", .text).notNull()
                t.column("cliFingerprint", .text).notNull()
                t.column("passedAt", .datetime).notNull()
                t.primaryKey(["gate", "cliFingerprint"])
            }
        }
        m.registerMigration("v5-taint-2") { db in
            // Task 10 fix round 1 (I2): what a tainted session wrote for others carries its origin; a turn that reads it is tainted.
            try db.alter(table: "message") { t in t.add(column: "taintedOrigin", .boolean).notNull().defaults(to: false) }
            try db.alter(table: "workItemEvent") { t in t.add(column: "taintedOrigin", .boolean).notNull().defaults(to: false) }
            try db.alter(table: "handoff") { t in t.add(column: "taintedOrigin", .boolean).notNull().defaults(to: false) }
        }
        m.registerMigration("v5-taint-3") { db in
            // Task 10 fix round 2 (S18, worktree files): a work item a tainted session created, edited or worked on. Sticky until
            // the item is done: no later clean edit clears it.
            try db.alter(table: "workItem") { t in t.add(column: "taintedOrigin", .boolean).notNull().defaults(to: false) }
        }
        m.registerMigration("v5-taint-4") { db in
            // S21: the item mark is sticky until done, whatever stale item value a later full-row update writes back.
            try db.execute(sql: """
                CREATE TRIGGER workItem_taint_sticky AFTER UPDATE OF taintedOrigin ON workItem
                WHEN OLD.taintedOrigin = 1 AND NEW.taintedOrigin = 0 AND NEW.status <> 'done'
                BEGIN UPDATE workItem SET taintedOrigin = 1 WHERE id = NEW.id; END
                """)
        }
        m.registerMigration("v5-transcripts") { db in
            // One row per captured turn: where its redacted, compressed slice of the Claude session transcript is, and which
            // bytes of the source file it covers (the next turn of that session continues from `byteEnd`).
            try db.create(table: "turnTranscript") { t in
                t.primaryKey("turnId", .text).references("turn", onDelete: .cascade)
                t.column("companyId", .text).notNull()
                t.column("agentId", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("path", .text).notNull()
                t.column("byteStart", .integer).notNull()
                t.column("byteEnd", .integer).notNull()
                t.column("codec", .text).notNull()
                t.column("sha", .text).notNull()
                t.column("capturedAt", .datetime).notNull()
            }
            try db.create(index: "turnTranscript_session", on: "turnTranscript", columns: ["sessionId", "capturedAt"])
            try db.create(index: "turnTranscript_agent", on: "turnTranscript", columns: ["companyId", "agentId", "capturedAt"])
        }
        m.registerMigration("v5-targets") { db in
            // Off-machine backup targets (a JSON array of `BackupTarget`) and the optional Litestream replica (a JSON
            // `WALShippingConfig`, NULL = off). Kept on the owner's one preferences row.
            try db.execute(sql: "ALTER TABLE ownerPrefs ADD COLUMN backupTargets TEXT NOT NULL DEFAULT '[]'")
            try db.execute(sql: "ALTER TABLE ownerPrefs ADD COLUMN walShipping TEXT")
        }
    }
}
