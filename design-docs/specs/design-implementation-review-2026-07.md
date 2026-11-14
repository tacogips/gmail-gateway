# Implementation and Specification Review (2026-07)

This document records a full review of the `mail-gateway` implementation and its
specifications, identifying defects, spec/implementation divergences, security and
robustness concerns, performance issues, and maintainability improvements.
No code changes were made as part of this review.

Reviewed sources:

- All Swift files under `Sources/MailGatewayCore/`, `Sources/MailGateway{Reader,Draft,Sender}/`
- `Tests/AppCoreTests/CommandTests.swift`, `Sources/MailGatewaySwiftSmokeTests/`
- `design-docs/specs/design-mail-gateway.md`, `architecture.md`, `command.md`
- `Package.swift`, `README.md`

Severity legend: **Critical** = feature broken or spec guarantee violated in a way
callers will hit; **High** = likely incorrect behavior or meaningful risk;
**Medium** = divergence or robustness gap; **Low** = polish, hygiene, docs.

## 1. Functional Defects

### 1.1 Body-file downloads can never succeed (Critical)

Nothing in the production code ever writes `body.txt` / `body.html` under the
message cache directory. The only writer is a smoke-test fixture
(`Sources/MailGatewaySwiftSmokeTests/MessageFileSmokeTests.swift:129`).

- `messageFileSet` (`MessageFileDownloads.swift:100-125`) only lists files that
  already exist on disk, so in real usage it always returns `hasFiles: false`.
- `file download` for `BODY_TEXT` / `BODY_HTML` / `TEMPORARY_FILE` kinds does not
  fetch from Gmail (`materializedFileURL`, `MessageFileDownloads.swift:289-291`
  returns the local path without materialization), so it always fails with
  "Message file is not materialized locally".

