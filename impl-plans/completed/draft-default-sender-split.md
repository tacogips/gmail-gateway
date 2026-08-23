# Draft Default Sender Split

## Design Reference

- `design-docs/specs/design-gmail-gateway.md`
- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`

## Scope

Make outbound mail behavior explicit by binary:

- `gmail-gateway-reader` remains read-only and rejects write mutations.
- `gmail-gateway-draft` treats the outbound `sendMessage` mutation as draft creation by default.
- `gmail-gateway-sender` is the only executable that maps `sendMessage` to direct provider send, and it also exposes draft creation.

## Tasks

- [x] Update Swift package products and executable targets for `gmail-gateway-draft` and `gmail-gateway-sender`.
- [x] Add write-mode CLI routing while preserving the current reader command behavior.
- [x] Add draft-default and direct-send GraphQL execution paths with separate error context and access checks.
- [x] Make `gmail-gateway-sender` a superset of draft behavior through `createDraft`.
- [x] Add smoke coverage for reader rejection, draft-default routing, sender routing, and package target availability.
- [x] Refresh README, Taskfile, and release/install commands.

## Verification

- `swift build`
- `swift run gmail-gateway-swift-smoke-tests`
- `mise run ci`
- `git diff --check`

## Progress Log

- 2026-06-25: Created plan after Riela design/implement workflow stalled during Step 2. Riela session was started with the requested behavior, produced unrelated intake notes, and was stopped before local implementation continued.
- 2026-06-25: Added `gmail-gateway-draft` and `gmail-gateway-sender` products and executable targets, write-mode CLI routing, draft-default/direct-send GraphQL dispatch, Gmail draft/send adapters, smoke coverage, and README/Taskfile updates.
- 2026-06-25: Renamed the default draft executable from `gmail-gateway` to `gmail-gateway-draft` so the binary family is `gmail-gateway-reader`, `gmail-gateway-draft`, and `gmail-gateway-sender`.
- 2026-06-25: Added `createDraft` to the write GraphQL surface so `gmail-gateway-sender` includes draft creation while keeping `sendMessage` as direct send.
- 2026-06-25: Verified with `swift build`, `swift run gmail-gateway-swift-smoke-tests`, `mise run ci`, and `git diff --check`.
