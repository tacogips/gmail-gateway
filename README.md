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
```

The package uses Swift Package Manager with:

- Library target: `GmailGatewayCore`
- Executable targets: `GmailGatewayReader`, `GmailGatewayDraft`, `GmailGatewaySender`
- Installed executables: `gmail-gateway-reader`, `gmail-gateway-draft`, `gmail-gateway-sender`

## Binary Capabilities

Each binary exposes a strictly separate slice of the GraphQL surface:

| Binary | Reads | Drafts | Sends |
|--------|-------|--------|-------|
| `gmail-gateway-reader` | Yes | No | No |
| `gmail-gateway-draft` | Yes | `createDraft`, `updateDraft`, `deleteDraft`, `drafts`, `draft` | No, never |
| `gmail-gateway-sender` | Yes | Same draft surface as the draft binary | `sendMessage`, `replyMessage`, `forwardMessage` |

Send mutations submitted to `gmail-gateway-draft` are rejected with
`SEND_DISABLED_IN_DRAFT_GATEWAY` before any provider call, so the draft binary has no
code path that can transmit mail. Draft mutations and queries submitted to
`gmail-gateway-reader` are rejected with `SEND_DISABLED_IN_READER`.

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
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