The entire body/temporary-file materialization flow described in
`design-mail-gateway.md` ("GraphQL returns downloadKey metadata, and file bytes
are retrieved only by an explicit gateway download command") is unreachable for
bodies. Either a body-materialization step must be implemented (e.g., during
`message` / `thread` retrieval or inside `file download`), or the
`messageFileSet` / body download surface should be removed from the schema and help
text until it works.

### 1.2 GraphQL variables are parsed and discarded (Critical)

`MailGatewayCLI.swift:144`:

```swift
_ = try loadVariables(flags: flags)
```

`--variables` / `--variables-file` are validated as JSON and then thrown away.
No variable substitution exists in the executor, so any query using `$var`
fails later with a confusing "Missing GraphQL argument" or "must be a string
literal" error. The design document explicitly shows
`--variables-file ./vars.json` as the primary transport example. Either
implement variable substitution or reject the flags with a clear
"variables are not supported yet" error.

### 1.3 Pagination is not implemented (Critical)

The spec defines `first: Int = 20` and `after: String` cursors with
"cursors are valid only for the same account and identical filter set".
Implementation:

- Page size is hardcoded to `maxResults=10` (`GmailLiveReader.swift:203`),
  contradicting the spec default of 20 and ignoring `first` entirely.
- `after` is never extracted or forwarded as a Gmail `pageToken`, so
  `pageInfo.endCursor` (which holds Gmail's `nextPageToken`) cannot be used.
  Results beyond the first page are unreachable.
- `edges[].cursor` is set to a Gmail *message* ID (`GmailLiveReader.swift:47`),
  which is not a valid continuation token of any kind, and is a different value
  space from `pageInfo.endCursor`.

### 1.4 `threads` returns single-message pseudo-threads (High)

`searchThreads` lists *messages* (`/users/me/messages`), dedupes by `threadId`,
and builds each "thread" node from exactly one message
(`GmailLiveReader.swift:39-53`). Consequences:

- `MailThread.messages` contains one message even for multi-message threads,
  while the `thread(...)` query returns all messages. The same type has two
  different shapes depending on the entry point.
- Thread `subject` / `snippet` come from whichever message matched the search,
  not the latest activity. The spec's ordering guarantee ("descending by most
  recent provider thread activity, with provider thread ID as a stable
  tie-breaker") is not enforced at all.
- `totalCount` is Gmail's `resultSizeEstimate` for *messages*, not threads, and
  it is an estimate. The spec presents it as a real count.

Using `/users/me/threads.list` would align semantics with the spec.

### 1.5 Missing search filters silently ignored (High)

`ThreadSearchInput` in the spec includes `unread`, `from`, and `hasAttachments`.
None are implemented in `MailGatewayGraphQL.swift:43-62` or
`GmailLiveReader.swift`. Because argument extraction is lookup-based, an
unsupported argument is silently dropped rather than rejected — a caller
sending `unread: true` gets unfiltered results with no warning. Unknown/
unsupported arguments should either work or produce an error.

### 1.6 `cache prune` reports success on failed deletion (Medium)

`MailGatewayCore.swift:343` uses `try? FileManager.default.removeItem(...)` and
then unconditionally appends the path to `prunedPaths`. A permission failure is
reported as a successful prune.

### 1.7 Cached-attachment lookup can match the wrong file (Medium)

`getAttachment` (`MailGatewayCore.swift:222-238`) matches directory entries by
the prefix `"<attachmentId>-"`. If one attachment ID is a prefix of another
(e.g., `abc` and `abc-def`), the entry `abc-def-<filename>` matches prefix
`abc-` and the wrong attachment metadata is returned. The stored-name scheme
(`<id>-<filename>`) has no delimiter that cannot appear inside an ID. The
hashed-prefix form already exists (`attachmentStorageFilenamePrefix`); using it
unconditionally, or storing a small metadata sidecar, would remove the
ambiguity. Additionally, this cached path returns `mimeType:
"application/octet-stream"` and `sizeBytes: null` even though the file is local
and could be stat'ed (`MailGatewayCore.swift:243-254`), and no metadata
consistency check is performed although the spec requires "if the file already
exists and its metadata matches, the cached path is reused".

### 1.8 RFC 2822 date parsing is single-format (Medium)

`parseMailDate` (`GmailLiveReader.swift:505-516`) only accepts
`"EEE, d MMM yyyy HH:mm:ss Z"`. Valid `Date:` headers without a weekday, with
obsolete zone names (`GMT`, `EST`), or with comments fall through and the *raw
header string* is returned in a field the spec types as `DateTime`. Callers
receive mixed ISO-8601 and RFC-2822 values in the same field. Fall back to
`internalDate` (already available) instead of returning the raw string.

### 1.9 Address parsing breaks on quoted display names (Medium)

`mailAddressList` (`GmailLiveReader.swift:496-503`) splits on `,`, so
`"Doe, John" <jd@example.com>` becomes two broken entries. It also emits only a
`raw` key; the spec references a `MailAddress` type but never defines its
fields (see 5.2), so the contract is undefined on both sides.

### 1.10 Date range filters silently drop time-of-day (Low)

`receivedAfter: "2026-07-01T15:00:00Z"` is truncated to `after:2026/07/01`
(`GmailLiveReader.swift:282-295`). Gmail interprets these dates in the
account's timezone. The spec types these as `DateTime`; the precision loss and
timezone semantics should at least be documented, or `after:`/`before:` with
epoch seconds should be used (Gmail supports Unix timestamps for these
operators, which preserves the time component).

## 2. Spec / Implementation Divergences

### 2.1 Reader write-blocking is textual, not schema-based (High)

The spec states: "`mail-gateway-reader` must fail fast if a send mutation is
submitted. This is enforced by exposing a reduced schema rather than only
checking at resolver runtime." The implementation is exactly the opposite: a
substring scan for `sendMessage` / `createDraft` at brace depth 1
(`MailGatewayGraphQL.swift:28-34`). It works for straightforward queries, but
it is not a reduced schema, and the guarantee depends on the correctness of a
hand-rolled scanner (see 4.1). Either implement per-binary schemas or amend the
spec to describe the actual enforcement and its limits.

### 2.2 Message bodies are inlined despite spec prohibition (High)

`design-mail-gateway.md` Schema Principles: "body and temporary-file payloads
are never inlined into GraphQL responses". But the same spec's
`MailMessage` type defines `textBody` / `htmlBody`, and the implementation
returns full decoded bodies inline (`GmailLiveReader.swift:383-384`). The spec
contradicts itself and the implementation follows the schema, not the
principle. Decide which is authoritative (the stated goal of bounding AI token
consumption suggests bodies should be truncated or file-backed) and fix the
other side.

### 2.3 `localPath` returned through GraphQL despite spec prohibition (Medium)

Schema Principles: "filesystem materialization paths are returned only by
explicit gateway download commands, not by GraphQL message-file metadata."
`attachment(...)` returns `localPath` for cached files
(`MailGatewayCore.swift:234-244`). Also the spec's own `MailAttachment` type
still declares `localPath: String` — another internal spec contradiction.

### 2.4 Rejected-attachment reporting not implemented (Medium)

Spec: mutations return "rejected attachment paths with reasons if partial
validation fails". Implementation throws on the first invalid path
(`MailGatewayWriteService.swift:78`) and `rejectedAttachments` is always `[]`
(`GmailLiveWriter.swift:34,63`).

### 2.5 Error model only partially surfaced through GraphQL (Medium)

`executeReaderGraphQL` / `executeWriteGraphQL` wrap only errors whose exit code
is `.graphqlExecutionError` into the GraphQL `errors` array
(`MailGatewayGraphQL.swift:10,116`). Provider API failures and rate limiting
(`PROVIDER_API_ERROR`, `PROVIDER_RATE_LIMITED`, exit code 6) escape to the CLI
error path and appear as a non-GraphQL error object on stderr. The spec's error
model lists these as GraphQL extension codes. Callers must handle two error
formats for the same command.

### 2.6 Observability section unimplemented (Medium)

No request IDs, no correlation logging, no provider request-ID capture exist
anywhere; the spec's "Errors and Observability / Logging" section (stderr logs,
request ID per request) is entirely unimplemented. Either implement a minimal
version (a UUID per invocation included in error details) or mark the section
as future work.

### 2.7 No provider adapter layer (Medium)

The spec defines a provider adapter contract (`listAccountsCapabilities`,
`searchThreads`, ..., `interactiveAuthorize`) with the GraphQL layer depending
only on the canonical interface. The implementation hardcodes
`GmailLiveReader()` / `GmailLiveWriter()` construction inside the service layer
(`MailGatewayCore.swift:190,207,213,261`; `MailGatewayWriteService.swift:82,89`).
Acceptable for v1, but the extensibility promise ("adding a new provider
requires a new adapter implementation") currently requires touching the service
layer everywhere. Introducing a `MailProviderAdapter` protocol would make the
seam real.

### 2.8 Default-config fallback fabricates an account (Low)

With no config file, a default account `personal` with email
`personal@example.invalid` is synthesized (`ConfigLoading.swift:185-198`) and
surfaced through `accounts` as if configured. In the draft/sender binaries this
placeholder becomes the `From:` header if a token exists. Consider marking
fallback accounts in output (or requiring an explicit email before writes).

### 2.9 `From` uses configured address, not authenticated identity (Low)

`buildRawMessage` uses `account.emailAddress` from config
(`GmailLiveWriter.swift:15-17`). Gmail typically rewrites `From:` to the
authenticated principal, but a config/token identity mismatch is silent. The
token store records `emailAddress` from the profile check
(`GmailOAuthBootstrap.swift:53`); comparing it against
`account.email_address` at login or send time would catch misconfiguration.

## 3. Outbound MIME Construction Issues

All in `GmailLiveWriter.swift`.

### 3.1 Mixed line endings in multipart bodies (High)

Top-level headers are joined with `\r\n`, but multipart part internals are
built with Swift multiline literals using `\n`, then parts are joined with
`\r\n` (`multipartBody`, lines 170-197). The result mixes `\n` and `\r\n`
within one MIME entity, violating RFC 5322/2045. Gmail is tolerant today; other
consumers of drafts (or future providers) may not be.

### 3.2 `textBody` silently dropped when `htmlBody` present (Medium)

Both `simpleBody` (line 160) and `multipartBody` (line 175) pick
`htmlBody ?? textBody`. Supplying both should produce
`multipart/alternative`; instead the text part vanishes without notice.

### 3.3 Empty `To:` header emitted (Medium)

`"To: \(input.to.joined(...))"` is always appended (line 105) even when `to`
is empty and recipients are only in `cc`/`bcc`, producing a malformed empty
`To:` header.

### 3.4 Attachment part quality (Low)

- `Content-Type` is always `application/octet-stream` regardless of extension.
- Filenames are sanitized ASCII-only (`sanitizedFilename`), silently renaming
  non-ASCII filenames with no RFC 2231/2047 encoding.
- `base64EncodedString()` produces one unwrapped line, exceeding RFC 2045's
  76-character encoded-line limit.
- Whole attachment files are loaded into memory (`Data(contentsOf:)`); no size
  guard exists even though Gmail rejects raw messages above ~25 MB with an
  opaque provider error.

## 4. Robustness and Security

### 4.1 Hand-rolled GraphQL scanner is the enforcement boundary (High)

The read-only guarantee of `mail-gateway-reader` (a stated security constraint)
rests on `rangeOfField` string scanning (`MailGatewayGraphQL.swift:280-336`).
The scanner handles strings and brace depth but not GraphQL comments
(`# sendMessage` on a line would false-positive; conversely a comment cannot
smuggle a mutation, so the failure mode is deny-side, which is safe), block
strings (`"""`), fragments, or aliases resolving to other fields. Today the
worst outcomes appear to be false rejections and silently ignored arguments
(see 1.5), not write escapes — but the boundary deserves either a real parser
or explicit documented limits plus adversarial tests. Related parsing gaps:

- `extractStringArgument("query", ...)` searches the entire field source
  including nested selections, so an argument with the same name on a nested
  field would be misattributed (low likelihood with the current schema).
- Operation names, fragments, aliases, `__typename`, and multi-field root
  selections are unsupported; only the first recognized root field is executed
  and the rest are silently ignored.

### 4.2 OAuth loopback receiver accepts exactly one connection (High)

`waitForCode` (`GmailOAuthBootstrap.swift:192-231`) accepts a single TCP
connection and reads once. Real browsers open speculative connections and may
request `/favicon.ico`; whichever connection arrives first is consumed, and the
login fails or hangs until timeout. The receiver should loop: accept, parse; if
the path does not match the redirect path (or the read is empty), respond 404
and keep waiting until the deadline. A single `read()` of 8 KiB also assumes
the request arrives in one segment; a partial first segment fails the login.

### 4.3 `localhost` redirect host vs IPv4-only bind (Medium)

When `--redirect-uri http://localhost:<port>/...` is given, the listener binds
`127.0.0.1` only (`LoopbackRedirectURI.bindHost`,
`GmailOAuthBootstrap.swift:124`), but the browser resolves `localhost`, which
can prefer `::1`. Depending on the browser's fallback behavior the callback may
fail. Either bind both stacks or rewrite the authorization redirect host to
`127.0.0.1` (Google's recommended loopback form).

### 4.4 Credential env-var name collisions (Medium)

`credentialEnvSuffix` (`ConfigLoading.swift:39-49`) maps every
non-alphanumeric character to `_` and uppercases, so credential IDs
`gmail-personal`, `gmail_personal`, and `gmail.personal` all resolve to
`MAIL_GATEWAY_CREDENTIAL_GMAIL_PERSONAL_...`. An env override intended for one
credential silently applies to another. Config loading should reject configs
whose credential IDs produce duplicate env suffixes.

### 4.5 Client-secret files required for unrelated commands (Medium)

`validateOAuthClientSecretPaths` (`ConfigLoading.swift:445-454`) runs on every
config load and fails if *any* credential's client secret file is unreadable —
including for `cache prune`, `file download` of cached files, or operations on
a different credential. One broken credential takes down the whole CLI.
Validation should be deferred to the credential actually being used (config
validate can keep the eager check).

### 4.6 Provider error bodies copied into error output (Low)

HTTP error handling includes up to 1000 characters of the response body in
error details (`GmailOAuthSupport.swift:160-167`). Gmail error bodies are
generally safe, but this channel will print whatever the server returns to
stderr; worth bounding to structured fields when the body parses as a Google
error JSON.

### 4.7 No retry/backoff despite modeling rate limits (Low)

`PROVIDER_RATE_LIMITED` is detected (HTTP 429) but never retried; transient
5xx/429 fail the whole invocation. For an AI-callers-first tool a bounded
retry with jitter for idempotent GETs would meaningfully improve reliability.

## 5. Specification Document Issues

### 5.1 Internal contradictions in design-mail-gateway.md (Medium)

- "body ... payloads are never inlined" vs `MailMessage.textBody/htmlBody`
  fields (see 2.2).
- "filesystem materialization paths are returned only by explicit gateway
  download commands" vs `MailAttachment.localPath` in the schema (see 2.3).
- "explicit hydration is performed only through `attachment(...)`" (line 151)
  vs "only explicit gateway download commands may fetch payload bytes"
  (Materialization Rules). The implementation's `attachment(...)` fetches
  metadata (and incidentally the full payload, see 6.1) but materializes
  nothing; the two spec passages disagree about what hydration means.

### 5.2 Undefined types and enums (Low)

The schema references `MailAddress!`, `DateTime`, `MailProvider`,
`ThreadSearchInput.unread/from/hasAttachments` without defining `MailAddress`
fields or `DateTime` format. Implementation invented `{ raw: String }` for
addresses. Define these in the spec.

### 5.3 Stale companion specs (Low)

- `architecture.md` still describes targets `AppCore` / `AppCLI`, which no
  longer exist (`MailGatewayCore`, `MailGatewayReader`, etc.), and mentions
  Cask DMG releases that the macos-cask-release skill marks removed.
- `command.md` documents `mail-gateway [--help] [--version]`: the binary name
  is wrong, `--version` is not implemented anywhere, and none of the real
  commands (`graphql`, `config validate`, `auth`, `cache prune`,
  `file download`) are documented. The real CLI surface exists only in
  `design-mail-gateway.md` prose and `--help` text. `command.md` should become
  the authoritative CLI reference.

### 5.4 `--version` missing entirely (Low)

No version flag or subcommand exists in `MailGatewayCLI`. For Homebrew-released
binaries a version identifier is expected (formula audits and user bug reports
both need it).

## 6. Performance

### 6.1 `attachment(...)` downloads the full payload to learn its size (High)

`getAttachment` (`GmailLiveReader.swift:81-151`) calls the attachments endpoint
whose response includes the complete base64 payload, decodes it solely to
compute `remoteSize`, and then discards the bytes (state stays
`NOT_MATERIALIZED`). A later `file download` fetches the same payload again.
For a metadata query this can transfer tens of megabytes twice. The message's
part metadata already includes `body.size`; the extra fetch should be dropped
(or, if fetched, the payload should be materialized to cache immediately).

### 6.2 N+1 sequential full-format fetches in thread search (Medium)

Each listed message triggers a sequential `format=full` fetch including decoded
bodies (`GmailLiveReader.swift:49`), so a default search issues up to 11
serial HTTP round trips and downloads full bodies to build list snippets.
`format=metadata` (headers only) or Gmail batch requests would cut both
latency and transfer substantially.

### 6.3 Size-equality fallback for attachment resolution (Low)

When the attachment ID does not match part metadata, the code falls back to
matching any attachment with the same byte size
(`GmailLiveReader.swift:109-111`) — a heuristic that can mislabel filename and
MIME type when two attachments share a size.

## 7. Configuration Loading

### 7.1 Hand-rolled TOML subset rejects valid TOML (Medium)

`parseTomlSubset` (`ConfigLoading.swift:241-342`):

- A trailing comment after a value (`cache_dir = "/x" # note`) is a parse
  error, though it is valid TOML.
- Escapes inside basic strings are not decoded (`"a\"b"` keeps the backslash;
  `\n`, `\t`, `\\` are all literal).
- No integers, booleans, multiline strings, literal strings, or dotted keys.

Either adopt a real TOML library (consistent with the project's
lib-replacement policy) or document the accepted subset in `command.md` and
emit clearer errors ("trailing comments are not supported").

### 7.2 Misc config semantics (Low)

- `email_address` validation is only "contains @".
- `ensureUnique` on `token_store_path` protects file stores, but two
  credentials can share the same `TOKEN_STORE_JSON` env content unchecked
  (consistent with 4.4).
- The generic catch in `MailGatewayCLI.run` maps *any* non-`MailGatewayError`
  to `CONFIG_INVALID` (`MailGatewayCLI.swift:50-56`), mislabeling unexpected
  failures.

## 8. Maintainability and Testing

### 8.1 `[String: Any]` domain model (Medium)

All domain data flows as `[String: Any]` dictionaries with stringly-typed keys
across reader, writer, GraphQL projection, and downloads. This forfeits Swift's
type system (typos in keys compile fine; `NSNull` juggling is everywhere) and
makes the GraphQL projection logic fragile. Introducing `Codable` structs for
the canonical model (the spec already defines it) would remove a whole class of
errors and simplify selection projection.

### 8.2 Naming and structure (Low)

- `MailGatewayReaderService` also powers writes and downloads; the name
  misleads (`MailGatewayWriteService` wraps it; `MessageFileDownloads.swift`
  extends it).
- Gmail URL construction is duplicated between reader and writer
  (`gmailURLComponents` vs inline components in `postGmailJSONObject`).
- Error-code reuse blurs taxonomy: file-copy failures and materialization
  failures use `CONFIG_INVALID` / `configurationError`
  (`MessageFileDownloads.swift:179-189,320-329`), and invalid download keys use
  `invalidCliUsage` even when reached via service APIs.
- `Tests/AppCoreTests` path vs target name `MailGatewayCoreTests`
  (`Package.swift:35-39`) is a leftover from the template rename.
- `mail-gateway-swift-smoke-tests` is exposed as a SwiftPM *product*
  (`Package.swift:15`); if it only exists for CI it does not need to be a
  public product that release tooling could pick up.

### 8.3 Test coverage gaps (Medium)

Unit tests cover OAuth client selection, token freshness, loopback receiver,
and outbound validation well. Missing coverage, in priority order:

1. GraphQL scanner behavior: mutation blocking with comments/aliases/multiple
   root fields; unsupported-argument handling; selection projection.
2. TOML subset parser: trailing comments, escapes, malformed sections.
3. Download-key encode/decode round trips, including sanitization and the
   attachment-without-attachmentId rejection.
4. `normalizedPath` / `isWithinRoot` traversal cases (`..`, symlink roots are
   untested; note `isWithinRoot` does not resolve symlinks, so a symlink inside
   an allowed root can point outside it — relevant to
   `allowed_send_attachment_roots` and download output validation).
5. Cached-attachment prefix-collision case from 1.7.
6. MIME construction: header folding, empty `To:`, both-bodies case.

Smoke tests (`MailGatewaySwiftSmokeTests`) cover CLI flows well but run as a
separate executable; wiring them into `task test` (if not already) and CI
matters more as the surface grows.

## 9. Prioritized Recommendations

| Priority | Item | Sections |
|----------|------|----------|
| P0 | Implement or remove body/temp-file materialization so `messageFileSet` + `file download` work end to end | 1.1 |
| P0 | Support GraphQL variables or reject the flags explicitly | 1.2 |
| P0 | Implement `first`/`after` pagination wired to Gmail `pageToken` | 1.3 |
| P1 | Switch thread search to `threads.list`; fix `totalCount`, node shape | 1.4 |
| P1 | Reject unsupported search arguments; implement `unread`/`from`/`hasAttachments` | 1.5 |
| P1 | Fix OAuth loopback accept-loop and partial-read handling | 4.2, 4.3 |
| P1 | Stop fetching full attachment payloads for metadata queries | 6.1 |
| P1 | Resolve spec self-contradictions (bodies inline, localPath, hydration) and update schema docs | 2.2, 2.3, 5.1 |
| P2 | Normalize MIME output (CRLF, multipart/alternative, To header, size guard) | 3.x |
| P2 | GraphQL errors for provider failures; error taxonomy cleanup | 2.5, 7.2, 8.2 |
| P2 | Env-suffix collision check; lazy client-secret validation | 4.4, 4.5 |
| P2 | Typed domain model (`Codable` structs) | 8.1 |
| P3 | Real TOML library or documented subset | 7.1 |
| P3 | `--version`, refresh `command.md` / `architecture.md` | 5.3, 5.4 |
| P3 | Provider adapter protocol; retry/backoff; observability minimum | 2.6, 2.7, 4.7 |

## References

- Primary spec: [design-mail-gateway.md](./design-mail-gateway.md)
- Credential setup: [design-gmail-credentials.md](./design-gmail-credentials.md)
- Pending decisions raised by this review: `design-docs/user-qa/qa-implementation-review-2026-07.md`
