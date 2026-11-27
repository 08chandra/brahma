# Release engineering — signed and notarized DMG, Homebrew cask, auto-update, opt-in crash reports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution:** subagent-driven, on a branch cut from `main` **after Plan R (the engine service, `BuildInfo`, `ServiceInstaller`) is merged and `main` is green**; independent of the X plans and can run beside them. Model policy (owner, 2026-11-21): Fable for implementers and routine reviews; **Opus (high)** for the signing, update-verification and service-installer tasks (T2, T5, T7) and the final review. Never Sonnet or Haiku.
>
> **Owner steps.** Signing and notarization need the owner's Developer ID certificate, an App Store Connect API key or Apple-ID app password stored in a `notarytool` keychain profile, an EdDSA update-signing key and a GitHub tap repository. **This plan scripts every step but never handles a credential:** the scripts take only names (a signing identity's common name, a keychain profile name, a key's Keychain label) and the owner runs the three commands that need them. No credential, key or password appears in the repository, in a test, in an environment file or in a commit.

**Goal:** A `scripts/release/` pipeline that produces a Developer-ID-signed, hardened-runtime, notarized and stapled `Brahma-<version>.dmg` with the app, the `brahma` CLI and the helpers; a Homebrew cask that installs it; signed auto-update through an appcast where every update drains the engine first and installs only on the owner's approval; opt-in, redacted, owner-sent crash reports; and a release checklist the owner follows, with a dry run tests can execute.

**Architecture:**
- **Build and bundle:** `scripts/make-app.sh` keeps building the bundle; it gains a `VERSION` file as the single source of the version, a `CFBundleVersion` derived from the commit count, and a templated `Info.plist`. Every signing decision moves into `scripts/release/sign.sh`, which signs inside-out (helpers, then the app) with a hardened runtime and per-binary entitlements. With no identity it signs ad hoc, exactly as today, so dev builds are unchanged.
- **Distribution:** `dmg.sh` makes the disk image; `notarize.sh` (owner) submits with `xcrun notarytool` using a keychain profile *name* and staples the DMG; **after** stapling, `checksums.sh` writes `SHASUMS256.txt` and `cask.sh` renders `Casks/brahma.rb` from the stapled DMG's sha256 for the owner's tap; `appcast.sh` (owner) runs Sparkle's `generate_appcast` against the stapled DMG with the owner's Keychain-resident EdDSA key; `release.sh` orchestrates and `dry-run.sh` runs the whole pipeline ad hoc with notarization and signing-key steps skipped, so a process-tier test proves the pipeline shape. **Every run of a script with a real signing identity or the update key is an OWNER step**, because a same-user process (a Workspace or Full agent) could otherwise use a Keychain item the owner had marked "Always Allow".
- **Update:** Sparkle 2 (SwiftPM, MIT) in `BrahmaApp`, embedded as `Contents/Frameworks/Sparkle.framework` and re-signed with the owner's identity, with the EdDSA **public** key in `Info.plist`, automatic checks daily, **no automatic install**: the owner approves each update. **Order, matching Plan R:** before Sparkle installs, the app asks the service to hold new admissions and waits until no turn is running; Sparkle then replaces the bundle and relaunches the app; the new app's `welcome` sees a different build and calls R's `restartForUpgrade`, so launchd restarts the service **from the new bundle**. If the hold does not drain in 60 s, the hold is released and the update is postponed with the reason. **(controller's call: Sparkle over a custom verifier — see "Decision for the owner" below.)**
- **Crash reports:** no telemetry (spec §4). The app, only when the owner opts in, scans macOS's own diagnostic reports for Brahma's processes, redacts them, shows them, and lets the owner copy or open a prefilled GitHub issue. Nothing is ever uploaded by Brahma.
- **Service:** a Developer-ID-signed bundle in `/Applications` with the default data home lets the installer use `SMAppService` (R left the seam; spec follow-up F-X7), migrating from R's LaunchAgent of the same label; ad-hoc builds and non-default homes keep the LaunchAgent. Gatekeeper translocation is detected and refused before installing the service.

**Tech Stack:** Swift 6.2 toolchain (`swift-tools-version: 6.0`, `.macOS(.v14)`), SwiftPM, Swift Testing; `codesign`, `xcrun notarytool`, `xcrun stapler`, `hdiutil`, `spctl`; Sparkle 2.x (`https://github.com/sparkle-project/Sparkle`, pinned to a 2.x tag); Homebrew cask DSL (Ruby); `SMAppService` (ServiceManagement); bash with `shellcheck` where installed.

