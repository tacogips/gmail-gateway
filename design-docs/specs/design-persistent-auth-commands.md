# Persistent Auth Commands

This document defines secure, persistent Gmail OAuth setup and lifecycle behavior
for `gmail-gateway-reader`, `gmail-gateway-sender`, and `gmail-gateway-draft`.

## Status

Updated proposed issue-resolution design after adversarial review for the issue
"Add persistent auth commands to all gmail-gateway executables". No GitHub
repository, issue number, or URL was provided with the workflow input.
The authoritative workflow issue reference is
`workflow-input:Add persistent auth commands to all gmail-gateway executables`.

## Goals

- Give the three named executables one consistent `auth setup`, `auth login`,
  `auth status`, and `auth revoke` contract.
- Persist OAuth client and token material in macOS Keychain so ordinary commands
  work without credential environment variables after setup.
- Bind persisted auth state to the credential ID and required executable access
  mode, with exact scope validation before every Gmail request.
- Preserve explicit configuration-path and environment sources where they are
  safe and unambiguous.
- Keep secret values out of stdout, stderr, logs, errors, tests, and repository
  files.

## Non-Goals

- Creating or renaming an executable to `gmail-gateway-writer`.
- Changing Gmail account, GraphQL, cache, or file command behavior.
- Editing the user's TOML configuration during auth setup.
- Automating Google Cloud project, consent-screen, or OAuth-client creation.
- Migrating or deleting existing file credentials without an explicit command.
- Sharing Keychain entries with `google-service-gateway` or another product.
- Adding persistent setup or changing auth/token behavior for
  `gmail-gateway-threads` or `gmail-gateway-message-box`.

## Executable And Access-Mode Boundary

The invoking executable supplies an immutable required access mode:

| Executable | Required access mode | Exact requested scopes |
| --- | --- | --- |
| `gmail-gateway-reader` | `read` | `gmail.readonly` |
| `gmail-gateway-sender` | `read_send` | `gmail.readonly`, `gmail.compose`, `gmail.send` |
| `gmail-gateway-draft` | `read_send` | `gmail.readonly`, `gmail.compose`, `gmail.send` |

Before client or token material is loaded, every auth and ordinary command must
verify that the selected configuration credential has the required access mode.
There is no subset or superset substitution: a `read_send`, `read_modify`, or
`full` credential is not accepted by the reader, and a `read` credential is not
accepted by sender or draft. Sender and draft may deliberately share the same
`read_send` profile because their required access mode is identical.

Persisted records include schema version, provider (`gmail`), credential ID,
and access mode. A record whose identity metadata differs from the current
selection fails closed as `SCOPE_MISMATCH`; it is never silently rebound.

The same guard runs before login, refresh, status evaluation, revocation, and
each provider request. Command routing remains in `GmailGatewayCore`; the three
entry points supply only their fixed mode.

### Excluded Shared-CLI Modes

`gmail-gateway-threads` (`mailboxThreads`) and `gmail-gateway-message-box`
(`messageBox`) share `GmailGatewayCLI` and `GmailOAuthSupport` but are outside
this issue. The shared CLI attaches a persistent-auth policy only for `reader`,
`directSender`, and `draftGateway`; it does not register `auth setup` for the two
excluded modes. Their existing `auth login`, `auth status`, and unconfirmed
local `auth revoke` syntax, `read_modify`/`full` capability checks, environment
and file resolution, token schema acceptance, refresh, and provider behavior
remain unchanged.

The selected CLI policy is propagated through the service and OAuth resolver so
shared helpers do not infer the new behavior from token access mode alone.
Direct library construction retains the existing legacy policy unless the
caller explicitly supplies one of the three target policies. Consequently, the
new client fingerprint and migration requirement apply only to target-policy
`read` and `read_send` execution, not package-wide to all token stores.

## CLI Contract

All three named executables expose:

