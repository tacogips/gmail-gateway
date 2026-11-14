# Architecture

## Status

Current implementation

## Overview

`gmail-gateway` is a Swift Package Manager project with a reusable core library,
five user-facing CLI executables, a smoke-test executable, package tests, and
Homebrew formula release automation. Persistent auth is scoped to reader,
sender, and draft; threads and message-box remain on the legacy shared-CLI auth
policy.

## Targets

- `GmailGatewayCore`: domain models, config loading, Gmail integration, GraphQL
  command execution, auth helpers, cache/file commands, and write services
- `GmailGatewayReader`: read-only CLI entry point for `gmail-gateway-reader`
- `GmailGatewayDraft`: draft-mode CLI entry point for `gmail-gateway-draft`
- `GmailGatewaySender`: direct-send CLI entry point for `gmail-gateway-sender`
- `GmailGatewayThreads`: mailbox-mutation CLI entry point for
  `gmail-gateway-threads`
- `GmailGatewayMessageBox`: mail-ingest CLI entry point for
  `gmail-gateway-message-box`
- `GmailGatewaySwiftSmokeTests`: executable smoke tests for CLI workflows
- `GmailGatewayCoreTests`: Swift package tests stored under
  `Tests/GmailGatewayCoreTests`

## Provider Boundary

`GmailGatewayCore` routes provider operations through the internal
`MailProviderAdapter` protocol. `GmailProviderAdapter` is the current adapter
and owns the direct `GmailLiveReader` / `GmailLiveWriter` calls; reader and
writer services depend on the adapter protocol instead of constructing Gmail
clients directly.

## Persistent Auth Boundary

The target persistent-auth design keeps executable mode policy and Gmail record
encoding in `GmailGatewayCore`, behind a Gmail-specific secure-vault adapter.
The adapter reuses the injectable `SecureCredentialStore` and macOS
`KeychainCredentialStore` boundary established by `GoogleServiceGatewayCore`,
using the exact `google-service-gateway` `0.1.1` package release and a
Gmail-specific Keychain namespace. Explicit legacy environment and file sources
remain supported through separate source adapters; secure-store failure never
falls back to a plaintext file. Tokens carry a canonical OAuth-client
fingerprint, and refresh or provider access fails before transport when the
resolved client does not match. A coordinator-owned, OS-visible per-user
advisory lock uses one provider/credential/access-mode identity across all three
executables and processes to serialize setup, login, refresh, and revoke.
Descriptor-relative file mutation rejects symlink substitution, while atomically
installed and synchronized transaction journals ensure recovery never observes
a partially written final journal. Persistent config validation queries the
same injected vault and accepts a missing synthesized client file only when the
exact client profile is present and valid. OAuth login selects a validated
stored Desktop redirect and preserves its IPv4, IPv6, hostname, port, and
callback-path semantics. A
`localhost` receiver binds every locally resolved loopback family on one port
before browser launch and never rewrites the registered hostname. This policy
is injected only for reader, sender, and draft; the shared threads and
message-box modes retain their existing auth and token behavior. See
[design-persistent-auth-commands.md](./design-persistent-auth-commands.md).

## Release Surfaces

- Split Homebrew formula archives under `dist/homebrew/`
- Rendered formula files for the tap under `Formula/`
