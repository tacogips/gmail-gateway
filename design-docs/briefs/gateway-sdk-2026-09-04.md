# Brief: replace the GraphQL scanner with the kit runtime, declared schema, variables, `GmailGatewaySDK` (2026-09-04)

Master design: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
(sections 2, 2.6 and 3.4 are normative). The shared kit is implemented at
`/Users/taco/gits/tacogips/gateway-sdk-kit` (read its `README.md`; the pieces this brief
uses are `GatewaySchemaCatalog`, `GatewayGraphQLRuntime`, `GatewayResolverContext`,
`GatewayResolverError`, `GatewayEnvelope`, `GatewaySDK`, `GatewaySchemaSearch`,
`GatewayJSONValue`). Treat this whole brief as exactly ONE feature.

IMPORTANT: this worktree (`/Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk`,
branch `feat/gateway-sdk`) was created from the committed HEAD `2761f3b`. The main checkout
at `/Users/taco/gits/tacogips/gmail-gateway` holds a large uncommitted persistent-OAuth
work in progress. Do not read from, write to, or build in the main checkout, and do not
try to reproduce that WIP here.

## Operator decisions

- **No backward compatibility.** The substring-scanning GraphQL implementation is
  deleted, not wrapped. Query shapes the scanner tolerated but the spec never declared
  (flat `threads(accountId: ...)` arguments, loosely-honoured input types) disappear.
- The GraphQL runtime is the kit's `GatewayGraphQLRuntime`; gmail-gateway contributes the
  schema declaration and one resolver per root field. gmail-gateway must not grow its own
  parser.
- GraphQL variables are first-class.

## Verified seams (2026-09-04, HEAD 2761f3b)

- `Sources/GmailGatewayCore/GmailGatewayCLI.swift:41 public struct GmailGatewayCLI`,
  init `:46 (mode:)`, `:143 run(arguments:environment:) -> GmailGatewayCommandResult`
  (sync, non-throwing; `GmailGatewayCore.swift:37`: `exitCode, stdout, stderr`);
  subcommand dispatch `:222-274`; help text `rootHelpText(mode:)` `:564-640`.
- `GmailGatewayCLIMode` (`GmailGatewayCLI.swift:4`): `.reader`, `.draftGateway`,
  `.directSender`, `.mailboxThreads`, `.messageBox`; `requiredCapability` `:27`.
- `GmailGatewayCLIParsing.swift:141-165` `graphql` flags; `:167 loadVariables(flags:)`
  (currently dead), `:190-198 rejectUnsupportedVariables` (called from
  `GmailGatewayCLI.swift:284`), `:200 loadVariablesFile`.
- **To delete**: `GmailGatewayGraphQLScanning.swift` (`prepareGraphQLQuery`),
  `GmailGatewayGraphQLArguments.swift` (`extractStringArgument`, ..., `threads` field set
  :195), `GmailGatewayGraphQLSelection.swift` (`directFieldExists`, `selectionBody`), and
  the `rootFieldSource` dispatch chains in `GmailGatewayGraphQL.swift` (reader :18-92,
  write :100-174), `GmailGatewayGraphQLDrafts.swift:27`, `GmailGatewayGraphQLMailbox.swift:30`,
  together with the per-mode rejection helpers (`GmailGatewayGraphQL.swift:21,:28,:232`,
  `GmailGatewayGraphQLDrafts.swift:96`, `GmailGatewayGraphQLMailbox.swift:85,:97`) and the
  `*RootFields` arrays — their knowledge moves into the declared schema.
- **To keep** (the provider layer): `GmailGatewayService` (`GmailGatewayCore.swift:229`:
  `listAccounts`, `graphQLAccounts`, `graphQLAccount(id:)`, `searchThreads(...)` :275,
  `getThread` :310, `getMessage` :320, `getAttachment` :330, `listLabels` :377,
  `getProfile` :383), `GmailGatewayWriteService` (`GmailGatewayWriteService.swift:225`,
  `sendMessage(input:mode:)` :269), `GmailGatewayDraftService.swift` (`listDrafts` :61,
  `getDraft` :79, `updateDraft` :88, `sendDraft` :130, `deleteDraft` :139),
  `GmailGatewayMailboxService.swift` (`modifyThreadLabels` :107 … `insertMessage` :274),
  the `MailboxCapability` / `AccessMode` gate (`GmailGatewayCore.swift:75-117`), config
  loading, OAuth, MIME, file materialisation. These return `[String: Any]` / `Any`;
  convert with `GatewayJSONValue(any:)`.
- Type shapes: `design-docs/specs/design-gmail-gateway.md:176-240` (`Query`, `Mutation`,
  `ThreadSearchInput`, `SendMessageInput`, `ReplyMessageInput`, `ForwardMessageInput`,
  `UpdateDraftInput`, `DeleteDraftInput`, `SendDraftInput`, `SendMessagePayload`,
  `MailAccount`, `ThreadConnection`, `MailThread`, `MailMessage`, `MailMessageFileSet`,
  `MailAttachment`, `MailLabel`, `MailProfile`) plus the mailbox (13) and ingest (2)
  mutations; the JSON the services actually build is the ground truth for object fields
  where the prose drifts.
- Mode table to reproduce as authorization: reader = queries only; draft = + `drafts`,
  `draft` + createDraft/createReplyDraft/createForwardDraft/updateDraft/deleteDraft;
  sender = draft + sendMessage/replyMessage/forwardMessage/sendDraft; threads = queries +
  modifyThreadLabels/modifyMessageLabels/batchModifyMessageLabels/trashThread/untrashThread/
  trashMessage/untrashMessage/deleteThread/deleteMessage/batchDeleteMessages/createLabel/
  updateLabel/deleteLabel; message-box = queries + importMessage/insertMessage.
