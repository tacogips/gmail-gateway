# Notes

Use this file for design notes that are not ready to become a dedicated
specification.

## Implementation and Specification Review (2026-07)

A full review of the implementation against the specs identified functional
defects (body downloads unreachable, GraphQL variables discarded, no
pagination), spec/implementation divergences, MIME construction issues, OAuth
callback robustness gaps, and performance problems. Details and prioritized
recommendations:
[design-implementation-review-2026-07.md](./design-implementation-review-2026-07.md).
Decisions requiring user input:
`design-docs/user-qa/qa-implementation-review-2026-07.md`.

## Gateway credential-state audit (2026-09-10)

Scope: the 18 root `*-gateway` Git repositories under the sibling checkout
directory; worktree copies are not separate products. This is a token-storage
audit, not a migration of all mutable application data or explicitly configured files.

| Repositories | Authoritative source / result |
| --- | --- |
| gmail-gateway | `ConfigLoading.swift`, `GmailCredentialResolution.swift`: existing XDG state default; historical implicit config `tokens/gmail-personal.json` needs safe migration; secure vault remains preferred. |
| calendar-gateway | `ConfigLoading.swift`, `GoogleCalendarOAuthSupport.swift`: existing state default; historical implicit `tokens/google-personal.json` needs safe migration. |
| google-documents-gateway | `GatewayCredentials.swift`, `GatewayRuntime.swift`: existing state default; historical config `tokens/<profile>.json` needs safe migration. |
| google-analytics-gateway | `Auth/CredentialProfiles.swift`, `CLI/ProfileSelection.swift`: OAuth files require explicit `tokenStorePath`; synthesized fallback is environment-only. Preserve explicit paths. |
| google-marketing-gateway | `CredentialProfiles.swift`, `ReaderAuthService.swift`: installed OAuth requires explicit client and token-store paths. Preserve explicit paths. |
| wrike-gateway, x-gateway | `CLI/GatewayComposition.swift` / `XGatewayOAuth2.swift`: persistent credentials use kinko, not a gateway-owned config token file. |
| google-service-gateway | `CredentialStore.swift`: OAuth vault uses OS Keychain. |
| instagram-gateway, line-business-gateway, meta-marketing-gateway, resend-gateway, tiktok-business-gateway | Credential resolver implementations use kinko references or injected environment values, without a default mutable token file. |
| thread-gateway | `CLI.swift`: token exchange results are not persisted; environment/CLI credentials. |
| agent-gateway, s3-gateway, web-gateway | Provider credential injection/configured references; no gateway-owned default mutable OAuth token store. |
| apple-gateway | OS authorization rather than OAuth token persistence. Download-key material is cache data, not an OAuth credential store. |

For the three file-default implementations, valid absolute XDG state/config
overrides select the respective roots; empty or relative values are ignored.
Explicit token file paths, directory overrides, inline JSON, kinko and Keychain
are not relocated. Migration must never overwrite a state token or reselect an
old token after revoke. A durable completion marker permits retaining a legacy
recovery copy without using the configuration directory for future token refreshes.
New token and migration files are private (`0600`), with private token directories
(`0700`), descriptor-anchored path operations, and atomic token publication.

The installed all-Codex Riela workflow was validated and attempted, but its manager
recursively launched the same workflow and concurrent launches collided on a session
ID. Those exact processes were stopped before repository writes. Implementation
continued with scoped agents and independent cross-review; no Riela source, package,
or unrelated running workflow was modified. Release acceptance still requires full
tests, SwiftLint, macOS archives, Calendar notarization, Homebrew tests/audit, and
published API metadata verification. Nix checks are unavailable: this checkout has
no flake/package definitions and the local `nix` executable is absent.

## swift-crypto 5.x migration (2026-10-27)

Goal: Package.swift requires
`.package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3")` and
Package.resolved pins swift-crypto 5.x, so the Riela dependency graph resolves
one 5.x version. No behavior change.

Scope:

