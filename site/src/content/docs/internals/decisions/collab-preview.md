---
title: Universal preview and granular communication
description: "One typed reference for all work, a preview that can show anything, a Show bar that costs nothing until the owner asks, and sharing that never widens access."
sidebar:
  order: 7
---

## Context

The owner wanted the preview pane to show any work, a search box above it to ask an agent to show something, and granular communication: agents sharing files with each other, the owner sending files to and requesting files from individual agents. The design had to do this without letting a share become a way around access rules, without an LLM turn on every keystroke, and inside the five-noun budget. It was finalised after a security review and a UX/cost review.

## Decision

- **One typed reference for all work, `WorkRef`.** Messages, previews, Inbox cards and Show answers carry references, never copies. When a reference is stored the engine resolves it, checks the reader's access and pins it to an immutable revision.
- **One preview, any work.** The preview pane keeps its fixed product tabs and adds one OPENED slot that can show any reference, with history: a file, a diff, an item's uncommitted worktree, an agent's live view.
- **The Show bar runs without an LLM** unless the owner presses Enter on an explicit Ask row. Plain code strips filler words and resolves direct references, a phrase table and fuzzy search over files, items, the handbook, artifacts, people and previews. An Ask goes to a cheap concierge turn by default: no session, no role card, read-only tools, its own lane. A real agent is asked only for explain-why-how questions or when the owner names a handle.
- **Three new tools**, `share`, `open_ref` and `show`; messaging tools gain attachments, replies and threads. File requests are DM cards answered with a share; agent-to-owner file requests are Inbox asks with a drop zone.
- **Private bytes live outside every agent mount**, in an engine vault in the data home that no agent can read. They are reachable only through `open_ref`, which checks access, taints when needed and logs. Sandboxed agents can read their own home, lab and notes but not another agent's.
- **Taint is data and travels with content.** Snapshots, replies, files and commits produced by a tainted session resolve as tainted and taint their readers, until a review merges the commit or the owner vouches.
- **Sharing never widens access.** A share to a reader who cannot read the reference is refused back to the sender, and no access ask is filed on anyone's behalf. Each channel member sees either the card or an opaque locked chip with no title.
- **The engine is never a confused deputy.** Agent-named paths are opened from engine-held root descriptors with `openat`/`O_NOFOLLOW`; every git call goes through a hardened wrapper with no filters, no external diff, literal pathspecs and hex-only revisions.

## Consequences

- The MVP is cut roughly in half: a first set of tasks before dogfood, the rest (reactions, pins, owner notes, multi-tab, a ledger view) after it, by evidence.
- Access is enforced in the store and the tools, never by hiding things in the UI; every lookup is scoped to the company.
- Attachments carry no authority: only the owner's own decisions change asks, and quoted or forwarded owner text is context, not an instruction.
- Nothing new for the owner to learn: the preview and Show bar sit under Work, attachments and threads under People, file and access asks in the Inbox, one cost line under Budget.

## Source

`2026-10-21-collab-preview-design.md`