```text
<binary> auth setup --credential ID --client-secret-path PATH
                    [--replace --confirm-credential ID]
<binary> auth login --credential ID [--redirect-uri URI]
                    [--open-browser true|false] [--timeout-seconds N]
<binary> auth status --credential ID
<binary> auth revoke --credential ID --confirm-credential ID
```

`--credential` remains required so a destructive or privileged action never
selects a profile implicitly. Existing global `--config` and `--pretty`
behavior remains unchanged.

### Setup

`auth setup` reads a Google Desktop-app OAuth JSON document from the named file,
validates it, and stores a normalized client record in the secure vault. Secret
JSON is not accepted as a command-line value because process arguments can be
observed by other tooling. The source file is neither modified nor removed.

Validation requires:

- an `installed` client with non-empty client ID;
- authorization endpoint `https://accounts.google.com/o/oauth2/auth` or
  `https://accounts.google.com/o/oauth2/v2/auth`, and token endpoint
  `https://oauth2.googleapis.com/token`, with no alternate host, scheme, port,
  user information, query, or fragment; the legacy authorization path is
  normalized to the v2 path before persistence, fingerprinting, and use;
- only valid loopback redirect entries for this local installed-app flow;
- selected provider, credential ID, and access mode matching the invoking
  executable; and
- credential IDs using 1-64 ASCII letters, numbers, `_`, or `-`, beginning with
  a letter or number.

Setup returns only credential ID, provider, access mode, client kind, project ID
when present, persistence backend, and `clientStored: true`. It never returns the
client ID, client secret, source contents, Keychain account name, or source path.

If a client record already exists, setup leaves both client and token state
unchanged unless `--replace` and an exact `--confirm-credential ID` are both
present. Client replacement validates the new client first, then atomically
replaces the profile envelope with the new client and no token. Failure
preserves the previous envelope.

### Login

Login retains the existing loopback PKCE flow and browser controls. It obtains
the client through the source-resolution rules below, requests only the fixed
scope set for the executable, sets `include_granted_scopes=false`, validates
callback state, and validates the authenticated Gmail profile.

The effective Google grant must exactly equal the normalized expected scope
set. When the authorization-code response omits `scope`, the exact scopes in
the just-created authorization request are authoritative, matching OAuth's
same-as-request omission rule. An explicit missing, extra, or incompatible
scope result fails without replacing existing auth state. A newly persisted
profile must contain a refresh token; omission also leaves the old token
untouched. After all checks pass, login replaces the token atomically in its
selected persistence backend.

Redirect selection preserves the registered Desktop-client callback semantics:

- an explicit `--redirect-uri` must be an `http` loopback URI accepted by one
  stored redirect entry, including its normalized host, optional fixed port,
  and percent-encoded callback path;
- without `--redirect-uri`, login selects the first validated loopback redirect
  from the stored client instead of synthesizing a product default;
- `127.0.0.1`, `::1`, and `localhost` remain distinct registered host choices;
  the URI sent to Google and the token exchange retains the selected host and
  does not rewrite `localhost` to `127.0.0.1`;
- the listener binds IPv4 loopback for `127.0.0.1` and IPv6 loopback for `::1`;
  for `localhost`, it resolves the hostname before browser launch, rejects any
  non-loopback result, and binds every resolved IPv4 and IPv6 loopback family
  on one effective port so browser address-family preference cannot make the
  callback unreachable;
- all listeners are loopback-only, and the authorization and token-exchange URI
  retains the selected registered host spelling rather than substituting a
  literal address; and
- a stored fixed port must be used exactly, while a stored redirect without a
  port permits the listener to allocate one port and substitute only that port.

For a dynamic `localhost` redirect, the receiver chooses one candidate port and
must bind that same port for every resolved loopback address family before
constructing the authorization URL. If any required bind fails, login closes
all partial listeners and fails before opening the browser; it does not degrade
to one family or rewrite the hostname.

The callback receiver accepts requests only on the selected percent-encoded
path and validates state before exposing an authorization code. Bind failure,
unsupported host, path mismatch, or a requested URI not accepted by a stored
entry fails before token exchange and leaves persistent state unchanged.

