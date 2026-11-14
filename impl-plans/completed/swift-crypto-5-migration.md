# swift-crypto 5.x Migration

**Status**: Completed (Linux build/test recorded as a verification gap)
**Plan ID**: PLAN-SC5-001
**Depends On**: none (BLK-1 resolved by google-service-gateway tag v0.1.7)
**Design Reference**: `design-docs/specs/notes.md#swift-crypto-5x-migration-2026-10-27`
**Issue**: workflowInput "gmail-gateway: move to swift-crypto 5.x (retry after google-service-gateway 0.1.7)" (no URL or number)

## Purpose

The owner wants every Swift package in the Riela dependency graph to require
apple/swift-crypto 5.x, so that Riela resolves a single 5.x version. In this
repository that means:

- Package.swift requires
  `.package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3")`.
- Package.swift pins google-service-gateway at the v0.1.7 commit
  `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`. That commit itself requires
  swift-crypto `from: "5.0.3"`.
- Package.resolved pins swift-crypto 5.x.
- Behavior does not change. Every SHA-256 output stays byte-for-byte identical.
- The version goes from `0.1.28` to `0.1.29`, in both `VERSION` and
  `gmailGatewayVersion()`.
- The stale version test compares against the real VERSION file. It no longer
  uses a hard-coded literal.

This is one plan, done in order, for two reasons. First, the issue says to
continue this plan and not to start a parallel one. Second, every verification
step needs the resolved manifest.

## Repository Context

- `Package.swift:1` is `// swift-tools-version: 6.0`. It must stay that way.
  swift-crypto 5.0.3 declares 6.2, and the mise toolchain is `swift = "6.3.3"`.
- `Package.swift:20` currently has swift-crypto `from: "4.5.2"`.
- `Package.swift:21` pins google-gateway-auth at revision
  `48e0112fb5eb057cf012194cfffaa2581ba29d76`. Keep it.
- `Package.swift:22` pins gateway-sdk-kit with `exact: "0.1.1"`. Keep it.
- `Package.swift:23` pins google-service-gateway at revision
  `4cfef44b245893e6de4f30780c70fb0314da70eb`. This changes.
- `Package.swift:31` links the `Crypto` product only on Linux:
  `condition: .when(platforms: [.linux])`. Keep it.
- `Package.resolved` currently has exactly 5 pins:
  - gateway-sdk-kit 0.1.1 (`b133fcaa…`)
  - google-gateway-auth `48e0112f…`
  - google-service-gateway `4cfef44b…`
  - swift-asn1 1.7.3 (`3b6410f7…`)
  - swift-crypto 4.5.2 (`da9d28d6…`)

  It also has `originHash`, which SwiftPM recomputes whenever the manifest
  changes. That change is expected.
- Five files use `#if canImport(CryptoKit) import CryptoKit #else import Crypto`.
  On macOS only CryptoKit is compiled. The only crypto API used is
  `SHA256.hash(data:)`:
  - `Sources/GmailGatewayCore/GmailOAuthClientFingerprint.swift:18`: hex via `%02x`
  - `Sources/GmailGatewayCore/GmailArchiveReads.swift:142`: `archiveSHA256`, hex via `%02x`
  - `Sources/GmailGatewayCore/MessageFileDownloads.swift:518`:
    `attachmentStorageFilenamePrefix(attachmentId:)`
  - `Sources/GmailGatewayCore/GmailOAuthBootstrap.swift:772`:
    `codeChallenge(for:)`, base64url
  - `Sources/GmailGatewayCore/GmailCredentialResolution.swift`: import only,
    no crypto call
- Version:
  - `VERSION` is `0.1.28`, one line.
  - `Sources/GmailGatewayCore/GmailGatewayUtilities.swift:4-6` has
    `func gmailGatewayVersion() -> String { "0.1.28" }`.
- Version tests in `Tests/GmailGatewayCoreTests/CommandTests.swift`:
  - `versionFlagReturnsVersionForAllBinaries` (lines 43-49) reads `VERSION`
    relative to the working directory and calls `nonBlank`. Do not change it.
  - `embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile` (lines 52-54)
    expects `"0.1.26"`. It fails at HEAD.
- Pattern to copy for a source-anchored path:
  `Tests/GmailGatewayCoreTests/PersistentAuthLifecycleSubprocessTests.swift:lockTestDirectory()`
  (lines 108-114). It calls `URL(fileURLWithPath: #filePath)` and then
  `.deletingLastPathComponent()` three times to reach the repository root.
