# Brief: declared schema, GraphQL variables, and `GmailGatewaySDK` (2026-09-04)

Master design: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
(sections 2 and 3.4 are normative). The shared kit is implemented at
`/Users/taco/gits/tacogips/gateway-sdk-kit` (read its `README.md` and
`design-docs/briefs/gateway-sdk-kit-2026-09-04.md` for the exact API, especially
`GraphQLVariableInliner`). Treat this whole brief as exactly ONE feature.

IMPORTANT: this worktree (`/Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk`,
branch `feat/gateway-sdk`) was created from the committed HEAD `2761f3b`. The main checkout
at `/Users/taco/gits/tacogips/gmail-gateway` holds a large uncommitted persistent-OAuth
work in progress (`runPersistent`, `auth setup`, Keychain vault, google-service-gateway
dependency). Do not read from, write to, or build in the main checkout, and do not try to
reproduce that WIP here. Everything in this brief is against the sync
`GmailGatewayCLI.run(arguments:environment:)` path that exists at HEAD.

## Goal

1. gmail-gateway gains a declared GraphQL schema (today there is none: execution is
   substring scanning and the only SDL is prose in `design-docs/specs/design-gmail-gateway.md`).
2. `graphql --query ... --variables <json> | --variables-file <path>` works in every mode.
3. A `GmailGatewaySDK` facade exposes operation-by-name invocation, raw passthrough,
   SDL, and regex search.

## Verified seams (2026-09-04, HEAD 2761f3b)

- `Sources/GmailGatewayCore/GmailGatewayCLI.swift:41 public struct GmailGatewayCLI`,
  init `:46 (mode:)`, `:143 run(arguments:environment:) -> GmailGatewayCommandResult`
  (sync, non-throwing; `GmailGatewayCore.swift:37`: `exitCode, stdout, stderr`).
  Subcommand dispatch `:222-274` (`doctor`, `graphql`, `config validate`, `auth ...`,
  `cache prune`, `file download`); no `schema` subcommand. Help text `rootHelpText(mode:)`
  `:564-640`.
- `GmailGatewayCLIMode` (`GmailGatewayCLI.swift:4`): `.reader`, `.draftGateway`,
  `.directSender`, `.mailboxThreads`, `.messageBox`; `requiredCapability` `:27`.
- `GmailGatewayCLIParsing.swift:141-165` `graphql` flags (`--query` xor `--query-file`,
  `--config`, `--pretty`); `:167 loadVariables(flags:)` (dead code, returns
  `[String: Any]`); `:190-198 rejectUnsupportedVariables` (called from
  `GmailGatewayCLI.swift:284`); `:200 loadVariablesFile`.
- Scanner: `GmailGatewayGraphQLScanning.swift:1 prepareGraphQLQuery` (strips comments,
  rejects fragments :51 and multiple root fields :62); dispatch chains
  `GmailGatewayGraphQL.swift` (reader :18-92, write :100-174, `executeReaderGraphQL` :3
  internal, `executeWriteGraphQL` :100 public, `executeMailboxGraphQL` :177,
  `executeMessageBoxGraphQL` :195), `GmailGatewayGraphQLDrafts.swift:27`,
  `GmailGatewayGraphQLMailbox.swift:30`; argument scanning
  `GmailGatewayGraphQLArguments.swift` (`extractStringArgument`, `extractOptionalIntArgument`,
  `threads` field set :195); selection projection `GmailGatewayGraphQLSelection.swift`.
- Root-field lists: `GmailGatewayGraphQLDrafts.swift:3 draftMutationRootFields`
  (createDraft, createReplyDraft, createForwardDraft, updateDraft, deleteDraft), `:10
  sendMutationRootFields` (sendMessage, replyMessage, forwardMessage, sendDraft), `:11
  draftQueryRootFields` (drafts, draft); `GmailGatewayGraphQLMailbox.swift:3
  mailboxMutationRootFields` (13), `:19 ingestMutationRootFields` (importMessage,
  insertMessage); `GmailGatewayGraphQL.swift:16 writeMutationRootFields`. Reader queries
  (every mode): `accounts`, `account(id)`, `threads(accountId, query, starred, direction,
  labelIds, receivedAfter, receivedBefore, first, after; also nested under input:)`,
  `thread(accountId, threadId)`, `message(accountId, messageId)`,
  `messageFileSet(accountId, messageId)`, `attachment(accountId, messageId, attachmentId)`,
  `labels(accountId)`, `profile(accountId)`.
