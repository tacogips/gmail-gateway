# GraphQL Yoga Migration Implementation Plan

**Status**: Completed
**Design Reference**: design-docs/specs/design-mail-gateway.md#GraphQL Design
**Created**: 2026-03-16
**Last Updated**: 2026-03-16

---

## Design Document Reference

**Source**: design-docs/specs/design-mail-gateway.md

### Summary

Replace the current direct GraphQL.js execution path with `graphql-yoga` while preserving the existing one-shot CLI GraphQL contract and error shape.

### Scope

**Included**: dependency update, schema/execution migration, regression tests, verification
**Excluded**: transport redesign, schema shape changes, resolver feature expansion

---

## Modules

### 1. GraphQL Execution

#### src/graphql.ts

**Status**: COMPLETED

**Checklist**:

- [x] Replace direct `graphql()` execution with Yoga execution
- [x] Preserve current query result envelope and exit code behavior
- [x] Preserve app error mapping into GraphQL error extensions

### 2. Dependency And Tests

#### package.json

#### bun.lock

#### src/lib.test.ts

**Status**: COMPLETED

**Checklist**:

- [x] Add `graphql-yoga` dependency through Bun
- [x] Cover the migrated execution path with regression tests
- [x] Keep typecheck and Bun tests passing

---

## Completion Criteria

- [x] GraphQL queries execute via `graphql-yoga`
- [x] CLI GraphQL JSON response shape remains compatible
- [x] Type checking passes
- [x] Bun tests pass

## Progress Log

### Session: 2026-03-16 00:00

**Tasks Completed**: Plan created
**Tasks In Progress**: GraphQL execution migration, dependency update, regression tests
**Blockers**: None
**Notes**: Replace the core GraphQL.js execution call with Yoga while keeping the current CLI contract stable.

### Session: 2026-03-16 00:30

**Tasks Completed**: GraphQL execution migration, dependency update, regression tests
**Tasks In Progress**: None
**Blockers**: None
**Notes**: Installed `graphql-yoga`, moved the one-shot execution path to Yoga request handling, preserved app error extensions, and verified with Prettier, typecheck, and Bun tests.