- `mise.toml` tasks:
  - `build` runs `swift build`.
  - `test` runs `swift test` and then `swift run gmail-gateway-swift-smoke-tests`.
  - `lint` runs `swiftlint`.
  - There is no Linux task.
- Local Linux runtimes exist at `/opt/homebrew/bin/docker` and
  `/opt/homebrew/bin/container`. Their daemons may not be running.
- `.gitignore` ignores `.build/` and `tmp/`. It does not ignore `.build-linux`,
  so put every Linux scratch path under `tmp/`.

## Non-Goals

- Do not fork, vendor, path-override, mirror, or remove any dependency.
- Do not change pin styles or the google-gateway-auth and gateway-sdk-kit pins.
- Do not change `swift-tools-version`.
- Do not refactor the `#if canImport(CryptoKit)` pattern.
- Do not remove the unused import in `GmailCredentialResolution.swift`.
- Do not add crypto helpers.
- Do not change any expected digest value in tests.
- Do not delete, skip, or weaken any test. Do not edit
  `versionFlagReturnsVersionForAllBinaries`.
- Do not make `gmailGatewayVersion()` read VERSION at runtime. It returns an
  embedded literal.
- Do not add version-generation scripts or build steps.
- Do not use `FileManager.changeCurrentDirectoryPath` in tests. Tests run in
  parallel.
- Do not edit `design-docs/`, `mise.toml`, `Formula/`, `dist/`,
  `impl-plans/PROGRESS.json`, or other plan files.
- Do not publish a GitHub release. Do not run `build:homebrew`,
  `homebrew:formula`, or `homebrew:tap-formula`.
- The implementer does not run `git commit`, `git push`, or any other git write.
  It also does not move plan files. Finalization commits and pushes to
  `origin/main` as one commit. The workflow's plan-archive step moves this plan
  and `impl-plans/active/swift-crypto-5-dispatch.json` to
  `impl-plans/completed/`.

## Invariants

- SHA-256 output does not change:
  - lowercase hex via `String(format: "%02x", $0)` for the fingerprint, archive
    sha256, and attachment prefix
  - base64url without padding for PKCE
- On macOS the code compiles against CryptoKit. `Crypto` stays linked only on
  Linux.
- The `Package.resolved` diff touches only:
  - `originHash`
  - the swift-crypto pin
  - the swift-asn1 pin, only if swift-crypto 5 requires a change
  - the google-service-gateway pin

  gateway-sdk-kit and google-gateway-auth pins must be byte-identical.
- Every Swift file stays under 1000 lines.
- Before each file edit, read the file again and record its sha256 in the
  Progress Log. Record it again after the edit. If the pre-edit hash differs
  from the hash recorded at TASK-001 (Package.swift, Package.resolved) or from
  the last recorded hash, stop. Report the drift and do not overwrite.

## Tasks

All command output goes to `tmp/swift-crypto-5/logs/<name>.log`. For each
command, record the exit code and the log path in the Progress Log. A
truncated or missing log does not count as a pass.

### TASK-001: Gate and baseline

**Parallelizable**: No

1. Check the upstream tag:
   - Command: `git ls-remote https://github.com/tacogips/google-service-gateway.git refs/tags/v0.1.7 'refs/tags/v0.1.7^{}'`
   - Log: `gate-ls-remote.log`
   - The tag must resolve to `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`.
   - If there is no `^{}` line, the tag is lightweight, so the SHA is the
     commit SHA.
   - If the SHA is different, stop and report it.
2. Read the upstream `Package.swift` at that SHA from
   `https://raw.githubusercontent.com/tacogips/google-service-gateway/ed020e4a8f45a0acedaf46334e2a67677e3c3e63/Package.swift`.
   Save it as `tmp/swift-crypto-5/logs/upstream-Package.swift.txt`. Confirm:
   - swift-crypto is `from: "5.0.3"`, or another lower bound of 5 or higher.
   - google-gateway-auth is `revision: "48e0112fb5eb057cf012194cfffaa2581ba29d76"`.

   If either check fails, stop. Report the exact constraint line as a blocker.
   Do not work around it.
3. Record `shasum -a 256 Package.swift Package.resolved VERSION Sources/GmailGatewayCore/GmailGatewayUtilities.swift Tests/GmailGatewayCoreTests/CommandTests.swift`.
4. Baseline:
   - Command: `swift test --filter CommandTests`
   - Log: `baseline-commandtests.log`
   - Record the exit code and the names of failing tests.
   - The only expected failure is
     `embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile`. Record it
     as pre-existing.
