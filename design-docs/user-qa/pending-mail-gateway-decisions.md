# Mail Gateway Resolved Decisions

**Status**: Resolved

**Created**: 2026-03-13

**Category**: Mail Gateway Product Design

## Resolved Defaults

The initial product decisions are fixed for implementation as follows.

## Decision 1: Required Transport for v1

Chosen: one-shot `graphql` only.

## Decision 2: Attachment Retention Policy

Chosen: persistent cache until explicit cleanup via `cache prune`.

## Decision 3: v1 Send Scope

Chosen: Phase 2 starts with new outbound messages only.

## Decision 4: Inline Image Size Limit

Chosen: inline attachment payloads are not supported. Attachments are exchanged only as files and local file paths to minimize AI token usage.

## Impact

These choices affect:

- [design-mail-gateway.md](../specs/design-mail-gateway.md)
- [command.md](../specs/command.md)
- future implementation plan scope and delivery phases

## Outcome

These defaults are reflected in the design specs and the reader-first implementation.
