# Bounded archive reads

Issue: https://github.com/tacogips/gmail-gateway/issues/4

Expose additive reader GraphQL operations without changing write behavior or existing thread search:

- `messageIds(accountId: ID!, query: String!, first: Int, after: String, includeSpamTrash: Boolean): GmailMessageIdPage!`. Default page size 50, maximum 100. Return only message/thread IDs and PageInfo; no body hydration, default-label or date filters. Cursor binds configured account identity, query, page size and spam/trash flag. A changed query must start a new scan. Provider pagination is not a mailbox snapshot; caller must deduplicate message IDs and independently fence the authenticated profile.
- `attachmentBytes(accountId: ID!, messageId: ID!, attachmentId: ID!, maxBytes: Int): GmailAttachmentBytes!`. Default/cap 20 MiB decoded; exact bytes returned as standard base64, byteCount and SHA256. No local file/cache materialization. Filename and MIME remain message metadata. Raw output must stay inside the caller's isolated inspection boundary.

A dedicated ephemeral URLSession GET transport stops declared or streamed oversize responses, rejects redirects, does not use cookies/disk caches, and observes the SDK cancellation context. It uses only fixed Gmail endpoints and an absolute 30-second wait. These new reads do not automatically retry. Cancellation is checked before credential resolution.

Provider contract references:
- https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list
- https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get

Verification: synthetic URLProtocol fixtures for exact request count, no hydration, cursor/filter mismatch, attachment bytes/hash/size, malformed identities/base64, streamed and declared bounds, cancellation before credential lookup; schema and complete package regressions. No real Gmail requests are authorized by these tests.

`messagePartBytes(accountId, messageId, partId, maxBytes)` reads an exact inline filename MIME part (including dotted or empty root part IDs), never an inferred attachment ID. It validates unique part identity and message ID, rejects remote-only/missing bytes, bounds the full-message response to 32 MiB and decoded bytes to 20 MiB, and returns `partId`, base64 bytes, byte count and SHA-256. Duplicate filenames remain distinct by part ID. Larger messages fail explicitly for caller reconciliation; no bytes are written to disk.