5. Read the swift-crypto 5.0.0 release notes:
   - Command: `gh release view 5.0.0 -R apple/swift-crypto`
   - Fallback: fetch `https://github.com/apple/swift-crypto/releases/tag/5.0.0`.
   - Log: `swift-crypto-5.0.0-notes.log`
   - Record whether any `SHA256`, `Digest`, or `HashFunction` API was renamed
     or removed.

**Completion Criteria**:

- [x] The tag SHA, the upstream swift-crypto line, and the google-gateway-auth
  line are recorded.
- [x] Baseline hashes, the CommandTests exit code, and failing test names are
  recorded.
- [x] Release-note findings for SHA256 are recorded.

### TASK-002: Manifest and resolution

**Parallelizable**: No (depends on TASK-001)

1. Edit `Package.swift`. Change only these two string values:
   - Line 20: `from: "4.5.2"` becomes `from: "5.0.3"`. The URL stays the same.
   - Line 23: `revision: "4cfef44b245893e6de4f30780c70fb0314da70eb"` becomes
     `revision: "ed020e4a8f45a0acedaf46334e2a67677e3c3e63"`.
2. Run the scoped update:
   - Command: `swift package update swift-crypto google-service-gateway`
   - Log: `package-update.log`
   - Pitfall: never run a bare `swift package update`. Never add
     `google-gateway-auth` or `gateway-sdk-kit` to the command.
3. If resolution fails because a dependency caps swift-crypto below 5, stop.
   Report the exact constraint line from the error as a blocker.
4. Check Package.resolved:
   - Command: `git diff Package.resolved`
   - Log: `resolved-diff.log`
   - It must satisfy the Package.resolved invariant.
   - swift-crypto `version` must start with `5.`.
   - google-service-gateway `revision` must equal `ed020e4a…`.
   - Record the swift-asn1 version.
5. Review the upstream API diff:
   - Command: `git -C .build/checkouts/google-service-gateway diff 4cfef44b245893e6de4f30780c70fb0314da70eb ed020e4a8f45a0acedaf46334e2a67677e3c3e63 --stat`,
     then the same with `-- Sources/GoogleServiceGatewayCore`.
   - Log: `upstream-diff.log`
   - If the SwiftPM checkout lacks history, clone instead:
     `git clone --filter=blob:none https://github.com/tacogips/google-service-gateway.git tmp/swift-crypto-5/upstream-gsg`,
     then run the same diff there.
   - Do not touch the sibling `../google-service-gateway` checkout.
   - Log any changed public symbol that `Sources/GmailGatewayCore` uses. Find
     uses with `grep -rn 'GoogleServiceGatewayCore\|SecureCredentialStore\|KeychainCredentialStore' Sources/GmailGatewayCore`.

**Completion Criteria**:

- [x] `grep -n 'swift-crypto\|google-service-gateway' Package.swift` shows
  `from: "5.0.3"` and `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`.
- [x] The Package.resolved diff contains only the allowed entries.
  swift-crypto is `5.x.y`.
- [x] Upstream API-diff findings are recorded. "None used" is a valid finding.

### TASK-003: Compile fixes with no behavior change

**Parallelizable**: No (depends on TASK-002)

1. Build on macOS:
   - Command: `swift build`
   - Log: `build-macos.log`
2. Build and test on Linux. This is the only check that compiles the
   `import Crypto` paths against swift-crypto 5.
   - Command: `docker run --rm -v "$PWD":/src -w /src swift:6.3 bash -lc 'swift build --scratch-path tmp/swift-crypto-5/build-linux && swift test --scratch-path tmp/swift-crypto-5/build-linux'`
   - Log: `linux-build-test.log`
   - Also record in the Progress Log: the host `swift --version`, the
     container `swift --version`, and the pulled image digest
     (`docker image inspect swift:6.3 --format '{{.Id}}'`).
   - If docker is not running, use the equivalent `container run` command.
   - If no Linux runtime works, or the image tag cannot be pulled, record a
     verification gap with the exact error. Cite the TASK-001 release-note
     finding for SHA256. A gap is not a pass.
   - Never put the Linux scratch path outside `tmp/`.
