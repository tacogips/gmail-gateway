# Gmail API Surface Gaps

## Design Reference

- `design-docs/specs/design-gmail-gateway.md`
- Gmail API v1 REST reference (verified 2026-09-01)

## Scope

Audit the full Gmail API v1 method list against the three binaries and add the methods that
fit each binary's charter.

## Gap Analysis

Verified against the Gmail API v1 resource/method enumeration. Gaps that fit an existing
binary charter:

| Gmail method | Binary | Added as |
|---|---|---|
| `users.labels.list` | reader | `labels(accountId:)` |
| `users.getProfile` | reader | `profile(accountId:)` |
| threaded draft composition | draft | `createReplyDraft`, `createForwardDraft` |
| `users.drafts.send` | sender | `sendDraft(accountId:draftId:)` |

`labels` closes a usability hole: `ThreadSearchInput.labelIds` already existed with no way to
discover label ids. `sendDraft` closes a workflow hole: drafts prepared by the draft binary
had no send path at all. `createReplyDraft` and `createForwardDraft` restore threaded draft
composition to the draft binary, which lost it when `replyMessage` and `forwardMessage`
became sender-only; they never send.

Deliberately not added, because they do not fit read / draft / send and need a capability
decision rather than an addition: mailbox mutation (`messages`/`threads` modify, trash,
untrash, delete, batch; `labels` create/update/patch/delete), all `users.settings.*`
administration, `history.list` (Phase 3 sync), `users.watch`/`users.stop` (needs serve mode),
and `messages.import`/`messages.insert`.

## Tasks

- [x] Verify the Gmail API v1 method list and the scopes for the added endpoints.
- [x] Add `labels` and `profile` reads with `MailLabel`/`MailProfile` models.
- [x] Add `createReplyDraft` and `createForwardDraft` draft-only mutations.
- [x] Add `sendDraft` with the `SEND_DRAFT` operation and sender-only gating.
- [x] Extend the capability boundary tests, smoke coverage, help text, README, and spec.

## Decisions

- No OAuth scope change was needed: `gmail.readonly` covers `labels.list` and `getProfile`,
  and the already-requested `gmail.compose` covers `drafts.send`.
- `sendDraft` is a send operation, so it lives with the other sends in `GmailLiveWriter` and
  is listed in `sendMutationRootFields`; the draft binary rejects it.
- `MailWriteResult` now reports `draftId` for `SEND_DRAFT` too, so a caller can correlate the
  draft it sent with the resulting message.

## Verification

- `swift build`
- `swift test` (120 tests)
- `swift run gmail-gateway-swift-smoke-tests`
- `swiftlint` (0 violations)

## Progress Log

- 2026-09-01: Audited the Gmail API v1 surface, added the reader label/profile reads, the
  draft-only threaded draft mutations, and the sender `sendDraft`, with tests and docs.
