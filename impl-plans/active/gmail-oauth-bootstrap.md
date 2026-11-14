# Gmail OAuth Bootstrap Implementation Plan

**Status**: In Progress
**Design Reference**: design-docs/specs/design-gmail-credentials.md#required-google-side-credentials
**Created**: 2026-06-23
**Last Updated**: 2026-06-23

---

## Design Document Reference

**Source**: design-docs/specs/design-gmail-credentials.md

### Summary

Implement the currently stubbed Gmail installed-app OAuth login path for `mail-gateway-reader auth login`, persist the resulting token store, and validate the token with the Gmail profile API.

### Scope

**Included**: Desktop OAuth client JSON parsing, browser-based loopback OAuth callback, token exchange, local token-store write, Gmail profile validation, smoke-test coverage for the non-interactive failure path.
**Excluded**: Live Gmail message retrieval, send workflow implementation, long-lived token refresh scheduling, provider adapter expansion.

---

## Modules

### 1. Gmail OAuth Bootstrap

#### Sources/MailGatewayCore/GmailOAuthBootstrap.swift

**Status**: Implemented

```swift
struct GmailOAuthBootstrapper {
    func login(credential: CredentialConfig) throws -> [String: Any]
}

struct GmailOAuthTokenStore: Codable {
    let accessMode: AccessMode
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    let expiresAt: String?
    let emailAddress: String?
}
```

**Checklist**:
- [x] Parse Google desktop OAuth client JSON
- [x] Open browser to Google consent URL with PKCE and loopback callback
- [x] Exchange authorization code for tokens
- [x] Persist token store JSON atomically
- [x] Validate access token against Gmail profile API

### 2. CLI Integration And Tests

#### Sources/MailGatewayCore/MailGatewayCore.swift
#### Sources/MailGatewayCore/MailGatewayCLI.swift
#### Sources/MailGatewaySwiftSmokeTests/main.swift

**Status**: Implemented

```swift
public struct MailGatewayReaderService {
    public func login(credentialId: String) throws -> [String: Any]
}
```

**Checklist**:
- [x] Return JSON payload from `auth login`
- [x] Preserve `auth status` token inspection compatibility
- [x] Add smoke coverage for invalid OAuth client JSON and ready token status
- [x] Run `swift build`
- [x] Run `swift run mail-gateway-swift-smoke-tests`

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Gmail OAuth Bootstrap | `Sources/MailGatewayCore/GmailOAuthBootstrap.swift` | IMPLEMENTED | Build passed |
| CLI Integration And Tests | `Sources/MailGatewayCore/MailGatewayCore.swift`, `Sources/MailGatewayCore/MailGatewayCLI.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift` | IMPLEMENTED | Smoke tests passed |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Gmail OAuth Bootstrap | Existing credential config model | Available |
| CLI Integration And Tests | Gmail OAuth Bootstrap | Implemented |

## Tasks

### TASK-001: Gmail OAuth Login And Validation

**Status**: Implemented
**Parallelizable**: No
**Deliverables**: `Sources/MailGatewayCore/GmailOAuthBootstrap.swift`, `Sources/MailGatewayCore/MailGatewayCore.swift`, `Sources/MailGatewayCore/MailGatewayCLI.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`
**Dependencies**: None

**Description**:
Implement interactive Gmail OAuth login and validate resulting credentials through the Gmail API.

**Completion Criteria**:
- [x] `auth login` launches Google OAuth for Gmail credentials
- [x] OAuth callback is received through a local loopback listener
- [x] Token store contains `accessMode`, token fields, expiry, scope, and Gmail profile email
- [x] Invalid OAuth client JSON is reported without launching a browser
- [x] Swift build and smoke tests pass

## Completion Criteria

- [x] Gmail OAuth login implementation completed
- [x] CLI returns structured login result JSON
- [x] Smoke tests passing
- [ ] Live verification attempted against local Gmail config

## Progress Log

### Session: 2026-06-23 09:53
**Tasks Completed**: None yet
**Tasks In Progress**: TASK-001
**Blockers**: None
**Notes**: User requested live Gmail verification; current implementation has `auth login` stubbed, so OAuth bootstrap is required first.

### Session: 2026-06-23 09:58
**Tasks Completed**: TASK-001 implementation and local smoke verification
**Tasks In Progress**: Live Gmail verification
**Blockers**: `~/.config/mail-gateway/config.toml` is missing and `MAIL_GATEWAY_CONFIG` is unset, so no OAuth client JSON or credential id is available for live login.
**Notes**: `swift build`, `swift run mail-gateway-swift-smoke-tests`, and `git diff --check` passed. `mail-gateway-reader config validate` confirms the default config file is missing.

### Session: 2026-06-23 10:57
**Tasks Completed**: Self-review improvements and repo-level verification
**Tasks In Progress**: Live Gmail verification
**Blockers**: `~/.config/mail-gateway/config.toml` is still missing and `MAIL_GATEWAY_CONFIG` is unset.
**Notes**: Added ready-token smoke coverage and explicit GraphQL error payload type annotations. `task ci` and `git diff --check` passed. Temporary CLI checks verified config validation, ready auth status, invalid OAuth client login failure, and the missing default config failure.

## Related Plans

- **Previous**: None
- **Next**: Future Gmail live read adapter plan if message retrieval is requested
- **Depends On**: None
