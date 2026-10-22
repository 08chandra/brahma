# Brahma Extensions: final design

Status: FINAL design proposal, 2026-10-21. Read-only research; no code changed. Owner sign-off is still needed on the decisions in §10.

Inputs: spec v2 (§1.3, §4.3, §4.4, §4.7, §4.8, §4.10.1, §4.16, §5); Plan 5-lite (decisions, Tasks 1a, 1b, 5, 9, 10, 11); Plan 3a (built `IndustryPack.swift`, `AskKind`, `ReservedMatters`); Plan L; the master roadmap; the three research passes (plugins, MCP, inventory) with their live probes on Claude Code 2.1.307; and three reviews of the draft (security, developer experience, architecture fit). §11 lists what changed from the draft.

> **Attribution correction.** The design review (`docs/research/2026-10-21-design-review.md`) does **not** recommend collapsing labs, modules, Toolbox, skills, plugins and CLI tools into "Skill" + "Connector". Its extension items are H7, rec 8 and rec 12. This design rests on the §1.3 concept budget and §4.10.1.

---

## 0. The design in one page

- **One thing to install: an extension.** It is a **valid Claude Code plugin folder**. Its `.claude-plugin/plugin.json` may hold only `name`, `version`, `description` and `author`. It can contain two kinds of part:
  - **Plugin parts**: `skills/`, `commands/`, `agents/` and `bin/`. These run inside the agent's Claude sandbox.
  - **An optional `connector`**: an MCP server, either a vendored stdio server or a remote HTTP URL. It is described in an optional `brahma.json` sidecar and runs inside a Brahma-owned sandbox, outside the agent.

  A skill-only extension needs no Brahma file at all. "Extensions" is a **Company setting, not a new noun** (§1.3 budget).
- **The trust boundary decides where each part runs:**
  - Skill text and `bin/` are mounted with `--plugin-dir`.
  - Connectors run only behind the **Brahma connector gateway** (`brahma ext gateway`), a stdio MCP server in the Brahma binary. The gateway launches the upstream under deny-default Seatbelt with no ambient environment, or calls the remote itself, injects credentials from Keychain, filters and routes tools, and marks taint.
  - Nothing from a package ever runs unsandboxed: no hooks, LSP, monitors, plugin settings, plugin-declared MCP, install scripts or `command` sources.
- **Brahma checks author claims instead of trusting them.**
  - The installer records `publisher`, `source` and the tree hash in the DB from the actual fetch path. It never reads them from the package.
  - Tool risk, route and `untrustedOutput` from a non-Brahma package are only suggestions. The owner card shows them, safe defaults apply, and any downgrade is recorded as owner-attested.
  - The validator works out what a package executes. Its own claims are ignored.
