---
title: Handbook
description: The company's wiki. Pages with every revision kept, paths and sections, restricted sections, edit leases, auto pages generated from live data, export and the read-only mirror in the workspace.
sidebar:
  order: 10
---

## What it is

The handbook is the company's wiki. Pages live in the database, with every revision kept. Agents read and write pages with their tools; you manage them in the app or with `brahma kb`.

Some pages are written by the engine from live data and cannot be edited by anyone: the org chart, the roster, the decisions log, the release history and the sprint summaries.

## How it works

**Paths and sections.** A path is up to `6` parts (`Engineering/Environments`). The first part is the section. A software company starts with Company, Product, Engineering, Design, Go-to-market, Operations, Research, Decisions log and Meeting notes. `INDEX` and `README` are reserved names. Pages link with `[[Path]]` or `kb:Path`, and each page lists its backlinks.

**Restricted sections.** A heading ending ` [restricted]` is for executives only; ` [restricted: <roles>]` is for those roles. The section and every subsection under it are hidden from other readers in reads, search, backlinks, old revisions and the mirror. Restrictions nest, and every enclosing one must be satisfied. An agent that cannot see every section must edit one section at a time. An edit that would change a hidden section, open a code fence over one or add a heading at its level is refused.

**Leases and edits.** Agents write with `kb_write` for a work item they own or lease. The write takes the page's edit lease for `7200` active seconds, and every edit names the revision it read (compare-and-swap). Agents read with `kb_read` and search with `search_kb`.

**Auto pages.** Org chart, Roster, Decisions log, Release history and Sprint summaries are generated from live data every `60` active seconds when their inputs change. No one can edit them. The decisions log shows decided asks by title only, reserved matters under a restricted section, and never terminations.

**Taint and vouching.** A page written in a session that read outside content is tainted. Only you clear it: `brahma kb <company> vouch <path>`, or a whole-page edit of your own. In the app, editing a tainted page is an explicit vouch; the sheet says so and its button reads **Save and vouch**.

**Export.** `brahma kb <company> export --to <empty dir>` writes Markdown files with front matter and an `INDEX.md`. A company export (`brahma export`) includes `handbook/`.

**The `.brahma/kb` mirror.** The workspace gets a read-only Markdown copy for agents' Bash and Read tools. It holds untainted pages only, with restricted sections removed. Each refresh sweeps it and rewrites any file that changed. A planted link raises an engine alert and wipes the mirror: it fails closed.

## In the app

**Work › Handbook** shows the page tree with `AUTO` and `TAINTED` chips, the selected page, its backlinks and the recently changed pages with revision numbers. From here you edit, roll back and export. The **MEMORY** tab shows remembered facts and episodes; see [Memory](/docs/concepts/memory/).

<img src="/screenshots/handbook.png" srcset="/screenshots/handbook@2x.png 2x" width="1600" height="1000" alt="The Handbook view of a seeded demo company: a page tree by section with AUTO and TAINTED chips, an empty page pane, a backlinks panel and a recently changed list" loading="lazy" decoding="async" />

*Work › Handbook in a seeded demo company. Auto pages carry an `AUTO` chip; a page written from outside content carries `TAINTED`.*

## From the CLI

- [`brahma kb`](/docs/cli/kb/): `list`, `show`, `export`, `rollback`, `vouch`, `status`
- [`brahma export`](/docs/cli/export/)

## Related

- [Memory](/docs/concepts/memory/)
- [Resources](/docs/concepts/resources/)
- [Sprints](/docs/concepts/sprints/)