3. Fix only errors or new deprecation warnings caused by swift-crypto 5 or
   google-service-gateway v0.1.7.
   - Crypto fixes go only in the five Repository Context files.
     google-service-gateway fixes go only at the call sites in
     `Sources/GmailGatewayCore`.
   - Use the smallest substitution that produces the same bytes. Log each
     change.
   - Pitfalls:
     - Do not switch the hash or encoding.
     - Do not change `%02x`.
     - Do not change PKCE base64url padding.
     - Do not put `SHA256` behind a new helper.
4. If a digest call site changed, add one known-answer assertion to that
   feature's existing test file:
   `SHA256("abc")` hex =
   `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
   Otherwise add no tests.

**Completion Criteria**:

- [x] `swift build` exits 0.
- [x] `grep -iE 'warning:.*(SHA256|Crypto|deprecated)' tmp/swift-crypto-5/logs/final-build.log`
  shows no warning from these files.
- [x] The Linux build and test exit 0, or an explicit verification gap is
  recorded.

### TASK-004: Version bump and version test fix

**Parallelizable**: No (depends on TASK-003, so failures can be attributed)

1. In `VERSION`, change `0.1.28` to `0.1.29`. Keep the existing line and
   newline style. Check the byte layout before editing with `xxd VERSION`.
2. In `Sources/GmailGatewayCore/GmailGatewayUtilities.swift:5`, change the
   literal `"0.1.28"` to `"0.1.29"`. Change nothing else in the file.
3. Rewrite only the body and signature of
   `embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile` in
   `Tests/GmailGatewayCoreTests/CommandTests.swift`:
   - The signature becomes `@Test func embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile() throws`.
   - Build the repository-root `VERSION` URL from `#filePath`. Copy the
     three-step `deletingLastPathComponent()` chain from `lockTestDirectory()`,
     then append `"VERSION"`.
   - Read the file with `String(contentsOf:encoding: .utf8)`.
   - `#require(nonBlank(...))` the value.
   - Then `#expect(gmailGatewayVersion() == expected)`.
   - Keep the test name.
   - Do not read `"VERSION"` relative to the working directory.
   - Do not use any version literal.
4. Run the filtered tests:
   - Command: `swift test --filter CommandTests`
   - Log: `commandtests-after.log`
   - It must exit 0 with both version tests passing.
5. Check for leftover old versions:
   - Command: `grep -rn '0\.1\.28\|0\.1\.26' Sources Tests VERSION`
   - It must print nothing. Exit 1 is expected.

Test cases:

- VERSION = `0.1.29`, literal = `"0.1.29"` -> both version tests pass.
- Literal and VERSION disagree, for example literal `"0.1.28"` -> the
  embedded-version test fails. This is the regression the test exists to catch.
- Test run from a working directory other than the repository root -> the
  embedded-version test still finds VERSION through `#filePath`.

**Completion Criteria**:

- [x] `cat VERSION` prints `0.1.29`.
- [x] `gmailGatewayVersion()` returns `"0.1.29"`.
- [x] `grep -n '"0.1.2[0-9]"' Tests/GmailGatewayCoreTests/CommandTests.swift`
  prints nothing.
- [x] `swift test --filter CommandTests` exits 0.

### TASK-005: Full verification and Progress Log

**Parallelizable**: No (depends on TASK-004)

Run V1 through V7 below. Record every exit code and log path. Then add a
completion entry to the Progress Log. Leave `**Status**` at `In Progress` if
any check other than V6 failed. Otherwise set it to `Completed`, and list V6
as passed or as a gap.

## Verification

- V1 `swift package resolve` -> exit 0. Log: `v1-resolve.log`.
- V2 `python3 -I -c "import json;print([(p['identity'],p['state']) for p in json.load(open('Package.resolved'))['pins']])"`
  -> swift-crypto `5.x`, google-service-gateway `ed020e4a…`, google-gateway-auth
  `48e0112f…`, gateway-sdk-kit `0.1.1`. Log: `v2-pins.log`.
- V3 `swift build` -> exit 0. Log: `v3-build.log`.
- V4 `mise run test` -> exit 0. This runs the full `swift test`, including
  both CommandTests version tests and the unchanged digest tests
  (`ArchiveReadTests.swift`, `PersistentAuthCredentialBindingTests.swift`,
  `LinuxPortabilityTests.swift`), plus the smoke tests. Log: `v4-test.log`.
