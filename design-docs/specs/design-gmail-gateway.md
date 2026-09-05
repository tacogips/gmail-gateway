# Gmail Gateway Design

This document defines the product and technical design for an AI-oriented gmail gateway that initially supports Gmail and can be extended to other mail providers later.

## Overview

Phase 1 ships one Swift Package Manager binary:

- `gmail-gateway-reader`: read-only access to configured mail accounts

Phase 2 adds:

- `gmail-gateway-draft`: read access plus the outbound draft lifecycle (create, update, delete, read); it can never send mail
- `gmail-gateway-sender`: explicit direct-send access to configured mail accounts, including the draft lifecycle
- `gmail-gateway-threads`: mailbox mutation (label changes, trash/untrash, label management, permanent delete); it never composes, sends, or ingests
- `gmail-gateway-message-box`: ingestion of existing RFC 822 mail through `importMessage` and `insertMessage`; it never sends

All business operations are exposed through GraphQL. The CLI surface exists only for bootstrapping, configuration validation, authentication setup, cache maintenance, and GraphQL transport.

## Goals

- Support multiple mail accounts in one configuration file
- Allow each account to reference a different Gmail credential set and token store
- Make account selection explicit for read operations
- Model all read operations through GraphQL in Phase 1
- Return body, attachment, and temporary-file metadata through GraphQL using
  `downloadKey` values instead of payload bytes
- Exchange binary and body payloads only through explicit gateway file download
  commands so AI callers do not consume tokens on large payloads
- Keep the provider layer extensible so Gmail is only the first adapter

## Non-Goals

- Implement IMAP/SMTP as a first milestone
- Build a generic web UI
- Support inline attachment payloads in GraphQL responses
- Synchronize an entire mailbox into a local database in v1
- Ship long-running `serve` mode in Phase 1
- Build a generic conversation UI on top of reply/forward threading

## Product Surface

### Binary Capabilities

| Binary | Read Mail | Send Mail | GraphQL Schema |
|--------|-----------|-----------|----------------|
| `gmail-gateway-reader` | Yes | No | `Query` only, plus local-cache side effects such as attachment materialization |
| `gmail-gateway-draft` | Yes | No, never | `Query`, draft `Query` (`drafts`, `draft`), and the draft lifecycle `Mutation` (`createDraft`, `createReplyDraft`, `createForwardDraft`, `updateDraft`, `deleteDraft`) |
| `gmail-gateway-sender` | Yes | Yes, explicit direct send plus `sendDraft` | `Query`, draft `Query`, direct-send `Mutation`, and the draft lifecycle `Mutation` |
| `gmail-gateway-threads` | Yes | No | `Query` plus the mailbox-mutation `Mutation`: label changes, trash/untrash, label management, and permanent delete |
| `gmail-gateway-message-box` | Yes | No | `Query` plus the ingestion `Mutation`: `importMessage` and `insertMessage` |

Every binary publishes an authorized catalog containing exactly the root fields in this
table. A root field declared by the full Gmail catalog but absent from the binary's
catalog fails before resolver dispatch with `CAPABILITY_DENIED` and names the mode.
Credential access-mode checks remain a second, service-owned authorization boundary.

### GraphQL Transport Modes

The primary mode is a one-shot CLI invocation:

```bash
gmail-gateway-reader graphql --query-file ./query.graphql
```

`--variables` and `--variables-file` are first-class and mutually exclusive. Each accepts
a JSON object; the file form reads that object from disk. Values remain separate from the
GraphQL document and are never interpolated into query text.

An optional long-running mode may be added later:

```bash
gmail-gateway-draft serve --listen 127.0.0.1:9407
```

For Phase 1, the one-shot `graphql` command is the required transport because it is simpler for local AI tool integration and avoids introducing daemon lifecycle management as a prerequisite.

## Configuration Design

Configuration is stored in TOML at:

- Default: `$XDG_CONFIG_HOME/gmail-gateway/config.toml`
- Override: `--config <path>` or `GMAIL_GATEWAY_CONFIG`

### Configuration Model

Credential profiles are defined independently from mail accounts. Mail accounts reference a credential profile by ID. This allows:

- multiple Gmail accounts using the same OAuth client configuration but different token stores
- multiple Gmail OAuth client configurations for different Google Cloud projects
- future providers to reuse the same account and credential graph without changing the higher-level API

Credential profiles also declare an explicit `access_mode`:

- `read`: read-only token scope
- `read_send`: read, draft creation, and send token scopes
- `read_modify`: read, mailbox mutation, and message insertion scopes
- `full`: read, send, mailbox mutation, insertion, and permanent-delete scope

This allows `auth login` and `auth status` to detect scope mismatches between configured intent and stored token metadata.

Credential path keys support a public-safe configuration mode:

- `oauth_client_secret_path` is optional when `GMAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_PATH` is set
- `token_store_path` is optional when `GMAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_PATH` is set
- if both TOML and env are present, the environment variable wins
- `<CREDENTIAL_ID>` is the credential ID uppercased with non-alphanumeric characters replaced by `_`

### Example Configuration

```toml
[storage]
cache_dir = "/home/taco/.local/share/gmail-gateway"
attachment_dir = "/home/taco/.cache/gmail-gateway/attachments"
allowed_send_attachment_roots = ["/home/taco/outbox-attachments"]

[[credentials]]
id = "gmail-personal-oauth"
provider = "gmail"
access_mode = "read"

[[credentials]]
id = "gmail-work-oauth"
provider = "gmail"
access_mode = "read_send"
oauth_client_secret_path = "/home/taco/.config/gmail-gateway/google-work-client.json"
token_store_path = "/home/taco/.config/gmail-gateway/tokens/work.json"

[[accounts]]
id = "personal"
provider = "gmail"
email_address = "me.personal@example.com"
credential_id = "gmail-personal-oauth"
default_label_ids = ["INBOX"]

[[accounts]]
id = "work"
provider = "gmail"
email_address = "me.work@example.com"
credential_id = "gmail-work-oauth"
default_label_ids = ["INBOX", "IMPORTANT"]
```

### Configuration Rules

- `credentials.id` and `accounts.id` must be unique within the file
- `accounts.credential_id` must reference a credential with the same `provider`
- `credentials.access_mode` must be `read`, `read_send`, `read_modify`, or `full`
- `credentials.oauth_client_secret_path` and `credentials.token_store_path` may be omitted when their per-credential env overrides are set
- token stores must be per account or per principal; sharing one token file across unrelated identities is invalid
- attachment and cache directories must be created on demand with user-only permissions
- send attachments must resolve under `storage.allowed_send_attachment_roots`
- secret-bearing files must never be returned through GraphQL