- The only swift-crypto use is `SHA256.hash(data:)`, in
  `GmailOAuthClientFingerprint.swift`, `GmailArchiveReads.swift`
  (`archiveSHA256`), `MessageFileDownloads.swift`
  (`attachmentStorageFilenamePrefix`), and `GmailOAuthBootstrap.swift`
  (PKCE `codeChallenge`). `GmailCredentialResolution.swift` imports the module
  but calls no crypto API. The `Crypto` product is linked only on Linux. macOS
  builds use CryptoKit, so only a Linux build compiles against swift-crypto.
- Digest output (lowercase hex, or base64url for PKCE) must stay byte-for-byte
  identical. The existing tests in `Tests/GmailGatewayCoreTests` are the oracle,
  and no expected value may change.
- Do not change the other pin styles: gateway-sdk-kit `exact: "0.1.1"`,
  google-gateway-auth by `revision:`. Neither package has dependencies.
- VERSION goes from `0.1.28` to `0.1.29` in the same final commit. The
  `gmailGatewayVersion()` literal in `GmailGatewayUtilities.swift` changes with
  it, as earlier bump commits did. It stays an embedded literal and never reads
  VERSION at runtime. This repo's `swift-tools-version: 6.0` does not change.
  Push to `origin/main`. Do not publish a GitHub release or a Homebrew
  formula/tap.

Ordering gate BLK-1 (resolved 2026-10-27): the old pin
`4cfef44b245893e6de4f30780c70fb0314da70eb` declared swift-crypto
`from: "4.5.1"`, which capped it below 5.0.0. Tag `v0.1.7` of
google-service-gateway is commit `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`.
`git ls-remote` gives that full SHA. The issue text says `ed020e4f`; the first
seven characters match and the full tag SHA is authoritative. At that commit,
`Package.swift:20` declares swift-crypto `from: "5.0.3"`, and google-gateway-auth
is pinned at `revision: "48e0112fb5eb057cf012194cfffaa2581ba29d76"`, which is
the same pin as gmail-gateway. gmail-gateway changes only the
google-service-gateway `revision:` value to the full tag SHA. The
google-gateway-auth and gateway-sdk-kit pins stay as they are. The no-workaround
rule still holds: no fork, path or mirror override, vendoring, or dropping a
dependency. If resolution shows any dependency capping swift-crypto below 5,
stop and report the exact constraint line.

Version test rule: `embeddedVersionDoesNotDependOnAWorkingDirectoryVersionFile`
(`Tests/GmailGatewayCoreTests/CommandTests.swift:53`) hard-codes a stale
`"0.1.26"` and fails at HEAD. Its expected value must not be another version
literal. The test reads the repository's `VERSION` file through a path built
from `#filePath`, the same way `PersistentAuthLifecycleSubprocessTests.swift`
does, and never through the working directory. It trims the value with
`nonBlank` and requires `gmailGatewayVersion()` to equal it. Every later bump
then only needs VERSION and the source literal to agree.
`versionFlagReturnsVersionForAllBinaries` is not changed.

Steps:

1. Edit both manifest lines: swift-crypto becomes `from: "5.0.3"`, and the
   google-service-gateway revision becomes `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`.
2. Run `swift package update swift-crypto google-service-gateway`. Never run a
   bare `swift package update`. The Package.resolved diff may touch only
   swift-crypto, its transitive swift-asn1, and google-service-gateway.
3. Confirm swift-crypto resolves to 5.x and record the swift-asn1 pin.
4. Review the upstream `4cfef44..ed020e4a` diff for public API changes used by
   `GmailGatewayCore`, and fix any affected call sites without changing behavior.
5. Fix any compile errors or deprecations from swift-crypto 5 without changing
   the digest format. The only API used is `SHA256.hash(data:)`.
6. Apply the version bump and the version test rule.
7. Run `swift build`, the full `swift test` (through `mise run test`), and
   `mise run lint`. Also run a Linux build and test that compiles the
   `import Crypto` paths. If the Linux check cannot run, report it as a
   verification gap backed by reviewing the swift-crypto 5.0.0 release notes
   for `SHA256`. Do not count it as passing.

The plan `impl-plans/active/swift-crypto-5-migration.md` and its dispatch
manifest `impl-plans/active/swift-crypto-5-dispatch.json` move to
`impl-plans/completed/` together in the final commit.