- V5 `mise run lint` -> exit 0. Log: `v5-lint.log`.
- V6 Linux build and test from TASK-003 step 2 -> exit 0, or a recorded gap.
- V7 `git status --porcelain` and `git diff --stat` -> changes appear only in:
  - `Package.swift`
  - `Package.resolved`
  - `VERSION`
  - `Sources/GmailGatewayCore/GmailGatewayUtilities.swift`
  - `Tests/GmailGatewayCoreTests/CommandTests.swift`
  - TASK-003 fix files, if any
  - this plan file
  - `design-docs/specs/notes.md`, only if it is still uncommitted from the
    design step
  - `impl-plans/active/swift-crypto-5-dispatch.json`, only if it is still
    uncommitted from the planning step. The implementer does not edit or move
    this file.
  - nothing under `tmp/`, which is ignored

  Log: `v7-status.log`.

## Progress Log

- 2026-10-27: Plan created from the accepted design note.
  - BLK-1 was open at local checkout 4cfef44.
  - TASK-001 decides whether the plan proceeds or stops.
- 2026-10-27: Revised for review finding F-SC5-001.
  - Added the embedded version constant and the stale CommandTests.swift:53
    literal to the plan.
  - Added a CommandTests baseline step.
  - A blocked stop still makes no version or test edits.
- 2026-10-27: TASK-001 stopped at BLK-1; no implementation or baseline test run.
  - `git ls-remote https://github.com/tacogips/google-service-gateway.git refs/heads/main` exited 0 and returned `b70f4ddcf02f7aee1e6c47fdfc9fb87f37a93ee6`.
  - Read `Package.swift` at that exact commit from `https://raw.githubusercontent.com/tacogips/google-service-gateway/b70f4ddcf02f7aee1e6c47fdfc9fb87f37a93ee6/Package.swift`; retrieval/inspection exited 0.
  - Exact constraint at line 20: `.package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1")`. This permits only 4.5.1..<5.0.0, so it does not meet the required 5.x lower bound.
  - Resume only after `google-service-gateway` main declares a swift-crypto 5.x lower bound; then rerun TASK-001 and record the new SHA and constraint before continuing.
- 2026-10-27: Plan revised for the retry after google-service-gateway v0.1.7.
  - BLK-1 is resolved. The tag `v0.1.7` resolves to
    `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`, confirmed by a design-review
    `git ls-remote` that exited 0. The issue text's `ed020e4f` matches only
    the first 7 characters.
  - The gate now checks that tag, not `refs/heads/main`.
  - The version test now reads VERSION through a `#filePath` path instead of
    using a literal.
  - The implementer does not commit, push, or archive. Finalization and the
    plan-archive step do that.
- 2026-10-27: Revised for plan review finding F-SC5-PLAN-V7-001 (mid).
  - V7 now allows `impl-plans/active/swift-crypto-5-dispatch.json` when it is
    still uncommitted from the planning step.
  - TASK-003 now also records the host and container `swift --version` and
    the swift:6.3 image digest, from the low-severity review note.