## GraphQL Design

### Schema Principles

- GraphQL is the only business API surface
- account selection is always explicit in message and thread queries
- provider-specific details are exposed in a namespaced way only when the canonical model is insufficient
- the full draft lifecycle (create, update, delete, read) exists in `gmail-gateway-draft`
- send operations (`sendMessage`, `replyMessage`, `forwardMessage`) exist only in
  `gmail-gateway-sender`; other modes deny them with `CAPABILITY_DENIED` before
  resolver dispatch
- filesystem materialization paths are returned only by explicit gateway
  download commands, not by GraphQL message or file metadata
- nested thread and message queries return metadata only; payload retrieval is
  performed only through explicit gateway download commands
- attachment payloads are never inlined into GraphQL responses
- body and temporary-file payloads are never inlined into GraphQL responses;
  GraphQL returns vendor-neutral `downloadKey` metadata, and file bytes are
  retrieved only by an explicit gateway download command. Callers may repeat
  `--key` to download multiple selected files in one gateway invocation.

### Phase 1d Normative Catalog and Runtime Contract

Phase 1d is the single `issue-resolution` work package identified by
`/Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk@feat/gateway-sdk:phase-1d`.
Its accepted planning decision is `accepted_with_low_findings` (`comm-001238`,
`needs_revision: false`). Normative and
repository guidance for this work package is:

