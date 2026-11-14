# Mail Gateway Design

This document defines the product and technical design for an AI-oriented mail gateway that initially supports Gmail and can be extended to other mail providers later.

## Overview

Phase 1 ships one Swift Package Manager binary:

- `mail-gateway-reader`: read-only access to configured mail accounts

Phase 2 adds:

- `mail-gateway-draft`: read access plus default outbound draft creation
- `mail-gateway-sender`: explicit direct-send access to configured mail accounts, including draft creation

All business operations are exposed through GraphQL. The CLI surface exists only for bootstrapping, configuration validation, authentication setup, cache maintenance, and GraphQL transport.

## Goals

- Support multiple mail accounts in one configuration file
- Allow each account to reference a different Gmail credential set and token store
- Make account selection explicit for read operations
- Model all read operations through GraphQL in Phase 1
- Materialize attachments to local files and return their paths through an explicit hydration query
- Exchange attachments only as files and local paths so AI callers do not consume tokens on binary payloads
- Keep the provider layer extensible so Gmail is only the first adapter

## Non-Goals

- Implement IMAP/SMTP as a first milestone
- Build a generic web UI
- Support inline attachment payloads in GraphQL responses
- Synchronize an entire mailbox into a local database in v1
- Ship long-running `serve` mode in Phase 1
- Ship reply or forward workflows in the first write implementation

## Product Surface

### Binary Capabilities

| Binary | Read Mail | Send Mail | GraphQL Schema |
|--------|-----------|-----------|----------------|
| `mail-gateway-reader` | Yes | No | `Query` only, plus local-cache side effects such as attachment materialization |
| `mail-gateway-draft` | Planned for Phase 2 | Draft only by default | `Query` and draft-backed `Mutation` |
| `mail-gateway-sender` | Planned for Phase 2 | Yes, explicit direct send and draft creation | `Query`, direct-send `Mutation`, and draft `Mutation` |

`mail-gateway-reader` must fail fast if a send mutation is submitted. This is enforced by exposing a reduced schema rather than only checking at resolver runtime.

### GraphQL Transport Modes

The primary mode is a one-shot CLI invocation:

```bash
mail-gateway-reader graphql --query-file ./query.graphql --variables-file ./vars.json
```

An optional long-running mode may be added later:

```bash
mail-gateway-draft serve --listen 127.0.0.1:9407
```

For Phase 1, the one-shot `graphql` command is the required transport because it is simpler for local AI tool integration and avoids introducing daemon lifecycle management as a prerequisite.

## Configuration Design

Configuration is stored in TOML at:

- Default: `$XDG_CONFIG_HOME/mail-gateway/config.toml`
- Override: `--config <path>` or `MAIL_GATEWAY_CONFIG`

### Configuration Model

Credential profiles are defined independently from mail accounts. Mail accounts reference a credential profile by ID. This allows:

- multiple Gmail accounts using the same OAuth client configuration but different token stores
- multiple Gmail OAuth client configurations for different Google Cloud projects
- future providers to reuse the same account and credential graph without changing the higher-level API

Credential profiles also declare an explicit `access_mode`:

- `read`: read-only token scope
- `read_send`: read, draft creation, and send token scopes

This allows `auth login` and `auth status` to detect scope mismatches between configured intent and stored token metadata.

Credential path keys support a public-safe configuration mode:

- `oauth_client_secret_path` is optional when `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_OAUTH_CLIENT_SECRET_PATH` is set
- `token_store_path` is optional when `MAIL_GATEWAY_CREDENTIAL_<CREDENTIAL_ID>_TOKEN_STORE_PATH` is set
- if both TOML and env are present, the environment variable wins
- `<CREDENTIAL_ID>` is the credential ID uppercased with non-alphanumeric characters replaced by `_`

### Example Configuration

```toml
[storage]
cache_dir = "/home/taco/.local/share/mail-gateway"
attachment_dir = "/home/taco/.cache/mail-gateway/attachments"
allowed_send_attachment_roots = ["/home/taco/outbox-attachments"]

[[credentials]]
id = "gmail-personal-oauth"
provider = "gmail"
access_mode = "read"

[[credentials]]
id = "gmail-work-oauth"
provider = "gmail"
access_mode = "read_send"
oauth_client_secret_path = "/home/taco/.config/mail-gateway/google-work-client.json"
token_store_path = "/home/taco/.config/mail-gateway/tokens/work.json"

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
- `credentials.access_mode` must be `read` or `read_send`
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
- draft creation exists in `mail-gateway-draft`
- direct send operations exist only in `mail-gateway-sender`
- filesystem materialization paths are returned only by explicit gateway download
  commands, not by GraphQL message-file metadata
- nested thread and message queries return attachment metadata only; explicit hydration is performed only through `attachment(...)`
- attachment payloads are never inlined into GraphQL responses
- body and temporary-file payloads are never inlined into GraphQL responses;
  GraphQL returns vendor-neutral `downloadKey` metadata, and file bytes are
  retrieved only by an explicit gateway download command. Callers may repeat
  `--key` to download multiple selected files in one gateway invocation.

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
}
```

Phase 2 adds:

```graphql
type Mutation {
  createDraft(input: SendMessageInput!): SendMessagePayload!
  sendMessage(input: SendMessageInput!): SendMessagePayload!
}
```

### Search Input Model

