# Default Config Fallback Implementation Plan

**Status**: Completed
**Design Reference**: design-docs/specs/design-mail-gateway.md#configuration-design
**Created**: 2026-06-23
**Last Updated**: 2026-06-23

---

## Design Document Reference

**Source**: design-docs/specs/design-mail-gateway.md

### Summary

Allow the reader CLI to start from built-in local defaults when the implicit default config file is missing.

### Scope

**Included**: Synthesized default config for missing implicit config path, default Gmail credential/account IDs, default local storage/token/client paths, smoke tests, docs.
**Excluded**: Writing config files to disk automatically, bypassing explicit `--config` or `MAIL_GATEWAY_CONFIG` failures, live Gmail OAuth without a client JSON file.

---

## Modules

### 1. Config Loader Fallback

#### Sources/MailGatewayCore/ConfigLoading.swift

**Status**: Completed

```swift
public enum MailGatewayConfigLoader {
    public static func loadConfig(configPath: String?, environment: [String: String]) throws -> MailGatewayConfig
    public static func validateConfig(configPath: String?, environment: [String: String]) throws -> [String: Any]
}
```

**Checklist**:
- [x] Detect missing implicit default config path
- [x] Synthesize default storage, credential, and account values
- [x] Preserve strict failures for explicit config paths
- [x] Keep environment credential path overrides working

### 2. Tests And Documentation

#### Sources/MailGatewaySwiftSmokeTests/main.swift
#### README.md

**Status**: Completed

```swift
func testMissingDefaultConfigUsesFallback(cleanup: inout [String]) throws
```

**Checklist**:
- [x] Add smoke coverage for missing default config fallback
- [x] Verify explicit missing config still fails
- [x] Document default values
- [x] Run repo verification

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Config Loader Fallback | `Sources/MailGatewayCore/ConfigLoading.swift` | COMPLETED | Smoke tests passed |
| Tests And Documentation | `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md` | COMPLETED | Smoke tests passed |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Default Config Fallback | Existing configuration loader | Available |

## Tasks

### TASK-001: Default Config Fallback

**Status**: Completed
**Parallelizable**: No
**Deliverables**: `Sources/MailGatewayCore/ConfigLoading.swift`, `Sources/MailGatewaySwiftSmokeTests/main.swift`, `README.md`
**Dependencies**: None

**Description**:
Implement built-in defaults for missing implicit config files while preserving explicit config error behavior.

**Completion Criteria**:
- [x] Missing implicit default config validates successfully
- [x] Explicit missing config path still fails
- [x] Default `auth status --credential gmail-personal` works without config file
- [x] Swift build and smoke tests pass

## Completion Criteria

- [x] Fallback implementation completed
- [x] Tests passing
- [x] Documentation updated
- [x] Direct CLI behavior verified

## Progress Log

### Session: 2026-06-23 11:08
**Tasks Completed**: None yet
**Tasks In Progress**: TASK-001
**Blockers**: None
**Notes**: User requested default startup behavior when `~/.config/mail-gateway/config.toml` is missing.

### Session: 2026-06-23 11:10
**Tasks Completed**: TASK-001
**Tasks In Progress**: None
**Blockers**: None
**Notes**: Implemented synthesized defaults for missing implicit config. Verified default `config validate`, default `auth status`, default `auth login` missing-client failure, strict explicit missing config failure, `task ci`, and `git diff --check`.

## Related Plans

- **Previous**: None
- **Next**: None
- **Depends On**: None
