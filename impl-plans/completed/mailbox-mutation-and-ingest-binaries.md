# Mailbox Mutation And Ingest Binaries

## Design Reference

- `design-docs/specs/design-gmail-gateway.md`
- `impl-plans/completed/gmail-api-surface-gaps.md`

## Scope

Give the previously unmapped Gmail surface a home, as two new binaries:

- `gmail-gateway-threads`: `messages`/`threads` modify, trash, untrash, delete, and the batch
  variants, plus `labels` create/update/delete.
- `gmail-gateway-message-box`: `messages.import` and `messages.insert`.

Each binary owns exactly one mutation group and rejects the others with an error naming the
binary that owns them, extending the existing read / draft / send separation.

## Tasks

- [x] Add the `MailboxCapability` model and the `read_modify` and `full` access modes, with
      their scopes, and replace the hardcoded `read_send` check with a capability check.
- [x] Add mailbox mutation transport (`GmailLiveMailbox`) and ingestion transport
      (`GmailLiveIngest`), plus PATCH and empty-response POST request helpers.
- [x] Add the service layer with argument validation that runs before any provider call.
- [x] Add the GraphQL surface and the cross-binary rejection for all four mutation groups.
- [x] Add the two executable targets, CLI modes, help text, doctor capability reporting,
      mise tasks, and Homebrew release product entries.
- [x] Add 22 tests and smoke coverage for the capability model and the binary boundaries.

## Decisions

- Labels create/update/delete went to `gmail-gateway-threads` rather than a third new binary:
  labels are the primitive the modify mutations operate on, so label management and label
  changes are one capability.
- `updateLabel` maps to the provider PATCH rather than PUT, so an update that names one field
  does not clear the others.
- Permanent delete is separated from the rest of mailbox mutation by access mode, not just by
  mutation name. Gmail accepts only its full-access scope for delete, so `read_modify` grants
  trash and label changes while `full` is required to destroy mail.
- The capability model is not a privilege ladder: `read_send` does not grant modify and
  `read_modify` does not grant send.
- Ingestion names its source by local path, validated against the same allowed roots that
  outbound attachments use, so it cannot read arbitrary files.

## Verification

- `swift build`
- `swift test` (142 tests)
- `swift run gmail-gateway-swift-smoke-tests`
- `swiftlint` (0 violations)

## Progress Log

- 2026-09-01: Added the capability-based access model, the mailbox and ingest transports and
  services, the two new binaries with full cross-binary gating, and tests and docs.