- repository brief: `design-docs/briefs/gateway-sdk-2026-09-04.md`;
- master behavior brief: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`,
  especially sections 2, 2.6, and 3.4;
- agent guidance: `AGENTS.md`, `.codex/skills/swift-coding-agent/SKILL.md`, and the Riela
  workflow contract `/Users/taco/gits/tacogips/riela/.codex/skills/riela-impl-workflow/SKILL.md`; and
- immutable runtime reference:
  `/Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime` at commit
  `4d4b56c686f6875defccb54f74e2276022eb524e`.

There is no Cursor-specific CLI behavior to preserve or adapt. Raw query, explicit query,
schema, search, and operation behavior stays behind `GmailGatewayCLI` and the shared
`GmailGatewayGraphQLExecutor`; no editor-specific path may bypass catalog or service
authorization.

Phase 1d replaces the substring scanner with the committed `GatewaySDKKit` runtime. The
following ownership rules are normative:

- `GatewaySchemaCatalog.gmailFull` declares every Gmail query, mutation, argument,
  input, payload, object, enum, scalar, summary, and destructive marker. Every root
  field has exactly one resolver, and runtime construction fails if the catalog and
  resolver registry differ in either direction.
- Every operation has a non-empty summary. `deleteDraft`, `deleteThread`,
  `deleteMessage`, `batchDeleteMessages`, `deleteLabel`, `trashThread`, and
  `trashMessage` are marked destructive; reversible `untrash` operations are not.
- `GatewaySchemaCatalog.gmail(mode:)` is the only binary-mode authorization catalog.
  It is a subset of `gmailFull`, uses stable tier strings `reader`, `draft`, `sender`,
  `threads`, and `message-box`, and validates without problems for every mode.
- After phase 1d lands, `Sources/GmailGatewayCore/Schema/GmailGatewaySchema*.swift` is
  the machine-readable schema source of truth. This document defines the required
  behavior and authorization boundary; the existing service-produced `[String: Any]`
  payloads define field spelling and nullability where older prose differs.
- `GmailGatewayGraphQLScanning.swift`, `GmailGatewayGraphQLArguments.swift`, and
  `GmailGatewayGraphQLSelection.swift` are removed, together with scanner-only dispatch,
  root-field arrays, and rejection helpers. No compatibility parser or scanner adapter is
  retained.
- The full catalog validates syntax and types before authorization. A valid full-catalog
  operation missing from the mode catalog returns `CAPABILITY_DENIED`, not
  `UNKNOWN_FIELD`, and no resolver or provider request runs.

The authorized operation sets are exact, not cumulative across unrelated capabilities:

| Mode / tier | Queries | Mutations |
|-------------|---------|-----------|
| `reader` | `accounts`, `account`, `threads`, `thread`, `message`, `messageFileSet`, `attachment`, `labels`, `profile` | None |
| `draft` | Reader queries plus `drafts`, `draft` | `createDraft`, `createReplyDraft`, `createForwardDraft`, `updateDraft`, `deleteDraft` |
| `sender` | Reader queries plus `drafts`, `draft` | Draft mutations plus `sendMessage`, `replyMessage`, `forwardMessage`, `sendDraft` |
| `threads` | Reader queries | `modifyThreadLabels`, `modifyMessageLabels`, `batchModifyMessageLabels`, `trashThread`, `untrashThread`, `trashMessage`, `untrashMessage`, `deleteThread`, `deleteMessage`, `batchDeleteMessages`, `createLabel`, `updateLabel`, `deleteLabel` |
| `message-box` | Reader queries | `importMessage`, `insertMessage` |

Catalog authorization never replaces credential authorization. Resolvers load config and
credential inputs only from `GatewayResolverContext.environment`, compose the existing
services, and preserve their `MailboxCapability` / `AccessMode` checks. Resolver adapters
carry existing `GmailGatewayError` codes into `GatewayResolverError`; unexpected failures
use the runtime's generic resolver error without exposing credentials or provider payloads.
Thus, for example, the `threads` mode exposes permanent-delete fields, but the service
still requires `full`, while reversible mailbox changes require `read_modify`; the
`sender` and `message-box` modes cannot borrow those capabilities.

`GmailGatewayGraphQLExecutor` is the single execution path for both
`GmailGatewayCLI` and `GmailGatewaySDK`. Its data flow is:

1. accept a document, a `[String: GatewayJSONValue]` variable object, a mode, and an
   explicit environment; construct `GatewayGraphQLRuntime` with `gmailFull`, the mode
   catalog, the complete resolver registry, and a generated request ID;
2. preflight parse and validate only to estimate provider cost, then reject authorized
   work above 1,000 estimated Gmail requests with a runtime-compatible envelope; a
   request-scoped shared budget also consumes one permit immediately before every
   Gmail HTTP attempt (including GET retries and attachment downloads), rejecting
   attempt 1,001 before it dispatches;
3. let the kit parse, validate, authorize, coerce input objects and variables, invoke
   resolvers, and project aliases and nested selections; and
4. return the kit `GatewayEnvelope`, preserving missing projected keys as `null` and
   existing Gmail service error codes.

Queries may contain multiple root fields and use the kit's bounded concurrent execution;
mutations contain exactly one root field. Fragments, directives, subscriptions, multiple
operations, and introspection remain unsupported according to the shared runtime contract.
Runtime syntax and validation failures exit `2`, capability and resolver failures exit
`1`, and success exits `0`.

The cost estimate includes one list request plus every possible selected per-item detail
request for `threads` and `drafts`, using each validated materialized `first` value and
the document-wide hydration plan applied by the resolver context. It therefore charges
every repeated alias for the aggregate detail selection before dispatch rather than
allowing concurrent root resolution to multiply Gmail work. A cost-limit rejection
returns `RESOURCE_LIMIT` with exit `2`, a generated request ID, and no provider request.
The kit remains authoritative for syntax and validation envelopes after this conservative
Gmail-specific guard.

`GmailGatewaySDK(mode:)` conforms to `GatewaySDK`, publishes provider
`gmail-gateway`, the stable mode tier, and the authorized catalog, and delegates
`execute(document:variables:environment:)` directly to the shared executor. Its overridden
`invoke` builds every GraphQL operation from `gmailFull`, then delegates to that same
executor so known denied operations return `CAPABILITY_DENIED`; builder failures use the
same coded, request-ID-bearing canonical envelope as CLI operation failures. It supports
`.default`, field-path, and raw selections without a CLI round trip.
SDK execution is fail-closed: `GMAIL_GATEWAY_CONFIG` must be present in the supplied
environment, must be absolute, and must not use `~`; no config, credential, data, or
cache default is read from the process home directory. Under this strict SDK policy,
nested storage and credential paths may remain relative to the containing config file,
but neither those values nor their per-credential environment overrides may use home
expansion. Validation covers `cache_dir`, `attachment_dir`, every
`allowed_send_attachment_roots` entry, `oauth_client_secret_path`, and
`token_store_path`, and fails before authentication or provider access. The CLI
explicitly selects its legacy default-path policy at its own boundary, retaining
command-line compatibility without granting the SDK ambient credential discovery.

The synchronous `GmailGatewayCLI.run(arguments:environment:)` API remains stable. Its
async bridge must run the executor task on an independent execution context before
waiting; it must not block an actor or serial executor that the task needs to complete.
`GmailGatewaySDK.execute` is cancellation-aware, and cancellation policy is classified
from operation intent rather than HTTP method. OAuth refresh is a cancellable control-plane
prerequisite even though it uses `POST`; cancelling it returns `CANCELLED` and prevents
the later Gmail request. Cancelling a safe read, retry wait, or mutation prerequisite
read cancels its live `URLSessionDataTask`, returns `CANCELLED`, prevents retries, and
prevents every later provider attempt, including the irreversible mutation request. Once
the Gmail mutation request itself is dispatched, cancellation must not replace a
definitive provider result: a received success preserves the operation payload, and a
received provider failure preserves that failure. If no definitive Gmail response is
available after mutation dispatch, whether or not the caller cancelled, the runtime returns
the non-retryable `MUTATION_OUTCOME_UNKNOWN` GraphQL error rather than a retryable transport
failure or a claimed cancellation. The synchronous HTTP bridge applies an absolute
30-second response deadline in addition to URLSession's inactivity timeout, cancels the
transport on expiry, and classifies the dispatched mutation as `MUTATION_OUTCOME_UNKNOWN`.
Callers must not automatically retry that outcome.
Before calling the executor, the CLI creates an effective copy of its supplied
environment and, when `--config` is present, sets `GMAIL_GATEWAY_CONFIG` in that copy to
the flag value. This preserves the existing `--config`-over-environment precedence
without adding a second executor configuration channel. `GmailGatewaySDK` does not read
process-global state and observes only the environment passed to `execute` or `invoke`.

The `graphql` command surface is the same in every binary and is catalog-driven:

- `graphql --query|--query-file` remains raw GraphQL passthrough;
- `graphql query --query|--query-file` is the explicit equivalent;
- both query forms accept `--variables|--variables-file` and `--pretty`;
- `graphql schema` prints the authorized catalog as SDL without loading credentials or
  contacting Gmail;
- `graphql search <regex> [--kinds ...] [--include-referenced-types] [--limit N]`
  searches only the authorized catalog using `GatewaySchemaSearch` and its bounded regex
  policy, without loading credentials or contacting Gmail; and
- `graphql operation <name> [--variables|--variables-file] [--select a.b,c]` builds a
  document from `gmailFull`; the shared executor then authorizes it against the mode
  catalog, so a known disallowed operation returns `CAPABILITY_DENIED` rather than
  `UNKNOWN_OPERATION`.

Each form has exact positional cardinality and a per-subcommand flag allowlist. Unknown
or inapplicable flags, duplicate singleton flags, and trailing positional arguments fail
with CLI usage error before variable-file loading, document construction, resolver
dispatch, or provider access. This applies equally to destructive operations.
Malformed regexes and patterns rejected by the shared bounded-regex policy map to a
single `INVALID_PATTERN` request error with exit `2`; they never become
`UNEXPECTED_ERROR`, load configuration, or contact Gmail.

All mutations accept exactly one non-null `input` object. `threads` accepts only
`input: ThreadSearchInput!`; the previously tolerated flat
`threads(accountId:first:...)` form is intentionally removed. Unknown, missing, or
mistyped arguments and variables fail validation rather than being recovered through
literal scanning.

### Canonical Root Types

Phase 1 reader schema:

```graphql
type Query {
  accounts: [MailAccount!]!
  account(id: ID!): MailAccount
  threads(input: ThreadSearchInput!): ThreadConnection!
  thread(accountId: ID!, threadId: ID!): MailThread
  message(accountId: ID!, messageId: ID!): MailMessage
  messageFileSet(accountId: ID!, messageId: ID!): MailMessageFileSet!
  attachment(accountId: ID!, messageId: ID!, attachmentId: ID!): MailAttachment
  labels(accountId: ID!): [MailLabel!]!
  profile(accountId: ID!): MailProfile!
}

type MailLabel {
  id: ID!
  accountId: ID!
  name: String
  type: String                  # system or user
  messageListVisibility: String
  labelListVisibility: String
}

