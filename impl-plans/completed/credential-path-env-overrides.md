# Credential Path Env Overrides Implementation Plan

**Status**: Completed
**Design Reference**: design-docs/specs/design-mail-gateway.md#Configuration Model
**Created**: 2026-03-15
**Last Updated**: 2026-03-15

---

## Design Document Reference

**Source**: design-docs/specs/design-mail-gateway.md

### Summary
Allow Gmail credential path settings to be omitted from `config.toml` and resolved from environment variables, while preserving TOML fallback and existing multi-credential behavior.

### Scope
**Included**: Config loader changes, CLI env propagation, tests, and setup/configuration documentation
**Excluded**: OAuth implementation, Gmail API fetch logic, token content changes

---

## Modules

### 1. Config Loading

#### src/config.ts

**Status**: COMPLETED

```typescript
interface CredentialConfig {
  readonly id: string;
  readonly provider: MailProvider;
  readonly accessMode: AccessMode;
  readonly oauthClientSecretPath: string;
  readonly tokenStorePath: string;
}
```

**Checklist**:
- [x] Allow credential path keys to be omitted from TOML
- [x] Resolve per-credential env overrides before TOML values
- [x] Fail clearly when neither env nor TOML provides a required path
- [x] Preserve path normalization and existing validation

### 2. CLI And Tests

#### src/cli.ts
#### src/lib.test.ts

**Status**: COMPLETED

**Checklist**:
- [x] Pass CLI env through to config loading and validation
- [x] Add tests for env-only credential path configuration
- [x] Add tests for env override precedence over TOML

### 3. Documentation

#### design-docs/specs/design-mail-gateway.md
#### design-docs/specs/design-gmail-credentials.md
#### design-docs/specs/command.md

**Status**: COMPLETED

**Checklist**:
- [x] Document supported env variable names and precedence
- [x] Document that TOML credential path keys are optional when env vars are used

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Config loading | `src/config.ts` | COMPLETED | Passed |
| CLI/test updates | `src/cli.ts`, `src/lib.test.ts` | COMPLETED | Passed |
| Documentation | `design-docs/specs/*.md` | COMPLETED | N/A |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Credential path env overrides | Existing config loader and CLI | Available |

## Completion Criteria

- [x] Credential path config works with TOML only
- [x] Credential path config works with env only
- [x] Env values take precedence over TOML values
- [x] Tests passing
- [x] Type checking passes

## Progress Log

### Session: 2026-03-15 00:00
**Tasks Completed**: Plan created
**Tasks In Progress**: Config loader, CLI env plumbing, tests, docs
**Blockers**: None
**Notes**: Implement per-credential env variable overrides so public-safe TOML can omit local secret paths.

### Session: 2026-03-15 00:30
**Tasks Completed**: Config loader, CLI env plumbing, tests, docs
**Tasks In Progress**: None
**Blockers**: None
**Notes**: Added per-credential env precedence for credential path settings, preserved TOML fallback, and verified with formatter, typecheck, and Bun tests.

## Related Plans

- **Previous**: None
- **Next**: None
- **Depends On**: None
