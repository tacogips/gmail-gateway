# Message File Materialization

**Status**: Completed
**Design Reference**: design-docs/specs/design-mail-gateway.md#attachment-handling

## Objective

Allow mail-gateway-reader to expose per-message body and temporary-file
metadata without placing file payloads in GraphQL. GraphQL returns
vendor-neutral `downloadKey` values. A separate gateway command downloads a
selected file or selected files into local paths only when a caller explicitly
needs them.

## Deliverables

- `Sources/MailGatewayCore/MailGatewayCore.swift`
  - Add message-file metadata helpers on `MailGatewayReaderService`.
  - Add a GraphQL-shaped field for reading a message file set.
  - Return `downloadKey` values, not file payloads, from GraphQL.
  - Add a `file download` command that resolves one or more keys and returns
    local paths.
- `Sources/MailGatewaySwiftSmokeTests/main.swift`
  - Cover body and temporary file materialization.
  - Cover cached message file set lookup.
- `README.md` and `design-docs/specs/design-mail-gateway.md`
  - Document the new local file materialization behavior.

## Completion Criteria

- [x] Message text body metadata can be exposed with a vendor-neutral download key.
- [x] Message HTML body metadata can be exposed with a vendor-neutral download key.
- [x] Temporary file metadata can be exposed with a vendor-neutral download key.
- [x] GraphQL file metadata does not include file payloads or local payload paths.
- [x] `file download --key` resolves a selected key and returns a local path.
- [x] Repeated `file download --key` values resolve a batch and return
  per-file local paths without filename collisions.
- [x] `swift build` passes.
- [x] `swift run mail-gateway-swift-smoke-tests` passes.
- [x] SwiftLint has been run or unavailability is reported.

## Progress Log

### Session: 2026-06-20

**Tasks Completed**: Started plan and inspected the current Swift baseline.
**Notes**: The current implementation is a local GraphQL-shaped reader baseline;
live Gmail API retrieval remains out of scope for this change.

### Session: 2026-06-20 Completion

**Tasks Completed**: Added vendor-neutral message file metadata with opaque
download keys, added `mail-gateway-reader file download --key`, updated smoke
coverage, and documented the no-payload GraphQL boundary. The download command
also supports repeated `--key` values for batch materialization.
**Verification**: `swift build` passed; `swift run mail-gateway-swift-smoke-tests`
passed; `swiftlint --quiet` passed; Xcode toolchain `/usr/bin/xcrun swiftlint
--quiet` passed.