type MailProfile {
  accountId: ID!
  emailAddress: String
  messagesTotal: Int
  threadsTotal: Int
  historyId: String
}
```

`labels` is what makes the `ThreadSearchInput.labelIds` filter usable: it is the only
way to discover the provider label ids that filter accepts. `profile` reports the
authenticated mailbox identity and totals. Both are reads, so they need only the
`read` access mode and are available in every binary.

Phase 2 adds:

```graphql
type Mutation {
  createDraft(input: SendMessageInput!): SendMessagePayload!
  createReplyDraft(input: ReplyMessageInput!): SendMessagePayload!
  createForwardDraft(input: ForwardMessageInput!): SendMessagePayload!
  updateDraft(input: UpdateDraftInput!): SendMessagePayload!
  deleteDraft(input: DeleteDraftInput!): SendMessagePayload!
  sendMessage(input: SendMessageInput!): SendMessagePayload!
  replyMessage(input: ReplyMessageInput!): SendMessagePayload!
  forwardMessage(input: ForwardMessageInput!): SendMessagePayload!
  sendDraft(input: SendDraftInput!): SendMessagePayload!
}

input SendMessageInput {
  accountId: ID!
  to: [String!]
  cc: [String!]
  bcc: [String!]
  replyTo: String
  subject: String
  textBody: String
  htmlBody: String
  attachmentPaths: [String!]
}

input SendDraftInput {
  accountId: ID!
  draftId: ID!
}

input UpdateDraftInput {
  accountId: ID!
  draftId: ID!
  to: [String!]            # omitted fields keep the value already on the draft
  cc: [String!]
  bcc: [String!]
  replyTo: String
  subject: String
  textBody: String         # supplying textBody and/or htmlBody replaces the whole body
  htmlBody: String
  attachmentPaths: [String!]   # local files added on top of retained attachments
  keepAttachmentIds: [String!] # omitted keeps all; [] drops all; listed ids are retained
}

input DeleteDraftInput {
  accountId: ID!
  draftId: ID!
}

input ReplyMessageInput {
  accountId: ID!
  messageId: ID!
  to: [String!]          # defaults to the original Reply-To (or From) when omitted
  cc: [String!]          # with replyAll and no explicit cc, defaults to original to+cc minus self
  bcc: [String!]
  replyAll: Boolean = false
  textBody: String
  htmlBody: String
  attachmentPaths: [String!]
}

input ForwardMessageInput {
  accountId: ID!
  messageId: ID!
  to: [String!]!
  cc: [String!]
  bcc: [String!]
  textBody: String       # optional note placed above the forwarded quote
  htmlBody: String
  includeAttachments: Boolean = true
  attachmentPaths: [String!]
}

type SendMessagePayload {
  operation: String!
  accountId: ID!
  provider: MailProvider!
  draftId: ID
  messageId: ID
  threadId: ID
  status: String!
  rejectedAttachments: [RejectedAttachment!]!
}

type RejectedAttachment {
  path: String!
  code: String!
  reason: String!
}
```

`replyMessage` and `forwardMessage` are sender-only mutations that send directly.
The draft binary has no send path at all and rejects them before any provider call;
it prepares the same threaded messages as drafts through `createReplyDraft` and
`createForwardDraft`, which build identical content but always stop at draft creation.
Replies set
`In-Reply-To`, `References`, the provider `threadId`, and a `Re:` subject
derived from the original message. Forwards quote the original body under a
`---------- Forwarded message ----------` header block, use a `Fwd:` subject,
carry the original attachments when `includeAttachments` is true, and stay on
the original provider thread via `threadId` and `References`.

Draft reads are part of the same surface and are available in
`gmail-gateway-draft` and `gmail-gateway-sender` only:

```graphql
type DraftQuery {
  drafts(accountId: ID!, first: Int = 20, after: String): MailDraftConnection!
  draft(accountId: ID!, draftId: ID!): MailDraft
}

type MailDraft {
  id: ID!
  accountId: ID!
  message: MailMessage
}

type MailDraftEdge {
  cursor: String!
  node: MailDraft!
}

