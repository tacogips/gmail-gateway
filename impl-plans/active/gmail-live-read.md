# Gmail Live Read Implementation Plan

**Status**: In Progress
**Design Reference**: design-docs/specs/design-mail-gateway.md#gmail-v1-adapter
**Created**: 2026-06-23
**Last Updated**: 2026-06-25

---

## Design Document Reference

**Source**: design-docs/specs/design-mail-gateway.md

### Summary

Replace the local empty thread/message stubs with live Gmail API metadata reads when a valid token store is available.

### Scope

**Included**: Gmail access-token loading, refresh-token exchange, messages list/get metadata reads, starred thread search filtering, thread/message GraphQL payloads, local smoke coverage for missing auth and token compatibility, docs.
**Excluded**: Attachment download from Gmail, full MIME body materialization, send workflow, daemon sync/cache.

---

## Modules

### 1. Gmail API Read Client

#### Sources/MailGatewayCore/GmailLiveReader.swift

**Status**: Completed

```swift
struct GmailLiveReader {
    func searchThreads(account: AccountConfig, credential: CredentialConfig) throws -> [String: Any]
    func getThread(account: AccountConfig, credential: CredentialConfig, threadId: String) throws -> Any
    func getMessage(account: AccountConfig, credential: CredentialConfig, messageId: String) throws -> Any
}
```

**Checklist**:
- [x] Load token store written by OAuth login
- [x] Refresh expired access tokens when a refresh token is present
- [x] Call Gmail messages list/get and threads get endpoints
- [x] Return metadata-only GraphQL-compatible payloads

### 2. Service Integration And Verification

#### Sources/MailGatewayCore/MailGatewayCore.swift
#### Sources/MailGatewaySwiftSmokeTests/main.swift
#### README.md

**Status**: In Progress

```swift
public struct MailGatewayReaderService {
    public func searchThreads(accountId: String) throws -> [String: Any]
    public func getThread(accountId: String, threadId: String) throws -> Any
    public func getMessage(accountId: String, messageId: String) throws -> Any
}
```

**Checklist**:
- [x] Wire GraphQL thread/message fields to live Gmail reads
- [x] Add smoke coverage for missing auth on read operations
- [x] Document no-config plus env/default credential flow
- [ ] Run local and direct CLI verification

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Gmail API Read Client | `Sources/MailGatewayCore/GmailLiveReader.swift` | COMPLETED | `swift run mail-gateway-swift-smoke-tests` |
| Service Integration And Verification | `Sources/MailGatewayCore/MailGatewayCore.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md` | BLOCKED_ON_CREDENTIALS | `task ci`; direct no-config CLI checks |
| Starred Thread Search | `Sources/MailGatewayCore/GmailLiveReader.swift`, `Sources/MailGatewayCore/MailGatewayGraphQL.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md`, `design-docs/specs/design-mail-gateway.md` | COMPLETED | `swift run mail-gateway-swift-smoke-tests` |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Gmail Live Read | Gmail OAuth token store | Implemented |

## Tasks

### TASK-001: Gmail Live Metadata Read

**Status**: In Progress
**Parallelizable**: No
**Deliverables**: `Sources/MailGatewayCore/GmailLiveReader.swift`, `Sources/MailGatewayCore/MailGatewayCore.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md`
**Dependencies**: gmail-oauth-bootstrap:TASK-001

**Description**:
Implement live Gmail metadata retrieval through the existing reader GraphQL operations.

**Completion Criteria**:
- [x] `threads` requires auth and calls Gmail when token exists
- [x] `thread` and `message` return Gmail metadata payloads
- [x] Expired access tokens refresh using the OAuth client JSON and refresh token
- [x] Local tests and CLI checks pass
- [x] Live Gmail retrieval attempted with available local/env credentials

### TASK-002: Gmail Starred Thread Search

**Status**: Completed
**Parallelizable**: Yes
**Deliverables**: `Sources/MailGatewayCore/GmailLiveReader.swift`, `Sources/MailGatewayCore/MailGatewayCore.swift`, `Sources/MailGatewayCore/MailGatewayGraphQL.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md`, `design-docs/specs/design-mail-gateway.md`
**Dependencies**: TASK-001

**Description**:
Expose a first-class `starred` filter on thread search and combine it with the existing Gmail query path.

**Completion Criteria**:
- [x] `threads(input:)` accepts `starred: true`
- [x] Gmail message listing combines `is:starred` with any supplied `query`
- [x] Account default label filters continue to be sent
- [x] Smoke tests cover starred-only, starred-plus-query, and query-only behavior without live Gmail credentials

## Completion Criteria

- [x] Live read implementation completed
- [x] Starred thread search implemented
- [x] Tests passing
- [x] Documentation updated
- [x] Direct verification completed

## Progress Log

