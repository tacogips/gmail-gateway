# Persistent Auth Accepted-Design Closure

**Status**: Completed
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `workflow-input:Add persistent auth commands to all gmail-gateway executables`
**Design Reference**: `design-docs/specs/design-persistent-auth-commands.md`
**Created**: 2026-09-04
**Last Updated**: 2026-09-05

## Purpose And Scope

Close all implementation, independent-review, and adversarial-review findings
against the accepted persistent-auth design. Persistent auth applies only to
`gmail-gateway-reader`, `gmail-gateway-sender`, and `gmail-gateway-draft`.

Excluded: `gmail-gateway-writer`, persistent auth changes for threads or
message-box, remote token revocation, automatic migration, new storage
backends, and live Google credential tests.

## Design And Reference Traceability

- `design-docs/specs/design-persistent-auth-commands.md`
- `design-docs/specs/architecture.md#persistent-auth-boundary`
- `design-docs/specs/command.md#auth`
- `design-docs/specs/command.md#config`
- `design-docs/references/README.md#local-behavioral-references`

| Reference | Adopted | Gmail-specific choice |
| --- | --- | --- |
| `/Users/taco/gits/tacogips/google-documents-gateway` | Per-executable roles, PKCE, exact scopes, atomic legacy files, redacted status, confirmed revoke | Store clients and tokens securely and preserve registered IPv4/IPv6/localhost redirects |
| `/Users/taco/gits/tacogips/google-service-gateway` `0.1.1` | Secure-store protocol, Keychain implementation, injected tests, device-only accessibility | Gmail-owned envelope, lock/journal policy, and namespace |

## Closure Matrix

| Area | Completed behavior | Primary evidence |
| --- | --- | --- |
| Lifecycle serialization | Independent coordinators and processes share one private no-follow OS lock per credential/access mode | concurrency and subprocess suites |
| File mutation safety | Descriptor-relative identity checks reject symlinks and stale destinations | adversarial and lifecycle suites |
| Config validation | One immutable snapshot; explicit sources fully parsed; exact vault checked before synthesized files; mixed modes supported | `PersistentAuthConfigValidationTests.swift` |
| Journal durability | Complete fsynced atomic generations identify replacement/revocation and candidate identity; ambiguity fails closed | `PersistentAuthJournalCrashSafetyTests.swift` |
| Redirect semantics | First stored redirect wins; IPv4, IPv6, localhost, paths, and fixed/dynamic ports are preserved; partial binds clean up before browser activity | `PersistentAuthRedirectSemanticsTests.swift` |
| Credential binding | Current file/environment tokens include schema, provider, and credential ID; legacy metadata requires re-login | `PersistentAuthCredentialBindingTests.swift`, legacy tests |
| Output safety | Provider errors, OAuth URLs, and invalid token-controlled metadata are redacted | output/provider redaction tests |
| Compatibility | Reader=`read`; sender/draft=`read_send`; threads/message-box retain legacy writer behavior; no writer product | isolation, command, package checks |

## Tasks

### TASK-001: Production lifecycle serialization and symlink safety

**Status**: Completed

- [x] Lock before resolving mutable client/token/revision/file identity.
- [x] Prove both refresh/revoke orderings and setup/login contention.
- [x] Prove separate processes contend through the production lock boundary.
- [x] Reject mutation-time substitution without touching the symlink target.
- [x] Bound test waits so regressions fail rather than hang.

### TASK-002: Exact persistent config validation

**Status**: Completed

- [x] Parse selected inline JSON and environment/TOML paths with the production client loader.
- [x] Use one loaded configuration snapshot throughout validation.
- [x] Query the exact provider/credential/access-mode vault profile.
- [x] Preserve explicit and vault-before-synthesized-file precedence.
- [x] Cover empty, unavailable, malformed, clientless, mismatched, valid, and mixed-mode stores.

### TASK-003: Crash-safe operation-aware journals

**Status**: Completed

- [x] Write unique `0600`, no-follow, fsynced candidate generations.
- [x] Atomically install/replace and directory-fsync each generation.
- [x] Record operation kind, expected identity, candidate identity, and phase.
- [x] Complete verified revocation but reject missing replacement artifacts.
- [x] Preserve crash-boundary evidence and reject malformed/substituted state.

### TASK-004: Registered redirect semantics

**Status**: Completed

- [x] Select the first validated stored redirect when no override is supplied.
- [x] Preserve host, path, and fixed port; allocate only omitted ports dynamically.
- [x] Bind every resolved localhost loopback family on one advertised port.
- [x] Accept callbacks over injected IPv4 and IPv6 listeners.
- [x] Clean partial binds and perform zero browser/token activity on bind failure.

### TASK-005: Integration, identity, redaction, docs, and gates

**Status**: Completed

- [x] Bind current tokens to schema/provider/credential and require legacy re-login.
- [x] Keep invalid metadata out of status and doctor output.
- [x] Preserve GraphQL error envelopes and excluded legacy executables.
- [x] Document setup/login/status/revoke and environment-free ordinary use.
- [x] Move completed plans to `impl-plans/completed` and synchronize progress JSON.

## Verification

- Focused suites passed for lifecycle concurrency/subprocess behavior, exact
  config validation, journal crash safety, redirects, credential binding,
  isolation, coherence, legacy upgrade, and redaction.
- `swift test list`: 273 tests discovered.
- `swift test`: all tests passed.
- `mise run test`: SwiftPM and smoke tests passed.
- `mise run lint`: zero violations.
- `mise run build`: passed.
- Reader, sender, and draft help passed; package assertion confirms no writer.
- `jq empty impl-plans/PROGRESS.json` and `git diff --check` passed.

## Residual Risks

- Live Google OAuth and the developer Keychain are intentionally not exercised
  in automated tests; deterministic injected production-boundary seams are used.
- No commit or push was performed.

## Progress Log

- 2026-09-04: Created the closure plan from carried review findings.
- 2026-09-04: Completed concurrency, vault validation, journal, redirect, and
  compatibility implementation and review cycles.
- 2026-09-05: Completed adversarial credential-binding, immutable-snapshot, and
  operation-aware recovery changes; compacted completed records under 400 lines.
