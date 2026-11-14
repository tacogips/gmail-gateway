# Draft Default Sender Split

## Design Reference

- `design-docs/specs/design-mail-gateway.md`
- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`

## Scope

Make outbound mail behavior explicit by binary:

- `mail-gateway-reader` remains read-only and rejects write mutations.
- `mail-gateway-draft` treats the outbound `sendMessage` mutation as draft creation by default.
- `mail-gateway-sender` is the only executable that maps `sendMessage` to direct provider send, and it also exposes draft creation.

## Tasks

- [x] Update Swift package products and executable targets for `mail-gateway-draft` and `mail-gateway-sender`.
- [x] Add write-mode CLI routing while preserving the current reader command behavior.
- [x] Add draft-default and direct-send GraphQL execution paths with separate error context and access checks.
- [x] Make `mail-gateway-sender` a superset of draft behavior through `createDraft`.
- [x] Add smoke coverage for reader rejection, draft-default routing, sender routing, and package target availability.
- [x] Refresh README, Taskfile, and release/install commands.

## Verification

- `swift build`
- `swift run mail-gateway-swift-smoke-tests`
- `task ci`
- `git diff --check`

## Progress Log

- 2026-06-25: Created plan after Riela design/implement workflow stalled during Step 2. Riela session was started with the requested behavior, produced unrelated intake notes, and was stopped before local implementation continued.
- 2026-06-25: Added `mail-gateway-draft` and `mail-gateway-sender` products and executable targets, write-mode CLI routing, draft-default/direct-send GraphQL dispatch, Gmail draft/send adapters, smoke coverage, and README/Taskfile updates.
- 2026-06-25: Renamed the default draft executable from `mail-gateway` to `mail-gateway-draft` so the binary family is `mail-gateway-reader`, `mail-gateway-draft`, and `mail-gateway-sender`.
- 2026-06-25: Added `createDraft` to the write GraphQL surface so `mail-gateway-sender` includes draft creation while keeping `sendMessage` as direct send.
- 2026-06-25: Verified with `swift build`, `swift run mail-gateway-swift-smoke-tests`, `task ci`, and `git diff --check`.
