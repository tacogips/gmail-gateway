# QA: Decisions Arising from the 2026-07 Implementation Review

Source: `design-docs/specs/design-implementation-review-2026-07.md`

These items were raised during the review because they changed externally
visible behavior or the spec contract. Resolved items record the implemented
decision; unresolved items still need a future decision.

## Q1. Body materialization direction (review item 1.1) - Resolved

Decision: materialize bodies on demand inside `file download`. GraphQL remains
metadata-only and returns `downloadKey` values for body variants.

## Q2. Inline bodies vs file-only bodies (review items 2.2, 5.1) - Resolved

Decision: enforce file-only bodies for read responses. `message` and `thread`
responses do not inline decoded text or HTML body payloads; callers use
`messageFileSet` plus `file download`.

## Q3. GraphQL variables (review item 1.2) - Resolved

Decision: reject `--variables` / `--variables-file` with a clear "not
supported" error until a real GraphQL library is adopted.

## Q4. GraphQL execution engine - Resolved

Decision: keep the hand-rolled scanner for now, document that the reader
rejects write root fields before resolver dispatch instead of exposing a
separate reduced schema, and cover scanner boundary behavior with adversarial
tests for comments, aliases, fragments/spreads, multiple root fields, and
unsupported arguments.

## Q5. Thread search backend (review item 1.4) - Resolved

Decision: use Gmail `threads.list` for thread search and fetch full thread
nodes only when requested by the GraphQL selection.

## Q6. TOML parsing (review item 7.1) - Resolved

Decision: keep the zero-dependency subset parser, with trailing-comment and
basic string escape handling documented by tests.

## Q7. Unsupported thread search filters (review item 1.5) - Resolved

Decision: reject unsupported `ThreadSearchInput` fields and unsupported direct
`threads(...)` arguments with `INVALID_ARGUMENT` rather than silently ignoring
them. `unread`, `from`, and `hasAttachments` remain future schema additions
until implemented end to end.

## Q8. Canonical read model typing (review item 8.1) - Resolved

Decision: use typed `Codable` canonical models for Gmail provider outputs
(`MailThreadConnection`, `MailThread`, `MailMessage`, `MailAttachment`,
`MailWriteResult`, and related metadata) and convert them to GraphQL JSON only
at the service boundary. CLI/config parsing and final JSON serialization may
still use `[String: Any]` where the data is inherently dynamic.
