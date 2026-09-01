# gmail-gateway

Swift command-line gateway for Gmail workflows

## Development

```bash
mise install
mise run build
mise run test
swift run gmail-gateway-reader --help
swift run gmail-gateway-draft --help
swift run gmail-gateway-sender --help
swift run gmail-gateway-threads --help
swift run gmail-gateway-message-box --help
```

The package uses Swift Package Manager with:

- Library target: `GmailGatewayCore`
- Executable targets: `GmailGatewayReader`, `GmailGatewayDraft`, `GmailGatewaySender`,
  `GmailGatewayThreads`, `GmailGatewayMessageBox`
- Installed executables: `gmail-gateway-reader`, `gmail-gateway-draft`, `gmail-gateway-sender`,
  `gmail-gateway-threads`, `gmail-gateway-message-box`

## Binary Capabilities

Each binary exposes a strictly separate slice of the GraphQL surface:

All five binaries share one read surface: `accounts`, `account`, `threads`, `thread`,
`message`, `messageFileSet`, `attachment`, `labels`, and `profile`. Each then owns exactly
one group of mutations, and rejects every other group with an error naming the binary that
owns it.

| Binary | Owns | Access mode |
|--------|------|-------------|
| `gmail-gateway-reader` | Nothing; reads only | `read` |
| `gmail-gateway-draft` | `createDraft`, `createReplyDraft`, `createForwardDraft`, `updateDraft`, `deleteDraft`, `drafts`, `draft` | `read_send` |
| `gmail-gateway-sender` | `sendMessage`, `replyMessage`, `forwardMessage`, `sendDraft`, plus the whole draft surface | `read_send` |
| `gmail-gateway-threads` | Mailbox mutation: label changes, trash/untrash, label management, permanent delete | `read_modify` (`full` for permanent delete) |
| `gmail-gateway-message-box` | Mail ingestion: `importMessage`, `insertMessage` | `read_modify` |

Send mutations submitted to `gmail-gateway-draft` are rejected with
`SEND_DISABLED_IN_DRAFT_GATEWAY` before any provider call, so the draft binary has no
code path that can transmit mail. Draft mutations and queries submitted to
`gmail-gateway-reader` are rejected with `SEND_DISABLED_IN_READER`.

`createReplyDraft` and `createForwardDraft` build the same threaded reply and forward
content as `replyMessage` and `forwardMessage`, but always stop at draft creation, so the
draft binary can prepare threaded mail without gaining a send path.

### Draft, then send

`labels` is the only way to discover the label ids that the `threads` `labelIds` filter
accepts, and `profile` reports the authenticated mailbox and its totals:

```bash
swift run gmail-gateway-reader graphql --query 'query { labels(accountId: "personal") { id name type } }'
swift run gmail-gateway-reader graphql --query 'query { profile(accountId: "personal") { emailAddress messagesTotal threadsTotal } }'
```

Prepare a draft with the draft binary, then send it by id with the sender:

```bash
swift run gmail-gateway-draft graphql --query '
mutation {
  createReplyDraft(input: {
    accountId: "personal",
    messageId: "1930f0c2b1a4d5e6",
    replyAll: true,
    textBody: "Thanks, sending the report shortly."
  }) { draftId }
}'

swift run gmail-gateway-sender graphql --query '
mutation { sendDraft(input: { accountId: "personal", draftId: "r-1234567890" }) { operation status draftId messageId threadId } }'
```

### Updating a draft

`updateDraft` maps to the Gmail `drafts.update` draft-replacement call, so the gateway
rebuilds the draft from the merged state:

- header and body fields left out of the input keep the value already on the draft
- supplying `textBody` and/or `htmlBody` replaces the entire body with exactly what was
  supplied, so an update never leaves a stale HTML or text part behind
- attachments already on the draft are all retained unless `keepAttachmentIds` is given;
  when given, only the listed provider attachment ids survive, and `[]` drops all of them
- `attachmentPaths` adds validated local files on top of what is retained
- the draft keeps its provider thread, `In-Reply-To`, and `References` headers
- the merged result is validated exactly like `createDraft`, so the draft must still end up
  with at least one recipient and a body; a recipient-less draft created elsewhere has to be
  given a recipient in the same `updateDraft` call

Replace every attachment on a draft, keeping its headers and body:

