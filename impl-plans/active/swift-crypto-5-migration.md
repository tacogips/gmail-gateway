# swift-crypto 5.x Migration

**Status**: In Progress
**Plan ID**: PLAN-SC5-001
**Depends On**: none (gated by upstream blocker BLK-1)
**Design Reference**: `design-docs/specs/notes.md#swift-crypto-5x-migration-2026-10-27`
**Issue**: workflowInput "gmail-gateway: move to swift-crypto 5.x" (no URL or number)

## Purpose

The owner wants every Swift package in the Riela dependency graph to require
apple/swift-crypto 5.x, so that Riela resolves a single 5.x version. In this
repository that means:

- Package.swift requires
  `.package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3")`.
- Package.resolved pins swift-crypto 5.x.
- Behavior does not change. Every SHA-256 output stays byte-for-byte identical.
- VERSION goes from `0.1.28` to `0.1.29`.
- The result is committed and pushed to `origin/main`.

## Repository Context

- `Package.swift:20` currently has swift-crypto `from: "4.5.2"`.
- `Package.swift:23` pins google-service-gateway at revision
  `4cfef44b245893e6de4f30780c70fb0314da70eb`.
- `Package.swift:21` pins google-gateway-auth at revision
  `48e0112fb5eb057cf012194cfffaa2581ba29d76`.
- `Package.swift:22` pins gateway-sdk-kit with `exact: "0.1.1"`.
- The swift-crypto `Crypto` product is linked only on Linux:
  `Package.swift:31`, `condition: .when(platforms: [.linux])`.
- Each of the five source files below uses
  `#if canImport(CryptoKit) import CryptoKit #else import Crypto`. The only
  crypto API used is `SHA256.hash(data:)`:
  - `Sources/GmailGatewayCore/GmailOAuthClientFingerprint.swift:18`
  - `Sources/GmailGatewayCore/GmailArchiveReads.swift:142` (`archiveSHA256`)
  - `Sources/GmailGatewayCore/MessageFileDownloads.swift:518`
    (`attachmentStorageFilenamePrefix(attachmentId:)`)
  - `Sources/GmailGatewayCore/GmailOAuthBootstrap.swift:772` (`codeChallenge(for:)`)
  - `Sources/GmailGatewayCore/GmailCredentialResolution.swift` imports the
    module only and calls no crypto API.
- Blocker BLK-1: at revision 4cfef44, `google-service-gateway/Package.swift:20`
  declares `.package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1")`.
  That allows only `4.5.1..<5.0.0`.
- The version appears in two places, and bump commits (for example bb9ddfb)
  change both:
  - `VERSION`, currently `0.1.28`
  - the `gmailGatewayVersion()` literal at
    `Sources/GmailGatewayCore/GmailGatewayUtilities.swift:5`, currently `"0.1.28"`
- Two tests in `Tests/GmailGatewayCoreTests/CommandTests.swift` check the version:
  - `versionFlagReturnsVersionForAllBinaries` (lines 43-49) requires the
    `--version` output to equal the VERSION file.
  - `embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile` (line 53)
    still expects the stale `"0.1.26"`, so it is expected to fail at HEAD.
- Verification tasks live in `mise.toml`:
  - `build` runs `swift build`.
  - `test` runs `swift test` and then `swift run gmail-gateway-swift-smoke-tests`.
  - `lint` runs `swiftlint`.
  - There is no Linux task.

## Non-Goals

- Do not fork, vendor, path-override, or remove google-service-gateway.
- Do not add `.package(path:)` or a mirror config to get past BLK-1.
- Do not change pin styles. Do not change gateway-sdk-kit.
- Do not refactor the `#if canImport(CryptoKit)` pattern.
- Do not remove the unused import in `GmailCredentialResolution.swift`.
- Do not add new crypto helpers.
- Do not change any expected digest value in tests.
- Do not delete, skip, or weaken any version test.
- Do not make `gmailGatewayVersion()` read the VERSION file at runtime. It must
  keep returning an embedded literal.
- Do not add version-generation scripts or build steps.
- Do not edit `design-docs/specs/architecture.md`. Its stale "0.1.1" text is
  out of scope.
- Do not publish a GitHub release. Do not run `build:homebrew`,
  `homebrew:formula`, or `homebrew:tap-formula`. Do not edit `Formula/` or
  `dist/`.