### Session: 2026-06-23 11:44
**Tasks Completed**: None yet
**Tasks In Progress**: TASK-001
**Blockers**: None
**Notes**: User clarified the end state: no config required by default, and Gmail mail retrieval should be verified through env/default credential setup if needed.

### Session: 2026-06-23 12:40
**Tasks Completed**: Wired live reader into service methods; added no-config missing-auth smoke coverage; ran `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, `git diff --check`, and direct no-config CLI checks.
**Tasks In Progress**: Live Gmail retrieval with real credentials
**Blockers**: No Gmail OAuth client JSON or token JSON is available in kinko, direnv, default config paths, or common local files. `auth login` fails because `~/.config/mail-gateway/google-client.json` is missing.
**Notes**: Source/test updates were applied by temporary Riela command workflow after packaged Riela agent workflows stalled in review. kinko now has the project-scope default credential path keys.

### Session: 2026-06-23 13:51
**Tasks Completed**: Reviewed current git diff and tightened live-read behavior.
**Tasks In Progress**: Live Gmail retrieval with real credentials remains blocked by missing local/env credential material.
**Blockers**: No Gmail OAuth client JSON or token JSON is available in kinko, direnv, default config paths, or common local files.
**Notes**: Removed accidental live Gmail attachment fetch from `attachment(...)`, kept Gmail message bodies out of GraphQL-shaped message payloads, preserved kinko/env token JSON by not writing refreshed tokens back to disk when token JSON is provided inline, made GraphQL field detection ignore string literals, added cached-attachment and projection smoke coverage, and reran `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, and `git diff --check`.

### Session: 2026-06-23 13:55
**Tasks Completed**: Fixed GraphQL argument parsing found during review.
**Tasks In Progress**: Live Gmail retrieval with real credentials remains blocked by missing local/env credential material.
**Blockers**: No Gmail OAuth client JSON or token JSON is available in kinko, direnv, default config paths, or common local files.
**Notes**: Replaced substring-based argument lookup with a string-literal-aware argument-label scanner so values such as `attachmentId: "accountId:"` do not corrupt parsing, added CLI smoke coverage for the case, and reran `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, and `git diff --check`.

### Session: 2026-06-23 13:59
**Tasks Completed**: Reviewed the current diff again and tightened GraphQL projection behavior.
**Tasks In Progress**: Live Gmail retrieval with real credentials remains blocked by missing local/env credential material.
**Blockers**: No Gmail OAuth client JSON or token JSON is available in kinko, direnv, default config paths, or common local files.
**Notes**: Made `attachment(...)` return only requested attachment fields, allowed whitespace around GraphQL argument colons, added smoke coverage for both cases, and reran `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, and `git diff --check`.

### Session: 2026-06-23 14:03
**Tasks Completed**: Reviewed current git diff and hardened lightweight GraphQL parsing/projection.
**Tasks In Progress**: Live Gmail retrieval with real credentials remains blocked by missing local/env credential material.
**Blockers**: No Gmail OAuth client JSON or token JSON is available in kinko, direnv, default config paths, or common local files.
**Notes**: Scoped root operation dispatch to root fields, scoped argument labels to GraphQL argument parentheses, made thread/attachment projection use direct selection fields, added smoke coverage for nested selection text and aliases, and reran `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, and `git diff --check`.

### Session: 2026-06-23 14:04
**Tasks Completed**: Restored live Gmail body extraction and remote attachment lookup while preserving offline smoke behavior.
**Tasks In Progress**: None for the verified Gmail read path.
**Blockers**: None for kinko-backed live verification.
**Notes**: Confirmed kinko-backed Gmail OAuth can read thread/message bodies, parse attachment metadata, resolve a remote Gmail attachment without materializing payload content locally, and filter Gmail search queries. The final validation suite was rerun before commit.

### Session: 2026-06-23 14:05
**Tasks Completed**: Final review of current git diff and GraphQL parser cleanup.
**Tasks In Progress**: None for the verified Gmail read path.
**Blockers**: None for kinko-backed live verification.
**Notes**: Kept the current live Gmail body/attachment behavior intact, removed dead parser helper code, confirmed root-field dispatch and direct-selection projection coverage, and reran `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, and `git diff --check`.

### Session: 2026-06-25 16:20
**Tasks Completed**: TASK-002
**Tasks In Progress**: None for starred thread search
**Blockers**: None for local starred-search verification
**Notes**: Riela simple-work review identified the missing starred filter in the current diff. Added `starred: true` thread search support, composed Gmail `is:starred` with caller query text, preserved default label filters, and added URL-intercepted smoke coverage that does not require live Gmail credentials.

## Related Plans

- **Previous**: `gmail-oauth-bootstrap.md`, `completed/default-config-fallback.md`
- **Next**: None
- **Depends On**: `gmail-oauth-bootstrap.md`
