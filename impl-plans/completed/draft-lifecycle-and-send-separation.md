# Draft Lifecycle And Send Separation

## Design Reference

- `design-docs/specs/design-gmail-gateway.md`
- `impl-plans/completed/draft-default-sender-split.md`

## Scope

Give `gmail-gateway-draft` the full draft lifecycle and remove every send path from it:

- Add `updateDraft` (Gmail `drafts.update`) with attachment replacement.
- Add `deleteDraft` (Gmail `drafts.delete`).
- Add the `drafts` and `draft` queries so callers can discover draft ids and the
  provider attachment ids that `updateDraft` `keepAttachmentIds` refers to.
- Stop routing `sendMessage` to draft creation in `gmail-gateway-draft`; reject
  `sendMessage`, `replyMessage`, and `forwardMessage` there with
  `SEND_DISABLED_IN_DRAFT_GATEWAY` so only `gmail-gateway-sender` can transmit mail.

## Tasks

- [x] Split oversized sources ahead of the feature work: extract `GmailAPIRequests.swift`
      and `GmailMessageParsing.swift` from `GmailLiveReader.swift`, and
      `GmailGatewayGraphQLSelection.swift` / `GmailGatewayGraphQLArguments.swift` from
      `GmailGatewayGraphQL.swift`.
- [x] Add `GmailGatewayWriteOperation` so draft operations carry their own auth context,
      mutation name, and `draftId` reporting rule instead of reusing the two write modes.
- [x] Add Gmail draft transport (`GmailLiveDrafts.swift`) plus PUT/DELETE request helpers.
- [x] Add `UpdateDraftInput` and the draft service layer with retain-on-omit merge semantics,
      all-or-nothing body replacement, and `keepAttachmentIds` attachment retention.
- [x] Add the draft GraphQL surface (`GmailGatewayGraphQLDrafts.swift`) and gate send
      mutations on `.directSend`; reject the draft surface in the reader.
- [x] Carry `In-Reply-To` through `MailMessage` so an updated reply draft keeps its threading.
- [x] Add unit and smoke coverage for the capability boundaries and the update semantics.
- [x] Refresh binary help text, README, and the design spec.

## Decisions

- `updateDraft` maps to a provider draft-replacement call, so it rebuilds the draft from the
  merged state. Fields left out are read back from the existing draft; supplying `textBody`
  and/or `htmlBody` replaces the whole body so an update cannot leave a stale alternative part.
- `keepAttachmentIds` is a single knob: omitted keeps all attachments, `[]` drops all, and a
  list keeps exactly those ids. Unknown ids fail with `ATTACHMENT_NOT_FOUND` before the write.
- `updateDraft` reuses the outbound validation that `createDraft` already applies, so a draft
  must still have at least one recipient and a body. A draft created outside the gateway with
  no recipient cannot be updated through it until a recipient is supplied in the same call.
- `gmail-gateway-sender` keeps the whole draft surface; only the draft binary loses send.

## Verification

- `swift build`
- `swift test` (112 tests)
- `swift run gmail-gateway-swift-smoke-tests`
- `swiftlint` (0 violations)

## Progress Log

- 2026-09-01: Split the oversized reader and GraphQL sources, added the Gmail draft
  update/delete/read transport and service layers, added the draft GraphQL surface, removed
  every send path from `gmail-gateway-draft`, and refreshed help text, README, and the spec.