type MailDraftConnection {
  edges: [MailDraftEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}
```

`draft` is what supplies the provider attachment ids that `updateDraft`
`keepAttachmentIds` refers to. `gmail-gateway-reader` denies both draft queries with
`CAPABILITY_DENIED` because the reader's authorized catalog has no draft surface.

### Search Input Model

```graphql
input ThreadSearchInput {
  accountId: ID!
  query: String
  starred: Boolean
  labelIds: [String!]
  direction: MailDirectionFilter
  receivedAfter: DateTime
  receivedBefore: DateTime
  first: Int = 20
  after: String
}

enum MailDirectionFilter {
  SENT
  RECEIVED
  ALL
}
```

`direction` is evaluated relative to the configured account selected by `accountId`:

- `SENT`: messages where the selected account is the effective sender
- `RECEIVED`: messages where the selected account is a recipient and not the effective sender
- `ALL`: no sent/received direction filter

`query` remains the raw provider search escape hatch and is combined with
structured filters using AND semantics. For Gmail-backed accounts,
`direction: SENT` maps to `in:sent`, `direction: RECEIVED` maps to `-in:sent`,
`receivedAfter` maps to `after:YYYY/MM/DD`, `receivedBefore` maps to
`before:YYYY/MM/DD`, and `starred: true` adds `is:starred`. Explicit
`labelIds` are sent as Gmail `labelIds` API parameters. When `labelIds` is not
provided, configured default label filters are preserved except that
`direction: SENT` does not apply the default inbox label filter.

The current implementation rejects unsupported thread-search fields rather
than silently ignoring them. Future schema additions may include
`unread: Boolean`, `from: [String!]`, and `hasAttachments: Boolean`; until
implemented, those fields fail with `INVALID_ARGUMENT`.

### Core Domain Types

```graphql
scalar DateTime

enum MailProvider {
  GMAIL
}

type MailAddress {
  address: String!
  raw: String!
}

type MailAccount {
  id: ID!
  provider: MailProvider!
  emailAddress: String!
  isFallback: Boolean!
  capabilities: MailCapabilities!
}

type MailCapabilities {
  canRead: Boolean!
  canSend: Boolean!
  configuredAccessMode: AccessMode!
  authState: AuthState!
  isFallback: Boolean!
}

type MailThread {
  id: ID!
  accountId: ID!
  subject: String
  snippet: String
  messages: [MailMessage!]!
  labels: [String!]!
  providerMetadata: ProviderMetadata
}

type MailMessage {
  id: ID!
  threadId: ID!
  accountId: ID!
  subject: String
  from: [MailAddress!]!
  to: [MailAddress!]!
  cc: [MailAddress!]!
  bcc: [MailAddress!]!
  replyTo: [MailAddress!]!
  sentAt: DateTime
  receivedAt: DateTime
  snippet: String
  textBody: String
  htmlBody: String
  attachments: [MailAttachment!]!
  labels: [String!]!
  historyId: String
  providerMetadata: ProviderMetadata
}

type MailAttachment {
  id: ID!
  accountId: ID
  messageId: ID
  filename: String
  mimeType: String!
  sizeBytes: Int
  downloadKey: String
  materializationState: AttachmentMaterializationState!
  providerMetadata: ProviderMetadata
}

type MailMessageFileSet {
  accountId: ID!
  messageId: ID!
  hasFiles: Boolean!
  files: [MailMessageFile!]!
}

type MailMessageFile {
  kind: MessageMaterializedFileKind!
  filename: String!
  hasPayload: Boolean!
  mimeType: String
  sizeBytes: Int
  downloadKey: String!
  materializationState: AttachmentMaterializationState!
}

enum MessageMaterializedFileKind {
  ATTACHMENT
  BODY_TEXT
  BODY_HTML
  TEMPORARY_FILE
}

type MailThreadEdge {
  cursor: String!
  node: MailThread!
}

type PageInfo {
  hasNextPage: Boolean!
  endCursor: String
}

type ThreadConnection {
  edges: [MailThreadEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

type ProviderMetadata {
  gmail: GmailProviderMetadata
}

type GmailProviderMetadata {
  accountId: ID
  messageId: ID
  threadId: ID
  attachmentId: ID
  partId: ID
  labelIds: [String!]
  historyId: String
}

enum AttachmentMaterializationState {
  NOT_MATERIALIZED
  CACHED
  MATERIALIZED
}

enum AccessMode {
  READ
  READ_SEND
  READ_MODIFY
  FULL
}

enum AuthState {
  MISSING
  READY
  EXPIRED
  SCOPE_MISMATCH
  INVALID
  UNKNOWN
}
```

`DateTime` is an ISO 8601/RFC 3339 timestamp string when the provider supplies
timestamp precision. If only an RFC 5322 mail header date is available, the
gateway normalizes it to the same timestamp format before returning it.

`MailAddress.raw` preserves the provider/header address string. The runtime-facing
resolver normalization also publishes that same value as `address`, satisfying the
canonical SDK projection `messages { from { address } }` without modifying provider or
service models. Both fields are therefore stable aliases in phase 1d; parsed display-name
and mailbox components remain future additive fields.

Resolver normalization is deliberately narrow and occurs before conversion to
`GatewayJSONValue`: recursively add `address` beside each service-produced
`MailAddress.raw`, and remove `localPath` from every `MailAttachment`. All other keys and
null values pass through unchanged. This is the only intentional difference from the
service dictionaries, and it preserves the existing rule that GraphQL never exposes
local filesystem paths. The executor derives an aggregate hydration plan from the parsed
GatewaySDKKit selection AST before resolver dispatch: summary-only `threads` and `drafts`
selections make only the list request, `edges` and summary thread-node selections avoid
detail reads, and selected thread message/subject/label fields or
`providerMetadata.gmail.labelIds` (plus draft nodes) trigger the needed detail hydration.
When a detail read is required, list-derived thread `snippet` and provider `historyId` values
remain authoritative so selecting a detail sibling does not change already selected summary
fields. The runtime then removes fields the caller did not select. `textBody` and
`htmlBody` remain present only as nullable compatibility fields whose resolver values are
always `null`; message content remains available solely through file download keys.

`MailProvider`, `AccessMode`, and `AuthState` are GraphQL enums. Configuration
uses lower-case provider/access values such as `gmail`, `read`, `read_send`,
`read_modify`, and `full`;
GraphQL responses use the upper-case enum values shown above.

### Query Semantics

- `threads` requires `accountId` within `ThreadSearchInput`
- pagination uses cursor-based connections
- ordering is descending by most recent provider thread activity, with provider thread ID as a stable tie-breaker
- cursors are valid only for the same account and identical filter set
- the current search model supports label filters, free text, starred state,
  sent-vs-received direction filters, and time range
- unsupported search fields are rejected with a GraphQL error rather than
  being ignored
- `MailMessage` returns message metadata and attachment metadata only.
  `messageFileSet.files` and `MailAttachment.downloadKey` describe
  downloadable content but do not expose body text, HTML, bytes, or local
  filesystem paths.

### Outbound Mutation Semantics

Phase 1 does not expose mutations. Phase 2 splits the outbound surface strictly by binary:

- `gmail-gateway-draft` owns the draft lifecycle (`createDraft`, `createReplyDraft`,
  `createForwardDraft`, `updateDraft`, `deleteDraft`) and has no send path; `sendMessage`,
  `replyMessage`, `forwardMessage`, and `sendDraft` are denied with
  `CAPABILITY_DENIED` before any provider call
- `gmail-gateway-sender` treats `sendMessage` as direct provider send, sends replies and
  forwards directly, sends prepared drafts through `sendDraft`, and also supports the full
  draft lifecycle
- `gmail-gateway-reader` denies write mutations with `CAPABILITY_DENIED`

`updateDraft` maps to the provider draft-replacement call (Gmail `drafts.update`), so the
gateway rebuilds the whole draft from the merged state rather than patching it in place:

- header and body fields left out of the input are read back from the existing draft
- supplying `textBody` and/or `htmlBody` replaces the entire body with exactly what was
  supplied, so an update cannot leave a stale alternative part behind
- attachments already on the draft are all retained unless `keepAttachmentIds` is given;
  when given, only the listed provider attachment ids survive, and an empty list drops all
- `attachmentPaths` adds validated local files on top of what is retained, so
  `keepAttachmentIds: []` combined with `attachmentPaths` is a full attachment replacement
- `keepAttachmentIds` entries that are not on the draft fail with `ATTACHMENT_NOT_FOUND`
  before the provider write
- the draft stays on its original provider thread, and its `In-Reply-To` and `References`
  headers are carried over
- the merged result is validated with the same outbound rules as `createDraft`, so an updated
  draft must still have at least one recipient and a body

`deleteDraft` maps to the provider draft delete and returns the deleted `draftId` with
status `DRAFT_DELETED`.

`sendDraft` maps to the provider draft-send call (Gmail `drafts.send`) and closes the
draft-then-send workflow: `gmail-gateway-draft` prepares and revises the draft, and
`gmail-gateway-sender` transmits it by id. It reports operation `SEND_DRAFT` with both the
`draftId` it sent and the resulting `messageId` and `threadId`.

The shared input fields are:

- required `accountId`
- header fields (`to`, `cc`, `bcc`, `subject`, `replyTo`)
- body variants (`textBody`, `htmlBody`)
- attachments by validated local file path

`SendMessageInput.to`, `cc`, and `bcc` are individually optional because the service
accepts any recipient combination, but their combined values must contain at least one
recipient. The existing service performs that semantic validation after GraphQL type
coercion and before any provider request.

Reply and forward workflows are provided by the dedicated `replyMessage` and
`forwardMessage` mutations described above rather than by `SendMessageInput`.

`createDraft` and `updateDraft` return:

- canonical draft metadata
- provider-assigned draft ID and message ID when available
- rejected attachment paths with reasons if partial validation fails before draft creation

`gmail-gateway-sender` `sendMessage` returns:

- canonical sent message metadata
- provider-assigned message ID and thread ID
- rejected attachment paths with reasons if partial validation fails before send

### Mailbox Mutation Semantics

`gmail-gateway-threads` owns every operation that changes stored mail. It never composes,
sends, or ingests, and the other modes deny its mutations with `CAPABILITY_DENIED`.

The `MailboxMutation` name below groups this mode's fields for readability; the catalog
merges them into the single GraphQL `Mutation` root.

```graphql
type MailboxMutation {
  modifyThreadLabels(input: ModifyThreadLabelsInput!): MailboxMutationPayload!
  modifyMessageLabels(input: ModifyMessageLabelsInput!): MailboxMutationPayload!
  batchModifyMessageLabels(input: BatchModifyMessageLabelsInput!): MailboxMutationPayload!
  trashThread(input: ThreadMailboxActionInput!): MailboxMutationPayload!
  untrashThread(input: ThreadMailboxActionInput!): MailboxMutationPayload!
  trashMessage(input: MessageMailboxActionInput!): MailboxMutationPayload!
  untrashMessage(input: MessageMailboxActionInput!): MailboxMutationPayload!
  deleteThread(input: ThreadMailboxActionInput!): MailboxMutationPayload!
  deleteMessage(input: MessageMailboxActionInput!): MailboxMutationPayload!
  batchDeleteMessages(input: BatchDeleteMessagesInput!): MailboxMutationPayload!
  createLabel(input: CreateLabelInput!): MailboxMutationPayload!
  updateLabel(input: UpdateLabelInput!): MailboxMutationPayload!
  deleteLabel(input: DeleteLabelInput!): MailboxMutationPayload!
}

input ModifyThreadLabelsInput {
  accountId: ID!
  threadId: ID!
  addLabelIds: [String!]
  removeLabelIds: [String!]
}

input ModifyMessageLabelsInput {
  accountId: ID!
  messageId: ID!
  addLabelIds: [String!]
  removeLabelIds: [String!]
}

input BatchModifyMessageLabelsInput {
  accountId: ID!
  messageIds: [ID!]!
  addLabelIds: [String!]
  removeLabelIds: [String!]
}

input ThreadMailboxActionInput {
  accountId: ID!
  threadId: ID!
}

input MessageMailboxActionInput {
  accountId: ID!
  messageId: ID!
}

input BatchDeleteMessagesInput {
  accountId: ID!
  messageIds: [ID!]!
}

input CreateLabelInput {
  accountId: ID!
  name: String!
  messageListVisibility: MessageListVisibility
  labelListVisibility: LabelListVisibility
}

input UpdateLabelInput {
  accountId: ID!
  labelId: ID!
  name: String
  messageListVisibility: MessageListVisibility
  labelListVisibility: LabelListVisibility
}

input DeleteLabelInput {
  accountId: ID!
  labelId: ID!
}

enum MessageListVisibility {
  show
  hide
}

enum LabelListVisibility {
  labelShow
  labelShowIfUnread
  labelHide
}

type MailboxMutationPayload {
  operation: String!
  accountId: ID!
  provider: MailProvider!
  status: String!
  threadId: ID
  messageId: ID
  messageIds: [ID!]
  labelId: ID
  label: MailLabel
  labelIds: [String!]
}
```

- a label change must name at least one `addLabelIds` or `removeLabelIds` value; an empty
  change is rejected before the provider call rather than sent as a no-op
- `modifyThreadLabels` reports the union of the resulting labels across the thread's
  messages, because the provider returns the modified thread rather than a thread-level
  label list
- `updateLabel` patches rather than replaces, so an update that names only `name` leaves
  the visibility settings untouched
- `deleteThread`, `deleteMessage`, and `batchDeleteMessages` are irreversible and bypass
  Trash. They require the `full` access mode, because the provider accepts only its
  full-access scope for them. `trashThread` and `trashMessage` are the reversible path and
  need only `read_modify`.

### Mail Ingestion Semantics

`gmail-gateway-message-box` adds existing RFC 822 mail to the mailbox without sending it.
The other modes deny its mutations with `CAPABILITY_DENIED`.

The `IngestMutation` name below is likewise a readable group whose fields are emitted on
the single GraphQL `Mutation` root.

```graphql
type IngestMutation {
  importMessage(input: MailboxIngestInput!): MailboxMutationPayload!
  insertMessage(input: MailboxIngestInput!): MailboxMutationPayload!
}

input MailboxIngestInput {
  accountId: ID!
  rfc822Path: String!            # must resolve under storage.allowed_send_attachment_roots
  labelIds: [String!]
  internalDateSource: InternalDateSource
  neverMarkSpam: Boolean         # importMessage only
  processForCalendar: Boolean    # importMessage only
  deleted: Boolean
}

enum InternalDateSource {
  RECEIVED_TIME
  DATE_HEADER
}
```

- `importMessage` runs the normal delivery pipeline, so it accepts `neverMarkSpam` and
  `processForCalendar`; `insertMessage` is a direct IMAP-APPEND-style add that bypasses
  most scanning, and those two flags are not sent for it
- the source is named by local path, never inlined, and is validated against the same
  allowed roots that outbound attachments use, so ingestion cannot read arbitrary files

### Deliberately Unmapped Provider Surface

The following remain unmapped, because they do not fit any binary's charter and would
require a new capability decision rather than an addition to an existing binary:

- mailbox administration: every `users.settings.*` resource (vacation, IMAP, POP,
  language, filters, delegates, forwarding addresses, send-as identities, S/MIME, CSE).
- `history.list`, which belongs with the Phase 3 incremental-sync cache.
- `users.watch` and `users.stop`, which require the long-running `serve` mode that Phase 1
  explicitly excludes.

## Attachment Handling

### Materialization Rules

- nested attachment, body, and temporary-file metadata returned from `threads`,
  `thread`, and `message` must not include payload bytes
- GraphQL returns `downloadKey` values that abstract provider-specific Gmail
  message part ids, attachment ids, and temporary cache handles
- only explicit gateway download commands may fetch payload bytes and
  materialize them to disk; batch downloads scope copied files by
  `<account_id>/<message_id>/` under the requested output directory to avoid
  filename collisions
- non-inline attachments are written under `storage.attachment_dir`
- the path format is deterministic and collision-safe:
  `<attachment_dir>/<account_id>/<message_id>/<attachment_id>-<sanitized_filename>`,
  with a hashed, length-bounded attachment-id prefix when provider ids exceed
  filesystem filename limits
- if the file already exists and its metadata matches, the cached path is reused
- materialization is idempotent from the API caller perspective
- materialized files persist until explicit cleanup through `cache prune`
- attachments are always exchanged as files and normalized local paths
- this avoids embedding large binary or base64 payloads in GraphQL responses, which keeps AI token consumption bounded
- LLM-oriented callers should inspect GraphQL metadata first and download only
  the files they truly need, avoiding token-heavy body expansion in normal
  prompt input

### Reader-Binary Interpretation

Attachment materialization writes to the local cache even from `gmail-gateway-reader`. This is considered an allowed local caching side effect, not a remote mailbox mutation.

## Provider Architecture

### Layering

1. CLI/GraphQL transport layer
2. Application service layer for config loading, account resolution, authorization, and result shaping
3. Provider adapter interface
4. Local storage layer for tokens, attachment cache, and optional metadata cache

### Provider Adapter Contract

Each provider implements:

- `listAccountsCapabilities`
- `searchThreads`
- `getThread`
- `getMessage`
- `getAttachmentContent`
- draft creation when the provider supports drafts
- direct send when the provider supports send and the `gmail-gateway-sender` executable is used
- `validateCredentialConfig`
- `interactiveAuthorize`

The GraphQL layer depends only on the canonical provider interface. Gmail-specific fields are converted into the canonical model plus a small `providerMetadata` object for details like Gmail label IDs or history IDs.

### Gmail v1 Adapter

The Gmail adapter uses:

- Gmail API for threads, messages, attachments, draft creation, and send
- OAuth 2.0 installed-app flow with PKCE where available
- per-credential token stores on local disk

Canonical mapping rules:

- Gmail thread ID maps to `MailThread.id`
- Gmail message ID maps to `MailMessage.id`
- Gmail labels map to canonical `labels`
- Gmail message part tree is normalized into message-file metadata and
  attachments; body payloads are retrieved through `messageFileSet` download
  keys and explicit `file download` commands

## Authentication and Authorization

### CLI Setup Commands

Authentication is handled outside the GraphQL business schema:

- `gmail-gateway-reader auth status --credential gmail-work-oauth`
- `gmail-gateway-reader auth login --credential gmail-work-oauth`
- `gmail-gateway-reader auth revoke --credential gmail-work-oauth`
- `gmail-gateway-reader cache prune --account work`
- `gmail-gateway-reader config validate`

These commands exist because they are environment bootstrapping tasks, not mail-domain operations.

### Storage Rules

- token files are stored with `0600` permissions where the platform allows it
- client secret files are referenced by path and never copied into cache directories
- GraphQL responses never include access tokens, refresh tokens, or client secret content
- logs must redact credential paths only if they would reveal sensitive directory structure configured by policy
- `auth login` must request scopes that exactly match the configured credential `access_mode`
- `auth status` must report token presence, validity hints, granted access mode when known, and access-mode mismatch

## Errors and Observability

### Access Modes

| Access mode | Scopes | Capabilities |
|-------------|--------|--------------|
| `read` | `gmail.readonly` | read |
| `read_send` | `gmail.readonly`, `gmail.compose`, `gmail.send` | read, send |
| `read_modify` | `gmail.readonly`, `gmail.modify`, `gmail.insert` | read, modify, insert |
| `full` | `https://mail.google.com/` | read, send, modify, insert, permanent delete |

The capability model is deliberately not a ladder: `read_send` does not grant modify and
`read_modify` does not grant send, so neither can stand in for the other. Only `full` grants
permanent delete, and only because the provider accepts no narrower scope for it.

### Error Model

GraphQL errors should be structured with machine-readable extension codes:

- `CAPABILITY_DENIED`
- `CANCELLED`
- `MUTATION_OUTCOME_UNKNOWN`
- `ACCOUNT_NOT_FOUND`
- `ATTACHMENT_NOT_FOUND`
- `CREDENTIAL_NOT_FOUND`
- `AUTH_REQUIRED`
- `FILE_OPERATION_FAILED`
- `INVALID_DOWNLOAD_KEY`
- `PROVIDER_RATE_LIMITED`
- `MESSAGE_NOT_FOUND`
- `AUTH_BOOTSTRAP_NOT_IMPLEMENTED`
- `SEND_NOT_SUPPORTED`
- `DRAFT_NOT_FOUND`
- `LABEL_NOT_FOUND`
- `MAILBOX_MUTATION_NOT_SUPPORTED`
- `MAIL_INGEST_NOT_SUPPORTED`
- `ACCESS_MODE_INSUFFICIENT`
- `CONFIG_INVALID`
- `UNEXPECTED_ERROR`

`SEND_DISABLED_IN_READER` and `SEND_DISABLED_IN_DRAFT_GATEWAY` remain defined for
service-level compatibility, but a root absent from an authorized phase 1d catalog returns
`CAPABILITY_DENIED` before resolver dispatch and must not report either retained code.

### Logging

- default structured CLI errors go to stderr
- GraphQL responses go to stdout in CLI mode
- error objects include a generated `requestId` for caller-side correlation
- provider API request IDs should be captured when providers expose them

## Security Constraints

- a credential's `access_mode` decides which capabilities it holds and the binary decides
  which it exposes; both must allow an operation. `read_send` cannot mutate stored mail and
  `read_modify` cannot send, so a credential scoped for one workflow cannot be borrowed for
  the other
- permanent delete is reachable only with the `full` access mode through
  `gmail-gateway-threads`, and only through the three explicitly named delete mutations
- the reader binary must not expose write resolvers
- direct send resolvers (`sendMessage`, `replyMessage`, `forwardMessage`) must be reachable
  only through `gmail-gateway-sender`; `gmail-gateway-draft` denies them before any provider
  call so the draft binary has no code path that can transmit mail
- `gmail-gateway-sender` may also expose draft resolvers, but draft resolvers must not send mail
- file paths returned by gateway download commands must always be normalized
  under configured storage roots or an allowed output directory
- attachment filenames must be sanitized to prevent path traversal or control-character issues
- sending attachments must read only explicit local paths supplied by the caller and only from configured allowlist roots
- provider-specific raw MIME submission must be deferred unless validation rules are defined

## Extensibility

The design must support new providers without changing the GraphQL contract for common operations.

Provider-specific expansion points:

- `MailProvider` enum extension
- provider credential validation rules
- provider metadata objects
- optional provider capability flags

Adding a new provider should usually require:

1. a new adapter implementation
2. config validation rules for that provider
3. provider-specific auth bootstrap
4. schema additions only when the canonical model is insufficient

## Phase 1d Dependency, Validation, and Rollout

`Package.swift` consumes product `GatewaySDKKit` through
`.package(path: "../../gateway-sdk-kit")`; an adjacent comment records that the operator
will replace the local path with a URL revision pin later. The package is immutable from
this work item: phase 1d must neither edit it nor copy its parser/runtime into
gmail-gateway.

The consumed sibling path and the supplied reference worktree are separate roles. The
reference at `/Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime` documents the
required committed API. Before implementation or verification, the consumed sibling must
resolve to a commit containing `GatewayGraphQLRuntime` and the catalog, SDK, search,
envelope, resolver, and JSON-value APIs. As verified on 2026-09-05, both the consumed
sibling and reference worktree resolve to commit
`4d4b56c686f6875defccb54f74e2276022eb524e`. If that precondition later fails,
implementation stops with the mismatch recorded; it must not alter GatewaySDKKit, bind an
older API, change the authorized dependency path, or restore a private parser.

Rollout is a single phase 1d feature on `feat/gateway-sdk`. It includes catalog,
resolvers, executor, SDK, CLI, tests, smoke coverage, and documentation together; no
compatibility interval keeps the scanner alive. Tests must prove:

- `gmailFull` and every mode catalog validate cleanly and operation-set parity holds in
  both directions against an expected five-mode authorization oracle declared in test
  data, not derived from the production catalog, resolver registry, mode root arrays, or
  another production authorization helper;
- the cross-product of every full-catalog root field and all five modes matches that
  independent oracle: every authorized literal and variable form reaches only its exact
  ordered provider effect sequence, and every denied form returns `CAPABILITY_DENIED`
  naming the mode without resolver or network dispatch; credential-mode tests separately
  prove the service-owned `AccessMode` boundary rather than reusing catalog authorization
  as their expected result;
- successful draft, sender, mailbox, and ingest cases compare the complete decoded
  GraphQL envelope by canonical equality, including the `data`, `errors`, and extension
  key shape; generated request IDs are validated separately. The selected root payload
  also uses exact key-set equality so unexpected fields fail the test. Every request in
  the exact provider sequence compares its complete body by canonical equality, treating
  a bodyless request as exactly absent.
  Draft and sender assertions decode every `raw` value and compare the complete
  operation-specific RFC 822/MIME message, including recipients, subject, bodies,
  threading headers, attachments, and provider wrapper keys, rather than testing
  substrings or a subset of JSON keys;
- variables cover strings, integers, lists, nested input objects, file loading, mutual
  exclusion, missing values, type errors, unused/undeclared/unknown variables, and
  non-object JSON;
- projection covers aliases, nested lists and objects, missing keys becoming `null`, and
  exact rejection of undeclared response fields;
- provider-mapping coverage proves that `labels` filters entries without a non-blank
  provider ID while preserving `accountId`, `name`, `type`, `messageListVisibility`, and
  `labelListVisibility`, and that `profile` preserves `emailAddress`, `messagesTotal`,
  `threadsTotal`, and `historyId`;
- SDK default selection executes for `threads`, `labels`, and `createDraft`, and strict
  SDK configuration tests reject a missing, relative, or home-expanded
  `GMAIL_GATEWAY_CONFIG` plus home-expanded nested storage/credential paths without
  provider access; a conflicting CLI `--config` and environment value proves flag
  precedence;
- raw passthrough, explicit `query`, schema, search, and operation CLI forms work in all
  five modes with independent provider-effect assertions. Every validator class asserts
  its exact stable code and exit class; malformed regexes assert `INVALID_PATTERN`, and
  every form rejects extra positionals, unknown or inapplicable flags, and duplicate
  singleton flags before effects;
- cancellation tests distinguish OAuth refresh, safe reads and retries, mutation
  prerequisite reads, definitive post-dispatch mutation responses, and cancelled and
  uncancelled lost or deadline-expired post-dispatch mutation responses. They prove
  cancellation before the irreversible request prevents it, definitive mutation results are
  not masked, and only an indeterminate dispatched mutation returns
  `MUTATION_OUTCOME_UNKNOWN`; and
- URLProtocol request assertions, smoke tests, full build/test, SwiftLint, file-size, and
  diff checks pass before the authorized local commit.

`TASK-006` must remain `In Progress` whenever any every-mode, per-CLI-form effect,
validator-code, independent-authorization-oracle, exact-envelope, exact-provider-body,
mapping, configuration, or cancellation evidence above is absent or stale. It may be
marked `Completed` only after all such evidence is present and the current focused and
full gates pass. A broad test command or partial status/body assertion is not sufficient.

The smoke suite has already been split by responsibility: `main.swift` is 409 lines and
`GraphQLRuntimeSmokeTests.swift` is 632 lines. Every non-generated Swift file remains
below 1,000 lines. The final gates are:

```bash
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk && swift build && swift test && swift run gmail-gateway-swift-smoke-tests && swiftlint'
git diff --check
find Sources Tests -name '*.swift' -not -path '*/.build/*' -print0 | xargs -0 wc -l | awk '$1 > 1000 && $2 != "total" { print; failed=1 } END { exit failed }'
git status --porcelain=v1
```

The final status command must be empty after the authorized local commit.

The only review-required changes outside the original brief are the strict SDK-only
configuration-path policy and operation-aware cancellation at the shared HTTP boundary.
They do not change OAuth scopes, token persistence or refresh payloads, CLI default-path
behavior, Gmail request shapes, service semantics, MIME construction, persistent auth,
or packaging. No push is authorized.

## Phased Delivery

### Phase 1

- Gmail read support
- multi-account configuration
- multi-credential configuration
- credential `access_mode`
- attachment materialization
- `auth status`
- `cache prune`
- `gmail-gateway-reader graphql`

### Phase 2

- Gmail draft lifecycle support in `gmail-gateway-draft` (`createDraft`, `updateDraft`,
  `deleteDraft`, plus the `drafts` and `draft` queries)
- Gmail direct send support in `gmail-gateway-sender` only
- long-running `serve` mode if local client ergonomics require it

### Phase 3

- provider abstraction hardening for non-Gmail adapters
- optional metadata cache for incremental sync or faster repeated lookups

## References

Credential setup notes: [design-gmail-credentials.md](./design-gmail-credentials.md)

See `design-docs/references/README.md` for external references.
