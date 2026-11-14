# Persistent Auth Review Hardening Implementation Plan

**Status**: Completed
**Design Reference**: `design-docs/specs/design-persistent-auth-commands.md`
**Created**: 2026-09-04
**Last Updated**: 2026-09-05

## Summary

Close review findings in the initial persistent-auth implementation: prove the
source matrix, enforce lifecycle coherence before mutation, support explicit
legacy upgrades, secure concurrent file/vault mutation, preserve GraphQL error
contracts, and prevent secrets from reaching output.

## Scope

Included: reader, sender, and draft persistent auth; exact source provenance;
credential/client/token coherence; legacy-token upgrade; secure lifecycle
mutation; redaction; regression and repository verification.

Excluded: a writer product, persistent auth for threads/message-box, remote
revocation, automatic migration, new persistence backends, and live credentials.

## Reference Traceability

| Reference | Reused | Intentional divergence |
| --- | --- | --- |
| `google-documents-gateway` | Immutable role, PKCE, exact scopes, atomic token files, redacted status, confirmed revoke | Gmail supports independent client/token precedence and secure client setup |
| `google-service-gateway` `0.1.1` | Injectable secure store and production Keychain boundary | Gmail owns record schema, namespace, fingerprints, and commands |

## Findings And Closure

| Finding | Closure | Evidence |
| --- | --- | --- |
| Cross-source precedence/coherence was incompletely exercised | Table-driven client/token source matrix through ordinary commands; invalid selected sources never fall through | `PersistentAuthCrossSourceMatrixTests.swift`, `PersistentAuthSourceMatrixTests.swift` |
| Legacy token lifecycle was incomplete | Writable legacy files report unknown/auth-required, then explicit login upgrades the same destination; inline legacy data remains immutable | `PersistentAuthLegacyUpgradeTests.swift` |
| Lifecycle mutation could target a different effective client/token | Validate identity, access mode, scopes, principal, and fingerprint before login/revoke/refresh mutation | `PersistentAuthLifecycleCoherenceTests.swift`, `PersistentAuthCoherenceTests.swift` |
| Concurrent lifecycle operations could publish stale state | Stable per-user OS locks, vault revisions, file identities, and conditional commits | concurrency and subprocess suites |
| File transactions were vulnerable to symlink/TOCTOU/crash states | Descriptor-relative no-follow traversal, private modes, quarantine identities, atomic durable journals, fail-closed recovery | adversarial and crash-safety suites |
| Callback/provider failures could leak secrets or alter GraphQL envelopes | State-first callback checks, structured GraphQL errors, centralized redaction, invalid-metadata suppression | output/provider redaction and GraphQL side-effect suites |

## Tasks

### TASK-001: Lifecycle coherence and mutation safety

**Status**: Completed

- [x] Guard every writable file and vault mutation with selected-client/token coherence.
- [x] Serialize refresh/revoke and setup/login at a stable cross-process boundary.
- [x] Reject leaf, parent, lock-namespace, and replacement symlink substitution.
- [x] Use identity-checked quarantine, publish, restore, revoke, and durable recovery journals.
- [x] Keep inline-token precedence free of lower-priority recovery side effects.

### TASK-002: Source matrix and precedence

**Status**: Completed

- [x] Cover environment JSON/path, TOML path, relocated path, vault, and synthesized defaults.
- [x] Assert coherent provenance and reject mismatches before refresh or Gmail transport.
- [x] Preserve exact vault-before-synthesized-file and explicit-source precedence.
- [x] Validate mixed `read`/`read_send` Keychain-only configurations.

### TASK-003: Legacy upgrade behavior

**Status**: Completed

- [x] Cover missing scope, fingerprint, and credential-binding metadata.
- [x] Require explicit re-login for legacy persistent tokens.
- [x] Upgrade the same writable destination and prove ordinary provider use afterward.
- [x] Keep inline legacy input immutable and return removal guidance.

### TASK-004: GraphQL, callback, and redaction behavior

**Status**: Completed

- [x] Preserve GraphQL error envelopes during persistent hydration failures.
- [x] Validate OAuth callback state before provider errors and redact URLs/messages.
- [x] Suppress untrusted token metadata for invalid or scope-mismatched records.
- [x] Prove login failures do not persist partial credentials.

### TASK-005: Integrated verification and compatibility

**Status**: Completed

- [x] Reader, sender, and draft retain fixed access modes; no writer exists.
- [x] Threads/message-box retain legacy concurrent atomic writes and parent permissions.
- [x] Docs and completed-plan indexes are synchronized.
- [x] Focused and full test/lint/build gates pass.

## Verification Evidence

- 273 tests discovered; all passed.
- Persistent auth focused suites cover lifecycle concurrency/subprocess behavior,
  config validation, source matrices, journal crash safety, redirect semantics,
  credential binding, isolation, legacy upgrade, and output redaction.
- `mise run test`, `mise run lint`, and `mise run build` passed; lint reported
  zero violations.
- CLI help and package-product assertions passed.
- Plan JSON and diff checks passed.

## Progress Log

- 2026-09-04: Closed initial source-matrix, legacy-upgrade, and lifecycle-coherence findings.
- 2026-09-04: Added file/vault concurrency, journal, redirect, GraphQL, and redaction hardening.
- 2026-09-05: Preserved excluded legacy writer behavior, completed mixed-mode and
  credential-binding regressions, and passed all gates.
