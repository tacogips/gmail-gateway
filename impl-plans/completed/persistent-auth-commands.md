# Persistent Auth Commands Implementation Plan

**Status**: Completed
**Design Reference**: `design-docs/specs/design-persistent-auth-commands.md`
**Created**: 2026-09-04
**Last Updated**: 2026-09-05

## Summary

Add `auth setup`, `auth login`, `auth status`, and confirmed local
`auth revoke` to `gmail-gateway-reader`, `gmail-gateway-sender`, and
`gmail-gateway-draft`. Store normalized Desktop OAuth clients and tokens in
Gmail-specific Keychain records through `GoogleServiceGatewayCore`, so normal
commands work without credential environment variables after setup and login.

Persistent auth is intentionally excluded from `gmail-gateway-threads` and
`gmail-gateway-message-box`. No `gmail-gateway-writer` product is introduced.

## Reference Decisions

| Reference | Adopted behavior | Gmail-specific decision |
| --- | --- | --- |
| `/Users/taco/gits/tacogips/google-documents-gateway` | Per-executable role, PKCE, exact scopes, atomic legacy files, redacted status, confirmed revoke, XDG defaults | Add secure client setup and enable persistent auth on exactly reader, sender, and draft |
| `/Users/taco/gits/tacogips/google-service-gateway` `0.1.1` | `SecureCredentialStore`, production `KeychainCredentialStore`, injectable test stores, device-only Keychain accessibility | Own the Gmail envelope, account keys, namespace, fingerprints, and lifecycle coordinator |

## Delivered Architecture

- `GmailAuthPolicy` binds reader to `read` and sender/draft to `read_send`.
- `GmailCredentialVault` stores one versioned client/token profile per provider,
  credential ID, and access mode in `com.tacogips.gmail-gateway`.
- `GmailCredentialResolution` preserves explicit environment/file precedence,
  tracks provenance, and falls back to the exact Keychain profile only where
  the design permits.
- OAuth clients are validated as installed Desktop clients and fingerprinted
  with canonical secret-free data.
- Current token records are bound to schema version, provider, credential ID,
  access mode, exact scopes, principal, and client fingerprint.
- `GmailAuthCoordinator` owns setup, login, status, revoke, refresh, validation,
  and hydration for persistent flows.
- Persistent file mutations use no-follow traversal, per-credential process
  locks, conditional identity checks, durable operation-aware journals, and
  crash recovery. Excluded executables retain the legacy atomic writer.
- Loopback OAuth preserves the registered IPv4, IPv6, or localhost host, path,
  and fixed/dynamic port contract.

## Tasks

### TASK-001: Secure-store dependency and Gmail vault

**Status**: Completed
**Deliverables**: `Package.swift`, `Package.resolved`, `GmailCredentialVault.swift`

- [x] Pin `google-service-gateway` exactly to `0.1.1` and link only `GoogleServiceGatewayCore`.
- [x] Use Gmail-owned versioned envelopes and deterministic per-credential account keys.
- [x] Normalize and validate stored clients and reject incoherent profiles.

### TASK-002: Policy and provenance-aware resolution

**Status**: Completed
**Deliverables**: `GmailPersistentAuthPolicy.swift`, `GmailCredentialResolution.swift`, `ConfigLoading.swift`

- [x] Fix reader/sender/draft access modes and preserve legacy defaults for other callers.
- [x] Implement explicit-source precedence without fallback after invalid selected input.
- [x] Support exact Keychain-only validation and mixed access-mode configurations.

### TASK-003: OAuth client setup and callback flow

**Status**: Completed
**Deliverables**: `GmailOAuthClientProfile.swift`, `GmailOAuthClientFingerprint.swift`, `GmailOAuthBootstrap.swift`

- [x] Validate Desktop clients, Google endpoints, and stored loopback redirects.
- [x] Preserve first-stored redirect order and IPv4/IPv6/localhost semantics.
- [x] Use PKCE and validate callback state before processing provider errors.

### TASK-004: Credential lifecycle and secure persistence

**Status**: Completed
**Deliverables**: coordinator, vault, token security, status/doctor integration

- [x] Implement setup/login/status/revoke and transparent refresh.
- [x] Bind tokens to credential identity and reject legacy/mismatched records before provider use.
- [x] Serialize lifecycle operations across processes and make file recovery fail closed.
- [x] Redact provider errors and invalid token-controlled metadata.

### TASK-005: CLI, compatibility, tests, and documentation

**Status**: Completed
**Deliverables**: CLI target mains, README, release notes, SwiftPM tests and smoke tests

- [x] Expose identical auth commands in reader, sender, and draft only.
- [x] Preserve legacy environment/file behavior and excluded executable behavior.
- [x] Document setup, login, status, revoke, source precedence, and migration.
- [x] Verify no writer product exists.

## Completion Evidence

- `swift test list`: 273 tests discovered across both Swift test frameworks.
- `swift test`: all discovered tests passed.
- `mise run test`: SwiftPM and smoke tests passed.
- `mise run lint`: passed with zero violations.
- `mise run build`: passed.
- Reader, sender, and draft `--help`: passed.
- Package-product assertion: reader/sender/draft present and writer absent.
- `jq empty impl-plans/PROGRESS.json` and `git diff --check`: passed.

Live Google OAuth and developer Keychain access are intentionally excluded from
automated verification; injected stores, transports, browsers, resolvers, and
fault hooks cover the production boundaries deterministically.

## Progress Log

- 2026-09-04: Designed and implemented the initial persistent-auth surface.
- 2026-09-04: Integrated the pinned secure-store dependency and completed CLI,
  persistence, migration, redaction, and compatibility coverage.
- 2026-09-05: Incorporated review and adversarial hardening recorded in the two
  companion completed plans; all repository gates passed.