- 2026-10-27: Implementation completed against the accepted design and this plan.
  - TASK-001 tag gate: `git ls-remote https://github.com/tacogips/google-service-gateway.git refs/tags/v0.1.7 'refs/tags/v0.1.7^{}'` exited 0; tag SHA is `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`. The fetched upstream manifest declares swift-crypto `from: "5.0.3"` and google-gateway-auth revision `48e0112fb5eb057cf012194cfffaa2581ba29d76`. Logs: `tmp/swift-crypto-5/PLAN-SC5-001/logs/gate-ls-remote.log`, `upstream-Package.swift.txt`.
  - TASK-001 baseline hashes: Package.swift `2c31b79db3042afb98e7f0096728ea0173973f7162e4ec84dd6827e9b10c1108`; Package.resolved `269e8c7494b4ef5441e2b9461286d33729c1874ad5225cd85e4e5bc7b0b028a5`; VERSION `5f30f682ec06500cbc89e949d22b27383646e8e7004b8714841c793a41ce8aec`; GmailGatewayUtilities.swift `930b5d1f95a63fbb1c71f6d8a120945617cd8fb63e95d497fc95e1f0960a4012`; CommandTests.swift `0e189b7d592813f3fbd60401fb931d5c0c4def4699d07b5f1a763d71bb72f67c`.
  - Baseline `swift test --filter CommandTests` exited 1 with 46 tests and one pre-existing failure: `embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile` expected `0.1.26` while the embedded value was `0.1.28`. Log: `tmp/swift-crypto-5/PLAN-SC5-001/logs/baseline-commandtests.log`.
  - swift-crypto 5.0.0 release notes reviewed; SHA256, Digest, and HashFunction APIs are not renamed or removed. The span API adds overloads; the existing `SHA256.hash(data:)` use remains. Log: `tmp/swift-crypto-5/PLAN-SC5-001/logs/swift-crypto-5.0.0-notes.log`.
  - TASK-002 `swift package update swift-crypto google-service-gateway` exited 0. Package.swift now requires swift-crypto from 5.0.3 and pins google-service-gateway to the full v0.1.7 SHA. Package.resolved changed only originHash, google-service-gateway, and swift-crypto; swift-asn1 remained 1.7.3. swift-crypto resolves to 5.0.3. gateway-sdk-kit 0.1.1 and google-gateway-auth revision 48e0112f remain unchanged. Logs: `tmp/swift-crypto-5/PLAN-SC5-001/logs/package-update.log`, `v1-resolve.log`, `v2-pins.log`, `resolved-diff.log`.
  - Upstream source diff changes the public `Version.current` value, but GmailGatewayCore has no use of that symbol. Its used credential-store types and APIs are unchanged. Log: `tmp/swift-crypto-5/PLAN-SC5-001/logs/upstream-diff.log`.
  - TASK-003 final macOS `swift build` exited 0. No SHA256, Crypto, or deprecation warnings matched in the final build log. No crypto call site or digest expectation changed. Logs: `tmp/swift-crypto-5/PLAN-SC5-001/logs/final-build.log`, `final-build-crypto-warning-search.log`.
  - Linux verification gap: Docker invocation exited 125 because the daemon failed to write its containerd metadata database (`input/output error`) and the image was unavailable. The documented `container run` fallback reached image fetch/unpack, then exited 1 with `No space left on device` while unpacking the 3.7 GB image; no Linux build or tests started. Image index digest: `sha256:c2f3ac2eb806ce43f68859c3d52bd3bb1cfc88672fb3a948b76e136d98e39278`; image metadata declares Swift 6.3.3. Host Swift: 6.3.3. Logs: `tmp/swift-crypto-5/PLAN-SC5-001/logs/linux-build-test.log`, `linux-container-build-test.log`, `container-image-inspect.log`, `host-swift-version.log`.
  - TASK-004 changed VERSION and the embedded version to 0.1.29. The test now reads VERSION from a three-parent `#filePath`-anchored URL and has no version literal. Filtered CommandTests passed 46/46. `mise run test` exited 0 with 185 tests in 8 suites and the Swift smoke tests passed. Changed-file `swiftlint lint --strict --quiet --no-cache` exited 0. `mise run lint` exited 0; it reported five warnings in untouched baseline files (three Statement Position warnings in GmailOAuthBootstrap.swift, one trailing-newline warning in GmailGatewayCLIHelp.swift, and one type-body-length warning in GmailRequestProtocolTests.swift). Logs: `tmp/swift-crypto-5/PLAN-SC5-001/logs/commandtests-after.log`, `v4-test.log`, `changed-files-swiftlint.log`, `v5-lint.log`.
  - Stale-version search returned no matches (grep exit 1, expected). Final source hashes: Package.swift `4793b5694fd76ad30b7fdb7f2f42849a3d516bdbd9068760dc13274c867b37b2`; Package.resolved `f8521d9cde8c740f20152fcb87981f2ebbf21dc273e108444c6a314bd3f5f21e`; VERSION `04fa6fd3d0e24d0cf4a85675f94b78ab88c4b469dd242527632da6d864eaf932`; GmailGatewayUtilities.swift `74db523ae9ae971f07e01cc93280f23c2829a645d836718bc5e78bebf71b96c1`; CommandTests.swift `02446fa2cd3708ce710b6bc8a085a5640c37fa652bb32e094d9a15171728d1a8`.
  - The implementation did not edit design notes, the dispatch manifest, or other plan files; it did not commit, push, or archive. Finalization and plan archival remain downstream workflow steps.
  - TASK-005 V7: `git status --porcelain` and `git diff --stat` both exited 0. The status lists only Package.swift, Package.resolved, VERSION, GmailGatewayUtilities.swift, CommandTests.swift, and this plan. The change summary is 6 files, 45 insertions, and 24 deletions. Logs: `tmp/swift-crypto-5/PLAN-SC5-001/logs/v7-status.log`, `v7-diff-stat.log`.
