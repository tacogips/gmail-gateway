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