- Per-mode rejection table (must be reproduced by the catalog): reader = queries only
  (`GmailGatewayGraphQL.swift:21,:28`); draft = + drafts/draft + draft mutations, no send
  (`GmailGatewayGraphQLDrafts.swift:96`); sender = + send mutations; threads = queries +
  mailbox mutations only (`GmailGatewayGraphQL.swift:232`, `GmailGatewayGraphQLMailbox.swift:85`);
  message-box = queries + ingest only (`GmailGatewayGraphQLMailbox.swift:97`). Explicit
  allowlists for `updateDraft` (`GmailGatewayGraphQLDrafts.swift:13`) and ingest
  (`GmailGatewayGraphQLMailbox.swift:21`).
- Type shapes: `design-docs/specs/design-gmail-gateway.md:176-240` (`Query`, `Mutation`,
  `ThreadSearchInput`, `SendMessageInput`, `ReplyMessageInput`, `ForwardMessageInput`,
  `UpdateDraftInput`, `DeleteDraftInput`, `SendDraftInput`, `SendMessagePayload`,
  `MailAccount`, `ThreadConnection`, `MailThread`, `MailMessage`, `MailMessageFileSet`,
  `MailAttachment`, `MailLabel`, `MailProfile`); the fields the projection layer actually
  returns (`GmailGatewayGraphQLSelection.swift`, the `*Service` JSON builders) are the
  ground truth where the prose drifts.
- Services (public, untyped `[String: Any]`, no tier enforcement): `GmailGatewayService`
  (`GmailGatewayCore.swift:229`), `GmailGatewayWriteService` (`GmailGatewayWriteService.swift:225`),
  drafts (`GmailGatewayDraftService.swift`), mailbox (`GmailGatewayMailboxService.swift`).
- Tests: swift-testing, `Tests/GmailGatewayCoreTests/` (~183 cases; `CommandTests.swift`,
  `DraftGatewayTests.swift`, `MailboxGatewayTests.swift`, `TestGmailRequestCaptureProtocol.swift`
  URLProtocol capture), plus `Sources/GmailGatewaySwiftSmokeTests` executable;
  `mise run test` = `swift test` + `swift run gmail-gateway-swift-smoke-tests`.
- riela calls `GmailGatewayCLI(mode:).run(arguments: ["graphql","--query",doc], environment:)`
  from `/Users/taco/gits/tacogips/riela/Sources/RielaCLI/ProductionNodeAdapter+GmailGatewayCLIAddons.swift:86-103`
  with `acceptsVariables: false`; it will switch to the facade and start passing
  variables. Keep `run(arguments:environment:)` working.

## Deliverables

1. **Dependency.** `Package.swift`: `.package(path: "../../gateway-sdk-kit")` (this
   worktree is `/Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk`) and
   product `GatewaySDKKit` on `GmailGatewayCore`. One-line comment that the operator
   switches it to a URL pin later.
