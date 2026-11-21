---
title: Extensions
description: "One installable thing, a trust boundary that decides where each part runs, one install pipeline for every source, and a connector gateway that keeps third-party code out of the agent's process."
sidebar:
  order: 8
---

## Context

Brahma had several half-overlapping ways to give agents more capability: a company plugin directory and skill library, connectors and an integrations catalogue, lab modules and a toolbox. The design replaces them with one concept, within the five-noun budget, and settles where third-party code may run. It rests on live probes of the `claude` CLI's plugin behaviour and three reviews of the draft (security, developer experience, architecture fit).

## Decision

- **One thing to install: an extension.** It is a folder the `claude` CLI itself accepts as a plugin, with a minimal manifest. It may contain plugin parts (`skills/`, `commands/`, `agents/`, `bin/`), which run inside the agent's sandbox, and an optional connector, an MCP server described in a `brahma.json` sidecar, which runs in a Brahma-owned sandbox outside the agent. A skill-only extension needs no Brahma file. Extensions are a Company setting, not a new noun.
- **The trust boundary decides where each part runs.** Skill text and `bin/` are mounted into the turn. Connectors run only behind the connector gateway (`brahma ext gateway`), a stdio MCP server in the Brahma binary that launches the upstream under a deny-default sandbox with no ambient environment, or calls a remote itself, injects credentials from the Keychain, filters and routes tools and marks taint. Nothing from a package ever runs unsandboxed: no hooks, language servers, monitors, plugin settings, plugin-declared MCP servers or install scripts.
- **Brahma checks author claims instead of trusting them.** Publisher, source and tree hash are recorded from the actual fetch, never read from the package. A package's own statements about tool risk are suggestions shown on the owner card; safe defaults apply and any downgrade is recorded as owner-attested. The validator works out what a package executes.
- **One pipeline for every source** — built-in catalogue, a git commit, a marketplace entry, a folder, an import from the owner's own `claude` setup, an agent's lab: fetch at a pinned hash, stage, decompose, validate, lint and scan, snapshot the connector's tools, run deterministic tests, then one pending Inbox ask, then materialise hash-pinned and bind with new tools off by default.
- **One resolver decides who gets what**, from the pack's role templates, company overrides and active grants, keeping only what is installed and verified and removing what taint blocks. The TurnProfile compiler reads only this resolver, and the mount set is frozen for each session.
- **One new ask kind, `extension`**, for install, update, enable and dev-link; skill text is a reserved prompt change and a connector a reserved connectors matter, so both are owner-only under every preset.
- **One SDK, `brahma ext`**, for authoring, linting, testing, trying and publishing extensions. Agents can author extensions in their lab and submit them with `propose_extension`.

## Consequences

- The old concepts are retired: plugin library, module manifests, the toolbox, the integrations page, string lists of skills and connectors on role templates.
- The validator refuses, from any source, every part that would run outside the sandbox or reconfigure the harness.
- Accepted residual risks are written down: a third-party skill's description sits in the turn's listing; a third-party stdio connector can use the vendor API it holds a credential for; on the non-sandboxed profiles a same-user process can tamper with materialised files between hash and load; injection scanning is heuristic. The structural controls are what matter.

## Source

`2026-10-21-extensions-design.md`