Login output is limited to credential ID, provider, access mode, state, email
address, expiry, refresh-token presence, and persistence backend. Authorization
codes, authorization URLs, client values, access tokens, refresh tokens, and
Keychain identifiers are never returned. When automatic browser opening is
disabled, the authorization URL may be written only to an interactive terminal,
not structured business output or logs.

### Status

`auth status` is local-only. It reports:

- credential ID, provider, configured access mode, and executable-required mode;
- redacted client source and token source kinds;
- client state and token state (`MISSING`, `READY`, `EXPIRED`,
  `SCOPE_MISMATCH`, `INVALID`, or `UNKNOWN`);
- normalized granted scope names when available;
- expiry, refresh-token presence, and authenticated email when available; and
- whether a persistent client and token exist.

It never performs refresh or provider calls and never prints secret values,
raw JSON, Keychain account names, authorization headers, or environment values.
For backward compatibility, an explicitly configured legacy path may still be
reported as a path; secure-vault internals are never reported.

### Revoke

`auth revoke` removes only the token for the selected credential and access
mode. It requires `--confirm-credential` to exactly match `--credential`, even
when no token exists. Client configuration remains available for a later login.
Inline environment token JSON is immutable for the process and cannot be
revoked; the command fails with guidance to remove that environment source.

Before a writable file token is overwritten by login or deleted by revoke, the
resolver must load that exact file and validate its lifecycle identity against
the selected credential and OAuth client. Access mode and any present scope
metadata must match. When `clientFingerprint` is present, it must match the
selected client; a mismatch fails as `AUTH_REQUIRED` before browser, OAuth, or
provider transport and leaves the file byte-for-byte unchanged. A missing scope
or fingerprint is treated only as legacy metadata: it may be replaced by a
successful login into that same file or explicitly deleted by confirmed revoke,
but it is never sufficient for refresh or ordinary Gmail use.

This command preserves the existing local-revocation meaning: it does not call
Google's remote revocation endpoint. Output contains only credential ID,
access mode, token source kind, and whether a local token was removed. Removing
or replacing the OAuth client is performed only by confirmed `auth setup
--replace`.

## Secure Persistence Boundary

`GmailGatewayCore` owns a Gmail-specific vault adapter. The adapter consumes
`SecureCredentialStore` and uses `KeychainCredentialStore` from the tagged
`GoogleServiceGatewayCore` package, configured with the Gmail-specific service
namespace `com.tacogips.gmail-gateway`. This reuses the established Keychain
security boundary without coupling Gmail behavior to the other product's CLI.

The Gmail adapter, rather than `OAuthCredentialVault`, owns record encoding and
keys because Gmail must bind client and token state to provider, credential ID,
access mode, scope set, and authenticated principal. One versioned profile
envelope contains the normalized client plus an optional token. A single
Keychain item update can therefore make setup replacement, login, refresh, and
local revoke atomic: revoke writes the same client with no token. Tests inject
an in-memory `SecureCredentialStore`; automated tests never access the
developer's Keychain.

Keychain writes use the referenced store's
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` policy. No filesystem
fallback is created for the new persistent flow. A Keychain failure is explicit
and does not fall back to a plaintext file. Existing user-selected file paths
remain supported as the legacy compatibility path.

The implementation adds an exact SwiftPM dependency on
`https://github.com/tacogips/google-service-gateway.git` version `0.1.1` and
links only the `GoogleServiceGatewayCore` library product into
`GmailGatewayCore`. It does not copy or locally reimplement the secure-store
contract, and it does not depend on any google-service-gateway executable. A
future dependency change requires a separate reviewed design update.

## Client And Token Coherence

Every target-policy current-schema token contains a `clientFingerprint`: a
SHA-256 digest of a UTF-8 canonical JSON object with fixed field names for
client kind, client ID, normalized project ID or null, authorization endpoint,
token endpoint, and lexically sorted normalized redirect URI strings. Object
keys are sorted before encoding. The client secret is omitted so normal secret
rotation for the same OAuth client does not invalidate tokens. The fingerprint
is internal metadata and is never returned or logged.