- Do not edit `impl-plans/PROGRESS.json` or any other plan file.

## Invariants

- SHA-256 output is unchanged:
  - Lowercase hex via `String(format: "%02x", $0)` for the fingerprint,
    the archive sha256, and the attachment filename prefix.
  - base64url for PKCE.
- On macOS the code keeps compiling against CryptoKit.
- `Crypto` stays linked only on Linux.
- Every Swift file stays under 1000 lines.
- Commit messages contain no AI attribution.

## Tasks

### TASK-001: Gate on BLK-1 (must run first; stop if it fails)

**Parallelizable**: No

1. Run `git ls-remote https://github.com/tacogips/google-service-gateway.git refs/heads/main`
   and record the SHA.
2. Read that commit's `Package.swift` swift-crypto requirement. Use whichever
   of these works:
   - `../google-service-gateway` after `git fetch`, using `git show <sha>:Package.swift`
   - a temporary clone in a new empty directory
     `tmp/swift-crypto-5/upstream-gsg`, without building it there
3. If the requirement is not a 5.x lower bound such as `from: "5.0.3"` or
   `"5.0.0"..<"6.0.0"`:
   - Stop and make no repository edits.
   - Report BLK-1 with the SHA and the exact constraint line.
   - The Progress Log entry is the only file change allowed.
4. If the requirement is 5.x, record the SHA as `GSG_NEW`.
5. Also record that commit's google-gateway-auth `revision:` value as
   `GGA_UPSTREAM`.
6. Run the baseline. Only on the pass path, and before any TASK-002 edit, run
   `swift test --filter CommandTests` once.
   - Log it to `tmp/swift-crypto-5/baseline-test.log`.
   - Record the exit code and the names of any failing tests in the Progress
     Log.
   - The `0.1.26` assertion at CommandTests.swift:53 is expected to fail.
     Record it as a pre-existing failure, not one caused by the migration.

**Completion Criteria**:

- [ ] The upstream SHA and its swift-crypto constraint line are recorded in
  the Progress Log.
- [ ] On the pass path, the baseline CommandTests exit code and failing test
  names are recorded.
- [ ] Either a blocked stop is reported, or `GSG_NEW` and `GGA_UPSTREAM` are
  recorded.

### TASK-002: Manifest and resolution (after TASK-001 passes)

**Parallelizable**: No

1. Take a sha256 of `Package.swift` and `Package.resolved` before editing.
2. Edit `Package.swift`:
   - Line 20 becomes `from: "5.0.3"`.
   - Line 23's `revision:` value becomes `GSG_NEW`.
   - Line 21's `revision:` value changes only if `GGA_UPSTREAM` differs from
     `48e0112…`. In that case set it to `GGA_UPSTREAM` and log why: SwiftPM
     requires identical revisions for the same package.
   - Change nothing else.
3. Run `swift package update swift-crypto google-service-gateway`. Add
   `google-gateway-auth` only if line 21 changed.
   - Pitfall: a plain `swift package update` with no arguments can move other
     pins. Do not use it.
4. Confirm `Package.resolved`:
   - swift-crypto `version` starts with `5.`.
   - google-service-gateway `revision` equals `GSG_NEW`.
   - gateway-sdk-kit is still `0.1.1`.
   - Record the swift-asn1 version.
5. Run `git diff GSG_OLD..GSG_NEW` (where `GSG_OLD` is `4cfef44`) in the
   upstream checkout, limited to `Sources/GoogleServiceGatewayCore`. Log any
   public API changes that gmail-gateway uses.
   - Uses to check: `SecureCredentialStore`, `KeychainCredentialStore`, and
     anything imported by `Sources/GmailGatewayCore`.

**Completion Criteria**:

- [ ] `grep -n 'swift-crypto' Package.swift` shows `from: "5.0.3"`.
- [ ] The Package.resolved swift-crypto version is `5.x.y`.
- [ ] The google-service-gateway revision equals `GSG_NEW`.

### TASK-003: Compile fixes with no behavior change

**Parallelizable**: No

1. Run `swift build`.
2. Build on Linux as well (see Verification V6). On macOS swift-crypto is not
   compiled into GmailGatewayCore, so errors from swift-crypto 5 appear only
   on Linux.
3. Fix errors and deprecation warnings only in the five files listed in
   Repository Context.
   - Apply the smallest API substitution that produces the same digest bytes.
   - Pitfalls:
     - Do not switch to a different hash or encoding.
     - Do not change the `%02x` formatting.
     - Do not change the PKCE base64url padding behavior.
