# Plan 1 follow-ups (deferred minor findings)

Recorded during Plan 1's per-task and final reviews. The final reviewer triaged
all of these as fine to defer; items fixed in the final wave are omitted. Pick
them up when a later plan touches the area.

## Store / schema
- Empty or relative `BRAHMA_HOME` / `BRAHMA_WORKSPACES` aren't normalized.
- Orphan workspace dir possible if the insert commits fail after `mkdir`; a pre-existing dir is reused silently (warn later).
- `messageFts` joins on the implicit rowid of a TEXT-PK table — a `VACUUM` could renumber rowids (consider an INTEGER PK or rebuild-on-vacuum).
- Crash recovery resets `readySince` (only affects tie-breaks); `Turn` has no public init (add when the app needs it).
- Pragma test helper lives on the production `Store` (internal; plan-mandated).

## Messaging / prompts
- Router uses `.now` rather than `Store.now()` (ms rounding only).
- Killed channel members accumulate pending inbox items (bounded).
- Mention regex rebuilt per call.
- MCP config is chmod'ed to 0600 after writing (brief 0644 window; no secrets in it).
- Empty roster renders an empty "Team:" block; "1 items" grammar.
- `TerminalText.sanitize` doesn't neutralize bidi overrides (U+202E) or U+2028/2029 (display spoofing only).

## Parser / MCP
- NSNumber bools accepted as numbers; a malformed result line defaults to success with empty session id (real `claude` always sends `is_error`).
- JSON-RPC: batch → -32700 instead of -32600; non-object params → `{}`; numeric ids go through Double; no read-buffer cap; empty encoder fallback.

## Scheduler / orchestrator / runner
- Company tie-break uses dictionary order on duplicate names (add an id tie-break).
- A DB error in a stream side-write (session flag, rate-limit save, tool event) aborts a live turn — wrap in `attempt`.
- Cancel gap after stdout EOF before `exit.wait()`; `.interrupted` overrides an already-arrived success result on Ctrl-C; stderr tail can miss its final chunk.
- Store lifecycle extension lives in `Orchestrator.swift` (belongs in `Lifecycle/`); `waitUntilIdle` polls every 5 ms.
- `isSessionNotFound` heuristic could match unrelated "session … not found" text (consequence: a fresh session).

## CLI
- `LiveCount` is process-global; `Kill` maps every `LifecycleError` to "already killed"; no "stopping…" message on Ctrl-C; `cannotOpen` lock error not mapped to a friendly message.
- Orchestrator lock fd lacks `O_CLOEXEC` (Darwin `Process` doesn't leak it — verified); lock taken after the store opens (migrations are transactional).

## Tests
- Gaps: recovery leaves non-running agents/finished turns untouched; hire lowercasing; scheduler mixed open/closed, weight ≤ 0, nil `readySince`; paused / requested-blocker + usage-hold combos; runner cancel/SIGKILL/large-prompt/grandchild paths; CLI pure helpers; paused waiter released on kill.
- `clock()`-based CPU assertion in TurnRunnerTests is process-wide — could flake under heavy parallel load (switch to per-thread `getrusage` if it ever fails).
- Live-test timeout path doesn't cancel in-flight turns.

## Linux (Plan 8)
- Default data home should follow `$XDG_DATA_HOME` / `~/.local/share/brahma` on Linux.
- Verify `NSLock.withLock` and `Date.ISO8601Format()` on the Linux Foundation build.