Client and token sources are resolved independently only to preserve existing
override precedence. Before refresh or Gmail access, the resolved token's
fingerprint must equal the resolved client's fingerprint in constant time. A
vault token therefore cannot be combined with a different environment or file
client, and a legacy token cannot be combined with a replacement vault client.
Mismatch fails as `AUTH_REQUIRED` before the token or client secret reaches a
request. The resolver does not skip an incoherent higher-priority token and
fall through to a lower-priority source.

The same coherence rule runs at the lifecycle-mutation boundary. Login and
revoke may encounter an existing file token that ordinary hydration would
reject; this exception exists so legacy files can be upgraded or removed, not
so mismatched current-schema files can be mutated. A present fingerprint is
therefore authoritative and must match before either operation. A mismatch
does not fall through to a lower-priority vault token or another file.

The Keychain envelope stores one client and optional token with the same
fingerprint. Target-policy file and environment token schemas gain the
fingerprint field so the same invariant applies across mixed source kinds.
Excluded shared-CLI modes do not decode or require this field.

## Source Resolution And Backward Compatibility

Resolution retains intentional user overrides and distinguishes explicit values
from synthesized defaults.

### OAuth client source, highest precedence first

1. Per-credential `*_OAUTH_CLIENT_SECRET_JSON` environment value.
2. Per-credential `*_OAUTH_CLIENT_SECRET_PATH` environment path.
3. Explicit `credentials[].oauth_client_secret_path` TOML path.
4. Matching secure-vault client record.
5. Existing synthesized config-relative default path.

An explicit unreadable or invalid environment/TOML source is an error; it does
not silently fall through to Keychain. This catches configuration mistakes and
preserves the current override contract.

### Token source, highest precedence first

1. Per-credential `*_TOKEN_STORE_JSON` environment value.
2. Per-credential `*_TOKEN_STORE_PATH` environment path.
3. Explicit `credentials[].token_store_path` TOML path.
4. A path relocated by `GMAIL_GATEWAY_CREDENTIAL_DIR`.
5. Matching secure-vault token record.
6. Existing synthesized XDG state token path.

Environment JSON remains read-only and is never persisted during refresh.
Explicit or relocated file sources retain atomic `0600` writes and `0700`
parent directories. When no explicit legacy token destination is selected,
login and refresh use Keychain. Populating Keychain therefore does not override
an operator's explicit source, but it does take priority over an old synthesized
default file.

### Accepted source-pair matrix

After the precedence rules choose one effective client and one effective token,
source kind does not itself determine compatibility. Every effective pairing is
accepted when identity, access mode, exact scopes, and client fingerprint are
coherent:

| Effective client source | Effective token sources tested |
| --- | --- |
| Environment JSON | Environment JSON, environment path, TOML path, relocated path, secure vault, synthesized default |
| Environment path | Environment JSON, environment path, TOML path, relocated path, secure vault, synthesized default |
| Explicit TOML path | Environment JSON, environment path, TOML path, relocated path, secure vault, synthesized default |
| Secure vault | Environment JSON, environment path, TOML path, relocated path, secure vault, synthesized default |
| Synthesized default | Environment JSON, environment path, TOML path, relocated path, synthesized default; when a vault token is selected, its envelope also supplies the higher-priority vault client |

Each row is also exercised with a mismatched selected token fingerprint. The
selected pair must fail as `AUTH_REQUIRED` without refresh or Gmail transport,
and without falling back to a coherent lower-priority vault token. Invalid or
unreadable explicit sources similarly fail at their selected precedence level;
they do not fall through.