4. If google-service-gateway API changes break other GmailGatewayCore files,
   fix them only at the call sites, keep their behavior the same, and log each
   change.

**Completion Criteria**:

- [ ] `swift build` exits 0.
- [ ] The build log shows no new warnings that mention swift-crypto or SHA256.

### TASK-004: VERSION bump, verification, commit, push

**Parallelizable**: No

1. Bump the version in three places. Change only the string literals:
   - `VERSION`: `0.1.28` to `0.1.29`. Keep it a single line with a trailing
     newline, matching the current file.
   - `Sources/GmailGatewayCore/GmailGatewayUtilities.swift:5`: the
     `gmailGatewayVersion()` literal goes from `"0.1.28"` to `"0.1.29"`.
   - `Tests/GmailGatewayCoreTests/CommandTests.swift:53`: the expected literal
     goes from `"0.1.26"` to `"0.1.29"`, because the embedded value must equal
     VERSION.
   - Then run `swift test --filter CommandTests`. It must exit 0.
   - Then run `grep -rn '0\.1\.28' Sources Tests VERSION`. It must print
     nothing.
2. Run V1 through V7.
3. Stage only:
   - `Package.swift`
   - `Package.resolved`
   - `VERSION`
   - `Sources/GmailGatewayCore/GmailGatewayUtilities.swift`
   - `Tests/GmailGatewayCoreTests/CommandTests.swift`
   - any changed files from TASK-003
   - this plan file
   - the committed design note, if it is not already committed
4. Commit with a structured message following the AGENTS.md commit policy.
   Include no AI attribution.
5. Run `git push origin main`.

**Completion Criteria**:

- [ ] V1 through V5 and V7 exit 0, or show the expected output.
- [ ] V6 passed, or is logged as a verification gap.
- [ ] `gmailGatewayVersion()` returns `"0.1.29"`.
- [ ] `versionFlagReturnsVersionForAllBinaries` passes.
- [ ] `embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile` passes.
- [ ] `git log origin/main -1` equals the local HEAD.

## Test Cases (existing tests are the oracle; the only allowed test edit is the version literal at CommandTests.swift:53)

- After TASK-004, `swift test --filter CommandTests` -> both version tests
  pass with `0.1.29`.

- Existing fingerprint, archive sha256, and attachment-prefix tests in
  `Tests/GmailGatewayCoreTests` pass with unchanged expected values. Examples:
  - `ArchiveReadTests.swift`
  - `PersistentAuthCredentialBindingTests.swift`
  - `LinuxPortabilityTests.swift`
- If TASK-003 changes a digest call site, add one known-answer assertion for
  that function: `SHA256("abc")` hex ->
  `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
  Put it in the existing test file for that feature.

## Verification

Every command's full output goes to `tmp/swift-crypto-5/<name>.log`. Record
each exit code in the Progress Log.

- V1 `swift package resolve` must exit 0.
- V2 `python3 -I -c "import json;print([p for p in json.load(open('Package.resolved'))['pins'] if p['identity'] in ('swift-crypto','swift-asn1','google-service-gateway','google-gateway-auth','gateway-sdk-kit')])"`
  must show swift-crypto `5.x`.
- V3 `swift build` must exit 0.
- V4 `mise run test` must exit 0. This runs `swift test` and the smoke tests.
- V5 `mise run lint` must exit 0.
- V6 Linux build and test with `--scratch-path .build-linux`. Use whichever is
  available:
  - a Swift 6.x Linux container, for example
    `swift build && swift test` with `--scratch-path .build-linux`
  - another Linux host
  If neither can run, log a verification gap. A gap does not count as passing.
- V7 `git diff --stat origin/main..HEAD` must show only the files listed in
  TASK-004 step 3, including `GmailGatewayUtilities.swift` and
  `CommandTests.swift`.

## Progress Log

- 2026-10-27: Plan created from the accepted design note.
  - BLK-1 was open at local checkout 4cfef44.
  - TASK-001 decides whether the plan proceeds or stops.
- 2026-10-27: Revised for review finding F-SC5-001.
  - Added the embedded version constant and the stale CommandTests.swift:53
    literal to the plan.
  - Added a CommandTests baseline step.
  - A blocked stop still makes no version or test edits.