- **One pipeline for every source** (Brahma's own fetcher; it never runs `claude plugin install`):

  ```
  fetch@pinned SHA (sandboxed) → stage → decompose → validate → lint/scan → snapshot connector tools (sandboxed, no creds) → deterministic tests → [lab only: review turn] → ONE pending Inbox ask (kind: extension) → materialize (hash-pinned) → bind (new tools default off)
  ```

- **One resolver decides who gets what.** `RoleBundle.effective(company, role, agent)` takes the pinned pack's `RoleTemplate.extensions`, applies company overrides, adds active `extension` grants, keeps only what is installed and verified, and removes what taint blocks. The TurnProfile compiler reads only this resolver. The mount set is frozen for each Claude session.
- **One new ask kind, `extension`**, for install, update, enable and dev-link.
  - Skill text is a reserved `prompt-change` and a connector is a reserved `connectors` matter, so both are owner-only under every preset.
  - Gateway write, spend and outbound asks reuse the kinds 3a already reserves: `spend`, `outbox`, and `other` with a category. All of them use one engine-executes-once payload.
- **One SDK, `brahma ext`**:
  - Authoring: `new`, `lint [--fix --snapshot --json]`, `test` (deterministic), `call` (replay), `try` (one dev turn), `link` (owner dev mount), `eval` (advisory), `publish` (to a Brahma-owned marketplace.json).
  - Agents can run `new`, `lint`, `test` and `call` in their lab sandbox, using a vendored SDK cache and a built-in `extension-authoring` skill. They submit with `propose_extension`.
- **Where it lands:**
  1. **5L Task 5** is rewritten as the *extension core*: validator, store, resolver, mounts, owner CLI. **5L Task 9** turns the grant kind into `extension`. **5L Task 10** adds the taint rules.
  2. **Plan X-core** (5 tasks, roadmap **#5½**, after L and before ML) adds importers, the Inbox card, the SDK, `propose_extension` and skill-only catalog rows.
  3. **Plan X-connectors** (8 tasks, roadmap **#10½**, after the dogfood week and Ops, before M #11) adds the gateway, connector asks and the first connector catalog.
  4. Plans M, G, 7, 11, 9 and 8 consume this one model instead of building their own.

```
 sources: built-in catalog (in signed app) · git@SHA · CC marketplace entry (format only) · folder/zip · "import from my Claude Code" · agent lab
                         │  Brahma fetcher under SandboxedRunner (writes: staging only; egress: pinned host only)
                         ▼
             ExtensionInstaller: stage → decompose → validate → lint/scan → snapshot → test → ask(kind: extension, pending)
                         │ owner approves in app
     ┌───────────────────┴──────────────────────────────────┐
 data home (agents: no read/write)                     workspace (agents: read-only)
 <home>/extensions/store/<id>/<hash12>/                <ws>/.brahma/ext/<id>/<hash12>/plugin/
   connector/ (vendored server) · ext.lock.json          .claude-plugin/plugin.json · skills/ commands/ agents/ bin/
     │                                                    │
 per turn: TurnProfileCompiler ← RoleBundle.effective(...)  (frozen per Claude session)
     │                                                    │
 --mcp-config ext_<id> → brahma ext gateway             --plugin-dir per mounted extension (sorted by id)
   (turn token + one-shot nonce, snapshot tools/list,     (Claude sandbox: Bash, bin/, ! injection)
    route/ask, Keychain creds, redaction, taint, audit)
     │
 upstream: stdio under deny-default Seatbelt (env -i, HOME→state, egress via CONNECT proxy)  |  HTTPS remote called by the gateway
```

---

## 1. The concept

### 1.1 What an extension is

An extension is a folder that Claude Code itself accepts as a plugin. It has these parts:

| Part | Files | Runs where | Reaches the agent as | Secrets |
|---|---|---|---|---|
| skills | `skills/<name>/SKILL.md` plus reference files and scripts | Agent context. Scripts and `!` injections run through Bash in the Claude sandbox (verified) | `/<id>:<skill>` via `--plugin-dir` | Never |
| commands | `commands/**/*.md` | Agent context | `/<id>:<cmd>` | Never |
| agents | `agents/**/*.md` | Inside the turn and its sandbox. `tools` can only narrow | `<id>:<agent>` (Task tool) | Never |
| bin | `bin/<id>-*` | Sandboxed Bash, placed after the system PATH (verified) | Commands on PATH | Never |
| connector | `brahma.json` `connector` plus `connector/` (vendored build) or a remote URL | Brahma gateway plus a per-connector Seatbelt sandbox, outside the agent | `mcp__ext_<id>__<tool>`, exact allow entries | Engine-held, injected only into the upstream |

Two parts are planned but **refused in format 1**, as reserved keys:
- `checks` (engine-run validators): Plan G owns check templates.
- `knowledge`: ML is lean and has no auto-ingest.

Playbooks and role-card text stay owned by the pack. A pack playbook may name a skill ("use `/brand-voice:brand-voice`"). Extensions do not inject text into role cards or orientation.

The validator **never accepts** the following, from any source:
- hooks, whether in `hooks/`, the manifest or any frontmatter;
- `.mcp.json` or `mcpServers` (the importer converts these to a connector, §3.3);
- `.lsp.json` or `lspServers`;
- `monitors/`, `settings.json`, `output-styles/`, `themes/`, `workflows/`;
- the manifest keys `channels`, `userConfig` and `dependencies`;
- a root `CLAUDE.md`;
- top-level `node_modules/`;
- symlinks and hard links;
- `command`-source and `npm`-source plugins.

Each of these either runs outside the sandbox (hooks, MCP, LSP and monitors were all verified to) or reconfigures the harness.

### 1.2 Rules that keep it modular

- **The unit you enable is the extension.** `skillOverrides` does not affect plugin skills, so there is no per-skill toggle. Connector tools are the one exception: each can be toggled through exact allow and deny rules plus gateway filtering.
- **Authoring rule:** make one extension per capability that can be granted on its own. Named bundles belong to Plan G. This design ships only `RoleTemplate.extensions` plus company overrides.
- **CLIs are split by trust:**
  - Helpers without secrets go in `bin/` and run sandboxed.
  - A credentialed CLI is not an extension part in format 1. Plan L's `HostingAdapter` stays engine-internal and unchanged; it may be wrapped later, or never.
- **What goes where:** a reusable multi-step procedure is a skill, a short per-item-type pointer is a pack playbook, and learned facts are memory. Plan 9's procedural-memory promotion outputs a skill extension through `propose_extension`.

### 1.3 What this replaces

| Existing concept | Becomes | Retired |
|---|---|---|
| Company plugin dir and skill library (v2 §4.8.2, 5L `pluginLib`) | Plugin parts of installed extensions at `.brahma/ext/<id>/<hash12>/plugin` | Both names. `pluginLib` → `extLib` |
| Claude Code plugin | The extension's source format and its runtime form | "Plugin" as an owner noun. No `brahma plugin` alias, since nothing has shipped |
| Bare SKILL.md folder | The smallest extension. The importer wraps it in a generated 4-key `plugin.json` | — |
| Connector and Integrations catalog/page (v2 §4.10.1, Plan 11) | The connector part. Catalog rows are extension folders shipped in the app | The Integrations page |
| Lab module, `module.json`, `propose_module`, Toolbox and `toolbox/` (v2 §4.16, Plan 9) | A draft extension in the lab, submitted with `propose_extension`. Status, tests and provenance live in the DB. "Built by your team" is a filter on the Installed list | `module.json`, `propose_module`, `toolbox/`, the Toolbox UI |
| MCP tools in modules (old §6.14) | A connector with an authored stdio server, run by the gateway | MCP on the agent's PATH |
| `RoleTemplate.skills` and `.connectors` (`[String]`, built in 3a) | `RoleTemplate.extensions: [ExtensionRef]`. Legacy strings decode with a warning | The two string fields (kept for decoding only) |
| `IndustryPack.connectors: [String]` | `IndustryPack.extensions: [ExtensionSuggestion{ref, roles, optional}]` | — |
| `companyPlugin` table, `GrantKind.plugin` | `companyExtension` + `extensionBinding`, `GrantKind.extension` | `companyPlugin.roles` as a source of truth |
| "System install" access ask (v2 §4.7.5) | `brahma.json` `requires.hostTools`. The doctor checks it, and a missing tool becomes an L `humanTask` | The grant kind (owner decision §10.6) |
| "Tool class" access ask (v2 §4.7.5) | A connector tool grant `<id>:<tool>`, or a role binding edit | The grant kind (owner decision §10.6) |

---

## 2. Package format

### 2.1 Layout

```
<id>/
  .claude-plugin/plugin.json   # REQUIRED. Exactly name, version, description, author. name = id.
  skills/<skill>/SKILL.md      # plus reference/*.md, scripts/
  commands/*.md  agents/*.md
  bin/<id>-<tool>              # helpers must be prefixed with the extension id
  assets/  README.md  LICENSE
  brahma.json                  # OPTIONAL: connector, agent egress, host tools, role suggestions
  connector/                   # connector source plus VENDORED build output (dist/, lockfile)
  tests/                       # deterministic cases and replay fixtures
  ext.lock.json                # GENERATED by `brahma ext lint --snapshot`; never hand-edited
```

- The working folder is a real plugin. While editing, `claude --plugin-dir .`, `claude plugin validate --strict` and `claude plugin details` all run on it unchanged. Exporting it to a marketplace changes nothing.
- At runtime only the plugin parts are copied into the workspace. `brahma.json`, `connector/`, `tests/` and the lock go to the data home.
- **Id rules:** `^[a-z][a-z0-9-]{0,39}$`, and the id may not contain `anthropic` or `claude`. An extension with a connector must have an id of at most 20 characters, and lint enforces `len("mcp__ext_") + len(id) + len("__") + len(tool) ≤ 64`, which allows tool names of at most 33 characters at the maximum id length. A test covers the longest allowed id and tool name.
- Ids are unique per company. An install is refused if its id matches an id the pack references but the publisher differs (§2.4).

### 2.2 `brahma.json` (format 1, every key optional)

```json
{
  "brahma": 1,
  "connector": {
    "transport": "stdio",
    "run": ["node", "connector/dist/server.js"],
    "url": null,
    "credentials": [ { "slot": "adminToken", "title": "…", "kind": "token", "howTo": "…",
                       "providerScopes": ["…"], "deliver": "fd" , "test": "shop_info", "rotateDays": 90 } ],
    "settings":    [ { "key": "shop", "title": "Store domain", "pattern": "^…$", "example": "acme.myshopify.com" } ],
    "network": ["{settings.shop}"],
    "limits": { "timeoutSec": 30, "maxResultChars": 20000, "callsPerTurn": 40, "callsPerDay": 2000 },
    "tools": { "<tool>": { "risk": ["read"], "route": "direct", "reserved": null,
                           "amountArg": null, "dataClasses": [], "untrustedOutput": true } }
  },
  "agentNetwork": [],
  "requires": { "hostTools": ["node>=22"] },
  "suits": { "roles": [ { "role": "support", "tools": ["…"] } ], "tags": ["…"] },
  "metering": { "kind": "none" }
}
```

- `transport` is `stdio` or `http`. For `http`, `url` is set and `run` is null. There is no `declarative-http` or `cli` transport, and no argument-rule language.
- `credentials[].deliver` says how a stdio upstream receives the credential:
  - `fd`: on inherited fd 3 as JSON. This is the default for Brahma templates and keeps it out of `ps eww`.
  - `env`: as an environment variable. This is for third-party servers, and is refused on Workspace and Full (§4.4).

  For `http` the credential is always a header that the gateway injects. OAuth means a sign-in ask, with tokens refreshed on the engine side.
- `tools` is a **policy overlay** keyed by tool name. Names, schemas and descriptions come from the server's own `tools/list`, recorded in `ext.lock.json`, so tools are declared only once. A tool with no overlay entry defaults to `risk: [write, destructive, external]`, `route: ask` and `untrustedOutput: true`, and lint lists it as "unclassified".
  - Thresholds such as "more than 50 units" are expressed by **splitting tools** (`inventory_adjust_small` enforces the cap in server code, `inventory_adjust` is routed `ask`), not with expressions.
  - `amountArg` names the spend argument. A spend tool whose `amountArg` is missing or fails to parse is refused before any ask is created, so it fails closed.
- `agentNetwork` lists domains that sandboxed agent Bash needs, for example for a `bin/` helper that fetches docs. The owner approves them, and they are added to the agent egress allowlist only for roles that mount the extension.
- `metering.kind` is `none`, `usage` or `spend`. Anything other than `none` requires a provider-side cap to be confirmed on the install card (§4.10.1).

**Computed by lint, never authored**, and stored in the DB and shown on the card:
- the parts present;
- `executes`: whether `bin/` exists, whether skills contain scripts, whether `!` injection is used;
- every host or URL found, compared with the declared `network` and `agentNetwork`;
- always-on tokens, from `claude plugin details` run on the allowlisted copy;
- hidden-Unicode flags;
- frontmatter that was stripped.

**Set by the installer, DB-only, never read from the package:**
- `publisher`: one of `brahma` (shipped inside the code-signed app bundle), `company:<slug>` (built in this company's lab and approved), `third-party:<host>`, or `local`;
- `source`: `{type, url, sha}`;
- `treeSha256`: computed over the folder as it is, excluding only `ext.lock.json`;
- the time it was fetched;
- for connectors from the vendor-namespace allowlist: the verified registry namespace.

### 2.3 How much Brahma trusts each policy field

| Field | `brahma` (app-bundled) | `company:<slug>` (lab-built and approved; no tainted-provenance commits) | `third-party:*` / `local` |
|---|---|---|---|
| tool `risk`, `route` | Used as written | Used as written (the owner saw it at review) | **Suggestion only.** Defaults apply. Any downgrade to `read` or `direct` needs an owner tick on the card, recorded as `ownerAttested` |
| `untrustedOutput` | Used as written | Used as written | **Forced `true`** |
| `dataClasses` | Used as written | Used as written | Used as written (it can only add restrictions) |
| Skill invocation is a taint source (§4.5) | No | No | **Yes** |
| Mount on Workspace/Full profiles | Yes | Yes | **No** |

The table is enforced on the engine side. Nothing in the package can move a tool into a less restrictive column.

### 2.4 References from packs

```
ExtensionRef = { publisher, id, version?, tools?: [String], writeRoute?: "ask" }
```

- A binding matches only when `publisher` equals the installed record's verified publisher. A pack that suggests `brahma/github` will never bind a `github` installed from some git URL.
- `version` is a label. The real pin is the installed hash.
- Pack `validate()` **warns** on unknown refs and never errors, until the catalogs exist.

### 2.5 Example: `brand-voice`, a skill extension built in a lab (no Brahma file)

```
brand-voice/
  .claude-plugin/plugin.json      {"name":"brand-voice","version":"1.2.0","description":"Write and review public copy in Acme's voice.","author":{"name":"Mira (Content lead)"}}
  skills/brand-voice/SKILL.md
  skills/brand-voice/reference/{voice-guide.md,examples.md}
  bin/brand-voice-lint            # 0755, pure text linter, no network
  tests/cases/lint.yaml  tests/fixtures/*.md
```

```markdown
---
name: brand-voice
description: Rewrite or review public copy in Acme's voice (plain, warm, specific; no hype). Use for social posts, landing pages, emails, release notes.
when_to_use: Any text a customer or the public will read.
---
1. Read reference/voice-guide.md (rules) and reference/examples.md (before/after pairs).
2. Draft. Then run `brand-voice-lint <file>` and fix every ERROR line.
3. Report the lint result in your hand-off.
```

The pack's marketing playbook may say "use `/brand-voice:brand-voice`".

### 2.6 Example: `shopify`, a first-party connector (stdio server built from the Brahma template)

Shopify's official MCP servers are not in the registry under a Shopify namespace, and Storefront MCP is customer-facing. So Brahma ships its own small TypeScript server that calls the Admin GraphQL API. It runs under the gateway sandbox, and its egress is limited to the store domain.

```json
{
  "brahma": 1,
  "connector": {
    "transport": "stdio",
    "run": ["node", "connector/dist/server.js"],
    "credentials": [{ "slot": "adminToken", "title": "Admin API access token", "kind": "token", "deliver": "fd",
      "howTo": "Shopify admin → Settings → Apps and sales channels → Develop apps → Create app → Admin API scopes below → Install → reveal token once.",
      "providerScopes": ["read_products","write_products","read_inventory","write_inventory","read_orders","write_orders","write_discounts"],
      "test": "shop_info", "rotateDays": 90 }],
    "settings": [{ "key": "shop", "title": "Store domain", "pattern": "^[a-z0-9][a-z0-9-]*\\.myshopify\\.com$", "example": "acme.myshopify.com" }],
    "network": ["{settings.shop}"],
    "limits": { "timeoutSec": 30, "maxResultChars": 20000, "callsPerTurn": 40, "callsPerDay": 2000 },
    "tools": {
      "shop_info":              { "risk": ["read"], "route": "direct", "untrustedOutput": false },
      "products_search":        { "risk": ["read"], "route": "direct" },
      "product_get":            { "risk": ["read"], "route": "direct" },
      "inventory_levels":       { "risk": ["read"], "route": "direct", "untrustedOutput": false },
      "orders_list":            { "risk": ["read"], "route": "direct" },
      "order_customer_get":     { "risk": ["read"], "route": "direct", "dataClasses": ["customer-pii"] },
      "product_update_draft":   { "risk": ["write"], "route": "direct" },
      "product_publish":        { "risk": ["write","external"], "route": "ask" },
      "inventory_adjust_small": { "risk": ["write"], "route": "direct" },
      "inventory_adjust":       { "risk": ["write"], "route": "ask" },
      "price_update":           { "risk": ["write","external"], "route": "ask", "reserved": "pricing" },
      "discount_create":        { "risk": ["write","spend","external"], "route": "ask", "reserved": "pricing", "amountArg": "value" },
      "order_refund":           { "risk": ["spend","external","destructive"], "route": "ask", "reserved": "money", "amountArg": "amount" },
      "product_delete":         { "risk": ["destructive"], "route": "ask", "reserved": "data-deletion" }
    }
  },
  "requires": { "hostTools": ["node>=22"] },
  "suits": { "roles": [
    { "role": "merchandiser", "tools": ["shop_info","products_search","product_get","inventory_levels","product_update_draft","product_publish","price_update","inventory_adjust_small","inventory_adjust"] },
    { "role": "support", "tools": ["shop_info","orders_list","order_customer_get","product_get","order_refund"] },
    { "role": "analyst", "tools": ["shop_info","products_search","orders_list","inventory_levels"] } ],
    "tags": ["ecommerce"] },
  "metering": { "kind": "none" }
}
```

How the server code backs the policy:
- `product_update_draft` refuses products that are not drafts.
- `inventory_adjust_small` refuses `|delta| > 50`.
- `orders_list` returns no customer contact fields. Contact details are only available through `order_customer_get`, which carries the PII data class.
- Reserved categories use 3a's built list: `pricing`, `money` and `data-deletion`.

---

## 3. Install

### 3.1 Sources

Every source feeds the same `ExtensionInstaller`. All fetching runs under `SandboxedRunner`: it can write only to staging, and its egress is limited to the pinned host.

| Source | Fetch | Pin |
|---|---|---|
| **Built-in catalog** | Folders inside the code-signed app bundle. Each app update carries a revocation list of bad catalog hashes | App signature plus tree hash |
| **Git URL** | Fetched with 5L `GitCommand` (`core.fsmonitor` and `hooksPath` neutralised), shallow, at a full 40-character SHA. A ref is resolved to a SHA once and shown on the card | SHA plus tree hash |
| **Claude Code marketplace entry** | Brahma **reads** `marketplace.json` and resolves the entry itself. Accepted source types: relative path, `github`, `url` or `git-subdir` **with `sha`**, or `archive` with `sha256`. Entries are refused when they use `command` or `npm` sources or declare `dependencies`. Brahma does **not** run `claude plugin install`, because it installs Node dependencies on cache copy and cannot be told not to, follows `dependencies`, runs `command` sources, and leaves a gap between check and install | SHA plus tree hash |
| **Local folder or `.zip`** | Copied from disk | Tree hash |
| **Import from my Claude Code** | An explicit owner action. The engine copies from `~/.claude/plugins/cache/...`, which agents can never read | Tree hash |
| **Agent lab** | `propose_extension{path}`. The engine snapshots the path at the agent's lab commit with `GitCommand` (`git archive`) | Lab commit plus tree hash |
| **MCP registry** | Only through built-in catalog rows, or a `server.json` the owner pastes. Never by free-text search. Remote rows are trusted only under the vendor-namespace allowlist: `com.stripe`, `io.github.github`, `com.supabase`, `com.figma.mcp`, `com.cloudflare.mcp`, `io.github.aws`, `com.notion`, `app.linear`, `io.github.getsentry` | Version plus npm integrity or mcpb `fileSha256`. `oci` is refused in v1 |

### 3.2 Pipeline

1. **Stage** into `<home>/extensions/staging/<uuid>/`. Limits:
   - at most 20 MB and at most 2,000 files;
   - no links, devices, or names containing control or bidi characters;
   - nothing outside the package root;
   - every component path must be relative and stay inside the package.
2. **Decompose** (§3.3), producing import notices.
3. **Validate.** This uses an allowlist, so any unknown key is refused.
   - `plugin.json` may hold exactly the four keys.
   - Top-level entries: `.claude-plugin/`, `skills/`, `commands/`, `agents/`, `bin/`, `assets/`, `connector/`, `tests/`, `brahma.json`, `ext.lock.json`, `README*` and `LICENSE*`.
   - Modes: text is 0644; only `bin/*` and the connector entry point are 0755.
   - `bin/` names must be prefixed `<id>-`, and any collision with another installed extension's `bin/` is refused.
   - **The frontmatter allowlist is checked on every `.md` file under `skills/`, `commands/` and `agents/`, recursively.**
     - Skills and commands may use: `name`, `description`, `when_to_use`, `argument-hint`, `disable-model-invocation`, `user-invocable`, `context` (value `fork` only), `agent` (an agent in the same extension, or a built-in one), `license`, `metadata`, `version`.
     - Agents may use: `name`, `description`, `tools` (must be a subset of the role's tools), `color`, `skills`.
     - Native and imported packages are handled the same way. `allowed-tools` and `model` are **stripped with a lint warning** (code and fix text). `hooks`, `mcpServers` and `lspServers` are **refused**.
     - Why `allowed-tools` is stripped: per the docs, it pre-approves tools for the invoking turn and workspace trust does not gate it. A third-party skill could otherwise pre-approve `mcp__company__*` or another role's connector tools.
4. **Lint and scan.** These are heuristics that raise flags on the card; the real controls are structural.
   - Hidden, zero-width or bidi Unicode in **every** string: Markdown, `plugin.json`, `brahma.json`, and snapshot tool names and descriptions.
   - Injection phrasing.
   - References to credential paths.
   - `curl | sh` patterns, base64 blobs, and binaries outside `assets/` and the connector build.
   - The 5L T4 secret scan, run on everything including `tests/fixtures`.
   - Hosts found, compared with the declared ones.
   - Description length: at most 1,024 characters. Namespace collisions.
   - `claude plugin validate --strict` and `claude plugin details` are run **only on the allowlisted copy**, under `SandboxedRunner`, with `--setting-sources ""`, `--strict-mcp-config` and `--settings '{"disableAllHooks":true}'`.
5. **Connector build check.** The build must already be vendored: `connector/dist` plus its lockfile. **Nothing is installed at runtime.**
   - When Brahma vendors a server itself (the importer, or `ext lint --fix`), it uses `npm ci --ignore-scripts` with integrity hashes, or `pip download --only-binary :all: --require-hashes`, under `SandboxedRunner` with egress only to the registry host.
   - Packages that need install scripts or sdist builds are refused.
6. **Snapshot.** The gateway launches the upstream in its sandbox **with no credentials** (or with owner-supplied test credentials) and records `tools/list` in `ext.lock.json`: names, descriptions, input schemas and `schemaHash`.
   - The gateway caps descriptions at 1,024 characters.
   - MCP annotations only pre-fill the overlay suggestion.
   - If listing needs auth, the snapshot is deferred to activation (step 10).
7. **Deterministic tests** (§5.3). They are required for lab proposals and optional otherwise.
8. **Review.** Lab-built packages only: a 3a review turn by the manager, plus the architect if there is a connector. This is a pre-check, not the approval.
9. **One pending Inbox ask, `kind: extension`, `action: install`.**
   - Category: `connectors` if there is a connector, otherwise `prompt-change`. Both are reserved, so the ask is owner-only.
   - **CLI installs (`brahma ext add`) also create a pending ask, which the owner confirms in the app.** The CLI never creates an already-decided ask, because a determined Workspace or Full process can get around the process-ancestry check.
   - The card is described in §6.2.
10. **Materialize and activate.**
    - The verified tree goes into `<home>/extensions/store/<id>/<hash12>/`, read-only, in the data home.
    - The plugin parts go into `<ws>/.brahma/ext/<id>/<hash12>/plugin/`, which is read-only and not in any agent's `allowWrite`.
    - The `companyExtension` and binding rows are written.
    - For connectors: secure credential fields are saved to Keychain, or a sign-in ask is raised. Then the `test` tool is called, and the deferred snapshot is taken. If the live `tools/list` differs from the snapshot the owner approved, the extension is blocked and an `engineAlert` is raised.
11. **Bind.** Pack-suggested roles are pre-ticked only for skill-only extensions from `brahma` or `company:` publishers. Connector tools are ticked one by one on the card, and any tool not ticked stays off.

### 3.3 The decomposing importer

| Found | Becomes |
|---|---|
| `skills/`, `commands/`, `agents/`, `bin/`, `assets/` | Plugin parts, after the frontmatter allowlist. `bin/` files are renamed `<id>-*`, with a notice |
| A bare folder containing a SKILL.md | A generated 4-key `plugin.json`. The id is the frontmatter `name` |
| `.mcp.json` or `mcpServers` with `type: http` | `connector.transport: http`, URL pinned. Auth headers become token slots; OAuth becomes a sign-in ask |
| `.mcp.json` stdio entry `npx -y pkg` or `uvx pkg` | `connector.transport: stdio`. The version is locked with its integrity and **vendored under `SandboxedRunner` with install scripts off** (§3.2 step 5). `${CLAUDE_PLUGIN_ROOT}` is rewritten, and credential env vars become `deliver: env` slots. If vendoring fails, the connector is dropped with a notice and the skills are still offered |
| hooks in any form | Dropped: "This plugin's `<event>` hook will not run in Brahma." |
| `.lsp.json`, `monitors/`, `settings.json`, `output-styles/`, `themes/`, `workflows/`, `channels`, a root `CLAUDE.md` | Dropped, with a notice |
| `userConfig` | Values that look like secrets are offered as credential slots. Everything else is dropped |
| `dependencies` | Listed as "also install X?", each a separate ask. Never followed automatically |
| `node_modules/` at the top level | Refused |

Example: the AWS, Azure and Vercel vendor plugins import as one extension each. Their skills become plugin parts, their MCP servers become connectors (remote where the vendor offers one, such as `mcp.vercel.com`), and their hooks are dropped.

### 3.4 Who gets what

```
RoleBundle.effective(company, role, agent) =
    pinned pack:  RoleTemplate.extensions                       (ExtensionRef, publisher-matched)
  ⊕ company overrides: extensionBinding rows  (add|remove, scope role|agent, tools subset, writeRoute "ask")
  ⊕ active grants: GrantKind.extension  ("<id>" | "<id>:<tool>"; scope once·item·agent·role·company; duration turn·sprint·always)
  ∩ installed ∧ enabled ∧ compat-ok ∧ hash-ok ∧ profile-ok (§4.4)
  − taint (high-risk connector tools; §4.5)
```

- **Pack upgrades** go through the existing pack-upgrade diff ask. For every extension binding the upgrade adds or widens, that diff must show the same roles × tools risk grid as the install card. Connector tools a pack newly introduces default to off.
- **A G-generated pack that references connectors** is a reserved `connectors` ask.
- **Company creation:** only first-party skill-only extensions are pre-ticked. Connectors are listed unticked, and each one raises its own install card and sign-in ask after creation.
- **Review turns** mount no plugin parts, as in 5L today.

### 3.5 Updates, drift, rollback and uninstall

- **Updates are manual in v1.**
  - `brahma ext check-updates` compares against the catalog version, the git ref, or the marketplace entry.
  - Each available update becomes an `extension` ask with `action: update`. Its diff shows:
    - capability changes (domains, credential slots, risk, new or removed tools), highlighted;
    - schema changes (`schemaHash`);
    - the rendered text diff of skills, commands and agents;
    - **a highlighted "code changed" block listing every changed `bin/` file, vendored `connector/` file and script, with old and new hashes and a text diff where one is possible;**
    - lint and test results;
    - the change in always-on tokens.
  - On approval, bindings carry over and new tools stay off.
  - There is no auto-update policy in v1. If one is added later, it must exclude any update that changes executable content.
- **Drift.**
  - The materialized tree is **fully rehashed every time the compiler mounts it**. Trees are at most 20 MB, and a cache keyed on (inode, size, ctime) is allowed within one engine run.
  - At each connector session the live upstream `schemaHash` is compared with the snapshot.
  - Any mismatch blocks the extension and raises an `engineAlert`.
  - Residual risk, documented: on Workspace and Full profiles a process running as the same user can still race the hash. This is why third-party parts are never mounted there (§4.4).
- **Rollback.** The previous version is kept. `brahma ext rollback` reverts to it immediately, because it was already approved, and the action is recorded. Hashes on the revocation list cannot be restored.
- **Uninstall.**
  - The extension is unmounted from the next session, and its bindings and grants are removed.
  - Pending connector asks expire with a note.
  - Connector state is deleted after 14 days.
  - The owner can choose "Delete stored credentials too".
  - If the pack still suggests the extension, a "removed by owner" override is kept, so a later pack upgrade does not bring it back.

---

## 4. Runtime

### 4.1 What the compiler emits

| Input | Output |
|---|---|
| Plugin parts | One `--plugin-dir <ws>/.brahma/ext/<id>/<hash12>/plugin` per mounted extension, sorted by id. Verified: these load as `<id>@inline` under `--setting-sources ""`. `--disable-slash-commands` is dropped once any plugin part mounts (design review rec 8) |
| Connector | One `--mcp-config` entry, `ext_<id>: {command: <brahma>, args: ["ext","gateway","--ext","<id>@<hash12>","--turn","<turnId>"], env: {BRAHMA_TURN_TOKEN, BRAHMA_LAUNCH_NONCE}}`, written into `<home>/run/` with mode 0600 and denyRead for agents. `--strict-mcp-config` stays on. In the settings, `permissions.allow` gets **exact** `mcp__ext_<id>__<tool>` entries and never the server-level form. `permissions.deny` lists every other tool of that connector, which hides them from the model (verified) |
| Taint hook | The 5L PostToolUse matcher also covers `mcp__ext_.*`, `Skill` and `Task` (§4.5) |
| `agentNetwork` | Added to the turn's agent egress allowlist through the 5L T2 proxy |
| `requires.hostTools` | Checked by the doctor. If a tool is missing, the extension is not mounted and a `humanTask` is raised |

**Sessions.**
- The mount set and connector set are **frozen for each Claude session**. If a grant or binding changes either set, the next turn starts a **fresh session with a Continuity block**; it does not `--resume`.
- A one-turn grant therefore costs a fresh session.
- Mounts are byte-stable within a session, so the cacheable prefix holds.
- Spec §4.3.3 gains the line: "Extension skills and connector tools are per-role by design. The company tool list stays uniform, and company-tool authorization stays server-side."

The existing defaults stay: `disableBundledSkills: true`, built-in plugins off, `--setting-sources ""`.

### 4.2 The connector gateway (`brahma ext gateway`)

1. **Launch authentication.**
   - The gateway checks `BRAHMA_TURN_TOKEN` against the Store, as `brahma mcp` does (3a `b199165`).
   - It also redeems a **one-shot `BRAHMA_LAUNCH_NONCE`** that the engine registers for this turn and connector, bound to the PID of the `claude` process the engine spawned. The gateway checks `getppid()`.
   - It refuses to start when `sandbox_check` reports that it is sandboxed.
   - So a copied token cannot start a second gateway, from sandboxed Bash or from unsandboxed Workspace or Full Bash.
   - The gateway registers with 5L's `EmergencyStopObserver`. A stop kills the gateway and its upstreams.
2. **Narrow MCP surface.** Toward Claude, the gateway advertises only the `tools` capability, with its own fixed `instructions` string. It never forwards an upstream's `instructions`, prompts, resources or logging. It refuses upstream `sampling/createMessage`, elicitation and `roots/list` requests. `list_changed` notifications are logged as drift and never passed on.
3. **`tools/list`** is served from the **approved snapshot**, filtered to the agent's effective tools and then by taint. The upstream starts lazily on the first call. A tool the upstream adds later never reaches the model.
4. **`tools/call`** runs these steps in order:
   1. validate the arguments against the snapshot schema;
   2. check the live `schemaHash` (once per session);
   3. pick the route: `ask` if the overlay route is `ask`, or the risk includes spend, external or destructive, or a `reserved` category applies, or the binding's `writeRoute` is `ask`; otherwise `direct`;
   4. if the session is tainted and the tool is high-risk, refuse with the 5L text;
   5. execute, or queue the ask.
5. **Ask route.**
   - The gateway creates an ask that carries `payload{extension, hash, tool, args, request_id}`. The kind depends on risk:
     - `spend` when the risk includes spend (category `money`);
     - `outbox` when it includes external;
     - otherwise `other` with the tool's `reserved` category, or `connectors`.
   - **The card's main content is the schema-validated arguments**, and any amount is read from `amountArg`. An upstream-supplied preview may appear only below them, labelled untrusted and sanitized.
   - The ask ends the turn.
   - On approval, the **engine** runs exactly that payload once, idempotent on `request_id`, through the same upstream, and posts the result as a notice. Any edit means a new ask.
   - The only auto-approval is an explicit owner policy, which Plan 11 adds.
6. **Upstream sandbox.**
   - **stdio:**
     - `env -i` with only allowlisted variables;
     - `HOME` and `XDG_*` set to `<home>/extensions/state/<company>/<id>/`;
     - credentials on fd 3, or in env for `deliver: env`;
     - a **deny-default** Seatbelt profile (the probe used `allow default`, which is not acceptable). Writes are allowed only to the state dir. Reads are allowed only to the package, the runtime and system libraries; the owner's dotfiles, `~/.ssh` and Keychains are denied;
     - network only through the 5L CONNECT proxy, limited to `connector.network` and checked with AddressPolicy (no loopback, private or metadata addresses);
     - **mDNSResponder and dnssd mach lookups denied**, so the proxy resolves names;
     - all other mach lookups limited to the 5L check-runner set.
     - Verified with the probe wrapper: writes outside the state dir and egress were denied, and only the injected variables were visible.
   - **http:** the gateway makes the HTTPS calls itself through the egress policy, injecting headers from Keychain on each request. The token stays in gateway memory, so it never appears in any config, env or argv. OAuth refresh happens on the engine side.
   - **Linux (Plan 8):** bubblewrap, or `srt` (@anthropic-ai/sandbox-runtime, beta) as an optional backend behind `SandboxedRunner`.
7. **Credentials** are read through 5L's `SecretVault`, only by the gateway, only for the slots of that extension, and only at launch or request time. Agents never see them:
   - the Claude child env allowlist does not carry them;
   - `run/*.json` is denyRead;
   - Keychain mach lookups are denied in the agent sandbox.
8. **Output handling.**
   - Known secret values are redacted.
   - Results are capped at `maxResultChars`. Anything larger is written to a file in the agent's lab and the path is returned.
   - Every result is wrapped in an "untrusted connector output" label.
   - **The gateway marks the session tainted synchronously, before it returns any output that has `untrustedOutput` true.** If it cannot record the taint, it returns an error instead of the result.
9. **Limits.** `callsPerTurn` and `callsPerDay` are enforced, and calls count toward the item budget. Until Plan 11, every spend tool goes to an ask.
10. **Audit.**
    - Every call is written to `connectorCall`: turn, agent, item, extension, tool, route, outcome (ok, denied, queued, error or refused-tainted), redacted args and their hash, size, latency and amount.
    - Every lifecycle change is written to `extensionEvent`.
    - Each turn's mounts and connector set are recorded in the work record.

### 4.3 Permission layering (v2 §4.8.3)

| Layer | Effect on extensions |
|---|---|
| 0. Install ceiling | Nothing can exceed what the owner approved: domains, tools, credential slots, data classes. Grants cannot widen past it |
| 1. Company profile | See §4.4 |
| 2. Role (pack refs plus company overrides) | Which extensions mount and which tools are allowed. `writeRoute: ask` can only make a route stricter |
| 3. Trust (3b; T1 for everyone until then) | Later, for example `write: direct` only at T2 and above |
| 4. Item | Item-scoped grants. Every call is tagged with the item. Item budget |
| 5. Grants | `extension` grants add an extension or a single tool. Presets never auto-approve them (risk medium or above) |
| 6. Taint | See §4.5 |

### 4.4 Profile gate (Workspace and Full: agent Bash is not sandboxed)

On these profiles:
- **No plugin parts are mounted from `third-party:*` or `local` publishers**, whether or not they contain executables. Their text alone can tell the agent to run anything.
- `disableSkillShellExecution: true` is set.
- Credentialed connectors are mounted **only** over `http`, or stdio with `deliver: fd`. Credentials delivered as `env` are refused, because a same-user `ps eww` would expose them.
- Dev links (§5.1) are not mounted.

The card says all of this.

### 4.5 Taint

`TaintPolicy.everyToolClassified` is satisfied for dynamic tools by these rules:
- **A connector tool is taint-safe only if** its effective risk is exactly `read`, it has no `dataClasses`, and its effective `untrustedOutput` is false. That last condition is impossible for third-party publishers, per §2.3. Every other connector tool is high-risk: hidden and refused while the session is tainted.
- **Invoking a third-party skill is a taint source.** That covers the `Skill` tool on `<id>:*` and a `Task` invocation of a third-party `<id>:<agent>`. The trigger is a publisher of `third-party:*` or `local`, or a lab package with tainted-provenance commits.
  - Brahma and company-reviewed skills are not taint sources.
  - Residual risk: a third-party skill's *description* (at most 1,024 characters) is always in the listing. It is scanned, shown verbatim on the install card, and covered by the prompt-change approval.
- `propose_extension` and `request_access` are refused while the session is tainted.
- **Lab provenance.** The engine records the taint state of each turn on its lab commits. `propose_extension` lists every commit made in a tainted turn and flags it on the owner card. If approved, the extension's publisher becomes `company:<slug>` but it is **treated as third-party for taint and profile purposes**.

---

## 5. Building extensions: the SDK

### 5.1 Commands

| Command | Who | Does |
|---|---|---|
| `brahma ext new skill\|connector <id> [--dir <path>] [--no-creds]` | Owner, agents (in the lab) | Writes Brahma's **embedded templates** straight to `--dir`. It never calls `claude plugin init`, which always writes to `~/.claude/skills/<name>` and would leak into the owner's own sessions. The connector template is TypeScript only in v1. `--no-creds` gives a local tool server with an empty egress list |
| `brahma ext lint [path] [--fix] [--snapshot] [--json]` | Owner, agents | Runs the structural validator, the frontmatter allowlist, the scans, `claude plugin validate --strict` and `details` on the allowlisted copy, the name-length and id checks, and overlay-versus-snapshot checks. `--fix` strips disallowed frontmatter and prefixes `bin/` names. `--snapshot` runs the sandboxed probe and writes `ext.lock.json`. `--json` emits `[{code, path, line, message, fix}]` |
| `brahma ext test [path]` | Owner, agents, engine | Deterministic tests only (§5.3) |
| `brahma ext call <tool> --args <json> [--fixtures dir] [--live]` | Owner, agents (replay only) | Calls one tool through the real gateway code path, routing included, against the replay upstream. `--live` is owner-only and uses test credentials |
| `brahma ext try <path> --role <r> --prompt <p>` | Owner | One sandboxed Haiku turn compiled exactly as production would. The working folder is mounted, connectors run in replay mode, no ask is created, and the turn is recorded as a dev run |
| `brahma ext link <path> --company <co> --role <r> [--days 7]` | Owner | Mounts the working folder's plugin parts as `<id>@dev` on later turns, on the Sandboxed profile only. It needs one owner confirmation in the app and shows a "dev" badge. It is rehashed each turn and every change is logged. It expires after N days. Connectors are never linked |
| `brahma ext eval [path]` | Owner | Advisory. Wraps `claude plugin eval` on the allowlisted copy, with `--model haiku` |
| `brahma ext publish <path> --to company:<co> \| marketplace:<dir>` | Owner | `company:` starts the install flow. `marketplace:` adds an entry, with relative path or `github` plus `sha`, to a Brahma-owned `marketplace.json`, which other companies on the same machine, or the owner's own Claude Code, can install from. There is no `.bext` format |
| Lifecycle commands: `ext add <source> <co>`, `list`, `show`, `bind`, `unbind`, `update`, `rollback`, `rm`, `check-updates` | Owner | Mutating commands create pending asks (§3.2 step 9). They are refused inside agent turns (3a/5L ancestry rule) |

### 5.2 Templates (v1)

- **`skill`**: a SKILL.md with a sharp `description` and `when_to_use`, a `reference/` folder, an optional `bin/<id>-tool`, and `tests/cases/`.
- **`connector`**: a TypeScript MCP server using `@modelcontextprotocol/sdk`, built to `connector/dist` with its lockfile committed. It includes:
  - credential reading from fd 3;
  - a `brahma.json` with one overlay entry per tool;
  - honest annotations;
  - a contract test that fails if `tools/list` and the lock differ;
  - fixtures for replay;
  - a README stating the trust model: "Your server runs in a Brahma sandbox with only the domains you declare. It receives credentials on fd 3. Never log them."

Python and other languages come later. Check templates belong to Plan G.

### 5.3 Testing tiers

1. **Deterministic tier.** This is the default, it is required for proposals, and it runs offline in the lab sandbox:
   - lint;
   - contract: live `tools/list` equals `ext.lock.json`;
   - replay cases;
   - route assertions: an `ask` tool never reaches the upstream, and a tainted refusal returns the expected text;
   - `bin/` unit tests;
   - the author's own tests (for example `npm test`) against the vendored SDK cache.

   Example case:
   ```yaml
   tool: order_refund
   args: {order: "1043", amount: "18.00"}
   expect: {route: ask, askKind: spend, category: money, upstreamCalled: false}
   ```
   Tool names are bare; the harness adds the `mcp__ext_<id>__` prefix.
2. **Model tier, advisory.** `ext try` and `ext eval` show tokens, turns and always-on cost per role. They never gate anything.
3. **Fixtures.** `--record` (owner, test account) **never records headers**. It keeps body fields only from an allowlist. The secret scanner runs on all fixtures, and `publish` or `propose_extension` is refused if it finds a match.

### 5.4 Agents building extensions

- **Tooling in the lab sandbox.** Agents can run `ext new`, `ext lint --json`, `ext test` and `ext call` (replay). Writes go only to the lab.
- **SDK cache.** A read-only vendored cache at `<home>/extensions/sdk-cache`, containing the npm packages the connector template needs plus TypeScript, is readable from labs. Templates resolve offline.
- **Authoring skill.** A built-in `extension-authoring` skill extension, published by `brahma`, is mounted on lab and itemless turns. It holds the format reference, the trust rules (no hooks, `bin/` prefix, tool-name budget), the naming rule and examples.
- **Submitting.** `propose_extension {path, summary, roles, item?}` is high-risk, refused while tainted, and counts toward the ask quota. It runs:
  1. a snapshot at the lab commit;
  2. the full pipeline with the deterministic tier required. On failure it returns the lint JSON;
  3. a review item;
  4. an owner `extension` ask with the verdict and any tainted-provenance flags.
- **No draft mounts in v1.** An agent's draft is never mounted before approval. This closes the taint-laundering path (owner decision §10.3).
- **Requesting.** `request_access {kind: "extension", value: "<publisher>/<id>" | "…:<tool>", reason, item?}` resolves like this:
  - installed: a grant ask;
  - a built-in catalog row: an install ask with the requester and the blocked item attached;
  - unknown: the reply "No extension '<id>'. Build one in your lab and use propose_extension."
  - Requests are deduplicated company-wide.

---

## 6. Owner UX (within the five-noun budget)

### 6.1 Placement

- **Company › Settings › Extensions** is a single Installed list with a "Browse catalog" sheet. There is no new noun, no Requests tab and no Toolbox. "Built by your team" is a filter.
- **Inbox:** install, update, grant and connector-action asks are ordinary cards. A filter chip `kind: extension · grant` takes the place of a second queue.
- **Insights** (read-only): the connector call ledger, skill usage drawn from transcripts (Skill and Task invocations, 5L T13a), always-on tokens per role, and a digest line "unused for 30 active days".

### 6.2 Install or update card

```
┌ Install "Shopify" 1.0.0 · publisher: Brahma (bundled in app) · hash 9f2c…e41a ─────────┐
│ Requested by @lee (Support) for SUP-41 · reserved: connectors                           │
│ Parts: 1 skill · connector (stdio, Brahma-built, sandboxed) · runs: node                 │
│ Reaches: acme.myshopify.com (connector only) · Agents' network: no change                │
│ Credentials: Admin API token → Keychain (fd delivery) · scopes read_products … write_orders│
│ Data: customer PII only via order_customer_get                                          │
│ Tool                 Risk (author → yours)       Route        [Merch][Support][Analyst]  │
│ orders_list          read                        direct          [ ]    [x]     [x]      │
│ order_refund         spend·external·destr.       ask → spend $   [ ]    [x]     [ ]      │
│ …                                                                                        │
│ Context cost ~70 tok always-on/role · Tests 9/9 deterministic · Lint 0 warnings          │
│ Import notices: —        Code changed: —                                                 │
│ [Approve ticked]  [Approve read-only tools only]  [Decline]  [Something else]            │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Third-party cards**:
  - show the publisher as `third-party:<host>` and the pinned SHA;
  - show each skill description verbatim;
  - show the author's risk claims in a separate "author claims" column; any downgrade needs a tick and is recorded as owner-attested;
  - always show "output is untrusted";
  - for third-party stdio code: "third-party code holds this credential".
- **Update cards** add "What changed" and the highlighted **Code changed** block (§3.5).
- **Lab cards** add the author, the review verdict, the deterministic test log and any tainted-provenance commits.
- **Metered connectors** need a "provider cap set: $__/month" confirmation before Approve is enabled.

### 6.3 Installed row

Each row shows:
- version, SHA and source, and whether an update is available;
- a roles × tools toggle grid (toggling counts as the owner acting);
- credential status, with a rotate button and "rotate due";
- 7-day usage;
- Update, Rollback, Disable and Uninstall buttons.

---

## 7. Where it lands

### 7.1 Placement

| Step | Roadmap slot | Contents |
|---|---|---|
| **5L Task 5 rewrite: "Extension core"** (plus small T1a, T1b, T9, T10, T11 edits) | #4 (5L) | Validator and allowlists, store tables, `RoleBundle.effective`, `--plugin-dir` mounts, owner CLI with pending asks, the `allowed-tools` strip, taint from third-party skills. Plugin parts only |
| **Plan X-core** (5 tasks) | **#5½**: after L, before ML | **XC1** fetcher and importers (git@SHA, marketplace-entry reader, folder/zip, bare SKILL.md, import from my Claude Code, decomposition notices). **XC2** the `extension` ask (install, update, enable, dev-link), the Inbox card, the Company › Settings list, update diff with the code-changed block, rollback, uninstall. **XC3** SDK: `new skill`, `lint` (`--fix`, `--json`), deterministic `test`, `try`, `link`, `publish --to marketplace`. **XC4** `propose_extension`, lab-provenance taint, review item, `request_access` kind `extension`, `extension-authoring` skill. **XC5** skill-only built-in catalog rows (`brand-voice` sample, `extension-authoring`) and an end-to-end run: lab-built skill → propose → review → owner approves → mounted → used |
| **Plan X-connectors** (8 tasks) | **#10½**: after the dogfood week (#9) and Ops (#10), before M (#11) | **XN1** `brahma.json` connector schema, `ext.lock.json`, sandboxed snapshot probe, vendoring under SandboxedRunner. **XN2** gateway core: turn token plus launch nonce, narrow MCP surface, snapshot `tools/list`, drift refusal, stop observer. **XN3** upstreams: deny-default Seatbelt stdio launcher (env -i, HOME remap, fd or env credentials, proxy-only egress, DNS denied) and the HTTP client with header injection and OAuth refresh. **XN4** routing plus asks: risk, publisher trust table, engine-executes-once payload on `spend`, `outbox` and `other`, `amountArg` failing closed, redaction, synchronous taint. **XN5** compiler: `ext_<id>` entries, exact allow and deny, PostToolUse matcher, `agentNetwork`, profile gate, session freezing. **XN6** audit: `connectorCall` ledger, Insights views. **XN7** SDK: `new connector` (TS), `call`, `--snapshot`, `--record`, SDK cache. **XN8** catalog v1 connectors: `github` (remote, read-only toolsets first), `sentry`, `linear`, `stripe` (test mode, restricted agent key; `stripe_api_write` routed `ask` as a whole), `supabase` (`--read-only`, `--project-ref`), `shopify`. End-to-end: a Shopify refund goes to a `spend` ask and is then executed by the engine in replay |

Why this placement:
- L's goal→live-URL proof stays first.
- The owner's 18:30 decision ("ONE plugin install system + easy modular building; agents build own plugins for owner approval") is delivered before dogfooding, by 5L plus X-core.
- The dogfood week measures the core engine without adding a credentialed connector surface (owner rulings 17:49 and 18:16).
- X-connectors lands just before M, which needs connectors, and so fixes M's current dependency on Plan 11 (#17).
- Plan 11 keeps funds and the browser, and consumes X-connectors.

### 7.2 Patch notes per plan

**Plan 3a (building; Tasks 1–4 committed). Small string additions only.**
1. T11a: add `extension` to `AskKind.reserved`, with the title "Extension". Do **not** add `connectorAction`. Gateway asks reuse the already-reserved `spend` and `outbox`, plus `other` with a category.
2. T11a: `ReservedMatters.categories` already has `prompt-change`, `connectors`, `pricing`, `money` and `data-deletion`. No change needed. Do not add `refund-policy`.
3. T1: no schema change to the built fields now. Document that 5L decodes `RoleTemplate.skills` and `.connectors` into `extensions: [ExtensionRef]`, and that `validate()` will **warn** (never error) on unknown refs.
4. Document that `ItemTypeDef.checkTemplate` stays unconsumed until Plan G defines check providers.

**Plan 5-lite.**
1. **T1a:**
   - Rename `SandboxLayout.pluginLib` → `extLib` (`.brahma/ext`). Agent Bash may read it but never write it.
   - Add `<home>/extensions/{store,staging,state,sdk-cache}` to the data home. Agents can neither read nor write `store`, `staging` or `state`. `sdk-cache` is read-only to labs.
2. **T1b:**
   - The compiler takes `pluginDirs` from `ExtensionMounts`.
   - Drop `--disable-slash-commands` when any plugin part mounts.
   - Freeze the mount set per Claude session; a change forces a fresh session.
   - On Workspace and Full profiles, set `disableSkillShellExecution: true`.
   - Doctor:
     - re-fingerprint for **2.1.307**, which is installed now (5L pins 2.1.306);
     - fail if the managed setting `disableSideloadFlags` is set;
     - canary: init `plugins` equals the expected `<id>@inline` set plus nothing else, and `skills` equals the expected set;
     - canary: `--plugin-dir` changes across `--resume`.
3. **T5 rewrite: "Extension core: validator, store, plugin parts per role".**
   - Migration `v5-extensions` replaces `v5-plugins`. Tables: `extensionPackage(hash, id, version, publisher, sourceType, sourceUrl, sha, treeSha256, fetchedAt, lintFacts JSON)`, `companyExtension(companyId, id, hash, enabled, installedAskId)`, `extensionBinding(companyId, id, scope role|agent, target, op add|remove, tools JSON, writeRoute)`, `extensionEvent`.
   - `PluginLibrary` → `ExtensionLibrary`. Validation:
     - the author's 4-key `plugin.json` is required (bare SKILL.md folders get one generated);
     - the recursive frontmatter allowlist strips `allowed-tools` and `model` with a warning and refuses `hooks`, `mcpServers` and `lspServers`;
     - `bin/` names must be `<id>-` prefixed;
     - size, file-count and hidden-Unicode limits;
     - the full refused list from §1.1.
   - Mounts come from `RoleBundle.effective` (publisher-matched pack refs, then overrides, then grants), not from `companyPlugin.roles`.
   - Full rehash at mount.
   - CLI: `brahma ext add|list|bind|unbind|rm`, creating **pending** asks. No `brahma plugin` alias.
   - Tests to add: `skillFrontmatterAllowedToolsStripped`, `commandFrontmatterHooksRefused`, `nestedAgentFrontmatterChecked`, `skillFrontmatterModelStripped`, `rootClaudeMdRefused`, `manifestMcpServersInlineRefused`, `manifestHooksInlineRefused`, `workflowsDirRefused`, `outputStylesRefused`, `hiddenBidiInPluginJson`, `bareSkillWraps`, `binPrefixEnforced`, `packBundleMountsPublisherMatched`, `lookalikePublisherDoesNotBind`, `overrideRemovesPackBinding`, `cliInstallIsPendingAsk`, `tamperedTreeBlocksMount`.
4. **T9:**
   - `GrantKind.plugin` → `.extension`, with value `<publisher>/<id>` or `…:<tool>`. Tool grants become meaningful in X-connectors.
   - `validate`: the extension must be installed. In 5L a catalog id is refused with "not installed"; X-core routes it to an install ask.
   - The "system install" and "tool class" kinds are not built, pending owner decision §10.6.
5. **T10:**
   - Add the dynamic connector-tool classification rule (§4.5) as the documented extension point for `everyToolClassified`.
   - Add the `Skill` and `Task` matcher: invoking a third-party extension skill or agent taints the session.
   - Record taint per turn on lab commits.
6. **T11 (app):** the minimal Company › Settings › Extensions list, and the pending install ask as an Inbox card. The richer card comes in X-core XC2.
7. Lint and doctor must run `claude plugin validate`, `details` and `eval` only on allowlisted copies, under `SandboxedRunner` with `--setting-sources ""`, `--strict-mcp-config` and `disableAllHooks`. Canary: `details` on a plugin with hooks and MCP creates no marker file.

**Plan L.**
1. No change. `HostingAdapter` stays engine-internal. X-connectors may wrap it later as a built-in connector, or never.
2. Hand-off note only: L's last migration is the anchor for X-core's migration (`vX-core`).

**Plan 11 (Running the company).**
1. Plan 11 consumes X-connectors. Drop the Integrations page and the separate connector model; catalog rows are extension folders.
2. Plan 11 keeps funds (agent wallets and virtual cards as spend-risk connector tools), the browser (still an engine feature), owner spend policies (auto-approve thresholds that read the `spend` ask's `amountArg`), money-budget enforcement, and metered cost tracking via `metering`.
3. Credentialed CLIs (a `cli` transport) are decided here, if at all. If added, they need `--flag=<value>` or post-`--` binding, refusal of values starting with `-`, a HOME and XDG remap, and a deny-default profile that denies owner dotfiles.

**Plan 9 (Labs and memory v2).**
1. Remove `module.json`, `propose_module`, `toolbox/` and the Toolbox UI. Modules are draft extensions submitted with `propose_extension` (already shipped in X-core).
2. Usage stats and deprecation come from X-connectors XN6 and the Insights skill-usage view.
3. Procedural-memory promotion and the experience store output skill extensions through `propose_extension`.
4. Revisit author-only draft mounts here, only with commit-level taint provenance (§4.5) and never on review turns.

**Plan G (Generator).**
1. Named, versioned role toolkits and bundles are G's: lists of publisher-qualified `ExtensionRef`s plus company-tool groups, referenced from `RoleTemplate`.
2. `propose_role` may reference installed or built-in catalog extensions. A ref that is not installed attaches an install ask to the role ask. A G-generated pack that references connectors is a reserved `connectors` ask.
3. "Save company as pack" exports bindings as pack refs.
4. G owns check templates. A future extension `checks` part (format 2) must declare itself a check provider and always run under the hardened Seatbelt check runner on every profile, never unsandboxed on Full.

**Other plans, for reference.**
- **ML (lean):** only the rule that connector-derived content keeps untrusted provenance, and that `customer-pii` is never ingested by default. No `knowledge` part.
- **M:** social and posting providers are connector extensions whose external tools route to `outbox`. Brand voice is a skill extension.
- **7:** outbound providers are connector extensions behind the company verbs, on the same `outbox` kind.
- **8:** bubblewrap or `srt` as the gateway sandbox backend. Refs of the form `publisher/id@version#hash` are portable.
- **10 Steward:** may propose extension updates and removals as `extension` asks.
- **4a:** no change.

**Spec v2 edits.**
- §1.3: Extensions is a Company setting.
- §4.3.3: add the per-role extension line.
- §4.3.5: drop `--disable-slash-commands` once plugin parts mount.
- §4.4: add `propose_extension` and `request_access` kind `extension`.
- §4.7.1: add the `extension` ask kind; gateway asks reuse `spend`, `outbox` and `other`.
- §4.7.5: the grant kinds become network domain, web domain, read path and extension.
- §4.8.2: plugin text becomes extension parts, and connectors go through the gateway.
- §4.10.1: catalog rows are extensions; drop the Integrations page.
- §4.16: modules become draft extensions; retire the Toolbox.
- §5: point at the roadmap table and insert X-core (#5½) and X-connectors (#10½).
- Appendix B: cite this document and correct the design-review attribution.

---

## 8. Verified, from docs, and still to probe

**Verified live on 2.1.307:**
- `--setting-sources ""` isolates the owner's plugins and skills.
- `--plugin-dir` loads skills, agents and `bin/` in `-p` mode as `<id>@inline`.
- `--strict-mcp-config` drops plugin MCP servers.
- Plugin `hooks.json` hooks and skill-frontmatter hooks run **outside** the sandbox, and `disableAllHooks` stops both.
- `!` injection and `bin/` run inside the sandbox.
- An isolated `CLAUDE_CONFIG_DIR` leaves `~/.claude` untouched.
- Stdio MCP servers run unsandboxed and inherit the full environment; an `env -i … sandbox-exec` wrapper confines them.
- `permissions.deny` hides MCP tools; a missing allow rule means deny under `-p`; a server-level allow grants every tool on the server.
- `headersHelper` injects auth headers for remote servers.
- `claude plugin init` has no output-folder option.

**From docs only:**
- the pre-approval semantics of `allowed-tools`;
- that plugin skills are immune to `skillOverrides`;
- the 1,536-character listing cap;
- Node dependency auto-install on cache copy;
- auto-update only in interactive sessions.

**Canaries and probes to add** (5L doctor or X tasks):
1. Whether a pre-approved `allowed-tools` overrides `--permission-prompts none`. It is stripped regardless; the probe confirms the gap.
2. Whether `disableAllHooks` also disables Brahma's own PostToolUse hook from `--settings`. Brahma does not rely on it.
3. Whether project `.claude/skills` in the cwd or lab loads under `--setting-sources ""` (5L T1b Step 1(c)).
4. Whether `bin/` is still on PATH under `--restricted --tools` with the 5L shell prefix.
5. A gateway launched from sandboxed Bash, or with a reused nonce or a wrong parent PID, refuses to start. A Keychain read from sandboxed Bash fails.
6. The `ext_<id>` server name yields exactly `mcp__ext_<id>__<tool>`, and the 64-character budget holds at maximum lengths.
7. A snapshot-served `tools/list` with a lazy upstream behaves normally in Claude Code.
8. `claude plugin validate --strict` and `details` accept a plugin root that contains `brahma.json`, `connector/` and `tests/`, at most with warnings.
9. `claude plugin details` and `eval` on a plugin with hooks and MCP start neither (marker-file check).
10. `--plugin-dir` changes across `--resume`, to confirm that freezing mounts per session is required.
11. The deny-default upstream Seatbelt profile still lets Node start, and DNS works only through the proxy.

---

## 9. Residual risks (accepted, documented)

- A third-party skill's description sits in the listing of every turn for roles that mount it. Mitigations: scanning, a verbatim card, a reserved prompt-change approval, and invocation taint.
- A third-party stdio connector can use the vendor API itself to exfiltrate the data it holds. Mitigations: prefer remote vendor servers, label "third-party code holds this credential", and minimise provider scopes.
- On Workspace and Full profiles a process running as the same user can tamper with materialized files between hash and load. Mitigation: only Brahma and company-reviewed parts are mounted there.
- Lint scans for injection are heuristic. The controls that matter are structural.

---

## 10. Owner decisions needed

1. **"Extensions" as a Company setting** (one installable unit with plugin parts plus an optional connector), instead of a two-noun "Skill + Connector" model. Neither has been signed off.
2. **Placement:** 5L T5 rewrite, then X-core at #5½ (after L, before ML), then X-connectors at #10½ (after dogfood and Ops, before M). Recommended.
3. **Agent drafts:** no pre-approval mounts of agent drafts in v1. Recommended "no"; revisit in Plan 9.
4. **Default route for connector `write` tools:** honour the manifest route for `brahma` and company-reviewed publishers, and use `ask` for third-party unless the owner flips it per role on the card. Recommended.
5. **Third-party plugin parts on Workspace and Full profiles:** refuse to mount (recommended), or mount with a warning.
6. **Drop the "tool class" and "system install" grant kinds** from spec §4.7.5. System install becomes a doctor-raised `humanTask` through `requires.hostTools`; tool class becomes connector tool grants. Recommended.

---

## 11. Changes from the draft (review disposition)

**Security review: every high-severity issue fixed.**
- Author-written policy is distrusted for non-Brahma publishers (§2.3).
- Publisher, source and integrity are installer-derived and DB-only (§2.2).
- Workspace and Full profiles get the profile gate, launch nonce plus parent-PID binding, fd credential delivery and `disableSkillShellExecution` (§4.2, §4.4).
- Draft mounts are removed and commits carry taint provenance (§4.5, §5.4).
- Invoking a third-party skill is a taint source, Unicode scanning covers every string, and tool descriptions are capped.
- All fetching and vendoring is sandboxed with install scripts off. `oci`, `npm`, `command` and `dependencies` are refused, and `claude plugin install` is not used, which also closes the TOCTOU gap.

**Security review: mediums and lows fixed.**
- Publisher-qualified refs.
- A narrowed gateway MCP surface.
- Args-first approval cards with `amountArg` failing closed.
- A code-changed block and a revocation list.
- A full rehash at mount.
- CLI installs as pending asks.
- `claude` lint commands only on allowlisted copies.
- The `cli` transport deferred, with its rules written down.
- DNS denied in upstream profiles.
- `GitCommand` snapshots, recursive frontmatter checks and the `bin/` prefix.
- Fixture recording without headers.

**Developer-experience review.**
- The source tree is a valid plugin, with the optional `brahma.json`.
- Capabilities are inferred by lint.
- Tools are declared once, via `ext.lock.json`.
- `declarative-http`, `argRules`, `preflight` and `redactFields` are removed.
- Format 1 is cut to plugin parts plus connector.
- Hashes are out of the authored tree.
- Distribution uses the marketplace format, with no `.bext`.
- Added `try`, `call`, `link` and the deterministic tier.
- Agents get an SDK cache, an authoring skill and `lint --json`.
- Embedded templates replace `claude plugin init`.
- The name-length arithmetic is fixed.
- Frontmatter handling is uniform.
- v1 ships TS-only templates and one naming rule.

**Architecture review.**
- The work is split into a 5L core, X-core (#5½) and X-connectors (#10½).
- MVP scope is cut: two transports, no DSL, no signing beyond the app bundle, per-company installs only, manual updates, one previous version kept.
- `roleFragments`, `knowledge` and `checks` are deferred.
- Only the `extension` ask kind is added.
- UI lives under Company › Settings with no Requests tab.
- Mounts are frozen per session.
- Company creation does not bulk-approve connectors.
- Pack-upgrade grids are added.
- The grant-kind decision is added to §10.
- Bundles go to G, and L is left untouched.
- Shopify uses the `money` category and `metering: none`.
- The spec §5 edit points at the roadmap, the alias is dropped, and the review-turn setting is dropped.