Legacy token files and environment JSON remain discoverable, and writable files
remain revocable and eligible as the destination for a new login. Inline
environment JSON remains immutable: remediation requires removing that override
and logging in to a writable file or Keychain destination. A pre-feature token
that lacks either exact scope metadata or `clientFingerprint` is not used for
refresh or Gmail access: status reports `UNKNOWN` with that re-login
remediation, and ordinary commands fail `AUTH_REQUIRED`. A successful login
through the same selected writable legacy destination upgrades it atomically.
Records with a mismatched access mode or explicit incompatible scopes fail
`SCOPE_MISMATCH`. This is the deliberate security exception to byte-for-byte
token-schema compatibility; environment names, configured paths, and
precedence remain backward compatible.

The required legacy-file upgrade sequence is explicit: local status reports
`UNKNOWN`; an ordinary operation fails `AUTH_REQUIRED` before refresh or Gmail
transport and leaves the file unchanged; login reuses the same selected writable
path; successful authorization atomically writes exact scope metadata and the
selected client's fingerprint; status then reports `READY`; and ordinary
hydration accepts the upgraded token and may proceed to the injected provider
transport. Tests cover missing scope, missing fingerprint, and both fields
missing. A present mismatched fingerprint is not a legacy omission and blocks
login and revoke without mutation.

`auth setup` does not import a legacy token automatically. Migration is
operator-controlled: set up the client, run login with the intended executable,
verify status, then remove the old external source if desired.

## Configuration Validation Boundary

Synchronous TOML loading records whether each OAuth-client path was explicit or
synthesized. For the three persistent-auth executables, a missing synthesized
client file is only a provisional condition; the asynchronous `config validate`
boundary must resolve it against the injected secure vault before reporting
success. It must not exempt every synthesized path solely because persistent
auth is enabled.

For every credential that relies on the synthesized client path, validation
queries the exact Gmail vault profile identified by provider, credential ID,
and configured access mode. Success requires a present, decodable profile with
a valid client whose identity metadata matches that key. A token is not
required. An empty vault, unavailable Keychain, malformed envelope, clientless
profile, or mismatched profile fails as `CONFIG_INVALID` with setup-oriented
remediation. Explicit environment and TOML client sources retain their existing
readability and shape checks and never fall through to Keychain.

This two-stage rule applies to `config validate` for reader, sender, and draft
through the same injected store used by setup and ordinary execution. Legacy
threads and message-box validation remains synchronous and file-based. Tests
must seed and inspect an injected store: the same Keychain-only TOML must fail
with an empty store and pass only after setup creates the matching profile for
each target executable mode.

## Lifecycle Serialization And File Mutation Safety

Setup, login, refresh during ordinary credential hydration, and confirmed
revoke share one coordinator-owned, OS-visible advisory lifecycle lock keyed by
provider, credential ID, and access mode. The lock identity lives in a stable
per-user namespace independent of the current config and token paths, so
reader, sender, draft, and separately launched processes contend on the same
lock. Its directory and file are user-only and opened without following
symlinks. An in-memory actor or lock scoped to one coordinator instance is not
sufficient.

The coordinator acquires the process-shared lock before taking any client,
token, vault-revision, or file-identity snapshot. The critical section spans
source resolution, recovery, identity capture, remote result validation where
applicable, and final persistence. No call site may implement the production
guarantee by locking direct vault or file helpers independently.

This gives refresh and revoke a deterministic linearization rule. If refresh
enters first, revoke observes the refreshed state and removes it before it
returns. If revoke enters first, a later hydration observes no token and cannot
restore the revoked credential from stale pre-lock state. Setup replacement and
login obey the same ordering, so a lifecycle operation never commits a result
derived from a profile displaced while it was waiting.

For a selected file destination, the coordinator records the opened parent
directory and leaf identity, then every mutation revalidates that identity at
the final descriptor-relative operation. Parent components and leaf entries are
never followed through symlinks. Mutation-time replacement of the leaf with a
symlink, or any identity change after resolution, fails closed without touching
the symlink target, without source fallback, and without publishing the new
token.

### Crash-Safe Transaction Journals