**Spec:** `docs/superpowers/specs/2026-11-21-any-product-and-hedges-design.md` (*spec §n*): §2 (positioning copy in the About box; never the Claude name or logo beyond "runs Claude Code"), §4 (no Brahma cloud, **no telemetry sent home**), §5 (no silent fallback; no credential where an agent can reach it), §6 (macOS 14+), standing constraints (the owner never pastes tokens in chat; Apache-2.0), §10 (the new row 13 this plan adds), "Follow-ups" **F-X7** (a signed, notarized build so the service uses `SMAppService`). Also `2026-11-17-website-docs-design.md` §"Installer dependency" (the site's Installer tab waits for a notarized release with a download link and checksum) and `2026-11-21-restructure-service-design.md` (`ServiceInstaller`, `restartForUpgrade`, upgrade drain; `SMAppService` left as a seam).

**Builds on (merged first), with the names this plan consumes:**
- **R:** `BuildInfo` (written by `make-app.sh` from `git describe`), `ServiceInstaller { install, uninstall, status, ensureCurrent }` (a struct in R's plan; Task 0 records whether a protocol already fronts it), `Launchctl` protocol, `InstallerStatus`, `LaunchAgentPlist`, the IPC client (R's `BrahmaEngineClient` type; called `EngineClient` here) with `status`, `shutdown{drain}`, `restartForUpgrade` (owner-proof HMAC) and the `welcome` build check, `EngineStatusReport`, `ServiceGuardTests` (bans `launchctl`/`SMAppService` strings outside `BrahmaService/Install/`), `brahma engine …`, the unmanaged-child fallback when launchd is unavailable (labelled in Settings › Engine).
- **S:** `Spawn`/`ToolPaths` (for `codesign` facts read at runtime), `EngineFiles`/`Place`, `SafeRead`, the redactor (`CanaryLeakMatcher`, `SecretScan`), `SafetyLintTests`.
- **P:** test tiers, `CLITreeFrozenTests`/`cli-tree.tsv`, `ScreenInventoryTests`, `ThemeLintTests`, shared components.
- Existing: `scripts/make-app.sh`, `scripts/smoke-app.sh`, `KeychainVault.trustedApplicationPaths` (Keychain ACLs pinned to the running binary and its sibling), `Doctor`, `site/` (Astro; `src/pages/start.astro` `installer` slot, `InstallTabs`), `README.md`, `THIRD_PARTY_NOTICES.md`.

Where merged code differs, **Task 0 records the drift and every later task uses Task 0's names.**

## Global Constraints

From S, R and P, still binding:
- Prefix every `swift`, `xcrun` and `codesign` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Swift 6, SwiftPM, Swift Testing; one `@Suite struct <FileName>` per test file. Core targets stay Linux-portable; Sparkle, ServiceManagement and CryptoKit are imported only in `BrahmaApp`, `BrahmaAppModel` and `BrahmaService/Install/`.
- Child processes only through S's `Spawn` with `ToolPaths`; files only through `EngineFiles`/`Place`. `SafetyLintTests` gains no baseline entry. `try?`, `?? true/false` and empty `catch {}` banned in `Sources/BrahmaAppModel/Update/`, `Sources/BrahmaAppModel/Diagnostics/`, `Sources/BrahmaService/Install/`.
- **Scripts never take a credential.** `scripts/release/*.sh` accept identity *names*, keychain profile *names* and a Keychain *account* name only, through `BRAHMA_SIGN_IDENTITY`, `BRAHMA_NOTARY_PROFILE` and `BRAHMA_SPARKLE_ACCOUNT` (Sparkle's `generate_appcast --account`; its tools read the Keychain themselves). A script that is passed something shaped like a key or a password refuses (`release-guard.sh`: `-----BEGIN`, `AuthKey_*.p8`, `.p12`, `--password`, `-p <value>`, `--ed-key-file`, `-s <key>`; no entropy heuristics, so paths and sha256 values pass). `ReleaseGuardTests` scan the repository for the same shapes plus `SUPrivateKey` and fail on any hit; the only allowlisted directory is `Tests/BrahmaAppModelTests/Fixtures/appcast/`, which holds a **public** key and signatures only.
- **Owner steps are owner-run.** `release.sh` with a real identity, `notarize.sh` and `appcast.sh` are run by the owner in an owner shell. `docs/release/OWNER-SETUP.md` tells the owner to answer Keychain prompts with **Allow, never Always Allow**, to run `notarytool store-credentials` interactively (no `--password` on a command line), and to keep the Sparkle key in the login Keychain with its default ACL.
- **Exact commands.** Each task's focused run is `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter '<Suite>'` for every suite the task names; expected output ends `Test run with N tests passed after …` with no failures; then `scripts/test.sh unit` (and `process` where the task says so); scripts are checked with `shellcheck scripts/release/*.sh` where installed.
- **The repository stays Apache-2.0 clean:** Sparkle's MIT notice is appended to `THIRD_PARTY_NOTICES.md`; nothing is bundled whose licence is not already listed there.
- **No telemetry.** Brahma opens no network connection for crash reporting, ever. The only outbound connections this plan adds are Sparkle's appcast and DMG downloads to the owner's configured feed host over HTTPS, and they happen only when the owner has not disabled updates.
- **Owner approves every install.** Updates download only after the owner clicks; they install only after the owner clicks; the engine holds admissions and drains first; a drain that does not complete in 60 s releases the hold and postpones the update with the reason. `BRAHMA_NO_UPDATES=1` and the Settings toggle disable checks entirely; a build with no `SUFeedURL` never starts the updater.
- **Existing CLI commands unchanged.** `brahma --version` already exists via `BuildInfo` (R); this plan adds only `brahma doctor` items. No new command. (`brahma engine …` keeps its surface; the installer swap is internal.) The only IPC addition is the `holdForUpgrade`/`releaseHold` pair if Task 0 finds R has no equivalent, under R's owner-proof HMAC.
- **The app keeps its ops-console layout.** The Diagnostics and Updates panels use P's components; `ScreenInventoryTests` baseline changes by additions only, in a commit tagged `approved release-engineering plan`.
- **Tests never touch** the real Keychain, launchd, `SMAppService`, the network, Apple's notary service or the owner's certificates. Scripts under test run ad hoc (`BRAHMA_SIGN_IDENTITY=-`) with `--no-notarize --no-appcast`. Sparkle's updater is never started in tests (`UpdateController` takes a `UpdaterDriving` protocol; `FakeUpdater` in tests).
- Every task ends with `swift build` green for all targets and `scripts/test.sh unit` green; tasks touching scripts also run `scripts/test.sh process` and `shellcheck` on changed scripts where installed.
- Commit messages end with `Co-Authored-By: Claude <your actual model name> <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01EwQXUbQgFTPnqvkUUwLRgW`.

**Pinned values** (each in the named file or type):

| Constant | Value | Owner |
|---|---|---|
| Version source | `VERSION` at the repo root, semver `MAJOR.MINOR.PATCH` (first release `0.3.0`, owner may change); `CFBundleShortVersionString = VERSION`; `CFBundleVersion = MAJOR×1 000 000 + MINOR×1 000 + PATCH` (monotonic with semver, so Sparkle's comparison agrees with ours); `BuildInfo.version = "<VERSION> (<short sha>[-dirty])"` for display only | `scripts/release/version.sh` |
| Bundle ids | app `dev.brahma.app`; helpers `dev.brahma.cli`, `dev.brahma.pdf`, `dev.brahma.helper`, `dev.brahma.vmhost` (when present) | `scripts/release/sign.sh` |
| Signing | `codesign --force --timestamp --options runtime --sign "$BRAHMA_SIGN_IDENTITY"`, inside-out: `Sparkle.framework`'s XPC services, `Autoupdate` and `Updater.app`, then the framework, then each helper, then the app; ad hoc (`-`) when unset, without `--timestamp` | `sign.sh` |
| Entitlements | app: none beyond hardened-runtime defaults (`com.apple.security.cs.allow-jit` **off**, `com.apple.security.cs.disable-library-validation` **off** — the embedded Sparkle is re-signed with the same identity, so library validation holds); `brahma-vmhost`: `com.apple.security.virtualization`; the App Sandbox entitlement is **not** set (Brahma spawns `claude` and the helpers) | `Resources/entitlements/*.entitlements` |
| Architecture | `arm64` only in v1 (the Linux micro-VM needs Apple silicon anyway; a universal build is one owner decision away) **(controller's call)** | `make-app.sh`, cask `depends_on arch: :arm64` |
| DMG | `Brahma-<VERSION>.dmg`, `hdiutil create -format ULFO -fs APFS -volname "Brahma <VERSION>"` with `Brahma.app` and an `Applications` symlink; signed with the same identity; no checksum yet (stapling changes the bytes) | `dmg.sh` |
| Notarization | `xcrun notarytool submit <dmg> --keychain-profile "$BRAHMA_NOTARY_PROFILE" --wait --timeout 30m`, then `xcrun stapler staple <dmg>` (the DMG only; the app inside a read-only image cannot be stapled, and Gatekeeper accepts a stapled DMG); verify `spctl --assess --type open --context context:primary-signature -v <dmg>` | `notarize.sh` (owner) |
| Checksums | after stapling: `SHASUMS256.txt` beside the DMG (`shasum -a 256`); the cask and the appcast use this value | `checksums.sh` |
| Cask | tap `08chandra/homebrew-brahma`, file `Casks/brahma.rb`: `version`, `sha256`, `url "https://github.com/08chandra/brahma/releases/download/v#{version}/Brahma-#{version}.dmg"`, `auto_updates true`, `depends_on macos: ">= :sonoma"`, `depends_on arch: :arm64`, `app "Brahma.app"`, `binary "#{appdir}/Brahma.app/Contents/Helpers/brahma"`, `uninstall quit: "dev.brahma.app", launchctl: "dev.brahma.engine"`, `zap trash: ["~/Library/Application Support/Brahma", "~/Library/LaunchAgents/dev.brahma.engine*.plist"]`, `livecheck` on GitHub releases | `cask.sh` |
| Appcast | `appcast.xml` on the release host (default: GitHub Releases asset + GitHub Pages `https://08chandra.github.io/brahma/appcast.xml`; needs the repository public — owner decision); `SUFeedURL` and `SUPublicEDKey` in `Info.plist` (the public key from the committed `Resources/sparkle-public-key.txt`; the feed URL empty for ad-hoc builds, which never start the updater); `SUEnableAutomaticChecks true`, `SUScheduledCheckInterval 86400`, `SUAutomaticallyUpdate false`, `SUAllowsAutomaticUpdates false` | `appcast.sh`, `Info.plist.in` |
| Hold before install | `EngineClient.holdForUpgrade()` (R's `shutdown{drain}`-shaped RPC if it exists, else a new `holdForUpgrade`/`releaseHold` pair under the same owner-proof HMAC as `restartForUpgrade`; Task 0 decides) then poll `status` until `runningTurns == 0`, deadline 60 s; on timeout `releaseHold()` and `engine still draining (<n> turns running)`; after relaunch R's `welcome` build check and `restartForUpgrade` run unchanged | `UpdateController.drainDeadline` |
| Crash reports | source `~/Library/Logs/DiagnosticReports/*.ips` whose `app_name`/`procName` ∈ {`Brahma`, `brahma`, `brahma-helper`, `brahma-pdf`, `brahma-vmhost`}; opt-in default **off**; redaction: the home path → `~`, the user name → `<user>`, the redactor's known values, `SecretScan` patterns, `BRAHMA_HOME` paths; shown text ≤ 64 KiB; issue URL body ≤ 6 KiB; issue URL `https://github.com/08chandra/brahma/issues/new?title=…&body=…` | `CrashReports` |
| Translocation | `Bundle.main.bundleURL.path` containing `/AppTranslocation/` or starting with `/Volumes/` → the service install is refused with `Move Brahma to /Applications first` and a Reveal in Finder button | `Translocation.isTranslocated`, `ServiceInstaller.preflight` |
| Release checklist | `docs/release/CHECKLIST.md`, one line per step marked `script` or `OWNER` | T8 |

## Review Focus

1. **A downgrade or a substituted feed:** an attacker (or a mistake) serves an appcast whose newest item is older than the running build, or an item signed by a different key. Expected: the app verifies the item's EdDSA signature itself (CryptoKit) before Sparkle's own check and refuses any version ≤ the running `CFBundleShortVersionString` even when the feed says otherwise; the owner sees `update refused: version <v> is not newer` or `update refused: bad signature`. → T5 `UpdateControllerTests.olderOrEqualVersionRefused`, `AppcastFixtureTests.wrongKeyRefused`, `goodFixtureVerifies`.
2. **An update replaces the bundle while turns run, or restarts the service on the old binary,** or the drain never finishes and the update sits forever. Expected: the app holds admissions and waits for `runningTurns == 0` before Sparkle installs; the service restarts only after the relaunched app's `welcome` sees the new build (R's flow); after 60 s the hold is released and the update is postponed with the reason. → T5 `UpdateControllerTests.holdsAndDrainsBeforeInstall`, `drainTimeoutReleasesHoldAndPostpones`, `serviceRestartHappensAfterRelaunch`.
3. **A signed build cannot read secrets an ad-hoc build stored** (the Keychain ACL pins the old code identity), so the engine starts and every secret-needing feature refuses. Expected: `brahma doctor` names it (`secrets-trust: items were stored by a differently signed Brahma; re-enter them in Settings › Secrets`) by comparing the item's trusted-application requirement with the running binary's, not by guessing from an error code; a Developer-ID build's designated requirement is stable across versions so this happens once. → T2 `SigningLayoutTests.cliTrustsItselfAndTheAppOnly` (R's rule: `Helpers/brahma` trusts itself and `MacOS/Brahma`, nothing outside the bundle, in the signed layout), T2 `DoctorSignatureTests.secretsTrustComparesRequirements`, and the checklist step "re-enter secrets once after the first signed build".
4. **Gatekeeper translocation:** the owner runs `Brahma.app` from the DMG or `~/Downloads`; `ServiceInstaller` writes a LaunchAgent pointing at `/private/var/folders/…/AppTranslocation/…` or `/Volumes/…`, which is gone at next login. Expected: the install is refused with the move-to-Applications message and a Reveal in Finder button. → T7 `TranslocationTests.detectsAndRefusesInstall`, `volumesPathRefused`.
5. **A crash report leaks:** an `.ips` carries the owner's user name, `BRAHMA_HOME`, environment names, and for `brahma mcp` crashes possibly agent-controlled argv text. Expected: redaction of home, user, known secret values and secret-shaped strings; the body is capped; nothing is sent by Brahma; the owner reads it first. → T6 `CrashReportsTests.redactsHomeUserAndSecrets`, `issueURLBounded`.

---

## File Structure

```
VERSION                                              single source of the version
scripts/release/{version.sh,sign.sh,dmg.sh,notarize.sh,checksums.sh,cask.sh,appcast.sh,release.sh,dry-run.sh,release-guard.sh}
scripts/make-app.sh                                   uses version.sh and sign.sh; Info.plist from the template; embeds Sparkle.framework
Resources/Info.plist.in                               template (version, build, SUFeedURL, SUPublicEDKey placeholders)
Resources/sparkle-public-key.txt                      the EdDSA PUBLIC key (committed; pasted once by the owner)
Resources/entitlements/{Brahma,brahma-vmhost}.entitlements
Casks/brahma.rb                                       rendered output committed for review; the owner copies it to the tap
Sources/BrahmaModel/Release/BuildSignature.swift     value: developerID(team) | adHoc | unsigned
Sources/BrahmaService/Install/BuildSignature+Current.swift   reads the running bundle's signature (Security.framework)
Sources/BrahmaAppModel/Update/{UpdateController,UpdateSettings,UpdaterDriving,AppcastSignature}.swift
Sources/BrahmaApp/Update/{SparkleDriver,UpdatesMenu}.swift
Sources/BrahmaAppModel/Diagnostics/{CrashReports,CrashRedactor}.swift; Sources/BrahmaApp/Views/{DiagnosticsPanel,UpdatesPanel}.swift
Sources/BrahmaService/Install/{ServiceInstalling,SMAppServiceInstaller,Translocation}.swift
Sources/BrahmaEngine/Engine/Doctor.swift              items build-signature, secrets-trust, updates, crash-reports
Tests/BrahmaReleaseTests/{ReleaseGuardTests,VersionScriptTests,SigningLayoutTests,DMGScriptTests,CaskRenderTests,DryRunTests}.swift
Tests/BrahmaAppModelTests/{UpdateControllerTests,AppcastFixtureTests,CrashReportsTests}.swift; Fixtures/{appcast/*,ips/*}
Tests/BrahmaServiceTests/{SMAppServiceInstallerTests,TranslocationTests}.swift
docs/release/CHECKLIST.md; docs/release/OWNER-SETUP.md
```

---

### Task 0: Inventory — the bundle today, R's installer and build info, the Keychain trust rule, the site's installer slot

**Files:**
- Create: `.superpowers/sdd/release/inventory.md`

**Interfaces:**
- Produces, in the inventory: (a) every "Builds on" name, "as named" or "renamed to"; (b) the merged `scripts/make-app.sh` (what it copies, signs and writes to `BuildInfo`), the helper binaries bundled (`brahma`, `brahma-pdf`, `brahma-helper`, and `brahma-vmhost` if X4 landed), and whether `ServiceInstaller` is a struct (R's plan) — then T7 extracts the `ServiceInstalling` protocol; (c) `KeychainVault.trustedApplicationPaths` and the exact ACL rule (`Helpers/brahma` trusts itself and `MacOS/Brahma`; the app trusts itself and `Helpers/brahma`) so T2 asserts the signed layout keeps it, and the Security API that reads an item's trusted-application requirement for the `secrets-trust` doctor line; (d) the site's `installer` slot and `InstallTabs` contract (link, checksum, `initial`); (e) R's IPC as merged: whether `shutdown{drain}` can hold admissions without exiting, or whether a `holdForUpgrade`/`releaseHold` pair must be added (under `restartForUpgrade`'s owner-proof HMAC), and how the `welcome` build check triggers `restartForUpgrade`; (f) Sparkle 2 as a SwiftPM binary target from a `.macOS(.v14)` manifest: whether `swift build` links it for `BrahmaApp`, the linker `-rpath @executable_path/../Frameworks` setting, where the artifact's `bin/generate_appcast` and `generate_keys` land (`.build/artifacts/sparkle/…`), and that `generate_appcast` selects its key with `--account`; (g) the owner's prerequisites as a checklist for `docs/release/OWNER-SETUP.md`: a Developer ID Application certificate in the login Keychain, `xcrun notarytool store-credentials "$BRAHMA_NOTARY_PROFILE"` run once interactively by the owner, Sparkle's `generate_keys --account brahma` run once by the owner (the private key stays in the owner's Keychain with its default ACL; the owner copies the printed **public** key into `Resources/sparkle-public-key.txt`), the tap repository created empty, the main repository made public and GitHub Pages enabled for the appcast (owner decision), and "answer Keychain prompts with Allow, never Always Allow".

- [ ] **Step 1:** Generate (a)–(g) on merged `main`.
- [ ] **Step 2: Stop rule.** If R's IPC as merged offers no way to hold admissions and observe `runningTurns == 0` without exiting the service, and adding one would change R's HMAC-protected surface, stop and report: the update path would otherwise install over running turns.
- [ ] **Step 3: Commit** the inventory.

---

### Task 1: `VERSION`, build metadata and the `Info.plist` template

**Files:**
- Create: `VERSION` (`0.3.0`), `scripts/release/version.sh`, `Resources/Info.plist.in`, `Tests/BrahmaReleaseTests/VersionScriptTests.swift`
- Modify: `scripts/make-app.sh` (reads `version.sh` output; renders `Info.plist.in`), `BuildInfo` writer (R) to `"<VERSION> (<sha>[-dirty])"` plus `BuildInfo.semver = "<VERSION>"`, `Package.swift` (test target `BrahmaReleaseTests`, `.processTier`), the About box (shows `BuildInfo.version`; the §2 tagline is X6's task, not repeated here)

**Interfaces:**
- Produces: `scripts/release/version.sh` prints `VERSION=<semver> BUILD=<n> SHA=<short> DIRTY=<0|1>` with `BUILD = MAJOR×1 000 000 + MINOR×1 000 + PATCH`; refuses when `VERSION` is not `^[0-9]+\.[0-9]+\.[0-9]+$`; `Info.plist.in` placeholders `@VERSION@`, `@BUILD@`, `@SUFEEDURL@` (empty unless `BRAHMA_FEED_URL` is set, so dev builds never start the updater) and `@SUPUBLICEDKEY@` (from `Resources/sparkle-public-key.txt`, empty until the owner commits it); `brahma --version` prints `brahma <VERSION> (<sha>)`.

- [ ] **Step 1: Write the failing tests** (`.processTier`, run the scripts in a temp git repo): `VersionScriptTests.printsFields`, `buildNumberIsMonotonicWithSemver` (`0.3.0 → 3000`, `0.10.1 → 10001`, `1.0.0 → 1000000`), `refusesBadVersion`, `dirtyFlagSet`, `plistRendersAllPlaceholders` (no `@…@` left; `CFBundleShortVersionString == VERSION`), `adHocBuildHasNoFeed` (`SUFeedURL` empty).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS; `scripts/make-app.sh debug && scripts/smoke-app.sh` green.
- [ ] **Step 5: Commit:** `build: VERSION file, build metadata and the Info.plist template`.

---

### Task 2: Signing — `sign.sh`, hardened runtime, entitlements, the signed layout and the secrets-trust doctor line (security)

**Files:**
- Create: `scripts/release/sign.sh`, `scripts/release/release-guard.sh`, `Resources/entitlements/{Brahma,brahma-vmhost}.entitlements`, `Sources/BrahmaModel/Release/BuildSignature.swift`, `Sources/BrahmaService/Install/BuildSignature+Current.swift`, `Tests/BrahmaReleaseTests/{SigningLayoutTests,ReleaseGuardTests}.swift`, `Tests/BrahmaEngineTests/DoctorSignatureTests.swift`
- Modify: `scripts/make-app.sh` (calls `sign.sh "$APP"`, ad hoc), `EngineServiceDeps` (+ `buildSignature: BuildSignature`, filled by `BrahmaService` from `BuildSignature.current`), `Doctor.swift` (items `build-signature`, `secrets-trust`), `KeychainVault` (+ `trustRequirementMatches(item:) -> Bool`, reading the item's trusted-application requirement with `SecAccessCopyACLList`/`SecTrustedApplicationCopyRequirement` and comparing it with the running code's designated requirement; wrapped as a value the doctor reads)

**Interfaces:**
- Produces:
  - `public enum BuildSignature: Equatable, Sendable, Codable { case developerID(team: String); case adHoc; case unsigned }`; `BuildSignature.current` (Service, Darwin) parses `SecCodeCopySigningInformation` of the main bundle.
  - `sign.sh <app> [--identity <name>]`: signs inside-out — `Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc`, `…/Autoupdate`, `…/Updater.app`, then the framework (T5 embeds it; absent in builds before T5), then `Contents/Helpers/*` each with its bundle id (and, for `brahma-vmhost`, its entitlements), then the app with `Resources/entitlements/Brahma.entitlements`; `--options runtime --timestamp` when the identity is not `-`; then `codesign --verify --strict --deep <app>` and `codesign -dv --verbose=4` parsed for `Authority=Developer ID Application` (printed as `signed: developer-id` or `signed: ad-hoc`). It refuses any argument or environment value matching `release-guard.sh`'s patterns. **With a real identity it is an OWNER step** (the Keychain prompt must be answered Allow, not Always Allow).
  - `release-guard.sh`: exits non-zero if any argument or `BRAHMA_*` variable contains `-----BEGIN`, `AuthKey_`, `.p8`, `.p12`, `--password`, `-p `, `--ed-key-file` or `-s ` followed by a value; used by every release script first.
  - Doctor `build-signature`: `pass` `developer-id (<team>)` or `warn` `ad-hoc (development build; Keychain items are re-authorized per build)`; `secrets-trust`: `fail` with `items were stored by a differently signed Brahma; re-enter them in Settings › Secrets` when any engine-held item's trusted-application requirement does not match the running binary's, else `pass`.

- [ ] **Step 1: Write the failing tests:** `SigningLayoutTests.cliTrustsItselfAndTheAppOnly` (Review Focus 3: after `make-app.sh debug`, `KeychainVault.trustedApplicationPaths(executable: <bundle>/Contents/Helpers/brahma)` is exactly `[Helpers/brahma, MacOS/Brahma]`, none outside the bundle), `signedInsideOutAndStrict` (`.processTier`, ad hoc: every helper, the framework when present, and the app verify `--strict --deep`; the app's entitlements have no sandbox key; the vmhost's have the virtualization key when the binary exists), `hardenedRuntimeFlagWhenIdentity` (a dry parse of the generated `codesign` argv with a fake identity shows `--options runtime --timestamp`); `ReleaseGuardTests.repositoryHasNoKeyMaterial`, `guardRefusesKeyShapedArgs`, `guardAcceptsPathsAndChecksums`; `DoctorSignatureTests.adHocWarns`, `secretsTrustComparesRequirements` (a fake vault reporting one mismatched item → `fail` with the message; all matching → `pass`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit and process tiers; `shellcheck scripts/release/*.sh`.
- [ ] **Step 5: Commit:** `build: inside-out signing with hardened runtime and entitlements; release guard; signature doctor lines`.

---

### Task 3: DMG, notarization and checksum scripts

**Files:**
- Create: `scripts/release/dmg.sh`, `scripts/release/notarize.sh`, `scripts/release/checksums.sh`, `Tests/BrahmaReleaseTests/DMGScriptTests.swift`

**Interfaces:**
- Produces: `dmg.sh <app> <outdir>` → `<outdir>/Brahma-<VERSION>.dmg` (pinned `hdiutil` flags, the `Applications` symlink, the DMG signed with the same identity when set); `notarize.sh <dmg> [--dry-run]` (**OWNER**): runs `release-guard.sh`, then the pinned `notarytool submit … --keychain-profile "$BRAHMA_NOTARY_PROFILE" --wait`, prints the request id and, on `Accepted`, staples **the DMG** (`xcrun stapler staple <dmg>`), then runs `spctl --assess --type open --context context:primary-signature -v` and fails on anything but `accepted`; `--dry-run` prints the exact commands and exits 0 without contacting Apple; a `notarytool log` is saved beside the DMG on failure. `checksums.sh <outdir>` writes `SHASUMS256.txt` for every file in the directory and must run **after** `notarize.sh` (stapling changes the DMG; the script refuses when the DMG lacks a ticket unless `--unstapled` is passed, which the dry run does).

- [ ] **Step 1: Write the failing tests** (`.processTier`, ad hoc): `DMGScriptTests.producesMountableDMGWithAppAndSymlink` (`hdiutil attach -nobrowse -readonly`, check contents, detach), `checksumsMatchAndRefuseUnstapledWithoutFlag`, `notarizeDryRunPrintsPinnedCommands` (the output contains `--keychain-profile`, staples the DMG only, and never a password flag), `notarizeRefusesWithoutProfileName`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS; `shellcheck`.
- [ ] **Step 5: Commit:** `build: DMG and owner-run notarization scripts`.

---

### Task 4: Homebrew cask

**Files:**
- Create: `scripts/release/cask.sh`, `Casks/brahma.rb` (rendered, committed for review), `Tests/BrahmaReleaseTests/CaskRenderTests.swift`, `Tests/BrahmaReleaseTests/Fixtures/cask/brahma.rb.golden`

**Interfaces:**
- Produces: `cask.sh <dmg> <version> [--url <template>]` renders `Casks/brahma.rb` with the pinned stanzas and the (stapled) DMG's sha256; prints the owner's push commands for the tap (`git -C <tap> add Casks/brahma.rb && git commit -m "brahma <version>" && git push`) without running them. Install line for the README and the site: `brew install --cask 08chandra/brahma/brahma`. If `ruby` is on the PATH, the script runs `ruby -c` on the output.

- [ ] **Step 1: Write the failing tests:** `CaskRenderTests.matchesGolden` (fixed version and sha → byte-identical to the golden, including `auto_updates true`, `depends_on arch: :arm64`, `uninstall quit:/launchctl:`), `sha256IsTheDMGs`, `binaryStanzaPointsAtHelpersBrahma`, `rubySyntaxIfAvailable`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: Commit:** `build: Homebrew cask renderer and the reviewed cask file`.

---

### Task 5: Auto-update — Sparkle embedded and signed, signed appcast, hold-and-drain before install, owner approval (security)

**Files:**
- Create: `Sources/BrahmaAppModel/Update/{UpdateController,UpdateSettings,UpdaterDriving,AppcastSignature}.swift`, `Sources/BrahmaApp/Update/{SparkleDriver,UpdatesMenu}.swift`, `Sources/BrahmaApp/Views/UpdatesPanel.swift`, `scripts/release/appcast.sh`, `Tests/BrahmaAppModelTests/{UpdateControllerTests,AppcastFixtureTests}.swift`, `Tests/BrahmaReleaseTests/SparkleEmbedTests.swift`, `Tests/BrahmaAppModelTests/Fixtures/appcast/{good.xml,older.xml,wrongkey.xml,test-public-key.txt,fixture.dmg}` (the fixture DMG is a 1 KiB file; its `good.xml` signature was made once with a throwaway key that is not kept anywhere)
- Modify: `Package.swift` (Sparkle 2.x pinned as a binary target for `BrahmaApp`; linker rpath per Task 0 (f)), `scripts/make-app.sh` (copies `Sparkle.framework` from the artifact into `Contents/Frameworks/`), `scripts/release/sign.sh` (already signs it inside-out, T2), `Resources/Info.plist.in` (the `SU*` keys of the pinned table), `THIRD_PARTY_NOTICES.md` (Sparkle MIT), `Doctor.swift` (item `updates`), P's inventory fixtures (the Updates panel; baseline commit tagged `approved release-engineering plan`)

**Interfaces:**
- Produces:
  - `public protocol UpdaterDriving: Sendable { func start(); func checkForUpdates(background: Bool); func setEnabled(_: Bool); var runningVersion: String { get } /* CFBundleShortVersionString */ }` — `SparkleDriver` wraps `SPUStandardUpdaterController(startingUpdater: false, …)` and implements `SPUUpdaterDelegate`: `updater(_:shouldProceedWithUpdate:)` → `UpdateController.allows(candidate:)` (version and `AppcastSignature` pre-check); `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` → `UpdateController.holdAndDrain(then:)`; automatic download and install are off (Sparkle asks; the owner clicks). `start()` is called only when `UpdateSettings.feedURL != nil`.
  - `public enum AppcastSignature { static func verify(edSignature: String, length: Int, data: Data, publicKey: String) -> Bool }` — CryptoKit `Curve25519.Signing.PublicKey`, Sparkle's base64 conventions.
  - `@MainActor @Observable final class UpdateController { init(driver: any UpdaterDriving, engine: any EngineClient, settings: UpdateSettings, publicKey: String, clock: …); func allows(candidate: AppcastItem) -> Decision<Void> /* refuses ≤ running (semver compare), a non-semver, or a signature that fails AppcastSignature.verify */; func holdAndDrain(then relaunch: @escaping () -> Void) async /* engine.holdForUpgrade(); poll status until runningTurns == 0, ≤ 60 s; then relaunch (Sparkle installs the new bundle and relaunches the app; R's welcome/restartForUpgrade restarts the service on the new binary); on timeout engine.releaseHold() and status = .postponed(reason) */; var status: UpdateStatus; static let drainDeadline: Duration = .seconds(60) }` and `UpdateSettings { var enabled: Bool /* false when BRAHMA_NO_UPDATES=1 or the toggle is off */; var feedURL: URL? /* nil in ad-hoc builds */; var lastCheck: Date? }` stored in the app's preferences (not the engine database).
  - `appcast.sh <release-dir> [--download-url-prefix <url>]` (**OWNER**): runs `release-guard.sh`, then Sparkle's `generate_appcast --account "$BRAHMA_SPARKLE_ACCOUNT" --download-url-prefix <url> <dir>` (the tool at Task 0 (f)'s artifact path): Sparkle 2's tool reads the EdDSA private key from the Keychain item that `generate_keys` created under that account, so the key never passes through an argument, a file or the script; `--ed-key-file` and `-s` are refused by `release-guard.sh`. It writes `appcast.xml` with the stapled DMG's EdDSA signature and length; `--dry-run` prints the command.
  - Doctor `updates`: `pass` `feed <url>, last check <t>`, `warn` `disabled by BRAHMA_NO_UPDATES`/`disabled in Settings`, or `pass` `development build (no feed)`.
  - UI: an `Updates` panel under Settings (toggle, last check, "Check now"), a "Check for Updates…" menu item; the Sparkle dialogs are the standard ones.

- [ ] **Step 1: Write the failing tests:** `UpdateControllerTests.olderOrEqualVersionRefused` (Review Focus 1: running `0.3.0`, candidates `0.3.0`, `0.2.9`, `abc` → refused with the message; `0.3.1` → allowed), `holdsAndDrainsBeforeInstall` (Review Focus 2: `FakeEngineClient` records `holdForUpgrade`, then `status` polls, and the relaunch closure runs only after `runningTurns == 0`; `restartForUpgrade` is **not** called by the controller), `drainTimeoutReleasesHoldAndPostpones` (a client that stays at 2 running turns → after 60 s `releaseHold` is called, the relaunch closure is not, and `status == .postponed("engine still draining (2 turns running)")`), `serviceRestartHappensAfterRelaunch` (R's `welcome` with a different build triggers `restartForUpgrade`; asserted against R's client fake), `disabledByEnvOrSetting` (no check is requested on the driver), `noFeedNeverStarts` (`feedURL == nil` → `start()` is never called); `AppcastFixtureTests.goodFixtureVerifies` (`AppcastSignature.verify` of `good.xml`'s item against `fixture.dmg` with `test-public-key.txt`), `wrongKeyRefused`, `olderFeedIsNotNewer`; `SparkleEmbedTests.frameworkEmbeddedAndSigned` (`.processTier`: after `make-app.sh debug`, `Contents/Frameworks/Sparkle.framework` exists, `otool -l` of the app shows the rpath, and `codesign --verify --strict --deep` passes).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit and process tiers; `scripts/make-app.sh debug` builds with Sparkle embedded and inert (`adHocBuildHasNoFeed` still passes); `scripts/ui-inventory.sh` diff shows only the Updates panel; `scripts/smoke-app.sh` green.
- [ ] **Step 5: Commit:** `feat(app): signed auto-update through Sparkle — owner-approved installs, engine held and drained first, downgrades and bad signatures refused`.

---

### Task 6: Opt-in crash reports — collected locally, redacted, sent by the owner

**Files:**
- Create: `Sources/BrahmaAppModel/Diagnostics/{CrashReports,CrashRedactor}.swift`, `Sources/BrahmaApp/Views/DiagnosticsPanel.swift`, `Tests/BrahmaAppModelTests/CrashReportsTests.swift`, `Tests/BrahmaAppModelTests/Fixtures/ips/{brahma-engine.ips,other-app.ips,mcp-with-argv.ips}`
- Modify: `Doctor.swift` (item `crash-reports`, only when opted in), `brahma engine logs` tail reused for context

**Interfaces:**
- Produces:
  - `public struct CrashReports { init(directory: URL /* injected; default ~/Library/Logs/DiagnosticReports */, since: Date?, redactor: CrashRedactor); func scan() throws -> [CrashReport] }` with `CrashReport { processName: String; timestamp: Date; bugType: String; exceptionSummary: String; redactedText: String /* ≤ 64 KiB */; path: URL }` — only the pinned process names; files are read through `SafeRead` with a 2 MiB cap; parsing is the `.ips` JSON header plus the body's first frames, nothing executed.
  - `CrashRedactor { init(home: URL, user: String, known: CanaryLeakMatcher, scan: SecretScan); func redact(_ text: String) -> String }` — home → `~`, user → `<user>`, every known value → `<redacted>`, every `SecretScan` hit → `<redacted:<kind>>`, `BRAHMA_HOME=…` values → `<home>`.
  - `DiagnosticsPanel`: toggle "Look for crash reports at launch" (default off; stored in app preferences), the list, "Copy redacted report", "Open an issue…" (opens the pinned URL with a title `Crash: <process> <bugType> <version>` and a ≤ 6 KiB body holding the exception summary, the first frames and `brahma --version`; the owner pastes the rest if they choose). **Brahma never uploads anything.**
  - Doctor `crash-reports`: when opted in, `warn` `2 new (Settings › Diagnostics)`, else `pass` `none` or `pass` `not checking (opt in under Settings › Diagnostics)`.

- [ ] **Step 1: Write the failing tests:** `CrashReportsTests.findsOnlyBrahmaReports` (the fixture dir has `other-app.ips` → not listed), `disabledByDefaultScansNothing`, `redactsHomeUserAndSecrets` (Review Focus 5: a fixture with `/Users/chandra/...`, a known value and an `sk-ant-…` string → none present), `argvFromMCPCrashIsRedactedAndBounded`, `issueURLBounded` (≤ 6 KiB body, percent-encoded, no raw path), `noNetworkCodePath` (a lint: `Sources/BrahmaAppModel/Diagnostics/` imports no networking and names no `URLSession`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement with P's components. **Step 4:** PASS with the unit tier; `scripts/ui-inventory.sh` diff shows only the Diagnostics panel; baseline commit tagged `approved release-engineering plan`; `ThemeLintTests`, `ScreenInventoryTests` green.
- [ ] **Step 5: Commit:** `feat(app): opt-in crash reports, redacted and owner-sent; no telemetry`.

---

### Task 7: `SMAppService` for signed builds; translocation preflight (security)

**Files:**
- Create: `Sources/BrahmaService/Install/{ServiceInstalling,SMAppServiceInstaller,Translocation}.swift`, `Tests/BrahmaServiceTests/{SMAppServiceInstallerTests,TranslocationTests}.swift`
- Modify: R's `ServiceInstaller` (conforms to the new `ServiceInstalling` protocol extracted from its surface: `install(program:)`, `uninstall()`, `status()`, `ensureCurrent(program:)`, `preflight()`), the installer selection in `BrahmaService` (`SMAppServiceInstaller` only when `BuildSignature.current` is `.developerID`, the bundle is under `/Applications` and the data home is the default one; otherwise R's LaunchAgent installer unchanged), `ServiceGuardTests` (the `SMAppService` string is allowed only in `BrahmaService/Install/`), `Doctor.swift` (the `service` item names the mechanism), the app's first-run flow (translocation message with Reveal in Finder)

**Interfaces:**
- Produces: `public protocol ServiceManaging: Sendable { func register() throws; func unregister() throws; var status: SMAppService.Status { get } }` (`SystemSMAppService` wraps `SMAppService.agent(plistName: "dev.brahma.engine.plist")`; `FakeServiceManager` in tests); `SMAppServiceInstaller: ServiceInstalling` with the same `InstallerStatus` values, mapping `.requiresApproval` → `.disabledByUser` with the `System Settings › Login Items` hint, and a thrown `register()` → `InstallerStatus.unavailable(reason:)` (new case; the app then uses R's labelled unmanaged-child fallback, never silently); **migration:** before `register()`, if R's LaunchAgent with the same label is loaded, `bootout` it and remove its plist (through R's `Launchctl`), once; the embedded `Contents/Library/LaunchAgents/dev.brahma.engine.plist` is rendered by R's `LaunchAgentPlist.render(embedded: true)` with `BundleProgram` `Contents/Helpers/brahma`, `ProgramArguments` `["engine", "serve"]`, and **no path keys** (no `BRAHMA_HOME`, `StandardOutPath` or `WorkingDirectory`: the default home is implied, and `brahma engine serve` redirects its own stdout and stderr to the log file at start when launched by SMAppService); `Translocation.isTranslocated(bundleURL:) -> Bool` (`/AppTranslocation/` or `/Volumes/` prefix) and `ServiceInstalling.preflight()` refusing with the pinned message. **Nothing changes for ad-hoc builds or non-default homes** (R's tests stay green untouched).

- [ ] **Step 1: Write the failing tests:** `SMAppServiceInstallerTests.chosenOnlyForDeveloperIDInApplicationsDefaultHome`, `registerMapsStatuses`, `registerFailureIsUnavailableWithReason`, `migratesFromLaunchAgent` (`FakeLaunchctl` records `bootout`; plist removed), `embeddedPlistHasBundleProgramAndNoPaths`, `adHocKeepsLaunchAgent` (R's `ServiceInstallerTests` run against the selector with an ad-hoc signature fact); `TranslocationTests.detectsAndRefusesInstall` (Review Focus 4), `volumesPathRefused`, `applicationsPathPasses`; `ServiceGuardTests.smAppServiceOnlyInInstall`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS with the unit and process tiers; manual (owner, once, after the first signed build): `brahma engine install` → `status` shows `SMAppService: enabled`; recorded in the task report.
- [ ] **Step 5: Commit:** `feat(service): SMAppService installer for Developer-ID builds; translocation preflight`.

---

### Task 8: `release.sh`, `dry-run.sh`, the checklist, owner setup, site and README, final review

**Files:**
- Create: `scripts/release/release.sh`, `scripts/release/dry-run.sh`, `docs/release/CHECKLIST.md`, `docs/release/OWNER-SETUP.md`, `Tests/BrahmaReleaseTests/DryRunTests.swift`
- Modify: `README.md` ("Install": the DMG, the cask line, "Build from source" kept), `site/src/pages/start.astro` `installer` slot and `InstallTabs` `initial` (the exact edits the site's README names; the link and checksum are filled by `release.sh`'s printed values — the owner commits them in the `site-docs` lane after the release exists), `site/src/components/HowItWorks.astro` (the Install step brief)

**Interfaces:**
- Produces:
  - `release.sh [--no-notarize] [--no-appcast] [--skip-tests] [--allow-dirty] [--out <dir>]`: refuses on a dirty tree (unless `--allow-dirty`, dry run only) or a `VERSION` without a matching note in `docs/release/NOTES-<VERSION>.md`; runs `release-guard.sh`, `scripts/test.sh all` (unless `--skip-tests`), `scripts/make-app.sh release` (which signs ad hoc), `sign.sh` with the identity (re-signing with `--force`; **OWNER** when the identity is real), `dmg.sh`, then **prints** the owner commands for `notarize.sh`, `checksums.sh`, `cask.sh`, `appcast.sh`, the tap push and the GitHub release (`gh release create v<VERSION> <dmg> SHASUMS256.txt appcast.xml --draft --notes-file docs/release/NOTES-<VERSION>.md`; `gh` is not installed here, so the command is printed, never run). Each step's output is logged under `<out>/release.log`.
  - `dry-run.sh`: `release.sh --no-notarize --no-appcast --skip-tests --allow-dirty --out <tmp>` with `BRAHMA_SIGN_IDENTITY=-`, then `checksums.sh --unstapled` and `cask.sh`, and asserts the DMG mounts, the app inside verifies `--strict --deep`, `SHASUMS256.txt` matches, `Casks/brahma.rb` renders, and the printed owner commands contain no credential-shaped text.
  - `docs/release/CHECKLIST.md`: one line per step, each tagged `script` or `OWNER`: bump `VERSION` and write `NOTES-<v>.md`; `scripts/test.sh all`; **OWNER** `release.sh` (real identity; answer Allow); **OWNER** `notarize.sh`; `spctl` green; `checksums.sh`; `cask.sh`; **OWNER** `appcast.sh` and upload `appcast.xml`; **OWNER** `gh release create … --draft`, review, publish; **OWNER** tap push; **OWNER** site `installer` slot; smoke the download on a second Mac (`xattr -d com.apple.quarantine` must **not** be needed); first signed build only: re-enter engine-held secrets once (`secrets-trust`); verify auto-update from the previous version on a test Mac (the engine holds and drains, 0 interrupted turns, the service restarts on the new build); rollback: delete the appcast item and re-point the cask to the previous DMG. A test checks the checklist's shape: every line carries exactly one of the two tags and every script it names exists.
  - `docs/release/OWNER-SETUP.md`: the one-time owner setup from T0 (g), with the exact commands and no values.

- [ ] **Step 1: Write the failing tests:** `DryRunTests.pipelineShapeHolds` (`.processTier`, runs `dry-run.sh`; skipped when `hdiutil` is unavailable), `printedOwnerCommandsCarryNoSecrets`, `checklistLinesTaggedAndScriptsExist`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement; `shellcheck`. **Step 4:** PASS with the process tier; `scripts/make-app.sh debug && scripts/smoke-app.sh` green.
- [ ] **Step 5: Final review (Opus)** of the branch against spec §4 (no telemetry), §5 (no credential where an agent can reach it; no silent fallback), the Global Constraints "Scripts never take a credential" and this Review Focus; then the owner-run live leg `LiveUpdate/appcastRoundTrip` (below) once a signed release exists, recorded in `docs/release/CHECKLIST.md`'s first entry.
- [ ] **Step 6: Commit:** `build: release orchestration, dry run, checklist and owner setup; install docs`.

---

## §10 row delivered by this plan (added to the spec as row 13 by this plan; final ids)

**This plan's "beats" line (row 13, Codex app / Conductor / Paradev: one-click signed installers with automatic updates):** *Brahma ships a notarized DMG and a Homebrew cask, and updates through a signed appcast where every update drains the engine first and installs only on the owner's approval, with no telemetry: crash reports are opt-in, redacted on the Mac and sent by the owner, never by Brahma.* **Acceptance:** (1) `DryRunTests.pipelineShapeHolds`: the pipeline produces a DMG whose app passes `codesign --verify --strict --deep`; (2) owner leg: `spctl --assess` accepts the notarized DMG and a fresh Mac opens it with no quarantine override; (3) `LiveUpdate/appcastRoundTrip` (owner-run): build N installed by the cask updates to N+1 through the appcast with the engine drained and 0 interrupted turns, while an older or wrongly signed appcast item is refused (`UpdateControllerTests.olderOrEqualVersionRefused`, `AppcastFixtureTests.wrongKeyRefused`); (4) `CrashReportsTests.noNetworkCodePath`.

| Row | Criterion | Task |
|---|---|---|
| 13 (1) | dry-run pipeline, strict signature | T2, T3, T8 |
| 13 (2) | notarized DMG accepted by Gatekeeper | T3 (owner) |
| 13 (3) | signed update, engine held and drained, service restarted on the new build, downgrade and bad signature refused | T5, T8 |
| 13 (4) | no network path in crash reporting | T6 |
| F-X7 | `SMAppService` on signed builds | T7 |
| Site "Installer dependency" | installer tab link and checksum | T8 |

## Decision for the owner

- **Sparkle 2 (recommended, controller's call) or a minimal custom verifier.** Sparkle adds one MIT dependency and brings a hardened installer path (atomic bundle replacement, EdDSA appcast signatures, Gatekeeper-aware relaunch) that a custom verifier would have to reproduce; the plan keeps every Sparkle automatism off so the owner approves each install. If the owner rules against the dependency, T5 becomes: a 300-line `UpdateChecker` (fetch `appcast.json`, verify an Ed25519 signature over `{version, sha256, url}` with CryptoKit, download, verify sha256, mount, `codesign --verify --strict --deep`, replace the bundle through a helper launched after quit, relaunch) with the same tests; effort grows by about two tasks and needs its own Opus review.
- **Hosting needs a public repository.** GitHub Releases downloads and a GitHub Pages appcast require `08chandra/brahma` to be public (the site's README notes it is not yet). Alternatives: a separate public `brahma-releases` repository holding only the DMGs and `appcast.xml`, or the owner's own HTTPS host. One line in the pinned table changes.
- **Architecture:** `arm64` only in v1 (controller's call), or a universal build (`swift build --arch arm64 --arch x86_64`, roughly double the build time and DMG size) so Intel Macs on macOS 14+ can run the app in Seatbelt mode.
- **Version and tap defaults:** first release `0.3.0`; tap `08chandra/homebrew-brahma`. Each is a one-line change in the pinned table.

## Self-review notes

- **Spec coverage.** §4 no telemetry: T6 (`noNetworkCodePath`), Global Constraints. §5 no credential where an agent can reach it: `release-guard.sh`, `ReleaseGuardTests` (T2), owner-run signing and the Allow-not-Always-Allow rule (Global Constraints, T0 (g)); no silent fallback: a failed drain postpones with the reason (T5), a failed `SMAppService` register is `unavailable(reason)` with R's labelled fallback (T7), translocation refuses with a message (T7). F-X7: T7. Website "Installer dependency": T8. Plan R's upgrade flow is kept: the app holds and drains, Sparkle installs, the relaunched app's `welcome` triggers `restartForUpgrade` on the new binary (T5). The brief's five deliverables: notarized signed DMG (T2, T3), Homebrew cask (T4), auto-update with a signed appcast (T5), opt-in crash reporting (T6), release checklist (T8). Owner steps scripted but credentials never handled: T0 (g), T2, T3, T5, T8.
- **Controller's calls made here:** Sparkle 2 with automatics off and an app-side EdDSA pre-check; crash reports to a prefilled GitHub issue opened by the owner (no endpoint); `SMAppService` only for Developer-ID builds in `/Applications` on the default home, with a one-time LaunchAgent migration; `arm64` only; `CFBundleVersion` derived from semver; `0.3.0`; the `BrahmaReleaseTests` process-tier target; the `secrets-trust` doctor line (requirement comparison) instead of a migration of Keychain ACLs (re-entering is the honest path and happens once).
- **Type consistency:** `BuildInfo.semver` (T1) is `UpdaterDriving.runningVersion` (T5); `BuildInfo.version` is display text and the issue title (T6); `BuildSignature` (T2, `BrahmaModel`) is read by the doctor through `EngineServiceDeps` and by the installer selector (T7); `ServiceInstalling` (T7) is conformed to by R's `ServiceInstaller` and `SMAppServiceInstaller`; `release-guard.sh` (T2) is called by every later script (T3, T4, T5, T8); `checksums.sh` (T3) feeds `cask.sh` (T4) and `appcast.sh` (T5); `InstallerStatus` (R, + `unavailable(reason:)`) is produced by both installers (T7); `AppcastSignature` (T5) is used by `UpdateController.allows` (T5).
- **Effort:** 9 tasks (T0–T8). L: T5. M: T2, T3, T6, T7, T8. S: T0, T1, T4. Three Opus reviews. About 6–8 implementer-days subagent-driven, plus the owner's one-time setup and the notarized live leg.