- Tests: swift-testing, `Tests/GmailGatewayCoreTests/` (~183 cases; `CommandTests.swift`,
  `DraftGatewayTests.swift`, `MailboxGatewayTests.swift`, `ReplyForwardTests.swift`,
  `TestGmailRequestCaptureProtocol.swift` URLProtocol capture), plus
  `Sources/GmailGatewaySwiftSmokeTests` executable; `mise run test` = `swift test` +
  `swift run gmail-gateway-swift-smoke-tests`.
- riela calls `GmailGatewayCLI(mode:).run(arguments: ["graphql","--query",doc], environment:)`
  from `/Users/taco/gits/tacogips/riela/Sources/RielaCLI/ProductionNodeAdapter+GmailGatewayCLIAddons.swift:86-103`;
  it will switch to the facade. Keep `run(arguments:environment:)` as the CLI entry.

## Deliverables

1. **Dependency.** `Package.swift`: `.package(url: "https://github.com/tacogips/gateway-sdk-kit.git", exact: "0.1.0")` (this
   worktree is `/Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk`) and
   product `GatewaySDKKit` on `GmailGatewayCore`. One-line comment that the operator
   switches it to a URL pin later.
2. **Declared schema** (`Sources/GmailGatewayCore/Schema/GmailGatewaySchema*.swift`):
   `GatewaySchemaCatalog.gmailFull` (every query, mutation, input, payload, object and
   enum type; `Direction` and any other enumerations the services accept) and
   `GatewaySchemaCatalog.gmail(mode: GmailGatewayCLIMode)` (the authorized subset; tier
   strings `reader`, `draft`, `sender`, `threads`, `message-box`). `threads` takes
   `input: ThreadSearchInput!` only. Mutations take `input:` objects only. `summary` on
   every operation; `isDestructive` on delete/trash/batchDelete. `validate()` empty for
   the full catalog and every mode; a test asserts the mode subsets match the table
   above both directions.
3. **Resolvers** (`Sources/GmailGatewayCore/GraphQL/GmailGatewayResolvers*.swift`): one
   `GatewayGraphQLRuntime.Resolver` per root field, taking coerced arguments, loading
   config from the `GatewayResolverContext.environment` (`GMAIL_GATEWAY_CONFIG`, credential
   variables) exactly as the CLI does today, calling the kept services, and returning
   `GatewayJSONValue`. Service errors become `GatewayResolverError`s carrying the existing
   `GmailGatewayError` codes so the envelope keeps today's error codes. The access-mode
   gate stays in the services.
4. **Executor** (`Sources/GmailGatewayCore/GraphQL/GmailGatewayGraphQLExecutor.swift`):
   `run(query:variables:mode:environment:) async -> GatewayEnvelope` building
   `GatewayGraphQLRuntime(catalog: .gmailFull, authorized: .gmail(mode:), resolvers:)`;
   used by the `graphql` CLI subcommand and by the facade. The CLI keeps its sync
   `run(arguments:environment:)` signature by bridging the async executor (a semaphore or
   `Task` + wait, matching how the codebase already does sync-over-async if it does;
   otherwise add a small helper). Delete `rejectUnsupportedVariables`; wire
   `--variables` / `--variables-file`. Delete the scanner files listed above and every
   helper that only they used.
5. **Facade** (`Sources/GmailGatewayCore/SDK/GmailGatewaySDK.swift`):
   ```swift
   public struct GmailGatewaySDK: GatewaySDK {
     public let provider = "gmail-gateway"
     public let tier: String
     public let catalog: GatewaySchemaCatalog       // .gmail(mode:)
     public init(mode: GmailGatewayCLIMode)
     public func execute(document:variables:environment:) async -> GatewayEnvelope
   }
   ```
6. **CLI.** `graphql --query|--query-file [--variables|--variables-file] [--pretty]`,
   `graphql schema` (authorized SDL), `graphql search <regex> [--kinds ...]
   [--include-referenced-types] [--limit N]`, `graphql operation <name>
   [--variables|--variables-file] [--select a.b,c]`; help text per mode; `README.md`
   rewritten for the declared schema, variables, and the SDK; `design-docs/specs/design-gmail-gateway.md`
   gets a note that `GmailGatewaySchema*.swift` is now normative and that the flat
   `threads` form was removed.
7. **Tests.** Rewrite the scanner-era tests against the runtime: every root field in
   every mode through `GmailGatewayCLI.run` with the URLProtocol capture (literal
   arguments and `$variables`, string/int/list/input-object variables); each validator
   error code surfaces as a non-zero exit with a JSON error; mode denial yields
   `CAPABILITY_DENIED` naming the mode and never hits the network; selection projection
   (aliases, nested `messages { from { address } }`, missing keys → null); facade `invoke`
   with `.default` selection for `threads`, `labels`, `createDraft`; `graphql schema` /
   `search` / `operation` CLI; smoke tests updated.

## Verification

`arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gmail-gateway-worktrees/gateway-sdk && swift build && swift test && swift run gmail-gateway-swift-smoke-tests && swiftlint'`
green. Commit on `feat/gateway-sdk` in this worktree as work lands; do not push.

## Non-goals

No changes to OAuth, config loading, services, MIME handling, persistent auth, or
packaging. No private parser. Do not touch `/Users/taco/gits/tacogips/gmail-gateway`
(the main checkout).