```graphql
input ThreadSearchInput {
  accountId: ID!
  query: String
  starred: Boolean
  labelIds: [String!]
  unread: Boolean
  from: [String!]
  hasAttachments: Boolean
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

### Core Domain Types

```graphql
type MailAccount {
  id: ID!
  provider: MailProvider!
  emailAddress: String!
  capabilities: MailCapabilities!
}

type MailCapabilities {
  canRead: Boolean!
  canSend: Boolean!
  configuredAccessMode: AccessMode!
  authState: AuthState!
}

type MailThread {
  id: ID!
  accountId: ID!
  subject: String
  snippet: String
  messages: [MailMessage!]!
  labels: [String!]!
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
  textBody: String
  htmlBody: String
  attachments: [MailAttachment!]!
  providerMetadata: ProviderMetadata
}

type MailAttachment {
  id: ID!
  filename: String
  mimeType: String!
  sizeBytes: Int
  localPath: String
  downloadKey: String
  materializationState: AttachmentMaterializationState!
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
  labelIds: [String!]!
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

### Query Semantics

- `threads` requires `accountId` within `ThreadSearchInput`
- pagination uses cursor-based connections
- ordering is descending by most recent provider thread activity, with provider thread ID as a stable tie-breaker
- cursors are valid only for the same account and identical filter set
- the canonical search model supports label filters, free text, unread state, sender filters, attachment-presence filters, sent-vs-received direction filters, and time range
- `from` filters by sender address or addresses
- `hasAttachments: true` limits results to messages with at least one attachment; `false` limits results to messages without attachments

### Outbound Mutation Semantics

Phase 1 does not expose mutations. Phase 2 introduces `sendMessage` for new outbound messages only, with binary-specific behavior:

- `mail-gateway-draft` treats `sendMessage` as draft creation and never sends the message immediately
- `mail-gateway-sender` treats `sendMessage` as direct provider send and also supports `createDraft`
- `mail-gateway-reader` rejects write mutations with `SEND_DISABLED_IN_READER`

The shared input fields are:

- required `accountId`
- header fields (`to`, `cc`, `bcc`, `subject`, `replyTo`)
- body variants (`textBody`, `htmlBody`)
- attachments by validated local file path
- no reply or forward workflow in the first write implementation

`mail-gateway-draft` `sendMessage` and `mail-gateway-sender` `createDraft` return:

- canonical draft metadata
- provider-assigned draft ID and message ID when available
- rejected attachment paths with reasons if partial validation fails before draft creation

`mail-gateway-sender` `sendMessage` returns:

- canonical sent message metadata
- provider-assigned message ID and thread ID
- rejected attachment paths with reasons if partial validation fails before send

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

Attachment materialization writes to the local cache even from `mail-gateway-reader`. This is considered an allowed local caching side effect, not a remote mailbox mutation.

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
- direct send when the provider supports send and the `mail-gateway-sender` executable is used
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
- Gmail message part tree is normalized into `textBody`, `htmlBody`, and `attachments`

## Authentication and Authorization

### CLI Setup Commands

Authentication is handled outside the GraphQL business schema:

- `mail-gateway-reader auth status --credential gmail-work-oauth`
- `mail-gateway-reader auth login --credential gmail-work-oauth`
- `mail-gateway-reader auth revoke --credential gmail-work-oauth`
- `mail-gateway-reader cache prune --account work`
- `mail-gateway-reader config validate`

These commands exist because they are environment bootstrapping tasks, not mail-domain operations.

### Storage Rules

- token files are stored with `0600` permissions where the platform allows it
- client secret files are referenced by path and never copied into cache directories
- GraphQL responses never include access tokens, refresh tokens, or client secret content
- logs must redact credential paths only if they would reveal sensitive directory structure configured by policy
- `auth login` must request scopes that exactly match the configured credential `access_mode`
- `auth status` must report token presence, validity hints, granted access mode when known, and access-mode mismatch

## Errors and Observability

### Error Model

GraphQL errors should be structured with machine-readable extension codes:

- `ACCOUNT_NOT_FOUND`
- `ATTACHMENT_NOT_FOUND`
- `CREDENTIAL_NOT_FOUND`
- `AUTH_REQUIRED`
- `PROVIDER_RATE_LIMITED`
- `MESSAGE_NOT_FOUND`
- `AUTH_BOOTSTRAP_NOT_IMPLEMENTED`
- `SEND_NOT_SUPPORTED`
- `SEND_DISABLED_IN_READER`
- `CONFIG_INVALID`

### Logging

- default logs go to stderr
- GraphQL responses go to stdout in CLI mode
- each request receives a request ID for correlation
- provider API request IDs are logged when available

## Security Constraints

- the reader binary must not expose write resolvers
- direct send resolvers must be reachable only through `mail-gateway-sender`
- `mail-gateway-sender` may also expose draft resolvers, but draft resolvers must not send mail
- file paths returned in GraphQL must always be normalized under configured storage roots
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

## Phased Delivery

### Phase 1

- Gmail read support
- multi-account configuration
- multi-credential configuration
- credential `access_mode`
- attachment materialization
- `auth status`
- `cache prune`
- `mail-gateway-reader graphql`

### Phase 2

- Gmail draft creation support in `mail-gateway-draft`
- Gmail direct send support in `mail-gateway-sender`
- new outbound messages only
- long-running `serve` mode if local client ergonomics require it

### Phase 3

- provider abstraction hardening for non-Gmail adapters
- reply threading support
- optional metadata cache for incremental sync or faster repeated lookups

## References

Credential setup notes: [design-gmail-credentials.md](./design-gmail-credentials.md)

See `design-docs/references/README.md` for external references.