```bash
swift run gmail-gateway-draft graphql --query '
mutation {
  updateDraft(input: {
    accountId: "personal",
    draftId: "r-1234567890",
    keepAttachmentIds: [],
    attachmentPaths: ["/allowed/send/root/report.pdf"]
  }) { operation status draftId messageId rejectedAttachments { path code reason } }
}'
```

Provider attachment ids for `keepAttachmentIds` come from the `draft` query:

```bash
swift run gmail-gateway-draft graphql --query '
query {
  draft(accountId: "personal", draftId: "r-1234567890") {
    id
    message { attachments { id filename providerMetadata { gmail { attachmentId } } } }
  }
}'
```

Delete a draft:

```bash
swift run gmail-gateway-draft graphql --query '
mutation { deleteDraft(input: { accountId: "personal", draftId: "r-1234567890" }) { operation status draftId } }'
```

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use identifier-safe values such as `GmailGatewayCore` and
`GmailGatewayReader` for Swift module/type variables.

## Access Modes

A credential's `access_mode` decides which capabilities it holds; the binary decides which
it exposes. Both must allow an operation for it to run.

| Access mode | Scopes | Grants |
|-------------|--------|--------|
| `read` | `gmail.readonly` | read |
| `read_send` | `gmail.readonly`, `gmail.compose`, `gmail.send` | read, send |
| `read_modify` | `gmail.readonly`, `gmail.modify`, `gmail.insert` | read, modify, insert |
| `full` | `https://mail.google.com/` | read, send, modify, insert, permanent delete |

`read_send` cannot mutate stored mail and `read_modify` cannot send, so a credential scoped
for one workflow cannot be borrowed for the other.

**Permanent delete requires `full`.** `deleteThread`, `deleteMessage`, and
`batchDeleteMessages` are irreversible, bypass Trash, and cannot be undone; Gmail accepts
only its full-access scope for them. Prefer `trashThread` and `trashMessage`, which are
reversible with `untrashThread` and `untrashMessage` and need only `read_modify`.

## Mailbox Mutation

`gmail-gateway-threads` changes stored mail and never composes, sends, or ingests it:

```bash
# Move a thread out of the inbox and tag it, in one call
swift run gmail-gateway-threads graphql --query '
mutation {
  modifyThreadLabels(input: {
    accountId: "personal",
    threadId: "1930f0c2b1a4d5e6",
    addLabelIds: ["Label_9"],
    removeLabelIds: ["INBOX"]
  }) { operation status threadId labelIds }
}'

# Reversible removal
swift run gmail-gateway-threads graphql --query '
mutation { trashMessage(input: { accountId: "personal", messageId: "1930f0c2b1a4d5e6" }) { status messageId } }'

# Label management
swift run gmail-gateway-threads graphql --query '
mutation { createLabel(input: { accountId: "personal", name: "Receipts", labelListVisibility: "labelShow" }) { labelId label { name } } }'
```

`updateLabel` patches rather than replaces, so naming only `name` leaves the visibility
settings untouched.

## Mail Ingestion

`gmail-gateway-message-box` adds existing RFC 822 mail to the mailbox without sending it.
`rfc822Path` must resolve under a configured `storage.allowed_send_attachment_roots` entry,
the same rule outbound attachments follow.

```bash
# Runs the normal delivery pipeline; accepts neverMarkSpam and processForCalendar
swift run gmail-gateway-message-box graphql --query '
mutation {
  importMessage(input: {
    accountId: "personal",
    rfc822Path: "/allowed/send/root/archived.eml",
    labelIds: ["INBOX"],
    internalDateSource: DATE_HEADER,
    neverMarkSpam: true
  }) { operation status messageId threadId }
}'

# Direct IMAP-APPEND-style add that bypasses most scanning
swift run gmail-gateway-message-box graphql --query '
mutation { insertMessage(input: { accountId: "personal", rfc822Path: "/allowed/send/root/archived.eml" }) { status messageId } }'
```

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render formulae after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.2
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.2
```

Install from the tap after the formula is published:

```bash
brew tap tacogips/tap
brew install gmail-gateway-reader
brew install gmail-gateway-draft
brew install gmail-gateway-sender
brew install gmail-gateway-threads
brew install gmail-gateway-message-box
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
