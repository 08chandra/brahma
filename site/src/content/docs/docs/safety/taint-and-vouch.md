---
title: Taint and vouch
description: "The taint rule: what a session may still do after it has read outside content, and what is refused. Lab marks, agent-built extensions, grants and presets, and how you, the owner, vouch."
sidebar:
  order: 5
---

## What it is

Outside content is anything an agent did not get from you or from the company's own records: a web page, another MCP server's output, fetched code, a document you dropped that Brahma could not trust. Once a session has read outside content, it is **tainted** until the agent's next fresh session. A tainted session keeps working, but it may no longer decide anything, and what it writes is marked so readers know where it came from.

Only you clear taint. That act is called **vouching**.

## How it works

**What taints a session.** A WebFetch or WebSearch result, another MCP server's output, a Bash command that reaches the network or runs fetched code (`curl`, `ssh`, `npm`, `pip`, `git fetch`, `/dev/tcp`, ...), a third-party or not-installed skill or sub-agent, an `EXTERNAL` resource, or a tainted handbook page or fact.

**What a tainted session can still do.** Talk, read, and ordinary item work: messages, channels, items, leases, `submit_for_review` and hand-offs.

**What it is refused.** Every other company tool: proposing or deciding asks, reviews and audits, sprint planning, asking for access or secrets, `use_secret`, mode requests, re-adopting branches and proposing extensions. It cannot start sub-agents or workflows.

**What its writing carries.** Everything it writes reaches readers marked as coming from a session that read outside content: facts, handbook edits, messages and hand-offs. Its items lose auto-approval. Tainted memory hits show without a snippet. Inheriting a fact keeps its taint, and a tainted contradiction never demotes a trusted fact. Text that claims to come from the owner is flagged and never changes an ask; only you approve anything.

**Fan-out turns** count as tainted from launch until the installed `claude` CLI passes the V-1 hook gate.

**The classifier is advisory.** Deciding which shell commands reach the network is done by a command classifier. It errs towards tainting: ordinary local commands such as `git stash`, `cd x && git status`, or variables in commands taint a session. It is not the wall. On the Sandboxed profile the network allowlist is the wall.

**Lab marks.** Each agent has a lab, a scratch repository it builds extensions in. Once a tainted session has worked in a lab, the lab carries a sticky mark: every extension proposed from it goes to you and mounts as third-party. A tainted turn on the Workspace or Full profile marks every lab in its company (a company mark, which new hires inherit). On Full it also leaves a machine-wide mark, since it could write any company's labs. Only you clear marks, after checking what is in the labs:

```text
brahma lab clear-taint <company> <handle>   one agent's lab
brahma lab clear-taint <company>            the company mark and every agent's lab mark in it
brahma lab clear-taint --machine-wide       the mark a Full-profile session left
```

A clear is refused while a tainted session or turn is still in scope. Commits made before the clear stay recorded as tainted.

**Agent-built extensions.** An agent proposes an extension from its own lab with `propose_extension`. Brahma decides its provenance from the lab commits that introduced its content. A clean one goes to the company's internal reviewer and then to you. One whose provenance is tainted or unrecorded, or that comes from a marked lab, goes straight to you and no teammate reads it. Nothing is mounted on any turn before you approve it. To try a folder yourself, `brahma ext try <folder> --company <company> --role <role> --prompt <text>` runs one throwaway Quick turn on the Sandboxed profile with the folder mounted; it files no ask, and everything it made is removed.

**Grants and presets.** An agent that needs more asks with `request_access`: a Bash domain, a WebFetch domain or a directory to read. You decide. A grant takes effect from the agent's next turn.

```text
brahma access <company>                              open access requests, and recently refused ones
brahma access approve <company> A-<n> --scope once|item|agent|role|company --duration turn|sprint|always
brahma approve <company> A-<n> --reject              reject one
brahma grants <company> [--all]                      the grant ledger
brahma grants revoke <company> G-<n>                 gone from the next turn
brahma presets <company> [enable|disable <preset>]   both off by default
```

Two presets exist. `readonly-web-engineers` lets engineers, QA, DevOps, security and architects read well-known docs sites (exact hosts). `auto-low-risk` approves low-risk web reads for the sprint under the `auto` autonomy preset. Neither ever approves a medium or high risk or a reserved matter.

**Vouching.** You clear taint on a handbook page with `brahma kb <company> vouch <path>`, or on a resource with `brahma resource <company> vouch F-<n>`. A whole-page edit of your own also vouches. When you add a resource, `--vouch` marks it `FROM YOU` and `--untrusted` marks it `EXTERNAL`, overriding the default. A repository imported with `brahma company create --from-repo` is outside content until you lift the mark with `brahma company trust-import <company> --yes` (engine stopped).

## In the app

**Work › Handbook** shows a `TAINTED` chip on pages written from outside content; the **MEMORY** tab shows it on facts. Editing a tainted page is an explicit vouch: the edit sheet shows the warning "Saving vouches for the whole page, including agent-written text" and its button reads **Save and vouch**. **Work › Resources** shows each resource's trust, `FROM YOU` or `EXTERNAL`. Access requests arrive in the **Inbox**; **Inbox › Grants** is the grant ledger.

## From the CLI

- [`brahma lab clear-taint`](/docs/cli/lab/clear-taint/)
- [`brahma access`](/docs/cli/access/), [`brahma access approve`](/docs/cli/access/approve/), [`brahma approve`](/docs/cli/approve/)
- [`brahma grants`](/docs/cli/grants/), [`brahma grants revoke`](/docs/cli/grants/revoke/), [`brahma presets`](/docs/cli/presets/)
- [`brahma kb`](/docs/cli/kb/) (`vouch`), [`brahma resource`](/docs/cli/resource/) (`vouch`, `--vouch`, `--untrusted`)
- [`brahma ext try`](/docs/cli/ext/try/), [`brahma company trust-import`](/docs/cli/company/trust-import/)

## What it does not do

- **Taint is enforced by Brahma's tools, not by the shell.** On the Workspace profile an agent's Bash can clear or forge taint flags by removing or writing the flag files or editing the database. The Sandboxed profile blocks this.
- **The classifier is advisory.** It can taint a session that reached nothing, and it is not what stops a command from reaching the network. The allowlist is, on Sandboxed only.
- **A marked work item still merges after a normal reviewer approval.** Its taint mark clears only when the item is done.
- **A lab mark covers the whole agent,** not one session. There is no command yet that lists lab marks.
- **On Workspace and Full,** an untainted agent writing into another agent's lab is not detected, and the folders of extension reviews and `ext try` stay readable to agents.
- **Resource scopes and lab privacy** are enforced only by Brahma's tools on Workspace and Full; an agent's shell can read them.
- **Vouching does not check the content.** It records that you took responsibility for it. Read it first.

## Related

- [Memory](/docs/concepts/memory/) (session taint in search)
- [Handbook](/docs/concepts/handbook/)
- [Resources](/docs/concepts/resources/) (trust and the `EXTERNAL` rule)
- [Profiles](/docs/safety/profiles/)