A token-file replacement or revoke journal is published and advanced by atomic
sibling-file installation within the already validated parent directory:

1. Create a uniquely named temporary journal with exclusive creation,
   no-follow semantics, and mode `0600`.
2. Encode and completely write one versioned phase record, then synchronize the
   temporary file before it can acquire the final journal name.
3. For initial publication, atomically rename without replacing an existing
   final journal. For a phase advance, atomically rename over the prior complete
   journal; never truncate or rewrite the final journal in place.
4. Synchronize the parent directory after each install and after final cleanup.

A crash before installation leaves no final journal or leaves the previous
complete phase intact. A crash after installation leaves one complete new phase
for recovery; incomplete temporary siblings are never interpreted as final
journals. Recovery removes only verified temporary artifacts, validates journal
schema, names, phases, and recorded file identities, and refuses to rename or
delete substituted entries. A malformed, truncated, symlinked, or incoherent
final journal fails closed rather than guessing which credential file to use.

## Data Flow

1. The executable fixes the required access mode.
2. Shared CLI parsing selects the credential and validates destructive
   confirmation before touching secret storage.
3. Configuration resolution returns both values and source provenance.
4. The mode guard validates configured and persisted identity metadata.
5. The Gmail vault adapter reads or writes the selected source through the
   injected secure store; legacy paths remain behind the existing file adapter.
6. Before file login/revoke mutation, the lifecycle guard validates access mode,
   any present scopes, and any present fingerprint against the selected client.
7. Before ordinary use, the coherence guard requires complete scope and
   fingerprint metadata and verifies the fingerprint against the resolved
   client without exposing either value.
8. OAuth bootstrap and refresh validate exact scopes before committing a token.
9. Provider operations receive an access token in memory only; result shaping
   exposes redacted metadata only.

## Failure And Redaction Rules

- Parse, confirmation, and mode errors occur before Keychain, filesystem,
  browser, or network access.
- Provider error bodies, decoding causes, URLs, headers, environment values,
  and serialized records are sanitized before reaching structured errors.
- Errors may identify the command, credential ID, source kind, required access
  mode, and remediation, but never secret-bearing values.
- Failed setup or login never destroys a previously valid record.
- Refresh preserves the previous refresh token and verified scope set when the
  provider omits them; an incompatible returned scope set is rejected.
- A missing or mismatched client fingerprint blocks refresh and provider access;
  it never triggers source fallback or automatic metadata upgrade.
- Status and doctor treat editable legacy metadata as local evidence, not proof
  of current provider validity.

## Rollout Constraints

- The first release adds the secure vault as a fallback after explicit legacy
  sources; there is no automatic migration or deletion.
- Existing target-policy `read` and `read_send` tokens without verified scopes
  and a client fingerprint require one explicit re-login before the three named
  executables can use them. Excluded modes do not migrate.
- Help and README examples cover exactly reader, sender, and draft. No writer
  executable or alias is introduced.
- The shared implementation is exercised through all three executable modes so
  behavior cannot drift between entry points.
- Packaging must include the reviewed secure-store dependency without requiring
  machine-local sibling repository paths.
- Release notes call out Keychain access prompts and the precedence rules.

## Verification Strategy

Tests use temporary legacy files, a deterministic in-memory secure store,
injected OAuth transports, and no live Google credentials. Coverage must prove:

- setup persistence, validation, redacted output, confirmed replacement, and
  non-destructive failure;
- Keychain-only TOML validation fails against an empty or mismatched injected
  vault and succeeds only when the exact persistent client profile exists, for
  reader, sender, and draft;
- login and environment-free ordinary commands for reader, sender, and draft;
- stored default and explicit redirect selection preserve IPv4, IPv6,
  `localhost`, fixed/dynamic port, and percent-encoded callback-path semantics
  through listener bind, authorization request, and token exchange; injected
  resolution tests make `localhost` return both loopback families and prove
  callbacks can arrive over either family on the same advertised port;
- exact executable/access-mode and stored-scope mismatch rejection before
  browser, token, or provider access;