2. **Declared schema** (`Sources/GmailGatewayCore/Schema/GmailGatewaySchema.swift`, split
   across files if over 1000 lines): one full declaration of every root field, argument,
   input type, payload and object type as `GatewaySchemaCatalog` building blocks, and
   `GatewaySchemaCatalog.gmail(mode: GmailGatewayCLIMode) -> GatewaySchemaCatalog`
   filtering by mode exactly per the rejection table (tier strings: `reader`, `draft`,
   `sender`, `threads`, `message-box`). `threads` is declared with flat arguments
   (accountId, query, starred, direction, labelIds, receivedAfter, receivedBefore, first,
   after) matching what the scanner reads; document in the summary that the nested
   `input:` form is also accepted by the scanner. Parity tests: for each mode, catalog
   query names == the reader list (+ drafts where applicable) and catalog mutation names
   == the union of the applicable `*RootFields` arrays; `catalog.validate()` empty for
   every mode; every argument name declared for a root field is one the scanner extracts
   (drive `prepareGraphQLQuery` + the dispatch with a fake service and assert no
   "unknown argument"/ignored-argument path; where the scanner silently ignores unknown
   arguments, add a test that it reads each declared argument).
3. **Variables.** Delete `rejectUnsupportedVariables` and its call sites; wire
   `loadVariables` / `loadVariablesFile` into the `graphql` path; convert to
   `[String: GatewayJSONValue]`; run `GraphQLVariableInliner(catalog: .gmail(mode:))
   .inline(document:variables:)` BEFORE `prepareGraphQLQuery`; map inliner errors to
   `GmailGatewayError(code: .invalidArgument, exitCode: .invalidCliUsage)` with the
   inliner's message. The rewritten document (no variable definitions, literals inlined)
   flows into the unchanged scanner. Documents without variable definitions behave exactly
   as before (byte-identical path).
4. **Facade** (`Sources/GmailGatewayCore/SDK/GmailGatewaySDK.swift`):
   ```swift
   public struct GmailGatewaySDK: GatewaySDK {
     public let provider = "gmail-gateway"
     public let tier: String                   // "reader" | "draft" | "sender" | "threads" | "message-box"
     public let catalog: GatewaySchemaCatalog
     public init(mode: GmailGatewayCLIMode)
     public func execute(document:variables:environment:) async -> GatewayEnvelope
   }
   ```
   `execute` goes through a new internal `GmailGatewayGraphQLExecutor.run(query:variables:
   mode:environment:) -> GmailGatewayCommandResult` that the `graphql` subcommand also
   uses (config loading from `GMAIL_GATEWAY_CONFIG` in `environment`, inliner, scanner,
   dispatch, envelope rendering), so CLI and SDK cannot drift; the result maps to
   `GatewayEnvelope` via `init(parsingCLIOutput:exitCode:)`.
5. **CLI.** `graphql schema` (prints `catalog.sdl()` for the binary's mode),
   `graphql search <regex> [--kinds ...] [--include-referenced-types] [--limit N]` (JSON
   matches), `graphql operation <name> [--variables|--variables-file] [--select a.b,c]`
   (facade invoke); `--variables` / `--variables-file` documented for `graphql`; help text
   per mode updated; `README.md` gains "GraphQL variables" and "Client SDK" sections;
   `design-docs/specs/design-gmail-gateway.md` gets a short note that the declared schema
   in `GmailGatewaySchema.swift` is now the source of truth.
6. **Tests**: parity and validate() per mode (item 2); variables end to end through
   `GmailGatewayCLI.run` with the URLProtocol capture for `threads` (string, int, list
   variables), `sendMessage` (input object variable) in sender mode, and a `$var` inside a
   string literal left untouched; each inliner validation error surfaces as
   `invalidArgument` with a non-zero exit; a document without variables produces the same
   request as before (regression); facade `invoke` with `.default` selection for `threads`
   and `labels` (reader) and `createDraft` (draft mode) producing accepted documents;
   reader-mode SDK invoking `sendMessage` yields the existing mode-rejection error in the
   envelope; `graphql schema` / `graphql search` CLI; smoke tests updated for the new help.

## Verification

`arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk && swift build && swift test && swift run gmail-gateway-swift-smoke-tests && swiftlint'`
green. Commit on `feat/gateway-sdk` in this worktree as work lands; do not push.

## Non-goals

No parser rewrite (the scanner stays), no changes to OAuth / config loading / services /
MIME handling, no persistent-auth work, no packaging changes. Do not touch
`/Users/taco/gits/tacogips/gmail-gateway` (the main checkout).
