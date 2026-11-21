---
title: The sandbox
description: "What a Sandboxed turn cannot do: the files, hosts and helper programs it is denied. How engine-run checks are confined, the network allowlist, and the git settings the engine forces off."
sidebar:
  order: 4
---

## What it is

On the `sandboxed` profile, each agent turn runs inside a macOS Seatbelt policy that Brahma compiles for that turn. The policy names the places the turn may write, the places it may read, and the hosts it may reach. Everything else is denied by the operating system, not by a rule the agent could talk its way around.

Engine-run checks, previews and the canary run under a second policy, Brahma's own, with its own limits and its own egress proxy.

## How it works

**What a Sandboxed turn cannot do.** It cannot:

- read your home folder, apart from the toolchain's read-only places and paths you grant;
- read Brahma's data home (the database, MCP configs, owner key, backups);
- read credentials and private app data, even under a granted path: `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.gnupg`, `~/.netrc`, `~/.docker`, `~/.kube`, `~/.claude`, `~/.gitconfig`, shell histories, the Keychains, cookies, Mail, Messages, Safari, browser and other app profiles;
- read or write other companies' workspaces;
- read `/Volumes`;
- read or delete your backup targets and the WAL replica folder;
- write outside its own places in the workspace: the item turn's worktree, or the agent's lab, plus its home (with its own cache inside) and its notes file. `.brahma/cache` and the other engine-owned parts of `.brahma`, and git's config, hooks, `info/` and `main` ref, are write-denied;
- reach hosts outside its allowlist. Bash's network is limited by the `claude` CLI's own sandbox network allowlist (`sandbox.network.allowedDomains`), set from the company's Bash list plus the agent's granted domains. WebFetch has its own list. The model provider's own domains are never on the Bash list. Listening on loopback is off unless you turn it on;
- use helper programs that act outside the sandbox: the Keychain, the pasteboard, screen capture, `open` (LaunchServices), `osascript` (Apple events), accessibility, privacy (TCC) services, preference writes (cfprefsd) and disk mounting (DiskArbitration and `mount_*`).

**The network allowlist.** The default Bash list is the package registries: npm, Yarn, PyPI, crates.io, Go, RubyGems, Maven and GitHub. WebFetch also gets a few documentation sites (Apple, Swift, MDN, Node, Python, docs.rs, pkg.go.dev). You change the lists per company:

```text
brahma network <company>                          the effective lists (defaults marked)
brahma network <company> add|rm <domain> [--web]  a Bash egress domain (--web: a WebFetch domain)
brahma network <company> local on|off             whether agents may listen on loopback
brahma network <company> toolchain add|rm <path>  an extra read-only toolchain path
```

An agent that needs more asks with `request_access`; you decide, and a grant takes effect from the agent's next turn. See [Taint and vouch](/docs/safety/taint-and-vouch/).

**Engine-run checks.** A check runs under Brahma's own Seatbelt policy, not a turn's. It writes only its own checkout under the data home. It reads the company's workspace except the private parts of `.brahma` (agents' homes, labs and notes, extension review pages, `ext try` copies, trash and plans), and it cannot read the `claude` CLI's temp folders. Its network goes only through Brahma's egress proxy: HTTPS (port `443`) to the company's Bash allowlist (grants are not included), and only at public addresses; loopback, private ranges and cloud metadata are refused. The egress proxy is used only by commands Brahma itself runs under Seatbelt: checks, and the owner-side runner the doctor, the sandbox canary and the `ext` commands use. Agent turns do not go through it.

**Engine git.** Every git command the engine runs forces off what a repository could make git run: hooks, fsmonitor, gpg, credential helpers, askpass, ssh, editors, submodule recursion and external diff. It reads attributes from the empty tree, ignores replace refs and grafts, and refuses, with one owner alert, a workspace whose git config holds anything beyond a short allowlist. When the engine commits an agent's work it leaves out, and reports, any symbolic link whose target has a `..` part or points outside the checkout.

**Before a sandboxed turn starts,** its `claude` build, turn shape and your canary probe file must have passed the sandbox canary. Until then the agent waits and you get a sandbox-check alert. See [The sandbox canary](/docs/safety/canary/).

## From the CLI

- [`brahma network`](/docs/cli/network/)
- [`brahma access`](/docs/cli/access/), [`brahma access approve`](/docs/cli/access/approve/), [`brahma grants`](/docs/cli/grants/)
- [`brahma doctor`](/docs/cli/doctor/) (`sandbox-backend`, `sandbox-canary-local`, `sandbox-canary`, `sandbox-helpers`)
- [`brahma canary run`](/docs/cli/canary/run/)
- [`brahma company profile`](/docs/cli/company/profile/)

## What it does not do

- **It only applies to the Sandboxed profile.** Workspace and Full turns are not sandboxed. See [Profiles](/docs/safety/profiles/).
- **It is as tested as your canary probes.** The canary checks only what your probe lines ask. Until you write them and they pass, sandboxed companies stay blocked.
- **Agent turns can write files in your user temp folder,** because `xcrun` needs its cache file there.
- **The command classifier is advisory.** Deciding which shell commands reach the network, for the taint rule, is a classifier that errs towards tainting. It is not the wall. On Sandboxed the network allowlist is the wall: a command the classifier misses still reaches only the allowlisted hosts.
- **Other Seatbelt mount routes** beyond the known DiskArbitration and `mount_*` routes (both denied and tested) have not been exhaustively reviewed.
- **Checks cannot attach or mount disk images,** and cannot read your SwiftPM cache, so a check that has to resolve packages through it fails.
- **Extensions run inside the agent's sandbox,** not a stricter one. Brahma refuses hooks, MCP servers, LSP servers, monitors, plugin settings and install scripts in any extension.
- **The `claude` CLI keeps its own unredacted transcript** of each session under `~/.claude/projects`. Brahma's captured copy is redacted; that one is not.
- **The git pre-commit hook is advisory.** The engine's submit- and merge-time scans are the real check.
- **Live tests have not been run.**

## Related

- [Profiles](/docs/safety/profiles/)
- [The sandbox canary](/docs/safety/canary/)
- [Taint and vouch](/docs/safety/taint-and-vouch/)
- [Work items](/docs/concepts/work-items/) (how checks are run)