- environment JSON, environment path, TOML path, relocated path, Keychain, and
  synthesized-default precedence;
- coherent same-client combinations and rejection of every mixed-source client
  fingerprint mismatch before refresh or provider transport, including proof
  that a selected incoherent source never falls through to a coherent vault;
- a legacy writable file missing scope, fingerprint, or both reports `UNKNOWN`,
  fails ordinary use as `AUTH_REQUIRED` with zero refresh/provider requests,
  remains unchanged on failure, is upgraded in place by login, then reports
  `READY` and is accepted for ordinary use;
- file-token login and revoke reject a present mismatched fingerprint before
  browser/network activity or filesystem mutation, while permitting explicit
  upgrade or deletion when the fingerprint is absent as legacy metadata;
- inline-environment legacy token non-persistence and remediation;
- status redaction for client secrets, access tokens, refresh tokens,
  authorization codes, Keychain identifiers, and environment values;
- exact confirmation and target isolation for revoke, including missing and
  immutable inline tokens;
- coordinator-level gates deterministically order refresh versus revoke in both
  directions using independent coordinator instances that open separate handles
  to the same lock identity, and prove a completed revoke cannot be undone by
  stale refresh;
- a subprocess contention fixture proves the lifecycle lock is shared across
  executable processes rather than only within one Swift object or process;
- coordinator login, refresh, and revoke fault points substitute a symlink only
  after destination resolution and prove the target remains byte-for-byte
  unchanged with no fallback mutation;
- journal fault injection before initial installation and before phase
  replacement proves the final journal is respectively absent or still the
  prior complete decodable record, and recovery rejects substituted or
  truncated final journals;
- the package still exposes the three named executables without a
  `gmail-gateway-writer` product;
- shared-CLI regression snapshots prove threads and message-box do not expose
  `auth setup`, retain their existing revoke syntax, and accept existing
  `read_modify`/`full` token fixtures without a fingerprint; and
- both reviewed Google authorization paths are accepted and normalize to the
  same v2 endpoint and client fingerprint, while endpoint variants outside the
  allowlist are rejected.

Required repository verification after implementation:

```bash
swift test
mise run test
mise run lint
mise run build
swift run gmail-gateway-reader --help
swift run gmail-gateway-sender --help
swift run gmail-gateway-draft --help
git diff --check
```

## Reference Mapping And Intentional Divergence

- `google-documents-gateway` supplies the shared auth command shape, immutable
  executable role, PKCE, exact scope enforcement, atomic legacy token files,
  XDG state defaults, redacted status, and confirmed local revoke behavior.
- `google-service-gateway` supplies `SecureCredentialStore`,
  `KeychainCredentialStore`, and the injectable secure-vault boundary.
- Unlike `google-documents-gateway`, this design adds `auth setup` because the
  issue requires environment-free persistent OAuth-client storage.
- Unlike the reference's fixed `127.0.0.1:<dynamic-port>/callback` receiver,
  Gmail preserves the selected redirect host, optional registered port, and
  callback path because those values are part of the imported Desktop client
  contract. Its receiver therefore also supports validated IPv6 loopback.
- Unlike `google-service-gateway`, Gmail keeps auth commands on each existing
  executable, uses a Gmail-specific Keychain namespace and record envelope, and
  keeps revoke local for compatibility. It does not expose an OAuth token
  command or a standalone auth executable.
- The secure-store integration directly consumes the tagged
  `GoogleServiceGatewayCore` product at version `0.1.1`; there is no local-copy
  fallback.
- No Cursor CLI behavior is in scope. If a future Cursor-facing adapter is
  added, it must remain outside core auth policy and translate only command
  input/output; it may not own scopes, secrets, or persistence.

## Open Questions

None. The secure backend, access-mode profiles, legacy precedence, replacement
confirmation, and migration behavior are resolved by this design.

## References

See [references/README.md](../references/README.md) for the inspected local
behavioral and secure-storage references.
